// Spotify in a circle's calls, the PC's half: the `ghost/spotify` channel (spotify.cpp).
#ifndef RUNNER_SPOTIFY_H_
#define RUNNER_SPOTIFY_H_

#include <flutter/binary_messenger.h>

void RegisterSpotify(flutter::BinaryMessenger* messenger);

// As the window closes, before the engine goes: no thread and no track of it is left, and nothing more is answered.
void ShutdownSpotify();

#endif
