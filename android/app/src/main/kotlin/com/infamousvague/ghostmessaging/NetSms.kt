package com.infamousvague.ghostmessaging

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * The SMS route's phone half (lib/net/sms_carrier.dart; Matt, 2026-11-14: "At its core id also like to be able to
 * send almost all chat data and negotiate calls when both parties have sms enabled"): packets as **data texts**.
 *
 * A data text is an SMS addressed to a port. Android hands it to whichever app listens on that port and to no
 * other: it is never written to the phone's messages, and no texting app shows it. So it works whether or not this
 * app is the phone's texting app (Matt: "by default we shouldn't ask users to switch to the app for mms and sms"),
 * needs no internet, and arrives with the app closed. It holds 133 bytes, costs what a text costs, and a few
 * carriers do not pass them at all: the route is for small things that matter.
 *
 * One that comes while the app's screens are not there is kept (the last [KEEP], for [KEEP_FOR]) and handed over
 * when they are ([drain]); what it says is sealed, and is opened in Dart.
 */
object NetSms {
    /** The port the app's data texts are addressed to. Any free one would do; both phones must agree. */
    const val PORT = 16962
    const val KEEP = 60
    const val KEEP_FOR = 24L * 60 * 60 * 1000
    private const val PREFS = "net_sms"

    /** Where a data text goes while the app's screens are there. */
    @Volatile var listener: ((String, ByteArray) -> Unit)? = null

    /** Whether data texts can be sent and heard: a SIM that is ready, and Android's leave to send and receive SMS. */
    fun available(context: Context): Boolean {
        val granted = { p: String -> context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED }
        if (!granted(Manifest.permission.SEND_SMS) || !granted(Manifest.permission.RECEIVE_SMS)) return false
        val telephony = context.getSystemService(TelephonyManager::class.java) ?: return false
        return telephony.simState == TelephonyManager.SIM_STATE_READY
    }

    /** Sends [bytes] to [address] as one data text on [PORT]; 133 bytes at most, which is all one holds. */
    @Suppress("DEPRECATION")
    fun send(context: Context, address: String, bytes: ByteArray) {
        require(bytes.size <= 133) { "too long for a data text" }
        val sms = context.getSystemService(SmsManager::class.java) ?: SmsManager.getDefault()
        sms.sendDataMessage(address, null, PORT.toShort(), bytes, null, null)
        DevLog.add(context, "net", "data text out, ${bytes.size} bytes")
    }

    /** A data text came (NetSmsReceiver). */
    fun received(context: Context, intent: Intent) {
        val messages = try { Telephony.Sms.Intents.getMessagesFromIntent(intent) } catch (_: Exception) { null } ?: return
        for (m in messages) {
            val from = m.originatingAddress ?: continue
            val bytes = m.userData ?: continue
            if (bytes.isEmpty()) continue
            DevLog.add(context, "net", "data text in, ${bytes.size} bytes")
            val to = listener
            if (to != null) to(from, bytes) else keep(context, from, bytes)
        }
    }

    /** Holds a data text that came with nobody listening, for the screens to take when they are there. */
    private fun keep(context: Context, from: String, bytes: ByteArray) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        synchronized(this) {
            val all = kept(prefs.getString("kept", null), System.currentTimeMillis())
            all.add(Triple(from, bytes, System.currentTimeMillis()))
            while (all.size > KEEP) all.removeAt(0)
            prefs.edit().putString("kept", JSONArray(all.map { (a, b, t) -> JSONObject().put("a", a).put("b", Base64.encodeToString(b, Base64.NO_WRAP)).put("t", t) }).toString()).apply()
        }
    }

    /** What is held, read back as who it is from, its bytes and when it came; those older than [KEEP_FOR] left out. */
    private fun kept(json: String?, now: Long): MutableList<Triple<String, ByteArray, Long>> {
        val out = mutableListOf<Triple<String, ByteArray, Long>>()
        if (json == null) return out
        try {
            val list = JSONArray(json)
            for (i in 0 until list.length()) {
                val o = list.getJSONObject(i)
                if (now - o.getLong("t") <= KEEP_FOR) out.add(Triple(o.getString("a"), Base64.decode(o.getString("b"), Base64.NO_WRAP), o.getLong("t")))
            }
        } catch (_: Exception) {}
        return out
    }

    /** What came while the app's screens were not there, oldest first; it is handed over once. */
    fun drain(context: Context): List<Map<String, Any?>> {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        synchronized(this) {
            val all = kept(prefs.getString("kept", null), System.currentTimeMillis())
            prefs.edit().remove("kept").apply()
            return all.map { (a, b, _) -> mapOf("address" to a, "bytes" to b) }
        }
    }
}

/** Android hands this a data text addressed to the app's port (AndroidManifest.xml). */
class NetSmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Telephony.Sms.Intents.DATA_SMS_RECEIVED_ACTION) NetSms.received(context.applicationContext, intent)
    }
}
