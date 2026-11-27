package com.infamousvague.ghostmessaging

import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64

/**
 * One connection from a paired computer, as the phone answers it (docs/desktop.md). It knows nothing of sockets:
 * frames come in through [receive] and go out through the function it was given, so the local network and the relay
 * are the same to it, and it runs on the JVM under test (DeskSessionTest) with a made-up phone behind it.
 *
 * A connection goes: the computer's hello in the clear (which pairing, a random number, a throwaway public key),
 * the phone's hello back, and from then sealed frames only ([DeskCrypto.Channel]). The computer's first sealed
 * frame, `ready`, is what shows it holds the pairing's key: nothing is answered before it. Then the computer asks
 * (`req`), the phone answers (`res`), and either may say something happened (`ev`).
 */
class DeskSession(private val host: DeskHost, val via: String, private val out: (ByteArray) -> Unit, private val random: SecureRandom = SecureRandom()) {
    /** The pairing this connection is under: its id once paired, the QR code's while pairing. */
    @Volatile var id: String = ""
        private set

    /** The two are still comparing their codes: nothing is asked or answered until both said they match. */
    @Volatile var pairing = false
        private set

    /** The computer has proved it holds the key. */
    @Volatile var live = false
        private set

    @Volatile var closed = false
        private set

    /** The computer's name, as its `ready` gave it. */
    @Volatile var peerName: String = ""
        private set

    /** Told once when the connection ends, so whatever carried it (a socket) can be let go. */
    @Volatile var onClosed: (() -> Unit)? = null

    private var channel: DeskCrypto.Channel? = null
    private val sendLock = Any()

    /**
     * One frame from the computer, as whatever carries the connection hands it over: a kind byte, then a hello in the
     * clear or a sealed message. A frame that is empty, too long, of no known kind or that will not open ends it.
     */
    fun receive(frame: ByteArray) {
        if (closed) return
        if (frame.isEmpty() || frame.size > DeskCrypto.MAX_FRAME) return close()
        val body = frame.copyOfRange(1, frame.size)
        when (frame[0]) {
            DeskCrypto.HELLO -> hello(body)
            DeskCrypto.SEALED -> {
                val text = channel?.open(body) ?: return close()
                val message = try { JSONObject(text) } catch (_: Exception) { return close() }
                sealed(message)
            }
            else -> close()
        }
    }

    /**
     * The computer's first frame, in the clear: who it says it is, a nonce and a one-time public key. Answered with
     * the phone's, and the session's keys are made from both and the key the two share (the pairing's, or the one
     * being made). Nothing is trusted yet: that comes with a sealed `ready`, which only the key's holder can send.
     */
    private fun hello(body: ByteArray) {
        // One hello to a connection: a second would ask for new keys under the old connection's name.
        if (channel != null) return close()
        val refuse = { why: String -> out(byteArrayOf(DeskCrypto.HELLO) + JSONObject().put("v", 1).put("err", why).toString().toByteArray()); close() }
        val o = try { JSONObject(String(body, Charsets.UTF_8)) } catch (_: Exception) { return close() }
        if (o.optInt("v") != 1) return refuse("version")
        val name = o.optString("id")
        val wantsPairing = o.optBoolean("pair", false)
        val theirNonce = try { Base64.getDecoder().decode(o.optString("n")) } catch (_: Exception) { return close() }
        val theirKey = try { Base64.getDecoder().decode(o.optString("e")) } catch (_: Exception) { return close() }
        if (theirNonce.size != 16 || theirKey.size != 33) return close()

        val pending = if (wantsPairing) host.pending(name) else null
        val key = if (wantsPairing) pending?.key else host.pairKey(name)
        if (key == null) return refuse("unknown")

        val mine = E2eCrypto.newKeyPair()
        val nonce = ByteArray(16).also { random.nextBytes(it) }
        val keys = DeskCrypto.sessionKeys(key, theirNonce, nonce, mine.private, theirKey) ?: return close()
        channel = DeskCrypto.Channel(sendKey = keys.second, receiveKey = keys.first)
        id = name
        pairing = wantsPairing
        val reply = JSONObject().put("v", 1)
            .put("n", Base64.getEncoder().encodeToString(nonce))
            .put("e", Base64.getEncoder().encodeToString(E2eCrypto.publicBytes(mine.public)))
        // While pairing the computer does not have the phone's public key yet: it travels here, in the clear. Swapped
        // on the way, it makes a key the swapper cannot (the QR code's secret is in it), and the codes will not match.
        if (pending != null) reply.put("k", Base64.getEncoder().encodeToString(pending.phonePublic))
        out(byteArrayOf(DeskCrypto.HELLO) + reply.toString().toByteArray())
    }

