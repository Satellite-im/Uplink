/* music_pack: see music_pack.h. FLAC's format is RFC 9639. */
#include "music_pack.h"

#include <string.h>

/* Bits written high first, as FLAC has them. */
typedef struct {
  uint8_t *out;
  int at;       /* whole bytes written */
  uint32_t acc; /* what waits, in its low [held] bits (fewer than 8) */
  int held;
} Bits;

static void put(Bits *b, uint32_t value, int n) {
  /* At most 24 at a time, so that the accumulator never overflows. */
  if (n > 16) {
    put(b, value >> 16, n - 16);
    value &= 0xffff;
    n = 16;
  }
  b->acc = (b->acc << n) | (value & ((1u << n) - 1));
  b->held += n;
  while (b->held >= 8) {
    b->held -= 8;
    b->out[b->at++] = (uint8_t)(b->acc >> b->held);
  }
  b->acc &= (1u << b->held) - 1;
}

static void put_unary(Bits *b, uint32_t zeros) {
  while (zeros >= 16) {
    put(b, 0, 16);
    zeros -= 16;
  }
  put(b, 1, (int)zeros + 1);
}

static uint8_t crc8(const uint8_t *p, int n) {
  uint8_t c = 0;
  for (int i = 0; i < n; i++) {
    c ^= p[i];
    for (int k = 0; k < 8; k++) c = (uint8_t)((c & 0x80) ? (c << 1) ^ 0x07 : c << 1);
  }
  return c;
}

static uint16_t crc16(const uint8_t *p, int n) {
  uint16_t c = 0;
  for (int i = 0; i < n; i++) {
    c ^= (uint16_t)(p[i] << 8);
    for (int k = 0; k < 8; k++) c = (uint16_t)((c & 0x8000) ? (c << 1) ^ 0x8005 : c << 1);
  }
  return c;
}

#define MOST_PARTITIONS 5 /* 2 to this many parts of a chunk's rests, each with a parameter of its own */

enum { CONSTANT, VERBATIM, FIXED };

/* How one channel is best told: which way, the bits it takes, and for FIXED its order and the Rice coding of its rests. */
typedef struct {
  int way, order, parts;
  uint32_t bits;
  uint8_t k[1 << MOST_PARTITIONS];
} Plan;

/* What [order] differences leave of the sample at [i]. */
static int32_t rest(const int32_t *x, int i, int order) {
  switch (order) {
    case 0: return x[i];
    case 1: return x[i] - x[i - 1];
    case 2: return x[i] - 2 * x[i - 1] + x[i - 2];
    case 3: return x[i] - 3 * x[i - 1] + 3 * x[i - 2] - x[i - 3];
    default: return x[i] - 4 * x[i - 1] + 6 * x[i - 2] - 4 * x[i - 3] + x[i - 4];
  }
}

/* A rest as Rice coding takes it: never below nothing, small where the rest is. */
static uint32_t fold(int32_t v) { return ((uint32_t)v << 1) ^ (uint32_t)(v >> 31); }

static void plan(const int32_t *x, int n, int depth, Plan *p) {
  int same = 1;
  for (int i = 1; i < n && same; i++) same = x[i] == x[0];
  if (same) {
    p->way = CONSTANT;
    p->bits = 8 + (uint32_t)depth;
    return;
  }
  p->way = VERBATIM;
  p->bits = 8 + (uint32_t)(n * depth);

  uint64_t sums[5] = {0, 0, 0, 0, 0};
  for (int i = 4; i < n; i++) {
    for (int o = 0; o < 5; o++) sums[o] += fold(rest(x, i, o));
  }
  int order = 0;
  for (int o = 1; o < 5; o++) {
    if (sums[o] < sums[order]) order = o;
  }

  for (int parts = 0; parts <= MOST_PARTITIONS; parts++) {
    const int each = n >> parts;
    if ((each << parts) != n || each <= order) break;
    uint64_t bits = 8 + (uint64_t)(order * depth) + 6;
    uint8_t ks[1 << MOST_PARTITIONS];
    for (int q = 0; q < 1 << parts; q++) {
      const int from = q == 0 ? order : q * each, to = (q + 1) * each;
      uint64_t sum = 0;
      for (int i = from; i < to; i++) sum += fold(rest(x, i, order));
      int guess = 0;
      while (guess < 14 && ((uint64_t)(to - from) << (guess + 1)) <= sum) guess++;
      uint64_t best = ~(uint64_t)0;
      for (int k = guess > 0 ? guess - 1 : 0; k <= guess + 1 && k <= 14; k++) {
        uint64_t b = (uint64_t)(to - from) * (uint64_t)(k + 1);
        for (int i = from; i < to; i++) b += fold(rest(x, i, order)) >> k;
        if (b < best) {
          best = b;
          ks[q] = (uint8_t)k;
        }
      }
      bits += 4 + best;
    }
    if (bits < p->bits) {
      p->way = FIXED;
      p->bits = (uint32_t)bits;
      p->order = order;
      p->parts = parts;
      memcpy(p->k, ks, sizeof(ks));
    }
  }
}

