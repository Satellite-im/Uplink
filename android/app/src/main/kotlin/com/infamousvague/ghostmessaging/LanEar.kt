package com.infamousvague.ghostmessaging

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The local network route's ear (lib/net/lan/lan_ground_io.dart, docs/network.md "The local network route"). Dart
 * opens the route's sockets and does everything on them. But a phone's Wi-Fi drops what is said to a whole network
 * before any app sees it, to save its battery, unless an app says it is listening: with no multicast lock held,
 * Android's packet filter drops every IPv4 broadcast but DHCP's. A route that only ever said its beacons and heard
 * none would be found by computers and by no other phone.
 *
 * So while the route is open, and no longer, Dart asks here to hold the lock (the channel `ghost_messaging/lan`,
 * method `hear`). On a phone the route is open only while the app is in use (LanPolicy.sleepsAway), so that is all the
 * while the lock is held.
 */
object LanEar {
    private var lock: WifiManager.MulticastLock? = null

    /** The channel Dart asks through, on the app's engine. Holds nothing. */
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "ghost_messaging/lan").setMethodCallHandler { call, result ->
            when (call.method) {
                "hear" -> result.success(hear(app, call.argument<Boolean>("on") == true))
                else -> result.notImplemented()
            }
        }
    }

    /** Holds the lock ([on]) or lets it go. Whether it is held after. */
    @Synchronized
    fun hear(context: Context, on: Boolean): Boolean {
        try {
            if (on) {
                val held = lock ?: (context.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                    .createMulticastLock("ghost-lan").also { it.setReferenceCounted(false); lock = it }
                if (!held.isHeld) held.acquire()
            } else {
                lock?.takeIf { it.isHeld }?.release()
            }
        } catch (_: Exception) {
            // No Wi-Fi service, or the lock refused: the route says its beacons all the same, and is found by whoever hears.
        }
        return lock?.isHeld == true
    }
}
