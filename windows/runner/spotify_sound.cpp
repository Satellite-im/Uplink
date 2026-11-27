// The sound of the Spotify app on this PC, and of nothing else (spotify_sound.h): WASAPI's loopback of one process and
// the processes under it, Windows 10 version 2004 and later, which asks nothing of the person.
//
// Only ever INCLUDE of Spotify's own process tree. Where Spotify is not running, or has gone, the track is silent and
// nothing else is listened to: there is no path here to the system's sound as a whole.
//
// CMakeLists.txt compiles this file with RTC_DESKTOP_DEVICE, as flutter_webrtc itself is: libwebrtc's factory has a
// function more with it, before those called here, and without it each call would reach the wrong one.
#include "spotify_sound.h"

#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <objidl.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdlib>
#include <cwchar>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "flutter_webrtc.h"
#include "flutter_webrtc/flutter_web_r_t_c_plugin.h"
#include "rtc_audio_source.h"
#include "rtc_audio_track.h"
#include "rtc_peerconnection_factory.h"

#ifndef RTC_DESKTOP_DEVICE
#error "spotify_sound.cpp must be compiled with RTC_DESKTOP_DEVICE (CMakeLists.txt)"
#endif

// In the Windows SDK from 10.0.20348; written here for an older one, as flutter_webrtc does.
#ifndef VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK
#define VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK L"VAD\\Process_Loopback"
typedef enum { PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE = 0 } PROCESS_LOOPBACK_MODE;
typedef struct {
  DWORD TargetProcessId;
  PROCESS_LOOPBACK_MODE ProcessLoopbackMode;
} AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS;
typedef enum { AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1 } AUDIOCLIENT_ACTIVATION_TYPE;
typedef struct {
  AUDIOCLIENT_ACTIVATION_TYPE ActivationType;
  union {
    AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
  };
} AUDIOCLIENT_ACTIVATION_PARAMS;
#endif

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

namespace {

constexpr wchar_t kName[] = L"Spotify.exe";

// A COM pointer let go of when it goes out of scope.
template <typename T>
class Com {
 public:
  Com() = default;
  Com(const Com&) = delete;
  Com& operator=(const Com&) = delete;
  ~Com() {
    if (p_) p_->Release();
  }
  T** out() { return &p_; }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }

 private:
  T* p_ = nullptr;
};

// A handle closed when it goes out of scope.
class Handle {
 public:
  explicit Handle(HANDLE h) : h_(h == INVALID_HANDLE_VALUE ? nullptr : h) {}
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  ~Handle() {
    if (h_) CloseHandle(h_);
  }
  HANDLE get() const { return h_; }
  explicit operator bool() const { return h_ != nullptr; }

 private:
  HANDLE h_;
};

// Told, on one of Windows' own threads, that the loopback has been made. Windows keeps a count on it for as long as it
// may still call it, so giving up waiting for it leaves nothing dangling, and what it was given goes with it.
class Activated : public IActivateAudioInterfaceCompletionHandler, public IAgileObject {
 public:
  // For the process [pid] and those under it, and for nothing else.
  explicit Activated(DWORD pid) : done_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {
    params_.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params_.ProcessLoopbackParams.TargetProcessId = pid;
    params_.ProcessLoopbackParams.ProcessLoopbackMode = PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
    PropVariantInit(&given_);
    given_.vt = VT_BLOB;
    given_.blob.cbSize = sizeof(params_);
    given_.blob.pBlobData = reinterpret_cast<BYTE*>(&params_);
  }

  HANDLE done() const { return done_.get(); }

  // What is asked for, kept here so that it is there for as long as Windows may look at it.
  PROPVARIANT* given() { return &given_; }

  // The client made, where one was: its count goes to the caller. After [done] alone.
  HRESULT Take(IAudioClient** client) {
    *client = client_;
    client_ = nullptr;
    return FAILED(result_) ? result_ : (*client ? S_OK : E_FAIL);
  }

  STDMETHODIMP ActivateCompleted(IActivateAudioInterfaceAsyncOperation* op) override {
    HRESULT made = E_FAIL;
    IUnknown* unknown = nullptr;
    const HRESULT asked = op->GetActivateResult(&made, &unknown);
    result_ = FAILED(asked) ? asked : made;
    if (SUCCEEDED(result_) && unknown) unknown->QueryInterface(__uuidof(IAudioClient), reinterpret_cast<void**>(&client_));
    if (unknown) unknown->Release();
    SetEvent(done_.get());
    return S_OK;
  }

