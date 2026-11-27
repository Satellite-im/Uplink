package com.infamousvague.ghostmessaging

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom
import java.util.Base64

/** A computer, played here in Kotlin, against the phone's session with a made-up phone behind it. */
class DeskSessionTest {
    private val random = SecureRandom()

    /** A phone with two conversations, that remembers what it was asked to send. */
    private class FakePhone : DeskPhone {
        val sentTexts = ArrayList<Pair<List<String>, String>>()
        val read = ArrayList<Long>()
        val keys = HashMap<String, Long>()
        var picture = ByteArray(1000000) { (it % 251).toByte() }
        /** How many conversations the phone holds, each with a snippet [snippetLength] long. */
        var held = 1
        var snippetLength = 12
        private fun one(i: Int) = mapOf("id" to (7L + i), "snippet" to if (i == 0) "See you at 7" else "x".repeat(snippetLength), "people" to listOf(mapOf("address" to "+15550100", "name" to "Maya")))
        override fun conversations() = (0 until held).map(::one)
        override fun conversationsPage(limit: Int, offset: Int, pinned: Boolean, archived: Boolean): Map<String, Any?> {
            val end = if (limit <= 0) held else minOf(held, offset + limit)
            return mapOf("items" to (offset until end).map(::one), "next" to (if (end < held) end else null), "asked" to limit)
        }
        override fun conversation(thread: Long) = if (thread == 7L) one(0) else null
        override fun archivedCount() = 0
        override fun messages(thread: Long, limit: Int) = listOf(mapOf("id" to 1L, "kind" to "sms", "body" to "See you at 7", "thread" to thread, "limit" to limit))
        override fun people(thread: Long) = listOf(mapOf("address" to "+15550100"))
        override fun threadFor(addresses: List<String>) = 7L
        override fun searchContacts(query: String) = emptyList<Map<String, Any?>>()
        override fun contact(address: String) = mapOf<String, Any?>("address" to address)
        override fun photo(uri: String): ByteArray? = byteArrayOf(1, 2, 3)
        override fun ownNumber(): String? = "+14436537451"
        val asked = ArrayList<Map<String, Any?>>()
        override fun me(what: Map<String, Any?>): Any? { asked.add(what); return mapOf("dir" to "text", "handle" to what["handle"]) }
        override fun buddies(what: Map<String, Any?>): Any? { asked.add(what); return mapOf("list" to emptyList<Any>()) }
        override fun handover(what: Map<String, Any?>): Any? { asked.add(what); return emptyMap<String, Any?>() }
        var video = ByteArray(2000000) { (it % 241).toByte() }
        var partReads = 0
        override fun part(id: Long): ByteArray? = when (id) { 5L -> picture; 7L -> video; else -> null }?.also { partReads++ }
        override fun send(addresses: List<String>, body: String): Long { sentTexts += addresses to body; return 7L }
        override fun markRead(thread: Long) { read += thread }
        override fun setFlag(name: String, thread: Long, on: Boolean) {}
        override fun setName(thread: Long, name: String) { did += "name $thread $name" }
        override fun archive(thread: Long, archived: Boolean) {}
        override fun draft(thread: Long): String? = null
        override fun setDraft(thread: Long, text: String) {}
        override fun e2e(address: String) = mapOf<String, Any?>("state" to "none")
        override fun sent(key: String): Long? = keys[key]
        override fun remember(key: String, thread: Long) { keys[key] = thread }

