package com.infamousvague.ghostmessaging

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * The app's interface sounds on the phone (lib/sounds.dart): a sound's WAV, already at the loudness wanted, played
 * once or over and over (ringing). Played as the sounds of an app's own screen (sonification), so the phone's
 * silent and Do Not Disturb modes and its media volume rule them; a ring plays as a ringtone does.
 */
object Sounds {
    private var app: Context? = null
    /** The ring playing over and over, if one is: the only sound [stop] ends. */
    private var looping: MediaPlayer? = null
    private var counter = 0

    /** The `ghost/sound` channel: play (a WAV's bytes, once or looped) and stop. A sound that fails is not heard. */
    fun register(context: Context, messenger: BinaryMessenger) {
        app = context.applicationContext
        MethodChannel(messenger, "ghost/sound").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "play" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        if (bytes != null) play(context.applicationContext, bytes, call.argument<Boolean>("loop") == true)
                        result.success(null)
                    }
                    "stop" -> { stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.success(null)
            }
        }
    }

    /** Plays the WAV in [bytes]; a looped one takes the place of the ring before it. */
    private fun play(context: Context, bytes: ByteArray, loop: Boolean) {
        // A file of its own for each sound playing, so two at once do not write over each other; a handful reused.
        val dir = File(context.cacheDir, "sounds").apply { mkdirs() }
        val file = File(dir, "play-${counter++ % 6}.wav")
        file.writeBytes(bytes)
        if (loop) stop()
        val player = MediaPlayer()
        player.setAudioAttributes(AudioAttributes.Builder()
            .setUsage(if (loop) AudioAttributes.USAGE_NOTIFICATION_RINGTONE else AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build())
        player.setDataSource(file.path)
        player.isLooping = loop
        player.setOnCompletionListener { if (!it.isLooping) it.release() }
        player.setOnErrorListener { p, _, _ -> p.release(); true }
        player.prepare()
        player.start()
        if (loop) looping = player
    }

    /** Ends the ring; sounds played once run to their end. */
    fun stop() {
        looping?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        looping = null
    }

    /**
     * The message sound chosen in Settings › Sounds, played by the phone itself: a text arrived in the conversation
     * open in front, where no notification is shown (Notifier.incoming).
     */
    fun messageIn(context: Context) {
        val ui = context.getSharedPreferences("ui", Context.MODE_PRIVATE)
        if (ui.getString("sounds", "on") == "off") return
        val take = ui.getString("sound_message", "4") ?: "4"
        try {
            // Read whole rather than by file descriptor, which needs the file stored uncompressed in the APK.
            val bytes = context.assets.open("flutter_assets/assets/sounds/message-in-$take.wav").use { it.readBytes() }
            play(context, bytes, loop = false)
        } catch (_: Exception) {}
    }
}
