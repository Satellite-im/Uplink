/* voicefx: see voicefx.h. */
#include "voicefx.h"

#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* The mode, the gain and DeepFilterNet's state are set on one thread and read on WebRTC's. C11 atomics where the
 * compiler has them; MSVC's C compiler (Windows) has them only behind an experimental switch, so there plain volatile
 * stands in: aligned 32- and 64-bit loads and stores are whole on x64 and arm64, and nothing here needs more. */
#if defined(_MSC_VER) && !defined(__clang__)
#define VFX_ATOMIC volatile
#define vfx_load(p) (*(p))
#define vfx_store(p, v) (*(p) = (v))
#else
#include <stdatomic.h>
#define VFX_ATOMIC _Atomic
#define vfx_load(p) atomic_load(p)
#define vfx_store(p, v) atomic_store(p, v)
#endif

#include "rnnoise.h"
#include "stretch.h"

#ifdef VOICEFX_WITH_DEEPFILTER
/* libDF's C API (DeepFilterNet, MIT/Apache-2.0), linked in where built (native/voicefx/deepfilter). */
typedef struct DFState DFState;
extern DFState *df_create(const char *path, float atten_lim, const char *log_level);
extern size_t df_get_frame_length(DFState *st);
extern float df_process_frame(DFState *st, float *input, float *output);
extern void df_free(DFState *st);
#endif

#define BLOCK 480 /* 10 ms at 48 kHz: RNNoise's frame, and DeepFilterNet's hop. */
#define MOST 1920 /* The longest block taken: 10 ms at 192 kHz. */
#define RING 8192 /* The effect's lines, at 48 kHz: a power of two, more than LATENCY and a piece. */
#define LATENCY 2048 /* How far behind an effect's voice is: 43 ms, a piece's window and the lowest voice's period. */
#define ANALYSE 1536 /* How much is looked at for the voice's period: 32 ms, two of the lowest. */
#define MARKS 64

/* One microphone's state. mode, gain and df may change under voicefx_process; the rest is the processing thread's
 * own: RNNoise's state, and a block at 48 kHz on its way in (at48) and out (out48) of whichever network runs. */
struct VoiceFx {
  VFX_ATOMIC int mode;
  VFX_ATOMIC float gain;
  DenoiseState *rnnoise;
#ifdef VOICEFX_WITH_DEEPFILTER
  DFState *VFX_ATOMIC df;
#endif
  float at48[BLOCK];
  float out48[BLOCK];
  /* Live voice changing (voicefx_live): what the microphone said, at 16 kHz, for the app to take and have changed;
   * and the changed voice the app gave back, at 48 kHz, played into the call in its place. Each is a ring with one
   * writer and one reader, so neither waits on the other. */
  VFX_ATOMIC int live;
  int16_t *heard; /* RING16 samples at 16 kHz */
  VFX_ATOMIC long heardIn, heardOut;
  float *give;    /* RING48 samples at 48 kHz */
  VFX_ATOMIC long giveIn, giveOut;
  float down[BLOCK];
  /* The voice effect (voicefx_effect), and what it keeps from block to block, touched only on WebRTC's thread. */
  VFX_ATOMIC int effect;
  int effectWas;
  float in[RING];       /* what was said, at 48 kHz, for the effect to cut its pieces from */
  float out[RING];      /* the pieces laid down, waiting to be given back */
  long inPos, lastMark, markAt;
  long marks[MARKS];    /* where each period is in [in], and how long it is (0: not voiced) */
  float periods[MARKS];
  double nextOut;       /* where the next piece goes */
  float period;
  int jumped;
  double wobble;        /* an older voice's waver, 0 to 1 */
  float bq[2][4];       /* the radio's two filters' state: x1, x2, y1, y2 */
  VfxStretch *stretch;  /* Signalsmith Stretch, for the voices (stretch.cpp) */
  float sin_[BLOCK], sout[BLOCK];
};

#define RING16 (16000 * 20) /* twenty seconds of what was said, waiting to be taken */
#define RING48 (48000 * 30) /* thirty seconds of the changed voice, waiting to be played */