        /** What the phone's screens do, asked of it by a computer: each remembered as it was asked. */
        val did = ArrayList<String>()
        val files = ArrayList<DeskFile>()
        override fun deleteMessage(kind: String, id: Long) { did += "deleteMessage $kind $id" }
        override fun voice(what: Map<String, Any?>): Any? = null
        override fun rcs(what: Map<String, Any?>): Any? = null
        override fun signins(what: Map<String, Any?>): Any? = null
        override fun telegram(what: Map<String, Any?>): Any? = null
        override fun deleteThreads(threads: List<Long>): Int { did += "deleteThreads $threads"; return threads.size }
        override fun editMessage(kind: String, id: Long, body: String) { did += "editMessage $kind $id $body" }
        override fun resendMms(id: Long, body: String?): Long { did += "resendMms $id $body"; return 7L }
        override fun setBlocked(address: String, blocked: Boolean) { did += "setBlocked $address $blocked" }
        override fun blockedNumbers() = listOf(mapOf<String, Any?>("address" to "+15550199"))
        override fun e2eOffer(address: String): Map<String, Any?> { did += "e2eOffer $address"; return mapOf("state" to "offered") }
        override fun e2eOff(address: String) { did += "e2eOff $address" }
        override fun e2eVerify(address: String, verified: Boolean) { did += "e2eVerify $address $verified" }
        override fun e2ePlainSeen(address: String) { did += "e2ePlainSeen $address" }
        override fun e2eList() = listOf(mapOf<String, Any?>("address" to "+15550100", "state" to "on"))
        override fun mmsStatus() = mapOf<String, Any?>("dataOn" to true)
        override fun voiceLimit() = mapOf<String, Any?>("seconds" to 91, "bytes" to 299008)
        override fun sendPictures(addresses: List<String>, body: String, files: List<DeskFile>): Long { did += "sendPictures $addresses $body ${files.map { it.name + ":" + it.type }}"; this.files += files; return 7L }
        override fun sendVoice(addresses: List<String>, sound: DeskFile): Long { did += "sendVoice $addresses ${sound.name}"; files += sound; return 7L }
        override fun sendSticker(addresses: List<String>, name: String, picture: ByteArray): Long { did += "sendSticker $addresses $name"; files += DeskFile(name, "image/png", picture); return 7L }
    }

    private class Host(val phone: FakePhone) : DeskHost {
        val keys = HashMap<String, ByteArray>()
        val pendings = HashMap<String, DeskPending>()
        val events = ArrayList<String>()
        val calls = DeskCalls(phone)
        override val name = "Fold"
        override val app = "0.7.0"
        override fun pairKey(id: String) = keys[id]
        override fun pending(pairingId: String) = pendings[pairingId]
        override fun mode(session: DeskSession) = "both"
        override fun call(session: DeskSession, method: String, args: JSONObject) = calls.call(method, args)
        override fun event(session: DeskSession, name: String, args: JSONObject) { events += name }
        override fun run(method: String, work: () -> Unit) = work()
        override fun closed(session: DeskSession) { events += "closed" }
    }

    /** The computer's side of one connection. */
    private inner class Computer(val host: Host, val pairKey: ByteArray?, val id: String, val pairing: Boolean = false, val secret: ByteArray? = null, val deskPrivate: java.security.PrivateKey? = null, val deskPublic: ByteArray? = null) {
        val fromPhone = ArrayList<ByteArray>()
        val session = DeskSession(host, "local", { fromPhone += it })
        var channel: DeskCrypto.Channel? = null
        var key: ByteArray? = pairKey
        var refused: String? = null
        private var next = 1

        fun hello() {
            val eph = E2eCrypto.newKeyPair()
            val nonce = ByteArray(16).also { random.nextBytes(it) }
            val hello = JSONObject().put("v", 1).put("id", id).put("n", b64(nonce)).put("e", b64(E2eCrypto.publicBytes(eph.public)))
            if (pairing) hello.put("pair", true)
            session.receive(byteArrayOf(DeskCrypto.HELLO) + hello.toString().toByteArray())
            val reply = fromPhone.removeAt(0)
            assertEquals(DeskCrypto.HELLO, reply[0])
            val o = JSONObject(String(reply, 1, reply.size - 1))
            if (o.has("err")) { refused = o.getString("err"); return }
            if (pairing) key = DeskCrypto.pairKey(deskPrivate!!, deskPublic!!, Base64.getDecoder().decode(o.getString("k")), secret!!)
            val keys = DeskCrypto.sessionKeys(key!!, nonce, Base64.getDecoder().decode(o.getString("n")), eph.private, Base64.getDecoder().decode(o.getString("e")))!!
            channel = DeskCrypto.Channel(sendKey = keys.first, receiveKey = keys.second)
        }

        fun say(message: JSONObject) = session.receive(byteArrayOf(DeskCrypto.SEALED) + channel!!.seal(message.toString()))

        fun hear(): JSONObject {
            val frame = fromPhone.removeAt(0)
            assertEquals(DeskCrypto.SEALED, frame[0])
            return JSONObject(channel!!.open(frame.copyOfRange(1, frame.size))!!)
        }

        fun ready(): JSONObject { say(JSONObject().put("t", "ready").put("name", "Matt's MacBook").put("proto", 1)); return hear() }

        fun ask(method: String, args: JSONObject = JSONObject()): JSONObject {
            val call = next++
            say(JSONObject().put("t", "req").put("id", call).put("m", method).put("a", args))
            val answer = hear()
            assertEquals("res", answer.getString("t"))
            assertEquals(call, answer.getInt("id"))
            return answer
        }
    }

