package com.infamousvague.ghostmessaging

import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Rational
import java.lang.ref.WeakReference
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * A call's picture in picture (GMFB-64, Kevin: "Streaming or video calling would be nice if there were a pop out
 * option"; Matt, 2026-11-25: "Please go ahead take care of the pop out video player as well"): sent home or to another
 * app during a call with a camera or a shared screen to see, the app goes on as a small window over everything, the
 * picture filling it at its own shape, with Mute and Leave. Out of such a call it never does.
 *
 * Dart says what there is to show over `ghost_messaging/pip` (`pip`: `on`, the picture's shape `w` by `h`, `muted`;
 * lib/ui/call_pip.dart) as it changes. Here it is kept and set as the screen's parameters: on Android 12 and later the
 * window goes in by itself as the app is left (auto-enter), below that MainActivity asks for it as the person leaves
 * (onUserLeaveHint). Back to Dart go the window going in and out (`changed`, `in`), and its buttons (`action`, `do`).
 * The app's screen alone: a conversation's bubble (BubbleActivity) never calls here.
 */
object CallPip {
    private const val CHANNEL = "ghost_messaging/pip"
    private const val ACTION = "com.infamousvague.ghostmessaging.PIP_ACTION"

    /** What Dart last said: a picture to show, its shape, and whether this device is muted (the Mute button's look). */
    @Volatile var on = false
    private var w = 4
    private var h = 3
    private var muted = false

    private var channel: MethodChannel? = null
    private var receiver: BroadcastReceiver? = null

    /** The app's screen now: made again over the running engine, it registers again (MainActivity). */
    private var screen: WeakReference<Activity>? = null

    /** Whether this phone has picture in picture at all (some launchers and low-memory phones do not). */
    fun supported(activity: Activity): Boolean =
        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    fun register(activity: Activity, messenger: BinaryMessenger) {
        screen = WeakReference(activity)
        channel = MethodChannel(messenger, CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "pip" -> {
                        on = call.argument<Boolean>("on") ?: false
                        w = call.argument<Int>("w") ?: w
                        h = call.argument<Int>("h") ?: h
                        muted = call.argument<Boolean>("muted") ?: false
                        screen?.get()?.let { apply(it) }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        listen(activity)
    }

    /** Sets what there is now as the screen's parameters; the call ended or its picture gone while in the window, the
     *  app is put away (the window with it) rather than left showing black. */
    fun apply(activity: Activity) {
        if (!supported(activity)) return
        try {
            activity.setPictureInPictureParams(params(activity))
        } catch (e: Exception) {
            DevLog.add(activity, "call", "picture in picture's parameters were refused: ${e.message}")
        }
        if (!on && activity.isInPictureInPictureMode) activity.moveTaskToBack(false)
    }

    /** Asked as the person leaves the app (the home button, another app), below Android 12 where it does not go in by
     *  itself: in only during a call with a picture. */
    fun leaving(activity: Activity) {
        if (!on || Build.VERSION.SDK_INT >= Build.VERSION_CODES.S || !supported(activity)) return
        try {
            activity.enterPictureInPictureMode(params(activity))
        } catch (e: Exception) {
            DevLog.add(activity, "call", "picture in picture was refused: ${e.message}")
        }
    }

    /** The window went in or out of picture in picture: Dart draws the picture alone while it is in. */
    fun changed(inPip: Boolean) {
        channel?.invokeMethod("changed", mapOf("in" to inPip))
    }

    private fun params(context: Context): PictureInPictureParams {
        // Android allows from 1:2.39 to 2.39:1; anything outside throws.
        val shape = (w.toDouble() / h.coerceAtLeast(1)).coerceIn(1 / 2.39, 2.39)
        val b = PictureInPictureParams.Builder()
            .setAspectRatio(Rational((shape * 1000).toInt().coerceAtLeast(1), 1000))
            .setActions(if (on) listOf(
                action(context, "mute", if (muted) "Unmute" else "Mute", if (muted) R.drawable.ic_pip_mic_off else R.drawable.ic_pip_mic, 1),
                action(context, "leave", "Leave", R.drawable.ic_pip_leave, 2),
            ) else emptyList())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setAutoEnterEnabled(on)
            b.setSeamlessResizeEnabled(true)
        }
        return b.build()
    }

    private fun action(context: Context, what: String, title: String, icon: Int, code: Int): RemoteAction {
        val intent = Intent(ACTION).setPackage(context.packageName).putExtra("do", what)
        val pending = PendingIntent.getBroadcast(context, 7500 + code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return RemoteAction(Icon.createWithResource(context, icon), title, title, pending)
    }

    /** The window's buttons, heard for as long as the app's screen is (its own broadcasts only). */
    private fun listen(activity: Activity) {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                val what = intent?.getStringExtra("do") ?: return
                channel?.invokeMethod("action", mapOf("do" to what))
            }
        }
        val filter = IntentFilter(ACTION)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) activity.applicationContext.registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
            else @Suppress("UnspecifiedRegisterReceiverFlag") activity.applicationContext.registerReceiver(r, filter)
            receiver = r
        } catch (e: Exception) {
            DevLog.add(activity, "call", "picture in picture's buttons could not be heard: ${e.message}")
        }
    }
}
