// Speech written out on the device, on Windows, by Windows' own speech recogniser (SAPI 5, the desktop dictation
// engine Windows installs with each speech language), for the two plugins that need it (Matt, 2026-11-21: "look for
// all the plugins which don't yet have windows support and add windows support"):
//
// - Live captions (lib/voice/captions.dart, "ghost/captions"): this device's own voice from the default microphone,
//   written out as it is said; words still being said come as "heard" with done false, a finished phrase with done
//   true. Paused while muted.
// - Scribe (lib/voice/scribe.dart, "ghost/scribe"): one track of a recording (track 0 is the mix, each after it a
//   person) read by Media Foundation into a file of plain sound beside it, then given to the recogniser as a stream;
//   each phrase with where it starts and ends.
//
// Where this Windows has no recogniser for dictation (some editions, or a language not installed), "available" says
// false and the plugins say so, as on a phone without on-device recognition.
// _wfopen: the standard library's plain file opening, as voicefx does (_CRT_SECURE_NO_WARNINGS).
#define _CRT_SECURE_NO_WARNINGS
#include "speech.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <sapi.h>

#include <cstdio>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "main_thread.h"

namespace {

// Lets go of a COM object and forgets it; nothing where there is none.
template <typename T>
void Free(T*& p) {
  if (p) p->Release();
  p = nullptr;
}

// UTF-8 as Windows' own wide text, and back.
std::wstring Wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n);
  return out;
}

std::string Narrow(const wchar_t* s) {
  if (!s) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, s, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return std::string();
  std::string out(n - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s, -1, out.data(), n, nullptr, nullptr);
  return out;
}

// What an event carries is let go of as SAPI's own SpClearEvent does (sphelper.h, not used: it needs ATL).
void ClearEvent(SPEVENT& e) {
  if (e.elParamType == SPET_LPARAM_IS_OBJECT && e.lParam) {
    reinterpret_cast<IUnknown*>(e.lParam)->Release();
  } else if ((e.elParamType == SPET_LPARAM_IS_POINTER || e.elParamType == SPET_LPARAM_IS_STRING) && e.lParam) {
    CoTaskMemFree(reinterpret_cast<void*>(e.lParam));
  }
  e.lParam = 0;
}

// The recogniser for [language] ("en-US"): one whose Language attribute is that locale's, else the one Windows
// would use. Null where there is none.
ISpObjectToken* RecognizerFor(const std::string& language) {
  ISpObjectTokenCategory* category = nullptr;
  if (FAILED(CoCreateInstance(CLSID_SpObjectTokenCategory, nullptr, CLSCTX_ALL, IID_ISpObjectTokenCategory, reinterpret_cast<void**>(&category)))) return nullptr;
  ISpObjectToken* found = nullptr;
  if (SUCCEEDED(category->SetId(SPCAT_RECOGNIZERS, FALSE))) {
    LCID lcid = language.empty() ? 0 : LocaleNameToLCID(Wide(language).c_str(), 0);
    wchar_t want[64] = L"";
    if (lcid) wsprintfW(want, L"Language=%x", LANGIDFROMLCID(lcid));
    IEnumSpObjectTokens* tokens = nullptr;
    if (want[0] && SUCCEEDED(category->EnumTokens(want, nullptr, &tokens)) && tokens) {
      tokens->Next(1, &found, nullptr);
      Free(tokens);
    }
    if (!found) {
      wchar_t* id = nullptr;
      if (SUCCEEDED(category->GetDefaultTokenId(&id)) && id) {
        ISpObjectToken* token = nullptr;
        if (SUCCEEDED(CoCreateInstance(CLSID_SpObjectToken, nullptr, CLSCTX_ALL, IID_ISpObjectToken, reinterpret_cast<void**>(&token)))) {
          if (SUCCEEDED(token->SetId(nullptr, id, FALSE))) {
            found = token;
          } else {
            Free(token);
          }
        }
        CoTaskMemFree(id);
      }
    }
  }
  Free(category);
  return found;
}

