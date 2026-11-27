package com.infamousvague.ghostmessaging

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/**
 * Google Messages' web connection on the phone itself (Matt, 2026-11-15: "Can you build the on phone google messages
 * connection too?"): the sidecar (sidecar/gmessages, AGPL-3.0, built for Android as libgmsidecar.so) run beside the
 * app, as the computers run it, so Uplink has Google Messages' conversations whole without its notifications: RCS
 * and texts, pictures, reactions, and their delivered and read marks.
 *
 * What it hears goes into the bridge's database (GmBridge.Db), as what the notifications say does, so everything
 * after (Store's list and conversations, Uplink's notifications, replies, a paired computer) works the same, with more
 * in it. Google Messages has one active web session at a time; the phone's takes it back when a computer's or
 * messages.google.com takes it (--takeover), and a paired computer uses the phone's (lib/desktop/gm_web.dart defers).
 *
 * It lives in the app's process, started by the notification listener (which Android keeps running) and the app;
 * the process is started again, more slowly each time, if it stops.
 */
object GmWeb {
    @Volatile private var process: Process? = null
    @Volatile private var input: BufferedWriter? = null
    private val waiting = ConcurrentHashMap<Long, CompletableFuture<JSONObject>>()
    private val next = AtomicLong(1)
    private var restarts = 0
    private lateinit var app: Context

    @Volatile var paired = false
    @Volatile var connected = false
    /** This session is not the active one: another (a computer, messages.google.com) took it for now. */
    @Volatile var inactive = false
    @Volatile var phone = ""
    /** While pairing: the address to show as a QR code on another screen. */
    @Volatile var qr: String? = null
    /** While pairing by Google account: the emoji to tap in Google Messages. */
    @Volatile var emoji: String? = null
    @Volatile var problem: String? = null

    /** The helper, packed as a native library so Android lets it run; [available] where this build carries it. */
    fun binary(context: Context) = File(context.applicationInfo.nativeLibraryDir, "libgmsidecar.so")
    fun available(context: Context) = binary(context).exists()
    private fun dir(context: Context) = File(context.filesDir, "gmessages").apply { mkdirs() }

    /** Whether a session was ever paired here (so the helper is worth starting as the app does). */
    fun hasSession(context: Context) = File(dir(context), "session.json").exists()

    /** Starts the helper where this build carries it; nothing where it is running already. */
    @Synchronized
    fun start(context: Context) {
        app = context.applicationContext
        if (process?.isAlive == true || !available(app)) return
        try {
            val p = ProcessBuilder(binary(app).absolutePath, "--dir", dir(app).absolutePath, "--takeover").start()
            process = p
            input = p.outputStream.bufferedWriter()
            Thread({ read(p) }, "gmweb-out").apply { isDaemon = true }.start()
            Thread({ try { p.errorStream.bufferedReader().forEachLine { } } catch (_: Exception) {} }, "gmweb-err").apply { isDaemon = true }.start()
        } catch (e: Exception) {
            problem = "The Google Messages helper could not start (${e.message})"
        }
    }

