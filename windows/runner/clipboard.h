// A picture on the clipboard, on Windows (clipboard.cpp).
#ifndef RUNNER_CLIPBOARD_H_
#define RUNNER_CLIPBOARD_H_

#include <flutter/binary_messenger.h>

// Answers lib/desktop/platform.dart's "pasteImage" on "ghost_desktop/system".
void RegisterClipboard(flutter::BinaryMessenger* messenger);

#endif