    private fun b64(b: ByteArray) = Base64.getEncoder().encodeToString(b)

    private fun paired(): Pair<Host, Computer> {
        val host = Host(FakePhone())
        val key = ByteArray(32).also { random.nextBytes(it) }
        host.keys[DeskCrypto.id(key)] = key
        return host to Computer(host, key, DeskCrypto.id(key))
    }

    @Test
    fun aPairedComputerConnectsAsksAndIsAnswered() {
        val (host, mac) = paired()
        mac.hello()
        val ready = mac.ready()
        assertEquals("ready", ready.getString("t"))
        assertEquals("Fold", ready.getString("name"))
        assertEquals("both", ready.getString("mode"))
        assertTrue(mac.session.live)
        assertEquals("Matt's MacBook", mac.session.peerName)
        assertEquals(listOf("ready"), host.events)

        val list = mac.ask("conversations")
        assertTrue(list.getBoolean("ok"))
        assertEquals("See you at 7", list.getJSONArray("r").getJSONObject(0).getString("snippet"))
        assertEquals("Maya", list.getJSONArray("r").getJSONObject(0).getJSONArray("people").getJSONObject(0).getString("name"))

        val messages = mac.ask("messages", JSONObject().put("thread", 7).put("limit", 50))
        assertEquals(50, messages.getJSONArray("r").getJSONObject(0).getInt("limit"))

        mac.ask("markRead", JSONObject().put("thread", 7))
        assertEquals(listOf(7L), host.phone.read)

        // The phone says a conversation changed.
        mac.session.event("changed", JSONObject().put("thread", 7))
        val event = mac.hear()
        assertEquals("changed", event.getString("m"))
        assertEquals(7, event.getJSONObject("a").getInt("thread"))
    }

    @Test
    fun aTextAskedForTwiceIsSentOnce() {
        val (host, mac) = paired()
        mac.hello(); mac.ready()
        val args = JSONObject().put("key", "mac-1").put("addresses", JSONArray(listOf("+15550100"))).put("body", "On my way")
        val first = mac.ask("send", args)
        assertEquals(7, first.getJSONObject("r").getInt("thread"))
        // The answer was lost with the connection; the computer asks again, on a new one.
        val again = Computer(host, mac.pairKey, mac.id)
        again.hello(); again.ready()
        val second = again.ask("send", args)
        assertTrue(second.getJSONObject("r").getBoolean("again"))
        assertEquals(1, host.phone.sentTexts.size)
        assertEquals("On my way", host.phone.sentTexts[0].second)
        // Words with nothing in them, and a text with no name, are refused.
        assertFalse(mac.ask("send", JSONObject().put("key", "mac-2").put("addresses", JSONArray(listOf("+15550100"))).put("body", "  ")).getBoolean("ok"))
        assertFalse(mac.ask("send", JSONObject().put("key", "").put("addresses", JSONArray(listOf("+15550100"))).put("body", "x")).getBoolean("ok"))
        assertEquals(1, host.phone.sentTexts.size)
    }