// An in-process recogniser for dictation, its context and its grammar, each let go of together.
struct Dictation {
  ISpRecognizer* recognizer = nullptr;
  ISpRecoContext* context = nullptr;
  ISpRecoGrammar* grammar = nullptr;

  ~Dictation() {
    if (grammar) grammar->SetDictationState(SPRS_INACTIVE);
    Free(grammar);
    Free(context);
    if (recognizer) recognizer->SetInput(nullptr, FALSE);
    Free(recognizer);
  }

  // Ready to hear [input]: false where this Windows can't take dictation.
  bool Open(const std::string& language, IUnknown* input, ULONGLONG interest) {
    if (FAILED(CoCreateInstance(CLSID_SpInprocRecognizer, nullptr, CLSCTX_ALL, IID_ISpRecognizer, reinterpret_cast<void**>(&recognizer)))) return false;
    ISpObjectToken* token = RecognizerFor(language);
    if (!token) return false;
    HRESULT hr = recognizer->SetRecognizer(token);
    Free(token);
    if (FAILED(hr)) return false;
    if (FAILED(recognizer->SetInput(input, TRUE))) return false;
    if (FAILED(recognizer->CreateRecoContext(&context))) return false;
    if (FAILED(context->SetInterest(interest, interest))) return false;
    if (FAILED(context->CreateGrammar(1, &grammar))) return false;
    if (FAILED(grammar->LoadDictation(nullptr, SPLO_STATIC))) return false;
    return true;
  }

  // Begins listening (and listens again after a pause).
  bool Start() { return SUCCEEDED(grammar->SetDictationState(SPRS_ACTIVE)) && SUCCEEDED(recognizer->SetRecoState(SPRST_ACTIVE)); }
};

// The whole phrase of a result, as text; empty where it has none.
std::string PhraseOf(ISpRecoResult* result) {
  wchar_t* text = nullptr;
  if (FAILED(result->GetText(static_cast<ULONG>(SP_GETWHOLEPHRASE), static_cast<ULONG>(SP_GETWHOLEPHRASE), TRUE, &text, nullptr)) || !text) return std::string();
  std::string out = Narrow(text);
  CoTaskMemFree(text);
  return out;
}

// --- Scribe -----------------------------------------------------------------------------------------------------

// One phrase of a transcript: where it starts and ends in the track, in milliseconds, and what was said.
struct Said {
  int64_t start, end;
  std::string text;
};

// Track [track] of [path] as plain 16-bit sound into [out]; its rate and channels, or an error.
std::string Decode(const std::string& path, int track, const std::wstring& out, UINT32* rate, UINT32* channels) {
  IMFSourceReader* reader = nullptr;
  if (FAILED(MFCreateSourceReaderFromURL(Wide(path).c_str(), nullptr, &reader))) return "can't open the recording";
  // Lets go of the reader however this returns.
  struct Hold {
    IMFSourceReader*& r;
    ~Hold() { Free(r); }
  } hold{reader};
  const DWORD stream = static_cast<DWORD>(track);
  // Only the one track is read, and as 16-bit PCM: Media Foundation puts in the decoder that makes it so.
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  if (FAILED(reader->SetStreamSelection(stream, TRUE))) return "the recording has no such track";
  IMFMediaType* pcm = nullptr;
  MFCreateMediaType(&pcm);
  pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  HRESULT hr = reader->SetCurrentMediaType(stream, nullptr, pcm);
  Free(pcm);
  if (FAILED(hr)) return "the track can't be decoded";
  IMFMediaType* got = nullptr;
  if (FAILED(reader->GetCurrentMediaType(stream, &got))) return "the track can't be decoded";
  got->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  got->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  Free(got);
  FILE* f = _wfopen(out.c_str(), L"wb");
  if (!f) return "can't write beside the recording";
  while (true) {
    DWORD flags = 0;
    IMFSample* sample = nullptr;
    hr = reader->ReadSample(stream, 0, nullptr, &flags, nullptr, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
      Free(sample);
      break;
    }
    if (!sample) continue;
    IMFMediaBuffer* buffer = nullptr;
    if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buffer))) {
      BYTE* p = nullptr;
      DWORD n = 0;
      if (SUCCEEDED(buffer->Lock(&p, nullptr, &n))) {
        fwrite(p, 1, n, f);
        buffer->Unlock();
      }
      Free(buffer);
    }
    Free(sample);
  }
  fclose(f);
  return FAILED(hr) ? "the track couldn't be read to the end" : std::string();
}

