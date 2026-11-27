package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.os.Bundle
import android.os.Parcelable
import android.provider.ContactsContract
import android.provider.Settings
import android.provider.Telephony
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Uplink beside Google Messages (Matt, 2026-11-15: "I'd like to see if there is a way we can proxy messages from google
 * messages to ghost so we can support RCS and other features ... I'd like to have a way that people can reliably get
 * text in and out of ghost without needing to switch the default messaging app"; the notifications bridge first).
 *
 * Google Messages stays the default SMS app and keeps RCS. Uplink, given notification access, reads what Google
 * Messages shows in its notifications (Android's MessagingStyle: the conversation, who said what, and when) into a
 * small database of its own, and answers through the notification's own Reply, as a watch or a car does, so an RCS
 * chat is answered as RCS. Texts (SMS, MMS) are in Android's database too, which an app that is not the default can
 * read: a bridged message the database already has is not kept twice ([Store] merges the two).
 *
 * What it cannot see: a message that makes no notification (a muted chat, or one open in Google Messages at the time),
 * RCS from before the bridge was on, and pictures. It relies on Android's notification interface, not on Google
 * Messages' insides, which is what Android Auto and Wear OS rely on too.
 */
object GmBridge {
    const val PACKAGE = "com.google.android.apps.messaging"

    /** What Android puts in place of a message it hides from notification readers (Android 15+, a one-time code). */
    private val HIDDEN = setOf("Sensitive notification content hidden")

    /**
     * Whether Google Messages' status for a message says it is still being brought down (a picture message, MMS): it
     * is told of then with a stand-in in place of its words ("Attachment", "SMS message from Jade"), and again under
     * the same id once it is had. Its statuses as the on-phone connection gives them, in lower case.
     */
    fun downloading(status: String): Boolean = status.lowercase().let { s ->
        s.startsWith("incoming_") && (s.contains("downloading") || s.contains("retrying_auto_download") || s.contains("retrying_manual_download") || s.contains("awaiting_auto_download"))
    }

    /** What to say of a picture message that will not come down by itself; null for any other status. */
    fun notDownloaded(status: String): String? = when (status.lowercase()) {
        "incoming_yet_to_manual_download" -> "Picture message not downloaded: open it in Google Messages to download it"
        "incoming_download_failed", "incoming_download_canceled" -> "Picture message could not be downloaded"
        "incoming_download_failed_too_large" -> "Picture message too large to download"
        "incoming_download_failed_sim_has_no_data" -> "Picture message not downloaded: no mobile data"
        "incoming_expired_or_not_available" -> "Picture message expired before it was downloaded"
        else -> null
    }

    /** Whether the person has given Uplink notification access (Settings › Notifications › Device & app notifications). */
    fun hasAccess(context: Context): Boolean {
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: return false
        val mine = ComponentName(context, GmListener::class.java).flattenToString()
        return enabled.split(':').any { it == mine }
    }

    /** Android's page for granting it, opened at Uplink where Android allows. */
    fun accessIntent(context: Context): Intent =
        Intent("android.settings.NOTIFICATION_LISTENER_DETAIL_SETTINGS")
            .putExtra("android.provider.extra.NOTIFICATION_LISTENER_COMPONENT_NAME", ComponentName(context, GmListener::class.java).flattenToString())
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    fun isInstalled(context: Context): Boolean = try {
        context.packageManager.getPackageInfo(PACKAGE, 0); true
    } catch (_: Exception) { false }

    /** Opens Google Messages, or its page in the Play Store where it is not on the phone (Settings › Messages › RCS). */
    fun open(context: Context): Boolean {
        val launch = context.packageManager.getLaunchIntentForPackage(PACKAGE)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val target = launch ?: Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$PACKAGE")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try { context.startActivity(target); true } catch (_: Exception) {
            try { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=$PACKAGE")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true } catch (_: Exception) { false }
        }
    }

    /** Android's notification settings for Google Messages, where its notifications are made silent. */
    fun openNotificationSettings(context: Context): Boolean = try {
        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, PACKAGE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    } catch (_: Exception) { false }

    // --- how loud Google Messages is (Matt, 2026-11-15: "investigate silencing google messages notifications so we only
    // see thr ones coming through ghost instead"; then "Let's do our best given these options and push out an update").
    //
    // No app but the system's own, or a companion device's, may change another app's notification settings, and a
    // notification is heard before Uplink can take it away. So the person makes Google Messages silent; Uplink watches
    // the channel each of its message notifications comes on (a listener is shown each one's settings) and says which
    // still make a sound or pop up: its "Incoming messages" and any conversation given a channel of its own, which
    // overrides that one. As of the last notification on each: a change is seen when the next one comes.

    private fun channels(context: Context) = context.getSharedPreferences("gm_channels", Context.MODE_PRIVATE)

    /** What [sbn]'s channel is set to, kept by the channel's id. */
    fun noteChannel(context: Context, channel: android.app.NotificationChannel?, title: String?) {
        channel ?: return
        val o = org.json.JSONObject()
            .put("id", channel.id)
            .put("name", channel.name?.toString() ?: channel.id)
            .put("importance", channel.importance)
            .put("sound", channel.sound != null)
            .put("vibrate", channel.shouldVibrate())
            .put("conversation", channel.conversationId ?: org.json.JSONObject.NULL)
            .put("title", title ?: org.json.JSONObject.NULL)
            .put("seen", System.currentTimeMillis())
        channels(context).edit().putString(channel.id, o.toString()).apply()
    }

    /**
     * The channels seen, loudest first: each with whether it still alerts. Alerting is importance Default or more
     * (a sound, or a pop-up at High); Low and below come in silently.
     */
    fun channelList(context: Context): List<Map<String, Any?>> = channels(context).all.values.mapNotNull { v ->
        try {
            val o = org.json.JSONObject(v as String)
            val importance = o.getInt("importance")
            mapOf(
                "id" to o.getString("id"), "name" to o.getString("name"), "importance" to importance,
                "loud" to (importance >= android.app.NotificationManager.IMPORTANCE_DEFAULT),
                "popup" to (importance >= android.app.NotificationManager.IMPORTANCE_HIGH),
                "conversation" to o.optString("conversation").takeIf { it.isNotEmpty() && it != "null" },
                "title" to o.optString("title").takeIf { it.isNotEmpty() && it != "null" },
                "seen" to o.getLong("seen"),
            )
        } catch (_: Exception) { null }
    }.sortedWith(compareByDescending<Map<String, Any?>> { it["importance"] as Int }.thenBy { it["name"] as String })

    /** Android's settings for one of Google Messages' channels (a conversation's own, or "Incoming messages"). */
    fun openChannel(context: Context, id: String, conversation: String?): Boolean {
        val exact = Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, PACKAGE)
            .putExtra(Settings.EXTRA_CHANNEL_ID, id)
            .apply { if (conversation != null) putExtra(Settings.EXTRA_CONVERSATION_ID, conversation) }
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try { context.startActivity(exact); true } catch (_: Exception) { openNotificationSettings(context) }
    }

    /** Whether Google Messages is the default SMS app now. */
    fun isGmDefault(context: Context): Boolean = Telephony.Sms.getDefaultSmsPackage(context) == PACKAGE

    /** A conversation's way to answer, kept while Google Messages keeps it: its Reply and its Mark as read. */
    class Actions(val reply: PendingIntent, val input: RemoteInput, val read: PendingIntent?)

    /** By conversation key, for as long as this process lives (a PendingIntent cannot be written down). */
    private val actions = ConcurrentHashMap<String, Actions>()

    /** What the newest notification of [conv] offered; null once the process has been restarted. */
    fun actionsFor(conv: String): Actions? = actions[conv]

    // --- reading a notification ---------------------------------------------------------------------------------------

    /**
     * One message read from a notification, before it is kept. [mime] and [uri]: the picture (or video, sound, file) it
     * carries, as MessagingStyle gives one, where it does.
     */
    data class Heard(val text: String, val time: Long, val sender: String?, val senderAddress: String?, val out: Boolean, val mime: String? = null, val uri: String? = null)

    /**
     * Whether a notification's words are what Google Messages puts in place of a picture or a file ("Photo",
     * "Attachment", "Sent an image", "SMS message from Jade"), not anything anyone wrote (Matt, 2026-11-26: "some RCS
     * images are just displaying as "attachment""). Kept as words, such a copy was a bubble saying it beside the picture
     * itself, never the same message as it.
     */
    fun standIn(text: String): Boolean {
        // Its marks first (an emoji is two of Kotlin's chars, so they go as words): "📷 Photo".
        var s = text.trim()
        for (mark in listOf("📷", "🎥", "📎", "🎤", "🖼", "️")) s = s.replace(mark, "")
        s = s.trim().lowercase().removeSuffix(".")
        if (s.isEmpty()) return false
        if (s in STAND_INS) return true
        if (Regex("^sent (a|an) (photo|picture|image|gif|sticker|video|attachment|file|voice message|audio message|audio)$").matches(s)) return true
        return Regex("^(sms|mms|rcs|picture|multimedia) message from .+$").matches(s)
    }

    private val STAND_INS = setOf(
        "attachment", "photo", "picture", "image", "gif", "sticker", "video", "audio", "voice message", "audio message",
        "file", "picture message", "multimedia message", "mms", "mms message", "photo message", "image attachment",
    )

    /**
     * Whether a notification's copy of a message ([noted], with [notedMedia] where it carries a picture) is the
     * on-phone connection's of [web] ([webMedia]): the same words, or a picture where the notification said only a
     * stand-in or nothing. Each is told of by its own way within moments of the other.
     */
    fun sameMessage(noted: String, notedMedia: Boolean, web: String, webMedia: Boolean): Boolean {
        if (noted.trim() == web.trim() && (noted.isNotBlank() || notedMedia == webMedia)) return true
        return webMedia && (notedMedia || noted.isBlank() || standIn(noted))
    }

    /**
     * What a conversation's list shows of a message of the bridge's: its words, or what it carries where it has none
     * or only a stand-in ([types]: its parts' kinds). Never "Attachment" for a picture.
     */
    fun summary(text: String, types: List<String>): String {
        val words = text.trim()
        if (words.isNotEmpty() && !standIn(words)) return words
        return when {
            types.any { it.startsWith("image/") && it != "image/svg+xml" } -> "Picture"
            types.any { it.startsWith("video/") } -> "Video"
            types.any { it.startsWith("audio/") } -> "Voice message"
            types.isNotEmpty() -> "Attachment"
            words.isEmpty() -> ""
            else -> standInKind(words)
        }
    }

    /** What a stand-in says a message is: "Picture", "Video", "Voice message", or a picture message for the rest. */
    fun standInKind(text: String): String {
        val s = text.lowercase()
        return when {
            s.contains("video") -> "Video"
            s.contains("audio") || s.contains("voice") -> "Voice message"
            s.contains("photo") || s.contains("picture") || s.contains("image") || s.contains("gif") || s.contains("sticker") -> "Picture"
            s.contains("file") -> "Attachment"
            else -> "Picture message"
        }
    }

    /** A notification of Google Messages', read: which conversation, who is in it, and its messages. */
    data class Read(val conv: String, val title: String?, val group: Boolean, val addresses: List<String>, val messages: List<Heard>)

    /**
     * Reads one of Google Messages' notifications; null for one that is not a conversation (its summary, "sending…",
     * a reminder to set it as default).
     */
    fun read(context: Context, sbn: StatusBarNotification): Read? {
        val n = sbn.notification ?: return null
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
        val extras = n.extras ?: return null
        val messages = @Suppress("DEPRECATION") extras.getParcelableArray(Notification.EXTRA_MESSAGES) ?: return null
        val flagged = extras.getBoolean(Notification.EXTRA_IS_GROUP_CONVERSATION, false)
        val title = (extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) ?: extras.getCharSequence(Notification.EXTRA_TITLE))?.toString()
        @Suppress("DEPRECATION") val me = extras.getParcelable<Person>(Notification.EXTRA_MESSAGING_PERSON)
        // The conversation's key: Google Messages gives each conversation a shortcut of its own; failing that, its tag.
        val conv = n.shortcutId ?: sbn.tag ?: "${sbn.id}"
        val addresses = LinkedHashSet<String>()
        val heard = ArrayList<Heard>()
        for (p in messages) {
            val b = p as? Bundle ?: continue
            val text = b.getCharSequence("text")?.toString() ?: continue
            // Android 15 and later hide what it takes for a one-time code from apps reading notifications. Those are
            // texts, which Android's database holds in full; the hidden copy is not kept.
            if (sbn.notification.extras.getBoolean("android.redacted", false) || text in HIDDEN) continue
            val time = b.getLong("time", 0L).takeIf { it > 0 } ?: sbn.postTime
            @Suppress("DEPRECATION") val person = b.getParcelable<Person>("sender_person")
            val senderName = person?.name?.toString() ?: b.getCharSequence("sender")?.toString()
            // A message with no sender is the person's own (MessagingStyle's way of saying "me").
            val out = person == null && b.getCharSequence("sender") == null || (me != null && person != null && samePerson(me, person))
            val address = if (out) null else person?.let { addressOf(context, it) }
            if (address != null) addresses += address
            // A picture's message names what it carries ("type", "uri"): its words are then a stand-in, or its caption.
            val mime = b.getString("type")?.trim()?.lowercase()?.takeIf { it.isNotEmpty() && !it.startsWith("text/") }
            @Suppress("DEPRECATION") val uri = if (mime == null) null else (b.getParcelable<Uri>("uri"))?.toString()
            val words = if (mime != null && standIn(text)) "" else text
            heard += Heard(words, time, if (out) null else senderName, address, out, mime, uri)
        }
        // Every message hidden (a one-time code, Android 15+): the conversation is still read, so Uplink can notify
        // from Android's own copy of the text.
        if (heard.isEmpty() && messages.isEmpty()) return null
        val group = looksLikeGroup(flagged, title, heard.filter { !it.out }.mapNotNull { it.sender })
        // One to one, with no address from the people in it: the title may be the number itself.
        if (addresses.isEmpty() && !group && title != null) ContactKey.of(title)?.let { addresses += ContactKey.main(title) }
        // One to one: whoever is not you is the one other person.
        val other = if (!group && addresses.size == 1) addresses.first() else null
        val filled = if (other == null) heard else heard.map { if (!it.out && it.senderAddress == null) it.copy(senderAddress = other) else it }
        return Read(conv, title, group, addresses.toList(), filled)
    }

    /**
     * Whether a notification is a group's: Google Messages says so, or two people or more wrote in it. (Not a writer
     * unlike the title: a contact kept under a nickname would take a one-to-one out of its thread.)
     */
    fun looksLikeGroup(flagged: Boolean, @Suppress("UNUSED_PARAMETER") title: String?, senders: List<String>): Boolean =
        flagged || senders.map { it.trim().lowercase() }.toSet().size > 1

    /**
     * The thread a notification's conversation is kept in. A group's notification names its people only as they
     * write, so the addresses it gives are often the newest writer's alone, whose thread is your one-to-one with them:
     * a group's messages were filed, and told of, there (Matt, 2026-11-17: "When a user sends a message in an RCS group
     * chat we get notified in our dm text conversation"). A group goes to the group of its name the on-phone connection
     * knows ([named]), else a thread of its own; never to a thread found from its writers.
     */
    fun pickThread(group: Boolean, named: Long?, synthetic: Long, byAddresses: () -> Long): Long = if (!group) byAddresses() else named ?: synthetic

    /** Whether two of a notification's people are one (its "me" and a line's sender): by key or address, not name. */
    private fun samePerson(a: Person, b: Person): Boolean =
        (a.key != null && a.key == b.key) || (a.uri != null && a.uri == b.uri)

    /** A person's number: from a tel: or mailto: address, or from the contact the address names. */
    private fun addressOf(context: Context, p: Person): String? {
        val uri = p.uri ?: return p.key?.let { k -> ContactKey.of(k)?.let { ContactKey.main(k) } }
        return when {
            uri.startsWith("tel:") -> Uri.decode(uri.removePrefix("tel:")).takeIf { it.isNotBlank() }
            uri.startsWith("mailto:") -> Uri.decode(uri.removePrefix("mailto:"))
            uri.startsWith("content://com.android.contacts") -> numberOfContact(context, Uri.parse(uri))
            else -> null
        }
    }

    /** The number of the contact a contacts address names: the one marked primary first, else the first listed. */
    private fun numberOfContact(context: Context, contact: Uri): String? = try {
        val id = context.contentResolver.query(contact, arrayOf(ContactsContract.Contacts._ID), null, null, null)?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
            ?: return null
        context.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.IS_PRIMARY),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?", arrayOf("$id"),
            "${ContactsContract.CommonDataKinds.Phone.IS_PRIMARY} DESC",
        )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) { null }

    /** Its Reply (the action that takes typed text) and its Mark as read (the one with the read semantic). */
    private fun actionsOf(n: Notification): Actions? {
        var reply: Notification.Action? = null
        var read: Notification.Action? = null
        for (a in n.actions ?: emptyArray()) {
            if (reply == null && a.remoteInputs?.any { it.allowFreeFormInput } == true) reply = a
            if (a.semanticAction == Notification.Action.SEMANTIC_ACTION_MARK_AS_READ) read = a
        }
        val r = reply ?: return null
        val input = r.remoteInputs.first { it.allowFreeFormInput }
        return Actions(r.actionIntent, input, read?.actionIntent)
    }

    // --- keeping what was read -----------------------------------------------------------------------------------------

    /** What reading a notification came to: its thread, whether anything was new, and whether a new one is theirs. */
    data class Kept(val thread: Long, val fresh: Boolean, val incoming: Boolean, val hidden: Boolean, val conv: String = "", val group: Boolean = false, val senders: List<String> = emptyList())

    /** What a notification said, kept; null for one that is not a conversation. */
    fun heard(context: Context, sbn: StatusBarNotification): Kept? {
        val r = read(context, sbn) ?: return null
        actionsOf(sbn.notification)?.let { actions[r.conv] = it }
        val db = Db.get(context)
        val senders = r.messages.filter { !it.out }.mapNotNull { it.senderAddress }
        // A group: the one of its name the on-phone connection knows; else the group picture message (MMS) Android has
        // just been given from one of its writers, so its notification and messages are the group's, not a thread of
        // the writer's own (Matt, 2026-11-18: "the notification comes through as a message from jade not from the
        // group chat").
        val named = if (!r.group) null else r.title?.let { db.webGroupNamed(it, r.conv) } ?: groupThreadNear(context, sbn.postTime, senders)
        val thread = pickThread(r.group, named, syntheticThread(r.conv)) { threadFor(context, r) }
        db.keepConversation(r, thread)
        var fresh = false
        var incoming = false
        for (m in r.messages) if (db.keepMessage(r.conv, m, mediaOf(context, r.conv, m))) { fresh = true; if (!m.out) incoming = true }
        return Kept(thread, fresh, incoming, hidden = r.messages.isEmpty(), conv = r.conv, group = r.group, senders = senders)
    }

    /**
     * The parts of a notification's message that carries a picture, as the bridge keeps a message's (`[{id, type}]`):
     * the picture copied from the notification into the cache the screens read pictures from (GmWeb.file), where
     * Google Messages lets it be read; else the kind alone, `missing`, so it is said to be a picture and not shown as
     * nothing. Null for a message with words alone.
     */
    private val unreadable: MutableSet<Long> = ConcurrentHashMap.newKeySet()

    private fun mediaOf(context: Context, conv: String, m: Heard): String? {
        val mime = m.mime ?: return null
        val id = GmWeb.partId("note:$conv:${m.time}:${m.out}")
        val ending = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"
        val f = File(File(context.cacheDir, "gmmedia").apply { mkdirs() }, "$id.$ending")
        // Every notification of a conversation tells its last few messages again: one not readable is tried once.
        val had = f.length() > 0 || (m.uri != null && id !in unreadable && try {
            context.contentResolver.openInputStream(Uri.parse(m.uri))?.use { i -> f.outputStream().use { o -> i.copyTo(o) } }
            f.length() > 0
        } catch (e: Exception) {
            unreadable += id
            DevLog.add(context, "bridge", "picture of a notification not readable: ${e.javaClass.simpleName}")
            false
        })
        if (!had) {
            f.delete()
            return org.json.JSONArray().put(org.json.JSONObject().put("type", mime).put("missing", true)).toString()
        }
        Db.get(context).keepPart(id, "note:${m.uri}", "", mime, null)
        return org.json.JSONArray().put(org.json.JSONObject().put("id", id).put("type", mime).put("name", "")).toString()
    }

    /**
     * Uplink's notifications in place of Google Messages' (Matt, 2026-11-15: "make the app work without needing to be
     * the default sms app so it can work in tandem and I can turn off notifications from google messages or hide them
     * and proxy everything through ghost"). On unless turned off in Settings › Notifications (`gm_proxy`).
     *
     * Google Messages' own must stay allowed (silent is best): they are what Uplink reads. Each of its message
     * notifications is taken away as it comes and Uplink's own put up, whose Reply goes back through Google Messages.
     */
    fun proxying(context: Context): Boolean =
        !isDefault(context) && context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("gm_proxy", "on") != "off" &&
            // Never hidden where Uplink could not show its own: the person would be told of nothing at all.
            context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()

    /**
     * The conversation's thread in Android's database where its people are known: the same thread its texts are in,
     * so its RCS and its SMS are one conversation in Uplink. Where they are not known, a thread of its own below zero.
     */
    fun threadFor(context: Context, r: Read): Long {
        if (r.addresses.isNotEmpty()) {
            try {
                return Telephony.Threads.getOrCreateThreadId(context, r.addresses.toSet())
            } catch (_: Exception) {}
        }
        return syntheticThread(r.conv)
    }

    /** The thread of the text Android was given most recently, within two minutes of [at]; null where none. */
    fun justArrived(context: Context, at: Long): Long? = try {
        context.contentResolver.query(
            Telephony.Sms.Inbox.CONTENT_URI, arrayOf("thread_id", "date"), "date >= ?", arrayOf("${at - 120_000}"), "date DESC LIMIT 1",
        )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
    } catch (_: Exception) { null }

    /**
     * The thread of the group picture message (MMS, three people or more) Android was given within two minutes of [at]
     * from one of [senders] (any, where none is known); null where there is none yet. Google Messages notifies a group's
     * message as it comes and writes it to Android's database a moment after, so a caller may ask again.
     */
    fun groupThreadNear(context: Context, at: Long, senders: List<String>): Long? = try {
        val r = context.contentResolver
        r.query(Uri.parse("content://mms/inbox"), arrayOf("_id", "thread_id"), "date >= ?", arrayOf("${(at - 120_000) / 1000}"), "date DESC LIMIT 6")?.use { c ->
            var found: Long? = null
            while (found == null && c.moveToNext()) {
                val id = c.getLong(0)
                var from: String? = null
                var count = 0
                r.query(Uri.parse("content://mms/$id/addr"), arrayOf("address", "type"), null, null, null)?.use { a ->
                    while (a.moveToNext()) {
                        count++
                        if (a.getInt(1) == 137) from = a.getString(0)
                    }
                }
                val fromOk = senders.isEmpty() || from?.let { f -> senders.any { Store.sameNumber(it, f) } } == true
                if (count >= 3 && fromOk) found = c.getLong(1)
            }
            found
        }
    } catch (_: Exception) { null }

    /** A thread number of the bridge's own, below zero so it is never one of Android's. */
    fun syntheticThread(conv: String): Long = -1L - (conv.hashCode().toLong() and 0x7fffffffL)

    /** A stand-in conversation for people nobody has texted yet, below zero and the same for the same people. */
    fun pendingThread(addresses: List<String>): Long = syntheticThread("to:" + addresses.map { it.trim() }.sorted().joinToString(","))

    /** The bridge's conversation with exactly these people, where it has one. */
    fun threadOfPeople(context: Context, addresses: List<String>): Long? = try { convFor(Db.get(context), addresses)?.thread } catch (_: Exception) { null }

    /**
     * Answers [conv] through Google Messages' own Reply, so an RCS chat is answered as RCS; false where there is no
     * Reply kept (Google Messages took the notification away, or the app was started since).
     */
    fun reply(context: Context, conv: String, text: String): Boolean {
        val a = actions[conv] ?: return false
        val fill = Intent()
        RemoteInput.addResultsToIntent(arrayOf(a.input), fill, Bundle().apply { putCharSequence(a.input.resultKey, text) })
        return try {
            a.reply.send(context, 0, fill)
            Db.get(context).keepMessage(conv, Heard(text, System.currentTimeMillis(), null, null, out = true))
            true
        } catch (_: PendingIntent.CanceledException) {
            actions.remove(conv)
            false
        }
    }

    /** Whether Uplink is the default SMS app; beside Google Messages it is not. */
    fun isDefault(context: Context): Boolean = try {
        val role = context.getSystemService(android.app.role.RoleManager::class.java)
        role.isRoleAvailable(android.app.role.RoleManager.ROLE_SMS) && role.isRoleHeld(android.app.role.RoleManager.ROLE_SMS)
    } catch (_: Exception) { false }

    /**
     * Sends from Uplink while Google Messages is the default (Messaging.send asks this first then):
     *  1. a conversation Google Messages notified about is answered through its Reply, as RCS where it is RCS;
     *  2. else words to one number go as SMS, which an app that is not the default may send (Android keeps the copy);
     *  3. else (a group, a picture) Google Messages opens with the words filled in, to send from there.
     * The thread it went to, for the screen.
     */
    fun sendBeside(context: Context, addresses: List<String>, body: String, attachments: List<String>): Long {
        val db = Db.get(context)
        val conv = convFor(db, addresses)
        // 0. The on-phone connection (GmWeb), where it is connected and has this conversation: words and pictures,
        //    as Google Messages would send them.
        if (conv != null && GmWeb.knows(conv.conv) && GmWeb.send(conv.conv, body, attachments.mapNotNull { a -> fileOf(context, a)?.let { Triple(it, kindOf(context, a), nameOf(context, a)) } })) return conv.thread
        if (conv != null && attachments.isEmpty() && reply(context, conv.conv, body)) return conv.thread
        val numbers = addresses.filter { ContactKey.of(it) != null }
        if (numbers.size == 1 && addresses.size == 1 && attachments.isEmpty()) {
            val sms = context.getSystemService(android.telephony.SmsManager::class.java)
            val parts = sms.divideMessage(body)
            if (parts.size > 1) sms.sendMultipartTextMessage(numbers[0], null, parts, null, null) else sms.sendTextMessage(numbers[0], null, body, null, null)
            return try { Telephony.Threads.getOrCreateThreadId(context, setOf(numbers[0])) } catch (_: Exception) { conv?.thread ?: -1L }
        }
        context.startActivity(composeIntent(context, if (numbers.isNotEmpty()) numbers else addresses, body, attachments))
        return conv?.thread ?: -1L
    }

    /** What a chosen file is, as Android says (`image/jpeg`, `video/mp4`), or by its ending. */
    private fun kindOf(context: Context, uri: String): String? = try {
        if (uri.startsWith("/")) android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(File(uri).extension.lowercase())
        else context.contentResolver.getType(Uri.parse(uri))
    } catch (_: Exception) { null }

    /** A chosen file's own name, as the picker gave it. */
    private fun nameOf(context: Context, uri: String): String? = try {
        if (uri.startsWith("/")) File(uri).name
        else context.contentResolver.query(Uri.parse(uri), arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (_: Exception) { null }

    /** A picture chosen to send (a content address, or a file), as a file the helper can read. */
    private fun fileOf(context: Context, uri: String): String? = try {
        if (uri.startsWith("/")) uri else {
            val f = File(File(context.cacheDir, "gmsend").apply { mkdirs() }, "${System.currentTimeMillis()}-${uri.hashCode().toUInt()}")
            context.contentResolver.openInputStream(Uri.parse(uri))?.use { inp -> f.outputStream().use { inp.copyTo(it) } }
            f.absolutePath
        }
    } catch (_: Exception) { null }

    /** The bridged conversation [addresses] are: the same people, or, for one known only by its title, that title. */
    private fun convFor(db: Db, addresses: List<String>): Conv? {
        val keys = addresses.mapNotNull { ContactKey.of(it) }.toSet()
        return db.conversations().firstOrNull { c ->
            (keys.isNotEmpty() && c.addresses.mapNotNull { a -> ContactKey.of(a) }.toSet() == keys) ||
                (addresses.size == 1 && c.title != null && c.title == addresses[0])
        }
    }

    /** Marks [conv] read in Google Messages too: through the on-phone connection, or its notification's Mark as read. */
    fun markRead(context: Context, conv: String) {
        GmWeb.read(conv)
        try { actions[conv]?.read?.send() } catch (_: Exception) {}
    }

    /**
     * Google Messages' compose page with [to] and [text] filled in, and the pictures with them (Matt, 2026-11-15: "Does
     * this also proxy videos and images"): for what the bridge cannot send itself.
     */
    fun composeIntent(context: Context, to: List<String>, text: String, attachments: List<String> = emptyList()): Intent {
        if (attachments.isEmpty()) {
            return Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:" + to.joinToString(";") { Uri.encode(it) }))
                .putExtra("sms_body", text).setPackage(PACKAGE).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        // A file of the app's own is handed over by the app's provider, which serves its MMS folder.
        val uris = ArrayList(attachments.map { a ->
            if (!a.startsWith("/")) Uri.parse(a) else {
                val copy = File(MmsFileProvider.dir(context), "share-${File(a).name}")
                File(a).copyTo(copy, overwrite = true)
                MmsFileProvider.uriFor(context, copy)
            }
        })
        val types = uris.map { context.contentResolver.getType(it) ?: "image/*" }.distinct()
        return Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE)
            .setType(types.singleOrNull() ?: "*/*")
            .apply { if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris[0]) else putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris) }
            .putExtra("address", to.joinToString(";"))
            .putExtra("sms_body", text)
            .putExtra(Intent.EXTRA_TEXT, text)
            .setPackage(PACKAGE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    // --- the database ------------------------------------------------------------------------------------------------

    /** The bridge's own small database: conversations Google Messages showed, and their messages. */
    class Db private constructor(context: Context) : SQLiteOpenHelper(context, "gm_bridge.db", null, 4) {
        companion object {
            @Volatile private var one: Db? = null
            fun get(context: Context): Db = one ?: synchronized(this) { one ?: Db(context.applicationContext).also { one = it } }

            /**
             * Each conversation with its newest message as its conversation shows it: not a picture message still coming
             * down, whose words are a stand-in (Store.withBridgedMessages leaves those out too).
             *
             * A message kept from a notification has no status of Google Messages' own (NULL), and in SQL a NULL that is
             * LIKE anything is neither true nor false: `NOT (out = 0 AND status LIKE …)` was then neither, and the row
             * was passed over. So every incoming message the notifications brought was left out of this, and a
             * conversation with nothing else in it was left out whole: its row in the list said its last SMS, or was not
             * there (0.12.44 and 0.12.45; Matt, 2026-11-26: "right now they don't always show the last message"). A
             * status that is not there is taken as none.
             */
            const val CONVERSATIONS =
                "SELECT c.conv, c.thread, c.title, c.grp, c.addresses, m.text, m.time, m.out, (SELECT COUNT(*) FROM msg u WHERE u.conv = c.conv AND u.out = 0 AND u.read = 0), m.media " +
                    "FROM conv c JOIN msg m ON m.id = (SELECT id FROM msg x WHERE x.conv = c.conv AND NOT (x.out = 0 AND COALESCE(x.status, '') LIKE 'incoming\\_%' ESCAPE '\\' " +
                    "AND (COALESCE(x.status, '') LIKE '%downloading%' OR COALESCE(x.status, '') LIKE '%retrying%' OR COALESCE(x.status, '') LIKE '%awaiting_auto_download%')) ORDER BY time DESC LIMIT 1) ORDER BY m.time DESC"
        }

        // Written ahead (WAL), so the helper's thread and the list's reads do not wait on each other. Set the
        // way Android allows: a PRAGMA that answers is refused by execSQL ("Queries can be performed using
        // SQLiteDatabase query or rawQuery methods only"), which stopped every send in 0.7.30.
        init { setWriteAheadLoggingEnabled(true) }

        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL("CREATE TABLE conv (conv TEXT PRIMARY KEY, thread INTEGER, title TEXT, grp INTEGER, addresses TEXT, updated INTEGER)")
            db.execSQL("CREATE TABLE msg (id INTEGER PRIMARY KEY AUTOINCREMENT, conv TEXT, text TEXT, time INTEGER, sender TEXT, address TEXT, out INTEGER, read INTEGER DEFAULT 0, UNIQUE(conv, time, text, out))")
            db.execSQL("CREATE INDEX msg_conv ON msg(conv, time)")
            onUpgrade(db, 1, 4)
        }

        override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) {
            // 2: Google Messages' own id for a message, its status, pictures and reactions, from the on-phone
            // connection (GmWeb.kt); a picture's way to be brought down, by the number the screens know it by.
            if (old < 2) {
                db.execSQL("ALTER TABLE msg ADD COLUMN gm_id TEXT")
                db.execSQL("ALTER TABLE msg ADD COLUMN status TEXT")
                db.execSQL("ALTER TABLE msg ADD COLUMN media TEXT")
                db.execSQL("ALTER TABLE msg ADD COLUMN reactions TEXT")
                db.execSQL("CREATE UNIQUE INDEX msg_gm ON msg(gm_id)")
                db.execSQL("CREATE TABLE part (id INTEGER PRIMARY KEY, media TEXT, key TEXT, mime TEXT, name TEXT)")
            }
            // 3: a picture's small copy (Google Messages' thumbnail), brought down where the picture itself can't be.
            if (old < 3) {
                db.execSQL("ALTER TABLE part ADD COLUMN thumb TEXT")
                db.execSQL("ALTER TABLE part ADD COLUMN thumb_key TEXT")
            }
            // 4: Google Messages' own lines about the conversation ("Texting with Katelynn (SMS/MMS)", its tombstones) and
            // the empty messages that came with them were kept as texts, one after another (Matt, 2026-11-17, with two
            // screenshots of a thread full of them): taken out, as GmWeb.keepMessage now leaves them out.
            if (old < 4) {
                db.execSQL("DELETE FROM msg WHERE status LIKE '%tombstone%' OR (TRIM(COALESCE(text, '')) = '' AND media IS NULL AND gm_id IS NOT NULL)")
            }
        }


        /** A conversation as the on-phone connection reads it: by Google Messages' own id. */
        /** The conversations kept for [thread], by Google Messages' (or the notification's) own id. */
        fun webConvsOf(thread: Long): List<String> = readableDatabase.rawQuery("SELECT conv FROM conv WHERE thread = ?", arrayOf(thread.toString())).use { c ->
            buildList { while (c.moveToNext()) add(c.getString(0)) }
        }

        fun keepWebConversation(conv: String, thread: Long, title: String?, group: Boolean, addresses: List<String>) {
            writableDatabase.insertWithOnConflict("conv", null, ContentValues().apply {
                put("conv", conv); put("thread", thread); put("title", title); put("grp", if (group) 1 else 0)
                put("addresses", addresses.joinToString("\u001f")); put("updated", System.currentTimeMillis())
            }, SQLiteDatabase.CONFLICT_REPLACE)
        }

        /**
         * A message as the on-phone connection reads it, by Google Messages' own id: kept once, its status and
         * reactions brought up to date when it comes again. A copy the notification bridge already kept (the same
         * words, the same side, within three minutes, in a conversation of the same thread) becomes this one.
         * True where it is new.
         */
        fun keepWebMessage(conv: String, thread: Long, gmId: String, text: String, time: Long, sender: String?, address: String?, out: Boolean, status: String, media: String?, reactions: String?, read: Boolean): Boolean {
            val db = writableDatabase
            val update = ContentValues().apply { put("status", status); put("reactions", reactions); if (media != null) put("media", media); if (read) put("read", 1) }
            // Told of again: its words too, where they have changed (a stand-in kept before this fix, now had in full;
            // an edit), so it is the same as Android's copy and shown once.
            if (db.update("msg", ContentValues(update).apply { if (text.isNotBlank()) put("text", text) }, "gm_id = ?", arrayOf(gmId)) > 0) return false
            // The notification's copy, the nearest first: the same words, or a picture it said only "Photo" or
            // "Attachment" of (sameMessage). It becomes this one, words and all.
            val hasMedia = !media.isNullOrBlank() && media != "[]"
            db.rawQuery(
                "SELECT m.id, m.text, m.media FROM msg m JOIN conv c ON c.conv = m.conv WHERE c.thread = ? AND m.gm_id IS NULL AND m.out = ? AND ABS(m.time - ?) < 180000 ORDER BY ABS(m.time - ?)",
                arrayOf("$thread", if (out) "1" else "0", "$time", "$time"),
            ).use { c ->
                while (c.moveToNext()) {
                    if (!sameMessage(c.getString(1) ?: "", !c.getString(2).isNullOrBlank(), text, hasMedia)) continue
                    db.update("msg", ContentValues(update).apply { put("gm_id", gmId); put("conv", conv); put("time", time); put("text", text) }, "id = ?", arrayOf("${c.getLong(0)}"))
                    return false
                }
            }
            val id = db.insertWithOnConflict("msg", null, ContentValues(update).apply {
                put("conv", conv); put("gm_id", gmId); put("text", text); put("time", time); put("sender", sender); put("address", address)
                put("out", if (out) 1 else 0); put("read", if (out || read) 1 else 0)
            }, SQLiteDatabase.CONFLICT_IGNORE)
            return id != -1L
        }

        fun keepPart(id: Long, media: String, key: String, mime: String, name: String?, thumb: String? = null, thumbKey: String? = null) {
            writableDatabase.insertWithOnConflict("part", null, ContentValues().apply {
                put("id", id); put("media", media); put("key", key); put("mime", mime); put("name", name); put("thumb", thumb); put("thumb_key", thumbKey)
            }, SQLiteDatabase.CONFLICT_REPLACE)
        }

        /** A picture's thumbnail and its key, where Google Messages gave one. */
        fun thumbOf(id: Long): Pair<String, String>? = readableDatabase.rawQuery("SELECT thumb, thumb_key FROM part WHERE id = ?", arrayOf("$id")).use { c ->
            if (c.moveToFirst() && !c.getString(0).isNullOrBlank()) c.getString(0) to (c.getString(1) ?: "") else null
        }

        fun part(id: Long): Triple<String, String, String>? = readableDatabase.rawQuery("SELECT media, key, mime FROM part WHERE id = ?", arrayOf("$id")).use { c ->
            if (c.moveToFirst()) Triple(c.getString(0), c.getString(1), c.getString(2)) else null
        }

        /** The newest message of [conv] Google Messages knows by its id: what marking it read goes as far as. */
        fun newestWebId(conv: String): String? = readableDatabase.rawQuery("SELECT gm_id FROM msg WHERE conv = ? AND gm_id IS NOT NULL ORDER BY time DESC LIMIT 1", arrayOf(conv)).use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

        fun webConversations(): Set<String> = readableDatabase.rawQuery("SELECT DISTINCT conv FROM msg WHERE gm_id IS NOT NULL", null).use { c ->
            buildSet { while (c.moveToNext()) add(c.getString(0)) }
        }

        /** The thread of the group named [title] that the on-phone connection keeps (its messages have Google's ids). */
        fun webGroupNamed(title: String, except: String): Long? = readableDatabase.rawQuery(
            "SELECT c.thread FROM conv c WHERE c.grp = 1 AND c.title = ? AND c.conv != ? AND EXISTS (SELECT 1 FROM msg m WHERE m.conv = c.conv AND m.gm_id IS NOT NULL) ORDER BY c.updated DESC LIMIT 1",
            arrayOf(title, except),
        ).use { c -> if (c.moveToFirst()) c.getLong(0) else null }

        /** Moves the bridge's conversation [conv] to [thread] (its group found in Android's database after all). */
        fun moveConversation(conv: String, thread: Long) {
            writableDatabase.update("conv", ContentValues().apply { put("thread", thread) }, "conv = ?", arrayOf(conv))
        }

        fun keepConversation(r: Read, thread: Long) {
            writableDatabase.insertWithOnConflict("conv", null, ContentValues().apply {
                put("conv", r.conv); put("thread", thread); put("title", r.title); put("grp", if (r.group) 1 else 0)
                put("addresses", r.addresses.joinToString("\u001f")); put("updated", System.currentTimeMillis())
            }, SQLiteDatabase.CONFLICT_REPLACE)
        }

        /** True where it is new. An outgoing message seen twice (sent here, then shown back by Google Messages) is one. */
        fun keepMessage(conv: String, m: Heard, media: String? = null): Boolean {
            val out = if (m.out) "1" else "0"
            if (m.out) {
                // Ours, sent through the Reply moments ago and now shown back: the same words within two minutes.
                readableDatabase.rawQuery("SELECT 1 FROM msg WHERE conv = ? AND out = 1 AND text = ? AND ABS(time - ?) < 120000", arrayOf(conv, m.text, "${m.time}")).use { c ->
                    if (c.moveToFirst()) return false
                }
            }
            val hasMedia = media != null
            // Told of again (each notification says a conversation's last few again): one kept when its picture was a
            // stand-in's words ("Photo") is that picture now.
            readableDatabase.rawQuery("SELECT id, text FROM msg WHERE conv = ? AND time = ? AND out = ?", arrayOf(conv, "${m.time}", out)).use { c ->
                while (c.moveToNext()) {
                    val had = c.getString(1) ?: ""
                    if (had == m.text) return false
                    if (hasMedia && (had.isBlank() || standIn(had))) {
                        writableDatabase.update("msg", ContentValues().apply { put("text", m.text); put("media", media) }, "id = ?", arrayOf("${c.getLong(0)}"))
                        return false
                    }
                }
            }
            // The on-phone connection has it already (it was quicker than the notification): the same words, or the
            // picture this says only "Photo" of.
            readableDatabase.rawQuery(
                "SELECT m.text, m.media FROM msg m JOIN conv c ON c.conv = m.conv WHERE c.thread = (SELECT thread FROM conv WHERE conv = ?) AND m.gm_id IS NOT NULL AND m.out = ? AND ABS(m.time - ?) < 180000",
                arrayOf(conv, out, "${m.time}"),
            ).use { c ->
                while (c.moveToNext()) if (sameMessage(m.text, hasMedia, c.getString(0) ?: "", !c.getString(1).isNullOrBlank() && c.getString(1) != "[]")) return false
            }
            val id = writableDatabase.insertWithOnConflict("msg", null, ContentValues().apply {
                put("conv", conv); put("text", m.text); put("time", m.time); put("sender", m.sender); put("address", m.senderAddress); put("out", if (m.out) 1 else 0)
                if (media != null) put("media", media)
            }, SQLiteDatabase.CONFLICT_IGNORE)
            return id != -1L
        }

        /** The conversations kept, newest first. */
        fun conversations(): List<Conv> = readableDatabase.rawQuery(CONVERSATIONS, null).use { c ->
            buildList {
                while (c.moveToNext()) add(Conv(c.getString(0), c.getLong(1), c.getString(2), c.getInt(3) == 1, c.getString(4).split('\u001f').filter { it.isNotEmpty() }, c.getString(5), c.getLong(6), c.getInt(7) == 1, c.getInt(8), c.getString(9)))
            }
        }

        fun messagesOfThread(thread: Long, limit: Int): List<Msg> = readableDatabase.rawQuery(
            "SELECT m.id, m.conv, m.text, m.time, m.sender, m.address, m.out, m.read, m.status, m.media, m.reactions FROM msg m JOIN conv c ON c.conv = m.conv WHERE c.thread = ? ORDER BY m.time DESC LIMIT ?",
            arrayOf("$thread", "$limit"),
        ).use { c ->
            buildList { while (c.moveToNext()) add(Msg(c.getLong(0), c.getString(1), c.getString(2), c.getLong(3), c.getString(4), c.getString(5), c.getInt(6) == 1, c.getInt(7) == 1, c.getString(8), c.getString(9), c.getString(10))) }
        }

        fun convOfThread(thread: Long): String? = readableDatabase.rawQuery("SELECT conv FROM conv WHERE thread = ? ORDER BY updated DESC LIMIT 1", arrayOf("$thread")).use { c -> if (c.moveToFirst()) c.getString(0) else null }

        fun markRead(thread: Long) {
            writableDatabase.execSQL("UPDATE msg SET read = 1 WHERE conv IN (SELECT conv FROM conv WHERE thread = ?)", arrayOf(thread))
        }

        /** Google Messages' own id of the bridge's message [id]. */
        fun gmIdOf(id: Long): String? = readableDatabase.rawQuery("SELECT gm_id FROM msg WHERE id = ?", arrayOf("$id")).use { c -> if (c.moveToFirst()) c.getString(0) else null }

        /** Google Messages' own id of a text in [thread]: the same words, the same side, within three minutes. */
        fun gmIdLike(thread: Long, text: String, out: Boolean, time: Long): String? = readableDatabase.rawQuery(
            "SELECT m.gm_id FROM msg m JOIN conv c ON c.conv = m.conv WHERE c.thread = ? AND m.gm_id IS NOT NULL AND m.out = ? AND m.text = ? AND ABS(m.time - ?) < 180000 ORDER BY ABS(m.time - ?) LIMIT 1",
            arrayOf("$thread", if (out) "1" else "0", text, "$time", "$time"),
        ).use { c -> if (c.moveToFirst()) c.getString(0) else null }

        fun forgetMessage(id: Long) {
            writableDatabase.delete("msg", "id = ?", arrayOf("$id"))
        }

        fun forget(thread: Long) {
            writableDatabase.execSQL("DELETE FROM msg WHERE conv IN (SELECT conv FROM conv WHERE thread = ?)", arrayOf(thread))
            writableDatabase.execSQL("DELETE FROM conv WHERE thread = ?", arrayOf(thread))
        }
    }

    /** A row of each table: a conversation as the bridge knows it (its newest words and when), and a message. */
    data class Conv(val conv: String, val thread: Long, val title: String?, val group: Boolean, val addresses: List<String>, val text: String, val time: Long, val out: Boolean, val unread: Int, val media: String? = null)
    data class Msg(val id: Long, val conv: String, val text: String, val time: Long, val sender: String?, val address: String?, val out: Boolean, val read: Boolean, val status: String? = null, val media: String? = null, val reactions: String? = null)
}

