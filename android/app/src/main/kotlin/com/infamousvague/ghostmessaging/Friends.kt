package com.infamousvague.ghostmessaging

import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Telephony
import android.telephony.SubscriptionManager
import org.json.JSONObject

/**
 * Friends: the phone's half (lib/friends/friends.dart is the rest). Matt, 2026-11-14: "Add a friend system that
 * allows users to talk without using SMS or MMS but still validate accounts by telephone numbers for now. If both
 * users chatting are on ghost messenger show an 'add friend' button".
 *
 * Two people are friends once each has said so. A friend is someone encryption is on with: exchanging keys by text
 * is what proved each number to the other, and where the two stand is kept on that same record ([E2e.friend]), so
 * it ends when encryption with them does. What friends write goes by the app's routes (lib/net: the relay server
 * first), not as a text.
 *
 * What is here:
 * - A friend's words are **kept with the phone's own messages**, as a text is: the conversation, the list, search,
 *   notifications and a paired computer show them with no second store to read. They are kept sealed, as an
 *   encrypted text is. Which rows came or went by the routes is remembered apart ([isNet]) so the screen can say.
 * - **The wake.** A message the relay server is keeping for a friend whose app is closed is followed by one data
 *   text ([isWake]): nothing is in it, and it is on no screen. The phone it reaches says a message is waiting; the
 *   message itself is fetched when the app opens.
 */
object Friends {
    private const val PREFS = "friends"

    /** How many rows are remembered as having gone by the routes: the newest. An older one reads as a text. */
    const val KEEP = 4000

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // --- which rows went by the routes ---------------------------------------------------------------------------------

    /** The ids of the texts that came or went by the routes, not the phone network. */
    fun netIds(context: Context): Set<Long> =
        (prefs(context).getString("net", "") ?: "").split(',').mapNotNull { it.toLongOrNull() }.toSet()

    fun isNet(context: Context, id: Long): Boolean = id in netIds(context)

    /** Notes that the text in row [id] came or went by the routes; the newest [KEEP] are remembered. */
    @Synchronized
    private fun mark(context: Context, id: Long) {
        val all = (prefs(context).getString("net", "") ?: "").split(',').filter { it.isNotEmpty() }.toMutableList()
        all.add(id.toString())
        prefs(context).edit().putString("net", kept(all, KEEP).joinToString(",")).apply()
    }

    /** The newest [most] of [ids], in the order they were added. */
    fun kept(ids: List<String>, most: Int): List<String> = if (ids.size > most) ids.subList(ids.size - most, ids.size) else ids

    // --- a friend's words, with the phone's messages -------------------------------------------------------------------

    private fun uri(id: Long): Uri = ContentUris.withAppendedId(Telephony.Sms.CONTENT_URI, id)

    /**
     * Words this phone is sending to [address] by the routes: kept as a text on its way, and its row's id returned
     * for [setRow] to say what became of it.
     */
    fun storeOut(context: Context, address: String, words: String): Long {
        val store = Store(context)
        val thread = store.threadFor(listOf(address))
        val body = E2e.wire(context, address, words) ?: words
        val row = store.insertSmsOutbox(thread, address, body, SubscriptionManager.getDefaultSmsSubscriptionId())
            ?: throw IllegalStateException("Could not save the message")
        val id = ContentUris.parseId(row)
        mark(context, id)
        Bus.changed(thread)
        return id
    }

    /** What became of a row from [storeOut]: "sent" (a route took it), "delivered" (their app has it), "failed". */
    fun setRow(context: Context, id: Long, state: String) {
        val store = Store(context)
        when (state) {
            "sent" -> store.setSmsType(uri(id), Telephony.Sms.MESSAGE_TYPE_SENT)
            "delivered" -> { store.setSmsType(uri(id), Telephony.Sms.MESSAGE_TYPE_SENT); store.setSmsStatus(uri(id), Telephony.Sms.STATUS_COMPLETE) }
            "failed" -> store.setSmsType(uri(id), Telephony.Sms.MESSAGE_TYPE_FAILED)
            else -> return
        }
        Bus.changed(store.threadOfSms(uri(id)))
    }

    /** A row from [storeOut] no route could take is taken back: the words go as a text instead, and are kept as one. */
    fun dropRow(context: Context, id: Long) {
        val store = Store(context)
        val thread = store.threadOfSms(uri(id))
        store.deleteMessage("sms", id)
        Bus.changed(thread)
    }

    /** Words that came from [address] by the routes: kept as a text that arrived is, and said as one is. */
    fun storeIn(context: Context, address: String, words: String, sentAt: Long) {
        val store = Store(context)
        val body = E2e.wire(context, address, words) ?: words
        val row = store.insertSmsInbox(address, body, System.currentTimeMillis(), sentAt, SubscriptionManager.getDefaultSmsSubscriptionId()) ?: return
        mark(context, ContentUris.parseId(row))
        val thread = store.threadOfSms(row)
        store.setArchived(thread, false)
        // It came sealed: whatever was said about their texts coming without encryption is over (E2e.arrived).
        try { E2e.arrived(context, address, body) } catch (_: Exception) {}
        Notifier.incoming(context, thread)
        Bus.changed(thread)
    }

    // --- the wake -------------------------------------------------------------------------------------------------------

    /**
     * Whether [bytes], a data text's, are the wake: a whole packet (lib/net/packet.dart: a byte of version and
     * flags, the sender's name in 16 bytes, the envelope), not sealed, whose envelope's kind is `wake`. It is sent
     * in the clear on purpose: there is nothing in it, and the phone can know it for one without the app's screens.
     */
    fun isWake(bytes: ByteArray): Boolean {
        if (bytes.size <= 17) return false
        val flags = bytes[0].toInt() and 0x0f
        if (flags and 1 != 0 || flags and 2 != 0) return false
        return try { JSONObject(String(bytes, 17, bytes.size - 17, Charsets.UTF_8)).optString("k") == "wake" } catch (_: Exception) { false }
    }

    /**
     * A data text came. Where it is the wake, from a friend, and the app's screens are not there to fetch what is
     * waiting, the phone says so. With the screens there, the routes are already fetching it.
     */
    fun woken(context: Context, intent: Intent) {
        val messages = try { Telephony.Sms.Intents.getMessagesFromIntent(intent) } catch (_: Exception) { null } ?: return
        for (m in messages) {
            val from = m.originatingAddress ?: continue
            val bytes = m.userData ?: continue
            if (!isWake(bytes)) continue
            // From a friend, or from someone this phone is in a group with: that group's conversation says it.
            val friend = E2e.friend(context, from) == "yes"
            val shared = if (friend) null else Groups.threadWith(context, from)
            if (!friend && shared == null) continue
            DevLog.add(context, "friends", "wake in")
            if (NetSms.listener != null) continue
            val store = Store(context)
            val thread = shared ?: store.threadFor(listOf(from))
            if (store.isMuted(thread)) continue
            Notifier.waiting(context, thread, store.contact(from)["name"] as? String ?: from)
        }
    }
}

/** Android hands this the data texts addressed to the app's port, as it does NetSmsReceiver (AndroidManifest.xml). */
class FriendWakeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Telephony.Sms.Intents.DATA_SMS_RECEIVED_ACTION) Friends.woken(context.applicationContext, intent)
    }
}
