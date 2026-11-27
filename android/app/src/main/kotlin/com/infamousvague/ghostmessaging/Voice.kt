package com.infamousvague.ghostmessaging

import android.content.Context
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File

/**
 * Voice messages (Matt, 2026-11-13: "I also want to have the ability to send audio messages"): recording one with
 * the phone's microphone, and playing one that came or went.
 *
 * A voice message goes as a picture message does, an MMS with one audio part, so every phone can play it and it is
 * not encrypted. It is recorded as AAC in an MPEG-4 file (`audio/mp4`, a `.m4a`), speech at 24 kbit/s, which is
 * about three kilobytes a second: the carrier's limit on a message (often 300 KB to 1 MB) is what bounds how long
 * one can be, and the recorder stops itself at that size ([maxSeconds]).
 *
 * The microphone is open only between [start] and [stop] or [cancel]: while the person is recording, with the app in
 * front. Nothing listens otherwise.
 */
object Voice {
    private const val TAG = "GhostMessaging"
    const val BIT_RATE = 24_000
    private const val SAMPLE_RATE = 16_000

    private var recorder: MediaRecorder? = null
    private var file: File? = null
    private var began = 0L
    private var full = 0L

    /** How many seconds fit in [budget] bytes at the rate recorded at, with room for the file's own headers. */
    fun maxSeconds(budget: Long): Int = (((budget - 6 * 1024) * 8) / (BIT_RATE + 1_500)).toInt().coerceIn(5, 600)

    /** A recording's file name, which is all that says it was made here: `voice-20261113-194502.m4a`. */
    fun fileName(now: Long = System.currentTimeMillis()): String =
        "voice-" + java.text.SimpleDateFormat("yyyyMMdd-HHmmss", java.util.Locale.US).format(java.util.Date(now)) + ".m4a"

    val recording: Boolean get() = recorder != null

    /** Starts recording into the app's own cache; stops by itself at [budget] bytes. Returns how long that is, in seconds. */
    @Synchronized
    fun start(context: Context, budget: Long): Int {
        cancel()
        val dir = File(context.cacheDir, "voice").apply { mkdirs() }
        // Recordings that were never sent do not pile up.
        dir.listFiles()?.forEach { if (System.currentTimeMillis() - it.lastModified() > 60 * 60 * 1000L) it.delete() }
        val out = File(dir, fileName())
        @Suppress("DEPRECATION")
        val r = if (Build.VERSION.SDK_INT >= 31) MediaRecorder(context) else MediaRecorder()
        try {
            r.setAudioSource(MediaRecorder.AudioSource.MIC)
            r.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            r.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            r.setAudioChannels(1)
            r.setAudioSamplingRate(SAMPLE_RATE)
            r.setAudioEncodingBitRate(BIT_RATE)
            r.setMaxFileSize(budget)
            r.setOutputFile(out.absolutePath)
            // The file is as big as a message may be: it records no more, and the screen is told so.
            r.setOnInfoListener { _, what, _ ->
                if (what == MediaRecorder.MEDIA_RECORDER_INFO_MAX_FILESIZE_REACHED && full == 0L) {
                    full = System.currentTimeMillis()
                    listener?.invoke(mapOf("type" to "voiceFull"))
                }
            }
            r.prepare()
            r.start()
        } catch (e: Exception) {
            try { r.release() } catch (_: Exception) {}
            out.delete()
            throw IllegalStateException("The microphone could not be started", e)
        }
        recorder = r
        file = out
        began = System.currentTimeMillis()
        full = 0L
        return maxSeconds(budget)
    }

    /** How loud it is right now, 0 to 1: for the level shown while recording. */
    @Synchronized
    fun level(): Double = try { ((recorder?.maxAmplitude ?: 0) / 32767.0).coerceIn(0.0, 1.0) } catch (_: Exception) { 0.0 }

    /** Stops recording: the file and how long it runs, or null where there is nothing worth keeping (under a second). */
    @Synchronized
    fun stop(): Pair<File, Long>? {
        val r = recorder ?: return null
        val out = file
        recorder = null
        file = null
        val length = (if (full > 0L) full else System.currentTimeMillis()) - began
        val ok = try { r.stop(); true } catch (e: Exception) { Log.w(TAG, "voice stop", e); false }
        try { r.release() } catch (_: Exception) {}
        if (!ok || out == null || length < 900 || out.length() < 512) { out?.delete(); return null }
        return out to length
    }

