// Where the Windows app starts: Flutter's stock runner, with a circle's invite link handed to a copy already running,
// the ghostmsg: scheme registered, and the window's name and size (which splash.cpp gives back after the splash).
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "links.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // A circle's invite link (links.cpp): handed to the copy already running, if one is, and this one goes.
  std::wstring link = LinkInCommandLine();
  if (!link.empty() && HandToRunningCopy(link)) {
    return EXIT_SUCCESS;
  }
  // One window of the app on a computer (GMFB-47, "Two windows one voice call"): two copies started from one folder are
  // one device to the relay and take each other's place on it every few seconds, in a call and out of it. A second
  // start shows the window already open and goes. The mutex is this Windows user's, held until this copy ends, and is
  // there before the window is, so two starts at once still make one window. Not where GHOST_DESK_DIR gives a copy a
  // folder of its own (lib/desktop/main.dart): that one is another install, and runs beside this. And a copy the app
  // opened itself to start afresh (GHOST_DESK_AGAIN, lib/desktop/desk.dart restartApp) takes the mutex and stays: the
  // copy that opened it is closing, and its window is not one to show.
  if (::GetEnvironmentVariableW(L"GHOST_DESK_DIR", nullptr, 0) == 0) {
    HANDLE only = ::CreateMutexW(nullptr, FALSE, L"Local\\st.gogho.GhostMessaging.OneWindow");
    const bool running = only != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
    const bool again = ::GetEnvironmentVariableW(L"GHOST_DESK_AGAIN", nullptr, 0) != 0;
    if (running && !again && ShowRunningCopy()) {
      ::CloseHandle(only);
      return EXIT_SUCCESS;
    }
  }
  RegisterLinkScheme();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, link);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1100, 740);
  if (!window.Create(L"Uplink", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
