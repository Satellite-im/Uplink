// A player of this PC's own for a circle's music sent without loss (lib/voice/music_sink.dart; Matt, 2026-11-25: "I'd like
// it to stream lossless audio"): the `ghost/music` channel. What it is given is played as it is, 48 kHz stereo 16-bit, by
// WASAPI in shared mode, on the device the call plays to; Windows makes it the device's own rate where that is another.
//
// WebRTC's echo canceller on Windows takes out what WebRTC plays and knows nothing of this: so it is told where the sound
// goes ("way"), and lib/voice/spotify.dart plays it to headphones alone.
#include "music_sink.h"

#include "main_thread.h"
#include "music_ring.h"
#include "utils.h"

#include <windows.h>

#include <audioclient.h>
#include <avrt.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = std::shared_ptr<flutter::MethodResult<EncodableValue>>;

// PKEY_AudioEndpoint_FormFactor, written here so that nothing more is linked for it.
const PROPERTYKEY kFormFactor = {{0x1da5d803, 0xd492, 0x4edd, {0x8c, 0x23, 0xe0, 0xc0, 0xff, 0xee, 0x7f, 0x0e}}, 0};

template <typename T>
class Com {
 public:
  Com() = default;
  Com(const Com&) = delete;
  Com& operator=(const Com&) = delete;
  ~Com() { reset(); }
  T** out() {
    reset();
    return &p_;
  }
  T* get() const { return p_; }
  T* operator->() const { return p_; }
  explicit operator bool() const { return p_ != nullptr; }
  void reset() {
    if (p_) p_->Release();
    p_ = nullptr;
  }

 private:
  T* p_ = nullptr;
};

std::wstring Wide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n > 0 ? n : 0, L'\0');
  if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

// The device the call's WebRTC calls [id] (Windows' own id of it); the system's own for none, or one that is gone.
void Device(const std::wstring& id, IMMDevice** device) {
  *device = nullptr;
  Com<IMMDeviceEnumerator> all;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(all.out())))) return;
  if (!id.empty() && SUCCEEDED(all->GetDevice(id.c_str(), device)) && *device) {
    DWORD state = 0;
    if (SUCCEEDED((*device)->GetState(&state)) && state == DEVICE_STATE_ACTIVE) return;
    (*device)->Release();
    *device = nullptr;
  }
  all->GetDefaultAudioEndpoint(eRender, eConsole, device);
}

// Where the sound goes, with nothing opened: what kind of thing Windows says it is, and the rate it runs at.
EncodableMap Way(const std::wstring& id) {
  EncodableMap out;
  std::string to = "none";
  int32_t rate = 0;
  Com<IMMDevice> device;
  Device(id, device.out());
  if (device) {
    // Windows calls a jack, a USB box and a laptop's own speakers alike "speakers": its person is asked.
    to = "unknown";
    LPWSTR name = nullptr;
    if (SUCCEEDED(device->GetId(&name)) && name) {
      out[EncodableValue("id")] = EncodableValue(Utf8FromUtf16(name));
      CoTaskMemFree(name);
    }
    Com<IPropertyStore> store;
    if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, store.out()))) {
      PROPVARIANT v;
      PropVariantInit(&v);
      if (SUCCEEDED(store->GetValue(kFormFactor, &v)) && v.vt == VT_UI4 && (v.ulVal == Headphones || v.ulVal == Headset)) to = "headphones";
      PropVariantClear(&v);
    }
    Com<IAudioClient> client;
    WAVEFORMATEX* format = nullptr;
    if (SUCCEEDED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.out()))) && SUCCEEDED(client->GetMixFormat(&format)) && format) {
      rate = static_cast<int32_t>(format->nSamplesPerSec);
      CoTaskMemFree(format);
    }
    // A Bluetooth headset whose microphone is in use runs at a call's rate.
    if (rate > 0 && rate < 44100) to = "call";
  }
  out[EncodableValue("to")] = EncodableValue(to);
  out[EncodableValue("rate")] = EncodableValue(rate);
  return out;
}

// The player: a thread of its own that opens the device and keeps it fed.
class Player {
 public:
  Player() : stop_(CreateEventW(nullptr, TRUE, FALSE, nullptr)), moved_(CreateEventW(nullptr, FALSE, FALSE, nullptr)) {}

  ~Player() {
    Close();
    if (stop_) CloseHandle(stop_);
    if (moved_) CloseHandle(moved_);
  }

  MusicRing ring;

  // Begins; [done] is told on this player's thread whether a device was opened.
  void Open(std::wstring device, std::function<void(bool)> done) {
    device_ = std::move(device);
    thread_ = std::thread([this, done] { Run(done); });
  }

  void To(std::wstring device) {
    {
      std::lock_guard<std::mutex> hold(lock_);
      if (device == device_) return;
      device_ = std::move(device);
    }
    SetEvent(moved_);
  }

  void Close() {
    if (stop_) SetEvent(stop_);
    if (thread_.joinable()) thread_.join();
  }

 private:
  void Run(std::function<void(bool)> done) {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    DWORD task = 0;
    HANDLE priority = AvSetMmThreadCharacteristicsW(L"Audio", &task);
    bool said = false;
    while (stop_ && moved_ && WaitForSingleObject(stop_, 0) != WAIT_OBJECT_0) {
      std::wstring device;
      {
        std::lock_guard<std::mutex> hold(lock_);
        device = device_;
      }
      Play(device, [&] {
        if (!said) done(true);
        said = true;
      });
      if (!said) {
        // Never opened: that is the answer, and there is nothing more to do.
        done(false);
        said = true;
        break;
      }
      // The device went, or another was chosen: opened again, after a moment where it can't be.
      if (WaitForSingleObject(stop_, 200) == WAIT_OBJECT_0) break;
    }
    if (!said) done(false);
    if (priority) AvRevertMmThreadCharacteristics(priority);
    if (SUCCEEDED(com)) CoUninitialize();
  }