    /**
     * A message that opened under the session's key: `ready` once, then `ev` (something the computer says) and `req`
     * (something it asks, answered with a `res` of the same id). Anything else ends the connection.
     */
    private fun sealed(m: JSONObject) {
        val type = m.optString("t")
        if (type == "ready") {
            if (live) return close()
            live = true
            peerName = m.optString("name").take(60)
            send(JSONObject().put("t", "ready").put("name", host.name).put("app", host.app).put("proto", 1).put("mode", host.mode(this)))
            host.event(this, "ready", m)
            return
        }
        if (!live) return close()
        when (type) {
            "ev" -> host.event(this, m.optString("m"), m.optJSONObject("a") ?: JSONObject())
            "req" -> {
                val call = m.optInt("id")
                if (pairing) { send(JSONObject().put("t", "res").put("id", call).put("ok", false).put("e", "Not paired yet")); return }
                val method = m.optString("m")
                val args = m.optJSONObject("a") ?: JSONObject()
                host.run(method) {
                    var answer = JSONObject().put("t", "res").put("id", call)
                    try { answer.put("ok", true).put("r", toJson(host.call(this, method, args))) }
                    catch (e: Exception) { answer.put("ok", false).put("e", e.message ?: e.toString()) }
                    // An answer too long for one frame would end the connection at the other end, and the next one
                    // after it: it is said in words, and the computer asks for less (a list a lot at a time).
                    if (answer.toString().length > DeskCrypto.MAX_FRAME - 1024) {
                        answer = JSONObject().put("t", "res").put("id", call).put("ok", false).put("e", "Too much to send at once")
                    }
                    send(answer)
                }
            }
            else -> close()
        }
    }

    /** Both said the codes match: this connection goes on as an ordinary one, under the pairing's own id. */
    fun paired(newId: String) {
        id = newId
        pairing = false
    }

    /** Something happened that the computer should know: a conversation changed, the pairing was removed. */
    fun event(name: String, args: JSONObject? = null) {
        if (!live || closed) return
        val m = JSONObject().put("t", "ev").put("m", name)
        if (args != null) m.put("a", args)
        send(m)
    }

    private fun send(message: JSONObject) {
        val channel = channel ?: return
        // Sealed and sent as one step: frames must arrive in the order their counters were taken.
        synchronized(sendLock) {
            if (closed) return
            try { out(byteArrayOf(DeskCrypto.SEALED) + channel.seal(message.toString())) } catch (_: Exception) { close() }
        }
    }

    /** Ends the session, once: the host and whatever carried it are told. */
    fun close() {
        if (closed) return
        closed = true
        live = false
        host.closed(this)
        try { onClosed?.invoke() } catch (_: Exception) {}
    }

    companion object {
        /** What a call answered, as JSON: maps and lists as they are, bytes as base64. */
        fun toJson(value: Any?): Any = when (value) {
            null -> JSONObject.NULL
            is Map<*, *> -> JSONObject().also { o -> for ((k, v) in value) o.put(k.toString(), toJson(v)) }
            is Iterable<*> -> JSONArray().also { a -> for (v in value) a.put(toJson(v)) }
            is ByteArray -> Base64.getEncoder().encodeToString(value)
            is Array<*> -> JSONArray().also { a -> for (v in value) a.put(toJson(v)) }
            else -> value
        }
    }
}

/** A pairing in progress, as a session needs it: the key both sides will keep, and the phone's public half of it. */
class DeskPending(val key: ByteArray, val phonePublic: ByteArray)