  STDMETHODIMP QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IActivateAudioInterfaceCompletionHandler)) {
      *out = static_cast<IActivateAudioInterfaceCompletionHandler*>(this);
    } else if (iid == __uuidof(IAgileObject)) {
      // Without it Windows refuses the handler from this kind of thread (RO_E_WRONG_THREAD).
      *out = static_cast<IAgileObject*>(this);
    } else {
      *out = nullptr;
      return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
  }

  STDMETHODIMP_(ULONG) AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }

  STDMETHODIMP_(ULONG) Release() override {
    const LONG left = InterlockedDecrement(&refs_);
    if (left == 0) delete this;
    return static_cast<ULONG>(left);
  }

 private:
  virtual ~Activated() {
    if (client_) client_->Release();
  }

  volatile LONG refs_ = 1;
  AUDIOCLIENT_ACTIVATION_PARAMS params_ = {};
  PROPVARIANT given_;
  Handle done_;
  HRESULT result_ = E_FAIL;
  IAudioClient* client_ = nullptr;
};

// The processor's count of time, in hundreds of nanoseconds.
int64_t Ticks() {
  static const int64_t frequency = [] {
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    return f.QuadPart;
  }();
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  // In two parts, so that the product never overflows.
  return now.QuadPart / frequency * 10000000 + now.QuadPart % frequency * 10000000 / frequency;
}

// The last part of the file [process] runs, as it is named.
bool IsSpotify(HANDLE process) {
  std::vector<wchar_t> path(32768);
  DWORD n = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &n)) return false;
  const wchar_t* name = wcsrchr(path.data(), L'\\');
  return name && _wcsicmp(name + 1, kName) == 0;
}

// flutter_webrtc's own factory and its list of the tracks this device made, which its friends use (its screen capture
// makes its loopback track the same way). They are protected: reached through pointers to members, which a class
// derived from it may take. Never made.
struct Inside : public flutter_webrtc_plugin::FlutterWebRTCBase {
  using Base = flutter_webrtc_plugin::FlutterWebRTCBase;
  static libwebrtc::scoped_refptr<libwebrtc::RTCPeerConnectionFactory>& Factory(Base* base) { return base->*(&Inside::factory_); }
  static std::map<std::string, libwebrtc::scoped_refptr<libwebrtc::RTCMediaTrack>>& Tracks(Base* base) { return base->*(&Inside::local_tracks_); }
};

flutter_webrtc_plugin::FlutterWebRTCBase* Plugin() {
  flutter_webrtc_plugin::FlutterWebRTC* webrtc = FlutterWebRTCPluginSharedInstance();
  if (!webrtc) return nullptr;
  flutter_webrtc_plugin::FlutterWebRTCBase* base = webrtc;
  // Asked for something, it has made its factory.
  if (!base->audio_processing()) return nullptr;
  return Inside::Factory(base) ? base : nullptr;
}

}  // namespace

bool CanHearOneProgram() {
  // GetVersionEx says what the manifest claims; this says what Windows is.
  using RtlGetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) return false;
  auto ask = reinterpret_cast<RtlGetVersion>(reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion")));
  if (!ask) return false;
  OSVERSIONINFOW v = {};
  v.dwOSVersionInfoSize = sizeof(v);
  return ask(&v) == 0 && (v.dwMajorVersion > 10 || (v.dwMajorVersion == 10 && v.dwBuildNumber >= 19041));
}

double SpeakerRate() {
  Com<IMMDeviceEnumerator> all;
  Com<IMMDevice> device;
  Com<IAudioClient> client;
  WAVEFORMATEX* format = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(all.out())))) return 0;
  if (FAILED(all->GetDefaultAudioEndpoint(eRender, eConsole, device.out()))) return 0;
  if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.out())))) return 0;
  if (FAILED(client->GetMixFormat(&format)) || !format) return 0;
  const double rate = format->nSamplesPerSec;
  CoTaskMemFree(format);
  return rate;
}

