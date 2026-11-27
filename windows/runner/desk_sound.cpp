// Voice messages from Windows' microphone (GMFB-32, from the Uplink gap review: "voice messages from the desktop"), as
// the Mac records them (macos/Runner/DeskSound.swift) and on the same channel, so lib/desktop/platform.dart asks both
// alike:
//
// - "voiceStart" {bytes}: opens the default microphone (waveIn, 48 kHz mono 16-bit, a twentieth of a second a block)
//   and answers {ok, seconds}: how long fits in [bytes] once made AAC, which on Windows is 96 kbit/s (the least Media
//   Foundation's AAC encoder makes; the Mac's 24 kbit/s is below it). {ok: false, denied: true} where Windows would not
//   open it (the microphone switched off for apps in Settings › Privacy), {ok: false, error} where there is none.
// - "voiceLevel": the loudest it has been since last asked, 0 to 1, and whether the recording is as long as it may be
//   ("full"): it keeps no more from there, as the Mac's and the phone's stop themselves.
// - "voiceCancel": closes it and keeps nothing.
// - "voiceStop": closes it and answers the recording as AAC in an .m4a (call_recorder.cpp's encoder, on a thread of its
//   own), or nothing where it was under a second.
//
// The microphone is open only between start and stop or cancel. The samples are held in memory (a five-minute message
// is 28 MB) and written to the temporary folder only to be encoded, then removed.
#define _CRT_SECURE_NO_WARNINGS
#include "desk_sound.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <mmsystem.h>
#include <mfapi.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

#include "call_recorder.h"
#include "main_thread.h"

namespace {

// The microphone's rate; what the encoder makes of a second; how many blocks the microphone fills in turn, and how
// long each is (a twentieth of a second); and the longest a message may be whatever it may weigh.
constexpr int kRate = 48000;
constexpr int kBytesPerSecond = 12000;  // 96 kbit/s
constexpr int kBlocks = 4;
constexpr int kBlockFrames = kRate / 20;
constexpr int kMostSeconds = 600;

// Windows' wide text as UTF-8, for the paths the encoder is given.
std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string out(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, out.data(), size, nullptr, nullptr);
  return out;
}

// One voice message being recorded: the open microphone, a thread that takes each block as it fills, and the samples
// kept so far.
class Recording {
 public:
  ~Recording() { Close(); }