/** What a session needs of the phone around it (Desk.kt on a phone; a made-up one under test). */
interface DeskHost {
    /** The phone's name, as the computer shows it, and the app's version. */
    val name: String
    val app: String

    /** The key of the paired computer [id] names, or null: unpaired, or never paired. */
    fun pairKey(id: String): ByteArray?

    /** The pairing in progress the QR code's [pairingId] names, or null. */
    fun pending(pairingId: String): DeskPending?

    /** How [session]'s pairing connects: both, local, relay. */
    fun mode(session: DeskSession): String

    /** Does what the computer asked; an exception's message is the computer's to show. */
    fun call(session: DeskSession, method: String, args: JSONObject): Any?

    /** `ready` (the computer proved itself), or what the computer said: confirmed, cancel, unpaired, mode. */
    fun event(session: DeskSession, name: String, args: JSONObject)

    /** Runs [work] off the thread frames arrive on, so a long read does not hold the next frame. */
    fun run(method: String, work: () -> Unit)

    /** The session has ended, however it ended: it is to be forgotten. */
    fun closed(session: DeskSession)
}

/** What the phone does for a computer: what the screen's own channel asks of Android (MainActivity), a part of it. */
interface DeskPhone {
    fun conversations(): List<Map<String, Any?>>

    /** A lot of conversations, the newest first: `items`, and `next`, the row the next lot starts at (Store). */
    fun conversationsPage(limit: Int, offset: Int, pinned: Boolean, archived: Boolean): Map<String, Any?>
    fun conversation(thread: Long): Map<String, Any?>?
    fun archivedCount(): Int
    fun messages(thread: Long, limit: Int): List<Map<String, Any?>>
    fun people(thread: Long): List<Map<String, Any?>>
    fun threadFor(addresses: List<String>): Long
    fun searchContacts(query: String): List<Map<String, Any?>>
    fun contact(address: String): Map<String, Any?>
    fun photo(uri: String): ByteArray?
    fun part(id: Long): ByteArray?
    fun send(addresses: List<String>, body: String): Long
    fun markRead(thread: Long)
    fun setFlag(name: String, thread: Long, on: Boolean)

    /** Gives a conversation a name on this phone, or takes it away with an empty one (Store.setThreadName). */
    fun setName(thread: Long, name: String)
    fun archive(thread: Long, archived: Boolean)
    fun draft(thread: Long): String?
    fun setDraft(thread: Long, text: String)
    fun e2e(address: String): Map<String, Any?>

    /** The conversation a text the computer named [key] went to, if it was already sent; and remembering one. */
    fun sent(key: String): Long?
    fun remember(key: String, thread: Long)

    // What a computer may also do since the phone's screens became the computer's (Matt, 2026-11-14: "the desktop
    // app should get all featues its missing from mobile"): what those screens do on the phone.
    fun deleteMessage(kind: String, id: Long)
    fun voice(what: Map<String, Any?>): Any?
    fun rcs(what: Map<String, Any?>): Any?
    fun signins(what: Map<String, Any?>): Any?
    fun telegram(what: Map<String, Any?>): Any?
    fun deleteThreads(threads: List<Long>): Int
    fun editMessage(kind: String, id: Long, body: String)

    /** A picture message that did not go, sent again with its own pictures ([body]: other words for it). */
    fun resendMms(id: Long, body: String?): Long
    fun setBlocked(address: String, blocked: Boolean)
    fun blockedNumbers(): List<Map<String, Any?>>
    fun e2eOffer(address: String): Map<String, Any?>
    fun e2eOff(address: String)
    fun e2eVerify(address: String, verified: Boolean)
    fun e2ePlainSeen(address: String)
    fun e2eList(): List<Map<String, Any?>>
    fun mmsStatus(): Map<String, Any?>

    /** How long a voice message may run on this phone's carrier: `seconds`, and `bytes`. */
    fun voiceLimit(): Map<String, Any?>

    /** Pictures the computer handed over, sent as the phone sends its own: made to fit, with [body] beside them. */
    fun sendPictures(addresses: List<String>, body: String, files: List<DeskFile>): Long