    @Test
    fun aRecordedFramePlayedAgainEndsTheConnectionAndSendsNothing() {
        val (host, mac) = paired()
        mac.hello(); mac.ready()
        val frame = byteArrayOf(DeskCrypto.SEALED) + mac.channel!!.seal(
            JSONObject().put("t", "req").put("id", 9).put("m", "send").put("a", JSONObject().put("key", "mac-9").put("addresses", JSONArray(listOf("+15550100"))).put("body", "Once")).toString())
        mac.session.receive(frame)
        assertEquals(1, host.phone.sentTexts.size)
        mac.session.receive(frame)
        assertTrue(mac.session.closed)
        assertEquals(1, host.phone.sentTexts.size)
        // On a new connection the old frame is under the wrong key: refused there too.
        val later = Computer(host, mac.pairKey, mac.id)
        later.hello(); later.ready()
        later.session.receive(frame)
        assertTrue(later.session.closed)
        assertEquals(1, host.phone.sentTexts.size)
    }

    @Test
    fun aStrangerLearnsNothingAndNothingIsAnsweredBeforeTheComputerProvesItself() {
        val (host, mac) = paired()
        // A pairing the phone does not have.
        val stranger = Computer(host, ByteArray(32), "0011223344556677")
        stranger.hello()
        assertEquals("unknown", stranger.refused)
        assertTrue(stranger.session.closed)
        // The right id, the wrong key: its first sealed frame does not open.
        val wrong = Computer(host, ByteArray(32) { 9 }, mac.id)
        wrong.hello()
        wrong.session.receive(byteArrayOf(DeskCrypto.SEALED) + wrong.channel!!.seal(JSONObject().put("t", "ready").toString()))
        assertTrue(wrong.session.closed)
        assertTrue(wrong.fromPhone.isEmpty())
        assertFalse(host.events.contains("ready"))
        // The right key, but asking before `ready`.
        mac.hello()
        mac.say(JSONObject().put("t", "req").put("id", 1).put("m", "conversations"))
        assertTrue(mac.session.closed)
        assertTrue(mac.fromPhone.isEmpty())
        // A sealed frame before any hello, an empty frame, a frame of another kind.
        for (frame in listOf(byteArrayOf(DeskCrypto.SEALED, 1, 2, 3), byteArrayOf(), byteArrayOf(9, 9))) {
            val s = DeskSession(host, "local", { throw AssertionError("nothing should be said") })
            s.receive(frame)
            assertTrue(s.closed)
        }
    }

    @Test
    fun whatAComputerMayNotDoIsRefused() {
        val (_, mac) = paired()
        mac.hello(); mac.ready()
        // Deleting, blocking and a sticker were refused here until the computer's screens became the phone's own
        // (aComputerDoesWhatThePhonesScreensDo). What is the phone's alone still is: its key, its settings, its other
        // computers, its log, its own update.
        for (method in listOf("e2eReset", "prefs", "setPref", "deskList", "deskUnpair", "devLogRead", "updateInstall", "shareText", "e2eMine")) {
            val answer = mac.ask(method, JSONObject().put("thread", 7))
            assertFalse(method, answer.getBoolean("ok"))
        }
        assertFalse(mac.ask("threadFlag", JSONObject().put("name", "archived").put("thread", 7)).getBoolean("ok"))
        assertTrue(mac.ask("threadFlag", JSONObject().put("name", "pinned").put("thread", 7)).getBoolean("ok"))
    }

    /** Hands [bytes] over to [calls] as [id], [piece] bytes at a time, as a computer does. */
    private fun handOver(calls: DeskCalls, id: String, bytes: ByteArray, piece: Int = DeskCalls.PIECE) {
        var at = 0
        while (at < bytes.size) {
            val end = minOf(bytes.size, at + piece)
            val said = calls.call("put", JSONObject().put("upload", id).put("offset", at).put("total", bytes.size).put("data", Base64.getEncoder().encodeToString(bytes.copyOfRange(at, end)))) as Map<*, *>
            assertEquals(end, said["have"])
            at = end
        }
    }