  // Opens the microphone, keeping at most [most] samples: empty, "denied", or why not.
  std::string Open(size_t most) {
    most_ = most;
    if (waveInGetNumDevs() == 0) return "There's no microphone on this PC";
    WAVEFORMATEX f{};
    f.wFormatTag = WAVE_FORMAT_PCM;
    f.nChannels = 1;
    f.nSamplesPerSec = kRate;
    f.wBitsPerSample = 16;
    f.nBlockAlign = 2;
    f.nAvgBytesPerSec = kRate * 2;
    event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event_) return "The microphone could not be started";
    MMRESULT m = waveInOpen(&in_, WAVE_MAPPER, &f, reinterpret_cast<DWORD_PTR>(event_), 0, CALLBACK_EVENT);
    if (m == MMSYSERR_BADDEVICEID || m == MMSYSERR_NODRIVER) return "There's no microphone on this PC";
    if (m != MMSYSERR_NOERROR) {
      in_ = nullptr;
      return "denied";
    }
    for (int i = 0; i < kBlocks; i++) {
      blocks_[i].assign(kBlockFrames, 0);
      headers_[i] = WAVEHDR{};
      headers_[i].lpData = reinterpret_cast<LPSTR>(blocks_[i].data());
      headers_[i].dwBufferLength = kBlockFrames * 2;
      waveInPrepareHeader(in_, &headers_[i], sizeof(WAVEHDR));
      waveInAddBuffer(in_, &headers_[i], sizeof(WAVEHDR));
    }
    if (waveInStart(in_) != MMSYSERR_NOERROR) return "The microphone could not be started";
    running_.store(true);
    pump_ = std::thread([this] { Pump(); });
    return {};
  }

  // The loudest since last asked, and whether it is full.
  std::pair<double, bool> Level() {
    std::lock_guard<std::mutex> lock(mutex_);
    double p = peak_;
    peak_ = 0;
    return {std::min(1.0, p), full_};
  }

  // Closes the microphone; the samples it kept.
  std::vector<int16_t> Close() {
    // The pump is woken to see it has been stopped, and waited for, before the blocks it reads are taken away.
    if (running_.exchange(false)) {
      SetEvent(event_);
      if (pump_.joinable()) pump_.join();
    }
    if (in_) {
      waveInReset(in_);
      // What the last blocks held when it stopped.
      for (int i = 0; i < kBlocks; i++) {
        if (headers_[i].dwFlags & WHDR_DONE) Take(headers_[i]);
        waveInUnprepareHeader(in_, &headers_[i], sizeof(WAVEHDR));
      }
      waveInClose(in_);
      in_ = nullptr;
    }
    if (event_) {
      CloseHandle(event_);
      event_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    return std::move(samples_);
  }

 private:
  // On its own thread: waits for Windows' word that a block is full (or a fifth of a second), takes every full
  // block, and hands each back to be filled again.
  void Pump() {
    while (running_.load()) {
      WaitForSingleObject(event_, 200);
      for (int i = 0; i < kBlocks && running_.load(); i++) {
        WAVEHDR& h = headers_[i];
        if (!(h.dwFlags & WHDR_DONE)) continue;
        Take(h);
        h.dwFlags &= ~WHDR_DONE;
        waveInAddBuffer(in_, &h, sizeof(WAVEHDR));
      }
    }
  }

  // One block's samples: the loudest of them is noted even once the recording is full, so the level still moves;
  // the samples are kept only while there is room.
  void Take(WAVEHDR& h) {
    const auto* p = reinterpret_cast<const int16_t*>(h.lpData);
    const size_t n = h.dwBytesRecorded / 2;
    h.dwBytesRecorded = 0;
    std::lock_guard<std::mutex> lock(mutex_);
    double loud = 0;
    for (size_t k = 0; k < n; k++) loud = std::max(loud, std::abs(static_cast<double>(p[k])) / 32768.0);
    peak_ = std::max(peak_, loud);
    if (full_) return;
    const size_t room = most_ > samples_.size() ? most_ - samples_.size() : 0;
    const size_t take = std::min(n, room);
    samples_.insert(samples_.end(), p, p + take);
    if (samples_.size() >= most_) full_ = true;
  }

  HWAVEIN in_ = nullptr;
  HANDLE event_ = nullptr;
  std::vector<int16_t> blocks_[kBlocks];
  WAVEHDR headers_[kBlocks]{};
  std::thread pump_;
  std::atomic<bool> running_{false};
  std::mutex mutex_;
  std::vector<int16_t> samples_;
  double peak_ = 0;
  size_t most_ = 0;
  bool full_ = false;
};

// The recording under way, if any: one at a time.
std::unique_ptr<Recording> g_recording;

// The "bytes" argument of a call: how much a message may weigh, or 0 where it is not said.
int BytesOf(const flutter::EncodableValue* args) {
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    auto it = map->find(flutter::EncodableValue("bytes"));
    if (it != map->end()) {
      if (const auto* n = std::get_if<int32_t>(&it->second)) return *n;
      if (const auto* n = std::get_if<int64_t>(&it->second)) return static_cast<int>(*n);
    }
  }
  return 0;
}

