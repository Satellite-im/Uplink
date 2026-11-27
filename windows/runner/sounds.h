// The app's interface sounds, on Windows (sounds.cpp).
#ifndef RUNNER_SOUNDS_H_
#define RUNNER_SOUNDS_H_

#include <flutter/binary_messenger.h>

// Answers lib/sounds.dart on "ghost/sound".
void RegisterSounds(flutter::BinaryMessenger* messenger);

#endif
