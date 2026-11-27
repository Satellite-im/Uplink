// The microphone's processing in calls, on Windows (voice_fx.cpp).
#ifndef RUNNER_VOICE_FX_H_
#define RUNNER_VOICE_FX_H_

#include <flutter/binary_messenger.h>

// Answers lib/voice/voice_fx.dart on "ghost/voicefx".
void RegisterVoiceFx(flutter::BinaryMessenger* messenger);

#endif
