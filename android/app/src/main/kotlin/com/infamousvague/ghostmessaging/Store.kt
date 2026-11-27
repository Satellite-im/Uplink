package com.infamousvague.ghostmessaging

import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.PhoneNumberUtils
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager

/**
 * Android's own SMS/MMS database (the Telephony provider), read and written as the default SMS app. Every message
 * lives there, not in this app: another SMS app picked later, or this one reinstalled, sees the same conversations.
 *
 * What goes to Flutter is plain maps and lists (the MethodChannel's StandardMessageCodec).
 */
class Store(private val context: Context) {
    private val resolver = context.contentResolver

    // --- people ------------------------------------------------------------------------------------------------------

    /**
     * Who a number is, kept until Android says the contacts have changed ([contactsChanged]): the list of
     * conversations is read again on every text that comes or goes, and asking Android for each person each time
     * was most of what that cost.
     */
    private val nameCache = java.util.concurrent.ConcurrentHashMap<String, Map<String, Any?>>()

    /** The phone's contacts changed: who a number is is read afresh the next time it is asked. */
    fun contactsChanged() { known = null; nameCache.clear() }

    /** One of the phone's contacts' numbers, as the contacts keep it. */
    private class Known(val number: String, val name: String?, val photo: String?)

    /** The contacts' numbers by [ContactKey], read once and kept until Android says the contacts changed. */
    @Volatile private var known: Map<String, List<Known>>? = null

