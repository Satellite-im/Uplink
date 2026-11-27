package com.infamousvague.ghostmessaging

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Who is known to have Uplink, and the backgrounds they share ([BackgroundWire]).
 *
 * A number is known to have the app once a text only the app writes has come from it: an encryption key, a sealed
 * text, or a background. A background is synced by itself only with people known to have it, since to anyone else
 * it would arrive as a line of letters.
 *
 * A background that arrives becomes the conversation's own (the `chat_bg_<thread>` choice the screen reads, in the
 * "ui" preferences), unless the person switched that off (Settings › Chat background › Wear backgrounds shared with
 * you).
 */
object Backgrounds {
    private const val TAG = "GhostMessaging"
    private const val PEERS = "peers"

    private fun ui(context: Context) = context.applicationContext.getSharedPreferences("ui", Context.MODE_PRIVATE)
    private fun peers(context: Context) = context.applicationContext.getSharedPreferences(PEERS, Context.MODE_PRIVATE)

    /** A text only Uplink writes came from [address]. */
    fun sawGhost(context: Context, address: String) {
        val key = E2e.norm(address)
        if (key.isEmpty() || peers(context).contains(key)) return
        peers(context).edit().putBoolean(key, true).apply()
    }

    /** Whether [body], as it arrived, is one of the texts only Uplink writes. */
    fun isGhostText(body: String): Boolean = E2eCrypto.keyIn(body) != null || E2eCrypto.isSealed(body) || BackgroundWire.valueIn(body) != null

    /** Whether everyone in [addresses] is known to have the app: a text of its own came from them, or their key is here. */
    fun allKnown(context: Context, addresses: List<String>): Boolean =
        addresses.isNotEmpty() && addresses.all { peers(context).contains(E2e.norm(it)) || E2e.hasTheirKey(context, it) }

    /**
     * [value] arrived in [thread]: the conversation wears it from now. [picture] is the message's picture, for
     * `image`. Returns false where it was not taken (switched off, or a picture that did not come).
     */
    fun received(context: Context, thread: Long, value: String, picture: ByteArray? = null): Boolean {
        if (thread < 0 || !BackgroundWire.valid(value)) return false
        if (ui(context).getString("bg_accept", "on") == "off") return false
        val raw = if (value == "image") {
            val bytes = picture ?: return false
            try {
                val dir = File(context.filesDir, "backgrounds").apply { mkdirs() }
                val file = File(dir, "t$thread-${System.currentTimeMillis()}.jpg")
                file.writeBytes(bytes)
                dir.listFiles { f -> f.name.startsWith("t$thread-") && f != file }?.forEach { it.delete() }
                "image:${file.absolutePath}"
            } catch (e: Exception) { Log.e(TAG, "shared background", e); return false }
        } else value
        // The same word is kept as what was last synced, so this phone does not send it straight back.
        ui(context).edit().putString("chat_bg_$thread", raw).putString("chat_bg_synced_$thread", raw).apply()
        Bus.prefsChanged()
        return true
    }

    /** This phone sent [raw] (the choice as the screen keeps it) to [thread]'s people. */
    fun sent(context: Context, thread: Long, raw: String) {
        ui(context).edit().putString("chat_bg_synced_$thread", raw).apply()
        Bus.prefsChanged()
    }
}
