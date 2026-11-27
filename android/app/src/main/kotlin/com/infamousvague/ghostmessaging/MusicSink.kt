package com.infamousvague.ghostmessaging

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * A player of the phone's own for a circle's music sent without loss (lib/voice/music_sink.dart; Matt, 2026-11-25: "I'd
 * like it to stream lossless audio"): the `ghost/music` channel. What it is given is played as it is, 48 kHz stereo
 * 16-bit, by an AudioTrack as media and not as a call's sound.
 *
 * In a call the phone is in MODE_IN_COMMUNICATION, and there media goes its own way: to a wired or USB headset where one
 * is in, else to the loudspeaker, whatever the call itself is on. While a Bluetooth headset's microphone is in use its
 * music profile (A2DP) is put away, and media would come from the phone's loudspeaker or at the call's quality. So it is
 * played only where the call's own sound goes to a wired or USB headset ([way]), and to that very one; the Opus plays
 * everywhere else.
 */
object MusicSink {
    private const val RATE = 48000

    /** Three seconds: lib/voice/spotify_lossless.dart never has more than two waiting. */
    private const val CAPACITY = RATE * 3

    private val main = Handler(Looper.getMainLooper())

    /** Opening and closing a track waits on the system's sound: never on the main thread. */
    private val work = Executors.newSingleThreadExecutor { Thread(it, "ghost.music.sink") }
    private var player: Player? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        MethodChannel(messenger, "ghost/music").setMethodCallHandler { call, result ->
            when (call.method) {
                "way" -> result.success(runCatching { way(audio, call.argument<String>("device") ?: "") }.getOrDefault(mapOf("to" to "none", "rate" to 0)))
                "open" -> {
                    val device = runCatching { worn(audio) }.getOrNull()
                    val old = player
                    player = null
                    work.execute {
                        old?.close()
                        val made = runCatching { Player(device) }.getOrNull()
                        main.post {
                            player = made
                            result.success(made != null)
                        }
                    }
                }
                "write" -> {
                    val pcm = call.arguments as? ByteArray
                    result.success(if (pcm == null) null else player?.write(pcm))
                }
                "set" -> {
                    player?.gain = if (call.argument<Boolean>("silent") == true) 0f else (call.argument<Double>("volume") ?: 1.0).toFloat().coerceIn(0f, 1f)
                    result.success(null)
                }
                "output" -> {
                    player?.to(runCatching { worn(audio) }.getOrNull())
                    result.success(null)
                }
                "clear" -> {
                    player?.clear()
                    result.success(null)
                }
                "close" -> {
                    val old = player
                    player = null
                    work.execute { old?.close() }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private val WORN = setOf(AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_USB_HEADSET)
    private val BLUETOOTH = setOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET)

    /** The wired or USB headset that is in, if one is. */
    private fun worn(audio: AudioManager): AudioDeviceInfo? = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type in WORN }

    /** Where the call's sound goes, with [device] chosen for it (as flutter_webrtc names them; empty for none chosen). */
    private fun way(audio: AudioManager, device: String): Map<String, Any> {
        val wired = worn(audio) != null
        val to = when (device) {
            "speaker", "earpiece" -> "speakers"
            "bluetooth" -> "call"
            "wired-headset" -> if (wired) "headphones" else "speakers"
            else -> if (Build.VERSION.SDK_INT >= 31) {
                when (audio.communicationDevice?.type) {
                    null -> if (wired) "headphones" else "speakers"
                    in WORN -> "headphones"
                    in BLUETOOTH -> "call"
                    else -> "speakers"
                }
            } else {
                @Suppress("DEPRECATION")
                when {
                    audio.isSpeakerphoneOn -> "speakers"
                    audio.isBluetoothScoOn -> "call"
                    wired -> "headphones"
                    else -> "speakers"
                }
            }
        }
        return mapOf("to" to to, "rate" to AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC))
    }

    /** The track, what waits for it, and the thread that moves one to the other. */
    private class Player(device: AudioDeviceInfo?) {
        private val ring = ShortArray(CAPACITY * 2)
        private var head = 0
        private var count = 0
        private var dry = 0
        private var running = false

        @Volatile
        var gain = 0f
            set(value) {
                field = value
                runCatching { track.setVolume(value) }
            }

        @Volatile
        private var on = true
        private val track: AudioTrack = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO).build())
            .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT), RATE / 10 * 4))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        private val thread = Thread({ run() }, "ghost.music")

        init {
            check(track.state == AudioTrack.STATE_INITIALIZED)
            if (device != null) track.preferredDevice = device
            track.setVolume(0f)
            track.play()
            thread.start()
        }

        fun to(device: AudioDeviceInfo?) {
            runCatching { track.preferredDevice = device }
        }

        /** Takes 16-bit samples, interleaved, low byte first: the frames that wait now, and how often it has run out. */
        fun write(pcm: ByteArray): List<Int> = synchronized(ring) {
            val frames = minOf(pcm.size / 4, CAPACITY - count)
            var at = (head + count) % CAPACITY
            for (i in 0 until frames) {
                ring[at * 2] = ((pcm[i * 4].toInt() and 0xff) or (pcm[i * 4 + 1].toInt() shl 8)).toShort()
                ring[at * 2 + 1] = ((pcm[i * 4 + 2].toInt() and 0xff) or (pcm[i * 4 + 3].toInt() shl 8)).toShort()
                if (++at == CAPACITY) at = 0
            }
            count += frames
            if (frames > 0) running = true
            listOf(count, dry)
        }

        fun clear() = synchronized(ring) {
            head = 0
            count = 0
            running = false
        }

        /** 20 ms at a time, for as long as it is open; silence for what is not there, so the track never stops. */
        private fun run() {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
            val block = ShortArray(RATE / 50 * 2)
            while (on) {
                synchronized(ring) {
                    val n = minOf(block.size / 2, count)
                    for (i in 0 until n) {
                        block[i * 2] = ring[head * 2]
                        block[i * 2 + 1] = ring[head * 2 + 1]
                        if (++head == CAPACITY) head = 0
                    }
                    count -= n
                    block.fill(0, n * 2)
                    if (n * 2 < block.size) {
                        if (running) dry++
                        running = false
                    }
                }
                // It waits until there is room. A track that is gone takes nothing: not asked over and over.
                if (track.write(block, 0, block.size) < 0) Thread.sleep(20)
            }
        }

        fun close() {
            on = false
            runCatching { track.pause() }
            runCatching { track.flush() }
            runCatching { thread.join(500) }
            runCatching { track.release() }
        }
    }
}