/**
 * Google Messages' notifications, as they come and go ([GmBridge]). Every other app's are ignored the moment they
 * arrive: nothing of theirs is read or kept.
 */
class GmListener : NotificationListenerService() {
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName != GmBridge.PACKAGE) return
        val context = applicationContext
        try {
            val kept = GmBridge.heard(context, sbn)
            if (kept?.fresh == true) Bus.changed(-1)
            // How loud the channel it came on is (the guide's last step, Settings › Notifications).
            if (sbn.notification.category == Notification.CATEGORY_MESSAGE) noteRanking(sbn)
            if (!GmBridge.proxying(context)) return
            if (sbn.notification.category != Notification.CATEGORY_MESSAGE) return
            val summary = sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY != 0
            // The group's summary goes once none of its conversations' notifications is left up.
            if (summary) {
                if ((activeNotifications ?: emptyArray()).none { it.packageName == GmBridge.PACKAGE && it.key != sbn.key && it.notification.flags and Notification.FLAG_GROUP_SUMMARY == 0 && it.notification.category == Notification.CATEGORY_MESSAGE }) cancelNotification(sbn.key)
                return
            }
            if (kept == null) return
            // Uplink's own first; Google Messages' taken away only once it is up (Matt, 2026-11-15, a code text that
            // showed nowhere: Uplink had taken Google Messages' away and had nothing of its own yet). A text Android
            // hid from the bridge (a code) is read from Android's database, which Google Messages may write a moment
            // after notifying: asked again for a few seconds. With the on-phone connection up, it notifies (GmWeb).
            val key = sbn.key
            Thread {
                var shown = GmWeb.connected
                if (!shown && (kept.incoming || kept.hidden)) {
                    for (wait in longArrayOf(250, 750, 1500, 2500, 4000)) {
                        Thread.sleep(wait)
                        // A hidden text hides its conversation's name too, so the bridge could not tell which thread it
                        // is: the text Android has just been given, the newest received in the last two minutes, is it.
                        var thread = if (kept.thread >= 0 || !kept.hidden) kept.thread else GmBridge.justArrived(context, sbn.postTime) ?: continue
                        // A group not yet found in Android's database: its picture message may have been written since.
                        if (thread < 0 && kept.group) GmBridge.groupThreadNear(context, sbn.postTime, kept.senders)?.let { found ->
                            GmBridge.Db.get(context).moveConversation(kept.conv, found)
                            Bus.changed(-1)
                            thread = found
                        }
                        shown = try { Notifier.incoming(context, thread) } catch (e: Exception) {
                            DevLog.add(context, "bridge", "Uplink's notification could not be shown: ${e.javaClass.simpleName}: ${e.message}"); false
                        }
                        if (shown) break
                    }
                } else if (!kept.incoming && !kept.hidden) {
                    // An update to one already shown (a reply of yours shown back): Uplink's stands as it is.
                    shown = true
                }
                if (shown) try { cancelNotification(key) } catch (_: Exception) {}
                else DevLog.add(context, "bridge", "Google Messages' notification left up: Uplink had nothing to show for it")
            }.start()
        } catch (e: Exception) {
            DevLog.add(context, "bridge", "A Google Messages notification could not be read: ${e.javaClass.simpleName}")
        }
    }

    /**
     * Android's SMS database, watched while Uplink is not the default: Google Messages writes the texts there, and
     * nothing else tells Uplink a text came or went. Changes close together are told once.
     */
    private var watcher: android.database.ContentObserver? = null

    private fun watch() {
        if (watcher != null || GmBridge.isDefault(this)) return
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val tell = Runnable { Bus.changed(-1) }
        watcher = object : android.database.ContentObserver(main) {
            override fun onChange(selfChange: Boolean) {
                main.removeCallbacks(tell)
                main.postDelayed(tell, 400)
            }
        }.also { contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, it) }
    }

    override fun onListenerDisconnected() {
        watcher?.let { contentResolver.unregisterContentObserver(it) }
        watcher = null
    }

    /** Reads the channel [sbn] came on from its ranking, and has GmBridge note how that channel is set. */
    private fun noteRanking(sbn: StatusBarNotification) {
        try {
            val r = Ranking()
            if (!currentRanking.getRanking(sbn.key, r)) return
            val title = sbn.notification.extras?.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE) ?: sbn.notification.extras?.getCharSequence(Notification.EXTRA_TITLE)
            GmBridge.noteChannel(applicationContext, r.channel, title?.toString())
        } catch (_: Exception) {}
    }

    override fun onListenerConnected() {
        watch()
        // The on-phone Google Messages connection, kept running while Android keeps this listener (GmWeb).
        if (GmWeb.hasSession(applicationContext)) GmWeb.start(applicationContext)
        for (sbn in activeNotifications ?: emptyArray()) if (sbn.packageName == GmBridge.PACKAGE && sbn.notification.category == Notification.CATEGORY_MESSAGE) noteRanking(sbn)
        // What Google Messages shows now, read as the bridge starts (after a restart, or access just given).
        try {
            var fresh = false
            for (sbn in activeNotifications ?: emptyArray()) if (sbn.packageName == GmBridge.PACKAGE && GmBridge.heard(applicationContext, sbn)?.fresh == true) fresh = true
            if (fresh) Bus.changed(-1)
        } catch (_: Exception) {}
    }
}