// The phrases in [pcm] (16-bit, [rate], [channels]); an error where none could be heard.
std::string Hear(const std::wstring& pcm, UINT32 rate, UINT32 channels, const std::string& language, std::vector<Said>* said) {
  IStream* file = nullptr;
  if (FAILED(SHCreateStreamOnFileEx(pcm.c_str(), STGM_READ | STGM_SHARE_DENY_WRITE, FILE_ATTRIBUTE_NORMAL, FALSE, nullptr, &file))) return "can't read the sound";
  ISpStream* stream = nullptr;
  if (FAILED(CoCreateInstance(CLSID_SpStream, nullptr, CLSCTX_ALL, IID_ISpStream, reinterpret_cast<void**>(&stream)))) {
    Free(file);
    return "speech isn't available";
  }
  // The file has no header, so the recogniser is told what its bytes are.
  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(channels ? channels : 1);
  format.nSamplesPerSec = rate ? rate : 48000;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(format.nChannels * 2);
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  HRESULT hr = stream->SetBaseStream(file, SPDFID_WaveFormatEx, &format);
  Free(file);
  if (FAILED(hr)) {
    Free(stream);
    return "the sound's format isn't one speech takes";
  }
  std::string error;
  {
    Dictation d;
    const ULONGLONG interest = SPFEI(SPEI_RECOGNITION) | SPFEI(SPEI_END_SR_STREAM);
    if (!d.Open(language, stream, interest) || FAILED(d.context->SetNotifyWin32Event()) || !d.Start()) {
      error = "This computer has no speech recognition for this language. Add it in Windows Settings › Time & language › Speech.";
    } else {
      // Phrases are taken as they come, until the recogniser says the stream has ended; a minute with no word from
      // it at all ends the wait with what was heard so far.
      bool ended = false;
      while (!ended) {
        if (d.context->WaitForNotifyEvent(60000) != S_OK) break;
        SPEVENT e = {};
        ULONG n = 0;
        while (!ended && d.context->GetEvents(1, &e, &n) == S_OK && n == 1) {
          if (e.eEventId == SPEI_RECOGNITION && e.elParamType == SPET_LPARAM_IS_OBJECT) {
            auto* result = reinterpret_cast<ISpRecoResult*>(e.lParam);
            std::string text = PhraseOf(result);
            SPRECORESULTTIMES times = {};
            result->GetResultTimes(&times);
            // The event's place in the stream is in bytes, at the phrase's end; the phrase's length is in units of
            // 100 nanoseconds. Both to milliseconds, and the start is the end less the length.
            const int64_t end = static_cast<int64_t>(e.ullAudioStreamOffset * 1000 / format.nAvgBytesPerSec);
            const int64_t length = static_cast<int64_t>(times.ullLength / 10000);
            if (!text.empty()) said->push_back({end > length ? end - length : 0, end, text});
          } else if (e.eEventId == SPEI_END_SR_STREAM) {
            ended = true;
          }
          ClearEvent(e);
        }
      }
    }
  }
  Free(stream);
  return error;
}

// Whether this Windows has a recogniser [language] could be heard by.
bool Available(const std::string& language) {
  ISpObjectToken* token = RecognizerFor(language);
  if (!token) return false;
  Free(token);
  return true;
}

// --- Live captions --------------------------------------------------------------------------------------------

