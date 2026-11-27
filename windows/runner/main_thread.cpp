// Work handed back to the app's own thread (main_thread.h): a window that shows nothing takes a message for each
// piece of work, and the app's message loop runs it.
#include "main_thread.h"

namespace {

// The message that carries one piece of work (its lparam points to it), and the window it is posted to.
constexpr UINT kRun = WM_APP + 0x47;
HWND g_window = nullptr;

// Runs the work a kRun message carries, and frees it.
LRESULT CALLBACK Proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kRun) {
    auto* work = reinterpret_cast<std::function<void()>*>(lparam);
    (*work)();
    delete work;
    return 0;
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

// A message-only window (never shown, no size) of a class of its own, on the calling thread.
HWND Make(const wchar_t* name, WNDPROC proc) {
  WNDCLASSW wc = {};
  wc.lpfnWndProc = proc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = name;
  RegisterClassW(&wc);
  return CreateWindowExW(0, name, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr);
}

}  // namespace

void MainThreadInit() {
  if (!g_window) g_window = Make(L"GhostMainThread", Proc);
}

void RunOnMain(std::function<void()> work) {
  if (!g_window) return;
  // The work is the window procedure's to free once it has run; freed here where the message could not be posted.
  auto* held = new std::function<void()>(std::move(work));
  if (!PostMessage(g_window, kRun, 0, reinterpret_cast<LPARAM>(held))) delete held;
}

HWND MainThreadWindow(WNDPROC handler) {
  // Each window has a class of its own, numbered, since a class holds one handler.
  static int made = 0;
  wchar_t name[64];
  wsprintfW(name, L"GhostMainThread%d", ++made);
  return Make(name, handler);
}
