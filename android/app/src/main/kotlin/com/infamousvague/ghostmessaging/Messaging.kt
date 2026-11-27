package com.infamousvague.ghostmessaging

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File

private const val TAG = "GhostMessaging"

/** Tells the app on screen, when there is one, that a conversation changed. */
object Bus {
    @Volatile var listener: ((Long) -> Unit)? = null

    /** The choices the screen reads (the "ui" preferences) were changed from this side: a background that arrived. */
    @Volatile var prefsListener: (() -> Unit)? = null
    /**
     * Conversations' bubbles (BubbleActivity, GMFB-8), each an engine of its own beside the app's: told the same as
     * [listener] and [prefsListener], which stay the app's.
     */
    val others = java.util.concurrent.CopyOnWriteArrayList<(Long) -> Unit>()
    val prefsOthers = java.util.concurrent.CopyOnWriteArrayList<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())
    /** A conversation changed: the screen is told on the main thread, and so are the computers connected now. */
    fun changed(thread: Long) {
        main.post { listener?.invoke(thread); for (o in others) o(thread) }
        // And the computers paired with this phone that are connected now (Desk.kt).
        Desk.changed(thread)
    }

    /** For the phone's own screen alone: something a paired computer did that it need not be told back. */
    fun changedOnPhone(thread: Long) { main.post { listener?.invoke(thread); for (o in others) o(thread) } }
    fun prefsChanged() { main.post { prefsListener?.invoke(); for (o in prefsOthers) o() } }
}

/** Mutable where the system adds its result extras to the intent it sends back (Android 12 asks that it be said). */
private val MUTABLE = PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

/** Android's sender for the SIM [subId] names, or its default one where that is no SIM. */
private fun smsManager(context: Context, subId: Int): SmsManager {
    val base = context.getSystemService(SmsManager::class.java)
    return if (subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID && subId >= 0) base.createForSubscriptionId(subId) else base
}

/** The SIM the phone is set to text from. */
private fun defaultSub(): Int = SubscriptionManager.getDefaultSmsSubscriptionId()