    /** A recording made on the computer, sent as a voice message (Voice.kt's kind: AAC in an `.m4a`). */
    fun sendVoice(addresses: List<String>, sound: DeskFile): Long

    /** One of the app's stickers, which the computer has too: its picture under its travelling [name]. */
    fun sendSticker(addresses: List<String>, name: String, picture: ByteArray): Long

    /** This phone's own number, as its screens show it; null where Android does not say and none was typed. */
    fun ownNumber(): String?

    /**
     * Settings › Me's number, done by the phone for the computer (Matt, 2026-11-14: "on desktop the phone number reads
     * as unknown and is not proxying the verification process"): [what] is one of the app's `{"dir": …}` asks, which
     * Dart answers (lib/me/me.dart, Me.forComputer). The code is texted to the phone and checked as the phone's.
     */
    fun me(what: Map<String, Any?>): Any?

    /** Friends by username: listed, looked up, asked, answered, removed (lib/friends/buddies.dart forComputer). */
    fun buddies(what: Map<String, Any?>): Any?

    /** The identity, friends by username and conversations with them, for the computer's own network (handover.dart). */
    fun handover(what: Map<String, Any?>): Any?

    /**
     * Translation done by the phone for the computer (Translate.kt; Matt, 2026-11-17: "add a translate plugin which
     * can automatically translate texts when detected from another language"): [what] has `op` ("text", "languages",
     * "model") and that request's own values. Null from a phone that has none.
     */
    fun translate(what: Map<String, Any?>): Any? = null
}

/** Something a computer handed over to be sent: its name, its kind, and what is in it. */
class DeskFile(val name: String, val type: String, val bytes: ByteArray)

/**
 * The computer's requests, by name, onto [DeskPhone]. What is not here the computer cannot do. At first it read, sent
 * text, marked read, pinned, muted, archived and kept a draft, and no more. Since 2026-11-14 the computer's screens
 * are the phone's own (Matt: "Unify the UI experience … the desktop app should get all featues its missing from
 * mobile"), so it also does what those screens do: deletes and edits, sends a picture message again, blocks, turns
 * encryption on and off with someone, and sends pictures, a voice recording and stickers, which it hands over in
 * pieces ([put]) since a frame holds less than a megabyte. It still cannot read or change the phone's own settings,
 * its other paired computers, or its encryption key. [CAPS] says what this phone does, so a computer asks first
 * and offers only that.
 */
class DeskCalls(private val phone: DeskPhone, private val now: () -> Long = System::currentTimeMillis) {
    /** The pictures and videos being handed over a piece at a time, newest last: several at once, since a computer
     *  fetches every picture a conversation shows together. It held one, so two fetched together each read their
     *  whole file again for every piece (a 10 MB video 27 times over), on two threads, until the computer gave up
     *  waiting and the picture never came (Matt, 2026-11-20: "some photos and videos are not coming through"). */
    private val parts = LinkedHashMap<Long, ByteArray>(8, 0.75f, true)

    /** What the computer is handing over, by the name it gave each: filled a piece at a time, taken by what sends it. */
    private class Upload(val total: Int, var touched: Long) { val bytes = java.io.ByteArrayOutputStream() }
    private val uploads = LinkedHashMap<String, Upload>()