    private fun refused(why: String, what: () -> Any?) {
        try { what(); throw AssertionError("was not refused: $why") } catch (e: IllegalArgumentException) { /* refused, with words */ assertTrue(why, (e.message ?: "").isNotEmpty()) }
    }

    /** What the phone's screens do, a computer may ask for too: each reaches the phone as it was asked. */
    @Test
    fun `the computer is told the phone's number, and its Me asks reach the phone's Dart side`() {
        // Matt, 2026-11-14: "on desktop the phone number reads as unknown and is not proxying the verification process".
        val phone = FakePhone()
        val calls = DeskCalls(phone)
        assertEquals("+14436537451", calls.call("ownNumber", JSONObject()))
        val said = calls.call("me", JSONObject().put("what", JSONObject().put("dir", "text").put("p", "phone").put("handle", "+14436537451")))
        assertEquals(mapOf("dir" to "text", "handle" to "+14436537451"), said)
        assertEquals(listOf(mapOf<String, Any?>("dir" to "text", "p" to "phone", "handle" to "+14436537451")), phone.asked)
        assertTrue("ownNumber" in DeskCalls.CAPS && "me" in DeskCalls.CAPS)
    }

    @Test
    fun aComputerDoesWhatThePhonesScreensDo() {
        val phone = FakePhone()
        val calls = DeskCalls(phone)
        // A group's name, given from the computer, is the phone's to keep.
        calls.call("threadName", JSONObject().put("thread", 7).put("name", "Family"))
        assertEquals(listOf("name 7 Family"), phone.did)
        phone.did.clear()
        assertTrue(DeskCalls.CAPS.contains("threadName"))
        calls.call("deleteMessage", JSONObject().put("kind", "sms").put("id", 41))
        assertEquals(2, calls.call("deleteThreads", JSONObject().put("threads", JSONArray(listOf(7, 8)))))
        assertEquals(1, calls.call("deleteThread", JSONObject().put("thread", 9)))
        calls.call("editMessage", JSONObject().put("kind", "mms").put("id", 5).put("body", "at 8"))
        assertEquals(7L, calls.call("resendMms", JSONObject().put("id", 12)))
        calls.call("resendMms", JSONObject().put("id", 13).put("body", "with other words"))
        calls.call("setBlocked", JSONObject().put("address", "+15550199").put("blocked", true))
        assertEquals("offered", (calls.call("e2eOffer", JSONObject().put("address", "+15550100")) as Map<*, *>)["state"])
        calls.call("e2eOff", JSONObject().put("address", "+15550100"))
        calls.call("e2eVerify", JSONObject().put("address", "+15550100").put("verified", false))
        calls.call("e2ePlainSeen", JSONObject().put("address", "+15550100"))
        assertEquals(listOf(
            "deleteMessage sms 41", "deleteThreads [7, 8]", "deleteThreads [9]", "editMessage mms 5 at 8", "resendMms 12 null",
            "resendMms 13 with other words", "setBlocked +15550199 true", "e2eOffer +15550100", "e2eOff +15550100",
            "e2eVerify +15550100 false", "e2ePlainSeen +15550100",
        ), phone.did)
        assertEquals(91, (calls.call("voiceLimit", JSONObject()) as Map<*, *>)["seconds"])
        assertEquals(1, (calls.call("blockedNumbers", JSONObject()) as List<*>).size)
        assertEquals(1, (calls.call("e2eList", JSONObject()) as List<*>).size)
        // The computer asks what this phone does, and offers only that.
        val caps = calls.call("caps", JSONObject()) as List<*>
        for (m in listOf("deleteMessage", "editMessage", "sendPictures", "sendVoice", "sendSticker", "put", "e2eOff")) assertTrue(m, caps.contains(m))
        // A message is a text or a picture message, nothing else; and what was never there is still refused.
        refused("a made-up kind") { calls.call("deleteMessage", JSONObject().put("kind", "../sms").put("id", 1)) }
        refused("the phone's own key") { calls.call("e2eReset", JSONObject()) }
        refused("the phone's settings") { calls.call("setPref", JSONObject().put("key", "theme").put("value", "dark")) }
    }