/** What the app sends by the carrier: texts, picture and group messages, stickers, voice messages. */
object Sender {
    /**
     * Sends one of the app's stickers (Matt, 2026-11-13: "generate 4 sticker packs using our ghost mascot") to
     * [addresses] as a picture message. [picture] is the sticker as the app keeps it (a WebP with a clear
     * background); it goes as a PNG, which every phone's texting app can show and which keeps the clear background a
     * photograph's JPEG would paint black. Its name, `ghost-sticker-…`, is how this app knows to draw it as a sticker
     * and not a photograph. Returns the conversation.
     */
    fun sendSticker(context: Context, addresses: List<String>, picture: ByteArray, name: String): Long {
        val store = Store(context)
        val clean = addresses.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        require(clean.isNotEmpty()) { "No one to send to" }
        val thread = store.threadFor(clean)
        val sub = defaultSub()
        val config = try { smsManager(context, sub).carrierConfigValues } catch (_: Exception) { Bundle() }
        val budget = config.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, 300 * 1024).coerceAtLeast(100 * 1024) - 8 * 1024
        // A sticker that moves (an animated PNG, tool/sticker_packs.py) goes as it is: made over, it would be its
        // first drawing alone. It is a still picture to any phone that does not know the kind.
        val png: ByteArray = if (Stickers.moves(picture) && picture.size <= budget) picture else {
            var bitmap = BitmapFactory.decodeByteArray(picture, 0, picture.size) ?: throw IllegalStateException("That sticker could not be read")
            var made: ByteArray
            while (true) {
                val out = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                made = out.toByteArray()
                if (made.size <= budget || bitmap.width < 160) break
                bitmap = Bitmap.createScaledBitmap(bitmap, (bitmap.width * 0.8).toInt(), (bitmap.height * 0.8).toInt(), true)
            }
            made
        }
        val file = Stickers.file(name)
        sendMms(context, store, thread, clean, "", emptyList(), listOf(Pdu.Part("image/png", png, name = file, contentLocation = file, contentId = "sticker")))
        Bus.changed(thread)
        return thread
    }

    /** The most a message may weigh on this phone's carrier, less room for its own headers: what a voice message may fill. */
    fun voiceBudget(context: Context): Long {
        val config = try { smsManager(context, defaultSub()).carrierConfigValues } catch (_: Exception) { Bundle() }
        // The same limit a picture message is held to (sendMms): the carrier's, and never more than LARGEST.
        return (config.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, 300 * 1024).coerceIn(100 * 1024, LARGEST) - 8 * 1024).toLong()
    }

    /**
     * Sends a voice message (Voice.kt) to [addresses]: the recording in [file], as an MMS with one audio part, which
     * any phone can play. It goes as a picture does, so it is not encrypted. Returns the conversation.
     */
    fun sendVoice(context: Context, addresses: List<String>, file: File): Long {
        val store = Store(context)
        val clean = addresses.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        require(clean.isNotEmpty()) { "No one to send to" }
        val bytes = file.readBytes()
        require(bytes.size <= voiceBudget(context) + 8 * 1024) { "That recording is too long for a message on this carrier" }
        val thread = store.threadFor(clean)
        // For Settings › Developer: what it was, never what was said.
        DevLog.add(context, "mms", "voice message: ${bytes.size / 1024} KB audio/mp4, the carrier's limit ${(voiceBudget(context) + 8 * 1024) / 1024} KB")
        sendMms(context, store, thread, clean, "", emptyList(), listOf(Pdu.Part("audio/mp4", bytes, name = file.name, contentLocation = file.name, contentId = "voice")))
        Bus.changed(thread)
        return thread
    }

    /**
     * Sends [body] to [addresses] and gives the conversation: one person is an SMS (in as many parts as it takes),
     * several are one group MMS, and pictures ([attachments], content URIs) make it an MMS too.
     * [plain] sends the words as they are, neither sealed nor marked. Throws where there is no one to send to or the
     * message could not be saved.
     */
    fun send(context: Context, addresses: List<String>, body: String, attachments: List<String> = emptyList(), plain: Boolean = false): Long {
        val store = Store(context)
        val clean = addresses.map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        require(clean.isNotEmpty()) { "No one to send to" }
        // A friend by username ("@maya") has no number: never written into the phone's store of texts or handed to Google
        // Messages, from this phone or from a computer paired with it (found in review, 2026-11-23). The app sends to
        // them over the internet (lib/friends/friends.dart) and says so where it can't.
        require(clean.none { it.startsWith("@") }) { "A friend by username has no number to text" }
        // Beside Google Messages (GmBridge): sent through it, or as a plain SMS. Android's database takes no writes from
        // an app that is not the default, so the way below (which writes the message there first) cannot be used.
        if (!GmBridge.isDefault(context)) {
            val thread = GmBridge.sendBeside(context, clean, body, attachments)
            Bus.changed(thread)
            return thread
        }
        val thread = store.threadFor(clean)
        // To one person with encryption on, the words go sealed (E2e), and are kept sealed in the SMS database.
        if (clean.size == 1 && attachments.isEmpty()) {
            var text = if (plain) body else (E2e.wire(context, clean[0], body) ?: body)
            // Not sealed, so nothing is exchanged with them yet: the invisible hello rides on the text where it costs
            // nothing (the same number of SMS with it as without), so their copy of the app, if they have one, knows.
            if (!plain && text == body && GhostMark.mayCarry(text) && E2e.wantsMark(context, clean[0]) && sameCost(text, GhostMark.add(text))) {
                text = GhostMark.add(text)
                E2e.marked(context, clean[0])
            }
            sendSms(context, store, thread, clean[0], text)
        } else sendMms(context, store, thread, clean, body, attachments)
        Bus.changed(thread)
        return thread
    }

    /** Whether [b] goes as the same number of SMS as [a]. */
    private fun sameCost(a: String, b: String): Boolean = try {
        android.telephony.SmsMessage.calculateLength(a, false)[0] == android.telephony.SmsMessage.calculateLength(b, false)[0]
    } catch (_: Exception) { false }

    /**
     * Writes the text to the outbox and hands it to Android in as many parts as it takes. What became of it comes back
     * to [SmsStatusReceiver], which marks the row.
     */
    private fun sendSms(context: Context, store: Store, thread: Long, address: String, body: String) {
        val sub = defaultSub()
        val row = store.insertSmsOutbox(thread, address, body, sub) ?: throw IllegalStateException("Could not save the message")
        val sms = smsManager(context, sub)
        val parts = sms.divideMessage(body)
        val sent = ArrayList<PendingIntent>()
        val delivered = ArrayList<PendingIntent>()
        for (i in parts.indices) {
            val code = (row.toString() + i).hashCode()
            // Only the last part's result marks the message: the others would race it.
            val last = i == parts.size - 1
            // Delivery reports are asked for unless switched off in Settings › Receipts.
            sent += PendingIntent.getBroadcast(context, code, Intent(context, SmsStatusReceiver::class.java).apply {
                action = if (last) SmsStatusReceiver.SENT else SmsStatusReceiver.SENT_PART
                data = row
            }, MUTABLE)
            delivered += PendingIntent.getBroadcast(context, code + 1, Intent(context, SmsStatusReceiver::class.java).apply {
                action = if (last) SmsStatusReceiver.DELIVERED else SmsStatusReceiver.DELIVERED_PART
                data = row
            }, MUTABLE)
        }
        try {
            val reports = context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("delivery_reports", "on") != "off"
            if (parts.size == 1) sms.sendTextMessage(address, null, body, sent[0], if (reports) delivered[0] else null)
            else sms.sendMultipartTextMessage(address, null, parts, sent, if (reports) delivered else null)
        } catch (e: Exception) {
            Log.e(TAG, "send failed", e)
            store.setSmsType(row, Telephony.Sms.MESSAGE_TYPE_FAILED)
        }
    }

    /**
     * Sends a picture message that did not go, again (Matt, 2026-11-13: "its specifically media messages like
     * pictures"): its own pictures and words, read back from where Android keeps them. Trying again used to send
     * the words alone as a text and delete the message, so a picture that failed once was gone.
     *
     * Where the carrier refused it (not where the phone had no connection), its pictures go smaller this time: under
     * 300 KB in all, which every carrier takes. [newBody]: other words, where it was edited before being sent again.
     */
    fun resendMms(context: Context, id: Long, newBody: String? = null, unasked: Boolean = false): Long {
        val store = Store(context)
        val row = Uri.parse("content://mms/$id")
        val thread = store.threadOfMms(row)
        val to = store.threadPeople(thread).mapNotNull { it["address"] as String? }.filter { it.isNotBlank() }
        require(to.isNotEmpty()) { "No one to send to" }
        val stored = store.mmsParts(id)
        val words = newBody ?: stored.filter { it.isText }.joinToString("\n") { String(it.data, Charsets.UTF_8) }
        var pictures = stored.filter { !it.isText && it.contentType != "application/smil" }
        val smaller = MmsDiag.wantsSmaller(context, id)
        // Tried again by the app itself, it counts on from where it was; tried again by the person, it starts afresh.
        val tries = if (unasked) MmsDiag.tries(context, id) + 1 else 1
        if (smaller) {
            val photos = pictures.count { it.contentType.startsWith("image/") && !Stickers.isSticker(it.name) }.coerceAtLeast(1)
            pictures = pictures.map { part ->
                if (!part.contentType.startsWith("image/") || Stickers.isSticker(part.name)) part
                else try {
                    val bitmap = BitmapFactory.decodeByteArray(part.data, 0, part.data.size) ?: throw IllegalStateException("it couldn't be decoded")
                    val (bytes, how) = shrink(bitmap, SMALL / photos)
                    DevLog.add(context, "mms", "a picture made smaller to send again: ${part.data.size / 1024} KB -> $how")
                    Pdu.Part("image/jpeg", bytes, name = part.name, contentLocation = part.contentLocation, contentId = part.contentId)
                } catch (e: Throwable) { part }
            }
        }
        store.deleteMessage("mms", id)
        MmsDiag.cleared(context, row)
        sendMms(context, store, thread, to, words, emptyList(), pictures, again = if (unasked) "try $tries" else if (smaller) "again, smaller" else "again", tries = tries)
        Bus.changed(thread)
        return thread
    }

    /** What every carrier takes for a whole picture message, less room for its wrapping. */
    private const val SMALL = 280 * 1024

    /** The most a picture message is made, whatever a carrier's settings say: larger ones often do not cross to another carrier. */
    private const val LARGEST = 1024 * 1024

    /**
     * Builds one MMS for everyone in [to]: each picture in [attachments] made a JPEG that fits its share of the
     * carrier's limit, then the words; written to the outbox and handed to Android. [again] and [tries] are for the
     * log and the count when a message is sent again.
     */
    private fun sendMms(context: Context, store: Store, thread: Long, to: List<String>, body: String, attachments: List<String>, ready: List<Pdu.Part> = emptyList(), again: String? = null, tries: Int = 1) {
        val sub = defaultSub()
        val sms = smsManager(context, sub)
        val config = try { sms.carrierConfigValues } catch (_: Exception) { Bundle() }
        val maxBytes = config.getInt(SmsManager.MMS_CONFIG_MAX_MESSAGE_SIZE, 300 * 1024).coerceIn(100 * 1024, LARGEST)
        // [ready]: parts that go as they are (a sticker, already a PNG that fits; a message's own, sent again).
        val parts = ArrayList<Pdu.Part>(ready)
        val notes = ArrayList<String>()
        val budget = (maxBytes - 8 * 1024 - body.toByteArray().size - ready.sumOf { it.data.size }) / attachments.size.coerceAtLeast(1)
        attachments.forEachIndexed { i, a ->
            // A picture that cannot be made ready stops the message, and says so: it used to be left out without a
            // word, and the message went with nothing in it.
            val made = try { compressImage(context, Uri.parse(a), budget.coerceAtLeast(40 * 1024)) } catch (e: Throwable) {
                val why = e.message ?: e.javaClass.simpleName
                DevLog.add(context, "mms", "picture ${i + 1} of ${attachments.size} couldn't be made ready: $why")
                throw IllegalStateException("that picture couldn't be read ($why)")
            }
            notes += made.second
            parts += Pdu.Part("image/jpeg", made.first, name = "image$i.jpg", contentLocation = "image$i.jpg", contentId = "image$i")
        }
        if (body.isNotEmpty()) parts += Pdu.Part("text/plain", body.toByteArray(), contentLocation = "text0.txt", contentId = "text0")
        DevLog.add(context, "mms", "send${again?.let { " ($it)" } ?: ""} to ${to.size}: " +
            (notes + ready.map { "${it.contentType} ${it.data.size / 1024} KB" }).ifEmpty { listOf("no pictures") }.joinToString("; ") +
            ", words ${body.length}, carrier's limit ${maxBytes / 1024} KB")
        val row = store.insertMms(Telephony.Mms.MESSAGE_BOX_OUTBOX, thread, null, to, emptyList(), parts, System.currentTimeMillis() / 1000, null, null, null, sub)
            ?: throw IllegalStateException("Could not save the message")
        // Delivery reports are asked for always; read reports unless switched off in Settings (few phones answer).
        val wantRead = context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("read_reports", "on") != "off"
        val wantDelivery = context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("delivery_reports", "on") != "off"
        val pdu = Pdu.sendReq(to, parts, deliveryReport = wantDelivery, readReport = wantRead)
        val file = File(MmsFileProvider.dir(context), "send-${System.nanoTime()}.pdu")
        file.writeBytes(pdu)
        val uri = MmsFileProvider.uriFor(context, file)
        val sent = PendingIntent.getBroadcast(context, row.hashCode(), Intent(context, MmsResultReceiver::class.java).apply {
            action = MmsResultReceiver.SENT
            data = row
            putExtra("file", file.absolutePath)
        }, MUTABLE)
        MmsDiag.cleared(context, row)
        MmsDiag.tried(context, row, tries)
        try {
            sms.sendMultimediaMessage(context, uri, null, null, sent)
        } catch (e: Exception) {
            Log.e(TAG, "mms send failed", e)
            store.setMmsBox(row, Telephony.Mms.MESSAGE_BOX_FAILED)
            val why = "Android wouldn't take it (${e.message ?: e.javaClass.simpleName})"
            DevLog.add(context, "mms", "not sent: $why")
            MmsDiag.failed(context, row, why)
            MmsDiag.note(context, "send", false, "$why, ${pdu.size / 1024} KB")
            file.delete()
        }
    }

    /**
     * A picture as a JPEG that fits in [budget] bytes, scaled down and squeezed until it does, with what was done to
     * it for the log. Throws, saying why, where the picture cannot be read: nothing is sent in its place.
     */
    private fun compressImage(context: Context, uri: Uri, budget: Int): Pair<ByteArray, String> {
        val resolver = context.contentResolver
        val kind = try { resolver.getType(uri) } catch (_: Exception) { null } ?: "a kind Android didn't name"
        val weight = try { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length }?.takeIf { it > 0 } } catch (_: Exception) { null }
        try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            (resolver.openInputStream(uri) ?: throw IllegalStateException("Android wouldn't open it")).use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IllegalStateException("this phone can't read it as a picture: $kind")
            var sample = 1
            while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
            val bmp = resolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 })
            } ?: throw IllegalStateException("it couldn't be decoded: $kind")
            val (bytes, how) = shrink(rotated(context, uri, bmp), budget)
            return bytes to "${bounds.outWidth}x${bounds.outHeight} ${weight?.let { "${it / 1024} KB " } ?: ""}$kind -> $how"
        } catch (e: OutOfMemoryError) {
            throw IllegalStateException("it is too large for this phone to shrink")
        } catch (e: SecurityException) {
            throw IllegalStateException("Android no longer lets this app read it; choose it again")
        }
    }

    /**
     * [picture] as a JPEG of at most [budget] bytes, and its size and quality as sent. A plain JPEG: eight bits a
     * colour and one picture. A phone's HDR photograph carries a second picture inside it (a gain map), which
     * Android writes into the JPEG it makes too; a carrier's server remakes pictures for the phone they are going
     * to, and a file with two pictures in it is not one it is known to take, so it is left off.
     */
    private fun shrink(picture: Bitmap, budget: Int): Pair<ByteArray, String> {
        var bmp = picture
        if (bmp.config != Bitmap.Config.ARGB_8888) bmp = bmp.copy(Bitmap.Config.ARGB_8888, false) ?: bmp
        var hdr = ""
        if (android.os.Build.VERSION.SDK_INT >= 34 && bmp.hasGainmap()) {
            if (!bmp.isMutable) bmp = bmp.copy(Bitmap.Config.ARGB_8888, true) ?: bmp
            bmp.gainmap = null
            hdr = " (HDR left off)"
        }
        var side = 1600
        var quality = 85
        while (true) {
            val scale = side.toFloat() / maxOf(bmp.width, bmp.height)
            val b = if (scale < 1f) Bitmap.createScaledBitmap(bmp, (bmp.width * scale).toInt().coerceAtLeast(1), (bmp.height * scale).toInt().coerceAtLeast(1), true) else bmp
            val out = ByteArrayOutputStream()
            b.compress(Bitmap.CompressFormat.JPEG, quality, out)
            if (out.size() <= budget || side < 320) return out.toByteArray() to "${b.width}x${b.height} q$quality ${out.size() / 1024} KB$hdr"
            if (quality > 55) quality -= 10 else side = (side * 0.75).toInt()
        }
    }

    /** [bmp] turned the way its file's EXIF says it was taken, since the JPEG made of it carries no EXIF. */
    private fun rotated(context: Context, uri: Uri, bmp: Bitmap): Bitmap = try {
        val exif = context.contentResolver.openInputStream(uri)?.use { android.media.ExifInterface(it) }
        val deg = when (exif?.getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1)) {
            android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
            android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
            android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
            else -> 0f
        }
        if (deg == 0f) bmp else Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, android.graphics.Matrix().apply { postRotate(deg) }, true)
    } catch (_: Exception) { bmp }
}

