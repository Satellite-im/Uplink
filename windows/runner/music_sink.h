// A player of this PC's own for a circle's music sent without loss (lib/voice/music_sink.dart).
#ifndef RUNNER_MUSIC_SINK_H_
#define RUNNER_MUSIC_SINK_H_

#include <flutter/binary_messenger.h>

void RegisterMusicSink(flutter::BinaryMessenger* messenger);
// Ends its thread as the window closes.
void ShutdownMusicSink();

#endif