    /** A voice recording, pictures and a sticker handed over in pieces and sent once, whole. */
    @Test
    fun whatAComputerHandsOverArrivesWholeAndIsSentOnce() {
        val phone = FakePhone()
        val calls = DeskCalls(phone)
        val to = JSONArray(listOf("+15550100"))
        val sound = ByteArray(900_000) { (it * 7 % 251).toByte() }
        handOver(calls, "aaaaaaaa00000001", sound)
        val sent = calls.call("sendVoice", JSONObject().put("key", "v1").put("addresses", to).put("upload", "aaaaaaaa00000001").put("name", "voice-20261114-030000.m4a")) as Map<*, *>
        assertEquals(7L, sent["thread"])
        assertArrayEquals(sound, phone.files.single().bytes)
        assertEquals("audio/mp4", phone.files.single().type)
        // Asked again (its answer was lost): said where it went, and not sent twice, though what was handed over is gone.
        val again = calls.call("sendVoice", JSONObject().put("key", "v1").put("addresses", to).put("upload", "aaaaaaaa00000001").put("name", "voice.m4a")) as Map<*, *>
        assertEquals(true, again["again"])
        assertEquals(1, phone.files.size)
        // Two pictures and words; a file's name is never a path.
        val one = ByteArray(40_000) { 1 }
        val two = ByteArray(500_000) { 2 }
        handOver(calls, "bbbbbbbb00000001", one)
        handOver(calls, "bbbbbbbb00000002", two, piece = 100_000)
        calls.call("sendPictures", JSONObject().put("key", "p1").put("addresses", to).put("body", "look").put("files", JSONArray(listOf(
            JSONObject().put("upload", "bbbbbbbb00000001").put("name", "../../etc/IMG 0001.jpg").put("type", "image/jpeg"),
            JSONObject().put("upload", "bbbbbbbb00000002").put("name", "shot.png").put("type", "image/png"),
        ))))
        assertEquals("sendPictures [+15550100] look [IMG0001.jpg:image/jpeg, shot.png:image/png]", phone.did.last())
        assertArrayEquals(two, phone.files.last().bytes)
        // A sticker is one of the app's own, by its travelling name.
        handOver(calls, "cccccccc00000001", one)
        calls.call("sendSticker", JSONObject().put("key", "s1").put("addresses", to).put("name", "ghost-sticker-party-03.png").put("upload", "cccccccc00000001"))
        assertEquals("sendSticker [+15550100] ghost-sticker-party-03.png", phone.did.last())
        handOver(calls, "cccccccc00000002", one)
        refused("not a sticker's name") { calls.call("sendSticker", JSONObject().put("key", "s2").put("addresses", to).put("name", "holiday.png").put("upload", "cccccccc00000002")) }
        // What is not a picture is not sent as one, and nothing is sent of it.
        handOver(calls, "dddddddd00000001", one)
        val before = phone.did.size
        refused("a file that is no picture") {
            calls.call("sendPictures", JSONObject().put("key", "p2").put("addresses", to).put("files", JSONArray(listOf(JSONObject().put("upload", "dddddddd00000001").put("name", "notes.pdf").put("type", "application/pdf")))))
        }
        assertEquals(before, phone.did.size)
    }