/** An SMS sent, or delivered: the row in the provider says so. */
class SmsStatusReceiver : BroadcastReceiver() {
    companion object {
        const val SENT = "ghost.SMS_SENT"
        const val SENT_PART = "ghost.SMS_SENT_PART"
        const val DELIVERED = "ghost.SMS_DELIVERED"
        const val DELIVERED_PART = "ghost.SMS_DELIVERED_PART"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val row = intent.data ?: return
        val store = Store(context)
        when (intent.action) {
            SENT -> {
                if (resultCode == Activity.RESULT_OK) store.setSmsType(row, Telephony.Sms.MESSAGE_TYPE_SENT)
                else {
                    store.setSmsType(row, Telephony.Sms.MESSAGE_TYPE_FAILED, resultCode)
                    Notifier.failed(context, store.threadOfSms(row))
                }
            }
            SENT_PART -> if (resultCode != Activity.RESULT_OK) store.setSmsType(row, Telephony.Sms.MESSAGE_TYPE_FAILED, resultCode)
            DELIVERED -> store.setSmsStatus(row, Telephony.Sms.STATUS_COMPLETE)
        }
        Bus.changed(store.threadOfSms(row))
    }
}

/** Incoming SMS, delivered to the default SMS app alone: it is this app's to keep. */
class SmsDeliverReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent) ?: return
        if (messages.isEmpty()) return
        val address = messages[0].displayOriginatingAddress ?: messages[0].originatingAddress ?: return
        val body = messages.joinToString("") { it.displayMessageBody ?: it.messageBody ?: "" }
        val sub = intent.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX", intent.getIntExtra("subscription", -1))
        val store = Store(context)
        val row = store.insertSmsInbox(address, body, System.currentTimeMillis(), messages[0].timestampMillis, sub) ?: return
        // Someone's encryption key: kept, and the conversation moves on (E2e.received).
        val key = E2eCrypto.keyIn(body)
        key?.let { try { E2e.received(context, address, it) } catch (e: Exception) { Log.e(TAG, "e2e key", e) } }
        // The invisible hello of another copy of the app: they have it, and their conversation now offers encryption
        // in a banner (the screen asks E2e.state). Nothing is sent because of it.
        try { if (GhostMark.has(body)) Backgrounds.sawGhost(context, address) } catch (e: Exception) { Log.e(TAG, "ghost mark", e) }
        val thread = store.threadOfSms(row)
        // A text only Uplink writes: they have the app. And a chat background, sealed or not, is worn.
        try {
            if (Backgrounds.isGhostText(body)) Backgrounds.sawGhost(context, address)
            BackgroundWire.valueIn(E2e.read(context, address, body).first)?.let {
                Backgrounds.sawGhost(context, address)
                Backgrounds.received(context, thread, it)
            }
        } catch (e: Exception) { Log.e(TAG, "shared background", e) }
        store.setArchived(thread, false)
        Notifier.incoming(context, thread)
        // Encryption is on with them and this came without it: said once, as the first one comes (E2e.arrived).
        try { if (E2e.arrived(context, address, body)) Notifier.plainWhileEncrypted(context, thread) } catch (e: Exception) { Log.e(TAG, "e2e plain", e) }
        // A paired computer hears of it through the service, which Android may have stopped since: a text arriving is
        // one of the few moments it lets a stopped app start one again.
        DeskService.sync(context)
        Bus.changed(thread)
        // A sign-in code: Ghost Keyboard, if it is watching, asks for it now (Codes.kt).
        try { Codes.arrived(context, E2e.read(context, address, body).first) } catch (e: Exception) { Log.e(TAG, "code", e) }
    }
}

