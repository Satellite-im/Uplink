package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A friend by username wrote while Uplink was closed (Matt, 2026-11-16: "Yes, wake-ups", "Check every ~15 min"). What
 * friends by username write goes by the relay server's hub (lib/net/hub_carrier.dart), which holds it while the app
 * is not connected; nothing on the phone hears it until the app opens. So every fifteen minutes or so, as Android
 * allows, this signs in to the hub only to look (relay/lib/hub.dart `peek`): told how much is held, nothing is
 * handed over or taken, and the app gets it all when it opens. Where something new is held, "New message" is shown.
 *
 * No Google services, no library: Android's own JobScheduler, which keeps the schedule across restarts, and the
 * app's own WebSocket client ([WsClient]). Nothing is done while there is no friend by username, or while the app is
 * open (it is connected itself then).
 */
object HubPeek {
    private const val JOB = 0x6870 // "hp"
    private const val NOTIFICATION = 0x68706b
    const val DEFAULT_HUB = "wss://gogho.st/hub"
    private const val GREETING = "ghost-hub v1 "

    /**
     * What is signed to a hub that takes it (relay/lib/hub.dart greetingV2, as lib/net/hub_carrier.dart signs it): the
     * words, the host dialled (its length, then it), then the hub's number. A relay that has seen this account sign in
     * so takes no v1 signature from it again, so a hub that says `v2` is always answered with v2.
     */
    private const val GREETING_V2 = "ghost-hub v2 "

    /** The host a v2 sign-in names for [url]: lower case, with its port where it is not the scheme's own. */
    fun hostOf(url: String): String {
        val u = java.net.URI(url)
        val host = (u.host ?: "").lowercase().removePrefix("[").removeSuffix("]")
        val shown = if (host.contains(':')) "[$host]" else host
        val usual = if (u.scheme == "wss") 443 else 80
        return if (u.port != -1 && u.port != usual) "$shown:${u.port}" else shown
    }

    /** What is signed with v2 to the hub reached at [host], for its number [nonce]. */
    fun signedV2(host: String, nonce: ByteArray): ByteArray {
        val h = host.toByteArray(Charsets.UTF_8).take(255).toByteArray()
        return GREETING_V2.toByteArray() + byteArrayOf(h.size.toByte()) + h + nonce
    }

    /** Asks Android for the check, once; already asked, it is left as it is so its clock is not reset. */
    fun schedule(context: Context) {
        val js = context.getSystemService(JobScheduler::class.java) ?: return
        if (js.getPendingJob(JOB) != null) return
        js.schedule(
            JobInfo.Builder(JOB, ComponentName(context, HubPeekJob::class.java))
                .setPeriodic(TimeUnit.MINUTES.toMillis(15))
                .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                .setPersisted(true)
                .build()
        )
    }

    /** Whether anyone is a friend by username: no one, nothing can be held for this phone by them. */
    fun anyFriends(context: Context): Boolean {
        val list = runCatching { JSONArray(Buddies.kept(context)) }.getOrNull() ?: return false
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            if (o.optString("s") == "yes" || o.optString("s") == "asked" || o.optString("s") == "invited") return true
        }
        return false
    }

    /** The hub the app uses: its own setting (lib/net/net.dart `net_hub`) or ours. */
    fun hubUrl(context: Context): String =
        context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("net_hub", "")?.trim()?.ifEmpty { null } ?: DEFAULT_HUB

    /**
     * Signs in to [url] as this phone, only to look; how many packets are held, or null where the hub could not be
     * asked. [sign] signs the hub's greeting with this phone's key.
     */
    fun look(url: String, id: String, key: ByteArray, sign: (ByteArray) -> ByteArray, waitSeconds: Long = 20): Int? {
        var held: Int? = null
        val done = CountDownLatch(1)
        lateinit var ws: WsClient
        ws = WsClient(url, object : WsClient.Listener {
            override fun onOpen() {}
            override fun onBinary(bytes: ByteArray) {}
            override fun onClosed(code: Int?) { done.countDown() }
            override fun onText(text: String) {
                val m = runCatching { JSONObject(text) }.getOrNull() ?: return
                if (m.has("hello")) {
                    // A hub that does not say it knows a look would hand over what it holds: not signed in to.
                    if (!m.optBoolean("peek")) return ws.close()
                    val nonce = m.getString("hello").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
                    // To a hub that takes it, bound to the host dialled; to one from before, as ever.
                    val v2 = m.optBoolean("v2")
                    val host = runCatching { hostOf(url) }.getOrNull() ?: return ws.close()
                    val sig = runCatching { sign(if (v2) signedV2(host, nonce) else GREETING.toByteArray() + nonce) }.getOrNull() ?: return ws.close()
                    val hello = JSONObject().put("id", id).put("key", Base64.getEncoder().encodeToString(key))
                        .put("sig", Base64.getEncoder().encodeToString(sig)).put("peek", true)
                    if (v2) hello.put("v", 2).put("host", host)
                    ws.sendText(hello.toString())
                } else if (m.has("ok")) {
                    // Only an answer that says it was a look is believed.
                    if (m.optBoolean("ok") && m.optBoolean("peek")) held = m.optInt("held", 0)
                    ws.close()
                    done.countDown()
                }
            }
        })
        val t = Thread({ ws.run() }, "hub-peek").apply { isDaemon = true; start() }
        done.await(waitSeconds, TimeUnit.SECONDS)
        ws.close()
        t.join(2000)
        return held
    }

    /** Looks, and shows "New message" where more is held than when it last said so. */
    fun check(context: Context) {
        if (MainActivity.inFront || !anyFriends(context)) return
        val pub = E2e.myPublic(context)
        val held = look(hubUrl(context), Net.idOf(pub), pub, { Net.sign(context, it) }) ?: return
        val state = context.getSharedPreferences("hub_peek", Context.MODE_PRIVATE)
        val told = state.getInt("told", 0)
        if (held == 0) {
            // All taken (the app opened): the next one is new again.
            if (told != 0) state.edit().putInt("told", 0).apply()
            return
        }
        if (held <= told) return
        state.edit().putInt("told", held).apply()
        notify(context)
    }

    private fun notify(context: Context) {
        val open = PendingIntent.getActivity(context, NOTIFICATION, Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(context, Notifier.channel(context))
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle("New message")
            .setContentText("A friend wrote. Open Uplink to read it.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setColor(0xFF4F5BD5.toInt())
            .build()
        try {
            context.getSystemService(android.app.NotificationManager::class.java).notify(NOTIFICATION, n)
        } catch (_: SecurityException) {}
    }

    /** The app opened and is connected: what was held is its now, and "New message" from a look is taken down. */
    fun opened(context: Context) {
        context.getSharedPreferences("hub_peek", Context.MODE_PRIVATE).edit().putInt("told", 0).apply()
        runCatching { context.getSystemService(android.app.NotificationManager::class.java).cancel(NOTIFICATION) }
    }
}

/** Android's side of [HubPeek]: runs the check off the main thread and says when it is done. */
class HubPeekJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread({
            try { HubPeek.check(applicationContext) } catch (_: Exception) {}
            jobFinished(params, false)
        }, "hub-peek-job").start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean = true
}