    /** Pieces come in order and add up to what was said; what is let go, too large or never whole is refused. */
    @Test
    fun whatIsHandedOverBadlyIsRefused() {
        val phone = FakePhone()
        var clock = 1_000_000L
        val calls = DeskCalls(phone) { clock }
        val to = JSONArray(listOf("+15550100"))
        fun piece(id: String, offset: Int, total: Int, size: Int) = calls.call("put", JSONObject().put("upload", id).put("offset", offset).put("total", total).put("data", Base64.getEncoder().encodeToString(ByteArray(size) { 9 })))
        refused("a name that is no name") { piece("../up", 0, 10, 10) }
        refused("larger than may be handed over") { piece("eeeeeeee00000001", 0, DeskCalls.MOST_BYTES + 1, 10) }
        refused("not from its beginning") { piece("eeeeeeee00000002", 5, 10, 5) }
        piece("eeeeeeee00000003", 0, 300, 100)
        refused("out of its turn") { piece("eeeeeeee00000003", 200, 300, 100) }
        // The same piece again is answered and not kept twice.
        assertEquals(100, (piece("eeeeeeee00000003", 0, 300, 100) as Map<*, *>)["have"])
        refused("more than it said") { piece("eeeeeeee00000003", 100, 300, 250) }
        refused("its length changed") { piece("eeeeeeee00000003", 100, 400, 100) }
        // Not whole yet: it is not sent.
        refused("not whole") { calls.call("sendVoice", JSONObject().put("key", "v9").put("addresses", to).put("upload", "eeeeeeee00000003")) }
        // Let go by the computer, or left too long: it is gone.
        piece("eeeeeeee00000004", 0, 100, 100)
        calls.call("drop", JSONObject().put("upload", "eeeeeeee00000004"))
        refused("dropped") { calls.call("sendVoice", JSONObject().put("key", "v8").put("addresses", to).put("upload", "eeeeeeee00000004")) }
        piece("eeeeeeee00000005", 0, 100, 100)
        clock += DeskCalls.STALE + 1
        piece("eeeeeeee00000006", 0, 100, 100)
        refused("left too long") { calls.call("sendVoice", JSONObject().put("key", "v7").put("addresses", to).put("upload", "eeeeeeee00000005")) }
        // Only so many are held at once: the oldest gives way.
        for (i in 0 until DeskCalls.MOST_AT_ONCE + 2) piece("ffffffff%08d".format(i), 0, 100, 100)
        refused("the oldest gave way") { calls.call("sendVoice", JSONObject().put("key", "v6").put("addresses", to).put("upload", "ffffffff00000000")) }
        calls.call("sendVoice", JSONObject().put("key", "v5").put("addresses", to).put("upload", "ffffffff%08d".format(DeskCalls.MOST_AT_ONCE + 1)))
        assertEquals(1, phone.files.size)
    }

    @Test
    fun aGreatManyConversationsCrossALotAtATimeAndNeverInOneFrameTooLongToCarry() {
        val (host, mac) = paired()
        mac.hello(); mac.ready()
        host.phone.held = 3000
        host.phone.snippetLength = 400
        // The whole list at once is more than a frame carries: said in words, with the connection left standing.
        val whole = mac.ask("conversations")
        assertFalse(whole.getBoolean("ok"))
        assertEquals("Too much to send at once", whole.getString("e"))
        assertFalse(mac.session.closed)
        // A lot at a time: never more than the phone hands over at once, however many are asked for.
        var at: Int? = 0
        var got = 0
        var lots = 0
        while (at != null) {
            val page = mac.ask("conversationsPage", JSONObject().put("limit", 100000).put("offset", at)).getJSONObject("r")
            assertEquals(DeskCalls.LOT, page.getInt("asked"))
            got += page.getJSONArray("items").length()
            at = if (page.isNull("next")) null else page.getInt("next")
            lots++
        }
        assertEquals(3000, got)
        assertEquals(12, lots)
        assertEquals(40, mac.ask("conversationsPage", JSONObject().put("limit", 40).put("pinned", true)).getJSONObject("r").getJSONArray("items").length())
        assertEquals("See you at 7", mac.ask("conversation", JSONObject().put("thread", 7)).getJSONObject("r").getString("snippet"))
        assertTrue(mac.ask("conversation", JSONObject().put("thread", 1)).isNull("r"))
        assertEquals(0, mac.ask("archivedCount").getInt("r"))
    }