    /** Does [method] with the arguments [a] and gives its answer; throws, in words for the computer, where it can't. */
    fun call(method: String, a: JSONObject): Any? = when (method) {
        "ping" -> null
        "conversations" -> phone.conversations()
        // A lot at a time, as the phone's own list reads them: never the whole of a store with thousands at once.
        "conversationsPage" -> phone.conversationsPage(
            limit = if (a.optBoolean("archived")) 0 else a.optInt("limit", LOT).coerceIn(1, LOT),
            offset = a.optInt("offset", 0).coerceAtLeast(0),
            pinned = a.optBoolean("pinned"),
            archived = a.optBoolean("archived"),
        )
        "conversation" -> phone.conversation(a.getLong("thread"))
        "archivedCount" -> phone.archivedCount()
        "messages" -> phone.messages(a.getLong("thread"), a.optInt("limit", 300).coerceIn(1, 1000))
        "people" -> phone.people(a.getLong("thread"))
        "threadFor" -> phone.threadFor(strings(a.getJSONArray("addresses")))
        "searchContacts" -> phone.searchContacts(a.optString("query"))
        "contact" -> phone.contact(a.getString("address"))
        "photo" -> phone.photo(a.getString("uri"))?.takeIf { it.size <= PIECE }
        "part" -> piece(a.getLong("id"), a.optInt("offset", 0), a.optInt("max", PIECE))
        "send" -> send(a.getString("key"), strings(a.getJSONArray("addresses")), a.optString("body"))
        "markRead" -> { phone.markRead(a.getLong("thread")); null }
        "threadFlag" -> {
            val name = a.getString("name")
            require(name == "pinned" || name == "muted") { "Not something a computer can change" }
            phone.setFlag(name, a.getLong("thread"), a.optBoolean("on", true)); null
        }
        "threadName" -> { phone.setName(a.getLong("thread"), a.optString("name")); null }
        "archive" -> { phone.archive(a.getLong("thread"), a.optBoolean("archived", true)); null }
        "draft" -> phone.draft(a.getLong("thread"))
        "setDraft" -> { phone.setDraft(a.getLong("thread"), a.optString("text")); null }
        "e2e" -> phone.e2e(a.getString("address"))
        "caps" -> CAPS
        "ownNumber" -> phone.ownNumber()
        "me" -> phone.me(plain(a.getJSONObject("what")))
        // Friends by username, the phone's, added and answered from the computer (lib/friends/buddies.dart): by Dart.
        "buddies" -> phone.buddies(plain(a.getJSONObject("what")))
        // The phone's identity and friends, handed to the computer for friends and circles of its own: by Dart.
        "handover" -> phone.handover(plain(a.getJSONObject("what")))
        // Voice channels, the phone's and the computer's kept in step (lib/voice/channels.dart): answered by Dart.
        "voice" -> phone.voice(plain(a.getJSONObject("what")))
        // How RCS stands on the phone, for its computer to say so (GMFB-11, lib/gm/rcs_share.dart): answered by Dart.
        "rcs" -> phone.rcs(plain(a.optJSONObject("what") ?: org.json.JSONObject()))
        // The networks' sign-ins the phone holds, for a computer that can't read the account's (lib/inbox/curl_sync.dart).
        "signins" -> phone.signins(plain(a.optJSONObject("what") ?: org.json.JSONObject()))
        // The phone's Telegram signs its computer in (lib/inbox/telegram.dart): answered by Dart.
        "telegram" -> phone.telegram(plain(a.getJSONObject("what")))
        // A text in another language, translated on the phone for the computer (Translate.kt).
        "translate" -> phone.translate(plain(a.getJSONObject("what")))
        "deleteMessage" -> { phone.deleteMessage(kind(a), a.getLong("id")); null }
        "deleteThread" -> phone.deleteThreads(listOf(a.getLong("thread")))
        "deleteThreads" -> phone.deleteThreads(longs(a.getJSONArray("threads")))
        "editMessage" -> { phone.editMessage(kind(a), a.getLong("id"), a.optString("body")); null }
        "resendMms" -> phone.resendMms(a.getLong("id"), if (a.isNull("body")) null else a.optString("body"))
        "setBlocked" -> { phone.setBlocked(a.getString("address"), a.optBoolean("blocked", true)); null }
        "blockedNumbers" -> phone.blockedNumbers()
        "e2eOffer" -> phone.e2eOffer(a.getString("address"))
        "e2eOff" -> { phone.e2eOff(a.getString("address")); null }
        "e2eVerify" -> { phone.e2eVerify(a.getString("address"), a.optBoolean("verified", true)); null }
        "e2ePlainSeen" -> { phone.e2ePlainSeen(a.getString("address")); null }
        "e2eList" -> phone.e2eList()
        "mmsStatus" -> phone.mmsStatus()
        "voiceLimit" -> phone.voiceLimit()
        "put" -> put(a.getString("upload"), a.optInt("offset", 0), a.getInt("total"), Base64.getDecoder().decode(a.getString("data")))
        "drop" -> { synchronized(uploads) { uploads.remove(a.getString("upload")) }; null }
        "sendPictures" -> {
            val listed = a.getJSONArray("files")
            require(listed.length() in 1..MOST_PICTURES) { "A message takes up to $MOST_PICTURES pictures" }
            val files = (0 until listed.length()).map { listed.getJSONObject(it) }
            for (f in files) require(f.optString("type").startsWith("image/")) { "Only pictures can be sent from a computer for now" }
            once(a.getString("key")) {
                phone.sendPictures(strings(a.getJSONArray("addresses")), a.optString("body"), files.map { DeskFile(safeName(it.optString("name"), "picture"), it.getString("type"), take(it.getString("upload"))) })
            }
        }
        "sendVoice" -> once(a.getString("key")) {
            phone.sendVoice(strings(a.getJSONArray("addresses")), DeskFile(safeName(a.optString("name"), "voice.m4a"), "audio/mp4", take(a.getString("upload"))))
        }
        "sendSticker" -> {
            val name = a.getString("name")
            require(Stickers.isSticker(name) && name == safeName(name, "")) { "That is not one of the app's stickers" }
            once(a.getString("key")) { phone.sendSticker(strings(a.getJSONArray("addresses")), name, take(a.getString("upload"))) }
        }
        else -> throw IllegalArgumentException("The phone doesn't do \"$method\" for a computer")
    }