// The message SAPI posts to [g_window] when the live recogniser has events waiting; the two channels; the live
// recogniser while captions are on; and whether this device is muted.
constexpr UINT kHeard = WM_APP + 0x48;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_captions;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_scribe;
std::unique_ptr<Dictation> g_live;
HWND g_window = nullptr;
bool g_muted = false;

// Tells Dart what was heard: [done] false for words still being said, true for a finished phrase.
void Heard(const std::string& text, bool done) {
  if (!g_captions || text.empty()) return;
  flutter::EncodableMap args;
  args[flutter::EncodableValue("text")] = flutter::EncodableValue(text);
  args[flutter::EncodableValue("done")] = flutter::EncodableValue(done);
  g_captions->InvokeMethod("heard", std::make_unique<flutter::EncodableValue>(args));
}

// The live recogniser's window: on SAPI's message it takes every event waiting and passes each on, on the app's
// thread. A guess at the words so far is a hypothesis, a finished phrase a recognition.
LRESULT CALLBACK LiveProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kHeard && g_live && g_live->context) {
    SPEVENT e = {};
    ULONG n = 0;
    while (g_live && g_live->context->GetEvents(1, &e, &n) == S_OK && n == 1) {
      if ((e.eEventId == SPEI_HYPOTHESIS || e.eEventId == SPEI_RECOGNITION) && e.elParamType == SPET_LPARAM_IS_OBJECT && !g_muted) {
        Heard(PhraseOf(reinterpret_cast<ISpRecoResult*>(e.lParam)), e.eEventId == SPEI_RECOGNITION);
      }
      ClearEvent(e);
    }
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

void StopLive() { g_live.reset(); }

// Captions on: a recogniser on the default microphone, in place of any there was. Made but not listening while
// muted. False where it could not be made.
bool StartLive(const std::string& language) {
  StopLive();
  if (!g_window) g_window = MainThreadWindow(LiveProc);
  if (!g_window) return false;
  ISpAudio* mic = nullptr;
  if (FAILED(CoCreateInstance(CLSID_SpMMAudioIn, nullptr, CLSCTX_ALL, IID_ISpAudio, reinterpret_cast<void**>(&mic)))) return false;
  auto d = std::make_unique<Dictation>();
  const ULONGLONG interest = SPFEI(SPEI_HYPOTHESIS) | SPFEI(SPEI_RECOGNITION);
  bool ok = d->Open(language, mic, interest) && SUCCEEDED(d->context->SetNotifyWindowMessage(g_window, kHeard, 0, 0));
  Free(mic);
  if (!ok) return false;
  if (!g_muted && !d->Start()) return false;
  g_live = std::move(d);
  return true;
}

// Muted, the recogniser stops listening (and anything it still says is dropped); unmuted, it listens again.
void SetMuted(bool on) {
  g_muted = on;
  if (!g_live) return;
  if (on) {
    g_live->recognizer->SetRecoState(SPRST_INACTIVE);
  } else {
    g_live->Start();
  }
}

// A call's argument by name, and as text or a whole number: null, empty or 0 where it is missing or another type.
const flutter::EncodableValue* Arg(const flutter::EncodableMap* args, const char* name) {
  if (!args) return nullptr;
  auto it = args->find(flutter::EncodableValue(name));
  return it == args->end() ? nullptr : &it->second;
}

std::string Str(const flutter::EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  const auto* s = v ? std::get_if<std::string>(v) : nullptr;
  return s ? *s : std::string();
}

int Int(const flutter::EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  if (!v) return 0;
  if (const auto* i = std::get_if<int32_t>(v)) return *i;
  if (const auto* l = std::get_if<int64_t>(v)) return static_cast<int>(*l);
  return 0;
}

}  // namespace

