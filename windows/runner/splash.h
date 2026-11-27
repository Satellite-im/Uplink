// The launch splash's window, on Windows (splash.cpp).
#ifndef RUNNER_SPLASH_H_
#define RUNNER_SPLASH_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// Makes [window] the splash's: small, centred, not resizable. Then answers "splash" false on
// "ghost_desktop/window" (lib/desktop/ui/launch_splash.dart) by giving it its own size back.
void RegisterSplash(flutter::BinaryMessenger* messenger, HWND window);

#endif