    /** The `kind` argument, which must be "sms" or "mms": it names the table a message's id is in. */
    private fun kind(a: JSONObject): String = a.getString("kind").also { require(it == "sms" || it == "mms") { "Not a kind of message" } }

    /**
     * Sends [body] once. The computer names each text it asks for; asked again for one already sent (its answer was
     * lost with the connection, and it tried again), the phone says where it went and sends nothing.
     */
    private fun send(key: String, addresses: List<String>, body: String): Map<String, Any?> {
        require(body.isNotBlank()) { "Nothing to send" }
        return once(key) { phone.send(addresses, body) }
    }

    /** Whatever is sent is sent once: [send] under [key], or where that already went if it did. */
    @Synchronized
    private fun once(key: String, send: () -> Long): Map<String, Any?> {
        require(key.isNotBlank() && key.length <= 64) { "What is sent needs a name" }
        phone.sent(key)?.let { return mapOf("thread" to it, "again" to true) }
        val thread = send()
        phone.remember(key, thread)
        return mapOf("thread" to thread)
    }

    /**
     * A piece of something the computer is handing over: [data] at [offset] of [total] bytes, under the name [id] it
     * gave. Pieces come in order; one already had is answered and not kept twice (its answer was lost, and it was sent
     * again). Answers how much is here. What is never sent is let go after [STALE] milliseconds, or when a newer one
     * needs the room.
     */
    private fun put(id: String, offset: Int, total: Int, data: ByteArray): Map<String, Any?> = synchronized(uploads) {
        require(Regex("[0-9a-f]{8,32}").matches(id)) { "Not a name for what is handed over" }
        require(total in 1..MOST_BYTES) { "That is too large to hand over (${MOST_BYTES / (1024 * 1024)} MB at most)" }
        require(data.size in 1..PIECE) { "Not a piece" }
        val at = now()
        uploads.entries.removeAll { at - it.value.touched > STALE }
        val u = uploads[id] ?: Upload(total, at).also {
            require(offset == 0) { "That did not start at its beginning" }
            while (uploads.size >= MOST_AT_ONCE || uploads.values.sumOf { v -> v.total } + total > MOST_HELD) {
                uploads.remove(uploads.keys.firstOrNull() ?: break)
            }
            uploads[id] = it
        }
        require(u.total == total) { "Its length changed on the way" }
        val have = u.bytes.size()
        when {
            offset == have -> {
                require(have + data.size <= total) { "More came than it said it holds" }
                u.bytes.write(data)
            }
            // A piece already here, come again.
            offset + data.size <= have -> {}
            else -> throw IllegalArgumentException("A piece came out of its turn")
        }
        u.touched = at
        mapOf("have" to u.bytes.size())
    }