// [samples] as an .m4a's bytes; empty with [error] set where it couldn't.
std::vector<uint8_t> Encoded(const std::vector<int16_t>& samples, std::string& error) {
  wchar_t folder[MAX_PATH];
  GetTempPathW(MAX_PATH, folder);
  const std::wstring base = std::wstring(folder) + L"ghost-voice-" + std::to_wstring(GetTickCount64());
  const std::wstring pcm = base + L".pcm", m4a = base + L".m4a";
  std::vector<uint8_t> out;
  FILE* f = _wfopen(pcm.c_str(), L"wb");
  if (!f) {
    error = "The recording has nowhere to go";
    return out;
  }
  fwrite(samples.data(), 2, samples.size(), f);
  fclose(f);
  error = EncodeAac(Utf8(pcm), Utf8(m4a), kBytesPerSecond);
  DeleteFileW(pcm.c_str());
  if (error.empty()) {
    FILE* r = _wfopen(m4a.c_str(), L"rb");
    if (r) {
      fseek(r, 0, SEEK_END);
      long size = ftell(r);
      fseek(r, 0, SEEK_SET);
      if (size > 0) {
        out.resize(static_cast<size_t>(size));
        out.resize(fread(out.data(), 1, out.size(), r));
      }
      fclose(r);
    }
    if (out.empty()) error = "The recording could not be read back";
  }
  DeleteFileW(m4a.c_str());
  return out;
}

}  // namespace

bool DeskSoundHandle(const flutter::MethodCall<flutter::EncodableValue>& call,
                     std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  const std::string& m = call.method_name();
  using flutter::EncodableMap;
  using flutter::EncodableValue;
  if (m == "voiceStart") {
    if (g_recording) g_recording->Close();
    g_recording.reset();
    // How many samples fit in what a message may weigh, at the encoder's rate; ten minutes at most.
    const int bytes = BytesOf(call.arguments());
    int seconds = bytes > 0 ? bytes / kBytesPerSecond : kMostSeconds;
    seconds = std::max(1, std::min(kMostSeconds, seconds));
    auto made = std::make_unique<Recording>();
    const std::string why = made->Open(static_cast<size_t>(seconds) * kRate);
    if (why.empty()) {
      g_recording = std::move(made);
      result->Success(EncodableValue(EncodableMap{{EncodableValue("ok"), EncodableValue(true)}, {EncodableValue("seconds"), EncodableValue(seconds)}}));
    } else if (why == "denied") {
      result->Success(EncodableValue(EncodableMap{{EncodableValue("ok"), EncodableValue(false)}, {EncodableValue("denied"), EncodableValue(true)}}));
    } else {
      result->Success(EncodableValue(EncodableMap{{EncodableValue("ok"), EncodableValue(false)}, {EncodableValue("error"), EncodableValue(why)}}));
    }
    return true;
  }
  if (m == "voiceLevel") {
    double level = 0;
    bool full = false;
    if (g_recording) std::tie(level, full) = g_recording->Level();
    result->Success(EncodableValue(EncodableMap{{EncodableValue("level"), EncodableValue(level)}, {EncodableValue("full"), EncodableValue(full)}}));
    return true;
  }
  if (m == "voiceCancel") {
    if (g_recording) g_recording->Close();
    g_recording.reset();
    result->Success();
    return true;
  }
  if (m == "voiceStop") {
    std::vector<int16_t> samples;
    if (g_recording) samples = g_recording->Close();
    g_recording.reset();
    // Under a second is nothing worth sending, as on the Mac.
    if (samples.size() < static_cast<size_t>(kRate * 9 / 10)) {
      result->Success();
      return true;
    }
    std::shared_ptr<flutter::MethodResult<EncodableValue>> held(result.release());
    std::thread([samples = std::move(samples), held] {
      HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      HRESULT mf = MFStartup(MF_VERSION);
      std::string error;
      std::vector<uint8_t> bytes = SUCCEEDED(mf) ? Encoded(samples, error) : std::vector<uint8_t>();
      if (FAILED(mf)) error = "Media Foundation isn't available";
      if (SUCCEEDED(mf)) MFShutdown();
      if (SUCCEEDED(co)) CoUninitialize();
      RunOnMain([held, error, bytes = std::move(bytes)]() mutable {
        if (error.empty()) {
          held->Success(EncodableValue(std::move(bytes)));
        } else {
          held->Error("voice", error);
        }
      });
    }).detach();
    return true;
  }
  return false;
}
