// Speech written out, on Windows (speech.cpp): a call's live captions and Scribe's transcripts.
#ifndef RUNNER_SPEECH_H_
#define RUNNER_SPEECH_H_

#include <flutter/binary_messenger.h>

// Answers lib/voice/captions.dart on "ghost/captions" and lib/voice/scribe.dart on "ghost/scribe".
void RegisterSpeech(flutter::BinaryMessenger* messenger);

#endif