    /** Ends the recording and keeps nothing of it. */
    @Synchronized
    fun cancel() {
        val r = recorder ?: return
        recorder = null
        try { r.stop() } catch (_: Exception) {}
        try { r.release() } catch (_: Exception) {}
        file?.delete()
        file = null
    }

    // --- playing ------------------------------------------------------------------------------------------------------

    private val main by lazy { Handler(Looper.getMainLooper()) }
    private var player: MediaPlayer? = null
    private var playingPart = -1L

    /** Told where the one playing has got to: its part, the position and the whole in milliseconds, whether it plays. */
    @Volatile var listener: ((Map<String, Any?>) -> Unit)? = null

    private val tick = object : Runnable {
        override fun run() {
            val p = player ?: return
            say(playing = try { p.isPlaying } catch (_: Exception) { false })
            main.postDelayed(this, 120)
        }
    }

    /** Tells the [listener] where the sound has got to; one that [ended] is said to be back at its start. */
    private fun say(playing: Boolean, ended: Boolean = false) {
        val p = player
        val (position, duration) = try { if (p == null || ended) 0 to (p?.duration ?: 0) else p.currentPosition to p.duration } catch (_: Exception) { 0 to 0 }
        listener?.invoke(mapOf("type" to "voice", "part" to playingPart, "position" to position, "duration" to duration, "playing" to playing))
    }

    /**
     * Where the audio part [part] is: an MMS part, or, for one from Google Messages' connection (GmWeb), a file in the
     * cache it is brought down to first. Blocks for that: never on the main thread.
     */
    private fun source(context: Context, part: Long): Uri? =
        if (GmWeb.isPart(part)) GmWeb.file(context, part)?.let { Uri.fromFile(it) } else Uri.parse("content://mms/part/$part")

    /** Plays the audio part [part] of a picture message from its start (or goes on, if it was paused); stops any other. */
    fun play(context: Context, part: Long) {
        if (GmWeb.isPart(part) && playingPart != part) {
            // From Google Messages' connection: brought down first, off the main thread, then played.
            Thread { val uri = source(context, part); main.post { playFrom(context, part, uri) } }.start()
            return
        }
        main.post { playFrom(context, part, if (GmWeb.isPart(part)) null else Uri.parse("content://mms/part/$part")) }
    }

    /** On the main thread: goes on with [part] if it is the one paused, else plays [uri]; a null one is said to end. */
    private fun playFrom(context: Context, part: Long, uri: Uri?) {
        val had = player
        if (had != null && playingPart == part) {
            try { had.start() } catch (_: Exception) {}
            main.removeCallbacks(tick); main.post(tick)
            return
        }
        halt()
        try {
            val p = MediaPlayer()
            p.setDataSource(context.applicationContext, uri ?: throw IllegalStateException("the audio could not be brought down"))
            p.setOnCompletionListener {
                say(playing = false, ended = true)
                halt()
            }
            p.prepare()
            player = p
            playingPart = part
            p.start()
            main.post(tick)
        } catch (e: Exception) {
            Log.w(TAG, "voice play", e)
            playingPart = part
            say(playing = false, ended = true)
            halt()
        }
    }

    /** Holds the sound where it is; [play] with the same part goes on from there. */
    fun pause() = main.post {
        try { player?.pause() } catch (_: Exception) {}
        main.removeCallbacks(tick)
        if (player != null) say(playing = false)
    }

    /** Stops whatever is playing and lets the player go. */
    fun halt() {
        main.removeCallbacks(tick)
        val p = player ?: return
        player = null
        try { p.stop() } catch (_: Exception) {}
        try { p.release() } catch (_: Exception) {}
    }

    /** How long the audio part [part] runs, in milliseconds; 0 where it cannot be read. */
    fun length(context: Context, part: Long): Long {
        val m = MediaMetadataRetriever()
        return try {
            m.setDataSource(context.applicationContext, source(context, part) ?: return 0L)
            m.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (_: Exception) { 0L } finally { try { m.release() } catch (_: Exception) {} }
    }
}
