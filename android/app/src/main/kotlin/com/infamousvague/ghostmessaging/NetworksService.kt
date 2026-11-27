package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps Uplink running, connected to Signal and Telegram, while it is out of sight (Matt, 2026-11-16, on Uplink
 * notifying for their messages: "Yes, build them"). Their connections live in the app's Dart (lib/inbox: Signal's
 * helper process, Telegram's TDLib), which runs in a Flutter engine kept past the screen (MainActivity
 * provideFlutterEngine); Android keeps the process for as long as a foreground service of the remote-messaging kind
 * runs, as DeskService does for a paired computer. Its notification is the quietest Android allows, on a channel of
 * its own the person can turn off.
 *
 * Started and stopped by Dart as networks are signed in and out (lib/inbox/alerts.dart, through MainActivity's
 * `keepNetworks`). Not restarted by Android if it is stopped: the app opening again connects again.
 *
 * And for calls from friends (GMFB-28, lib/keep_running.dart): a friend's call rings on a phone only while the app
 * is connected to the relay, and a closed app is not. Where the person chose "Ring when the app is closed" the
 * service runs for that too (`calls`), with or without a network signed in, and its notification says so. It keeps
 * the running app; it can't start one, so after the phone restarts the app has to be opened once ([Reach]).
 */
class NetworksService : Service() {
    companion object {
        private const val CHANNEL = "networks-min"
        private const val NOTIFICATION = 7501

        /**
         * Keeps the app running for the networks in [names], which its notification names, and for calls from friends
         * where [calls]; with neither it stops.
         */
        fun keep(context: Context, names: List<String>, calls: Boolean = false) {
            val i = Intent(context.applicationContext, NetworksService::class.java).putStringArrayListExtra("names", ArrayList(names)).putExtra("calls", calls)
            try {
                if (names.isEmpty() && !calls) context.applicationContext.stopService(i) else context.applicationContext.startForegroundService(i)
            } catch (e: Exception) {
                // Android refuses a foreground service started from the background at most moments: it starts the next
                // time the app is opened.
                DevLog.add(context, "networks", "the service that keeps ${(names + if (calls) listOf("calls") else emptyList()).joinToString(" and ")} connected did not start: ${e.message}")
            }
        }

        /** What the notification says for [names] and [calls]: its title, then its line. */
        fun words(names: List<String>, calls: Boolean): Pair<String, String> = when {
            names.isEmpty() -> "Ready for calls" to "A friend's call rings, and their messages come, while Uplink is closed."
            calls -> "Connected to ${said(names)}" to "Calls ring and new messages are told to you as they come."
            else -> "Connected to ${said(names)}" to "New messages are told to you as they come."
        }

        /** "Signal", "Signal and Telegram", "Signal, Telegram and Bluesky". */
        fun said(names: List<String>): String = when (names.size) {
            0 -> ""
            1 -> names[0]
            else -> names.dropLast(1).joinToString(", ") + " and " + names.last()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val names = intent?.getStringArrayListExtra("names")?.toList().orEmpty()
        val calls = intent?.getBooleanExtra("calls", false) ?: false
        if (names.isEmpty() && !calls) {
            stopSelf()
            return START_NOT_STICKY
        }
        val n = notification(names, calls)
        try {
            if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            else startForeground(NOTIFICATION, n)
        } catch (e: Exception) {
            DevLog.add(this, "networks", "Android refused to keep ${words(names, calls).first} going: ${e.message}")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    /** The service's notification: silent, kept off the lock screen, a press opening the app. */
    private fun notification(names: List<String>, calls: Boolean): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        // Made again each time: a channel made before calls were kept for is given its name of now (Android keeps
        // whatever the person changed of it).
        run {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Staying connected", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Android asks for a notification while Uplink stays connected with the app closed: to Signal, Telegram and the like, and for calls from friends. This one is as quiet as Android allows; turn it off here if you like, and calls and messages still come."
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
                setSound(null, null)
                enableVibration(false)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle(words(names, calls).first)
            .setContentText(words(names, calls).second)
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            .setGroup("networks")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setLocalOnly(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .build()
    }
}
