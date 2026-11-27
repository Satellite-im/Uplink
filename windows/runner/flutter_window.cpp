// The Windows app's one window: Flutter's stock runner window, which also sets up each of the app's own channels as
// it is made and takes the link another copy hands over.
#include "flutter_window.h"

#include "voice_fx.h"
#include "call_recorder.h"
#include "speech.h"
#include "sounds.h"
#include "clipboard.h"
#include "ducking.h"
#include "links.h"
#include "splash.h"
#include "music_sink.h"
#include "spotify.h"

#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project, std::wstring link)
    : project_(project), link_(std::move(link)) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // The microphone's processing in calls (voice_fx.cpp), after flutter_webrtc is registered.
  RegisterVoiceFx(flutter_controller_->engine()->messenger());
  // Spotify played to a circle's call (spotify.cpp).
  RegisterSpotify(flutter_controller_->engine()->messenger());
  // And its music played here without loss (music_sink.cpp).
  RegisterMusicSink(flutter_controller_->engine()->messenger());
  // Recording a call (call_recorder.cpp), and live captions and Scribe (speech.cpp).
  RegisterCallRecorder(flutter_controller_->engine()->messenger());
  RegisterSpeech(flutter_controller_->engine()->messenger());
  // The interface sounds (sounds.cpp).
  RegisterSounds(flutter_controller_->engine()->messenger());
  // Other sounds left as loud as they are in a call, unless chosen otherwise (ducking.cpp).
  RegisterDucking(flutter_controller_->engine()->messenger());
  // A picture on the clipboard, for the message field (clipboard.cpp).
  RegisterClipboard(flutter_controller_->engine()->messenger());
  // Circles' invite links opened into the app (links.cpp).
  RegisterLinks(flutter_controller_->engine()->messenger(), link_);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // The launch splash first: small and centred until the app says it is ready (splash.cpp).
  RegisterSplash(flutter_controller_->engine()->messenger(), GetHandle());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Its threads and its track go before the engine does.
  ShutdownSpotify();
  ShutdownMusicSink();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA:
      // Another copy, started by a circle's link, handing it over (links.cpp).
      if (LinkCopied(hwnd, lparam)) return 1;
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
