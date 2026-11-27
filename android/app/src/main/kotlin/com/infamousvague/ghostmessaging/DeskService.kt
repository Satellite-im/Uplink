package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

/**
 * What keeps the phone reachable by the computers it is paired with (docs/desktop.md): a foreground service of
 * Android's "remote messaging" kind, which is the one made for carrying a phone's texts to another of its owner's
 * devices. It runs while a computer is paired, or a pairing is being made, and stops when there is neither.
 *
 * It holds the two ways in:
 * - **The local network.** A port the paired computer connects to, announced as `_ghostmsg._tcp` (NSD) so the
 *   computer finds it; announced again when the phone's network changes. The phone listens and the computer dials,
 *   since a phone announcing is the dependable direction with its screen off.
 * - **The relay.** A WebSocket the phone dials out on for each pairing that may use one ([WsClient]), tried again
 *   with a growing wait when it drops.
 *
 * Either way what arrives is frames for a [DeskSession], and nothing is answered that is not sealed under a
 * pairing's key. Without the service Android stops the app minutes after the screen goes off; with it, the app is
 * still cut from the network in deep sleep (Doze), where a new text is what lets it through for a moment.
 */
class DeskService : Service() {
    companion object {
        private const val TAG = "GhostDesk"
        const val SERVICE_TYPE = "_ghostmsg._tcp"
        // The quietest a notification can be (Matt, 2026-11-14: "don't show the notification for the phone app and
        // desktop app being linked it's blocking notifications for text messages", and on 0.7.13 "it still says
        // paired with matts macbook air"). Android has a foreground service show a notification, and a channel an
        // app makes off is turned back on for one (0.7.13's "desk-quiet" was made off and Android raised it to
        // low: shown, in the status bar). The least an app may ask is minimum: folded to one line at the foot of
        // the shade under Silent, with no icon in the status bar, nothing on the lock screen and no sound. Only the
        // person can turn it off, on Android's page for it (Settings › Computers leads there).
        const val CHANNEL = "desk-min"
        private val OLD_CHANNELS = listOf("desk", "desk-quiet")
        private const val NOTIFICATION = 7301
        private const val MAX_CONNECTIONS = 8

        /** Starts the service if there is a computer to be reachable by, and stops it if there is none. */
        fun sync(context: Context) {
            try {
                Desk.init(context)
                val intent = Intent(context.applicationContext, DeskService::class.java)
                if (Desk.wanted()) context.applicationContext.startForegroundService(intent) else context.applicationContext.stopService(intent)
            } catch (e: Exception) {
                // Android refuses a foreground service started from the background at most moments: it starts the
                // next time the app is opened, or a text arrives.
                Log.w(TAG, "the link service could not be started now: ${e.message}")
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var server: LocalServer? = null
    private var nsdListener: NsdManager.RegistrationListener? = null
    private val relays = HashMap<String, RelayLink>()
    private val connections = ConcurrentHashMap.newKeySet<Connection>()
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastText = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Desk.init(applicationContext)
        foreground()
        Desk.serviceListener = { apply() }
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { main.post { networkChanged() } }
            override fun onLost(network: Network) { main.post { networkChanged() } }
        }
        try { getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(callback); networkCallback = callback } catch (e: Exception) { Log.w(TAG, "network callback", e) }
        // A name or a face changed in the phone's contacts: the computers read their lists again.
        try { contentResolver.registerContentObserver(android.provider.ContactsContract.Contacts.CONTENT_URI, true, contactsWatcher) } catch (_: Exception) {}
    }

    private val contactsWatcher = object : android.database.ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { Desk.contactsChanged(); Desk.changed(-1) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        foreground()
        apply()
        return START_STICKY
    }

    override fun onDestroy() {
        Desk.serviceListener = null
        try { contentResolver.unregisterContentObserver(contactsWatcher) } catch (_: Exception) {}
        networkCallback?.let { try { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) } catch (_: Exception) {} }
        stopLocal()
        for (r in relays.values) r.stop()
        relays.clear()
        super.onDestroy()
    }