    /**
     * Every contact's numbers in one question to Android (Matt, 2026-11-13: "Users with a ton of messages stored on
     * their phone are taking forever to load"). Looking each conversation's number up was a question apiece: with
     * three thousand conversations, most of the twenty seconds the list took to appear.
     */
    private fun knownNumbers(): Map<String, List<Known>> {
        known?.let { return it }
        if (!hasContacts()) return emptyMap()
        val out = HashMap<String, ArrayList<Known>>()
        try {
            val phone = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            resolver.query(phone, arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME, ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val number = c.getString(0) ?: continue
                    val key = ContactKey.of(number) ?: continue
                    out.getOrPut(key) { ArrayList() } += Known(ContactKey.main(number), c.getString(1), c.getString(2))
                }
            }
        } catch (_: Exception) {
            return emptyMap()   // not kept: asked again the next time a name is wanted
        }
        known = out
        return out
    }

    /** The contact for [address]: their name and photo's URI where the phone has them. */
    fun contact(address: String): Map<String, Any?> {
        // A member of a group shown under a stand-in (Groups.shownAddress): "Someone", never anyone's contact.
        Groups.memberName(address)?.let { return mapOf("address" to address, "name" to it, "photo" to null) }
        nameCache[address]?.let { return it }
        // A sender's name or an email address is nobody's phone number; a number is found among the contacts by its
        // last digits and then compared whole, as Android compares two numbers.
        val found = ContactKey.of(address)?.let { key -> knownNumbers()[key]?.firstOrNull { sameNumber(it.number, address) } }
        val out = mapOf("address" to address, "name" to found?.name, "photo" to found?.photo)
        nameCache[address] = out
        return out
    }

    fun clearContactCache() { known = null; nameCache.clear() }

    private fun hasContacts() = context.checkSelfPermission(android.Manifest.permission.READ_CONTACTS) == android.content.pm.PackageManager.PERMISSION_GRANTED

    /** Contacts with a phone number matching [query] (name or digits), for a new message's To. */
    fun searchContacts(query: String, limit: Int = 40): List<Map<String, Any?>> {
        if (!hasContacts()) return emptyList()
        val out = ArrayList<Map<String, Any?>>()
        val seen = HashSet<String>()
        val uri = if (query.isBlank()) ContactsContract.CommonDataKinds.Phone.CONTENT_URI
        else Uri.withAppendedPath(ContactsContract.CommonDataKinds.Phone.CONTENT_FILTER_URI, Uri.encode(query))
        try {
            resolver.query(
                uri,
                arrayOf(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                    ContactsContract.CommonDataKinds.Phone.NUMBER,
                    ContactsContract.CommonDataKinds.Phone.PHOTO_THUMBNAIL_URI,
                    ContactsContract.CommonDataKinds.Phone.TYPE,
                    ContactsContract.CommonDataKinds.Phone.LABEL,
                ),
                null, null,
                if (query.isBlank()) "${ContactsContract.CommonDataKinds.Phone.TIMES_CONTACTED} DESC, ${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} ASC" else null,
            )?.use { c ->
                while (c.moveToNext() && out.size < limit) {
                    val number = c.getString(1) ?: continue
                    val key = number.filter { it.isDigit() }.takeLast(10)
                    if (!seen.add(c.getString(0) + key)) continue
                    val label = ContactsContract.CommonDataKinds.Phone.getTypeLabel(context.resources, c.getInt(3), c.getString(4)).toString()
                    out += mapOf("name" to c.getString(0), "address" to number, "photo" to c.getString(2), "label" to label)
                }
            }
        } catch (_: Exception) {}
        return out
    }

    /** A contact's picture, by the address the contacts gave for it; null where it cannot be read. */
    fun photo(uri: String): ByteArray? = try {
        resolver.openInputStream(Uri.parse(uri))?.use { it.readBytes() }
    } catch (_: Exception) { null }

    // --- this phone's own numbers ------------------------------------------------------------------------------------

    /** This phone's own numbers, to leave out of a group MMS's people. Empty when Android will not say. */
    fun ownNumbers(): Set<String> {
        val out = HashSet<String>()
        try {
            val sm = context.getSystemService(SubscriptionManager::class.java)
            val subs = sm.activeSubscriptionInfoList ?: emptyList()
            for (s in subs) {
                val n = if (android.os.Build.VERSION.SDK_INT >= 33) sm.getPhoneNumber(s.subscriptionId) else @Suppress("DEPRECATION") s.number
                if (!n.isNullOrBlank()) out += n
            }
        } catch (_: Exception) {}
        try {
            @Suppress("DEPRECATION", "MissingPermission")
            val n = context.getSystemService(TelephonyManager::class.java).line1Number
            if (!n.isNullOrBlank()) out += n
        } catch (_: Exception) {}
        val saved = context.getSharedPreferences("ghost", Context.MODE_PRIVATE).getString("own_number", null)
        if (!saved.isNullOrBlank()) out += saved
        return out
    }

    fun isOwn(address: String, own: Set<String>): Boolean = own.any { sameNumber(it, address) }

    // --- conversations -----------------------------------------------------------------------------------------------

    private val canonical = java.util.concurrent.ConcurrentHashMap<Long, String>()
    @Volatile private var canonicalRead = false

    /** Every address Android keeps for conversations, in one question: each conversation's own was one apiece. */
    private fun readCanonical() {
        if (canonicalRead) return
        try {
            resolver.query(Uri.parse("content://mms-sms/canonical-addresses"), null, null, null, null)?.use { c ->
                val iId = c.getColumnIndex("_id"); val iAddress = c.getColumnIndex("address")
                if (iId >= 0 && iAddress >= 0) while (c.moveToNext()) c.getString(iAddress)?.let { canonical[c.getLong(iId)] = it }
            }
        } catch (_: Exception) {}   // a store that will not list them is asked for each, below
        canonicalRead = true
    }

    /** The number behind one of Android's recipient ids (a conversation lists its people by these), remembered. */
    private fun canonicalAddress(id: Long): String? {
        canonical[id]?.let { return it }
        // One that is not in the list read at the start: a conversation begun since, or a store that lists none.
        resolver.query(Uri.parse("content://mms-sms/canonical-address/$id"), null, null, null, null)?.use {
            if (it.moveToFirst()) { val a = it.getString(0); canonical[id] = a; return a }
        }
        return null
    }

    /** A conversation's `recipient_ids` ("12 40 7") as numbers; an id Android no longer knows is left out. */
    private fun recipientsOf(ids: String?): List<String> =
        (ids ?: "").split(' ').mapNotNull { it.toLongOrNull() }.mapNotNull { canonicalAddress(it) }

    /** Every conversation, the newest first. */
    @Suppress("UNCHECKED_CAST")
    fun conversations(): List<Map<String, Any?>> = conversationsPage()["items"] as List<Map<String, Any?>>

    /** One conversation as the list has it, or null where it is gone. */
    @Suppress("UNCHECKED_CAST")
    fun conversation(thread: Long): Map<String, Any?>? = (conversationsPage(only = setOf(thread))["items"] as List<Map<String, Any?>>).firstOrNull()

    /**
     * Conversations, the newest first, a lot at a time (Matt, 2026-11-13: "see if we can load by most recent first
     * so that things are faster"): [limit] of them from the [offset]th row of Android's list, or all of them where
     * [limit] is 0. Answers with `items`, with `next` (the row the next lot starts at, or null at the end), and with
     * `floor`: where more follow, the date of the last row taken in order, so everything newer than it is here.
     *
     * [pinnedToo] adds what heads the screen however old it is, for the first lot: the pinned conversations, and the
     * newest few unread ones ([UNREAD_TOO]; the list shows unread ones first, and they used to arrive lot by lot under
     * the eyes). [only]: these conversations alone (the archived ones' page, or one by its id).
     *
     * Every lot is whole in itself (Matt, 2026-11-26: "they don't always show the last message"): each row has the
     * newest words of its conversation whether Android's database or Google Messages' bridge holds them, and a
     * conversation the bridge has newer words for is on the lot its newest message's date falls in. Only the first lot
     * used to be brought up to date by the bridge, and a later lot's row for the same conversation, as Android has it
     * (its last SMS, however old), was then laid over it.
     */
    fun conversationsPage(limit: Int = 0, offset: Int = 0, pinnedToo: Boolean = false, only: Set<Long>? = null): Map<String, Any?> {
        val out = ArrayList<Map<String, Any?>>()
        var next: Int? = null
        if (only != null && only.isEmpty()) return mapOf("items" to out, "next" to null)
        val uri = Uri.parse("content://mms-sms/conversations?simple=true")
        val archived = archivedThreads()
        val pinned = threadFlags("pinned")
        val muted = threadFlags("muted")
        val drafts = drafts()
        val hidden = hiddenThreads()
        val standIns = rcsStandIns()
        // Android's blocked list, read once: asking it about each conversation's number is a call to Android apiece.
        val blocked = blockedKeys()
        // The newest of each RCS group's stand-in threads, left out of the list, for its group's row.
        val carried = Newest()
        // Google Messages' conversations as the bridge has them (GmBridge), read once for the lot.
        val bridged = try { GmBridge.Db.get(context).conversations().distinctBy { it.thread } } catch (_: Exception) { emptyList() }
        // The dates this lot lies between: the row before its first ([upper]; null for the first lot) and the last row
        // it took in order ([floor]; null where it took the last there is).
        var upper: Long? = null
        var floor: Long? = null
        readCanonical()
        // No projection: OEM providers (Samsung's among them) differ in the columns they keep, and naming one they
        // lack fails the whole query. Each column is read if it is there.
        try {
            // The groups of friends this phone is in, by their conversations (Groups.kt): who is in one, and what
            // it is called, are read from its record, not from who Android holds the conversation to be with.
            val groups = Groups.byThread(context)
            fun row(c: Cursor, k: Cols): Map<String, Any?>? {
                val id = c.getLong(k.id)
                // A store that takes no notice of which were asked for is held to them here.
                if (only != null && id !in only) return null
                val count = if (k.count >= 0) c.getInt(k.count) else 1
                // A count of nothing is believed only where the conversation holds nothing: some phones' stores
                // do not keep the count, and every conversation would be left out.
                if (count == 0 && !hasMessages(id)) return null
                val group = groups[id]
                val recipients = if (group != null) Groups.people(context, group) else recipientsOf(if (k.recipients >= 0) c.getString(k.recipients) else null)
                val date = k.dateOf(c)
                // Deleted beside Google Messages, and nothing newer since (hideThread).
                if (hidden[id]?.let { date <= it } == true) return null
                // An RCS group's stand-in, already found to be a group the bridge shows (withBridge).
                val standIn = group == null && recipients.isNotEmpty() && recipients.all(::isRcsStandIn)
                val summary = E2e.preview(context, if (group != null) null else recipients.singleOrNull(), if (k.snippet >= 0) c.getString(k.snippet) ?: "" else "").let { if (BackgroundWire.valueIn(it) != null) "Chat background" else it }
                // Its messages are its group's (messages()), so its newest is the group's newest too, where it is
                // newer: the list said the group's older words while the group showed these (Matt, 2026-11-26: "The
                // most recent message doesnt match what's actually sent as the last message on chats").
                if (standIn && id in standIns) {
                    carried.carry(standIns.getValue(id), date, summary.ifBlank { latestSnippet(id, "$date:$count") }, k.unread(c))
                    return null
                }
                val people = recipients.map { contact(it) }
                return mapOf(
                    "id" to id,
                    "date" to date,
                    "count" to count,
                    "people" to people,
                    // What someone not in the contacts last sent, for sorting the conversation by (lib/plugins):
                    // the newest message may be your own reply, which says nothing of what they are (Matt,
                    // 2026-11-14: "Health insurance sales people are not getting caught by the sales filter").
                    "heard" to if (group == null && people.size == 1 && people[0]["name"] == null) latestHeard(id, "$date:$count") else null,
                    // A picture message's summary in Android's list is its subject, often empty: its words, or
                    // what it is, instead.
                    "snippet" to summary.ifBlank { latestSnippet(id, "$date:$count") },
                    "encrypted" to (group != null || (recipients.size == 1 && E2e.isOn(context, recipients[0]))),
                    "group" to group?.optString("id"),
                    "unread" to k.unread(c),
                    "error" to (k.error >= 0 && c.getInt(k.error) != 0),
                    "attachment" to (k.attachment >= 0 && c.getInt(k.attachment) != 0),
                    "archived" to archived.contains(id),
                    "pinned" to pinned.contains(id),
                    "muted" to muted.contains(id),
                    "name" to (group?.optString("name")?.takeIf { it.isNotBlank() } ?: threadName(id) ?: if (standIn) rcsGroupName(recipients) else null),
                    "draft" to drafts[id.toString()],
                    "blocked" to (group == null && recipients.size == 1 && E2e.norm(recipients[0]) in blocked),
                )
            }
            resolver.query(uri, null, only?.let { "_id IN (${it.joinToString(",")})" }, null, "date DESC")?.use { c ->
                val k = Cols(c)
                if (offset <= 0 || c.moveToPosition(offset - 1)) {
                    if (offset > 0) upper = k.dateOf(c)
                    var last: Long? = null
                    while (c.moveToNext()) {
                        if (limit > 0 && out.size >= limit) { next = c.position; break }
                        last = k.dateOf(c)
                        row(c, k)?.let { out += it }
                    }
                    if (next != null) floor = last
                }
                // What heads the screen from further down: the cursor stands on the first row not taken. The pinned
                // ones wherever they are, and the newest unread ones the list brings up (not a muted or an archived
                // one, which it does not).
                if (pinnedToo && next != null) {
                    val have = out.mapTo(HashSet()) { it["id"] as Long }
                    var pinnedLeft = pinned.count { it !in have }
                    var unreadLeft = UNREAD_TOO
                    do {
                        if (pinnedLeft <= 0 && unreadLeft <= 0) break
                        val id = c.getLong(k.id)
                        if (id in have) continue
                        if (id in pinned) {
                            pinnedLeft--
                            row(c, k)?.let { out += it }
                        } else if (unreadLeft > 0 && k.unread(c) && id !in muted && id !in archived) {
                            row(c, k)?.let { out += it; unreadLeft-- }
                        }
                    } while (c.moveToNext())
                }
            }
            // Android's own row of each conversation the bridge has newer words for, which belongs on this lot by them
            // though Android lists it further down (its last SMS is old): brought up, to be given those words below.
            if (only == null) {
                val have = out.mapTo(HashSet()) { it["id"] as Long }
                val wanted = bridgedOnLot(bridged.map { it.thread to it.time }, have, floor, upper).filter { it > 0 }
                if (wanted.isNotEmpty()) resolver.query(uri, null, "_id IN (${wanted.joinToString(",")})", null, null)?.use { c ->
                    val k = Cols(c)
                    while (c.moveToNext()) row(c, k)?.let { out += it }
                }
            }
        } catch (e: Exception) {
            // A phone whose store will not answer this way is read the plain way, from the texts themselves. If that
            // fails too the screen is told, and says so: an empty list would look like every message had gone.
            android.util.Log.e("GhostMessaging", "conversations", e)
            out.clear()
            next = null
            floor = null
            upper = null
            if (offset <= 0) out += conversationsFromTexts(archived, pinned, muted, drafts).filter { only == null || (it["id"] as Long) in only }
        }
        withBridge(out, bridged, only, lower = floor, upper = upper)
        // After the bridge's own rows are in: an RCS group's row is one of them, where Android has none for it.
        carried.into(out)
        withReadHere(out)
        return mapOf("items" to out, "next" to next, "floor" to floor)
    }

    /** The columns of Android's list of conversations a row is read from, each where [c]'s store has it. */
    private class Cols(c: Cursor) {
        val id = c.getColumnIndex("_id"); val date = c.getColumnIndex("date"); val count = c.getColumnIndex("message_count")
        val recipients = c.getColumnIndex("recipient_ids"); val snippet = c.getColumnIndex("snippet"); val read = c.getColumnIndex("read")
        val error = c.getColumnIndex("error"); val attachment = c.getColumnIndex("has_attachment")
        fun dateOf(c: Cursor): Long = if (date >= 0) c.getLong(date) else 0L
        fun unread(c: Cursor): Boolean = read >= 0 && c.getInt(read) == 0
    }

    /**
     * Google Messages' conversations as the bridge has them ([bridged]; GmBridge) brought into a lot of the list: one
     * whose thread is in [out] brings its newer words and its unread; one Android's database does not have (an RCS
     * chat) is added on the lot its date falls on (from [lower], below [upper]; null is no bound).
     */
    private fun withBridge(out: ArrayList<Map<String, Any?>>, bridged: List<GmBridge.Conv>, only: Set<Long>?, lower: Long?, upper: Long?) {
        if (bridged.isEmpty()) return
        val at = HashMap<Long, Int>()
        out.forEachIndexed { i, row -> at[row["id"] as Long] = i }
        val archived = archivedThreads(); val pinned = threadFlags("pinned"); val muted = threadFlags("muted")
        var added = false
        val hidden = hiddenThreads()
        val drafts = drafts()
        for (b in bridged) {
            if (only != null && b.thread !in only) continue
            if (hidden[b.thread]?.let { b.time <= it } == true) continue
            val i = at[b.thread]
            // Its words, or what it carries where it has none or only Google Messages' stand-in ("Photo", "Attachment").
            val said = GmBridge.summary(b.text, partTypes(b.media))
            if (i != null) {
                val row = out[i]
                if (b.time > (row["date"] as Long)) {
                    out[i] = row + mapOf("date" to b.time, "snippet" to said, "unread" to ((row["unread"] as Boolean) || b.unread > 0), "bridged" to true)
                    added = true
                } else if (b.unread > 0 && row["unread"] != true) {
                    out[i] = row + mapOf("unread" to true)
                }
                continue
            }
            if (!onLot(b.time, lower, upper)) continue
            val people = if (b.addresses.isNotEmpty()) b.addresses.map { contact(it) } else listOf(mapOf("address" to (b.title ?: ""), "name" to b.title))
            out += mapOf(
                "id" to b.thread, "date" to b.time, "count" to 1, "people" to people, "heard" to null, "snippet" to said,
                "encrypted" to false, "group" to null, "unread" to (b.unread > 0), "error" to false, "attachment" to false,
                "archived" to archived.contains(b.thread), "pinned" to pinned.contains(b.thread), "muted" to muted.contains(b.thread),
                "name" to (threadName(b.thread) ?: if (b.group) b.title else null), "draft" to drafts[b.thread.toString()], "blocked" to false, "bridged" to true,
            )
            added = true
        }
        // An RCS group as Android's database has it: Google Messages keeps it there under one made-up address
        // (…@rcs.google.com), so it would be listed a second time, as a chat with a long code for its number (Matt,
        // 2026-11-16: "some RCS chats are being duplicated with a number that has a huge string when I'm in a group
        // chat"). The address names the group's RCS id, not its people, so it is matched to the bridge's group by its
        // newest message, and the match is kept: from then on it is never listed.
        val groups = bridged.filter { it.group }
        if (groups.isNotEmpty()) {
            val learned = HashMap<Long, Long>()
            val iter = out.listIterator()
            val unreadIn = HashSet<Long>()
            // What each one left out said last, for its group's row where it is newer.
            val newest = Newest()
            while (iter.hasNext()) {
                val row = iter.next()
                @Suppress("UNCHECKED_CAST") val people = row["people"] as List<Map<String, Any?>>
                if (people.isEmpty() || !people.all { (it["address"] as? String)?.let(::isRcsStandIn) == true }) continue
                val words = (row["snippet"] as? String)?.trim().orEmpty()
                val date = row["date"] as Long
                // By its people first: the stand-in's newest message names them, as the group the on-phone connection
                // keeps does (Matt, 2026-11-18: a picture in a new group came "separately" under the long code, with no
                // words to match it by). Else by its newest message: the same words within ten minutes, or no words
                // (a picture) within two.
                val members = standInMembers(row["id"] as Long)
                val match = groups.firstOrNull { g -> g.thread != row["id"] && members.isNotEmpty() && g.addresses.size == members.size && g.addresses.all { a -> members.any { m -> sameNumber(a, m) } } }
                    ?: groups.firstOrNull { g -> g.thread != row["id"] && g.text.trim() == words && words.isNotEmpty() && kotlin.math.abs(g.time - date) <= 10 * 60_000L }
                    ?: groups.filter { g -> g.thread != row["id"] && words.isEmpty() && g.text.isBlank() && kotlin.math.abs(g.time - date) <= 2 * 60_000L }.singleOrNull()
                    ?: continue
                learned[row["id"] as Long] = match.thread
                if (row["unread"] == true) unreadIn += match.thread
                newest.carry(match.thread, date, words, row["unread"] == true)
                iter.remove()
            }
            if (learned.isNotEmpty()) {
                keepRcsStandIns(learned)
                out.forEachIndexed { i, row -> if (row["id"] in unreadIn && row["unread"] != true) out[i] = row + mapOf("unread" to true) }
                if (newest.into(out)) added = true
            }
        }
        if (added) out.sortByDescending { it["date"] as Long }
    }

    /**
     * Who is in an RCS group's stand-in thread, as its newest picture or group message names them: everyone it went to
     * and came from but this phone (its own number, Android's type 151) and the stand-in address itself.
     */
    private fun standInMembers(thread: Long): Set<String> = try {
        val id = resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id"), "thread_id = ?", arrayOf("$thread"), "date DESC LIMIT 1")?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        if (id == null) emptySet() else buildSet {
            resolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address", "type"), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    val a = c.getString(0) ?: continue
                    if (c.getInt(1) == 151 || isRcsStandIn(a) || a.contains("insert-address-token")) continue
                    if (none { sameNumber(it, a) }) add(a)
                }
            }
        }
    } catch (_: Exception) { emptySet() }

    /** The stand-in threads found to be [thread]'s RCS group: their messages are the group's ([messages]). */
    private fun standInsOf(thread: Long): List<Long> = rcsStandIns().filterValues { it == thread }.keys.toList()

    /** Google Messages' address for an RCS group (not a business's, which is …@bot.rcs.google.com). */
    private fun isRcsStandIn(address: String): Boolean =
        address.endsWith("@rcs.google.com", ignoreCase = true) && !address.endsWith("@bot.rcs.google.com", ignoreCase = true)

    /** RCS groups' stand-in threads found to be the bridge's groups: stand-in thread to the group's thread. */
    private fun rcsStandIns(): Map<Long, Long> = try {
        val o = org.json.JSONObject(prefs.getString("rcs_standins", "{}")!!)
        o.keys().asSequence().associate { it.toLong() to o.getLong(it) }
    } catch (_: Exception) { emptyMap() }

    private fun keepRcsStandIns(found: Map<Long, Long>) {
        val o = try { org.json.JSONObject(prefs.getString("rcs_standins", "{}")!!) } catch (_: Exception) { org.json.JSONObject() }
        for ((k, v) in found) o.put("$k", v)
        prefs.edit().putString("rcs_standins", o.toString()).apply()
    }

    /**
     * What a stand-in is called where no group matches it: the group's name where its address carries one (base32 of
     * "name␟owner␟id"), else "Group chat"; never the code.
     */
    private fun rcsGroupName(addresses: List<String>): String {
        val code = addresses.first().substringBefore('@').uppercase().trimEnd('=')
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        val bytes = java.io.ByteArrayOutputStream()
        var buffer = 0; var bits = 0
        for (ch in code) {
            val v = alphabet.indexOf(ch); if (v < 0) return "Group chat"
            buffer = (buffer shl 5) or v; bits += 5
            if (bits >= 8) { bits -= 8; bytes.write((buffer shr bits) and 0xff) }
        }
        val name = try { bytes.toString("UTF-8").split('\u001f').firstOrNull()?.replace('+', ' ')?.trim() } catch (_: Exception) { null }
        return name?.takeIf { it.isNotEmpty() && it.none { c -> c.isISOControl() } } ?: "Group chat"
    }

    /** The numbers on Android's blocked list, as conversations are told apart by them ([E2e.norm]). */
    private fun blockedKeys(): Set<String> {
        val out = HashSet<String>()
        try {
            resolver.query(android.provider.BlockedNumberContract.BlockedNumbers.CONTENT_URI, arrayOf(android.provider.BlockedNumberContract.BlockedNumbers.COLUMN_ORIGINAL_NUMBER), null, null, null)?.use {
                while (it.moveToNext()) it.getString(0)?.let { n -> out += E2e.norm(n) }
            }
        } catch (_: Exception) {}
        return out
    }

    /** Whether [thread] holds a text or a picture message at all. */
    private fun hasMessages(thread: Long): Boolean {
        for (uri in listOf(Telephony.Sms.CONTENT_URI, Telephony.Mms.CONTENT_URI)) {
            val any = try {
                resolver.query(uri, arrayOf("_id"), "thread_id = ?", arrayOf(thread.toString()), "_id LIMIT 1")?.use { it.count > 0 } ?: false
            } catch (_: Exception) { false }
            if (any) return true
        }
        return false
    }

    /**
     * The conversations as the texts themselves give them, for a store that will not list its conversations: the
     * newest text of each, by the conversation it says it is in. One person each (a text has one address); group
     * picture messages are found by [threadPeople] where the store answers that.
     */
    private fun conversationsFromTexts(archived: Set<Long>, pinned: Set<Long>, muted: Set<Long>, drafts: Map<String, String>): List<Map<String, Any?>> {
        val seen = LinkedHashMap<Long, Map<String, Any?>>()
        resolver.query(Telephony.Sms.CONTENT_URI, arrayOf("thread_id", "address", "body", "date", "read", "type"), null, null, "date DESC")?.use { c ->
            while (c.moveToNext()) {
                val id = c.getLong(0)
                if (seen.containsKey(id)) continue
                val address = c.getString(1) ?: ""
                val people = try { threadPeople(id).ifEmpty { listOf(contact(address)) } } catch (_: Exception) { listOf(contact(address)) }
                val one = people.singleOrNull()?.get("address") as String?
                seen[id] = mapOf(
                    "id" to id,
                    "date" to c.getLong(3),
                    "count" to 1,
                    "people" to people,
                    "snippet" to E2e.preview(context, one, c.getString(2) ?: "").let { if (BackgroundWire.valueIn(it) != null) "Chat background" else it },
                    "encrypted" to (one != null && E2e.isOn(context, one)),
                    "unread" to (c.getInt(4) == 0 && c.getInt(5) == Telephony.Sms.MESSAGE_TYPE_INBOX),
                    "error" to (c.getInt(5) == Telephony.Sms.MESSAGE_TYPE_FAILED),
                    "attachment" to false,
                    "archived" to archived.contains(id),
                    "pinned" to pinned.contains(id),
                    "muted" to muted.contains(id),
                    "name" to threadName(id),
                    "draft" to drafts[id.toString()],
                    "blocked" to (one != null && isBlocked(one)),
                )
            }
        }
        return seen.values.toList()
    }

    /** What a conversation with no summary of its own shows, kept while the conversation stands as it did. */
    private val snippets = java.util.concurrent.ConcurrentHashMap<Long, Pair<String, String>>()

    /**
     * The summary of [thread] where Android's own is empty, as its newest message gives it. [stamp] is the
     * conversation's date and count: while they are what they were, the answer is what it was, where it used to be
     * read again (several questions to Android) for every such conversation each time the list was.
     */
    private val heards = java.util.concurrent.ConcurrentHashMap<Long, Pair<String, String>>()

    /** The newest words that came in in [thread] (a text, or a picture message's words), kept until it changes. */
    private fun latestHeard(thread: Long, stamp: String): String {
        heards[thread]?.let { if (it.first == stamp) return it.second }
        val words = try { readLatestHeard(thread) } catch (_: Exception) { "" }
        heards[thread] = stamp to words
        return words
    }

    /** The words of the newest message received in [thread], a text or a picture message's, opened where sealed. */
    private fun readLatestHeard(thread: Long): String {
        val which = arrayOf(thread.toString())
        var mms: Long? = null
        var mmsDate = 0L
        resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id", "date"), "thread_id = ? AND msg_box = 1", which, "date DESC LIMIT 1")?.use {
            if (it.moveToFirst()) { mms = it.getLong(0); mmsDate = it.getLong(1) * 1000 }
        }
        resolver.query(Telephony.Sms.CONTENT_URI, arrayOf("date", "address", "body"), "thread_id = ? AND type = 1", which, "date DESC LIMIT 1")?.use {
            if (it.moveToFirst() && (mms == null || it.getLong(0) >= mmsDate)) return E2e.read(context, it.getString(1) ?: "", it.getString(2) ?: "").first
        }
        val id = mms ?: return ""
        return (mmsPartsOf(listOf(id))[id] ?: emptyList()).filter { it["type"] == "text/plain" }.joinToString("\n") { it["text"] as String? ?: "" }
    }

    /** [readLatestSnippet], read once for a conversation and a [stamp]: read again only when the stamp has changed. */
    private fun latestSnippet(thread: Long, stamp: String): String {
        snippets[thread]?.let { if (it.first == stamp) return it.second }
        val words = try { readLatestSnippet(thread) } catch (_: Exception) { "" }
        snippets[thread] = stamp to words
        return words
    }

    private fun readLatestSnippet(thread: Long): String {
        val which = arrayOf(thread.toString())
        // The newest picture message, unless a text is newer still.
        var mms: Long? = null
        var mmsDate = 0L
        resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id", "date"), "thread_id = ?", which, "date DESC LIMIT 1")?.use {
            if (it.moveToFirst()) { mms = it.getLong(0); mmsDate = it.getLong(1) * 1000 }
        }
        resolver.query(Telephony.Sms.CONTENT_URI, arrayOf("date", "address", "body"), "thread_id = ?", which, "date DESC LIMIT 1")?.use {
            if (it.moveToFirst() && (mms == null || it.getLong(0) >= mmsDate)) {
                val opened = E2e.read(context, it.getString(1) ?: "", it.getString(2) ?: "").first
                return if (BackgroundWire.valueIn(opened) != null) "Chat background" else opened
            }
        }
        val id = mms ?: return ""
        val parts = mmsPartsOf(listOf(id))[id] ?: emptyList()
        val written = parts.filter { it["type"] == "text/plain" }.joinToString("\n") { it["text"] as String? ?: "" }
        if (BackgroundWire.valueIn(written) != null) return "Chat background"
        if (written.isNotBlank()) return written
        val rest = parts.filter { it["type"] != "text/plain" && it["type"] != "application/smil" }
        return when {
            rest.any { (it["type"] as String).startsWith("image/") && Stickers.isSticker(it["name"] as String?) } -> "Sticker"
            rest.any { (it["type"] as String).startsWith("image/") } -> "Picture"
            rest.any { (it["type"] as String).startsWith("audio/") } -> "Voice message"
            rest.any { (it["type"] as String).startsWith("video/") } -> "Video"
            rest.isNotEmpty() -> "Attachment"
            else -> ""
        }
    }

    /** Who [thread] is with, each as [contact] gives them; empty for a conversation nothing knows. */
    fun threadPeople(thread: Long): List<Map<String, Any?>> {
        // A group of friends' conversation is with its members, as its record has them (Groups.kt).
        Groups.ofThread(context, thread)?.let { return Groups.people(context, it).map { a -> contact(a) } }
        resolver.query(Uri.parse("content://mms-sms/conversations?simple=true"), arrayOf("_id", "recipient_ids"), "_id = ?", arrayOf(thread.toString()), null)?.use {
            if (it.moveToFirst()) return recipientsOf(it.getString(1)).map { a -> contact(a) }
        }
        // A conversation only the bridge has (an RCS chat Google Messages showed): its people as the bridge read them.
        try {
            GmBridge.Db.get(context).conversations().firstOrNull { c -> c.thread == thread }?.let { c ->
                return if (c.addresses.isNotEmpty()) c.addresses.map { a -> contact(a) } else listOf(mapOf("address" to (c.title ?: ""), "name" to c.title))
            }
        } catch (_: Exception) {}
        return emptyList()
    }

    /**
     * The conversation with exactly these people, made in Android's database where there is none yet.
     *
     * Beside Google Messages (not the default SMS app) Android finds a conversation that exists but lets no app but the
     * default make one, and asking threw "Unable to find or allocate a thread ID" (Matt, 2026-11-26: "I can't open a new
     * text message conversation"). There the conversation is the bridge's where it has one with these people, else a
     * stand-in of its own ([GmBridge.pendingThread], below zero), empty, which the app leaves for the real one once the
     * first text has made it (lib/ui/thread.dart).
     */
    fun threadFor(addresses: List<String>): Long = try {
        Telephony.Threads.getOrCreateThreadId(context, addresses.toSet())
    } catch (e: Exception) {
        if (GmBridge.isDefault(context)) throw e
        GmBridge.threadOfPeople(context, addresses) ?: GmBridge.pendingThread(addresses)
    }

    // --- messages ----------------------------------------------------------------------------------------------------

    /** The newest [limit] messages of [thread], SMS and MMS together, the newest first. */
    fun messages(thread: Long, limit: Int = 300): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        // An RCS group's own, and what Google Messages keeps of it under its stand-in address (…@rcs.google.com): one
        // conversation (Matt, 2026-11-18: "These two came through separately but should habe come through inside the
        // group").
        val threads = (listOf(thread) + standInsOf(thread)).joinToString(",")
        val receipts = receipts()
        // The texts that came or went by the app's routes, between friends, not the phone network (Friends.kt).
        val net = Friends.netIds(context)
        resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf("_id", "address", "body", "date", "type", "status", "read", "date_sent"),
            "thread_id IN ($threads)", null, "date DESC LIMIT $limit",
        )?.use { c ->
            while (c.moveToNext()) {
                val type = c.getInt(4)
                // A sealed text is opened here, as it is shown; a text carrying a key is a notice, not words.
                val (opened, sealed) = E2e.read(context, c.getString(1) ?: "", c.getString(2) ?: "")
                // A text that carried a chat background (BackgroundWire) is a notice too.
                val background = BackgroundWire.valueIn(opened)
                val words = if (background != null) "" else opened
                out += mapOf(
                    "id" to c.getLong(0),
                    "kind" to "sms",
                    "address" to (c.getString(1) ?: ""),
                    "body" to words,
                    "encrypted" to (sealed == "encrypted"),
                    "notice" to (if (sealed == "key" || sealed == "undecryptable") sealed else if (background != null) "background" else null),
                    "date" to c.getLong(3),
                    "outgoing" to (type != Telephony.Sms.MESSAGE_TYPE_INBOX),
                    "state" to smsState(type, c.getInt(5)),
                    "read" to (c.getInt(6) != 0),
                    "via" to (if (c.getLong(0) in net) "net" else null),
                )
            }
        }
        resolver.query(
            Telephony.Mms.CONTENT_URI,
            arrayOf("_id", "date", "msg_box", "read", "m_type", "sub", "m_id", "st"),
            "thread_id IN ($threads)", null, "date DESC LIMIT $limit",
        )?.use { c ->
            // In a group of friends (Groups.kt): what came or went by the app's routes, and the lines about the group.
            val groupNet = Groups.netIds(context)
            val groupNotes = Groups.noteIds(context)
            // Every message's parts in one question to Android, where it was one question a message.
            val rows = ArrayList<List<Any?>>()
            while (c.moveToNext()) rows += listOf(c.getLong(0), c.getLong(1), c.getInt(2), c.getInt(3), c.getInt(4), c.getString(5), c.getString(6), c.getInt(7))
            val partsOf = mmsPartsOf(rows.map { it[0] as Long })
            for (row in rows) {
                val id = row[0] as Long
                val box = row[2] as Int
                val mType = row[4] as Int
                val outgoing = box != Telephony.Mms.MESSAGE_BOX_INBOX
                val parts = partsOf[id] ?: emptyList()
                val written = parts.filter { it["type"] == "text/plain" }.joinToString("\n") { it["text"] as String? ?: "" }
                // A picture or group message that carried a chat background: a notice, its picture not a message's.
                val background = BackgroundWire.valueIn(written)
                val text = if (background != null) "" else written
                out += mapOf(
                    "id" to id,
                    "kind" to "mms",
                    "address" to (if (outgoing) "" else mmsSender(id)),
                    "body" to text,
                    "notice" to (if (id in groupNotes) "group" else if (background != null) "background" else null),
                    "via" to (if (id in groupNet) "net" else null),
                    "subject" to row[5] as String?,
                    "date" to (row[1] as Long) * 1000,
                    "outgoing" to outgoing,
                    "state" to when {
                        // A picture message announced and not here: being brought down now, or it could not be
                        // (insertMmsNotice). The conversation draws it with a way to try again.
                        mType == Pdu.NOTIFICATION_IND -> if ((row[7] as Int) == NOTICE_DOWNLOADING) "downloading" else "pending_download"
                        box == Telephony.Mms.MESSAGE_BOX_OUTBOX -> "sending"
                        box == Telephony.Mms.MESSAGE_BOX_FAILED -> "failed"
                        outgoing -> receipts[row[6] as String? ?: ""] ?: "sent"
                        else -> "received"
                    },
                    "read" to ((row[3] as Int) != 0),
                    "parts" to (if (background != null) emptyList() else parts.filter { it["type"] != "text/plain" && it["type"] != "application/smil" }),
                    // Why it did not go, where it did not (MmsWhy): said under it.
                    "why" to (if (box == Telephony.Mms.MESSAGE_BOX_FAILED) MmsDiag.why(context, id) else null),
                )
            }
        }
        withBridgedMessages(thread, out, limit)
        hiddenMessages().takeIf { it.isNotEmpty() }?.let { gone -> out.removeAll { "${it["kind"]}:${it["id"]}" in gone } }
        out.sortByDescending { it["date"] as Long }
        val originals = originals()
        val marked = if (originals.isEmpty()) out else out.map { m ->
            val original = originals["${m["kind"]}:${m["id"]}"]
            if (original == null) m else m + mapOf("edited" to true, "original" to original)
        }
        return if (marked.size > limit) marked.subList(0, limit) else marked
    }

    /** The texts that arrived since [since], opened where they were sealed: their words and when, newest first. */
    fun recentInbox(since: Long, limit: Int = 20): List<Pair<String, Long>> {
        val out = ArrayList<Pair<String, Long>>()
        resolver.query(Telephony.Sms.Inbox.CONTENT_URI, arrayOf("address", "body", "date"), "date >= ?", arrayOf(since.toString()), "date DESC LIMIT $limit")?.use { c ->
            while (c.moveToNext()) out += E2e.read(context, c.getString(0) ?: "", c.getString(1) ?: "").first to c.getLong(2)
        }
        return out
    }

    private fun smsState(type: Int, status: Int): String = when (type) {
        Telephony.Sms.MESSAGE_TYPE_INBOX -> "received"
        Telephony.Sms.MESSAGE_TYPE_OUTBOX, Telephony.Sms.MESSAGE_TYPE_QUEUED -> "sending"
        Telephony.Sms.MESSAGE_TYPE_FAILED -> "failed"
        else -> if (status == Telephony.Sms.STATUS_COMPLETE) "delivered" else "sent"
    }

    /** The parts of each of [ids], in the order each message keeps them: asked for a hundred messages at a time. */
    private fun mmsPartsOf(ids: List<Long>): Map<Long, List<Map<String, Any?>>> {
        val out = HashMap<Long, ArrayList<Map<String, Any?>>>()
        for (chunk in ids.chunked(100)) {
            resolver.query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "text", "name", "cl", "_data", "mid"), "mid IN (${chunk.joinToString(",")})", null, "mid ASC, seq ASC")?.use { c ->
                while (c.moveToNext()) {
                    val partId = c.getLong(0)
                    val type = (c.getString(1) ?: "").lowercase()
                    var text: String? = null
                    if (type == "text/plain") {
                        text = c.getString(2)
                        if (text == null && c.getString(5) != null) text = readPart(partId)?.toString(Charsets.UTF_8)
                    }
                    out.getOrPut(c.getLong(6)) { ArrayList() } += mapOf("id" to partId, "type" to type, "text" to text, "name" to (c.getString(3) ?: c.getString(4)))
                }
            }
        }
        return out
    }

    /** The parts of the picture message [id] with what is in them, as they would be sent: for sending it again. */
    fun mmsParts(id: Long): List<Pdu.Part> {
        val out = ArrayList<Pdu.Part>()
        resolver.query(Uri.parse("content://mms/part"), arrayOf("_id", "ct", "text", "name", "cl", "cid", "_data"), "mid = ?", arrayOf(id.toString()), "seq ASC")?.use { c ->
            while (c.moveToNext()) {
                val type = (c.getString(1) ?: "").lowercase()
                if (type.isEmpty()) continue
                val data = if (type == "text/plain" && c.getString(2) != null) c.getString(2).toByteArray(Charsets.UTF_8) else (readPart(c.getLong(0)) ?: continue)
                val place = c.getString(4) ?: c.getString(3)
                out += Pdu.Part(type, data, name = c.getString(3) ?: place, contentLocation = place, contentId = c.getString(5)?.trim('<', '>'))
            }
        }
        return out
    }

    /** The bytes of a picture message's part, from Android's database or, for one of GmWeb's, from GmWeb. */
    fun readPart(partId: Long): ByteArray? = if (GmWeb.isPart(partId)) GmWeb.part(context, partId) else try {
        resolver.openInputStream(Uri.parse("content://mms/part/$partId"))?.use { it.readBytes() }
    } catch (_: Exception) { null }

    /** Who sent each picture message, remembered: a stored message's sender does not change. */
    private val senders = java.util.concurrent.ConcurrentHashMap<Long, String>()

    /** Who sent the picture message [id]: its address of type 137 (the PDU's From); "" where there is none. */
    private fun mmsSender(id: Long): String {
        senders[id]?.let { return it }
        var from = ""
        resolver.query(Uri.parse("content://mms/$id/addr"), arrayOf("address", "type"), "type = 137", null, null)?.use {
            if (it.moveToFirst()) from = it.getString(0) ?: ""
        }
        if (from.isNotEmpty()) senders[id] = from
        return from
    }

    // --- writing -----------------------------------------------------------------------------------------------------

    /** A text that arrived, written unread and unseen; Android finds its conversation. Its row, or null. */
    fun insertSmsInbox(address: String, body: String, date: Long, dateSent: Long, subId: Int): Uri? {
        val v = ContentValues().apply {
            put("address", address)
            put("body", body)
            put("date", date)
            put("date_sent", dateSent)
            put("read", 0)
            put("seen", 0)
            put("type", Telephony.Sms.MESSAGE_TYPE_INBOX)
            put("sub_id", subId)
        }
        return resolver.insert(Telephony.Sms.Inbox.CONTENT_URI, v)
    }

    /** A text about to be sent, written as waiting to go; [setSmsType] and [setSmsStatus] say what became of it. */
    fun insertSmsOutbox(thread: Long, address: String, body: String, subId: Int): Uri? {
        val v = ContentValues().apply {
            put("thread_id", thread)
            put("address", address)
            put("body", body)
            put("date", System.currentTimeMillis())
            put("read", 1)
            put("seen", 1)
            put("type", Telephony.Sms.MESSAGE_TYPE_OUTBOX)
            put("status", Telephony.Sms.STATUS_PENDING)
            put("sub_id", subId)
        }
        return resolver.insert(Telephony.Sms.CONTENT_URI, v)
    }

    fun setSmsType(uri: Uri, type: Int, errorCode: Int = 0) {
        resolver.update(uri, ContentValues().apply { put("type", type); put("error_code", errorCode) }, null, null)
    }

    fun setSmsStatus(uri: Uri, status: Int) {
        resolver.update(uri, ContentValues().apply { put("status", status) }, null, null)
    }

    /** The conversation a message's row is in, or -1 where the row is gone. */
    fun threadOfSms(uri: Uri): Long {
        resolver.query(uri, arrayOf("thread_id"), null, null, null)?.use { if (it.moveToFirst()) return it.getLong(0) }
        return -1
    }

    fun threadOfMms(uri: Uri): Long {
        resolver.query(uri, arrayOf("thread_id"), null, null, null)?.use { if (it.moveToFirst()) return it.getLong(0) }
        return -1
    }

    /** Writes an MMS (received or being sent) with its people and parts; returns its row. */
    fun insertMms(
        box: Int,
        thread: Long,
        from: String?,
        to: List<String>,
        cc: List<String>,
        parts: List<Pdu.Part>,
        dateSeconds: Long,
        subject: String?,
        messageId: String?,
        transactionId: String?,
        subId: Int,
    ): Uri? {
        val v = ContentValues().apply {
            put("thread_id", thread)
            put("date", dateSeconds)
            put("date_sent", dateSeconds)
            put("msg_box", box)
            put("read", if (box == Telephony.Mms.MESSAGE_BOX_INBOX) 0 else 1)
            put("seen", if (box == Telephony.Mms.MESSAGE_BOX_INBOX) 0 else 1)
            put("m_type", if (box == Telephony.Mms.MESSAGE_BOX_INBOX) Pdu.RETRIEVE_CONF else Pdu.SEND_REQ)
            put("v", 0x12)
            put("ct_t", "application/vnd.wap.multipart.related")
            put("text_only", if (parts.all { it.isText || it.isSmil }) 1 else 0)
            if (!subject.isNullOrBlank()) { put("sub", subject); put("sub_cs", 106) }
            if (messageId != null) put("m_id", messageId)
            if (transactionId != null) put("tr_id", transactionId)
            put("sub_id", subId)
        }
        val uri = resolver.insert(Telephony.Mms.CONTENT_URI, v) ?: return null
        val id = uri.lastPathSegment ?: return uri
        fun addr(a: String, type: Int) {
            resolver.insert(Uri.parse("content://mms/$id/addr"), ContentValues().apply {
                put("address", a); put("type", type); put("charset", 106)
            })
        }
        addr(from ?: "insert-address-token", 137)
        to.forEach { addr(it, 151) }
        cc.forEach { addr(it, 130) }
        var seq = 0
        for (p in parts) {
            val pv = ContentValues().apply {
                put("mid", id)
                put("seq", if (p.isSmil) -1 else seq++)
                put("ct", p.contentType)
                put("cid", "<${p.contentId ?: p.contentLocation ?: "part$seq"}>")
                put("cl", p.contentLocation ?: p.name ?: "part$seq")
                if (p.name != null) put("name", p.name)
                if (p.isText || p.isSmil) { put("chset", 106); put("text", p.text()) }
            }
            val partUri = resolver.insert(Uri.parse("content://mms/$id/part"), pv) ?: continue
            if (!p.isText && !p.isSmil) {
                try { resolver.openOutputStream(partUri)?.use { it.write(p.data) } } catch (_: Exception) {}
            }
        }
        return uri
    }

    /**
     * A picture message the carrier has announced and that is not here yet (Matt, 2026-11-13, of "a photo could not
     * be downloaded": "when I tap it I'd like it to take me to the associated chat and show the failed image with a
     * retry if needed"). Kept as Android keeps one, a row of the announcement itself: where the picture waits at the
     * carrier, and the name the carrier knows the fetch by. It stands in the sender's conversation until the picture
     * comes down, which takes its place, and is what Try again fetches from. One announced twice is one row.
     */
    fun insertMmsNotice(thread: Long, from: String, location: String, transactionId: String?, subId: Int): Uri? {
        resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id"), "m_type = ${Pdu.NOTIFICATION_IND} AND ct_l = ?", arrayOf(location), null)?.use { c ->
            if (c.moveToFirst()) return Uri.withAppendedPath(Telephony.Mms.CONTENT_URI, c.getLong(0).toString()).also { setMmsNoticeDownloading(it, true) }
        }
        val uri = resolver.insert(Telephony.Mms.CONTENT_URI, ContentValues().apply {
            put("thread_id", thread)
            put("date", System.currentTimeMillis() / 1000)
            put("msg_box", Telephony.Mms.MESSAGE_BOX_INBOX)
            put("read", 0)
            put("seen", 0)
            put("m_type", Pdu.NOTIFICATION_IND)
            put("v", 0x12)
            put("ct_l", location)
            if (transactionId != null) put("tr_id", transactionId)
            put("st", NOTICE_DOWNLOADING)
            put("sub_id", subId)
        }) ?: return null
        val id = uri.lastPathSegment ?: return uri
        resolver.insert(Uri.parse("content://mms/$id/addr"), ContentValues().apply { put("address", from); put("type", 137); put("charset", 106) })
        return uri
    }

    /** Whether the picture [notice] stands for is being brought down now, or could not be. */
    fun setMmsNoticeDownloading(notice: Uri, downloading: Boolean) {
        resolver.update(notice, ContentValues().apply { put("st", if (downloading) NOTICE_DOWNLOADING else NOTICE_FAILED) }, null, null)
    }

    /** Where the picture message announced as [id] waits at the carrier, the fetch's name there, and the SIM. */
    fun mmsNotice(id: Long): Triple<String, String?, Int>? {
        resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("ct_l", "tr_id", "sub_id"), "_id = ? AND m_type = ${Pdu.NOTIFICATION_IND}", arrayOf(id.toString()), null)?.use { c ->
            if (c.moveToFirst()) return Triple(c.getString(0) ?: return null, c.getString(1), c.getInt(2))
        }
        return null
    }

    /** The announcement kept for the picture message waiting at [location], if one is. */
    fun mmsNoticeAt(location: String): Uri? {
        resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id"), "m_type = ${Pdu.NOTIFICATION_IND} AND ct_l = ?", arrayOf(location), null)?.use { c ->
            if (c.moveToFirst()) return Uri.withAppendedPath(Telephony.Mms.CONTENT_URI, c.getLong(0).toString())
        }
        return null
    }

    fun deleteMms(uri: Uri) { resolver.delete(uri, null, null) }

    /** Whether the picture message [id] is still there and still waiting to go. */
    fun isMmsOutbox(id: Long): Boolean = try {
        resolver.query(Uri.parse("content://mms/$id"), arrayOf("msg_box"), null, null, null)?.use { it.moveToFirst() && it.getInt(0) == Telephony.Mms.MESSAGE_BOX_OUTBOX } ?: false
    } catch (_: Exception) { false }

    /**
     * Messages that have stood as Sending for longer than [olderThan] milliseconds are marked not sent, so they can
     * be tried again: Android reports each one's result, but a phone switched off or an app stopped in between
     * leaves one waiting for an answer that will never come. Answers how many.
     */
    fun failStale(olderThan: Long = 15L * 60 * 1000): Int {
        var n = 0
        val before = System.currentTimeMillis() - olderThan
        try {
            resolver.query(Telephony.Mms.CONTENT_URI, arrayOf("_id", "thread_id"), "msg_box = ${Telephony.Mms.MESSAGE_BOX_OUTBOX} AND date < ${before / 1000}", null, null)?.use { c ->
                while (c.moveToNext()) {
                    val uri = Uri.parse("content://mms/${c.getLong(0)}")
                    setMmsBox(uri, Telephony.Mms.MESSAGE_BOX_FAILED)
                    MmsDiag.failed(context, uri, "it was interrupted before it went")
                    n++
                }
            }
            n += resolver.update(Telephony.Sms.CONTENT_URI, ContentValues().apply { put("type", Telephony.Sms.MESSAGE_TYPE_FAILED) },
                "type IN (${Telephony.Sms.MESSAGE_TYPE_OUTBOX}, ${Telephony.Sms.MESSAGE_TYPE_QUEUED}) AND date < $before", null)
        } catch (_: Exception) {}
        return n
    }

    fun setMmsBox(uri: Uri, box: Int) {
        resolver.update(uri, ContentValues().apply { put("msg_box", box) }, null, null)
    }

    /**
     * The bridge's messages for [thread] (GmBridge: RCS chats Google Messages showed), each one Android's database
     * does not already have: a text it has with the same words within three minutes is the same message.
     */
    private fun withBridgedMessages(thread: Long, out: ArrayList<Map<String, Any?>>, limit: Int) {
        val bridged = try { GmBridge.Db.get(context).messagesOfThread(thread, limit) } catch (_: Exception) { return }
        if (bridged.isEmpty()) return
        val have = out.map { AndroidCopy(it["outgoing"] as Boolean, (it["body"] as String?)?.trim() ?: "", it["date"] as Long, (it["parts"] as? List<*>)?.isNotEmpty() == true) }
        val used = HashSet<Int>()
        for (m in bridged) {
            // A picture message still coming down, kept before it was waited for: its words are a stand-in, and Android's
            // copy is the message itself (Matt, 2026-11-18: "it still shows me the "attachement" and "Sms message from jade"").
            if (!m.out && GmBridge.downloading(m.status ?: "")) continue
            // From a notification (no status of Google Messages' own): words that are a stand-in for a picture ("Photo",
            // "Attachment", kept so before 0.12.43) are no words, and say it is a picture (Matt, 2026-11-26: "some RCS
            // images are just displaying as "attachment"").
            val noted = m.status == null
            val stand = noted && GmBridge.standIn(m.text)
            val text = if (stand) "" else m.text
            // From the on-phone connection (GmWeb) or a notification: its pictures, where they can be had; else what
            // they were (`missing`).
            var missing: String? = if (stand) GmBridge.standInKind(m.text) else null
            val parts = m.media?.let { j ->
                try {
                    val a = org.json.JSONArray(j)
                    (0 until a.length()).mapNotNull { i ->
                        a.getJSONObject(i).let { p ->
                            if (p.optBoolean("missing") || !p.has("id")) { missing = GmBridge.summary("", listOf(p.optString("type"))); null }
                            else mapOf("id" to p.getLong("id"), "type" to p.optString("type"), "name" to p.optString("name").ifBlank { null })
                        }
                    }
                } catch (_: Exception) { emptyList() }
            } ?: emptyList()
            val media = parts.isNotEmpty() || missing != null
            if (androidCopyOf(have, m.out, text, m.time, media, used) != null) continue
            // A notification's copy beside the on-phone connection's own, kept before either knew of the other.
            if (noted && bridged.any { w -> w.status != null && w.out == m.out && kotlin.math.abs(w.time - m.time) < 180_000 && GmBridge.sameMessage(m.text, media, w.text, !w.media.isNullOrBlank() && w.media != "[]") }) continue
            val status = m.status ?: ""
            val state = when {
                !m.out -> "received"
                status.contains("fail") || status.contains("error") || status.contains("canceled") -> "failed"
                // Still "sending" a quarter of an hour on: its update was missed (Google Messages says "failed" of one that
                // failed), so it is shown as sent rather than sending for ever.
                status.contains("sending") || status.contains("yet_to_send") || status.contains("resending") -> if (System.currentTimeMillis() - m.time > 15 * 60_000) "sent" else "sending"
                status.contains("display") || status.contains("read") -> "read"
                status.contains("delivered") -> "delivered"
                else -> "sent"
            }
            out += mapOf(
                "id" to m.id, "kind" to "rcs", "address" to (m.address ?: m.sender ?: ""),
                // Its reactions apart from its words, drawn once with the rest (lib/reactions.dart): in the words they were
                // shown twice, there and under it (Matt, 2026-11-17: "When people react to a message we sent we see double
                // reactions").
                "body" to text, "reactions" to (m.reactions?.split(Regex("\\s+"))?.filter { it.isNotBlank() } ?: emptyList<String>()), "encrypted" to false,
                "notice" to null, "date" to m.time, "outgoing" to m.out, "state" to state,
                "read" to (m.out || m.read), "via" to "gm", "sender" to m.sender, "parts" to parts,
                "missing" to (if (parts.isEmpty()) missing else null),
            )
        }
    }

    fun markRead(thread: Long) {
        // Beside Google Messages (GmBridge): read in the bridge, and in Google Messages too where it offers that. Android's
        // database takes no writes from an app that is not the default, so the two updates below may change nothing.
        // Every conversation of Google Messages' that is this one, not the newest alone: a thread is often two (the one
        // its notifications named and the one its on-phone connection knows), and only the second can be marked read
        // there (Matt, 2026-11-16: "Rcs messages are not being marked as read when i view the message group").
        try {
            val db = GmBridge.Db.get(context)
            for (conv in (db.webConvsOf(thread) + listOfNotNull(db.convOfThread(thread))).distinct()) GmBridge.markRead(context, conv)
            db.markRead(thread)
        } catch (e: Exception) { DevLog.add(context, "read", "marking $thread read beside Google Messages: ${e.message}") }
        // Read here whatever Android's database says: beside Google Messages it takes no writes from this app, and
        // Google Messages may not have marked it yet (or at all, with its connection down).
        keepRead(thread)
        val v = ContentValues().apply { put("read", 1); put("seen", 1) }
        try {
            resolver.update(Telephony.Sms.CONTENT_URI, v, "thread_id = ? AND read = 0", arrayOf(thread.toString()))
            resolver.update(Telephony.Mms.CONTENT_URI, v, "thread_id = ? AND read = 0", arrayOf(thread.toString()))
        } catch (_: SecurityException) {}
    }

    /**
     * Deletes every message of [thread], and says so if Android did not (Matt, 2026-11-14: "deleting messages isn't
     * working"). On an emulator the plain way works; a phone's own store may want it asked another way, so where
     * the conversation still holds messages afterwards its texts and its picture messages are deleted by the
     * conversation they say they are in, and if they are still there after that the screen is told, not left
     * showing "deleted" over something that was not.
     */
    /**
     * Conversations deleted while Uplink is not the default SMS app, each with the time it was deleted at: left out of
     * the list until something newer arrives in them. Android lets only the default SMS app delete texts.
     */
    /** When each conversation was last read here: what came before then is read, whatever Android's database says. */
    fun readThreads(): Map<Long, Long> = try {
        val o = org.json.JSONObject(prefs.getString("read_threads", "{}")!!)
        o.keys().asSequence().mapNotNull { k -> k.toLongOrNull()?.let { it to o.getLong(k) } }.toMap()
    } catch (_: Exception) { emptyMap() }

    /** Notes that [thread] was read here, and when: this app's own record, for where Android's cannot be written. */
    private fun keepRead(thread: Long) {
        val o = try { org.json.JSONObject(prefs.getString("read_threads", "{}")!!) } catch (_: Exception) { org.json.JSONObject() }
        o.put(thread.toString(), System.currentTimeMillis())
        prefs.edit().putString("read_threads", o.toString()).apply()
    }

    /** [rows] with each one read here since its newest message shown as read. */
    private fun withReadHere(rows: ArrayList<Map<String, Any?>>) = readHere(rows, readThreads())

    /** Conversations deleted here beside Google Messages, and when: out of the list until something newer comes. */
    fun hiddenThreads(): Map<Long, Long> = try {
        val o = org.json.JSONObject(prefs.getString("hidden_threads", "{}")!!)
        o.keys().asSequence().mapNotNull { k -> k.toLongOrNull()?.let { it to o.getLong(k) } }.toMap()
    } catch (_: Exception) { emptyMap() }

    private fun hideThread(thread: Long) {
        val o = try { org.json.JSONObject(prefs.getString("hidden_threads", "{}")!!) } catch (_: Exception) { org.json.JSONObject() }
        o.put(thread.toString(), System.currentTimeMillis())
        prefs.edit().putString("hidden_threads", o.toString()).apply()
    }

    fun deleteThread(thread: Long) {
        // Beside Google Messages, where Android lets only it delete texts (Matt, 2026-11-15: "I also need to be able to
        // proxy deleting conversations when ghost is not the default messaging app"): Google Messages deletes it,
        // through its web connection where Uplink is paired with it (GmWeb), which deletes it from Android's store and
        // every device; and Uplink leaves it out of its list until something newer arrives, paired or not.
        if (!GmBridge.isDefault(context)) {
            GmWeb.deleteThread(thread)
            hideThread(thread)
            try { GmBridge.Db.get(context).forget(thread) } catch (_: Exception) {}
            snippets.remove(thread)
            return
        }
        try { GmBridge.Db.get(context).forget(thread) } catch (_: Exception) {}
        // Only the bridge's (an RCS chat Google Messages showed): nothing of Android's to delete.
        if (thread < 0) return
        var gone = 0
        try { gone += resolver.delete(Uri.parse("content://mms-sms/conversations/$thread"), null, null) } catch (e: Exception) { android.util.Log.w("GhostMessaging", "delete conversation", e) }
        if (hasMessages(thread)) {
            try { gone += resolver.delete(Telephony.Sms.CONTENT_URI, "thread_id = ?", arrayOf(thread.toString())) } catch (_: Exception) {}
            try { gone += resolver.delete(Telephony.Mms.CONTENT_URI, "thread_id = ?", arrayOf(thread.toString())) } catch (_: Exception) {}
            DevLog.add(context, "del", "a conversation was not deleted the usual way; asked for its messages by conversation instead ($gone gone)")
        }
        if (hasMessages(thread)) throw IllegalStateException("Android did not delete it. Is Uplink still the default SMS app?")
        snippets.remove(thread)
    }

    /** Deletes one message, and says so if Android did not: asked by its own address, then by its number. */
    /** Messages deleted beside Google Messages that Android would not let go of: left out of the list ("kind:id"). */
    fun hiddenMessages(): Set<String> = prefs.getStringSet("hidden_msgs", emptySet())!!

    /**
     * Joins [threads] (each with when it was deleted) and [msgs] from the Uplink account into the lists here
     * (lib/kept_lists.dart): the later time for a conversation in both. True where any was new.
     */
    fun addHidden(threads: Map<Long, Long>, msgs: Collection<String>): Boolean {
        val o = try { org.json.JSONObject(prefs.getString("hidden_threads", "{}")!!) } catch (_: Exception) { org.json.JSONObject() }
        var added = false
        for ((t, at) in threads) {
            if (o.optLong(t.toString(), 0L) < at) { o.put(t.toString(), at); added = true }
        }
        val before = hiddenMessages()
        if (!before.containsAll(msgs)) added = true
        prefs.edit().putString("hidden_threads", o.toString()).putStringSet("hidden_msgs", before + msgs).apply()
        return added
    }

    private fun hideMessage(kind: String, id: Long) {
        prefs.edit().putStringSet("hidden_msgs", hiddenMessages() + "$kind:$id").apply()
    }

    fun deleteMessage(kind: String, id: Long) {
        // One the bridge read from Google Messages (GmBridge): deleted in Google Messages where Uplink is paired with
        // its web connection (Matt, 2026-11-15: "if possible proxy the archive and delete messages too"), and
        // forgotten here either way.
        if (kind == "rcs") {
            val db = GmBridge.Db.get(context)
            db.gmIdOf(id)?.let { GmWeb.deleteMessage(it) }
            db.forgetMessage(id)
            return
        }
        // Beside Google Messages Android lets only it delete texts: Google Messages deletes its copy (found by the
        // same words and time) where Uplink is paired, and Uplink leaves the text out of its list either way.
        if (!GmBridge.isDefault(context) && kind == "sms") {
            try {
                resolver.query(Telephony.Sms.CONTENT_URI, arrayOf("thread_id", "body", "type", "date"), "_id = ?", arrayOf("$id"), null)?.use { c ->
                    if (c.moveToFirst()) {
                        val out = c.getInt(2) != Telephony.Sms.MESSAGE_TYPE_INBOX
                        GmBridge.Db.get(context).gmIdLike(c.getLong(0), c.getString(1) ?: "", out, c.getLong(3))?.let { GmWeb.deleteMessage(it) }
                    }
                }
            } catch (_: Exception) {}
            hideMessage(kind, id)
            return
        }
        if (!GmBridge.isDefault(context)) { hideMessage(kind, id); return }
        val all = if (kind == "mms") Telephony.Mms.CONTENT_URI else Telephony.Sms.CONTENT_URI
        var gone = try { resolver.delete(Uri.withAppendedPath(all, id.toString()), null, null) } catch (e: Exception) { android.util.Log.w("GhostMessaging", "delete message", e); 0 }
        if (gone == 0) {
            gone = try { resolver.delete(all, "_id = ?", arrayOf(id.toString())) } catch (_: Exception) { 0 }
            if (gone > 0) DevLog.add(context, "del", "a message was not deleted by its address; deleted by its number instead")
        }
        val still = try { resolver.query(all, arrayOf("_id"), "_id = ?", arrayOf(id.toString()), null)?.use { it.count > 0 } ?: false } catch (_: Exception) { false }
        if (still) throw IllegalStateException("Android did not delete it. Is Uplink still the default SMS app?")
        editsPrefs.edit().remove("$kind:$id").apply()
    }

    /** How many messages are unread, texts and picture messages together. */
    fun unreadCount(): Int {
        var n = 0
        val read = readThreads()
        // A text read here counts as read (withReadHere). MMS dates are in seconds.
        resolver.query(Telephony.Sms.Inbox.CONTENT_URI, arrayOf("thread_id", "date"), "read = 0", null, null)?.use { c ->
            while (c.moveToNext()) if (c.getLong(1) > (read[c.getLong(0)] ?: -1L)) n++
        }
        resolver.query(Telephony.Mms.Inbox.CONTENT_URI, arrayOf("thread_id", "date"), "read = 0", null, null)?.use { c ->
            while (c.moveToNext()) if (c.getLong(1) * 1000 > (read[c.getLong(0)] ?: -1L)) n++
        }
        return n
    }

    // --- receipts: what came back about an MMS of ours, by the name the MMSC gave it --------------------------------

    private val receiptPrefs get() = context.getSharedPreferences("receipts", Context.MODE_PRIVATE)

    /** Message-ID -> "delivered" or "read". */
    fun receipts(): Map<String, String> = receiptPrefs.all.mapValues { it.value.toString() }

    /** Read outranks delivered: a delivery report arriving after a read report changes nothing. */
    fun setReceipt(messageId: String, state: String) {
        if (state == "delivered" && receiptPrefs.getString(messageId, null) == "read") return
        receiptPrefs.edit().putString(messageId, state).apply()
    }

    fun setMmsMessageId(uri: Uri, messageId: String) {
        resolver.update(uri, ContentValues().apply { put("m_id", messageId) }, null, null)
    }

    // --- edits (this app's own record: SMS has no edit, so the original is kept here) ------------------------------

    private val editsPrefs get() = context.getSharedPreferences("edits", Context.MODE_PRIVATE)

    /** "sms:12" -> the text it had before its first edit. */
    fun originals(): Map<String, String> = editsPrefs.all.mapValues { it.value.toString() }

    /** Changes the text of one of your messages on this phone, keeping what it first said. */
    fun editMessage(kind: String, id: Long, body: String) {
        val key = "$kind:$id"
        val before: String?
        if (kind == "mms") {
            var partId = -1L
            var text: String? = null
            resolver.query(Uri.parse("content://mms/part"), arrayOf("_id", "text"), "mid = ? AND ct = 'text/plain'", arrayOf(id.toString()), "seq ASC")?.use {
                if (it.moveToFirst()) { partId = it.getLong(0); text = it.getString(1) }
            }
            before = text
            if (partId >= 0) {
                resolver.update(Uri.parse("content://mms/part/$partId"), ContentValues().apply { put("text", body) }, null, null)
            } else {
                resolver.insert(Uri.parse("content://mms/$id/part"), ContentValues().apply {
                    put("mid", id); put("seq", 0); put("ct", "text/plain"); put("chset", 106)
                    put("cid", "<text0>"); put("cl", "text0.txt"); put("text", body)
                })
            }
        } else {
            var text: String? = null
            var address = ""
            resolver.query(Uri.parse("content://sms/$id"), arrayOf("body", "address"), null, null, null)?.use {
                if (it.moveToFirst()) { text = it.getString(0); address = it.getString(1) ?: "" }
            }
            // What it first said is kept as words; the row keeps a sealed text sealed.
            val sealed = text != null && E2eCrypto.isSealed(text!!)
            before = if (sealed) E2e.read(context, address, text!!).first else text
            val stored = if (sealed) (E2e.wire(context, address, body) ?: body) else body
            resolver.update(Uri.parse("content://sms/$id"), ContentValues().apply { put("body", stored) }, null, null)
        }
        if (!editsPrefs.contains(key)) editsPrefs.edit().putString(key, before ?: "").apply()
    }

    // --- archive (this app's own, not the provider's) ----------------------------------------------------------------

    private val prefs get() = context.getSharedPreferences("ghost", Context.MODE_PRIVATE)

    /**
     * A name given to a conversation on this phone (Matt, 2026-11-14: "expand on the ability to create, name and
     * manage groups like telegram"): a group's, which otherwise goes by its people's first names. It is this
     * phone's own: a group text has nowhere to carry one, so the others in it do not see it.
     */
    fun threadName(thread: Long): String? = prefs.getString("name_$thread", null)?.takeIf { it.isNotBlank() }

    fun setThreadName(thread: Long, name: String) {
        val clean = name.trim().take(NAME_MOST)
        prefs.edit().apply { if (clean.isEmpty()) remove("name_$thread") else putString("name_$thread", clean) }.apply()
    }

    /** A set of conversations kept by this app under [name]: "pinned", "muted". */
    fun threadFlags(name: String): Set<Long> = prefs.getStringSet(name, emptySet())!!.mapNotNull { it.toLongOrNull() }.toSet()

    /** Puts [thread] in, or takes it out of, the set kept under [name]. */
    fun setThreadFlag(name: String, thread: Long, on: Boolean) {
        val s = prefs.getStringSet(name, emptySet())!!.toMutableSet()
        if (on) s += thread.toString() else s -= thread.toString()
        prefs.edit().putStringSet(name, s).apply()
    }

    fun isMuted(thread: Long) = threadFlags("muted").contains(thread)

    // --- drafts: what was typed into a conversation and not sent ----------------------------------------------------

    private val draftPrefs get() = context.getSharedPreferences("drafts", Context.MODE_PRIVATE)

    fun drafts(): Map<String, String> = draftPrefs.all.mapValues { it.value.toString() }

    fun draft(thread: Long): String? = draftPrefs.getString(thread.toString(), null)

    /** Keeps what was typed into [thread] and not sent; nothing but spaces forgets it. */
    fun setDraft(thread: Long, text: String) {
        if (text.isBlank()) draftPrefs.edit().remove(thread.toString()).apply() else draftPrefs.edit().putString(thread.toString(), text).apply()
    }

    /** Every number on Android's blocked list, with the contact it is, for Settings. */
    fun blockedNumbers(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        try {
            resolver.query(android.provider.BlockedNumberContract.BlockedNumbers.CONTENT_URI, arrayOf(android.provider.BlockedNumberContract.BlockedNumbers.COLUMN_ORIGINAL_NUMBER), null, null, null)?.use {
                while (it.moveToNext()) { val n = it.getString(0) ?: continue; out += contact(n) }
            }
        } catch (_: Exception) {}
        return out
    }

    // --- blocked numbers: Android's own list, which the default SMS app may read and write --------------------------

    fun isBlocked(address: String): Boolean = try {
        android.provider.BlockedNumberContract.isBlocked(context, address)
    } catch (_: Exception) { false }

    /** Android itself stops a blocked number's texts and calls before any app sees them. */
    fun setBlocked(address: String, blocked: Boolean) {
        if (blocked) {
            resolver.insert(android.provider.BlockedNumberContract.BlockedNumbers.CONTENT_URI, ContentValues().apply {
                put(android.provider.BlockedNumberContract.BlockedNumbers.COLUMN_ORIGINAL_NUMBER, address)
            })
        } else {
            android.provider.BlockedNumberContract.unblock(context, address)
        }
    }

    /** The conversations archived: this app's own set, since Android's database has no archive. */
    fun archivedThreads(): Set<Long> = prefs.getStringSet("archived", emptySet())!!.mapNotNull { it.toLongOrNull() }.toSet()

    fun setArchived(thread: Long, archived: Boolean) {
        // Archived in Google Messages too, where Uplink is paired with its web connection (Matt, 2026-11-15: "if
        // possible proxy the archive and delete messages too"), so the two keep the same archive.
        if (!GmBridge.isDefault(context)) Thread { GmWeb.archiveThread(thread, archived) }.start()
        val s = prefs.getStringSet("archived", emptySet())!!.toMutableSet()
        if (archived) s += thread.toString() else s -= thread.toString()
        prefs.edit().putStringSet("archived", s).apply()
    }

    /**
     * The newest message of conversations left out of the list for another's sake (an RCS group's stand-in thread, its
     * messages shown in its group's): [into] gives each one's row its newest words and time where they are newer.
     */
    class Newest {
        private val by = HashMap<Long, Triple<Long, String, Boolean>>()

        /** [date] and [snippet] of a conversation shown as [thread]'s: kept where newer than any kept for it. */
        fun carry(thread: Long, date: Long, snippet: String, unread: Boolean) {
            val had = by[thread]
            by[thread] = if (had == null || date > had.first) Triple(date, snippet, unread || had?.third == true) else had.copy(third = had.third || unread)
        }

        /** Each of [rows] (by `id`) brought to the newest kept for it; true where any changed. */
        fun into(rows: MutableList<Map<String, Any?>>): Boolean {
            if (by.isEmpty()) return false
            var changed = false
            rows.forEachIndexed { i, row ->
                val (date, snippet, unread) = by[row["id"] as Long] ?: return@forEachIndexed
                val newer = date > (row["date"] as Long) && snippet.isNotBlank()
                if (!newer && (!unread || row["unread"] == true)) return@forEachIndexed
                rows[i] = row + (if (newer) mapOf("date" to date, "snippet" to snippet) else emptyMap()) + (if (unread) mapOf("unread" to true) else emptyMap())
                changed = true
            }
            return changed
        }
    }

    /** The kinds of a bridged message's parts (its `media`, `[{id, type}]`); none where it has none. */
    private fun partTypes(media: String?): List<String> = if (media.isNullOrBlank()) emptyList() else try {
        val a = org.json.JSONArray(media)
        (0 until a.length()).map { a.getJSONObject(it).optString("type") }
    } catch (_: Exception) { emptyList() }

    /** A message as Android's database lists it, for [androidCopyOf]: its side, its words, when, whether it has a picture. */
    data class AndroidCopy(val out: Boolean, val words: String, val time: Long, val media: Boolean)

    companion object {
        /**
         * Which of Android's messages ([have]) is the same as one the bridge has, if any, and marks it [used] so it is
         * the same as no other. Words alike within three minutes; or a picture beside a picture message of the same
         * words (none, mostly) within fifteen, the nearest first (Matt, 2026-11-16: "they don't show up in the app
         * properly after closing and re opening and they get stuck on sending never sent"). Google Messages tells of a
         * picture as it starts sending, and where RCS gives up and it goes as MMS, Android's copy is dated when the MMS
         * went, minutes later; the bridge's own copy then never hears it went, and stood beside it as "sending".
         */
        fun androidCopyOf(have: List<AndroidCopy>, out: Boolean, text: String, time: Long, media: Boolean, used: MutableSet<Int>): Int? {
            val words = text.trim()
            var best: Int? = null
            var gap = Long.MAX_VALUE
            for ((i, h) in have.withIndex()) {
                if (i in used || h.out != out || h.words != words) continue
                val d = kotlin.math.abs(h.time - time)
                // The bridge's copy with no words and no picture is a picture message whose picture it was never told
                // of (your own, mostly): as near as a picture's (Matt, 2026-11-19: "when I'm sending pictures and voice
                // messages sometimes I don't see my outbound messages just the delivered tag").
                val near = if (h.media && (media || words.isEmpty())) d < 15 * 60_000 else d < 180_000
                if (near && d < gap) { best = i; gap = d }
            }
            best?.let { used += it }
            return best
        }

        /** [rows] (conversations, newest message's time in `date`) read at [read]'s times, by id: unread no more if nothing newer came. */
        fun readHere(rows: MutableList<Map<String, Any?>>, read: Map<Long, Long>) {
            if (read.isEmpty()) return
            rows.forEachIndexed { i, row ->
                val at = read[row["id"] as Long] ?: return@forEachIndexed
                if (row["unread"] == true && (row["date"] as Long) <= at) rows[i] = row + mapOf("unread" to false)
            }
        }

        /** The longest name a conversation can be given. */
        const val NAME_MOST = 60

        /** How many unread conversations from beyond the first lot come with it: enough to fill the top of the screen. */
        const val UNREAD_TOO = 20

        /**
         * Whether a conversation whose newest message is dated [time] belongs on the lot of the list that runs from
         * [lower] to just below [upper] (null: no bound that side; conversationsPage).
         */
        fun onLot(time: Long, lower: Long?, upper: Long?): Boolean = (lower == null || time >= lower) && (upper == null || time < upper)

        /**
         * The bridge's conversations ([bridged]: each one's thread and its newest message's time) that belong on a lot
         * by that time and are not among the rows it [have]s: Android's own row of each is brought up for it.
         */
        fun bridgedOnLot(bridged: List<Pair<Long, Long>>, have: Set<Long>, lower: Long?, upper: Long?): List<Long> =
            bridged.filter { (thread, time) -> thread !in have && onLot(time, lower, upper) }.map { it.first }

        /** A picture message's announcement: being brought down, or it could not be (Android's own two numbers). */
        const val NOTICE_DOWNLOADING = 129
        const val NOTICE_FAILED = 130

        fun sameNumber(a: String, b: String): Boolean {
            if (a.contains('@') || b.contains('@')) return a.equals(b, ignoreCase = true)
            val da = a.filter { it.isDigit() }
            val db = b.filter { it.isDigit() }
            if (da.isEmpty() || db.isEmpty()) return a == b
            @Suppress("DEPRECATION")
            return PhoneNumberUtils.compare(a, b) || da.takeLast(10) == db.takeLast(10)
        }

        @Suppress("unused")
        private fun Cursor.str(name: String): String? = getColumnIndex(name).let { if (it < 0) null else getString(it) }
    }
}