VoiceFx *voicefx_create(void) {
  VoiceFx *fx = calloc(1, sizeof(VoiceFx));
  if (!fx) return NULL;
  vfx_store(&fx->mode, VOICEFX_OFF);
  vfx_store(&fx->gain, 1.0f);
  fx->rnnoise = rnnoise_create(NULL);
  /* A 48 ms window, a new one every 12 ms: as short as a low voice allows, so the voice is 48 ms behind. */
  fx->stretch = vfx_stretch_create(48000, 2304, 576);
  fx->heard = calloc(RING16, sizeof(int16_t));
  fx->give = calloc(RING48, sizeof(float));
  if (!fx->heard || !fx->give) {
    free(fx->heard);
    free(fx->give);
    if (fx->rnnoise) rnnoise_destroy(fx->rnnoise);
    free(fx);
    return NULL;
  }
  return fx;
}

void voicefx_destroy(VoiceFx *fx) {
  if (!fx) return;
  vfx_stretch_destroy(fx->stretch);
  if (fx->rnnoise) rnnoise_destroy(fx->rnnoise);
  free(fx->heard);
  free(fx->give);
#ifdef VOICEFX_WITH_DEEPFILTER
  DFState *df = vfx_load(&fx->df);
  vfx_store(&fx->df, NULL);
  if (df) df_free(df);
#endif
  free(fx);
}

int voicefx_modes(VoiceFx *fx) {
  int bits = 0;
  if (fx && fx->rnnoise) bits |= 1 << VOICEFX_RNNOISE;
#ifdef VOICEFX_WITH_DEEPFILTER
  if (fx && vfx_load(&fx->df)) bits |= 1 << VOICEFX_DEEPFILTER;
#endif
  return bits;
}

int voicefx_deepfilter_model(VoiceFx *fx, const char *path) {
#ifdef VOICEFX_WITH_DEEPFILTER
  if (!fx || !path) return 0;
  if (vfx_load(&fx->df)) return 1;
  /* No limit on how far noise is brought down (100 dB); its frame is 480 at 48 kHz or it is not used. */
  DFState *df = df_create(path, 100.0f, NULL);
  if (!df) return 0;
  if (df_get_frame_length(df) != BLOCK) {
    df_free(df);
    return 0;
  }
  vfx_store(&fx->df, df);
  return 1;
#else
  (void)fx;
  (void)path;
  return 0;
#endif
}

/* The gain is held to 0..2. A mode this build cannot run is kept as asked and does nothing: the sound passes. */
void voicefx_configure(VoiceFx *fx, int mode, float gain) {
  if (!fx) return;
  if (gain < 0) gain = 0;
  if (gain > 2) gain = 2;
  vfx_store(&fx->mode, mode);
  vfx_store(&fx->gain, gain);
}

/* Linear resampling between a block of [n] and one of [m] samples: the same 10 ms either way. */
static void resample(const float *in, int n, float *out, int m) {
  if (n == m) {
    memcpy(out, in, sizeof(float) * (size_t)n);
    return;
  }
  for (int i = 0; i < m; i++) {
    float at = (float)i * (float)(n - 1) / (float)(m - 1 > 0 ? m - 1 : 1);
    int a = (int)at;
    int b = a + 1 < n ? a + 1 : n - 1;
    float f = at - (float)a;
    out[i] = in[a] * (1 - f) + in[b] * f;
  }
}

static float limit(float x);

