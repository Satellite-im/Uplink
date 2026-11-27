// Spotify in a circle's calls, the PC's half (lib/voice/spotify_app.dart WindowsSpotify, WindowsMusic; Matt, 2026-11-25:
// "add a spotify plugin for circles that allows a user to add songs to a queue and play them from spotify" and "also make
// sure this works on windows"): the `ghost/spotify` channel.
//
// - A song is played by opening its own address, `spotify:track:` and a track's id of 22 letters and digits, which is all
//   that is ever opened. Spotify may only show it: lib/voice/spotify_deck.dart sees to that.
// - Pause, go on, seek, and what is playing are Windows' media controls (GlobalSystemMediaTransportControls), of the
//   session that is Spotify's. No other player's is read or pressed.
// - Its sound is spotify_sound.cpp's.
//
// What waits (Windows' media controls, the opening of an address) runs on threads of its own, each with its own COM, and
// what came of it is answered on the app's thread (main_thread.h), where Flutter's channels are spoken.
#include "spotify.h"

#include "main_thread.h"
#include "spotify_sound.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlwapi.h>

#pragma warning(push, 0)
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
#pragma warning(pop)

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

namespace media = winrt::Windows::Media::Control;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = std::shared_ptr<flutter::MethodResult<EncodableValue>>;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;
std::unique_ptr<SpotifySound> g_sound;

// The app's thread alone: false once the window closes, and nothing is answered after.
bool g_open = false;

// Chunks of the music without loss on their way to the app's thread.
std::atomic<int> g_chunks{0};

// What a thread of its own came to, answered on the app's thread.
void Answer(Result result, std::function<void(flutter::MethodResult<EncodableValue>&)> say) {
  RunOnMain([result, say] {
    if (g_open) say(*result);
  });
}

void Succeed(Result result, EncodableValue value) {
  Answer(result, [value](flutter::MethodResult<EncodableValue>& r) { r.Success(value); });
}

void Refuse(Result result, std::string code) {
  Answer(result, [code](flutter::MethodResult<EncodableValue>& r) { r.Error(code, "Spotify"); });
}

// One thread and the work waiting for it, in turn. [com] is the kind of COM it has for as long as it lives.
class Worker {
 public:
  explicit Worker(DWORD com) : com_(com) {}

  void Do(std::function<void()> work) {
    std::lock_guard<std::mutex> hold(lock_);
    if (ended_) return;
    waiting_.push_back(std::move(work));
    if (!thread_.joinable()) thread_ = std::thread([this] { Run(); });
    more_.notify_one();
  }

  // Ends it once what it is at is done; what still waits is let go of.
  void End() {
    {
      std::lock_guard<std::mutex> hold(lock_);
      ended_ = true;
      waiting_.clear();
      more_.notify_one();
    }
    if (thread_.joinable()) thread_.join();
  }

 private:
  void Run() {
    const HRESULT com = CoInitializeEx(nullptr, com_);
    for (;;) {
      std::function<void()> work;
      {
        std::unique_lock<std::mutex> hold(lock_);
        more_.wait(hold, [this] { return ended_ || !waiting_.empty(); });
        if (ended_) break;
        work = std::move(waiting_.front());
        waiting_.pop_front();
      }
      work();
    }
    if (SUCCEEDED(com)) CoUninitialize();
  }

  const DWORD com_;
  std::mutex lock_;
  std::condition_variable more_;
  std::deque<std::function<void()>> waiting_;
  bool ended_ = false;
  std::thread thread_;
};

// Windows' media controls wait for their answers, which a thread with a window of its own may not: multithreaded.
// Opening an address goes through the shell, which is for the other kind.
std::unique_ptr<Worker> g_media;
std::unique_ptr<Worker> g_shell;

// How long Windows or Spotify may take over one thing asked of the media controls.
constexpr auto kPatience = std::chrono::seconds(4);

// Set as the window closes, so that nothing waited for holds it open.
std::atomic<bool> g_ending{false};

// An answer waited for, and no longer than [kPatience]. Throws where it came to nothing.
template <typename Async>
auto Wait(Async const& asked) {
  using winrt::Windows::Foundation::AsyncStatus;
  const auto until = std::chrono::steady_clock::now() + kPatience;
  AsyncStatus how = AsyncStatus::Started;
  while (how == AsyncStatus::Started && !g_ending && std::chrono::steady_clock::now() < until) {
    how = asked.wait_for(std::chrono::milliseconds(100));
  }
  if (how != AsyncStatus::Completed) {
    asked.Cancel();
    throw winrt::hresult_error(HRESULT_FROM_WIN32(ERROR_TIMEOUT));
  }
  return asked.GetResults();
}