/**
 * An MMS's notification (WAP push): the message itself waits at the carrier's MMSC, to be fetched. Android fetches
 * it into our file ([MmsFileProvider]) and tells [MmsResultReceiver].
 */
class MmsPushReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val data = intent.getByteArrayExtra("data") ?: return
        val sub = intent.getIntExtra("android.telephony.extra.SUBSCRIPTION_INDEX", intent.getIntExtra("subscription", defaultSub()))
        val ind = try { Pdu.parse(data) } catch (e: Exception) { Log.e(TAG, "push", e); return }
        // A report on a message of ours: delivered to someone's phone, or read on it.
        if (ind.type == Pdu.DELIVERY_IND || ind.type == Pdu.READ_ORIG_IND) {
            val id = ind.messageId ?: return
            val store = Store(context)
            val state = when {
                ind.type == Pdu.READ_ORIG_IND -> if (ind.readStatus == null || ind.readStatus == 0x80) "read" else null
                ind.status == 0x81 -> "delivered" // retrieved
                else -> null
            }
            if (state != null) { store.setReceipt(id, state); Bus.changed(-1) }
            return
        }
        if (ind.type != Pdu.NOTIFICATION_IND || ind.contentLocation == null) return
        // The announcement is kept in the sender's conversation until the picture is here: if it cannot be brought
        // down, that is where it is shown, with a way to try again.
        val store = Store(context)
        val from = ind.from?.takeIf { it.isNotBlank() && !it.contains("insert-address-token", ignoreCase = true) }
        val notice = if (from == null) null else try {
            store.insertMmsNotice(store.threadFor(listOf(from)), from, ind.contentLocation, ind.transactionId, sub)
        } catch (e: Exception) { Log.e(TAG, "notice", e); null }
        if (notice != null) Bus.changed(store.threadOfMms(notice))
        download(context, ind.contentLocation, ind.transactionId, sub, notice)
    }

    companion object {
        /** Asks Android to fetch the picture message waiting at [location]. [notice]: its announcement's row, if kept. */
        fun download(context: Context, location: String, transactionId: String?, sub: Int, notice: Uri? = null, addId: Boolean = false) {
            val file = File(MmsFileProvider.dir(context), "recv-${System.nanoTime()}.pdu")
            val uri = MmsFileProvider.uriFor(context, file)
            // It waits from now until it has come: a fetch that fails is asked for again (retryWaiting).
            MmsDiag.fetching(context, location, transactionId, sub)
            try {
                val sms = smsManager(context, sub)
                // The carrier's own settings say whether its server wants the transaction id on the address
                // (MmsWhy.fetchAddress): without it, on those carriers (Verizon), every fetch is "not found".
                // [addId]: the address as announced has just been answered "not found", and is asked for with it.
                val asks = try { sms.carrierConfigValues?.getBoolean(SmsManager.MMS_CONFIG_APPEND_TRANSACTION_ID, false) ?: false } catch (_: Exception) { false }
                val from = MmsWhy.fetchAddress(location, transactionId, asks || addId)
                val done = PendingIntent.getBroadcast(context, file.name.hashCode(), Intent(context, MmsResultReceiver::class.java).apply {
                    action = MmsResultReceiver.DOWNLOADED
                    putExtra("file", file.absolutePath)
                    putExtra("location", location)
                    putExtra("tid", transactionId)
                    putExtra("sub", sub)
                    putExtra("with_id", from != location)
                    if (notice != null) putExtra("notice", notice.toString())
                }, MUTABLE)
                val how = when {
                    from == location -> if (asks) ", as announced (the carrier's settings ask for the transaction id, and this address takes none)" else ", as announced"
                    asks -> ", the transaction id added as the carrier's settings ask"
                    else -> ", the transaction id added after \"not found\" without it"
                }
                DevLog.add(context, "mms", "fetching from ${MmsWhy.hostOf(location)} on SIM $sub$how")
                sms.downloadMultimediaMessage(context, from, uri, null, done)
            } catch (e: Exception) {
                Log.e(TAG, "download", e)
                MmsDiag.note(context, "download", false, "Android wouldn't fetch it (${e.message ?: e.javaClass.simpleName})")
                failed(context, notice)
            }
        }

        /** The picture could not be brought down: its announcement says so in its conversation, and a notification leads there. */
        fun failed(context: Context, notice: Uri?) {
            val store = Store(context)
            val thread = notice?.let {
                try { store.setMmsNoticeDownloading(it, false); store.threadOfMms(it) } catch (e: Exception) { Log.e(TAG, "notice", e); null }
            }
            Notifier.downloadFailed(context, thread)
            if (thread != null) Bus.changed(thread)
        }

        /** Try again, from the conversation: the picture message announced as [id] is asked for once more. */
        fun retry(context: Context, id: Long) {
            val store = Store(context)
            val (location, transactionId, sub) = store.mmsNotice(id) ?: throw IllegalStateException("That picture is no longer waiting")
            val notice = Uri.withAppendedPath(Telephony.Mms.CONTENT_URI, id.toString())
            store.setMmsNoticeDownloading(notice, true)
            Bus.changed(store.threadOfMms(notice))
            download(context, location, transactionId, if (sub >= 0) sub else defaultSub(), notice)
        }

        /**
         * Asks again for the picture messages announced and never fetched. Answers how many were asked for. One whose
         * announcement is kept in its conversation is asked for as that one, so the conversation follows it.
         */
        fun retryWaiting(context: Context): Int {
            val all = MmsDiag.worthRetrying(context)
            val store = Store(context)
            for (w in all) {
                val notice = try { store.mmsNoticeAt(w.location) } catch (e: Exception) { Log.e(TAG, "notice", e); null }
                if (notice != null) {
                    try { store.setMmsNoticeDownloading(notice, true); Bus.changed(store.threadOfMms(notice)) } catch (e: Exception) { Log.e(TAG, "notice", e) }
                }
                download(context, w.location, w.transactionId, if (w.sub >= 0) w.sub else defaultSub(), notice)
            }
            return all.size
        }
    }
}

