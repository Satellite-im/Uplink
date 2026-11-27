package com.infamousvague.ghostmessaging

import android.app.IntentService
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.database.Cursor
import android.graphics.drawable.Icon
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.Telephony
import java.io.File

/** Notifications: one per conversation, its newest messages in it, with Reply and Mark as read. */
object Notifier {
    private const val CHANNEL = "messages"
    private const val CHANNEL_ALERTS = "alerts"
    const val EXTRA_THREAD = "thread"
    const val KEY_REPLY = "reply"

    /**
     * The messages' channel, with the message sound chosen in Settings › Sounds (lib/sounds.dart; Matt, 2026-11-16:
     * "give me the options to pick from for the calling and notification sounds"). A channel's sound cannot change
     * once it is made, so each sound has a channel of its own ("messages-sound-<take>"), the others are taken away as
     * one is chosen, and the first channel ("messages", the phone's own sound) goes as well.
     */
    fun channel(context: Context): String {
        val ui = context.getSharedPreferences("ui", Context.MODE_PRIVATE)
        val take = (ui.getString("sound_message", "4") ?: "4").filter { it.isDigit() }.ifEmpty { "4" }
        val silent = ui.getString("sounds", "on") == "off"
        return if (silent) "$CHANNEL-sound-off" else "$CHANNEL-sound-$take"
    }

