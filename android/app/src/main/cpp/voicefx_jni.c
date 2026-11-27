/* VoiceFx.kt's native half: voicefx (native/voicefx) over WebRTC's capture buffer, which is a direct ByteBuffer of
 * floats on the 16-bit scale (webrtc-sdk's ExternalAudioProcessingJni). */
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>

#include "voicefx.h"

#define FN(name) Java_com_infamousvague_ghostmessaging_VoiceFx_##name

JNIEXPORT jlong JNICALL FN(nativeCreate)(JNIEnv *env, jobject self) { return (jlong)(intptr_t)voicefx_create(); }

JNIEXPORT jint JNICALL FN(nativeModes)(JNIEnv *env, jobject self, jlong fx) { return voicefx_modes((VoiceFx *)(intptr_t)fx); }

JNIEXPORT void JNICALL FN(nativeConfigure)(JNIEnv *env, jobject self, jlong fx, jint mode, jfloat gain) {
  voicefx_configure((VoiceFx *)(intptr_t)fx, mode, gain);
}

/* Runs voicefx over one block and answers its loudest sample as it is sent, 0 to 1: how loud the microphone is, for
 * the ripple on this device's own face (VoiceFx.kt `levels`), read here where the samples already are. */
JNIEXPORT jfloat JNICALL FN(nativeProcess)(JNIEnv *env, jobject self, jlong fx, jobject buffer, jint frames, jint rate) {
  float *samples = (float *)(*env)->GetDirectBufferAddress(env, buffer);
  jlong bytes = (*env)->GetDirectBufferCapacity(env, buffer);
  if (!samples || bytes < (jlong)frames * (jlong)sizeof(float)) return 0;
  voicefx_process((VoiceFx *)(intptr_t)fx, samples, frames, rate);
  float loudest = 0;
  for (jint i = 0; i < frames; i++) {
    float a = samples[i] < 0 ? -samples[i] : samples[i];
    if (a > loudest) loudest = a;
  }
  loudest /= 32768.0f;
  return loudest > 1 ? 1 : loudest;
}

/* The loudest of the 16-bit samples in a direct buffer, 0 to 1, looking at every [step]th: someone's decoded voice,
 * handed to a tap 100 times a second (VoiceFx.kt hear). */
JNIEXPORT jfloat JNICALL FN(nativePeak16)(JNIEnv *env, jobject self, jobject buffer, jint samples, jint step) {
  const int16_t *s = (const int16_t *)(*env)->GetDirectBufferAddress(env, buffer);
  jlong bytes = (*env)->GetDirectBufferCapacity(env, buffer);
  if (!s || step < 1 || samples < 1) return 0;
  if ((jlong)samples * 2 > bytes) samples = (jint)(bytes / 2);
  int loudest = 0;
  for (jint i = 0; i < samples; i += step) {
    int a = s[i] < 0 ? -(int)s[i] : s[i];
    if (a > loudest) loudest = a;
  }
  return (float)loudest / 32768.0f;
}

/* The voice effect by its name (voicefx_effect_id); none for null or a name that is no effect's. */
JNIEXPORT void JNICALL FN(nativeEffect)(JNIEnv *env, jobject self, jlong fx, jstring name) {
  const char *n = name ? (*env)->GetStringUTFChars(env, name, NULL) : NULL;
  voicefx_effect((VoiceFx *)(intptr_t)fx, voicefx_effect_id(n));
  if (n) (*env)->ReleaseStringUTFChars(env, name, n);
}
JNIEXPORT void JNICALL FN(nativeLive)(JNIEnv *env, jobject self, jlong fx, jboolean on) { voicefx_live((VoiceFx *)(intptr_t)fx, on ? 1 : 0); }

/* What was said since last asked: 16-bit little-endian samples at 16 kHz, as bytes. */
JNIEXPORT jbyteArray JNICALL FN(nativeTake)(JNIEnv *env, jobject self, jlong fx, jint most) {
  if (most <= 0) most = 1;
  int16_t *buf = malloc(sizeof(int16_t) * (size_t)most);
  int n = buf ? voicefx_take((VoiceFx *)(intptr_t)fx, buf, most) : 0;
  jbyteArray out = (*env)->NewByteArray(env, n * 2);
  if (out && n > 0) (*env)->SetByteArrayRegion(env, out, 0, n * 2, (const jbyte *)buf);
  free(buf);
  return out;
}

/* The changed voice to play into the call: 16-bit little-endian samples at [rate], as bytes. Read, never written
 * back (JNI_ABORT). */
JNIEXPORT void JNICALL FN(nativeFeed)(JNIEnv *env, jobject self, jlong fx, jbyteArray pcm, jint rate) {
  jsize bytes = (*env)->GetArrayLength(env, pcm);
  if (bytes < 2) return;
  jbyte *data = (*env)->GetByteArrayElements(env, pcm, NULL);
  if (!data) return;
  voicefx_feed((VoiceFx *)(intptr_t)fx, (const int16_t *)data, bytes / 2, rate);
  (*env)->ReleaseByteArrayElements(env, pcm, data, JNI_ABORT);
}

JNIEXPORT jint JNICALL FN(nativeQueued)(JNIEnv *env, jobject self, jlong fx) { return voicefx_queued_ms((VoiceFx *)(intptr_t)fx); }
