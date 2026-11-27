package com.infamousvague.ghostmessaging

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap

/**
 * What is done to the microphone before Opus, on the phone (lib/voice/voice_fx.dart; Matt, 2026-11-15: "build in like
 * krisp noise supression or other fancy noise suppression tools, add a volume slider for input ... with
 * overboosting"): RNNoise and the gain from native/voicefx, run in flutter_webrtc's capture post-processing hook,
 * on WebRTC's audio thread. DeepFilterNet is the computers'; the phone answers RNNoise alone.
 *
 * The hook exists once flutter_webrtc has made its PeerConnectionFactory, so [attach] is tried at every configure
 * (the Dart side configures again once the microphone is open).
 *
 * It also says how loud each voice in a call is (`levels`; lib/voice/rtc.dart draws the ripple on a face from it):
 * the microphone's from this hook, and everyone else's from a tap on their decoded track ([hear]). The app used to
 * ask WebRTC for a connection's whole statistics seven times a second for each person in the call just to read one
 * number from them, which was about a third of what a quiet call cost the phone (Matt, 2026-11-24: "please see what
 * you can do about the high CPU usage"; docs/performance-audit.md, "Calls").
 */
object VoiceFx : AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private val handle: Long by lazy {
        System.loadLibrary("voicefx")
        nativeCreate()
    }
    @Volatile private var rate = 48000
    private var attached: AudioProcessingAdapter? = null

    /** The `ghost/voicefx` channel: modes (what this build can do) and configure (the mode and the gain). */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "ghost/voicefx").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "modes" -> {
                        val bits = nativeModes(handle)
                        result.success(listOfNotNull(if (bits and (1 shl 1) != 0) "rnnoise" else null, if (bits and (1 shl 2) != 0) "deepfilter" else null, "live", "effects", "levels"))
                    }
                    // Live voice changing (lib/voice/live_changer.dart): what was said, taken; the changed voice, fed.
                    // A voice effect made here as it is said (lib/voice/live_changer.dart, native/voicefx voicefx_effect).
                    "effect" -> {
                        nativeEffect(handle, call.argument<String>("name") ?: "none")
                        result.success(attach())
                    }
                    "live" -> {
                        nativeLive(handle, call.argument<Boolean>("on") == true)
                        result.success(attach())
                    }
                    "take" -> result.success(nativeTake(handle, call.argument<Int>("most") ?: 32000))
                    "feed" -> {
                        nativeFeed(handle, call.argument<ByteArray>("pcm") ?: ByteArray(0), call.argument<Int>("rate") ?: 24000)
                        result.success(nativeQueued(handle))
                    }
                    "queued" -> result.success(nativeQueued(handle))
                    // How loud each voice is (lib/voice/rtc.dart): someone's track tapped, let go of, and what each
                    // has been at its loudest since last asked.
                    "hear" -> result.success(hear(call.argument<String>("key") ?: "", call.argument<String>("track") ?: ""))
                    "unhear" -> { unhear(call.argument<String>("key") ?: ""); result.success(null) }
                    "levels" -> result.success(levels())
                    "configure" -> {
                        val mode = when (call.argument<String>("mode")) { "rnnoise" -> 1; "deepfilter" -> 2; else -> 0 }
                        val gain = (call.argument<Double>("gain") ?: 1.0).toFloat()
                        nativeConfigure(handle, mode, gain)
                        result.success(attach())
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("voicefx", e.message, null)
            }
        }
    }

    /** Into flutter_webrtc's capture hook, once; true once it is in. */
    @Synchronized
    private fun attach(): Boolean {
        if (attached != null) return true
        val hook = runCatching { FlutterWebRTCPlugin.sharedSingleton?.audioProcessingController?.capturePostProcessing }.getOrNull() ?: return false
        hook.addProcessor(this)
        attached = hook
        return true
    }

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        rate = sampleRateHz
    }

    override fun reset(newRate: Int) {
        rate = newRate
    }

    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        // One block of 10 ms: its rate is its length (webrtc-sdk's ExternalAudioProcessor says the same).
        // What comes back is the block's loudest sample as it is sent, kept for when `levels` is next asked.
        val loudest = nativeProcess(handle, buffer, numFrames, numFrames * 100)
        if (loudest > micPeak) micPeak = loudest
        micHeard = true
        // The voice as it is sent, for a recording of the call being made here (CallRecorder.kt).
        CallRecorder.mic(buffer, numFrames, numFrames * 100)
        // And for the call's captions, where they are on (LiveCaptions.kt).
        LiveCaptions.feed(buffer, numFrames, numFrames * 100)
    }

    // --- how loud each voice is ---------------------------------------------------------------------------------------

    /** The loudest the microphone has been since `levels` was last asked, 0 to 1: WebRTC's audio thread writes it. */
    @Volatile private var micPeak = 0f

    /** Whether the hook has been handed any of the microphone since `levels` was last asked: without it nothing is said
     *  for the microphone, and the Dart side reads it its old way. */
    @Volatile private var micHeard = false

    /** Someone else's voice, tapped: the loudest it has been since last asked, and what to take the tap off. */
    private class Heard {
        @Volatile var peak = 0f
        var track: AudioTrack? = null
        var sink: AudioTrackSink? = null
    }

    private val heard = ConcurrentHashMap<String, Heard>()

    /**
     * Taps [trackId], someone's decoded voice (before this device's volume for them), under [key]: from then on
     * [levels] says how loud it has been. False where the track is not a voice WebRTC holds now (the Dart side then
     * reads that person's level from the connection's statistics, as before). A block is 10 ms; every fourth sample is
     * looked at, which is plenty for how loud a voice is and a quarter of the work. The native library is loaded by
     * then ([handle]): a call's microphone is configured before anyone is heard.
     */
    @Synchronized
    private fun hear(key: String, trackId: String): Boolean {
        unhear(key)
        if (key.isEmpty() || trackId.isEmpty()) return false
        // The native library, which the tap reads the samples with, loaded before any tap can be called.
        if (runCatching { handle }.isFailure) return false
        val track = runCatching { FlutterWebRTCPlugin.sharedSingleton?.getRemoteTrack(trackId) as? AudioTrack }.getOrNull() ?: return false
        val h = Heard()
        val sink = AudioTrackSink { data, bits, _, channels, frames, _ ->
            val step = channels.coerceAtLeast(1) * 4
            val samples = frames * channels.coerceAtLeast(1)
            val p = if (bits == 16 && data.isDirect) {
                // WebRTC's own buffer, read where it lies in one call: read from here a byte at a time, each byte was a
                // call into the runtime, 24,000 of them a second for every voice.
                nativePeak16(data, samples, step)
            } else {
                // Any other buffer (none is handed over now): 16-bit little-endian samples a byte at a time, 8-bit ones
                // brought up to the 16-bit scale.
                var loudest = 0
                var i = 0
                val wide = bits == 16
                val last = (if (wide) data.limit() / 2 else data.limit()).coerceAtMost(samples)
                while (i < last) {
                    val v = if (wide) (data.get(i * 2).toInt() and 0xff) or (data.get(i * 2 + 1).toInt() shl 8) else data.get(i).toInt() shl 8
                    val m = if (v < 0) -v else v
                    if (m > loudest) loudest = m
                    i += step
                }
                loudest / 32768f
            }
            if (p > h.peak) h.peak = p
        }
        return try {
            track.addSink(sink)
            h.track = track
            h.sink = sink
            heard[key] = h
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** Takes the tap off [key]'s voice. The track may be gone with its connection: taking a tap off it throws. */
    @Synchronized
    private fun unhear(key: String) {
        val h = heard.remove(key) ?: return
        val track = h.track
        val sink = h.sink
        if (track != null && sink != null) runCatching { track.removeSink(sink) }
    }

    /** `me` for the microphone (only where the hook has been handed some of it) and each tapped voice by its key: the
     *  loudest each has been since last asked, 0 to 1. */
    private fun levels(): Map<String, Double> {
        val out = HashMap<String, Double>()
        if (micHeard) {
            out["me"] = micPeak.toDouble().coerceIn(0.0, 1.0)
            micPeak = 0f
            micHeard = false
        }
        for ((key, h) in heard) {
            out[key] = h.peak.toDouble().coerceIn(0.0, 1.0)
            h.peak = 0f
        }
        return out
    }

    private external fun nativeCreate(): Long
    private external fun nativeModes(fx: Long): Int
    private external fun nativeConfigure(fx: Long, mode: Int, gain: Float)
    private external fun nativeProcess(fx: Long, buffer: ByteBuffer, frames: Int, rate: Int): Float
    private external fun nativePeak16(buffer: ByteBuffer, samples: Int, step: Int): Float
    private external fun nativeEffect(fx: Long, name: String)
    private external fun nativeLive(fx: Long, on: Boolean)
    private external fun nativeTake(fx: Long, most: Int): ByteArray
    private external fun nativeFeed(fx: Long, pcm: ByteArray, rate: Int)
    private external fun nativeQueued(fx: Long): Int
}