    /** Android's notification manager, with the app's channels made (and message channels of other sounds removed). */
    private fun manager(context: Context): NotificationManager {
        val nm = context.getSystemService(NotificationManager::class.java)
        val id = channel(context)
        if (nm.getNotificationChannel(id) == null) {
            for (old in nm.notificationChannels) {
                if (old.id == CHANNEL || (old.id.startsWith("$CHANNEL-sound-") && old.id != id)) try { nm.deleteNotificationChannel(old.id) } catch (_: Exception) {}
            }
            nm.createNotificationChannel(NotificationChannel(id, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "New text messages"
                enableVibration(true)
                // A conversation's notification may sit on the side of the screen as a bubble (Bubbles.kt), where
                // Android's own setting for the app and the conversation lets it.
                setAllowBubbles(true)
                val take = id.substringAfterLast('-')
                if (take == "off") {
                    setSound(null, null)
                } else {
                    val raw = context.resources.getIdentifier("notify_message_$take", "raw", context.packageName)
                    if (raw != 0) setSound(Uri.parse("android.resource://${context.packageName}/$raw"), AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build())
                }
            })
        }
        if (nm.getNotificationChannel(CHANNEL_ALERTS) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ALERTS, "Problems", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "A message that could not be sent or downloaded"
            })
        }
        return nm
    }

    /** Texts keep to a group of their own, apart from the paired-computer notification's ("desk"). */
    private const val GROUP = "texts"

    /**
     * The conversation's shortcut, which makes its notification a conversation's (Matt, 2026-11-14: "can we make it
     * a seperate notification chain", of the paired-computer notification beside the texts): Android puts a
     * notification with a long-lived conversation shortcut in the shade's Conversations section, at its top and
     * apart from every other notification, the paired-computer one included (that one is Silent, at its foot).
     * Null where Android would not take it; the notification is then an ordinary one, as before.
     */
    /**
     * The face Android shows for a conversation's notification: the contact's photo, or the first letter of their
     * name on a colour of its own (the app's avatars' way), drawn here since the shade cannot read the contacts.
     */
    private fun face(context: Context, name: String, photo: String?): Icon {
        val side = 192
        if (photo != null) try {
            context.contentResolver.openInputStream(Uri.parse(photo))?.use { stream ->
                BitmapFactory.decodeStream(stream)?.let { return Icon.createWithAdaptiveBitmap(squareOf(it, side)) }
            }
        } catch (_: Exception) {}
        val hues = intArrayOf(0xFF4F5BD5.toInt(), 0xFF2A9D4B.toInt(), 0xFFE0662A.toInt(), 0xFFB04CC8.toInt(), 0xFF1E88C8.toInt(), 0xFFD6455D.toInt())
        // Adaptive: a square drawn larger than it is shown, its middle two thirds the part in sight.
        val big = (side * 1.5).toInt()
        val bitmap = Bitmap.createBitmap(big, big, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(hues[Math.floorMod(name.hashCode(), hues.size)])
        val letter = name.firstOrNull { it.isLetterOrDigit() }?.uppercaseChar()?.toString() ?: "#"
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt(); textSize = side * 0.42f; textAlign = Paint.Align.CENTER; isFakeBoldText = true }
        canvas.drawText(letter, big / 2f, big / 2f - (paint.descent() + paint.ascent()) / 2, paint)
        return Icon.createWithAdaptiveBitmap(bitmap)
    }

    /** The middle square of [src], half as large again as [side]: an adaptive icon shows only the middle two thirds. */
    private fun squareOf(src: Bitmap, side: Int): Bitmap {
        val big = (side * 1.5).toInt()
        val cut = minOf(src.width, src.height)
        val square = Bitmap.createBitmap(src, (src.width - cut) / 2, (src.height - cut) / 2, cut, cut)
        return Bitmap.createScaledBitmap(square, big, big, true)
    }

    /**
     * A conversation's long-lived shortcut, which is what lets Android show its notification as a conversation: the
     * shortcut's id, or null where it could not be made and the notification is an ordinary one.
     */
    private fun shortcut(context: Context, thread: Long, title: String, people: List<Person>, icon: Icon): String? = try {
        val id = "thread-$thread"
        val info = ShortcutInfo.Builder(context, id)
            .setShortLabel(title.take(40).ifBlank { "Conversation" })
            .setLongLabel(title.ifBlank { "Conversation" })
            .setLongLived(true)
            .setPersons(people.toTypedArray())
            .setCategories(setOf(ShortcutInfo.SHORTCUT_CATEGORY_CONVERSATION))
            .setIcon(icon)
            .setIntent(Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                putExtra(EXTRA_THREAD, thread)
            })
            .build()
        val sm = context.getSystemService(ShortcutManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) sm.pushDynamicShortcut(info)
        else if (sm.dynamicShortcuts.none { it.id == id } && sm.dynamicShortcuts.size >= sm.maxShortcutCountPerActivity) { /* no room: an ordinary notification */ null }
        else sm.addDynamicShortcuts(listOf(info))
        if (Build.VERSION.SDK_INT >= 30 || sm.dynamicShortcuts.any { it.id == id }) id else null
    } catch (_: Exception) {
        null
    }

    /** A press that opens the app at [thread]. */
    private fun open(context: Context, thread: Long): PendingIntent =
        PendingIntent.getActivity(context, thread.toInt(), Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(EXTRA_THREAD, thread)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** Shows [thread]'s unread messages; true where a notification is up for it (GmListener waits on this). */
    fun incoming(context: Context, thread: Long): Boolean {
        // -1 is "the list", never a conversation. A bridged conversation below that (GmBridge) is notified like any.
        if (thread == -1L) return false
        // Open on the screen now: nothing to notify, and nothing is missed; the message sound says it came.
        if (MainActivity.openThread == thread && MainActivity.inFront) {
            if (!Store(context).isMuted(thread)) Sounds.messageIn(context)
            return true
        }
        val store = Store(context)
        if (store.isMuted(thread)) return true
        // Open in its bubble (Bubbles.kt): the notification is brought up to date for the bubble, kept out of the shade
        // and without its alert, and the message sound says it came, as with the conversation open in the app.
        val inBubble = thread in Bubbles.showing
        if (inBubble) Sounds.messageIn(context)
        val people = store.threadPeople(thread)
        val unread = store.messages(thread, 8).filter { !(it["outgoing"] as Boolean) && !(it["read"] as Boolean) }.reversed()
        if (unread.isEmpty()) { seen(context, thread); return false }
        val ui = context.getSharedPreferences("ui", Context.MODE_PRIVATE)
        // A text the list hides (a kind the filter has unticked, or Spam) makes no notification, the app open or not; it
        // still arrives and is kept (GMFB-18, Matt, Android 0.12.3: "If we dont have a specific kind of message enabled
        // like political messages we shouldn't get notified via sms for those messages"). NotifyHush.kt says how.
        // A member of a group shown under a stand-in (Groups.memberName) is called "Someone" and is still nobody's contact.
        val strangers = people.all { val a = it["address"] as String; Groups.memberName(a) != null || store.contact(a)["name"] == null }
        if (!inBubble && NotifyHush.hushes(ui.getString(NotifyHush.PREF, null), thread, people.map { it["address"] as String }, people.size > 1, strangers, unread.last()["body"] as String)) return true
        // (Nor while the app's own lock is on: AppLock.kt, GMFB-46.)
        val previews = ui.getString("notif_preview", "on") != "off" && !AppLock.hidesWords(ui)
        // A group only the bridge has (its people named only as they write): still a group, under the name Google
        // Messages gave it, never titled as the one who wrote (Matt, 2026-11-18: "the notification comes through as a
        // message from jade not from the group chat").
        val bridgedGroup = if (thread >= 0) null else try { GmBridge.Db.get(context).conversations().firstOrNull { it.thread == thread && it.group } } catch (_: Exception) { null }
        val group = people.size > 1 || bridgedGroup != null
        val title = store.threadName(thread) ?: bridgedGroup?.title?.takeIf { it.isNotBlank() } ?: people.joinToString(", ") { (it["name"] as String?) ?: (it["address"] as String) }
        val me = Person.Builder().setName("You").build()
        val senders = LinkedHashMap<String, Person>()
        val style = Notification.MessagingStyle(me).setGroupConversation(group)
        if (group) style.conversationTitle = title
        for (m in unread) {
            val addr = (m["address"] as String).ifEmpty { (people.firstOrNull()?.get("address") as String?) ?: "" }
            val c = store.contact(addr)
            val sender = Person.Builder().setName((c["name"] as String?) ?: addr).setKey(addr).build()
            senders[addr] = sender
            var body = m["body"] as String
            when (m["notice"]) {
                "key" -> body = if (E2e.isOn(context, addr)) "Texts with them are now encrypted." else "Sent an encryption key. Open to turn encryption on."
                "undecryptable" -> body = "Encrypted message"
                "background" -> body = "Changed the chat background"
            }
            // Formatting markers are drawn in the app, not said here (GMFB-35).
            if (m["notice"] == null) body = MarkdownPlain.strip(body)
            if (!previews && m["notice"] == null) body = "New message"
            @Suppress("UNCHECKED_CAST") val parts = m["parts"] as List<Map<String, Any?>>? ?: emptyList()
            if (body.isBlank()) body = if (parts.any { (it["type"] as String).startsWith("image/") }) "📷 Picture" else "Attachment"
            style.addMessage(Notification.MessagingStyle.Message(body, m["date"] as Long, sender))
        }

        val reply = Notification.Action.Builder(
            Icon.createWithResource(context, android.R.drawable.ic_menu_send), "Reply",
            PendingIntent.getBroadcast(context, thread.toInt(), Intent(context, NotificationActionReceiver::class.java).apply {
                action = NotificationActionReceiver.REPLY; putExtra(EXTRA_THREAD, thread)
            }, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
        ).addRemoteInput(RemoteInput.Builder(KEY_REPLY).setLabel("Message").build())
            .setSemanticAction(Notification.Action.SEMANTIC_ACTION_REPLY)
            .setAllowGeneratedReplies(true)
            .build()
        val read = Notification.Action.Builder(
            Icon.createWithResource(context, android.R.drawable.ic_menu_view), "Mark as read",
            PendingIntent.getBroadcast(context, thread.toInt() + 1_000_000, Intent(context, NotificationActionReceiver::class.java).apply {
                action = NotificationActionReceiver.READ; putExtra(EXTRA_THREAD, thread)
            }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
        ).setSemanticAction(Notification.Action.SEMANTIC_ACTION_MARK_AS_READ).build()

        // A sign-in code in the newest message gets a button that copies it.
        val code = if (previews && ui.getString("notif_code", "on") != "off") otp(unread.last()["body"] as String) else null

        // Quiet hours (lib/plugins/quiet.dart): from ten at night to seven in the morning a text from someone who is not a
        // contact, or from anyone where the person chose so, arrives without a sound; a contact's urgent words still do.
        val quiet = quietNow(context, ui, strangers, unread.last()["body"] as String)
        val avatar = if (group) face(context, title, null) else face(context, title, people.firstOrNull()?.let { store.contact(it["address"] as String)["photo"] as String? })
        val builder = Notification.Builder(context, if (quiet) quietChannel(context) else channel(context))
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setStyle(style)
            .setContentIntent(open(context, thread))
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setColor(0xFF4F5BD5.toInt())
            .setGroup(GROUP)
            .setShortcutId(shortcut(context, thread, title, people.map { p ->
                val a = p["address"] as String
                senders[a] ?: Person.Builder().setName((p["name"] as String?) ?: a).setKey(a).build()
            }, avatar))
            // The conversation as a bubble on the side of the screen (GMFB-8; Bubbles.kt), where Settings ›
            // Notifications › Bubbles is on and Android lets this conversation bubble.
            .setBubbleMetadata(Bubbles.metadata(context, thread, avatar, quiet = inBubble))
            .setOnlyAlertOnce(inBubble)
        if (code != null) {
            builder.addAction(Notification.Action.Builder(
                Icon.createWithResource(context, android.R.drawable.ic_menu_save), "Copy $code",
                PendingIntent.getBroadcast(context, thread.toInt() + 2_000_000, Intent(context, NotificationActionReceiver::class.java).apply {
                    action = NotificationActionReceiver.COPY; putExtra(EXTRA_THREAD, thread); putExtra("code", code)
                }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            ).build())
        }
        builder.addAction(reply).addAction(read)
        val n = builder.build()
        // The home screen's widgets count it too (GhostWidgets.kt).
        GhostWidgets.refresh(context)
        return try { manager(context).notify(thread.toInt(), n); true } catch (_: SecurityException) { false }
    }

    private const val CHANNEL_QUIET = "quiet"

    /// The channel a quiet hour's texts arrive on: shown, with no sound or vibration.
    private fun quietChannel(context: Context): String {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_QUIET) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_QUIET, "Quiet hours", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Texts that arrive in quiet hours (Settings › Quiet hours): shown, without a sound."
                setAllowBubbles(true)
            })
        }
        return CHANNEL_QUIET
    }

    private val urgent = Regex("(?i)(?<![a-z])(?:urgent|emergency|asap|911|call me|hospital|help)(?![a-z])")

    /// Whether a text arriving now is quiet: the Quiet hours plugin on, its hours chosen, the time between ten at night
    /// and seven in the morning, and the text from a stranger (or from anyone, where everyone was chosen and the words
    /// are not urgent).
    fun quietNow(context: Context, ui: android.content.SharedPreferences, stranger: Boolean, words: String, hour: Int = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)): Boolean {
        if (ui.getString("plugin_quiet", "on") == "off" || ui.getString("plugin_quiet_hours", "off") != "on") return false
        if (hour in 7..21) return false
        if (stranger) return true
        return ui.getString("plugin_quiet_everyone", "off") == "on" && !urgent.containsMatchIn(words)
    }

    // A word of its own: "pin" is in "shipping", "shopping" and "opinion", and "code" in "barcode", and a text with one
    // of those and an order's number is not a sign-in code. "verif" starts verify, verification, verified.
    private val codeWord = Regex("(?i)(?<![A-Za-z0-9_])(?:(?:code|passcode|password|pin|otp|one[- ]time|2fa|login|log in|sign in|security)(?![A-Za-z0-9_])|verif)")
    private val codeDigits = Regex("(?<![\\w.,/-])(\\d{3}[- ]\\d{3}|\\d{4,8})(?![\\w/-]|[.,]\\d)")

    /**
     * The sign-in code in [body], if it reads like one: 4 to 8 digits (or 123-456) in a text that speaks of a code.
     * The list's Codes section (lib/plugins/codes.dart, `signInCode`) is these two rules written again in Dart, and
     * both are held to test/code_vectors.json: change one, change the other.
     */
    fun otp(body: String): String? {
        if (body.length > 400 || !codeWord.containsMatchIn(body)) return null
        return codeDigits.find(body)?.value?.filter { it.isDigit() }
    }

    /**
     * A friend's message is waiting at the relay server and the app is closed (Friends.woken): said in the
     * conversation's own place among the notifications, so the message itself takes its place once it is fetched.
     */
    fun waiting(context: Context, thread: Long, who: String) {
        if (thread < 0) return
        val n = Notification.Builder(context, channel(context))
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle(who)
            .setContentText("New message. Open Uplink to read it.")
            .setContentIntent(open(context, thread))
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setColor(0xFF4F5BD5.toInt())
            .build()
        try { manager(context).notify(thread.toInt(), n) } catch (_: SecurityException) {}
    }

    /**
     * A friend by username wrote (lib/standalone/overlay.dart): their name and words, opening the conversation.
     * Their words are kept in Dart, not Android's store, so this is told them rather than reading them itself. Not
     * while that conversation is on the screen; "New message" where previews are off.
     */
    fun chat(context: Context, thread: Long, who: String, body: String) {
        if (MainActivity.openThread == thread && MainActivity.inFront) { Sounds.messageIn(context); return }
        val previews = wordsShown(context)
        val sender = Person.Builder().setName(who).setKey(who).build()
        val style = Notification.MessagingStyle(Person.Builder().setName("You").build())
            .addMessage(Notification.MessagingStyle.Message(if (previews) MarkdownPlain.strip(body) else "New message", System.currentTimeMillis(), sender))
        val n = Notification.Builder(context, channel(context))
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setStyle(style)
            .setContentIntent(open(context, thread))
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setColor(0xFF4F5BD5.toInt())
            .setGroup(GROUP)
            .build()
        try { manager(context).notify(thread.toInt(), n) } catch (_: SecurityException) {}
    }

    /**
     * Whether a notification says the message's words: where previews are on, and not while the app's own lock is on
     * (AppLock.kt, GMFB-46), when it says "New message" and who it is from.
     */
    private fun wordsShown(context: Context): Boolean {
        val ui = context.getSharedPreferences("ui", Context.MODE_PRIVATE)
        return ui.getString("notif_preview", "on") != "off" && !AppLock.hidesWords(ui)
    }

    /** The tag a Signal or Telegram chat's notification is shown under, apart from the texts' (numbered by thread). */
    private const val INBOX_TAG = "inbox"
    const val EXTRA_INBOX = "inbox"

    /**
     * A new message on Signal or Telegram (lib/inbox/alerts.dart; Matt, 2026-11-16): the chat's name and its newest
     * words, with the network's name under them; a press opens the chat. [key] is `network:chat`. Dart decides
     * whether to notify (not muted, not spam, not on the screen); "New message" where previews are off.
     */
    fun inbox(context: Context, key: String, network: String, title: String, body: String, group: Boolean) {
        val previews = wordsShown(context)
        val who = Person.Builder().setName(title).setKey(key).build()
        val style = Notification.MessagingStyle(Person.Builder().setName("You").build())
            .addMessage(Notification.MessagingStyle.Message(if (previews) MarkdownPlain.strip(body).ifBlank { "New message" } else "New message", System.currentTimeMillis(), who))
        if (group) style.setConversationTitle(title).setGroupConversation(true)
        val open = PendingIntent.getActivity(context, key.hashCode(), Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(EXTRA_INBOX, key)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n = Notification.Builder(context, channel(context))
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setStyle(style)
            .setSubText(network)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setColor(0xFF4F5BD5.toInt())
            .setGroup(GROUP)
            .build()
        try { manager(context).notify(INBOX_TAG, key.hashCode(), n) } catch (_: SecurityException) {}
    }

    fun cancelInbox(context: Context, key: String) {
        context.getSystemService(NotificationManager::class.java).cancel(INBOX_TAG, key.hashCode())
    }

    /** Takes down the notification of [thread]'s new messages. */
    fun cancel(context: Context, thread: Long) {
        context.getSystemService(NotificationManager::class.java).cancel(thread.toInt())
        GhostWidgets.refresh(context)
    }

    /**
     * [thread] was read: its notification goes (as [cancel]), except where it is showing as a bubble, which stays on
     * the side of the screen until the person puts it away, its notification only taken out of the shade
     * (Bubbles.quieten). A conversation deleted is [cancel]led, bubble and all.
     */
    fun seen(context: Context, thread: Long) {
        if (!Bubbles.quieten(context, thread)) cancel(context, thread)
    }

    /**
     * Encryption is on with the person in [thread], and a text of theirs came without it (E2e.arrived; Matt,
     * 2026-11-14: "detect if a user is sending us unencrypted messages and let us know so we can disable it").
     * Opens the conversation, which says the same over its message field with a way to turn encryption off.
     */
    fun plainWhileEncrypted(context: Context, thread: Long) {
        if (thread < 0) return
        // The conversation is open in front: it says so itself, over its message field.
        if (MainActivity.openThread == thread && MainActivity.inFront) return
        val people = Store(context).threadPeople(thread)
        val who = people.joinToString(", ") { (it["name"] as String?) ?: (it["address"] as String) }.ifEmpty { "Someone" }
        val n = Notification.Builder(context, CHANNEL_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle("$who sent a text that isn't encrypted")
            .setContentText("Encryption is on with them. They may not be able to read what you send. Tap to decide.")
            .setStyle(Notification.BigTextStyle().bigText("Encryption is on with them, and their text came without it. They may have turned it off or changed phones, and then can't read what you send encrypted. Tap to open the conversation and decide."))
            .setContentIntent(open(context, thread))
            .setAutoCancel(true)
            .build()
        try { manager(context).notify(5200 + (thread % 1000).toInt(), n) } catch (_: SecurityException) {}
    }

    /** A message in [thread] did not go: says to whom, and opens the conversation to try again. */
    fun failed(context: Context, thread: Long) {
        if (thread < 0) return
        val people = Store(context).threadPeople(thread)
        val who = people.joinToString(", ") { (it["name"] as String?) ?: (it["address"] as String) }
        val n = Notification.Builder(context, CHANNEL_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle("Message not sent")
            .setContentText(if (who.isEmpty()) "Tap to try again" else "To $who. Tap to try again.")
            .setContentIntent(open(context, thread))
            .setAutoCancel(true)
            .build()
        try { manager(context).notify(-thread.toInt() - 1, n) } catch (_: SecurityException) {}
    }

    /**
     * A picture message could not be brought down. A tap opens the conversation it is for ([thread], where its
     * announcement was kept), which shows it with Try again (Matt, 2026-11-13: "when I tap it I'd like it to take me
     * to the associated chat and show the failed image with a retry if needed").
     */
    fun downloadFailed(context: Context, thread: Long? = null) {
        val n = Notification.Builder(context, CHANNEL_ALERTS)
            .setSmallIcon(R.drawable.ic_stat_ghost)
            .setContentTitle("A picture couldn't be downloaded")
            .setContentText(if (thread != null) "Tap to open the conversation and try again. Check mobile data is on." else "Check mobile data is on. Your carrier will usually send it again.")
            .setAutoCancel(true)
            .apply { if (thread != null) setContentIntent(open(context, thread)) }
            .build()
        // One for each conversation, so a second failure does not take the first one's place.
        try { manager(context).notify(if (thread != null) 4200 + (thread % 1000).toInt() else 42, n) } catch (_: SecurityException) {}
    }
}

class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val REPLY = "ghost.REPLY"
        const val READ = "ghost.READ"
        const val COPY = "ghost.COPY"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val thread = intent.getLongExtra(Notifier.EXTRA_THREAD, -1)
        if (thread < 0) return
        val store = Store(context)
        when (intent.action) {
            REPLY -> {
                val text = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(Notifier.KEY_REPLY)?.toString()?.trim()
                if (!text.isNullOrEmpty()) {
                    val people = store.threadPeople(thread).map { it["address"] as String }
                    if (people.isNotEmpty()) Sender.send(context, people, text)
                }
                store.markRead(thread)
                Notifier.seen(context, thread)
            }
            READ -> {
                store.markRead(thread)
                Notifier.seen(context, thread)
            }
            COPY -> {
                val code = intent.getStringExtra("code") ?: return
                val clip = context.getSystemService(android.content.ClipboardManager::class.java)
                clip.setPrimaryClip(android.content.ClipData.newPlainText("Code", code))
                store.markRead(thread)
                Notifier.seen(context, thread)
            }
        }
        Bus.changed(thread)
    }
}

