// Signalsmith Stretch (MIT, signalsmith/; Matt, 2026-11-21: "Try Signalsmith") behind a C face, for voicefx.c's
// effects: a voice's pitch and its formants moved apart by a phase vocoder, as it goes.
#include "signalsmith/signalsmith-stretch.h"

#include "stretch.h"

// One voice's stretcher, and the shape it was last given. Its randomness is seeded with a fixed number, so the same
// samples in give the same samples out on every run.
struct VfxStretch {
  signalsmith::stretch::SignalsmithStretch<float> s{12345};
  float pitch = 1, formant = 1;
};

extern "C" VfxStretch *vfx_stretch_create(int rate, int block, int interval) {
  auto *v = new VfxStretch();
  v->s.configure(1, block > 0 ? block : rate * 64 / 1000, interval > 0 ? interval : rate * 16 / 1000);
  // 0: the voice's fundamental is found from the sound itself, not told.
  v->s.setFormantBase(0);
  return v;
}

extern "C" void vfx_stretch_destroy(VfxStretch *v) { delete v; }

extern "C" void vfx_stretch_shape(VfxStretch *v, float pitch, float formant) {
  if (!v) return;
  // Only what changed is set. The formants are set again when the pitch moves too, since they are kept where they
  // were by taking the pitch's move back out of them.
  if (pitch != v->pitch) v->s.setTransposeFactor(pitch);
  if (formant != v->formant || pitch != v->pitch) v->s.setFormantFactor(formant, true);
  v->pitch = pitch;
  v->formant = formant;
}

extern "C" void vfx_stretch_process(VfxStretch *v, const float *in, float *out, int n) {
  if (!v) return;
  const float *ins[1] = {in};
  float *outs[1] = {out};
  v->s.process(ins, n, outs, n);
}

// How many samples late what comes out is, in and out together.
extern "C" int vfx_stretch_latency(VfxStretch *v) { return v ? v->s.inputLatency() + v->s.outputLatency() : 0; }

extern "C" void vfx_stretch_reset(VfxStretch *v) {
  if (v) v->s.reset();
}
