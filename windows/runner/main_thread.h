// Work handed back to the app's own thread, on Windows: Flutter's channels are spoken on it alone, and a recording's
// encoding, a transcript and speech heard all finish on threads of their own (call_recorder.cpp, speech.cpp).
#ifndef RUNNER_MAIN_THREAD_H_
#define RUNNER_MAIN_THREAD_H_

#include <windows.h>

#include <functional>

// Made once, on the app's thread, before anything below is used.
void MainThreadInit();

// Runs [work] on the app's thread, soon: from any thread.
void RunOnMain(std::function<void()> work);

// A window of no size on the app's thread whose messages come to [handler]: for SAPI's word that it has heard
// something (speech.cpp). Null where it could not be made.
HWND MainThreadWindow(WNDPROC handler);

#endif