/** An MMS sent (or not), or one downloaded: written into the provider and shown. */
class MmsResultReceiver : BroadcastReceiver() {
    companion object {
        const val SENT = "ghost.MMS_SENT"
        const val DOWNLOADED = "ghost.MMS_DOWNLOADED"
        const val ACK = "ghost.MMS_ACK"
        const val RETRY = "ghost.MMS_RETRY"

        /** Where a picture message that was fetched and could not be read is kept, to be read again later. */
        private fun keptDir(context: Context) = File(context.filesDir, "mms-kept").apply { mkdirs() }

        /**
         * Reads again the picture messages that were fetched and could not be read (Matt, 2026-11-13: "let's focus
         * on reliability of sending pictures and whatnot"). A carrier lets go of a message once it has been fetched,
         * so one this app could not read was gone for good; now its bytes are kept, and each time the app comes
         * forward (and so after every update, which is when the reading may have been mended) they are tried again.
         */
        fun readKept(context: Context) {
            val files = keptDir(context).listFiles { f -> f.name.endsWith(".pdu") } ?: return
            val store = Store(context)
            for (f in files) {
                val about = File(f.path + ".txt").takeIf { it.exists() }?.readLines() ?: emptyList()
                // A fortnight on, it is not coming back: let it go.
                if (System.currentTimeMillis() - f.lastModified() > 14L * 24 * 3600 * 1000) { f.delete(); File(f.path + ".txt").delete(); continue }
                try {
                    if (MmsResultReceiver().keep(context, store, f.readBytes(), about.getOrNull(1)?.ifEmpty { null }, about.getOrNull(2)?.toIntOrNull() ?: defaultSub())) {
                        about.getOrNull(0)?.takeIf { it.isNotEmpty() }?.let { try { store.deleteMms(Uri.parse(it)) } catch (_: Exception) {} }
                        f.delete(); File(f.path + ".txt").delete()
                        DevLog.add(context, "mms", "a picture message that could not be read before has been read and kept")
                        Bus.changed(-1)
                    }
                } catch (_: Exception) {}
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val file = intent.getStringExtra("file")?.let { File(it) }
        val store = Store(context)
        when (intent.action) {
            SENT -> {
                val row = intent.data ?: return
                val size = file?.takeIf { it.exists() }?.length()?.let { ", ${it / 1024} KB" } ?: ""
                // The carrier's answer: it names the message (its delivery and read reports come back under that
                // name), and it says whether the message was accepted. Android calls a message sent once the
                // carrier's server has answered at all; an answer that refuses it is a message that did not go.
                val conf = try { intent.getByteArrayExtra(SmsManager.EXTRA_MMS_DATA)?.takeIf { it.isNotEmpty() }?.let { Pdu.parse(it) } } catch (e: Exception) { Log.w(TAG, "send-conf", e); null }
                val refused = if (resultCode == Activity.RESULT_OK) MmsWhy.refused(conf?.responseStatus, conf?.responseText) else null
                if (resultCode == Activity.RESULT_OK && refused == null) {
                    store.setMmsBox(row, Telephony.Mms.MESSAGE_BOX_SENT)
                    if (!conf?.messageId.isNullOrBlank()) store.setMmsMessageId(row, conf!!.messageId!!)
                    MmsDiag.cleared(context, row)
                    MmsDiag.note(context, "send", true, "sent$size")
                    DevLog.add(context, "mms", "sent$size${conf?.messageId?.let { ", the carrier's id for it ${it.take(24)}" } ?: ", no answer from the carrier to read"}")
                } else {
                    val http = intent.getIntExtra(SmsManager.EXTRA_MMS_HTTP_STATUS, 0)
                    val why = refused ?: MmsWhy.send(resultCode, http)
                    Log.w(TAG, "mms send result $resultCode: $why")
                    val id = row.lastPathSegment?.toLongOrNull()
                    val tries = id?.let { MmsDiag.tries(context, it) } ?: MmsWhy.TRIES
                    // For want of a connection, or the carrier's server in trouble: tried again unasked, twice, the
                    // message standing as Sending meanwhile. The person is told only once those have failed too.
                    if (refused == null && id != null && tries < MmsWhy.TRIES && MmsWhy.worthAnotherTry(resultCode, http)) {
                        val wait = MmsWhy.waitBefore(tries + 1)
                        DevLog.add(context, "mms", "try $tries did not go$size: $why (result $resultCode, HTTP $http). Trying again in ${wait / 1000} s")
                        val again = PendingIntent.getBroadcast(context, row.hashCode() xor 0x5a5a, Intent(context, MmsResultReceiver::class.java).apply { action = RETRY; data = row }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                        context.getSystemService(android.app.AlarmManager::class.java).setAndAllowWhileIdle(android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP, android.os.SystemClock.elapsedRealtime() + wait, again)
                        file?.delete()
                        return
                    }
                    DevLog.add(context, "mms", "not sent$size: $why (result $resultCode, HTTP $http${conf?.responseStatus?.let { ", carrier status 0x%02X".format(it) } ?: ""})${if (tries > 1) ", after $tries tries" else ""}")
                    store.setMmsBox(row, Telephony.Mms.MESSAGE_BOX_FAILED)
                    // Refused by the carrier, not for want of a connection: its pictures go smaller the next time.
                    MmsDiag.failed(context, row, why, smaller = refused != null || resultCode == 13 || (resultCode == 4 && http >= 400))
                    MmsDiag.note(context, "send", false, "$why$size")
                    Notifier.failed(context, store.threadOfMms(row))
                }
                file?.delete()
                Bus.changed(store.threadOfMms(row))
            }
            DOWNLOADED -> {
                val sub = intent.getIntExtra("sub", defaultSub())
                val bytes = file?.takeIf { it.exists() }?.readBytes()
                file?.delete()
                val notice = intent.getStringExtra("notice")?.let { Uri.parse(it) }
                val location = intent.getStringExtra("location")
                if (resultCode != Activity.RESULT_OK || bytes == null || bytes.isEmpty()) {
                    val http = intent.getIntExtra(SmsManager.EXTRA_MMS_HTTP_STATUS, 0)
                    // "Not found" at an address that stops at an equals sign, asked for without the transaction id:
                    // the carrier expects the id there and this phone's settings for it did not say so. Asked for
                    // once more with it, before anyone is told the picture could not be fetched.
                    if (location != null && MmsWhy.worthAskingWithId(http, location, intent.getStringExtra("tid"), intent.getBooleanExtra("with_id", false))) {
                        DevLog.add(context, "mms", "not found at the address as announced (HTTP 404): asking again with the transaction id added")
                        MmsPushReceiver.download(context, location, intent.getStringExtra("tid"), sub, notice, addId = true)
                        return
                    }
                    val why = if (resultCode == Activity.RESULT_OK) "the carrier sent nothing" else MmsWhy.download(resultCode, http)
                    Log.w(TAG, "mms download result $resultCode: $why")
                    DevLog.add(context, "mms", "not fetched: $why (result $resultCode, HTTP $http)")
                    MmsDiag.note(context, "download", false, why)
                    // One the carrier no longer has will never come; any other waits and is asked for again.
                    if (http == 404 || http == 410) MmsDiag.fetched(context, location)
                    // Its announcement says so in its conversation, with Try again, and the notification leads there.
                    MmsPushReceiver.failed(context, notice)
                    return
                }
                MmsDiag.fetched(context, location)
                MmsDiag.note(context, "download", true, "fetched, ${bytes.size / 1024} KB")
                DevLog.add(context, "mms", "fetched ${bytes.size / 1024} KB")
                val pending = goAsync()
                Thread {
                    try {
                        if (keep(context, store, bytes, intent.getStringExtra("tid"), sub)) {
                            // The picture is here: its announcement has done its work.
                            notice?.let { val thread = store.threadOfMms(it); store.deleteMms(it); Bus.changed(thread) }
                        } else { kept(context, bytes, notice, intent.getStringExtra("tid"), sub, "it is not a picture message"); MmsPushReceiver.failed(context, notice) }
                    } catch (e: Exception) {
                        Log.e(TAG, "keep", e)
                        kept(context, bytes, notice, intent.getStringExtra("tid"), sub, "${e.javaClass.simpleName}: ${e.message ?: ""}")
                        MmsPushReceiver.failed(context, notice)
                    }
                    finally { pending.finish() }
                }.start()
            }
            ACK -> file?.delete()
            RETRY -> {
                // The moment has passed: the message goes again, if it is still there and still waiting to go.
                val row = intent.data ?: return
                val id = row.lastPathSegment?.toLongOrNull() ?: return
                if (!store.isMmsOutbox(id)) return
                val pending = goAsync()
                Thread {
                    try { Sender.resendMms(context, id, unasked = true) } catch (e: Exception) {
                        DevLog.add(context, "mms", "could not be tried again: ${e.message ?: e.javaClass.simpleName}")
                        try { store.setMmsBox(row, Telephony.Mms.MESSAGE_BOX_FAILED); MmsDiag.failed(context, row, "it could not be tried again"); Bus.changed(store.threadOfMms(row)) } catch (_: Exception) {}
                    } finally { pending.finish() }
                }.start()
            }
        }
    }

    /** A picture message fetched and not read: its bytes are put by, with what is needed to read them again. */
    private fun kept(context: Context, bytes: ByteArray, notice: Uri?, transactionId: String?, sub: Int, why: String) {
        try {
            val f = File(keptDir(context), "${System.currentTimeMillis()}.pdu")
            f.writeBytes(bytes)
            File(f.path + ".txt").writeText(listOf(notice?.toString() ?: "", transactionId ?: "", sub.toString()).joinToString("\n"))
            DevLog.add(context, "mms", "fetched ${bytes.size / 1024} KB but it could not be read ($why): kept, to be read again. It begins ${bytes.take(12).joinToString(" ") { "%02x".format(it) }}")
        } catch (_: Exception) {}
    }

    /** Keeps the picture message in [bytes]; false where they are no picture message, or it could not be kept. */
    internal fun keep(context: Context, store: Store, bytes: ByteArray, notificationTid: String?, sub: Int): Boolean {
        val m = Pdu.parse(bytes)
        if (m.type != Pdu.RETRIEVE_CONF) return false
        val own = store.ownNumbers()
        val from = m.from ?: ""
        // The people of the conversation: the sender and everyone else it went to, never this phone. With no number
        // of its own known, a message to one address is taken to be to this phone alone.
        val others = (m.to + m.cc).filter { !store.isOwn(it, own) }
        val people = if (m.to.size + m.cc.size <= 1) listOf(from) else (listOf(from) + others)
        val unique = people.filter { it.isNotBlank() }.distinctBy { it.filter(Char::isDigit).takeLast(10).ifEmpty { it } }
        val thread = store.threadFor(unique.ifEmpty { listOf(from) })
        val row = store.insertMms(
            Telephony.Mms.MESSAGE_BOX_INBOX, thread, from, m.to, m.cc, m.parts,
            m.date ?: (System.currentTimeMillis() / 1000), m.subject, m.messageId, m.transactionId ?: notificationTid, sub,
        )
        if (row != null) {
            // A chat background shared by someone here with the app: the message's picture, or what its words name.
            try {
                val words = m.parts.filter { it.contentType.startsWith("text/plain") }.joinToString("\n") { String(it.data, Charsets.UTF_8) }
                BackgroundWire.valueIn(words)?.let { value ->
                    Backgrounds.sawGhost(context, from)
                    Backgrounds.received(context, thread, value, m.parts.firstOrNull { it.contentType.startsWith("image/") }?.data)
                }
            } catch (e: Exception) { Log.e(TAG, "shared background", e) }
            store.setArchived(thread, false)
            Notifier.incoming(context, thread)
            Bus.changed(thread)
        }
        // Tell the MMSC it came down, or it may send the notification again.
        val tid = notificationTid ?: m.transactionId ?: return row != null
        try {
            val ack = File(MmsFileProvider.dir(context), "ack-${System.nanoTime()}.pdu")
            ack.writeBytes(Pdu.notifyRespInd(tid))
            val pi = PendingIntent.getBroadcast(context, ack.name.hashCode(), Intent(context, MmsResultReceiver::class.java).apply {
                action = ACK; putExtra("file", ack.absolutePath)
            }, MUTABLE)
            smsManager(context, sub).sendMultimediaMessage(context, MmsFileProvider.uriFor(context, ack), null, null, pi)
        } catch (e: Exception) { Log.w(TAG, "ack", e) }
        return row != null
    }
}
