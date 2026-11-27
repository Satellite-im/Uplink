package com.infamousvague.ghostmessaging

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import io.flutter.FlutterInjector
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The walkthrough's voice (lib/onboarding/onboarding.dart, GuideVoice): one of the app's Flutter assets
 * (assets/onboarding/<page>.mp3, ElevenLabs' voice made at build time), played once; false where the file is not
 * there. As Ghost Keyboard's MainActivity plays its own.
 */
object GuideVoice {
    private var player: MediaPlayer? = null

    /** The `ghost/guide` channel: play (an asset by its Flutter name) and stop. */
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "ghost/guide").setMethodCallHandler { call, result ->
            when (call.method) {
                "play" -> result.success(play(app, call.argument<String>("asset") ?: ""))
                "stop" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    /** Plays [asset] in place of whatever was playing; false where it is missing or cannot be played. */
    @Synchronized
    private fun play(context: Context, asset: String): Boolean {
        stop()
        return runCatching {
            // Where Flutter put the asset inside the APK.
            val key = FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(asset)
            context.assets.openFd(key).use { fd ->
                player = MediaPlayer().apply {
                    setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                    setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
                    setOnCompletionListener { done -> done.release(); synchronized(this@GuideVoice) { if (player === done) player = null } }
                    prepare()
                    start()
                }
            }
            true
        }.getOrDefault(false)
    }

    @Synchronized
    fun stop() {
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
    }
}