    /** Reads the helper's output, a line of JSON at a time, until it stops. */
    private fun read(p: Process) {
        try {
            p.inputStream.bufferedReader().forEachLine { line -> try { heard(JSONObject(line)) } catch (_: Exception) {} }
        } catch (_: Exception) {}
        // It stopped: what waited is told, and it is started again, more slowly each time (a minute at most).
        if (process == p) {
            process = null
            connected = false
            for (w in waiting.values) w.completeExceptionally(IllegalStateException("The Google Messages helper stopped"))
            waiting.clear()
            val wait = (1L shl restarts.coerceAtMost(6)).coerceAtMost(60) * 1000
            restarts++
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ start(app) }, wait)
        }
    }

    /** Asks the helper [op]; its answer, or the error it gave. Blocks: never on the main thread. */
    fun ask(op: String, args: Map<String, Any?> = emptyMap(), seconds: Long = 60): JSONObject {
        val w = input ?: throw IllegalStateException("The Google Messages helper is not running")
        val id = next.getAndIncrement()
        val done = CompletableFuture<JSONObject>()
        waiting[id] = done
        val line = JSONObject(args).put("id", id).put("op", op).toString()
        synchronized(w) { w.write(line); w.newLine(); w.flush() }
        try {
            return done.get(seconds, TimeUnit.SECONDS)
        } finally {
            waiting.remove(id)
        }
    }

    /** One line from the helper: the answer to something asked (it has the asking's `id`), or an event. */
    private fun heard(o: JSONObject) {
        if (o.has("id")) {
            val w = waiting.remove(o.getLong("id")) ?: return
            if (o.has("error")) w.completeExceptionally(IllegalStateException(o.getString("error"))) else w.complete(o.optJSONObject("ok") ?: JSONObject())
            return
        }
        when (o.optString("ev")) {
            "ready" -> { restarts = 0; Thread { status(); if (paired) sync() }.start() }
            "connected" -> { connected = true; problem = null; Thread { status(); sync() }.start() }
            "qr" -> qr = o.optString("url")
            "emoji" -> emoji = o.optString("emoji")
            "paired" -> { qr = null; emoji = null; paired = true; problem = null; Thread { status(); sync(); watchUntilConnected() }.start() }
            "pair_failed" -> { qr = null; emoji = null; problem = o.optString("why") }
            "unpaired" -> { paired = false; connected = false; problem = o.optString("why"); Bus.changed(-1) }
            "inactive" -> inactive = true
            "active" -> { inactive = false; Thread { sync() }.start() }
            "phone" -> problem = if (o.optBoolean("responding")) null else "Google Messages on this phone isn't answering"
            "conversation" -> o.optJSONObject("data")?.let { Thread { keepConversation(it); Bus.changed(-1) }.start() }
            "message" -> o.optJSONObject("data")?.let { m -> Thread { keepMessage(m, notify = true) }.start() }
        }
    }

    /** Paired but not yet said to be connected: asked again every 15 seconds for two minutes, and read in when it is. */
    private fun watchUntilConnected() {
        for (i in 0 until 8) {
            if (connected || !paired) return
            Thread.sleep(15_000)
            status()
            if (connected) { sync(); return }
        }
    }

    private fun status() {
        try {
            val s = ask("status", seconds = 10)
            paired = s.optBoolean("paired")
            connected = s.optBoolean("connected")
            phone = s.optString("phone")
        } catch (_: Exception) {}
    }

    /** Conversations, and the newest messages of the newest of them, read again. */
    private fun sync() {
        if (!paired) return
        try {
            val list = ask("conversations", mapOf("count" to 100)).optJSONArray("items") ?: return
            for (i in 0 until list.length()) keepConversation(list.getJSONObject(i))
            for (i in 0 until minOf(list.length(), 25)) {
                val conv = list.getJSONObject(i).getString("id")
                val ms = ask("messages", mapOf("conv" to conv, "count" to 30)).optJSONArray("items") ?: continue
                for (j in 0 until ms.length()) keepMessage(ms.getJSONObject(j), notify = false)
            }
            Bus.changed(-1)
        } catch (_: Exception) {}
    }

    private val people = ConcurrentHashMap<String, JSONObject>()

    private fun keepConversation(c: JSONObject) {
        val conv = c.getString("id")
        val ps = c.optJSONArray("people") ?: JSONArray()
        val addresses = ArrayList<String>()
        // You are among a conversation's people, not always marked as you (Matt, 2026-11-15: "i see two chats for
        // message DMs one in the nromal layout that just shows the person I'm texting then one that is the person and
        // me in a group"): known also as the one the conversation sends from, and by this phone's own numbers.
        val outgoing = c.optString("outgoing")
        val store = Store(app)
        val own = try { store.ownNumbers() } catch (_: Exception) { emptySet() }
        for (i in 0 until ps.length()) {
            val p = ps.getJSONObject(i)
            people["$conv/${p.optString("id")}"] = p
            val number = p.optString("number")
            val me = p.optBoolean("me") || (outgoing.isNotEmpty() && p.optString("id") == outgoing) || (number.isNotBlank() && store.isOwn(number, own))
            if (!me && number.isNotBlank() && addresses.none { Store.sameNumber(it, number) }) addresses += number
        }
        val group = c.optBoolean("group")
        val title = c.optString("name").ifBlank { null }
        val read = GmBridge.Read(conv, title, group, addresses, emptyList())
        val thread = GmBridge.threadFor(app, read)
        GmBridge.Db.get(app).keepWebConversation(conv, thread, title, group, addresses)
        threads[conv] = thread
        if (group && c.optBoolean("rcs")) rcsGroups += conv else rcsGroups -= conv
        unreadIn[conv] = c.optBoolean("unread")
    }

    private val threads = ConcurrentHashMap<String, Long>()

    /** The conversations that are RCS groups: only those have a name everyone in them sees ([renameGroup]). */
    private val rcsGroups: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /**
     * Gives [thread]'s RCS group [name] for everyone in it, as Google Messages' own Group details does (Matt, 2026-11-18:
     * "there is no rcs group chat name that is set for other users"). A picture-message (MMS) group has no name to share:
     * it stays this phone's own. False where nothing was renamed (not connected, not an RCS group, or it would not).
     */
    fun renameGroup(thread: Long, name: String): Boolean {
        if (!connected || name.isBlank()) return false
        val convs = threads.filterValues { it == thread }.keys.filter { it in rcsGroups }
        var any = false
        for (conv in convs) {
            try { ask("rename", mapOf("conv" to conv, "name" to name.trim())); any = true } catch (e: Exception) { DevLog.add(app, "gmweb", "rename: ${e.message}") }
        }
        return any
    }

    /** Whether [thread] is an RCS group Google Messages knows, whose name can be everyone's. */
    fun isRcsGroup(thread: Long): Boolean = threads.any { (conv, t) -> t == thread && conv in rcsGroups }
    private val unreadIn = ConcurrentHashMap<String, Boolean>()

    private fun keepMessage(m: JSONObject, notify: Boolean) {
        // Google Messages' own lines about the conversation are not texts: its tombstones ("Texting with Katelynn
        // (SMS/MMS)", a switch to or from RCS, someone joining) and a message with nothing in it at all (Matt,
        // 2026-11-17: a thread full of "Texting with Jade (SMS/MMS)" with a time and an empty line each).
        val status = m.optString("status")
        if (status.contains("tombstone", ignoreCase = true)) return
        // A picture message still being brought down is not one yet (Matt, 2026-11-18: "when i get messages in an RCS
        // group chat it still shows me the "attachement" and "Sms message from jade""): Google Messages tells of it
        // with a stand-in, then again under the same id once it is had. Kept, and told of, only then, as
        // mautrix-gmessages does.
        if (GmBridge.downloading(status)) return
        // One that will not come down by itself (auto-download off, or it failed): said so, in place of its stand-in.
        val text = GmBridge.notDownloaded(status) ?: m.optString("text")
        if (text.isBlank() && (m.optJSONArray("media")?.length() ?: 0) == 0) return
        val conv = m.getString("conv")
        val thread = threads[conv] ?: run {
            // A message in a conversation not read yet: read it first.
            try { keepConversation(ask("conversations", mapOf("count" to 100)).optJSONArray("items")?.let { all -> (0 until all.length()).map { all.getJSONObject(it) }.firstOrNull { it.optString("id") == conv } } ?: return) } catch (_: Exception) { return }
            threads[conv] ?: return
        }
        val out = m.optBoolean("me")
        val from = people["$conv/${m.optString("from")}"]
        val media = m.optJSONArray("media")
        val parts = JSONArray()
        val db = GmBridge.Db.get(app)
        if (media != null) for (i in 0 until media.length()) {
            val p = media.getJSONObject(i)
            // Your own picture is first told of before it is uploaded, with no id yet, and is told of again with one;
            // but not always, and the message then stood as nothing but its "Delivered" (Matt, 2026-11-19: "when I'm
            // sending pictures and voice messages sometimes I don't see my outbound messages just the delivered tag").
            // Yours with no id is the file sent from here, under a stand-in named by the message, until an id comes.
            val stand = "sent:${m.optString("id")}:$i"
            if (p.optString("id").isBlank()) {
                if (!out) continue
                val id = partId(stand)
                db.keepPart(id, stand, "", p.optString("mime"), p.optString("name").ifBlank { null })
                claimSent(conv, id, p.optString("mime").ifBlank { null })
                if (!hasFile(id)) continue
                parts.put(JSONObject().put("id", id).put("type", p.optString("mime")).put("name", p.optString("name")))
                continue
            }
            val id = partId(p.getString("id"))
            // Its id come at last: the file kept under the stand-in is its picture.
            if (out) adopt(partId(stand), id, p.optString("mime").ifBlank { null })
            db.keepPart(id, p.getString("id"), p.optString("key"), p.optString("mime"), p.optString("name").ifBlank { null },
                p.optString("thumb").ifBlank { null }, p.optString("thumbKey").ifBlank { null })
            // Your own, just sent from here: its preview is the file sent, whatever Google Messages names it.
            if (out) claimSent(conv, id, p.optString("mime").ifBlank { null })
            parts.put(JSONObject().put("id", id).put("type", p.optString("mime")).put("name", p.optString("name")))
        }
        val reactions = m.optJSONArray("reactions")?.let { r -> (0 until r.length()).mapNotNull { r.getJSONObject(it).optString("emoji").ifBlank { null } }.joinToString(" ") }?.ifBlank { null }
        val time = m.optLong("time")
        // Read where Google Messages has the conversation read and this is not newer than what was read.
        val read = out || unreadIn[conv] == false
        val fresh = db.keepWebMessage(conv, thread, m.getString("id"), text, time, from?.optString("name")?.ifBlank { null }, from?.optString("number")?.ifBlank { null }, out, m.optString("status"), if (parts.length() > 0) parts.toString() else null, reactions, read)
        Bus.changed(thread)
        // A new message of theirs, just now: Uplink's notification (Google Messages' own may be off altogether).
        if (notify && fresh && !out && System.currentTimeMillis() - time < 5 * 60_000) {
            unreadIn[conv] = true
            try { Notifier.incoming(app, thread) } catch (e: Exception) { DevLog.add(app, "gmweb", "notification: ${e.message}") }
        }
    }

    /** A picture's number for the screens: from its id, the same every time, never one of Android's (which are small). */
    fun partId(media: String): Long = 1_000_000_000_000L + (media.hashCode().toLong() and 0x7fffffffL)

    /** Whether a picture's number is one of these, not one of Android's. */
    fun isPart(id: Long) = id >= 1_000_000_000_000L

    /** A picture's bytes, brought down once and kept in the app's cache. */
    fun part(context: Context, id: Long): ByteArray? = file(context, id)?.readBytes()

    /**
     * A picture's or a video's file, brought down once into the app's cache (Matt, 2026-11-15: "videos are saying
     * "cannot play on this phone"": the player read Android's MMS store, where these are not). Blocks: never on the
     * main thread. Named with its kind's ending, which a player may go by.
     */
    fun file(context: Context, id: Long): File? {
        val (media, key, mime) = GmBridge.Db.get(context).part(id) ?: return null
        val ending = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"
        val f = File(File(context.cacheDir, "gmmedia").apply { mkdirs() }, "$id.$ending")
        if (!f.exists() || f.length() == 0L) {
            // Kept from sending under another ending (the kind Google Messages says may differ from the one sent).
            File(context.cacheDir, "gmmedia").listFiles { x -> x.nameWithoutExtension == "$id" && x.length() > 0 }?.firstOrNull()?.let { return it }
            try { ask("media", mapOf("media" to media, "key" to key, "path" to f.absolutePath), seconds = 180) } catch (e: Exception) {
                DevLog.add(context, "gmweb", "picture $id not brought down: ${e.message}")
                // Its small copy, where Google Messages gave one: a picture you sent is sometimes had only so.
                val thumb = GmBridge.Db.get(context).thumbOf(id) ?: return null
                try { ask("media", mapOf("media" to thumb.first, "key" to thumb.second, "path" to f.absolutePath), seconds = 60) } catch (e2: Exception) {
                    DevLog.add(context, "gmweb", "picture $id's thumbnail not brought down either: ${e2.message}")
                    return null
                }
            }
        }
        return if (f.exists() && f.length() > 0) f else null
    }

    /** Whether [conv] is one this connection knows: what is sent to it goes this way. */
    fun knows(conv: String) = connected && threads.containsKey(conv)

    /** Files being sent from here to each conversation, oldest first, until Google Messages tells of their message. */
    private val sending = ConcurrentHashMap<String, MutableList<Pair<File, Long>>>()

    /**
     * Gives the picture [id] of your message in [conv] the file sent from here, where none is kept for it yet (Matt,
     * 2026-11-16: "the preview of the image I sent never loads"). Google Messages can tell of the message before the
     * send has answered, and may name its picture otherwise than the upload was named; the file is then not where
     * [file] looks, and bringing your own picture down from Google does not always work.
     */
    private fun claimSent(conv: String, id: Long, mime: String?) {
        val dir = File(app.cacheDir, "gmmedia")
        if (dir.listFiles { x -> x.nameWithoutExtension == "$id" && x.length() > 0 }?.isNotEmpty() == true) return
        val queue = sending[conv] ?: return
        val now = System.currentTimeMillis()
        val next = synchronized(queue) {
            queue.removeAll { now - it.second > 5 * 60_000 }
            if (queue.isEmpty()) null else queue.removeAt(0)
        } ?: return
        try {
            val ending = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: next.first.extension.ifBlank { "bin" }
            dir.mkdirs()
            next.first.copyTo(File(dir, "$id.$ending"), overwrite = true)
        } catch (e: Exception) { DevLog.add(app, "gmweb", "sent copy: ${e.message}") }
    }

    /** Whether a picture's file is kept in the cache already. */
    private fun hasFile(id: Long) = File(app.cacheDir, "gmmedia").listFiles { x -> x.nameWithoutExtension == "$id" && x.length() > 0 }?.isNotEmpty() == true

    /** The file kept under the stand-in [from], kept for the picture [to] too, where [to] has none yet. */
    private fun adopt(from: Long, to: Long, mime: String?) {
        if (hasFile(to)) return
        val had = File(app.cacheDir, "gmmedia").listFiles { x -> x.nameWithoutExtension == "$from" && x.length() > 0 }?.firstOrNull() ?: return
        try {
            val ending = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: had.extension.ifBlank { "bin" }
            had.copyTo(File(had.parentFile, "$to.$ending"), overwrite = true)
        } catch (e: Exception) { DevLog.add(app, "gmweb", "sent copy: ${e.message}") }
    }

    /** A sent file, kept as the picture Google Messages names [media]: where [file] would bring it down to. */
    private fun keepSent(media: String, mime: String?, from: File) {
        try {
            val ending = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"
            val to = File(File(app.cacheDir, "gmmedia").apply { mkdirs() }, "${partId(media)}.$ending")
            if (!to.exists()) from.copyTo(to)
        } catch (e: Exception) { DevLog.add(app, "gmweb", "sent copy: ${e.message}") }
    }

    /** Sends words, and files (each its path, its kind and its name), to [conv]. */
    fun send(conv: String, text: String, files: List<Triple<String, String?, String?>> = emptyList()): Boolean = try {
        if (files.isEmpty()) ask("send", mapOf("conv" to conv, "text" to text))
        else {
            for ((i, f) in files.withIndex()) {
                val (path, mime, name) = f
                // Waiting for its message, which may come before the send answers (claimSent).
                val queue = sending.getOrPut(conv) { mutableListOf() }
                val entry = File(path) to System.currentTimeMillis()
                synchronized(queue) { queue.add(entry) }
                val r = ask("send_media", mapOf("conv" to conv, "path" to path, "mime" to mime, "name" to name, "text" to if (i == files.lastIndex) text else ""), seconds = 180)
                // Your own picture or video, as its preview: this phone's copy kept where the download would have put it
                // (Matt, 2026-11-15: "Outbound picture and video messages are not loading the preview").
                r.optString("media").ifBlank { null }?.let { keepSent(it, r.optString("mime").ifBlank { mime }, File(path)) }
            }
        }
        true
    } catch (e: Exception) {
        DevLog.add(app, "gmweb", "send: ${e.message}")
        false
    }

    /** Archives [thread]'s conversations in Google Messages, or brings them back, as messages.google.com's Archive does. */
    fun archiveThread(thread: Long, archived: Boolean) {
        if (!connected) return
        val convs = threads.filterValues { it == thread }.keys.ifEmpty { GmBridge.Db.get(app).webConvsOf(thread).toSet() }
        for (conv in convs) {
            try { ask("archive_conv", mapOf("conv" to conv, "remove" to !archived)) } catch (e: Exception) { DevLog.add(app, "gmweb", "archive: ${e.message}") }
        }
    }

    /** Deletes one message in Google Messages by its own id. False where not connected or it would not. */
    fun deleteMessage(gmId: String): Boolean {
        if (!connected) return false
        return try { ask("delete_msg", mapOf("msg" to gmId)); true } catch (e: Exception) { DevLog.add(app, "gmweb", "delete message: ${e.message}"); false }
    }

    /**
     * Deletes the conversations of [thread] in Google Messages, as messages.google.com's Delete does: from Android's
     * store (Google Messages is the default SMS app) and every device. False where not connected or none is known.
     */
    fun deleteThread(thread: Long): Boolean {
        if (!connected) return false
        val convs = threads.filterValues { it == thread }.keys.ifEmpty { GmBridge.Db.get(app).webConvsOf(thread).toSet() }
        var all = convs.isNotEmpty()
        for (conv in convs) {
            try { ask("delete_conv", mapOf("conv" to conv)); threads.remove(conv) } catch (e: Exception) { all = false; DevLog.add(app, "gmweb", "delete: ${e.message}") }
        }
        return all
    }

    /** Marks [conv] read in Google Messages, as far as its newest message (which sends a read receipt where on). */
    fun read(conv: String) {
        if (!connected) {
            DevLog.add(app, "gmweb", "read: not connected to Google Messages, so $conv is read in Uplink alone")
            return
        }
        // A conversation known only from notifications has no id of the connection's: nothing to tell it.
        val newest = GmBridge.Db.get(app).newestWebId(conv) ?: return
        unreadIn[conv] = false
        Thread { try { ask("read", mapOf("conv" to conv, "msg" to newest)) } catch (e: Exception) { DevLog.add(app, "gmweb", "read $conv: ${e.message}") } }.start()
    }

    /** Begins pairing by QR code ([qr] follows); false, with [problem] saying why, where the helper would not. */
    fun pair(): Boolean = try { problem = null; ask("pair"); true } catch (e: Exception) { problem = e.message; false }

    /** Pairs by Google account from a signed-in browser's cookies (lib/gm/google_signin.dart); an emoji follows. */
    fun pairGoogle(cookies: Map<String, String>): String? = try {
        problem = null; emoji = null
        ask("pair_google", mapOf("cookies" to JSONObject(cookies as Map<*, *>)))
        null
    } catch (e: Exception) { e.message }

    /** Ends the pairing with Google Messages' web; false, with [problem] saying why, where the helper would not. */
    fun unpair(): Boolean = try { ask("unpair"); paired = false; connected = false; true } catch (e: Exception) { problem = e.message; false }

    /** How it stands, for Settings. */
    fun state(context: Context): Map<String, Any?> = mapOf(
        "available" to available(context), "running" to (process?.isAlive == true), "paired" to paired, "connected" to connected,
        "inactive" to inactive, "phone" to phone, "qr" to qr, "emoji" to emoji, "problem" to problem,
    )
}
