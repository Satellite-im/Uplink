package com.infamousvague.ghostmessaging

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * A friend calling, as a phone shows a call (GMFB-28, from the Uplink gap review: "The other person's devices ring with
 * accept/decline, including a full-screen incoming call on Android"). The app hears the call (lib/voice/friend_calls.dart)
 * and asks for this notification; it is a call's own notification, Answer and Decline, and full screen while the phone
 * is locked or the app is out of sight. The app plays the ringing itself, so the channel makes no sound of its own.
 *
 * Answer opens the app, which answers ([MainActivity] tells Dart `ringAction: answer`); Decline is said without opening
 * it ([DeclineReceiver]). The app takes the notification away as the call is answered, declined anywhere, called off or
 * rings out ([end]).
 */
object IncomingCall {
    // The notification channel's id, the one notification's id, and the intent extra that says what was pressed
    // ("answer", or "screen" for the notification itself and its full-screen form).
    private const val CHANNEL = "incoming_call"
    private const val NOTIFICATION = 7402
    const val EXTRA = "ring"

    /** Told when Answer or Decline is pressed ("answer", "decline"): to Dart (MainActivity). */
    @Volatile var onAction: ((String) -> Unit)? = null

    /** Shows the call from [from]: Android's own call style from Android 12, two plain buttons before it. */
    fun show(context: Context, from: String, video: Boolean) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Incoming calls", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A friend calling you: Answer or Decline, full screen while the phone is locked."
                setSound(null, null)
                enableVibration(true)
                setShowBadge(false)
            })
        }
        val answer = PendingIntent.getActivity(context, 7402, Intent(context, MainActivity::class.java).putExtra(EXTRA, "answer").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val screen = PendingIntent.getActivity(context, 7403, Intent(context, MainActivity::class.java).putExtra(EXTRA, "screen").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val decline = PendingIntent.getBroadcast(context, 7404, Intent(context, DeclineReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val b = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle(from)
            .setContentText(if (video) "Video call" else "Voice call")
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(screen)
            .setFullScreenIntent(screen, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            b.setStyle(Notification.CallStyle.forIncomingCall(Person.Builder().setName(from).setImportant(true).build(), decline, answer).setIsVideo(video))
        } else {
            b.addAction(Notification.Action.Builder(null, "Decline", decline).build())
            b.addAction(Notification.Action.Builder(null, "Answer", answer).build())
        }
        try { nm.notify(NOTIFICATION, b.build()) } catch (_: SecurityException) {}
    }

    /** Takes the call's notification away, however the ringing ended. */
    fun end(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION)
    }

    /** Over the lock screen and the screen turned on while a call rings ([on]), as a phone's call screen is. */
    fun overLock(activity: Activity, on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            activity.setShowWhenLocked(on)
            activity.setTurnScreenOn(on)
        }
    }

    /** Decline, pressed on the notification: it goes, and the app is told, without its screen being opened. */
    class DeclineReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            end(context)
            onAction?.invoke("decline")
        }
    }
}
