package com.infamousvague.ghostmessaging

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Reminders about a conversation (lib/plugins/replies.dart; Matt, 2026-11-14, of the ideas to streamline someone's
 * day: "Follow-up nudges: You told Maya you'd send the photos — remind me tonight?"). A message's menu, or the
 * button over the composer after a promise, asks for one at a time; Android's alarm brings it back as a notification
 * that opens the conversation. Inexact (within a few minutes), so no permission for exact alarms is asked for. A
 * reminder is lost if the phone is restarted before it is due.
 */
object Reminders {
    private const val CHANNEL = "reminders"
    const val ACTION = "ghost.REMIND"

    /**
     * Sets a reminder about [thread] for [at] (milliseconds since 1970), waking the phone for it. One reminder for a
     * conversation and a time: asked again, it takes the new words. False where Android would not set it.
     */
    fun schedule(context: Context, thread: Long, title: String, body: String, at: Long): Boolean = try {
        val intent = Intent(context, ReminderReceiver::class.java).setAction(ACTION)
            .putExtra(Notifier.EXTRA_THREAD, thread).putExtra("title", title).putExtra("body", body)
        val pending = PendingIntent.getBroadcast(context, (thread xor at).toInt(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        context.getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        true
    } catch (e: Exception) {
        DevLog.add(context, "remind", "schedule: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
        false
    }

    /** The reminder's notification, which opens [thread]; one for a conversation, a newer one taking its place. */
    fun show(context: Context, thread: Long, title: String, body: String) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Reminders", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A conversation you asked to be reminded about."
            })
        }
        val open = PendingIntent.getActivity(context, thread.toInt(), Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(Notifier.EXTRA_THREAD, thread)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setColor(0xFF4F5BD5.toInt())
            .build()
        try { nm.notify(("remind" + thread).hashCode(), n) } catch (_: SecurityException) {}
    }
}

/** Woken by the alarm [Reminders.schedule] set: shows the reminder it carries. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Reminders.ACTION) return
        Reminders.show(context, intent.getLongExtra(Notifier.EXTRA_THREAD, -1), intent.getStringExtra("title") ?: "Reminder", intent.getStringExtra("body") ?: "")
    }
}
