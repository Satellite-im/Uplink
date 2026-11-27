/* Signalsmith Stretch behind a C face (stretch.cpp), for voicefx.c. */
#ifndef VOICEFX_STRETCH_H
#define VOICEFX_STRETCH_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VfxStretch VfxStretch;

/* Mono at [rate]; its analysis window [block] samples, a new one every [interval] (0 for each: 64 ms and 16 ms). */
VfxStretch *vfx_stretch_create(int rate, int block, int interval);
void vfx_stretch_destroy(VfxStretch *v);
/* The new pitch over the old, and the new formants over the old (the formants kept where they were as the pitch moves). */
void vfx_stretch_shape(VfxStretch *v, float pitch, float formant);
/* [n] samples in, [n] out: what came in its latency ago, reshaped. */
void vfx_stretch_process(VfxStretch *v, const float *in, float *out, int n);
int vfx_stretch_latency(VfxStretch *v);
void vfx_stretch_reset(VfxStretch *v);

#ifdef __cplusplus
}
#endif

#endif