static void write_channel(Bits *b, const int32_t *x, int n, int depth, const Plan *p) {
  const uint32_t mask = (1u << depth) - 1;
  if (p->way == CONSTANT) {
    put(b, 0x00, 8);
    put(b, (uint32_t)x[0] & mask, depth);
    return;
  }
  if (p->way == VERBATIM) {
    put(b, 0x02, 8);
    for (int i = 0; i < n; i++) put(b, (uint32_t)x[i] & mask, depth);
    return;
  }
  put(b, (uint32_t)(8 + p->order) << 1, 8);
  for (int i = 0; i < p->order; i++) put(b, (uint32_t)x[i] & mask, depth);
  put(b, 0, 2);
  put(b, (uint32_t)p->parts, 4);
  const int each = n >> p->parts;
  for (int q = 0; q < 1 << p->parts; q++) {
    const int k = p->k[q];
    put(b, (uint32_t)k, 4);
    for (int i = q == 0 ? p->order : q * each; i < (q + 1) * each; i++) {
      const uint32_t u = fold(rest(x, i, p->order));
      put_unary(b, u >> k);
      if (k) put(b, u & ((1u << k) - 1), k);
    }
  }
}

int music_pack(const int16_t *lr, int frames, uint32_t number, uint8_t *out) {
  if (frames < 16 || frames > MUSIC_PACK_MOST) return 0;
  /* Left, right, their middle and their difference: 64 KB of the stack, which every thread here has. */
  int32_t x[4][MUSIC_PACK_MOST];
  for (int i = 0; i < frames; i++) {
    const int32_t l = lr[i * 2], r = lr[i * 2 + 1];
    x[0][i] = l;
    x[1][i] = r;
    x[2][i] = (l + r) >> 1;
    x[3][i] = l - r;
  }
  Plan p[4];
  memset(p, 0, sizeof(p));
  for (int c = 0; c < 4; c++) plan(x[c], frames, c == 3 ? 17 : 16, &p[c]);
  /* FLAC's four ways: each alone; left and the difference; the difference and right; the middle and the difference. */
  static const int first[4] = {0, 0, 3, 2}, second[4] = {1, 3, 1, 3}, code[4] = {1, 8, 9, 10};
  int way = 0;
  for (int w = 1; w < 4; w++) {
    if (p[first[w]].bits + p[second[w]].bits < p[first[way]].bits + p[second[way]].bits) way = w;
  }

  Bits b = {out, 0, 0, 0};
  put(&b, 0xfff8, 16);
  put(&b, 0x7a, 8); /* the count in 16 bits below, 48 kHz */
  put(&b, (uint32_t)(code[way] << 4) | 0x08, 8);
  number &= 0x7fffffff;
  if (number < 0x80) {
    put(&b, number, 8);
  } else {
    /* As UTF-8 has it, up to six bytes. */
    int more = number < 0x800 ? 1 : number < 0x10000 ? 2 : number < 0x200000 ? 3 : number < 0x4000000 ? 4 : 5;
    put(&b, ((0xff00u >> (more + 1)) & 0xff) | (number >> (6 * more)), 8);
    while (more--) put(&b, 0x80 | ((number >> (6 * more)) & 0x3f), 8);
  }
  put(&b, (uint32_t)(frames - 1), 16);
  put(&b, crc8(out, b.at), 8);
  write_channel(&b, x[first[way]], frames, first[way] == 3 ? 17 : 16, &p[first[way]]);
  write_channel(&b, x[second[way]], frames, second[way] == 3 ? 17 : 16, &p[second[way]]);
  if (b.held) put(&b, 0, 8 - b.held);
  put(&b, crc16(out, b.at), 16);
  return b.at;
}

int music_chunk(const int16_t *lr, int frames, uint64_t at, uint8_t *out) {
  const int n = music_pack(lr, frames, (uint32_t)(at / (uint64_t)(frames > 0 ? frames : 1)), out + MUSIC_CHUNK_HEAD);
  if (n <= 0 || n > 0xffff) return 0;
  out[0] = MUSIC_CHUNK_VERSION;
  out[1] = MUSIC_CHUNK_FLAC;
  out[2] = (uint8_t)frames;
  out[3] = (uint8_t)(frames >> 8);
  for (int i = 0; i < 6; i++) out[4 + i] = (uint8_t)(at >> (8 * i));
  out[10] = (uint8_t)n;
  out[11] = (uint8_t)(n >> 8);
  return MUSIC_CHUNK_HEAD + n;
}