void RegisterSpeech(flutter::BinaryMessenger* messenger) {
  MainThreadInit();
  // The app's thread is already in COM (Flutter's engine); SAPI's objects made here live on it.
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  g_captions = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost/captions", &flutter::StandardMethodCodec::GetInstance());
  g_captions->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    const std::string& m = call.method_name();
    if (m == "available") {
      result->Success(flutter::EncodableValue(Available(Str(args, "language"))));
    } else if (m == "start") {
      result->Success(flutter::EncodableValue(StartLive(Str(args, "language"))));
    } else if (m == "stop") {
      StopLive();
      result->Success(flutter::EncodableValue(true));
    } else if (m == "muted") {
      const auto* v = Arg(args, "on");
      const auto* b = v ? std::get_if<bool>(v) : nullptr;
      SetMuted(b && *b);
      result->Success(flutter::EncodableValue(true));
    } else {
      result->NotImplemented();
    }
  });
  g_scribe = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost/scribe", &flutter::StandardMethodCodec::GetInstance());
  g_scribe->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    const std::string& m = call.method_name();
    if (m == "available") {
      result->Success(flutter::EncodableValue(Available(Str(args, "language"))));
    } else if (m == "decode") {
      // One track of a recording as plain 16-bit sound, written to a file, for the recording opened in the mixer
      // (lib/voice/recording_playback.dart): its rate and channels as the recording has them (48 kHz mono as made).
      std::string path = Str(args, "path"), out = Str(args, "out");
      int track = Int(args, "track");
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> held(result.release());
      std::thread([path, out, track, held] {
        HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        HRESULT mf = MFStartup(MF_VERSION);
        UINT32 rate = 0, channels = 0;
        std::string error = SUCCEEDED(mf) ? Decode(path, track, Wide(out), &rate, &channels) : std::string("Media Foundation isn't available");
        if (SUCCEEDED(mf)) MFShutdown();
        if (SUCCEEDED(co)) CoUninitialize();
        RunOnMain([held, error, rate, channels] {
          if (!error.empty()) {
            held->Error("decode", error);
            return;
          }
          flutter::EncodableMap got;
          got[flutter::EncodableValue("rate")] = flutter::EncodableValue(static_cast<int32_t>(rate));
          got[flutter::EncodableValue("channels")] = flutter::EncodableValue(static_cast<int32_t>(channels));
          held->Success(flutter::EncodableValue(got));
        });
      }).detach();
    } else if (m == "transcribe") {
      // One track written out as phrases, on a thread of its own: decoded to a file of plain sound beside the
      // recording, heard, and the file deleted. The answer goes back on the app's thread.
      std::string path = Str(args, "path"), language = Str(args, "language");
      int track = Int(args, "track");
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> held(result.release());
      std::thread([path, language, track, held] {
        HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
        HRESULT mf = MFStartup(MF_VERSION);
        std::vector<Said> said;
        std::string error;
        wchar_t tag[32];
        wsprintfW(tag, L".track%d.pcm", track);
        const std::wstring pcm = Wide(path) + tag;
        UINT32 rate = 0, channels = 0;
        error = SUCCEEDED(mf) ? Decode(path, track, pcm, &rate, &channels) : std::string("Media Foundation isn't available");
        if (error.empty()) error = Hear(pcm, rate, channels, language, &said);
        DeleteFileW(pcm.c_str());
        if (SUCCEEDED(mf)) MFShutdown();
        if (SUCCEEDED(co)) CoUninitialize();
        RunOnMain([held, error, said] {
          if (!error.empty()) {
            held->Error("transcribe", error);
            return;
          }
          flutter::EncodableList lines;
          for (const auto& s : said) {
            flutter::EncodableMap line;
            line[flutter::EncodableValue("start")] = flutter::EncodableValue(s.start);
            line[flutter::EncodableValue("end")] = flutter::EncodableValue(s.end);
            line[flutter::EncodableValue("text")] = flutter::EncodableValue(s.text);
            lines.push_back(flutter::EncodableValue(line));
          }
          held->Success(flutter::EncodableValue(lines));
        });
      }).detach();
    } else {
      result->NotImplemented();
    }
  });
}
