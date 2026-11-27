/* A circle's music packed without loss (lib/voice/spotify_lossless.dart; Matt, 2026-11-25: "the audio doesn't sound high
 * quality for the other user they said it sounds compressed I'd like it to stream lossless audio"): 48 kHz stereo 16-bit
 * made FLAC frames of their own, each of which stands by itself, so one that is lost takes nothing with it. Only what is
 * quick and small of FLAC is used: its fixed predictors, Rice coding, and the four ways two channels may be told, which
 * any FLAC decoder takes (the Mac's own does: tool/spotify/check.sh). The other end is lib/voice/flac.dart. */
#ifndef MUSIC_PACK_H
#define MUSIC_PACK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The frames in a chunk: 40 ms. And the most there may be in one, and the bytes the most takes packed. */
#define MUSIC_PACK_FRAMES 1920
#define MUSIC_PACK_MOST 4096
#define MUSIC_PACK_ROOM (MUSIC_PACK_MOST * 4 + 64)

/* Before a chunk's payload: version, flags, count (16 bits), running frame number (48 bits), length (16 bits), each low
 * byte first. The number is of the chunk's first frame since the DJ's sound began, gaps counted. */
#define MUSIC_CHUNK_HEAD 12
#define MUSIC_CHUNK_VERSION 1
/* Flags: the payload is a FLAC frame; without it, plain 16-bit samples. Anything else is refused by who receives it. */
#define MUSIC_CHUNK_FLAC 1
#define MUSIC_CHUNK_ROOM (MUSIC_CHUNK_HEAD + MUSIC_PACK_ROOM)

/* Packs [frames] (16 to MUSIC_PACK_MOST) of interleaved stereo as one FLAC frame, numbered [number]: how many bytes of
 * [out], which has MUSIC_PACK_ROOM of them, or 0 where it can't be. Never more than the samples themselves and a few
 * bytes. It allocates nothing and keeps nothing between calls. */
int music_pack(const int16_t *lr, int frames, uint32_t number, uint8_t *out);

/* Makes a whole chunk of [frames] from the running number [at]: how many bytes of [out], which has MUSIC_CHUNK_ROOM. */
int music_chunk(const int16_t *lr, int frames, uint64_t at, uint8_t *out);

#ifdef __cplusplus
}
#endif

#endif