/* A second-order filter (RBJ's cookbook) on [s], its state in [z]. */
static void biquad(float *s, int n, float *z, double b0, double b1, double b2, double a1, double a2) {
  for (int i = 0; i < n; i++) {
    double x = s[i];
    double y = b0 * x + b1 * z[0] + b2 * z[1] - a1 * z[2] - a2 * z[3];
    z[1] = z[0];
    z[0] = (float)x;
    z[3] = z[2];
    z[2] = (float)y;
    s[i] = (float)y;
  }
}
/* A high-pass ([high]) or a low-pass at [hz], for sound at 48 kHz. */
static void pass(float *s, int n, float *z, double hz, int high) {
  const double w = 2.0 * 3.14159265358979 * hz / 48000.0, q = 0.8;
  const double c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha;
  if (high) {
    biquad(s, n, z, (1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0);
  } else {
    biquad(s, n, z, (1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0);
  }
}
/* Driven: soft saturation on the 16-bit scale, [drive] times into it. */
static void drive(float *s, int n, float amount) {
  for (int i = 0; i < n; i++) {
    float x = s[i] / 32768.0f * amount;
    s[i] = 32768.0f * 0.85f * (x / (1.0f + fabsf(x)));
  }
}

/* --- voice effects ------------------------------------------------------------------------------------------------ */

/* A voice's pitch and its formants (the resonances of the throat and mouth that say how big the speaker is) moved
 * apart, as the voice goes (Matt, 2026-11-21: "work on making them sound more realistic and do feminine masculine and
 * things like that"). Every voice but the robot is now moved by Signalsmith Stretch (see effect, below); what follows
 * is the robot's way, and the others' where there is no Stretch:
 * pitch-synchronous overlap-add (PSOLA). The voice's period is found (YIN, on a quarter-rate copy);
 * each period is cut out round its peak with a window two periods long; the pieces are laid down again closer together
 * for a higher voice or further apart for a lower one, which moves the pitch and leaves the formants where they were;
 * and each piece is squeezed or stretched as it is laid down, which moves the formants alone. Moving only the pitch is
 * what makes a voice sound like a cartoon; a woman's voice is about an octave's two thirds higher and her formants
 * about a sixth higher than a man's.
 *
 * Everything at 48 kHz, LATENCY behind: the window must be whole before it is laid down. Unvoiced sound (an s, a
 * breath) is cut in pieces of 10 ms and laid down where it was, its formants moved all the same. */

typedef struct {
  float pitch;   /* the new pitch over the old: 1.6 is a woman's from a man's */
  float formant; /* the new formants over the old */
  float hz;      /* a fixed pitch instead (the robot); 0 for none */
  float vibrato; /* how far the pitch wavers, as a fraction (an older voice) */
  float drive;   /* how rough, 0 for clean */
} Shape;

/* What each effect does to a voice; the radio has no shape (it is filters alone), nor has none. */
static Shape shape_of(int which) {
  Shape s = {1, 1, 0, 0, 0};
  switch (which) {
    case VOICEFX_EFFECT_FEMININE: s.pitch = 1.55f; s.formant = 1.17f; break;
    case VOICEFX_EFFECT_MASCULINE: s.pitch = 0.66f; s.formant = 0.86f; break;
    case VOICEFX_EFFECT_DEEPER: s.pitch = 0.82f; s.formant = 0.93f; break;
    case VOICEFX_EFFECT_HIGHER: s.pitch = 1.22f; s.formant = 1.06f; break;
    case VOICEFX_EFFECT_CHILD: s.pitch = 1.8f; s.formant = 1.3f; break;
    case VOICEFX_EFFECT_OLDER: s.pitch = 0.93f; s.formant = 0.97f; s.vibrato = 0.035f; s.drive = 1.2f; break;
    case VOICEFX_EFFECT_MONSTER: s.pitch = 0.55f; s.formant = 0.74f; s.drive = 2.0f; break;
    case VOICEFX_EFFECT_CHIPMUNK: s.pitch = 1.9f; s.formant = 1.75f; break;
    case VOICEFX_EFFECT_ROBOT: s.hz = 105; s.formant = 1.0f; break;
    default: break;
  }
  return s;
}

/* The lowest and highest pitch a voice is looked for at. */
#define PI 3.14159265358979
#define MIN_HZ 70
#define MAX_HZ 500

/* The voice's period now in samples at 48 kHz, from the newest ANALYSE samples; 0 where it is not voiced. */
static float find_period(VoiceFx *fx) {
  /* A quarter-rate copy (12 kHz), each sample the mean of four. */
  enum { N = ANALYSE / 4 };
  float x[N];
  float energy = 0;
  long end = fx->inPos;
  for (int i = 0; i < N; i++) {
    long at = end - ANALYSE + i * 4;
    float v = 0;
    for (int k = 0; k < 4; k++) v += fx->in[(at + k) & (RING - 1)];
    x[i] = v / 4;
    energy += x[i] * x[i];
  }
  if (sqrtf(energy / N) < 250) return 0; /* quiet: nobody is speaking */
  const int lo = 12000 / MAX_HZ, hi = 12000 / MIN_HZ, w = N - hi;
  float d[12000 / MIN_HZ + 2];
  float sum = 0;
  int best = -1;
  d[0] = 1;
  for (int tau = 1; tau <= hi + 1; tau++) {
    float s = 0;
    for (int i = 0; i < w; i++) {
      float diff = x[i] - x[i + tau];
      s += diff * diff;
    }
    sum += s;
    d[tau] = sum > 0 ? s * tau / sum : 1; /* YIN's cumulative mean normalised difference */
  }
  for (int tau = lo; tau <= hi; tau++) {
    if (d[tau] < 0.18f) {
      while (tau + 1 <= hi && d[tau + 1] < d[tau]) tau++;
      best = tau;
      break;
    }
  }
  if (best < 0) return 0;
  /* Between the samples, from the parabola through the dip and its neighbours. */
  float a = d[best - 1], b = d[best], c = d[best + 1];
  float den = a - 2 * b + c;
  float t = best + (fabsf(den) > 1e-6f ? 0.5f * (a - c) / den : 0);
  return t * 4;
}

/* What was said at [at], which may fall between two samples: a straight line between them. */
static float in_at(VoiceFx *fx, double at) {
  long a = (long)floor(at);
  float f = (float)(at - (double)a);
  return fx->in[a & (RING - 1)] * (1 - f) + fx->in[(a + 1) & (RING - 1)] * f;
}

/* Marks the input where each period is: at its peak, a period on from the last. */
static void mark_input(VoiceFx *fx, float period) {
  for (;;) {
    float p = period > 0 ? period : 480;
    long next = fx->lastMark + (long)p;
    long reach = period > 0 ? (long)(p / 3) : 0;
    if (next + reach + 1 > fx->inPos) break;
    if (next < fx->inPos - RING / 2) next = fx->inPos - RING / 2; /* after silence, from now */
    if (reach > 0) {
      long best = next;
      float top = -1e9f;
      for (long k = next - reach; k <= next + reach; k++) {
        if (k <= fx->lastMark + (long)(p / 2)) continue;
        float v = fx->in[k & (RING - 1)];
        if (v > top) {
          top = v;
          best = k;
        }
      }
      next = best;
    }
    fx->marks[fx->markAt % MARKS] = next;
    fx->periods[fx->markAt % MARKS] = period > 0 ? period : 0;
    fx->markAt++;
    fx->lastMark = next;
  }
}

/* One piece laid down: the input round mark [m] (its period [p], 0 unvoiced) at output position [c]. */
static void lay(VoiceFx *fx, long m, float p, double c, float formant, float gain) {
  float half = (p > 0 ? p : 480) / formant;
  long from = (long)ceil(c - half), to = (long)floor(c + half);
  for (long t = from; t <= to; t++) {
    double k = (double)t - c;
    float w = (float)(0.5 + 0.5 * cos(PI * k / half));
    fx->out[t & (RING - 1)] += in_at(fx, (double)m + k * formant) * w * gain;
  }
}

/* PSOLA on one block: [s] goes into the ring, pieces are laid down for it, and [s] comes back as what was said
 * LATENCY ago, reshaped. */
static void reshape(VoiceFx *fx, int which, float *s, int n) {
  Shape sh = shape_of(which);
  for (int i = 0; i < n; i++) fx->in[(fx->inPos + i) & (RING - 1)] = s[i];
  fx->inPos += n;
  float found = find_period(fx);
  /* Steadied: a period near the last is trusted at once, a jump only once it is heard twice. */
  if (found > 0 && fx->period > 0 && fabsf(found - fx->period) > fx->period * 0.3f && fx->jumped == 0) {
    fx->jumped = 1;
    found = fx->period;
  } else {
    fx->jumped = 0;
  }
  fx->period = found;
  mark_input(fx, found);
  /* Pieces are laid down while their input is all there; what is LATENCY behind is given back. */
  const long ready = fx->inPos - (long)(48000 / MIN_HZ * 3 / 2);
  while (fx->nextOut <= (double)ready) {
    /* The input mark nearest this output one. */
    long m = -1;
    float p = 0;
    double bestGap = 1e18;
    for (long i = fx->markAt - 1; i >= 0 && i >= fx->markAt - MARKS; i--) {
      double gap = fabs((double)fx->marks[i % MARKS] - fx->nextOut);
      if (gap < bestGap) {
        bestGap = gap;
        m = fx->marks[i % MARKS];
        p = fx->periods[i % MARKS];
      }
    }
    float step = 480;
    if (m >= 0 && bestGap < 2000) {
      if (p > 0) {
        step = sh.hz > 0 ? 48000.0f / sh.hz : p / sh.pitch;
        if (sh.vibrato > 0) {
          step /= 1.0f + sh.vibrato * (float)sin(2 * PI * fx->wobble);
          fx->wobble += step * 5.5 / 48000.0;
          fx->wobble -= floor(fx->wobble);
        }
      } else {
        step = 480;
      }
      float half = (p > 0 ? p : 480) / sh.formant;
      /* Hann pieces 2 x half long, laid every step: their sum is half / step; brought back to one. */
      float gain = step < 2 * half ? step / half : 1;
      lay(fx, m, p, fx->nextOut, sh.formant, gain);
    }
    fx->nextOut += step;
  }
  for (int i = 0; i < n; i++) {
    long t = fx->inPos - LATENCY - n + i;
    float v = fx->out[t & (RING - 1)];
    fx->out[t & (RING - 1)] = 0;
    s[i] = v;
  }
  if (sh.drive > 0) drive(s, n, sh.drive);
}

/* The voice effect [which] on one block at 48 kHz, in place: the radio by filters, the robot by PSOLA, every other
 * voice by Signalsmith Stretch. */
static void effect(VoiceFx *fx, int which, float *s, int n) {
  if (which != fx->effectWas) {
    /* A new effect starts from quiet: nothing of the last one is heard. */
    memset(fx->in, 0, sizeof fx->in);
    memset(fx->out, 0, sizeof fx->out);
    memset(fx->bq, 0, sizeof fx->bq);
    fx->inPos = fx->lastMark = fx->markAt = 0;
    fx->nextOut = 0;
    fx->period = 0;
    fx->jumped = 0;
    fx->wobble = 0;
    fx->effectWas = which;
    vfx_stretch_reset(fx->stretch);
  }
  if (which == VOICEFX_EFFECT_RADIO) {
    pass(s, n, fx->bq[0], 400, 1);
    pass(s, n, fx->bq[1], 2800, 0);
    drive(s, n, 3.0f);
    return;
  }
  Shape sh = shape_of(which);
  /* The robot's one flat pitch is PSOLA's alone; every other voice is Signalsmith Stretch's, where it was made. */
  if (sh.hz > 0 || !fx->stretch) {
    reshape(fx, which, s, n);
    return;
  }
  float pitch = sh.pitch;
  if (sh.vibrato > 0) {
    pitch *= 1.0f + sh.vibrato * (float)sin(2 * PI * fx->wobble);
    fx->wobble += (double)n * 5.5 / 48000.0;
    fx->wobble -= floor(fx->wobble);
  }
  vfx_stretch_shape(fx->stretch, pitch, sh.formant);
  for (int i = 0; i < n; i++) fx->sin_[i] = s[i] / 32768.0f;
  vfx_stretch_process(fx->stretch, fx->sin_, fx->sout, n);
  for (int i = 0; i < n; i++) s[i] = limit(fx->sout[i] * 32768.0f);
  if (sh.drive > 0) drive(s, n, sh.drive);
}

/* Over full scale, rounded off rather than clipped: the top tenth of the range is bent toward its end. */
static float limit(float x) {
  const float top = 32767.0f, knee = 29490.0f; /* 90% */
  float a = fabsf(x);
  if (a <= knee) return x;
  float over = (a - knee) / (top - knee);
  float bent = knee + (top - knee) * (over / (1.0f + over));
  return x < 0 ? -bent : bent;
}

/* Noise first, then gain. Both networks run at 48 kHz: a block at another rate is resampled to 480 samples, cleaned,
 * and resampled back. A block longer than MOST is left as it came. */
void voicefx_process(VoiceFx *fx, float *samples, int frames, int rate) {
  if (!fx || !samples || frames <= 0 || frames > MOST) return;
  int mode = vfx_load(&fx->mode);
  float gain = vfx_load(&fx->gain);
  /* A block that is not 10 ms is not denoised (neither network could take it); the gain still applies. */
  int tenMs = rate > 0 && frames * 100 == rate;
#ifdef VOICEFX_WITH_DEEPFILTER
  DFState *df = vfx_load(&fx->df);
#endif
  if (tenMs && mode == VOICEFX_RNNOISE && fx->rnnoise) {
    resample(samples, frames, fx->at48, BLOCK);
    rnnoise_process_frame(fx->rnnoise, fx->out48, fx->at48); /* On the 16-bit scale, as it is given. */
    resample(fx->out48, BLOCK, samples, frames);
  }
#ifdef VOICEFX_WITH_DEEPFILTER
  else if (tenMs && mode == VOICEFX_DEEPFILTER && df) {
    resample(samples, frames, fx->at48, BLOCK);
    for (int i = 0; i < BLOCK; i++) fx->at48[i] /= 32768.0f; /* DeepFilterNet takes -1 to 1. */
    df_process_frame(df, fx->at48, fx->out48);
    for (int i = 0; i < BLOCK; i++) fx->out48[i] *= 32768.0f;
    resample(fx->out48, BLOCK, samples, frames);
  }
#endif
  if (gain != 1.0f) {
    for (int i = 0; i < frames; i++) samples[i] = limit(samples[i] * gain);
  }
  int which = vfx_load(&fx->effect);
  if (which > 0 && which < VOICEFX_EFFECT_COUNT && tenMs && !vfx_load(&fx->live)) {
    resample(samples, frames, fx->at48, BLOCK);
    effect(fx, which, fx->at48, BLOCK);
    resample(fx->at48, BLOCK, samples, frames);
  } else if (which != fx->effectWas) {
    fx->effectWas = -1; /* begun afresh when it is next on */
  }
  if (vfx_load(&fx->live) && tenMs) {
    /* What was said, cleaned and at its loudness, kept at 16 kHz for the app (every third sample of 48 kHz, after a
     * three-tap average so nothing above 8 kHz folds back). */
    resample(samples, frames, fx->at48, BLOCK);
    long in = vfx_load(&fx->heardIn), out = vfx_load(&fx->heardOut);
    for (int i = 0; i + 2 < BLOCK; i += 3) {
      if (in - out >= RING16) break; /* nobody is taking it: what is newest waits for room */
      float v = (fx->at48[i] + fx->at48[i + 1] + fx->at48[i + 2]) / 3.0f;
      fx->heard[in % RING16] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v);
      in++;
    }
    vfx_store(&fx->heardIn, in);
    /* And in its place, the changed voice where some has come back; silence where none has. */
    long gin = vfx_load(&fx->giveIn), gout = vfx_load(&fx->giveOut);
    for (int i = 0; i < BLOCK; i++) {
      if (gout < gin) {
        fx->out48[i] = fx->give[gout % RING48];
        gout++;
      } else {
        fx->out48[i] = 0;
      }
    }
    vfx_store(&fx->giveOut, gout);
    resample(fx->out48, BLOCK, samples, frames);
  }
}

void voicefx_live(VoiceFx *fx, int on) {
  if (!fx) return;
  vfx_store(&fx->live, on ? 1 : 0);
  /* Begun or ended, nothing old is said or played. */
  vfx_store(&fx->heardOut, vfx_load(&fx->heardIn));
  vfx_store(&fx->giveIn, vfx_load(&fx->giveOut));
}

int voicefx_take(VoiceFx *fx, int16_t *out, int most) {
  if (!fx || !out || most <= 0) return 0;
  long in = vfx_load(&fx->heardIn), at = vfx_load(&fx->heardOut);
  int n = 0;
  while (at < in && n < most) out[n++] = fx->heard[at++ % RING16];
  vfx_store(&fx->heardOut, at);
  return n;
}

void voicefx_feed(VoiceFx *fx, const int16_t *pcm, int n, int rate) {
  if (!fx || !pcm || n <= 0 || rate <= 0) return;
  long in = vfx_load(&fx->giveIn), out = vfx_load(&fx->giveOut);
  /* To 48 kHz, linearly: for each sample at 48 kHz, where it falls in what was given. */
  long m = (long)n * 48000 / rate;
  for (long j = 0; j < m; j++) {
    if (in - out >= RING48) break; /* thirty seconds behind already: the rest is dropped */
    double at = (double)j * rate / 48000.0;
    int a = (int)at;
    int b = a + 1 < n ? a + 1 : n - 1;
    float f = (float)(at - a);
    fx->give[in % RING48] = pcm[a] * (1 - f) + pcm[b] * f;
    in++;
  }
  vfx_store(&fx->giveIn, in);
}

int voicefx_queued_ms(VoiceFx *fx) {
  if (!fx) return 0;
  return (int)((vfx_load(&fx->giveIn) - vfx_load(&fx->giveOut)) / 48);
}

void voicefx_effect(VoiceFx *fx, int effect) {
  if (!fx) return;
  if (effect < 0 || effect >= VOICEFX_EFFECT_COUNT) effect = VOICEFX_EFFECT_NONE;
  vfx_store(&fx->effect, effect);
}

/* The names in the order of the VOICEFX_EFFECT_ numbers: a name's place in the list is its effect. */
int voicefx_effect_id(const char *name) {
  static const char *names[VOICEFX_EFFECT_COUNT] = {"none", "deeper", "higher", "chipmunk", "monster", "robot", "radio", "feminine", "masculine", "child", "older"};
  if (!name) return VOICEFX_EFFECT_NONE;
  for (int i = 1; i < VOICEFX_EFFECT_COUNT; i++) {
    if (strcmp(name, names[i]) == 0) return i;
  }
  return VOICEFX_EFFECT_NONE;
}
