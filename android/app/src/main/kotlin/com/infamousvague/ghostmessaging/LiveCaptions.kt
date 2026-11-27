package com.infamousvague.ghostmessaging

import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import kotlin.concurrent.thread

/**
 * This device's own voice in a call, written out as it is said, for the call's captions (lib/voice/captions.dart; Matt,
 * 2026-11-19: "Live captions"). The voice VoiceFx has just cleaned is handed here ([feed], on WebRTC's audio thread),
 * brought to 16 kHz and passed through a pipe to the phone's on-device speech recognition, in one long segmented
 * session; what it hears goes to Dart as it comes (a line still being said) and as each line ends. Nothing leaves the
 * phone but the words, which Dart says to the call.
 */
object LiveCaptions {
    private const val RATE = 16000
    private val main = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var context: Context? = null

    @Volatile private var on = false
    @Volatile private var muted = false
    private var language: String? = null
    private var recognizer: SpeechRecognizer? = null
    /** The recognizer reads one end ([0]); [stream] writes the other. Blocks wait in [queue] for the [writer]. */
    private var pipe: Array<ParcelFileDescriptor>? = null
    @Volatile private var stream: FileOutputStream? = null
    private val queue = LinkedBlockingQueue<ByteArray>()
    private var writer: Thread? = null

    /** The `ghost/captions` channel: available, start (in a language), stop and muted; `heard` goes back to Dart. */
    fun register(context: Context, messenger: BinaryMessenger) {
        this.context = context
        val ch = MethodChannel(messenger, "ghost/captions")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(Scribe.available(context))
                "start" -> {
                    language = call.argument<String>("language")
                    result.success(start())
                }
                "stop" -> {
                    stop()
                    result.success(true)
                }
                "muted" -> {
                    muted = call.argument<Boolean>("on") == true
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Turns captions on: false where the phone has no on-device recognition. */
    private fun start(): Boolean {
        val ctx = context ?: return false
        if (!Scribe.available(ctx)) return false
        if (on) return true
        on = true
        queue.clear()
        // The pipe is written on a thread of its own: a write that waits must never hold WebRTC's audio thread.
        writer = thread(name = "ghost-captions") {
            while (on) {
                val b = runCatching { queue.poll(200, java.util.concurrent.TimeUnit.MILLISECONDS) }.getOrNull() ?: continue
                val out = stream ?: continue
                runCatching { out.write(b) }
            }
        }
        listen()
        return true
    }

    private fun stop() {
        on = false
        main.post {
            recognizer?.destroy()
            recognizer = null
            closePipe()
        }
    }

    private fun closePipe() {
        stream = null
        pipe?.forEach { runCatching { it.close() } }
        pipe = null
    }

    /** A segmented session reading the pipe; started again whenever it ends while captions are on. */
    private fun listen() {
        main.post { listenNow() }
    }

    /** On the main thread, as a recognizer must be made and used: a new pipe and a new recognizer reading it. */
    private fun listenNow() {
        val ctx = context ?: return
        if (!on) return
        recognizer?.destroy()
        closePipe()
        val p = ParcelFileDescriptor.createPipe()
        pipe = p
        stream = FileOutputStream(p[1].fileDescriptor)
        val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            fun words(b: Bundle?) = b?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.takeIf { it.isNotBlank() }
            fun again() {
                if (on) main.postDelayed({ listen() }, 300)
            }
            override fun onPartialResults(partialResults: Bundle?) {
                words(partialResults)?.let { say(it, false) }
            }
            override fun onSegmentResults(segmentResults: Bundle) {
                words(segmentResults)?.let { say(it, true) }
            }
            override fun onResults(results: Bundle?) {
                words(results)?.let { say(it, true) }
                again()
            }
            override fun onEndOfSegmentedSession() = again()
            override fun onError(error: Int) = again()
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            language?.let { putExtra(RecognizerIntent.EXTRA_LANGUAGE, it) }
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_SEGMENTED_SESSION, RecognizerIntent.EXTRA_AUDIO_SOURCE)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, p[0])
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, RATE)
            putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
        })
    }

    /** Tells Dart what was heard: [done] false for a line still being said, true once it has ended. */
    private fun say(words: String, done: Boolean) = main.post {
        channel?.invokeMethod("heard", mapOf("text" to words, "done" to done))
    }

    /** From VoiceFx.process, on WebRTC's audio thread: one block of this device's voice, floats on the 16-bit scale. */
    fun feed(buffer: ByteBuffer, frames: Int, rate: Int) {
        if (!on || frames <= 0 || rate <= 0) return
        // Held to a few seconds: a recognizer that stops reading never fills the memory.
        if (queue.size > 300) return
        val b = buffer.duplicate().order(ByteOrder.nativeOrder())
        val n = (frames.toLong() * RATE / rate).toInt()
        val out = ByteArray(n * 2)
        val silent = muted
        // Down to 16 kHz by taking the nearest earlier sample; silence while muted, so the session goes on.
        for (i in 0 until n) {
            val at = (i.toLong() * rate / RATE).toInt().coerceAtMost(frames - 1)
            val v = if (silent) 0 else b.getFloat(at * 4).coerceIn(-32768f, 32767f).toInt()
            out[i * 2] = (v and 0xff).toByte()
            out[i * 2 + 1] = ((v shr 8) and 0xff).toByte()
        }
        queue.offer(out)
    }
}
