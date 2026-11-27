/* Reads what music_pack made back, for the tests alone (the app reads it in lib/voice/flac.dart): written from FLAC's
 * format (RFC 9639), not from music_pack.c. Answers the frames, or a negative number naming what is wrong. */
#ifndef MUSIC_UNPACK_H
#define MUSIC_UNPACK_H

#include <stdint.h>
#include <stdlib.h>

typedef struct {
  const uint8_t *p;
  long at, end; /* in bits */
  int over;
} MuIn;

static uint32_t mu_bits(MuIn *in, int n) {
  uint32_t v = 0;
  while (n--) {
    if (in->at >= in->end) {
      in->over = 1;
      return 0;
    }
    v = (v << 1) | ((in->p[in->at >> 3] >> (7 - (in->at & 7))) & 1);
    in->at++;
  }
  return v;
}

static int32_t mu_signed(MuIn *in, int n) {
  const uint32_t v = mu_bits(in, n);
  return (v >> (n - 1)) ? (int32_t)v - (int32_t)(1u << n) : (int32_t)v;
}

static int mu_channel(MuIn *in, int32_t *x, int n, int depth) {
  const uint32_t type = mu_bits(in, 8);
  if (type == 0x00) {
    const int32_t v = mu_signed(in, depth);
    for (int i = 0; i < n; i++) x[i] = v;
    return 0;
  }
  if (type == 0x02) {
    for (int i = 0; i < n; i++) x[i] = mu_signed(in, depth);
    return 0;
  }
  const int order = (int)(type >> 1) - 8;
  if ((type & 1) || order < 0 || order > 4) return -10;
  for (int i = 0; i < order; i++) x[i] = mu_signed(in, depth);
  if (mu_bits(in, 2) != 0) return -11;
  const int parts = (int)mu_bits(in, 4), each = n >> parts;
  if ((each << parts) != n || each <= order) return -12;
  for (int q = 0; q < 1 << parts; q++) {
    const int k = (int)mu_bits(in, 4);
    if (k == 15) return -13;
    for (int i = q ? q * each : order; i < (q + 1) * each; i++) {
      uint32_t hi = 0;
      while (!mu_bits(in, 1)) {
        if (in->over || ++hi > 1u << 20) return -14;
      }
      const uint32_t u = (hi << k) | mu_bits(in, k);
      int64_t e = (u & 1) ? -(int64_t)(u >> 1) - 1 : (int64_t)(u >> 1);
      switch (order) {
        case 0: break;
        case 1: e += x[i - 1]; break;
        case 2: e += 2 * x[i - 1] - x[i - 2]; break;
        case 3: e += 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3]; break;
        default: e += 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4]; break;
      }
      if (e < -(1 << 16) || e >= 1 << 16) return -15;
      x[i] = (int32_t)e;
    }
  }
  return 0;
}

static int music_unpack(const uint8_t *p, int len, int16_t *lr, int most) {
  MuIn in = {p, 0, (long)len * 8, 0};
  if (mu_bits(&in, 16) != 0xfff8) return -1;
  if (mu_bits(&in, 8) != 0x7a) return -2;
  const uint32_t how = mu_bits(&in, 8);
  if ((how & 0x0f) != 8) return -3;
  uint32_t lead = mu_bits(&in, 8);
  int more = 0;
  if (lead >= 0xc0) {
    while (lead & (0x80u >> more)) more++;
    more--;
  }
  while (more--) mu_bits(&in, 8);
  const int n = (int)mu_bits(&in, 16) + 1;
  if (n > most) return -4;
  uint8_t c8 = 0;
  for (long i = 0; i < in.at / 8; i++) {
    c8 ^= p[i];
    for (int k = 0; k < 8; k++) c8 = (uint8_t)((c8 & 0x80) ? (c8 << 1) ^ 7 : c8 << 1);
  }
  if (mu_bits(&in, 8) != c8) return -5;
  int32_t *a = (int32_t *)malloc(sizeof(int32_t) * (size_t)n * 2), *b = a + n;
  const uint32_t way = how >> 4;
  int wrong = way == 1 || (way >= 8 && way <= 10) ? 0 : -6;
  if (!wrong) wrong = mu_channel(&in, a, n, way == 9 ? 17 : 16);
  if (!wrong) wrong = mu_channel(&in, b, n, way == 8 || way == 10 ? 17 : 16);
  if (in.at & 7) mu_bits(&in, 8 - (int)(in.at & 7));
  uint16_t c16 = 0;
  for (long i = 0; i < in.at / 8; i++) {
    c16 ^= (uint16_t)(p[i] << 8);
    for (int k = 0; k < 8; k++) c16 = (uint16_t)((c16 & 0x8000) ? (c16 << 1) ^ 0x8005 : c16 << 1);
  }
  if (!wrong && (mu_bits(&in, 16) != c16 || in.over || in.at != in.end)) wrong = -7;
  for (int i = 0; i < n && !wrong; i++) {
    int32_t l = a[i], r = b[i];
    if (way == 8) r = l - r;
    if (way == 9) l = l + r;
    if (way == 10) {
      const int32_t m = l, s = r;
      l = (2 * m + (s & 1) + s) >> 1;
      r = (2 * m + (s & 1) - s) >> 1;
    }
    lr[i * 2] = (int16_t)l;
    lr[i * 2 + 1] = (int16_t)r;
  }
  free(a);
  return wrong ? wrong : n;
}

#endif
