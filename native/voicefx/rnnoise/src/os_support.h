/* Not in RNNoise 0.2's release, though vec_neon.h includes it (it is Opus's): the one macro it uses from it.
 * Added for Uplink's voicefx (native/voicefx/README.md). */
#ifndef OS_SUPPORT_H
#define OS_SUPPORT_H
#include <string.h>
#define OPUS_CLEAR(dst, n) (memset((dst), 0, (n) * sizeof(*(dst))))
#endif