    // --- the notification a foreground service must show ----------------------------------------------------------------

    /** The notification's one line: the pairing being made, else the computer or how many computers are paired. */
    private fun text(): String {
        val all = Desk.all()
        val pending = Desk.pending
        return when {
            pending != null && (pending.phase == "waiting" || pending.phase == "code") -> "Pairing with ${pending.offer.name}"
            all.size == 1 -> "Paired with ${all[0].name}"
            else -> "Paired with ${all.size} computers"
        }
    }

    private fun notification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        for (old in OLD_CHANNELS) if (nm.getNotificationChannel(old) != null) try { nm.deleteNotificationChannel(old) } catch (_: Exception) {}
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Paired computers", NotificationManager.IMPORTANCE_MIN).apply {
                description = "Android asks for a notification while a computer is paired. This one is as quiet as Android allows; turn it off here if you like, and the computer still reaches the phone."
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_SECRET
                setSound(null, null)
                enableVibration(false)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).putExtra("desk", true), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        lastText = text()
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle(lastText)
            .setContentText("Your texts reach it sealed. Tap to manage.")
            .setContentIntent(open)
            .setOngoing(true)
            .setShowWhen(false)
            // Never bundled with the texts' notifications, where it could fold them under itself.
            .setGroup("desk")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setLocalOnly(true)
            .setOnlyAlertOnce(true)
            .setVisibility(Notification.VISIBILITY_SECRET)
            .build()
    }

    private fun foreground() {
        try {
            if (Build.VERSION.SDK_INT >= 34) startForeground(NOTIFICATION, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            else startForeground(NOTIFICATION, notification())
        } catch (e: Exception) {
            Log.w(TAG, "could not go to the foreground: ${e.message}")
        }
    }

    // --- what should be held now ----------------------------------------------------------------------------------------

    /** Looks at the pairings and the pairing being made, and holds exactly what they need. */
    private fun apply() {
        // Before anything else, and before stopping when the last computer was unpaired: the relay is told to forget
        // the channels of pairings removed here.
        forgetRemoved()
        if (!Desk.wanted()) { stopSelf(); return }
        if (text() != lastText) getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification())
        val all = Desk.all()
        val pending = Desk.pending?.takeIf { (it.phase == "waiting" || it.phase == "code") && !it.expired }

        // The computer is reached while pairing the way IT offered: that is where it is looking.
        val local = all.any { it.mode != "relay" } || (pending != null && pending.offer.mode != "relay")
        if (local) startLocal() else stopLocal()

        val want = HashMap<String, Triple<String, String, Boolean>>()
        for (p in all) if (p.mode != "local" && p.relay.isNotBlank()) want["p:${p.id}"] = Triple(join(p.relay, DeskCrypto.relayChannel(p.key)), DeskCrypto.relayToken(p.key), false)
        if (pending != null && pending.offer.mode != "local" && pending.offer.relay.isNotBlank()) {
            want["pairing:${pending.pairingId}"] = Triple(join(pending.offer.relay, DeskCrypto.pairingChannel(pending.offer.secret)), DeskCrypto.pairingToken(pending.offer.secret), true)
        }
        for (name in relays.keys.toList()) if (name !in want || relays[name]!!.url != want[name]!!.first) relays.remove(name)!!.stop()
        for ((name, w) in want) if (name !in relays) relays[name] = RelayLink(w.first, w.second, w.third).also { it.start() }
    }

    /** A relay channel's address: the relay's, then the channel's name. */
    private fun join(relay: String, channel: String) = relay.trimEnd('/') + "/" + channel

    /**
     * A pairing that was unpaired here: the relay is told to forget its channel, by the connection already open to
     * it or by one made for the telling, which goes on for the few seconds it needs even as the service stops.
     */
    private fun forgetRemoved() {
        for (gone in Desk.takeRemoved()) {
            val url = join(gone.relay, gone.channel)
            val had = relays.entries.firstOrNull { it.value.url == url }
            if (had != null) { had.value.forget(); relays.remove(had.key) } else RelayLink(url, gone.token, temp = false, forgetOnly = true).start()
        }
    }

    private fun networkChanged() {
        // A new network: the phone says where it is again, and the relay is tried now, not when its wait runs out.
        server?.let { unregisterNsd(); registerNsd(it.port) }
        for (r in relays.values) r.kick()
    }

    // --- the local network ----------------------------------------------------------------------------------------------

    /** Listens for paired computers on the local network and announces the phone there (Bonjour, [SERVICE_TYPE]). */
    private fun startLocal() {
        if (server != null) return
        try {
            val s = LocalServer()
            server = s
            s.start()
            registerNsd(s.port)
        } catch (e: Exception) {
            Log.e(TAG, "could not listen on the local network", e)
            server = null
        }
    }

    /** Stops announcing and listening, and ends the local connections open now. */
    private fun stopLocal() {
        unregisterNsd()
        server?.close()
        server = null
        for (c in connections) c.end()
    }

    /** Announces the phone on the local network under its service name, at [port]; a failure is only logged. */
    private fun registerNsd(port: Int) {
        try {
            val info = NsdServiceInfo().apply { serviceName = Desk.serviceName(); serviceType = SERVICE_TYPE; setPort(port) }
            val listener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo) {}
                override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) { Log.w(TAG, "announcing failed: $code") }
                override fun onServiceUnregistered(info: NsdServiceInfo) {}
                override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
            }
            getSystemService(NsdManager::class.java).registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
            nsdListener = listener
        } catch (e: Exception) { Log.w(TAG, "could not announce on the local network", e) }
    }

    private fun unregisterNsd() {
        val l = nsdListener ?: return
        nsdListener = null
        try { getSystemService(NsdManager::class.java).unregisterService(l) } catch (_: Exception) {}
    }

    /** The port paired computers connect to: the one used last when it is free, so a remembered address still works. */
    private inner class LocalServer {
        private val socket = ServerSocket()
        val port: Int
        @Volatile private var closed = false

        init {
            socket.reuseAddress = true
            val remembered = Desk.port
            try { socket.bind(InetSocketAddress(if (remembered in 1024..65535) remembered else 0)) } catch (_: IOException) { socket.bind(InetSocketAddress(0)) }
            port = socket.localPort
            Desk.port = port
            // The port alone, never who connects: for `adb forward` when trying it on an emulator (docs/desktop.md).
            Log.i(TAG, "listening for paired computers on port $port")
        }

        fun start() {
            Thread({
                while (!closed) {
                    val s = try { socket.accept() } catch (_: IOException) { break }
                    if (connections.size >= MAX_CONNECTIONS) { try { s.close() } catch (_: Exception) {}; continue }
                    Connection(s).start()
                }
            }, "ghost-desk-accept").start()
        }

        fun close() { closed = true; try { socket.close() } catch (_: Exception) {} }
    }

    /** One computer connected over the local network: frames with their length before them, both ways. */
    private inner class Connection(private val socket: Socket) : Thread("ghost-desk-local") {
        fun end() { try { socket.close() } catch (_: Exception) {} }

        override fun run() {
            connections += this
            var session: DeskSession? = null
            try {
                socket.tcpNoDelay = true
                // A hello must come soon; once the computer has proved itself, silence may last as long as its pings.
                socket.soTimeout = 10_000
                val input = DataInputStream(socket.getInputStream().buffered())
                val out = socket.getOutputStream()
                val s = DeskSession(Desk, "local", { frame ->
                    synchronized(out) {
                        out.write(byteArrayOf((frame.size ushr 24).toByte(), (frame.size ushr 16).toByte(), (frame.size ushr 8).toByte(), frame.size.toByte()))
                        out.write(frame)
                        out.flush()
                    }
                })
                session = s
                s.onClosed = { end() }
                while (!s.closed) {
                    val length = input.readInt()
                    if (length <= 0 || length > DeskCrypto.MAX_FRAME) break
                    val frame = ByteArray(length).also { input.readFully(it) }
                    s.receive(frame)
                    if (s.live) socket.soTimeout = 90_000
                }
            } catch (_: Exception) {
                // The computer went, or said something that is no frame.
            } finally {
                session?.close()
                end()
                connections -= this
            }
        }
    }

    // --- the relay ------------------------------------------------------------------------------------------------------

    /**
     * One pairing's connection out to the relay, kept up while the service runs. The computer starts each
     * conversation with a hello; a hello is a new [DeskSession], and the relay saying the computer left ends it.
     */
    private inner class RelayLink(val url: String, private val token: String, private val temp: Boolean, private val forgetOnly: Boolean = false) {
        @Volatile private var stopped = false
        @Volatile private var client: WsClient? = null
        @Volatile private var session: DeskSession? = null
        @Volatile private var forget = forgetOnly
        private var thread: Thread? = null

        fun start() {
            thread = Thread({
                var wait = 2_000L
                var tries = 0
                while (!stopped) {
                    var joined = false
                    val ws = WsClient(url, object : WsClient.Listener {
                        override fun onOpen() {
                            client?.sendText(JSONObject().put("auth", token).put("role", "phone").also { if (temp) it.put("temp", true) }.toString())
                        }
                        override fun onText(text: String) {
                            val o = try { JSONObject(text) } catch (_: Exception) { return }
                            if (o.optBoolean("ok")) {
                                joined = true
                                if (forget) { client?.sendText("{\"delete\":true}"); stopped = true; client?.close() }
                            }
                            // The computer left the relay: its connection here is over, and its next hello starts another.
                            if (o.has("peer") && !o.optBoolean("peer")) session?.close()
                        }
                        override fun onBinary(bytes: ByteArray) {
                            if (forget) return
                            if (bytes.isNotEmpty() && bytes[0] == DeskCrypto.HELLO) {
                                session?.close()
                                val c = client ?: return
                                session = DeskSession(Desk, "relay", { frame -> if (!c.sendBinary(frame)) throw IOException("the relay is gone") })
                            }
                            session?.receive(bytes)
                        }
                        override fun onClosed(code: Int?) {}
                    })
                    client = ws
                    ws.run()
                    client = null
                    session?.close()
                    session = null
                    if (stopped) break
                    // Only a few tries to tell the relay to forget a channel: it forgets an unused one by itself.
                    if (forgetOnly && ++tries >= 3) break
                    wait = if (joined) 2_000L else (wait * 2).coerceAtMost(60_000L)
                    try { Thread.sleep(wait) } catch (_: InterruptedException) {}
                }
            }, "ghost-desk-relay").also { it.start() }
        }

        /** Tries the relay now: the network just changed. */
        fun kick() { thread?.interrupt() }

        fun stop() {
            stopped = true
            client?.close()
            thread?.interrupt()
        }

        /** The pairing was removed here: the relay is told to forget the channel, then the connection is closed. */
        fun forget() {
            forget = true
            val c = client
            if (c != null && c.sendText("{\"delete\":true}")) { stop(); return }
            // Not connected at this moment: the loop tells it as soon as it is, a few times at most.
            kick()
            main.postDelayed({ stop() }, 30_000)
        }
    }
}

/** After a restart, and after the app is updated, the service starts again if a computer is paired. */
class DeskBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            DeskService.sync(context)
            // Calls that are to ring while the app is closed can't until it has been opened again (Reach.kt).
            Reach.afterBoot(context)
        }
    }
}