// Whether Windows' name for an app is Spotify's: the desktop app's or the Microsoft Store's (lib/voice/spotify_app.dart
// isSpotifyAppId looks at it again).
bool IsSpotifyApp(winrt::hstring const& id) {
  std::wstring s(id);
  std::transform(s.begin(), s.end(), s.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  if (s == L"spotify.exe") return true;
  const std::wstring head = L"spotifyab.spotifymusic_", tail = L"!spotify";
  return s.size() > head.size() + tail.size() && s.compare(0, head.size(), head) == 0 && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}

// Spotify's media session, where it has one: it has once it has played something.
media::GlobalSystemMediaTransportControlsSession Session() {
  const auto manager = Wait(media::GlobalSystemMediaTransportControlsSessionManager::RequestAsync());
  for (auto const& one : manager.GetSessions()) {
    if (IsSpotifyApp(one.SourceAppUserModelId())) return one;
  }
  return nullptr;
}

int64_t Milliseconds(winrt::Windows::Foundation::TimeSpan const& t) { return std::chrono::duration_cast<std::chrono::milliseconds>(t).count(); }

// What Spotify's session says: a list of one, or of none.
EncodableList Now() {
  EncodableList out;
  const auto session = Session();
  if (!session) return out;
  EncodableMap m;
  m[EncodableValue("app")] = EncodableValue(winrt::to_string(session.SourceAppUserModelId()));
  using Status = media::GlobalSystemMediaTransportControlsSessionPlaybackStatus;
  const auto playback = session.GetPlaybackInfo();
  const auto status = playback ? playback.PlaybackStatus() : Status::Closed;
  const bool playing = status == Status::Playing;
  m[EncodableValue("state")] = EncodableValue(playing ? "playing" : status == Status::Paused ? "paused" : "stopped");
  const auto said = Wait(session.TryGetMediaPropertiesAsync());
  if (said) {
    m[EncodableValue("name")] = EncodableValue(winrt::to_string(said.Title()));
    m[EncodableValue("artist")] = EncodableValue(winrt::to_string(said.Artist()));
  }
  const auto line = session.GetTimelineProperties();
  if (line) {
    const int64_t length = Milliseconds(line.EndTime() - line.StartTime());
    int64_t position = Milliseconds(line.Position() - line.StartTime());
    // Where it was when Spotify last said, and on by the clock since then while it plays.
    if (playing && length > 0 && line.LastUpdatedTime().time_since_epoch().count() > 0) {
      const int64_t since = Milliseconds(winrt::clock::now() - line.LastUpdatedTime());
      if (since > 0) position += since;
      position = (std::min)(position, length);
    }
    m[EncodableValue("length")] = EncodableValue(length > 0 ? length : int64_t{0});
    m[EncodableValue("position")] = EncodableValue(length > 0 && position > 0 ? position : int64_t{0});
  }
  out.push_back(EncodableValue(m));
  return out;
}

bool Running() {
  HANDLE process = OpenSpotify(nullptr);
  if (!process) return false;
  CloseHandle(process);
  return true;
}

// Something of Windows' media controls, on their thread: [work] answers, and what it throws is refused.
void Media(Result result, std::function<EncodableValue()> work) {
  g_media->Do([result, work] {
    if (!Running()) return Refuse(result, "closed");
    try {
      Succeed(result, work());
    } catch (winrt::hresult_error const& e) {
      Refuse(result, e.code() == E_ACCESSDENIED ? "denied" : "failed");
    } catch (...) {
      Refuse(result, "failed");
    }
  });
}

// A button of Spotify's session; "failed" where there is no session or it would not.
void Press(Result result, std::function<winrt::Windows::Foundation::IAsyncOperation<bool>(media::GlobalSystemMediaTransportControlsSession const&)> button) {
  Media(result, [button]() -> EncodableValue {
    const auto session = Session();
    if (!session || !Wait(button(session))) throw winrt::hresult_error(E_FAIL);
    return EncodableValue();
  });
}

// A track's id: 22 letters and digits, and nothing else.
bool IsTrack(const std::string& id) {
  return id.size() == 22 && std::all_of(id.begin(), id.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); });
}

// Opens the track [id] in Spotify, which is running: shown there, and played where Spotify does.
void Open(Result result, const std::string& id) {
  // Letters and digits only, so each is one wide character.
  const std::wstring address = L"spotify:track:" + std::wstring(id.begin(), id.end());
  g_shell->Do([result, address] {
    if (!Running()) return Refuse(result, "closed");
    SHELLEXECUTEINFOW what = {};
    what.cbSize = sizeof(what);
    // Done before it comes back, with no box of Windows' own where nothing opens it.
    what.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    what.lpVerb = L"open";
    what.lpFile = address.c_str();
    what.nShow = SW_SHOWNOACTIVATE;
    if (!ShellExecuteExW(&what)) return Refuse(result, "failed");
    Succeed(result, EncodableValue());
  });
}

