// Whether Windows lowers other sounds while the app is in a call (ducking.cpp).
#ifndef RUNNER_DUCKING_H_
#define RUNNER_DUCKING_H_

#include <flutter/binary_messenger.h>

// Answers lib/voice/ducking.dart's "set" on "ghost/ducking".
void RegisterDucking(flutter::BinaryMessenger* messenger);

#endif
