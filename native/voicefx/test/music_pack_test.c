/* Packs sounds of every kind and reads them back bit for bit; writes a FLAC file of them for another decoder to read
 * (test/run_pack.sh has the Mac's own do it), and the chunks test/flac_test.dart reads. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "music_pack.h"
#include "music_unpack.h"

static uint32_t seed = 7;
static int32_t noise(int32_t most) {
  seed = seed * 1664525u + 1013904223u;
  return (int32_t)((seed >> 8) % (uint32_t)(2 * most + 1)) - most;
}

static const char *const kinds[] = {"silence", "a constant", "noise", "full scale square", "tone", "two tones", "music-like", "one side alone", "opposite sides", "all extremes", "quiet dither", "an impulse", "sides far apart"};
#define KINDS 13

static void make(int kind, int16_t *lr, int n, long from) {
  for (int i = 0; i < n; i++) {
    const double t = (double)(from + i) / 48000.0;
    double l = 0, r = 0;
    switch (kind) {
      case 0: break;
      case 1: l = 123; r = -32768; break;
      case 2: l = noise(32767); r = noise(32767); break;
      case 3: l = r = ((from + i) / 50) % 2 ? 32767 : -32768; break;
      case 4: l = r = 12000 * sin(6.2831853 * 440 * t); break;
      case 5: l = 8000 * sin(6.2831853 * 440 * t); r = 8000 * sin(6.2831853 * 1000 * t); break;
      case 6: l = 6000 * sin(6.2831853 * 220 * t) + 3000 * sin(6.2831853 * 1330 * t) + noise(400); r = l * 0.8 + 900 * sin(6.2831853 * 3000 * t) + noise(300); break;
      case 7: l = noise(9000); break;
      case 8: l = noise(32767); r = -l; break;
      case 9: l = noise(1) > 0 ? 32767 : -32768; r = noise(1) > 0 ? 32767 : -32768; break;
      case 10: l = noise(1); r = noise(1); break;
      case 11: l = i == n / 2 ? 32767 : 0; r = i == n / 2 ? -32768 : 0; break;
      default: l = 32767 - abs(noise(3)); r = -32768 + abs(noise(3)); break;
    }
    lr[i * 2] = (int16_t)(l > 32767 ? 32767 : l < -32768 ? -32768 : l);
    lr[i * 2 + 1] = (int16_t)(r > 32767 ? 32767 : r < -32768 ? -32768 : r);
  }
}

int main(int argc, char **argv) {
  static int16_t lr[MUSIC_PACK_MOST * 2], back[MUSIC_PACK_MOST * 2];
  static uint8_t out[MUSIC_CHUNK_ROOM + 64];
  const int counts[] = {16, 17, 160, 480, 961, 1920, 4096};
  int wrong = 0;
  for (int k = 0; k < KINDS; k++) {
    for (int c = 0; c < 7; c++) {
      make(k, lr, counts[c], 0);
      memset(out, 0xee, sizeof(out));
      const int n = music_pack(lr, counts[c], (uint32_t)(k * 999983 + c * 77), out);
      const int got = n > 0 && n <= MUSIC_PACK_ROOM ? music_unpack(out, n, back, MUSIC_PACK_MOST) : -99;
      if (got != counts[c] || memcmp(lr, back, (size_t)counts[c] * 4) || out[MUSIC_PACK_ROOM] != 0xee) {
        printf("FAIL: %s, %d frames: %d\n", kinds[k], counts[c], got);
        wrong++;
      }
      if (n > counts[c] * 4 + 24) {
        printf("FAIL: %s, %d frames: %d bytes\n", kinds[k], counts[c], n);
        wrong++;
      }
      /* Any one byte changed is noticed. */
      for (int i = 0; i < n; i += n / 13 + 1) {
        out[i] ^= 0x10;
        if (music_unpack(out, n, back, MUSIC_PACK_MOST) == counts[c]) {
          printf("FAIL: %s, %d frames: byte %d changed and not noticed\n", kinds[k], counts[c], i);
          wrong++;
        }
        out[i] ^= 0x10;
      }
      if (c == 5) printf("%-18s %5d bytes of %d: %d kbit/s\n", kinds[k], n, counts[c] * 4, n * 8 / 40);
    }
  }
  /* And many random lengths and loudnesses. */
  for (int i = 0; i < 4000; i++) {
    const int n = 16 + abs(noise(1 << 20)) % (MUSIC_PACK_MOST - 15), loud = 1 << (abs(noise(1 << 20)) % 16);
    for (int j = 0; j < n * 2; j++) lr[j] = (int16_t)noise(loud > 32767 ? 32767 : loud);
    const int len = music_pack(lr, n, (uint32_t)i, out);
    if (music_unpack(out, len, back, MUSIC_PACK_MOST) != n || memcmp(lr, back, (size_t)n * 4)) {
      printf("FAIL: random %d, %d frames\n", i, n);
      wrong++;
    }
  }
  if (music_pack(lr, 15, 0, out) || music_pack(lr, MUSIC_PACK_MOST + 1, 0, out)) {
    printf("FAIL: a count it should not take\n");
    wrong++;
  }

  if (argc > 1) {
    /* A FLAC file of 13 kinds, ten chunks of each, and the same as plain samples. */
    char name[1024];
    snprintf(name, sizeof(name), "%s/pack.flac", argv[1]);
    FILE *f = fopen(name, "wb");
    snprintf(name, sizeof(name), "%s/pack.raw", argv[1]);
    FILE *raw = fopen(name, "wb");
    if (!f || !raw) return 2;
    const uint64_t total = (uint64_t)KINDS * 10 * MUSIC_PACK_FRAMES;
    uint8_t info[42] = {'f', 'L', 'a', 'C', 0x80, 0, 0, 34, MUSIC_PACK_FRAMES >> 8, MUSIC_PACK_FRAMES & 0xff, MUSIC_PACK_FRAMES >> 8, MUSIC_PACK_FRAMES & 0xff};
    /* 48000 in 20 bits, 2 channels, 16 bits, the total in 36. */
    info[18] = 48000 >> 12;
    info[19] = (48000 >> 4) & 0xff;
    info[20] = (uint8_t)(((48000 & 15) << 4) | (1 << 1) | 0);
    info[21] = (uint8_t)((15 << 4) | (total >> 32));
    for (int i = 0; i < 4; i++) info[22 + i] = (uint8_t)(total >> (24 - 8 * i));
    fwrite(info, 1, 42, f);
    for (int i = 0; i < KINDS * 10; i++) {
      make(i / 10, lr, MUSIC_PACK_FRAMES, (long)i * MUSIC_PACK_FRAMES);
      const int n = music_pack(lr, MUSIC_PACK_FRAMES, (uint32_t)i, out);
      fwrite(out, 1, (size_t)n, f);
      fwrite(lr, 4, MUSIC_PACK_FRAMES, raw);
    }
    fclose(f);
    fclose(raw);
    /* For Dart: each kind's chunk whole, with the samples it came from: how long each is (32 bits, low first), then it. */
    snprintf(name, sizeof(name), "%s/music_chunks.bin", argv[1]);
    f = fopen(name, "wb");
    for (int k = 0; k < KINDS; k++) {
      const int n = k == 6 ? MUSIC_PACK_FRAMES : 320;
      make(k, lr, n, 0);
      const uint32_t len[2] = {(uint32_t)music_chunk(lr, n, (uint64_t)k * 0x1234567u + (k == 12 ? 0x100000000ull : 0), out), (uint32_t)n * 4};
      fwrite(len, 4, 2, f);
      fwrite(out, 1, len[0], f);
      fwrite(lr, 4, (size_t)n, f);
    }
    fclose(f);
  }
  printf(wrong ? "%d wrong\n" : "PASS\n", wrong);
  return wrong ? 1 : 0;
}