HANDLE OpenSpotify(DWORD* pid) {
  struct One {
    DWORD id, parent;
  };
  std::vector<One> found;
  {
    Handle all(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    if (!all) return nullptr;
    PROCESSENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    for (BOOL more = Process32FirstW(all.get(), &entry); more; more = Process32NextW(all.get(), &entry)) {
      if (_wcsicmp(entry.szExeFile, kName) == 0) found.push_back({entry.th32ProcessID, entry.th32ParentProcessID});
    }
  }
  DWORD ours = 0;
  ProcessIdToSessionId(GetCurrentProcessId(), &ours);
  for (const One& one : found) {
    bool root = one.id != 0;
    for (const One& other : found) {
      if (other.id == one.parent && other.id != one.id) root = false;
    }
    DWORD session = 0;
    if (!root || !ProcessIdToSessionId(one.id, &session) || session != ours) continue;
    Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, one.id));
    // Looked at again by its handle: the number may have been given to another process since the list was made.
    if (!process || !IsSpotify(process.get())) continue;
    HANDLE kept = nullptr;
    if (!DuplicateHandle(GetCurrentProcess(), process.get(), GetCurrentProcess(), &kept, 0, FALSE, DUPLICATE_SAME_ACCESS)) continue;
    if (pid) *pid = one.id;
    return kept;
  }
  return nullptr;
}

// What WebRTC has of it: the source the sound is given to, the track a connection sends, and its name.
struct SpotifySound::Track {
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source;
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track;
  std::string id;
};

SpotifySound::SpotifySound(std::function<void()> quit, std::function<void(std::vector<uint8_t>)> chunk) : quit_(std::move(quit)), tee_(std::move(chunk)) {}

SpotifySound::~SpotifySound() { End(); }

std::string SpotifySound::Begin(bool echo, bool noise, bool gain) {
  if (track_) return track_->id;
  if (!CanHearOneProgram()) return std::string();
  auto* base = Plugin();
  if (!base) return std::string();

  static int made = 0;
  const std::string id = "ghost-music-" + std::to_string(GetCurrentProcessId()) + "-" + std::to_string(++made);
  libwebrtc::RTCAudioOptions options;
  options.echo_cancellation = echo;
  options.noise_suppression = noise;
  options.auto_gain_control = gain;
  auto track = std::make_unique<Track>();
  track->id = id;
  auto& factory = Inside::Factory(base);
  track->source = factory->CreateAudioSource(("source-" + id).c_str(), libwebrtc::RTCAudioSource::SourceType::kCustom, options);
  if (!track->source) return std::string();
  track->track = factory->CreateAudioTrack(track->source, id.c_str());
  if (!track->track) return std::string();

  stop_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (!stop_) return std::string();
  Inside::Tracks(base)[id] = track->track;
  track_ = std::move(track);
  feed_->Clear();
  peak_ = 0.0f;
  capture_ = std::thread([this] { Capture(); });
  feeder_ = std::thread([this] { Feed(); });
  return id;
}

void SpotifySound::End() {
  if (stop_) SetEvent(stop_);
  if (capture_.joinable()) capture_.join();
  if (feeder_.joinable()) feeder_.join();
  if (stop_) CloseHandle(stop_);
  stop_ = nullptr;
  if (track_) {
    auto* base = FlutterWebRTCPluginSharedInstance();
    if (base) Inside::Tracks(base).erase(track_->id);
  }
  track_ = nullptr;
  feed_->Clear();
}

float SpotifySound::Level() { return peak_.exchange(0.0f); }

void SpotifySound::Capture() {
  // This thread's own COM, for as long as it lives.
  const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  while (WaitForSingleObject(stop_, 0) != WAIT_OBJECT_0) {
    DWORD pid = 0;
    Handle process(OpenSpotify(&pid));
    if (process && pid != 0) {
      Hear(pid, process.get());
      // It has gone, and was not told to: said, and looked for again.
      if (WaitForSingleObject(process.get(), 0) == WAIT_OBJECT_0 && WaitForSingleObject(stop_, 0) != WAIT_OBJECT_0 && quit_) quit_();
    }
    // Not running, gone, or not to be had: looked for again in a second. Nothing is listened to meanwhile.
    if (WaitForSingleObject(stop_, 1000) == WAIT_OBJECT_0) break;
  }
  if (SUCCEEDED(com)) CoUninitialize();
}

