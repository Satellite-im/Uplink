package com.infamousvague.ghostmessaging

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Words from a recorded call, on the phone (lib/voice/scribe.dart; Matt, 2026-11-19: "Start with the recording plugin,
 * then scribe"): one track of a recording's MP4 (one person's voice) decoded, cut where they pause, and each stretch
 * heard by the phone's own on-device speech recognition. Each stretch's place in the track is known from the cut, so
 * every line has its time, and the track says whose voice it is. Nothing leaves the phone.
 *
 * Needs Android 13 (speech recognition reading audio it is handed) and the phone's on-device recognizer.
 */
object Scribe {
    private const val RATE = 16000

    /** The rate a recording is made at, and opened in the mixer at. */
    private const val MIX_RATE = 48000
    private val main = Handler(Looper.getMainLooper())

    /** Whether this phone can do it: Android 13 and an on-device recognizer. Live captions ask the same question. */
    fun available(context: Context): Boolean =
        Build.VERSION.SDK_INT >= 33 && runCatching { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) }.getOrDefault(false)

    /** The `ghost/scribe` channel: available, and transcribe (one track of a file, on a thread of its own). */
    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "ghost/scribe").setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(available(context))
                // One track of a recording as 48 kHz mono 16-bit samples, written to a file, for the recording opened
                // in the mixer (lib/voice/recording_playback.dart).
                "decode" -> {
                    val path = call.argument<String>("path")!!
                    val track = call.argument<Int>("track") ?: 0
                    val out = call.argument<String>("out")!!
                    thread(name = "ghost-decode") {
                        try {
                            val pcm = decode(path, track, MIX_RATE)
                            val bytes = ByteArray(pcm.size * 2)
                            for (i in pcm.indices) {
                                bytes[i * 2] = (pcm[i].toInt() and 0xff).toByte()
                                bytes[i * 2 + 1] = (pcm[i].toInt() shr 8).toByte()
                            }
                            FileOutputStream(out).use { it.write(bytes) }
                            main.post { result.success(mapOf("rate" to MIX_RATE, "channels" to 1, "samples" to pcm.size)) }
                        } catch (e: Throwable) {
                            main.post { result.error("decode", e.message, null) }
                        }
                    }
                }
                "transcribe" -> {
                    val path = call.argument<String>("path")!!
                    val track = call.argument<Int>("track") ?: 0
                    val language = call.argument<String>("language")
                    if (!available(context)) return@setMethodCallHandler result.error("unavailable", "This phone has no on-device speech recognition", null)
                    thread(name = "ghost-scribe") {
                        try {
                            val lines = transcribe(context, path, track, language)
                            main.post { result.success(lines) }
                        } catch (e: Throwable) {
                            main.post { result.error("scribe", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** The stretches of [track] in [path] with words in them, as `{start, end, text}` (milliseconds). */
    private fun transcribe(context: Context, path: String, track: Int, language: String?): List<Map<String, Any>> {
        val pcm = decode(path, track)
        val out = ArrayList<Map<String, Any>>()
        for ((from, to) in stretches(pcm)) {
            val text = recognize(context, pcm, from, to, language) ?: continue
            if (text.isBlank()) continue
            out.add(mapOf("start" to from * 1000L / RATE, "end" to to * 1000L / RATE, "text" to text.trim()))
        }
        return out
    }

    /** [track] of [path] as mono 16-bit samples at [toRate] (16 kHz for speech). */
    private fun decode(path: String, track: Int, toRate: Int = RATE): ShortArray {
        val ex = MediaExtractor()
        ex.setDataSource(path)
        ex.selectTrack(track)
        val format = ex.getTrackFormat(track)
        val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        codec.configure(format, null, null, 0)
        codec.start()
        var rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val raw = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var inDone = false
        var outDone = false
        while (!outDone) {
            if (!inDone) {
                val ix = codec.dequeueInputBuffer(10_000)
                if (ix >= 0) {
                    val n = ex.readSampleData(codec.getInputBuffer(ix)!!, 0)
                    if (n < 0) {
                        codec.queueInputBuffer(ix, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inDone = true
                    } else {
                        codec.queueInputBuffer(ix, 0, n, ex.sampleTime, 0)
                        ex.advance()
                    }
                }
            }
            val ox = codec.dequeueOutputBuffer(info, 10_000)
            if (ox == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                rate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            } else if (ox >= 0) {
                val b = codec.getOutputBuffer(ox)!!
                val bytes = ByteArray(info.size)
                b.position(info.offset)
                b.get(bytes)
                raw.write(bytes)
                codec.releaseOutputBuffer(ox, false)
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outDone = true
            }
        }
        codec.stop()
        codec.release()
        ex.release()
        // To 16 kHz mono: the nearest earlier frame for each sample, its channels averaged.
        val all = raw.toByteArray()
        val frames = all.size / 2 / channels.coerceAtLeast(1)
        val n = (frames.toLong() * toRate / rate).toInt()
        val out = ShortArray(n)
        for (i in 0 until n) {
            val at = (i.toLong() * rate / toRate).toInt().coerceAtMost(frames - 1)
            var v = 0
            for (c in 0 until channels) {
                val k = (at * channels + c) * 2
                v += (all[k].toInt() and 0xff) or (all[k + 1].toInt() shl 8)
            }
            out[i] = (v / channels).toShort()
        }
        return out
    }

    /**
     * Where someone is talking: 30 ms blocks louder than the track's quiet, joined across pauses under 0.7 s, each
     * stretch at most 25 s (a recognizer hears one utterance at a time) and at least 0.3 s.
     */
    fun stretches(pcm: ShortArray): List<Pair<Int, Int>> {
        val block = RATE * 30 / 1000
        val levels = (0 until pcm.size / block).map { b ->
            var sum = 0.0
            for (i in b * block until (b + 1) * block) sum += pcm[i].toDouble() * pcm[i]
            Math.sqrt(sum / block)
        }
        if (levels.isEmpty()) return emptyList()
        // The track's quiet is its tenth-quietest block in a hundred; talking is three times that, and never under 300.
        val quiet = levels.sorted()[levels.size / 10]
        val loud = maxOf(300.0, quiet * 3)
        val out = ArrayList<Pair<Int, Int>>()
        var start = -1
        var lastLoud = -1
        val gap = 700 / 30
        val most = 25_000 / 30
        for ((b, l) in levels.withIndex()) {
            if (l >= loud) {
                if (start < 0) start = b
                lastLoud = b
            }
            if (start >= 0 && (b - lastLoud > gap || b - start >= most || b == levels.lastIndex)) {
                val end = lastLoud + 1
                // Kept from ten blocks (0.3 s) up, with five blocks (0.15 s) of room either side.
                if (end - start >= 10) out.add(maxOf(0, start - 5) * block to minOf(levels.size, end + 5) * block)
                start = -1
            }
        }
        return out
    }

    /** What the on-device recognizer hears in [pcm] from [from] to [to]; null where it heard nothing. */
    private fun recognize(context: Context, pcm: ShortArray, from: Int, to: Int, language: String?): String? {
        val pipe = ParcelFileDescriptor.createPipe()
        val latch = CountDownLatch(1)
        var heard: String? = null
        var recognizer: SpeechRecognizer? = null
        main.post {
            val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
            recognizer = r
            r.setRecognitionListener(object : RecognitionListener {
                // What it heard: the final results where they come with words, else what came as segments or as the
                // newest partial result (an on-device engine may give its words only those ways).
                val segments = ArrayList<String>()
                var partial: String? = null
                fun words(b: Bundle?) = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.takeIf { it.isNotBlank() }
                fun done() {
                    if (heard == null) heard = segments.joinToString(" ").ifBlank { null } ?: partial
                    latch.countDown()
                }
                override fun onResults(results: Bundle?) {
                    heard = words(results)
                    done()
                }
                override fun onSegmentResults(segmentResults: Bundle) {
                    words(segmentResults)?.let { segments.add(it) }
                }
                override fun onEndOfSegmentedSession() = done()
                override fun onPartialResults(partialResults: Bundle?) {
                    words(partialResults)?.let { partial = it }
                }
                override fun onError(error: Int) {
                    done()
                }
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                if (language != null) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, pipe[0])
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
            }
            r.startListening(intent)
        }
        // The stretch, then a little silence so the recognizer knows it has ended; then the pipe closed.
        FileOutputStream(pipe[1].fileDescriptor).use { out ->
            val bytes = ByteArray((to - from + RATE / 2) * 2)
            for (i in from until to) {
                val v = pcm[i].toInt()
                bytes[(i - from) * 2] = (v and 0xff).toByte()
                bytes[(i - from) * 2 + 1] = ((v shr 8) and 0xff).toByte()
            }
            runCatching { out.write(bytes) }
        }
        runCatching { pipe[1].close() }
        // A recognizer that never answers is given up on after a minute, with whatever it had said.
        latch.await(60, TimeUnit.SECONDS)
        main.post { recognizer?.destroy() }
        runCatching { pipe[0].close() }
        return heard
    }
}
