package com.infamousvague.ghostmessaging

import android.content.Context
import android.net.Uri
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager

/**
 * What the app remembers of its picture messages so that a failure can be told and tried again (Matt, 2026-11-13:
 * "It seems like picture sending is also not working at all almost like MMS isn't working"): why each failed one
 * failed ([MmsWhy]), how the last one sent and the last one fetched went, and the ones announced whose fetching
 * failed, which were lost before this (the carrier keeps a message a few days; the app asked for it once).
 */
object MmsDiag {
    private const val SEP = "\u0001"
    private const val KEEP_MS = 5L * 24 * 3600 * 1000   // a carrier's own patience with a message nobody fetched
    private const val TRIES = 8

    private fun prefs(context: Context) = context.getSharedPreferences("mms", Context.MODE_PRIVATE)

    /** Why the picture message in [row] was not sent, for under it in the conversation. */
    fun failed(context: Context, row: Uri, why: String, smaller: Boolean = false) {
        prefs(context).edit().putString("why:${row.lastPathSegment}", why).apply {
            if (smaller) putBoolean("small:${row.lastPathSegment}", true) else remove("small:${row.lastPathSegment}")
        }.apply()
    }

    /** The picture message in [row] went, or is gone: what was kept about its failing is forgotten. */
    fun cleared(context: Context, row: Uri) {
        prefs(context).edit().remove("why:${row.lastPathSegment}").remove("small:${row.lastPathSegment}").remove("tries:${row.lastPathSegment}").apply()
    }

    /** How many times the picture message in [row] has been sent, this one included. */
    fun tried(context: Context, row: Uri, times: Int) {
        prefs(context).edit().putInt("tries:${row.lastPathSegment}", times).apply()
    }

    fun tries(context: Context, id: Long): Int = prefs(context).getInt("tries:$id", 1)

    /** The carrier refused the picture message [id] as it was: sent again, its pictures go smaller. */
    fun wantsSmaller(context: Context, id: Long): Boolean = prefs(context).getBoolean("small:$id", false)

    fun why(context: Context, id: Long): String? = prefs(context).getString("why:$id", null)

    /** How the last send or the last fetch went: [kind] is "send" or "download". */
    fun note(context: Context, kind: String, ok: Boolean, detail: String) {
        prefs(context).edit().putString("last_$kind", listOf(System.currentTimeMillis(), if (ok) 1 else 0, detail).joinToString(SEP)).apply()
    }

    /** What [note] kept for [kind]: `at` (milliseconds), `ok` and `detail`; null where nothing was. */
    private fun last(context: Context, kind: String): Map<String, Any?>? {
        val f = prefs(context).getString("last_$kind", null)?.split(SEP) ?: return null
        if (f.size < 3) return null
        return mapOf("at" to (f[0].toLongOrNull() ?: 0L), "ok" to (f[1] == "1"), "detail" to f[2])
    }

    /** A picture message announced and not yet fetched: where the carrier keeps it. */
    class Waiting(val location: String, val transactionId: String?, val sub: Int, val since: Long, val tries: Int, val asked: Long) {
        fun line() = listOf(location, transactionId ?: "", sub, since, tries, asked).joinToString(SEP)
        companion object {
            fun of(line: String): Waiting? {
                val f = line.split(SEP)
                if (f.size < 6) return null
                return Waiting(f[0], f[1].ifEmpty { null }, f[2].toIntOrNull() ?: -1, f[3].toLongOrNull() ?: 0L, f[4].toIntOrNull() ?: 0, f[5].toLongOrNull() ?: 0L)
            }
        }
    }

    /** The picture messages announced and not yet fetched, the longest waiting first. */
    fun waiting(context: Context): List<Waiting> =
        prefs(context).getStringSet("waiting", emptySet())!!.mapNotNull { Waiting.of(it) }.sortedBy { it.since }

    private fun keep(context: Context, all: List<Waiting>) {
        prefs(context).edit().putStringSet("waiting", all.map { it.line() }.toSet()).apply()
    }

    /** A fetch of [location] has been asked for: it waits until it comes, counted each time it is asked for. */
    fun fetching(context: Context, location: String, transactionId: String?, sub: Int) {
        val all = waiting(context)
        val had = all.firstOrNull { it.location == location }
        val now = System.currentTimeMillis()
        keep(context, all.filter { it.location != location } + Waiting(location, transactionId ?: had?.transactionId, sub, had?.since ?: now, (had?.tries ?: 0) + 1, now))
    }

    /** [location] came, or will never come. */
    fun fetched(context: Context, location: String?) {
        if (location == null) return
        keep(context, waiting(context).filter { it.location != location })
    }

    /** The waiting ones still worth having: not ones the carrier has long since let go, or asked for too often. */
    private fun live(context: Context): List<Waiting> {
        val now = System.currentTimeMillis()
        val all = waiting(context)
        val live = all.filter { now - it.since < KEEP_MS && it.tries < TRIES }
        if (live.size != all.size) keep(context, live)
        return live
    }

    /**
     * The ones to ask for again now: not one asked for in the last two minutes, whose fetch may still be under way
     * (asking twice would bring the message twice).
     */
    fun worthRetrying(context: Context): List<Waiting> {
        val now = System.currentTimeMillis()
        return live(context).filter { now - it.asked > 120_000 }
    }

    /** What Settings › Android says of picture messages: whether they can go at all, and how the last ones went. */
    fun status(context: Context): Map<String, Any?> {
        val sub = SubscriptionManager.getDefaultSmsSubscriptionId()
        val telephony = context.getSystemService(TelephonyManager::class.java).let { if (sub >= 0) it.createForSubscriptionId(sub) else it }
        val sms = context.getSystemService(SmsManager::class.java).let { if (sub >= 0) it.createForSubscriptionId(sub) else it }
        val config = try { sms.carrierConfigValues } catch (_: Exception) { null }
        return mapOf(
            "dataOn" to try { telephony.isDataEnabled } catch (_: Exception) { null },
            "carrier" to try { telephony.simOperatorName?.ifBlank { null } ?: telephony.networkOperatorName?.ifBlank { null } } catch (_: Exception) { null },
            "sim" to (sub >= 0),
            "allowed" to config?.getBoolean(SmsManager.MMS_CONFIG_MMS_ENABLED, true),
            "maxBytes" to config?.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, 0)?.takeIf { it > 0 },
            "lastSend" to last(context, "send"),
            "lastDownload" to last(context, "download"),
            "waiting" to live(context).size,
        )
    }
}