bool SpotifySound::Hear(DWORD pid, HANDLE process) {
  Com<IAudioClient> client;
  {
    Com<Activated> handler;
    *handler.out() = new Activated(pid);
    if (!handler->done()) return false;
    Com<IActivateAudioInterfaceAsyncOperation> operation;
    if (FAILED(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), handler->given(), handler.get(), operation.out()))) return false;
    HANDLE either[] = {stop_, handler->done()};
    if (WaitForMultipleObjects(2, either, FALSE, 5000) != WAIT_OBJECT_0 + 1) return false;
    if (FAILED(handler->Take(client.out()))) return false;
  }

  // 48 kHz stereo 16-bit, whatever the speakers are set to: this kind of client makes what it is asked for.
  WAVEFORMATEX format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(MusicFeed::kChannels);
  format.nSamplesPerSec = MusicFeed::kRate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(format.nChannels * format.wBitsPerSample / 8);
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  const DWORD flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
  if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 200000, 0, &format, nullptr))) return false;

  Handle ready(CreateEventW(nullptr, FALSE, FALSE, nullptr));
  if (!ready || FAILED(client->SetEventHandle(ready.get()))) return false;
  Com<IAudioCaptureClient> captured;
  if (FAILED(client->GetService(__uuidof(IAudioCaptureClient), reinterpret_cast<void**>(captured.out())))) return false;
  if (FAILED(client->Start())) return false;

  DWORD task = 0;
  HANDLE priority = AvSetMmThreadCharacteristicsW(L"Audio", &task);
  bool on = true;
  while (on) {
    // Told to end, or Spotify gone: first in the list, so both are heard before more sound is.
    HANDLE any[] = {stop_, process, ready.get()};
    const DWORD which = WaitForMultipleObjects(3, any, FALSE, 1000);
    if (which == WAIT_OBJECT_0 || which == WAIT_OBJECT_0 + 1 || which == WAIT_FAILED) break;
    UINT32 packet = 0;
    for (;;) {
      if (FAILED(captured->GetNextPacketSize(&packet))) {
        on = false;
        break;
      }
      if (packet == 0) break;
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD how = 0;
      const HRESULT got = captured->GetBuffer(&data, &frames, &how, nullptr, nullptr);
      if (got == AUDCLNT_S_BUFFER_EMPTY) break;
      if (FAILED(got)) {
        on = false;
        break;
      }
      const auto* samples = (how & AUDCLNT_BUFFERFLAGS_SILENT) ? nullptr : reinterpret_cast<const int16_t*>(data);
      feed_->Write(samples, frames);
      tee_.Write(samples, frames);
      if (samples) {
        int loudest = 0;
        for (size_t i = 0; i < static_cast<size_t>(frames) * MusicFeed::kChannels; i++) loudest = (std::max)(loudest, std::abs(static_cast<int>(samples[i])));
        const float now = static_cast<float>(loudest) / 32768.0f;
        float was = peak_.load();
        while (now > was && !peak_.compare_exchange_weak(was, now)) {
        }
      }
      if (FAILED(captured->ReleaseBuffer(frames))) {
        on = false;
        break;
      }
    }
  }
  if (priority) AvRevertMmThreadCharacteristics(priority);
  client->Stop();
  feed_->Clear();
  return true;
}

void SpotifySound::Feed() {
  DWORD task = 0;
  HANDLE priority = AvSetMmThreadCharacteristicsW(L"Audio", &task);
  HANDLE made = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
  // Before Windows 10 version 1803 there is no such timer; those can't hear one program either, but a timer all the same.
  Handle timer(made ? made : CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS));
  std::vector<int16_t> block(MusicFeed::kFrames * MusicFeed::kChannels);
  constexpr int64_t kStep = 100000;  // 10 ms
  int64_t next = Ticks();
  while (timer) {
    const int64_t now = Ticks();
    // The PC slept, or the thread was held up: on from here rather than a burst of everything missed.
    if (now > next + kStep * 20) next = now;
    if (now < next) {
      LARGE_INTEGER due;
      due.QuadPart = -(next - now);
      if (!SetWaitableTimer(timer.get(), &due, 0, nullptr, nullptr, FALSE)) break;
      HANDLE either[] = {stop_, timer.get()};
      if (WaitForMultipleObjects(2, either, FALSE, INFINITE) != WAIT_OBJECT_0 + 1) break;
    } else if (WaitForSingleObject(stop_, 0) == WAIT_OBJECT_0) {
      break;
    }
    next += kStep;
    feed_->Read(block.data(), MusicFeed::kFrames);
    track_->source->CaptureFrame(block.data(), 16, MusicFeed::kRate, MusicFeed::kChannels, MusicFeed::kFrames);
  }
  if (priority) AvRevertMmThreadCharacteristics(priority);
}