    /** What was handed over as [id], whole, and no longer held. */
    private fun take(id: String): ByteArray = synchronized(uploads) {
        val u = uploads[id] ?: throw IllegalArgumentException("That was not handed over, or was let go: send it again")
        require(u.bytes.size() == u.total) { "That did not arrive whole" }
        uploads.remove(id)
        u.bytes.toByteArray()
    }

    /** A file's name as the phone will keep it: its last part, plain letters, never a path. */
    private fun safeName(said: String, otherwise: String): String {
        val last = said.substringAfterLast('/').substringAfterLast('\\')
        val plain = last.filter { it.isLetterOrDigit() || it == '.' || it == '-' || it == '_' }.take(80).trimStart('.')
        return plain.ifEmpty { otherwise }
    }

    private fun longs(a: JSONArray): List<Long> = (0 until a.length()).map { a.getLong(it) }

    /** What the computer sent, as Dart's channel carries it: maps, lists, strings, numbers, true and false. */
    private fun plain(o: Any?): Any? = when (o) {
        is JSONObject -> o.keys().asSequence().associateWith { plain(o.opt(it)) }
        is JSONArray -> (0 until o.length()).map { plain(o.opt(it)) }
        JSONObject.NULL -> null
        else -> o
    }

    @Suppress("UNCHECKED_CAST")
    private fun plain(o: JSONObject): Map<String, Any?> = plain(o as Any?) as Map<String, Any?>

    /** A picture crosses in pieces: [max] bytes from [offset], and how long the whole is. */
    @Synchronized
    private fun piece(id: Long, offset: Int, max: Int): Map<String, Any?>? {
        val bytes = synchronized(parts) { parts[id] } ?: (phone.part(id) ?: return null).also { keepPart(id, it) }
        val from = offset.coerceIn(0, bytes.size)
        val to = (from + max.coerceIn(1, PIECE)).coerceAtMost(bytes.size)
        if (to >= bytes.size) synchronized(parts) { parts.remove(id) }
        return mapOf("data" to bytes.copyOfRange(from, to), "total" to bytes.size)
    }

    /** Keeps [bytes] for the pieces to come, the longest unused going first past [PARTS_HELD] or [PARTS_BYTES]. */
    private fun keepPart(id: Long, bytes: ByteArray) = synchronized(parts) {
        parts[id] = bytes
        val it = parts.entries.iterator()
        while ((parts.size > PARTS_HELD || parts.values.sumOf { b -> b.size.toLong() } > PARTS_BYTES) && it.hasNext()) {
            it.next()
            if (parts.size <= 1) break
            it.remove()
        }
    }

    private fun strings(a: JSONArray): List<String> = (0 until a.length()).map { a.getString(it) }

    companion object {
        /** As much of a picture as one frame carries: its base64 stays well under [DeskCrypto.MAX_FRAME]. */
        const val PIECE = 384 * 1024

        /** The most pictures and videos held while their pieces go over, and their bytes in all. */
        const val PARTS_HELD = 6
        const val PARTS_BYTES = 64L * 1024 * 1024

        /** The most conversations handed over at once. */
        const val LOT = 250

        /** What a computer hands over: the most one may hold, how many at once and in all, and how long unsent. */
        const val MOST_BYTES = 12 * 1024 * 1024
        const val MOST_AT_ONCE = 8
        const val MOST_HELD = 36 * 1024 * 1024
        const val STALE = 5 * 60 * 1000L

        /** As many pictures as the phone's own message takes. */
        const val MOST_PICTURES = 5

        /** What this phone does for a computer beyond the first few: a computer asks (`caps`) and offers these. */
        val CAPS = listOf(
            "threadName", "deleteMessage", "deleteThread", "deleteThreads", "editMessage", "resendMms", "setBlocked", "blockedNumbers",
            "e2eOffer", "e2eOff", "e2eVerify", "e2ePlainSeen", "e2eList", "mmsStatus", "voiceLimit",
            "put", "drop", "sendPictures", "sendVoice", "sendSticker", "ownNumber", "me", "voice", "telegram",
            "translate", "buddies", "handover", "rcs", "signins",
        )
    }
}