bool Installed() {
  wchar_t name[260];
  DWORD n = 260;
  return SUCCEEDED(AssocQueryStringW(ASSOCF_IS_PROTOCOL | ASSOCF_NOTRUNCATE, ASSOCSTR_FRIENDLYAPPNAME, L"spotify", nullptr, name, &n));
}

const EncodableValue* Arg(const EncodableMap* args, const char* name) {
  if (!args) return nullptr;
  auto it = args->find(EncodableValue(name));
  return it == args->end() ? nullptr : &it->second;
}

bool Flag(const EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  const auto* b = v ? std::get_if<bool>(v) : nullptr;
  return b && *b;
}

int64_t Number(const EncodableMap* args, const char* name) {
  const auto* v = Arg(args, name);
  if (!v) return 0;
  if (const auto* i = std::get_if<int32_t>(v)) return *i;
  if (const auto* l = std::get_if<int64_t>(v)) return *l;
  return 0;
}

void Handle(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> given) {
  Result result(std::move(given));
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "able") {
    g_shell->Do([result] {
      const bool running = Running();
      EncodableMap m;
      m[EncodableValue("system")] = EncodableValue(CanHearOneProgram());
      m[EncodableValue("running")] = EncodableValue(running);
      m[EncodableValue("installed")] = EncodableValue(running || Installed());
      Succeed(result, EncodableValue(m));
    });
  } else if (method == "now") {
    Media(result, [] { return EncodableValue(Now()); });
  } else if (method == "play") {
    const auto* v = Arg(args, "id");
    const auto* id = v ? std::get_if<std::string>(v) : nullptr;
    if (!id || !IsTrack(*id)) {
      result->Error("song", "not a track");
      return;
    }
    Open(result, *id);
  } else if (method == "pause") {
    Press(result, [](auto const& s) { return s.TryPauseAsync(); });
  } else if (method == "resume") {
    Press(result, [](auto const& s) { return s.TryPlayAsync(); });
  } else if (method == "seek") {
    // In hundreds of nanoseconds, as Windows has it.
    const int64_t to = (std::max)(int64_t{0}, Number(args, "ms")) * 10000;
    Press(result, [to](auto const& s) { return s.TryChangePlaybackPositionAsync(to); });
  } else if (method == "begin") {
    if (!CanHearOneProgram()) {
      result->Error("system", "Windows 10 version 2004");
      return;
    }
    if (!g_sound) {
      g_sound = std::make_unique<SpotifySound>([] {
        RunOnMain([] {
          if (g_open && g_channel) g_channel->InvokeMethod("quit", nullptr);
        });
      }, [](std::vector<uint8_t> chunk) {
        // A second of them waiting on an app that does not look is as many as are kept: the rest are let go of, and their
        // numbers say so.
        if (g_chunks >= 25) return;
        g_chunks++;
        RunOnMain([chunk = std::move(chunk)] {
          g_chunks--;
          if (g_open && g_channel) g_channel->InvokeMethod("chunk", std::make_unique<EncodableValue>(chunk));
        });
      });
    }
    const std::string id = g_sound->Begin(Flag(args, "echo"), Flag(args, "noise"), Flag(args, "gain"));
    if (id.empty()) {
      g_sound = nullptr;
      result->Error("sound", "no track");
      return;
    }
    result->Success(EncodableValue(id));
  } else if (method == "end") {
    g_sound = nullptr;
    result->Success();
  } else if (method == "pack") {
    if (g_sound) g_sound->Pack(Flag(args, "on"));
    result->Success();
  } else if (method == "rate") {
    g_shell->Do([result] { Succeed(result, EncodableValue(SpeakerRate())); });
  } else if (method == "level") {
    result->Success(EncodableValue(static_cast<double>(g_sound ? g_sound->Level() : 0.0f)));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void RegisterSpotify(flutter::BinaryMessenger* messenger) {
  MainThreadInit();
  g_open = true;
  // Each thread is made only once something is asked of it.
  g_media = std::make_unique<Worker>(COINIT_MULTITHREADED);
  g_shell = std::make_unique<Worker>(COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "ghost/spotify", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(Handle);
}

void ShutdownSpotify() {
  if (!g_open) return;
  g_open = false;
  g_ending = true;
  g_sound = nullptr;
  if (g_media) g_media->End();
  if (g_shell) g_shell->End();
  if (g_channel) g_channel->SetMethodCallHandler(nullptr);
  g_channel = nullptr;
}
