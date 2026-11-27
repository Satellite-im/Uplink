package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings

/**
 * Ringing while the app is closed (GMFB-28: "The other person's devices ring with accept/decline"; checked against
 * the code on 2026-11-25: "a fully closed app is not woken for a call, so it usually shows as missed"). There is no
 * push service behind this app, so a friend's call reaches a phone only while the app is connected to the relay. Where
 * the person chose "Ring when the app is closed" (lib/keep_running.dart, the choice `stay_reachable`), the app is
 * kept running after its screen is closed (NetworksService.kt) and goes on hearing.
 *
 * Two things only Android can do are here:
 * - **While the phone sleeps.** A phone holds back the apps that run while it sleeps, some makers' far more than
 *   Android itself asks, unless the person lets one run unrestricted ([exempt], [ask]): a kept app that is held back
 *   rings late or not at all. (Android's own default SMS app is let run already.)
 * - **After the phone restarts**, or the app is updated, nothing of the app is running, and Android lets no app open
 *   itself. So the person is told, once, to open it ([afterBoot]); opening it takes the notification away ([opened]).
 */
object Reach {
    private const val CHANNEL = "reach"
    private const val NOTIFICATION = 7503
    private const val KEY = "stay_reachable"

    /** Whether the person chose to be rung while the app is closed (the app's own choices, as Dart keeps them). */
    fun wanted(context: Context): Boolean = context.applicationContext.getSharedPreferences("ui", Context.MODE_PRIVATE).getString(KEY, null) == "on"

    /** Whether Android lets the app run while the phone sleeps (it is not held back to save battery). */
    fun exempt(context: Context): Boolean = try {
        context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName)
    } catch (_: Exception) {
        false
    }

    /** Android's own question: may this app run unrestricted? False where the question could not be shown. */
    fun ask(context: Context): Boolean = try {
        context.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: Exception) {
        // Some phones have no such question: the list it is on, then.
        try {
            context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (_: Exception) {
            false
        }
    }

    /** The phone restarted, or the app was updated: where calls are to ring while it is closed, say it must be opened. */
    fun afterBoot(context: Context) {
        if (!wanted(context)) return
        try {
            val nm = context.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Open the app to be reachable", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "After the phone restarts, Uplink has to be opened once before a friend's call can ring."
                setShowBadge(false)
            })
            val open = PendingIntent.getActivity(context, NOTIFICATION, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            nm.notify(NOTIFICATION, Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_ghost)
                .setContentTitle("Open Uplink to be reachable")
                .setContentText("Calls from friends can't ring until it has been opened once since the phone started.")
                .setStyle(Notification.BigTextStyle().bigText("Calls from friends can't ring until Uplink has been opened once since the phone started. Tap to open it."))
                .setContentIntent(open)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
                .build())
        } catch (_: Exception) {
            // Notifications not allowed: nothing to say it with.
        }
    }

    /** The app is open: nothing more to say. */
    fun opened(context: Context) {
        try { context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION) } catch (_: Exception) {}
    }
}
