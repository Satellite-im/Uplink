package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps a voice call in a space going with the phone locked (Matt, 2026-11-15: "Also voice chat stops working when
 * the phone is locked"). Since Android 9 an app that is out of sight loses the microphone, and Android may put its
 * network and processor to sleep: a call needs a foreground service of the microphone's kind (and the camera's while
 * video is on, and media playback's for what is heard), as every calling app has. It shows an ongoing notification,
 * "In a voice call", with Leave; it holds a partial wake lock and a Wi-Fi lock for as long as the call lasts, and
 * goes when the call does.
 *
 * Started by the app as it joins a call (lib/voice/channels.dart, through MainActivity's `callStarted`), which is
 * while it is in front, as Android asks of a microphone service.
 */
class CallService : Service() {
    companion object {
        private const val CHANNEL = "call"
        private const val NOTIFICATION = 7401
        private const val LEAVE = "com.infamousvague.ghostmessaging.LEAVE_CALL"

        /** Told when the notification's Leave is pressed: the app leaves the call (MainActivity). */
        @Volatile var onLeave: (() -> Unit)? = null

        /**
         * [screen]: this device is sharing its screen (GMFB-27). Android 14 lets a screen be captured only under a
         * foreground service of the media projection kind, started after the person agreed to share and before the
         * capture begins, so the app says so between the two (lib/voice/rtc.dart, RtcMedia.setScreen).
         */
        fun start(context: Context, name: String, video: Boolean, screen: Boolean = false) {
            val i = Intent(context, CallService::class.java).putExtra("name", name).putExtra("video", video).putExtra("screen", screen)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i) else context.startService(i)
            } catch (e: Exception) {
                DevLog.add(context, "call", "the call's service did not start: ${e.message}")
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallService::class.java))
        }
    }

    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == LEAVE) {
            onLeave?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        val name = intent?.getStringExtra("name")?.ifBlank { null } ?: "a space"
        val video = intent?.getBooleanExtra("video", false) ?: false
        val screen = intent?.getBooleanExtra("screen", false) ?: false
        val n = notification(name, video, screen)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (video) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                if (screen) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                startForeground(NOTIFICATION, n, types)
            } else {
                startForeground(NOTIFICATION, n)
            }
        } catch (e: Exception) {
            // Started from the background (Android refuses a microphone service then): the call goes on while the app
            // is in front, as it did before.
            DevLog.add(this, "call", "the call's service was refused: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        // Six hours at most, so a call that never ends cannot hold the processor awake for good.
        if (wake == null) {
            wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GhostMessaging:call").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        }
        if (wifi == null) {
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager).createWifiLock(mode, "GhostMessaging:call").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        return START_NOT_STICKY
    }

    private fun notification(name: String, video: Boolean, screen: Boolean): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Voice calls", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while you are in a voice call in a space, so it goes on with the phone locked."
                setShowBadge(false)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val leave = PendingIntent.getService(this, 1, Intent(this, CallService::class.java).setAction(LEAVE), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle(if (screen) "Sharing your screen" else if (video) "In a video call" else "In a voice call")
            .setContentText(name)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Leave", leave).build())
            .build()
    }

    override fun onDestroy() {
        try { wake?.release() } catch (_: Exception) {}
        try { wifi?.release() } catch (_: Exception) {}
        wake = null
        wifi = null
        super.onDestroy()
    }
}