    // Matt, 2026-11-20: "some photos and videos are not coming through". A computer fetches every picture a
    // conversation shows together: the phone kept one, so each piece of two fetched together read its whole file
    // again, and the computer gave up waiting.
    @Test
    fun twoPicturesFetchedTogetherAreEachReadOnce() {
        val (host, mac) = paired()
        mac.hello(); mac.ready()
        val wholes = mapOf(5 to java.io.ByteArrayOutputStream(), 7 to java.io.ByteArrayOutputStream())
        val totals = mutableMapOf(5 to -1, 7 to -1)
        while (totals.any { (id, t) -> t < 0 || wholes[id]!!.size() < t }) {
            for (id in listOf(5, 7)) {
                val t = totals[id]!!
                if (t >= 0 && wholes[id]!!.size() >= t) continue
                val r = mac.ask("part", JSONObject().put("id", id).put("offset", wholes[id]!!.size())).getJSONObject("r")
                totals[id] = r.getInt("total")
                wholes[id]!!.write(Base64.getDecoder().decode(r.getString("data")))
            }
        }
        assertArrayEquals(host.phone.picture, wholes[5]!!.toByteArray())
        assertArrayEquals(host.phone.video, wholes[7]!!.toByteArray())
        assertEquals(2, host.phone.partReads)
    }

    @Test
    fun aPictureCrossesInPieces() {
        val (host, mac) = paired()
        mac.hello(); mac.ready()
        val whole = java.io.ByteArrayOutputStream()
        var total = -1
        while (total < 0 || whole.size() < total) {
            val r = mac.ask("part", JSONObject().put("id", 5).put("offset", whole.size())).getJSONObject("r")
            total = r.getInt("total")
            val piece = Base64.getDecoder().decode(r.getString("data"))
            assertTrue(piece.isNotEmpty() && piece.size <= DeskCalls.PIECE)
            whole.write(piece)
        }
        assertArrayEquals(host.phone.picture, whole.toByteArray())
        assertTrue(mac.ask("part", JSONObject().put("id", 6)).isNull("r"))
        assertEquals("AQID", mac.ask("photo", JSONObject().put("uri", "content://x")).getString("r"))
    }

    @Test
    fun pairingGivesBothTheSameKeyAndCodeAndNothingIsAnsweredUntilBothSayTheyMatch() {
        val host = Host(FakePhone())
        // The computer's QR code.
        val desk = E2eCrypto.newKeyPair()
        val deskPublic = E2eCrypto.publicBytes(desk.public)
        val secret = ByteArray(16).also { random.nextBytes(it) }
        val offer = DeskCrypto.parseOffer(DeskCrypto.offerText(DeskCrypto.Offer(deskPublic, secret, "Matt's MacBook", "both", "")))!!
        // The phone scans it: its own key pair, and the pairing's key.
        val phone = E2eCrypto.newKeyPair()
        val phonePublic = E2eCrypto.publicBytes(phone.public)
        val phoneKey = DeskCrypto.pairKey(phone.private, phonePublic, offer.key, offer.secret)!!
        host.pendings[DeskCrypto.pairingId(offer.secret)] = DeskPending(phoneKey, phonePublic)

        val mac = Computer(host, null, DeskCrypto.pairingId(secret), pairing = true, secret = secret, deskPrivate = desk.private, deskPublic = deskPublic)
        mac.hello()
        assertArrayEquals(phoneKey, mac.key)
        assertEquals(DeskCrypto.code(phoneKey), DeskCrypto.code(mac.key!!))
        mac.ready()
        assertTrue(mac.session.pairing)
        assertFalse(mac.ask("conversations").getBoolean("ok"))
        mac.say(JSONObject().put("t", "ev").put("m", "confirmed"))
        assertEquals(listOf("ready", "confirmed"), host.events)
        // The phone said so too: the connection goes on as an ordinary one.
        host.keys[DeskCrypto.id(phoneKey)] = phoneKey
        mac.session.paired(DeskCrypto.id(phoneKey))
        assertTrue(mac.ask("conversations").getBoolean("ok"))
        assertEquals(DeskCrypto.id(phoneKey), mac.session.id)

        // Someone in the middle who swaps the phone's public key for their own never saw the QR code: no key.
        val eve = E2eCrypto.newKeyPair()
        val theirs = DeskCrypto.pairKey(desk.private, deskPublic, E2eCrypto.publicBytes(eve.public), secret)!!
        assertFalse(theirs.contentEquals(phoneKey))
        assertNull(host.pairKey(DeskCrypto.id(theirs)))
    }
}
