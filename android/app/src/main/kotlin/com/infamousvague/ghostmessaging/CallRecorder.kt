package com.infamousvague.ghostmessaging

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.webrtc.AudioTrack
import org.webrtc.AudioTrackSink
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * A call's voices, each to a file of its own, and the MP4 made of them (lib/voice/recorder.dart; Matt, 2026-11-19: "a
 * "record call" plugin where it records the call to an MP4 with multiple named audio tracks").
 *
 * Each voice is written as 48 kHz mono 16-bit, held to the clock: a voice that starts late begins with the silence it
 * missed, one whose sound stops (they left, the playout paused) is filled with silence as it goes on, and one that runs
 * ahead loses a block, so every file has the same length for the same time.
 *
 * - This device's own voice: the block VoiceFx has just cleaned, in flutter_webrtc's capture hook ([mic], from
 *   VoiceFx.process), silence while muted (a muted track's capture goes on).
 * - Someone else's: WebRTC's sink on their decoded track ([AudioTrack.addSink]), before this device's volume for them.
 */
object CallRecorder {
    private const val RATE = 48000
    private val main = Handler(Looper.getMainLooper())

    /** One voice's file of raw samples, and how many it holds so far. */
    private class Track(val file: File) {
        private val out = BufferedOutputStream(FileOutputStream(file), 1 shl 16)
        /** Samples in the file, silence included. */
        var written = 0L
            private set
        private var last = 0f

        /** Writes [frames] samples of [read] at [rate], given in [channels] channels, held to [due] samples. */
        @Synchronized
        fun write(due: Long, frames: Int, rate: Int, channels: Int, read: (frame: Int, channel: Int) -> Float) {
            // Too far behind the clock (it came late, or stopped a while): the missed time as silence.
            if (due - written > RATE / 10) pad(due - frames.toLong() * RATE / rate.coerceAtLeast(1))
            // Too far ahead (its clock runs fast): this block is let go.
            if (written - due > RATE / 10) return
            val n = (frames.toLong() * RATE / rate.coerceAtLeast(1)).toInt()
            val bytes = ByteArray(n * 2)
            for (i in 0 until n) {
                // Linear between the two nearest of its samples, every channel together.
                val pos = i.toDouble() * rate / RATE
                val a = pos.toInt().coerceAtMost(frames - 1)
                val b = (a + 1).coerceAtMost(frames - 1)
                val f = (pos - a).toFloat()
                var v = 0f
                for (c in 0 until channels) v += read(a, c) * (1 - f) + read(b, c) * f
                v /= channels
                val s = v.coerceIn(-32768f, 32767f).toInt()
                bytes[i * 2] = (s and 0xff).toByte()
                bytes[i * 2 + 1] = ((s shr 8) and 0xff).toByte()
                last = v
            }
            out.write(bytes)
            written += n
        }

        /** Silence up to sample [to]; nothing when the file is already that long. */
        @Synchronized
        fun pad(to: Long) {
            val gap = to - written
            if (gap <= 0) return
            val zeros = ByteArray(minOf(gap, RATE.toLong()).toInt() * 2)
            var left = gap
            while (left > 0) {
                val n = minOf(left, zeros.size / 2L).toInt()
                out.write(zeros, 0, n * 2)
                left -= n
            }
            written = to
        }

        @Synchronized
        fun close() = out.close()
    }

    /** When the recording began, on the elapsed-time clock in nanoseconds; 0 while nothing is recorded. */
    @Volatile private var started = 0L
    @Volatile private var mutedNow = false
    @Volatile private var micTrack: Track? = null
    /** Everyone else by Dart's key: their file, and the track and sink tapping it (null once the tap is taken off). */
    private val others = HashMap<String, Pair<Track, Pair<AudioTrack, AudioTrackSink>?>>()

    /** Samples due now, by the clock since the recording began. */
    private fun due(): Long = (SystemClock.elapsedRealtimeNanos() - started) * RATE / 1_000_000_000L

    /**
     * The `ghost/recorder` channel: start (this device's file), muted, add and remove (someone else's voice), stop
     * (the samples in each file) and mux (the files into one MP4, off the main thread).
     */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, "ghost/recorder").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        stopAll()
                        started = SystemClock.elapsedRealtimeNanos()
                        mutedNow = call.argument<Boolean>("muted") == true
                        micTrack = Track(File(call.argument<String>("mic")!!).also { it.parentFile?.mkdirs() })
                        result.success(true)
                    }
                    "muted" -> {
                        mutedNow = call.argument<Boolean>("on") == true
                        result.success(true)
                    }
                    "add" -> result.success(add(call.argument<String>("key")!!, call.argument<String>("track")!!, call.argument<String>("path")!!))
                    "remove" -> {
                        remove(call.argument<String>("key")!!, close = false)
                        result.success(true)
                    }
                    "stop" -> result.success(stopAll())
                    "mux" -> {
                        val out = call.argument<String>("out")!!
                        val inputs = call.argument<List<String>>("inputs")!!
                        thread(name = "ghost-mux") {
                            try {
                                mux(inputs, out)
                                main.post { result.success(out) }
                            } catch (e: Throwable) {
                                main.post { result.error("mux", e.message, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("recorder", e.message, null)
            }
        }
    }

    /** From VoiceFx.process, on WebRTC's audio thread: one block of this device's voice, floats on the 16-bit scale. */
    fun mic(buffer: ByteBuffer, frames: Int, rate: Int) {
        val t = micTrack ?: return
        val b = buffer.duplicate().order(ByteOrder.nativeOrder())
        val muted = mutedNow
        t.write(due(), frames, rate, 1) { i, _ -> if (muted) 0f else b.getFloat(i * 4) }
    }

    /**
     * Taps the remote track [trackId] into [key]'s file at [path]. Someone who comes back (a new track for the same
     * key) goes on in the file they had. False when nothing is being recorded or the track is not a known voice.
     */
    @Synchronized
    private fun add(key: String, trackId: String, path: String): Boolean {
        if (started == 0L) return false
        val track = FlutterWebRTCPlugin.sharedSingleton?.getRemoteTrack(trackId) as? AudioTrack ?: return false
        val had = others[key]
        val file = had?.first ?: Track(File(path))
        // The track they had may be gone with its connection (one made again, GMFB-52): taking the tap off it throws.
        had?.second?.let { (t, s) -> runCatching { t.removeSink(s) } }
        val sink = AudioTrackSink { data, bits, rate, channels, frames, _ ->
            val d = data.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            file.write(due(), frames, rate, channels.coerceAtLeast(1)) { i, c ->
                // Interleaved samples; 8-bit ones are brought up to the 16-bit scale.
                val at = (i * channels + c)
                if (bits == 16) d.getShort(at * 2).toFloat() else (d.get(at).toInt() shl 8).toFloat()
            }
        }
        track.addSink(sink)
        others[key] = file to (track to sink)
        return true
    }

    /** Takes the tap off [key]'s track. The file is kept, so it is filled with silence to the end at the stop. */
    @Synchronized
    private fun remove(key: String, close: Boolean) {
        val had = others[key] ?: return
        had.second?.let { (t, s) -> runCatching { t.removeSink(s) } }
        others[key] = had.first to null
        if (close) had.first.close()
    }

    /** Stops every tap, fills each file to the end with silence, and says how many samples each has. */
    @Synchronized
    private fun stopAll(): Map<String, Long> {
        if (started == 0L) return emptyMap()
        val end = due()
        val counts = HashMap<String, Long>()
        micTrack?.let {
            it.pad(end)
            it.close()
            counts["me"] = it.written
        }
        micTrack = null
        for (key in others.keys.toList()) {
            val t = others[key]!!.first
            remove(key, close = false)
            t.pad(end)
            t.close()
            counts[key] = t.written
        }
        others.clear()
        started = 0L
        return counts
    }

    /**
     * Encodes each of [inputs] (48 kHz mono 16-bit) as AAC and writes them as the tracks of one MP4 at [out], in their
     * order. Each is encoded to a file of its own first: a muxer must be told every track before it is started.
     */
    private fun mux(inputs: List<String>, out: String) {
        val encoded = inputs.map { encode(File(it)) }
        val muxer = MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        try {
            val tracks = encoded.map { muxer.addTrack(it.first) }
            muxer.start()
            // Written in time order across the tracks, so the file is interleaved as a player reads it.
            class Next(val inp: DataInputStream) {
                var size = 0; var pts = 0L; var flags = 0; var bytes = ByteArray(0); var ok = false
                fun read() {
                    ok = try {
                        size = inp.readInt(); pts = inp.readLong(); flags = inp.readInt()
                        if (bytes.size < size) bytes = ByteArray(size)
                        inp.readFully(bytes, 0, size)
                        true
                    } catch (_: java.io.EOFException) { false }
                }
            }
            val nexts = encoded.map { Next(DataInputStream(FileInputStream(it.second).buffered(1 shl 16))).also { n -> n.read() } }
            val info = MediaCodec.BufferInfo()
            try {
                while (true) {
                    var pick = -1
                    for ((i, n) in nexts.withIndex()) if (n.ok && (pick < 0 || n.pts < nexts[pick].pts)) pick = i
                    if (pick < 0) break
                    val n = nexts[pick]
                    info.set(0, n.size, n.pts, n.flags)
                    muxer.writeSampleData(tracks[pick], ByteBuffer.wrap(n.bytes, 0, n.size), info)
                    n.read()
                }
            } finally {
                nexts.forEach { runCatching { it.inp.close() } }
                encoded.forEach { it.second.delete() }
            }
            muxer.stop()
        } finally {
            muxer.release()
        }
    }

    /** [pcm] as AAC-LC frames, each written as its size, time and flags then its bytes; and the format the muxer needs. */
    private fun encode(pcm: File): Pair<MediaFormat, File> {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, RATE, 1).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, 128_000)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()
        val frames = File(pcm.path + ".aac")
        var outFormat: MediaFormat? = null
        val info = MediaCodec.BufferInfo()
        FileInputStream(pcm).buffered(1 shl 16).use { inp ->
            DataOutputStream(FileOutputStream(frames).buffered(1 shl 16)).use { dst ->
                var read = 0L
                var done = false
                var ended = false
                val chunk = ByteArray(4096)
                while (!ended) {
                    if (!done) {
                        val ix = codec.dequeueInputBuffer(10_000)
                        if (ix >= 0) {
                            val ib = codec.getInputBuffer(ix)!!
                            ib.clear()
                            val n = inp.read(chunk, 0, minOf(chunk.size, ib.remaining()))
                            // Two bytes a sample: the time of this chunk in microseconds.
                            val pts = read / 2 * 1_000_000L / RATE
                            if (n <= 0) {
                                codec.queueInputBuffer(ix, 0, 0, pts, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                done = true
                            } else {
                                ib.put(chunk, 0, n)
                                codec.queueInputBuffer(ix, 0, n, pts, 0)
                                read += n
                            }
                        }
                    }
                    val ox = codec.dequeueOutputBuffer(info, 10_000)
                    when {
                        ox == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> outFormat = codec.outputFormat
                        ox >= 0 -> {
                            val ob = codec.getOutputBuffer(ox)!!
                            // The codec's setup bytes are left out: the muxer has them in the format.
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                                val bytes = ByteArray(info.size)
                                ob.position(info.offset)
                                ob.get(bytes)
                                dst.writeInt(info.size)
                                dst.writeLong(info.presentationTimeUs)
                                dst.writeInt(info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM.inv())
                                dst.write(bytes)
                            }
                            codec.releaseOutputBuffer(ox, false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) ended = true
                        }
                    }
                }
            }
        }
        codec.stop()
        codec.release()
        return (outFormat ?: error("the encoder gave no format")) to frames
    }
}
