// Circles' invite links opened into the app on Windows (links.cpp).
#ifndef RUNNER_LINKS_H_
#define RUNNER_LINKS_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <string>

// The ghostmsg: link this copy was started with, or empty.
std::wstring LinkInCommandLine();

// Hands [link] to a copy of the app already running and says true; false where none is.
bool HandToRunningCopy(const std::wstring& link);

// Brings the window of a copy of the app already running to the front, for a second start with no link (GMFB-47);
// false where no window of one is found.
bool ShowRunningCopy();

// Makes ghostmsg: links open this app, for this Windows user (no administrator needed).
void RegisterLinkScheme();

// Answers lib/desktop/links.dart on "ghost_desktop/links", with [first] waiting where the app was started with one.
void RegisterLinks(flutter::BinaryMessenger* messenger, const std::wstring& first);

// A WM_COPYDATA from another copy: the link it was started with. True where it was one.
bool LinkCopied(HWND window, LPARAM lparam);

#endif