/** "Respond via message" from the incoming-call screen: send it, with no screen of our own. */
@Suppress("DEPRECATION")
class HeadlessSmsSendService : IntentService("HeadlessSmsSendService") {
    @Deprecated("IntentService")
    override fun onHandleIntent(intent: Intent?) {
        if (intent?.action != "android.intent.action.RESPOND_VIA_MESSAGE") return
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim().orEmpty()
        val to = intent.data?.schemeSpecificPart?.substringBefore('?')?.split(',', ';')?.map { Uri.decode(it).trim() }?.filter { it.isNotEmpty() }.orEmpty()
        if (text.isEmpty() || to.isEmpty()) return
        try { Sender.send(this, to, text) } catch (_: Exception) {}
    }
}

/**
 * Files the phone process reads (an MMS to send) or writes (one it downloaded) by content URI. Android's MMS
 * service is granted the URI on our behalf by SmsManager, which is why it must be grantable.
 */
class MmsFileProvider : ContentProvider() {
    companion object {
        /** Where a picture message's bytes wait, in the app's cache; and the content address of a file there. */
        fun dir(context: Context): File = File(context.cacheDir, "mms").apply { mkdirs() }
        fun uriFor(context: Context, file: File): Uri = Uri.Builder().scheme("content").authority("${context.packageName}.mmsfiles").path(file.name).build()
    }

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val ctx = context ?: return null
        val name = uri.lastPathSegment ?: return null
        if (name.contains('/') || name.contains("..")) return null
        val file = File(dir(ctx), name)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
    }

    // A file shared or opened from a Files space is asked its name and size by the app it goes to; a picture message's
    // own parts (.pdu) are never asked. Its type by its ending, and an MMS's where it has none that Android knows.
    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? {
        val ctx = context ?: return null
        val name = uri.lastPathSegment ?: return null
        if (name.contains('/') || name.contains("..")) return null
        val file = File(dir(ctx), name)
        if (!file.exists()) return null
        val shown = name.replace(Regex("^share-[0-9]+-"), "")
        val cols = p ?: arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE)
        return android.database.MatrixCursor(cols).apply {
            addRow(cols.map { when (it) { android.provider.OpenableColumns.DISPLAY_NAME -> shown; android.provider.OpenableColumns.SIZE -> file.length(); else -> null } })
        }
    }
    override fun getType(uri: Uri): String =
        android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension((uri.lastPathSegment ?: "").substringAfterLast('.', "").lowercase()) ?: "application/vnd.wap.mms-message"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?) = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?) = 0
}

