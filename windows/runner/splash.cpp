// The launch splash on Windows (lib/desktop/ui/launch_splash.dart; Matt, 2026-11-20: "add a checking for updates splash
// window that shows before the app launches and load the app on this screen too similar to how discord does on
// launch"): the window starts small and centred, with no resize edge or maximise button, while the app looks for an
// update and loads; "splash" false gives it the size main.cpp asked for, centred on the same screen.
#include "splash.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace {

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
HWND g_window = nullptr;
// The window's style from before the splash took its resize edge and maximise button.
LONG_PTR g_style = 0;
// Whether the window is small now (the splash, or signing in), so Leave() has something to undo.
bool g_splash = false;

// The window's own size, in 96-DPI pixels, as main.cpp makes it.
constexpr int kFullWidth = 1100;
constexpr int kFullHeight = 740;
constexpr int kSplashWidth = 300;
constexpr int kSplashHeight = 340;
constexpr int kCompactWidth = 480;
constexpr int kCompactHeight = 720;

// Sizes the window to [width] by [height] (96-DPI pixels, scaled to its screen) in the middle of that screen's
// work area, and no larger than it.
void Centre(HWND window, int width, int height) {
  const UINT dpi = GetDpiForWindow(window);
  const int w = MulDiv(width, dpi, 96), h = MulDiv(height, dpi, 96);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &info);
  const RECT& work = info.rcWork;
  const int cw = (w < work.right - work.left) ? w : work.right - work.left;
  const int ch = (h < work.bottom - work.top) ? h : work.bottom - work.top;
  const int x = work.left + ((work.right - work.left) - cw) / 2;
  const int y = work.top + ((work.bottom - work.top) - ch) / 2;
  SetWindowPos(window, nullptr, x, y, cw, ch, SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

// The splash's edges back: only the resize edge and maximise button it took away, added to the window's style as it is
// now. The style kept at RegisterSplash is from before the window was shown, without WS_VISIBLE: put back whole, it
// hid the window as the app loaded (the release check's "the app is running with no window", 0.10.0).
void Leave() {
  if (!g_splash || g_window == nullptr) return;
  g_splash = false;
  const LONG_PTR now = GetWindowLongPtr(g_window, GWL_STYLE);
  SetWindowLongPtr(g_window, GWL_STYLE, now | (g_style & (WS_THICKFRAME | WS_MAXIMIZEBOX)));
  Centre(g_window, kFullWidth, kFullHeight);
}

// Signing up or in: smaller than the app and not resizable, its minimise and close buttons kept. Leave() gives the
// window its own size back, as after the splash.
void Compact() {
  if (g_window == nullptr) return;
  const LONG_PTR now = GetWindowLongPtr(g_window, GWL_STYLE);
  SetWindowLongPtr(g_window, GWL_STYLE, now & ~(WS_THICKFRAME | WS_MAXIMIZEBOX));
  g_splash = true;
  Centre(g_window, kCompactWidth, kCompactHeight);
}

// The window as it was before it was made the call's mini window (lib/desktop/mini_window.dart, GMFB-41: "An
// always-on-top call overlay for games on desktop"): where it was and how (maximised or not), and its style.
WINDOWPLACEMENT g_mini_place{};
LONG_PTR g_mini_style = 0;
bool g_mini = false;

// The call's mini window: a client area [width] by [height] (96-DPI pixels, scaled to its screen) in the work area's
// top right corner, above every other window that is not itself topmost, with no maximise button; its title bar still
// moves it. False while the splash or the sign-in's small window is up.
bool EnterMini(int width, int height) {
  if (g_window == nullptr) return false;
  if (g_mini) return true;
  if (g_splash) return false;
  g_mini_place.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(g_window, &g_mini_place)) return false;
  g_mini_style = GetWindowLongPtr(g_window, GWL_STYLE);
  if (IsZoomed(g_window) || IsIconic(g_window)) ShowWindow(g_window, SW_RESTORE);
  const LONG_PTR style = g_mini_style & ~WS_MAXIMIZEBOX;
  SetWindowLongPtr(g_window, GWL_STYLE, style);
  const UINT dpi = GetDpiForWindow(g_window);
  RECT outer{0, 0, MulDiv(width, dpi, 96), MulDiv(height, dpi, 96)};
  AdjustWindowRectExForDpi(&outer, static_cast<DWORD>(style), FALSE, static_cast<DWORD>(GetWindowLongPtr(g_window, GWL_EXSTYLE)), dpi);
  const int w = outer.right - outer.left, h = outer.bottom - outer.top;
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  GetMonitorInfo(MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST), &info);
  const RECT& work = info.rcWork;
  const int margin = MulDiv(16, dpi, 96);
  SetWindowPos(g_window, HWND_TOPMOST, work.right - w - margin, work.top + margin, w, h, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  g_mini = true;
  return true;
}

// The window as it was before the mini window: not topmost, its style, its place and size, maximised again if it was.
void LeaveMini() {
  if (!g_mini || g_window == nullptr) return;
  g_mini = false;
  SetWindowLongPtr(g_window, GWL_STYLE, g_mini_style);
  SetWindowPos(g_window, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  SetWindowPlacement(g_window, &g_mini_place);
}

// An int argument [name] of a call's map; [fallback] where it is not said.
int IntOf(const flutter::EncodableValue* args, const char* name, int fallback) {
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    auto it = map->find(flutter::EncodableValue(name));
    if (it != map->end()) {
      if (const auto* n = std::get_if<int32_t>(&it->second)) return *n;
      if (const auto* n = std::get_if<int64_t>(&it->second)) return static_cast<int>(*n);
    }
  }
  return fallback;
}

// Whether a call's map says `on` true.
bool OnOf(const flutter::EncodableValue* args) {
  if (const auto* map = std::get_if<flutter::EncodableMap>(args)) {
    auto it = map->find(flutter::EncodableValue("on"));
    if (it != map->end()) {
      if (const auto* b = std::get_if<bool>(&it->second)) return *b;
    }
  }
  return false;
}

}  // namespace

// Makes the window the splash at once, before it is shown, and answers "ghost_desktop/window": `splash`, `compact` and
// `mini`.
void RegisterSplash(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_style = GetWindowLongPtr(window, GWL_STYLE);
  SetWindowLongPtr(window, GWL_STYLE, g_style & ~(WS_THICKFRAME | WS_MAXIMIZEBOX));
  g_splash = true;
  Centre(window, kSplashWidth, kSplashHeight);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "ghost_desktop/window", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "splash") {
      const auto* on = std::get_if<bool>(call.arguments());
      if (on != nullptr && !*on) Leave();
      result->Success();
    } else if (call.method_name() == "compact") {
      // Signing up or in: a small window of its own (Matt, 2026-11-20: "make the sign up / sign in window smaller").
      const auto* on = std::get_if<bool>(call.arguments());
      if (on != nullptr && *on) {
        Compact();
      } else {
        Leave();
      }
      result->Success();
    } else if (call.method_name() == "mini") {
      // The call's mini window (lib/desktop/mini_window.dart): `on` with its size, or the window as it was.
      if (OnOf(call.arguments())) {
        result->Success(flutter::EncodableValue(EnterMini(IntOf(call.arguments(), "width", 340), IntOf(call.arguments(), "height", 236))));
      } else {
        LeaveMini();
        result->Success(flutter::EncodableValue(true));
      }
    } else {
      result->NotImplemented();
    }
  });
}