  // Plays to [device] until it goes, another is chosen, or [stop_]. [opened] is told once it plays.
  void Play(const std::wstring& id, std::function<void()> opened) {
    Com<IMMDevice> device;
    Device(id, device.out());
    if (!device) return;
    Com<IAudioClient> client;
    if (FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.out())))) return;
    WAVEFORMATEX format = {};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 2;
    format.nSamplesPerSec = MusicRing::kRate;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 4;
    format.nAvgBytesPerSec = MusicRing::kRate * 4;
    const DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    // 40 ms in Windows' hands.
    if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 400000, 0, &format, nullptr))) return;
    HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!ready) return;
    Com<IAudioRenderClient> render;
    UINT32 room = 0;
    if (SUCCEEDED(client->SetEventHandle(ready)) && SUCCEEDED(client->GetBufferSize(&room)) && SUCCEEDED(client->GetService(__uuidof(IAudioRenderClient), reinterpret_cast<void**>(render.out()))) && SUCCEEDED(client->Start())) {
      opened();
      for (;;) {
        HANDLE any[] = {stop_, moved_, ready};
        const DWORD which = WaitForMultipleObjects(3, any, FALSE, 2000);
        if (which != WAIT_OBJECT_0 + 2) {
          // Told to end or move on; or Windows has said nothing for two seconds, and it is opened again.
          break;
        }
        UINT32 waiting = 0;
        if (FAILED(client->GetCurrentPadding(&waiting))) break;
        const UINT32 frames = room - waiting;
        if (frames == 0) continue;
        BYTE* data = nullptr;
        if (FAILED(render->GetBuffer(frames, &data))) break;
        ring.Read(reinterpret_cast<int16_t*>(data), frames);
        if (FAILED(render->ReleaseBuffer(frames, 0))) break;
      }
      client->Stop();
    }
    CloseHandle(ready);
  }

  HANDLE stop_, moved_;
  std::mutex lock_;
  std::wstring device_;
  std::thread thread_;
};

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::shared_ptr<Player> g_player;
// The app's thread alone: false once the window closes.
bool g_open = false;

// Let go of on a thread of its own: closing waits for the device.
void LetGo(std::shared_ptr<Player> player) {
  if (player) std::thread([player]() mutable { player.reset(); }).detach();
}

std::wstring DeviceOf(const EncodableMap* args) {
  if (!args) return std::wstring();
  auto it = args->find(EncodableValue("device"));
  const auto* s = it == args->end() ? nullptr : std::get_if<std::string>(&it->second);
  return s ? Wide(*s) : std::wstring();
}

void Handle(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> given) {
  Result result(std::move(given));
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "way") {
    const std::wstring device = DeviceOf(args);
    std::thread([result, device] {
      const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      const EncodableMap way = Way(device);
      if (SUCCEEDED(com)) CoUninitialize();
      RunOnMain([result, way] {
        if (g_open) result->Success(EncodableValue(way));
      });
    }).detach();
  } else if (method == "open") {
    LetGo(std::move(g_player));
    g_player = std::make_shared<Player>();
    std::weak_ptr<Player> weak = g_player;
    g_player->Open(DeviceOf(args), [result, weak](bool ok) {
      RunOnMain([result, weak, ok] {
        if (!g_open) return;
        if (!ok && g_player && g_player == weak.lock()) LetGo(std::move(g_player));
        result->Success(EncodableValue(ok));
      });
    });
  } else if (method == "write") {
    const auto* pcm = std::get_if<std::vector<uint8_t>>(call.arguments());
    if (!pcm || !g_player) {
      result->Success();
      return;
    }
    const MusicRing::Now now = g_player->ring.Write(pcm->data(), pcm->size());
    result->Success(EncodableValue(EncodableList{EncodableValue(static_cast<int32_t>(now.waiting)), EncodableValue(now.dry)}));
  } else if (method == "set") {
    double volume = 1;
    bool silent = false;
    if (args) {
      auto v = args->find(EncodableValue("volume"));
      if (v != args->end()) {
        if (const auto* d = std::get_if<double>(&v->second)) volume = *d;
      }
      auto s = args->find(EncodableValue("silent"));
      if (s != args->end()) {
        if (const auto* b = std::get_if<bool>(&s->second)) silent = *b;
      }
    }
    if (g_player) g_player->ring.Set(silent ? 0.0f : static_cast<float>(volume));
    result->Success();
  } else if (method == "output") {
    if (g_player) g_player->To(DeviceOf(args));
    result->Success();
  } else if (method == "clear") {
    if (g_player) g_player->ring.Clear();
    result->Success();
  } else if (method == "close") {
    LetGo(std::move(g_player));
    g_player = nullptr;
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterMusicSink(flutter::BinaryMessenger* messenger) {
  MainThreadInit();
  g_open = true;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "ghost/music", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(Handle);
}

void ShutdownMusicSink() {
  if (!g_open) return;
  g_open = false;
  if (g_player) g_player->Close();
  g_player = nullptr;
  if (g_channel) g_channel->SetMethodCallHandler(nullptr);
  g_channel = nullptr;
}
