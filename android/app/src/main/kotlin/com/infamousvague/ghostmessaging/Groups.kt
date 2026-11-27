package com.infamousvague.ghostmessaging

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.provider.Telephony
import android.telephony.SubscriptionManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/**
 * Groups of friends: the phone's half (lib/friends/groups.dart is the rest). Matt, 2026-11-14: "expand on the
 * ability to create, name and manage groups like telegram".
 *
 * A group is made by one person out of their friends and is its own thing, not a group text: it has a name every
 * member sees, members who can be added and taken out, and admins who do that. What is written in it goes to each
 * member by the app's routes (lib/net), never as an MMS.
 *
 * What is here:
 * - **The record** of each group this phone is in ([save], [view]): its name, its members (each by the name of
 *   their key, with the key and their number), its admins, a count of how many times it has been changed.
 * - **Its conversation.** One of the phone's own, so the list, search, notifications and a paired computer show it
 *   with nothing new to read. A conversation is told apart by who it is with; a group's is with an address that is
 *   nobody's ([address]), so it is never an existing group text's nor another group's, and stays the same
 *   conversation as its members change. Who is in it is read from the record ([people]).
 * - **Its members as people the routes reach** ([peers]). Two members need not have exchanged keys by text: each
 *   has the other's key from the record, which came from someone both had, and the two make their pair's key from
 *   it as two who exchanged keys do.
 * - **What is written in it**, kept as a group message is ([storeIn], [storeOut]), and lines about the group itself
 *   ("Ann added Dan": [note]).
 */
object Groups {
    private const val PREFS = "groups"
    // A name for a group's address, not a link: kept when the site moved to gogho.st (2026-11-15), since phones have
    // groups stored under it and send it to each other.
    private const val DOMAIN = "@group.ghost-sms.com"

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Who a group's conversation is with, as Android keeps it: an address that is nobody's, made from its [id]. It
     * holds no digit (each of the id's is written as a letter, g for 0 to p for 9), so nothing that compares
     * numbers by their last digits (E2e.norm, the contacts) can take it for someone's.
     */
    fun address(id: String) = id.map { if (it in '0'..'9') 'g' + (it - '0') else it }.joinToString("") + DOMAIN

    /** The group an address made by [address] is of, or null for any other. */
    fun idOf(address: String?): String? {
        val name = address?.takeIf { it.endsWith(DOMAIN) }?.removeSuffix(DOMAIN) ?: return null
        if (name.length != 32 || !name.all { it in 'a'..'p' }) return null
        return name.map { if (it in 'g'..'p') '0' + (it - 'g') else it }.joinToString("")
    }

    /** A group's id: 32 hex digits, made by whoever made the group. */
    fun isId(id: String) = id.length == 32 && id.all { it in '0'..'9' || it in 'a'..'f' }

    // A name for a member's stand-in address, as [DOMAIN] is for a group's: nobody's, never sent anywhere.
    private const val MEMBER = "@member.ghost-sms.com"

    /**
     * What a member of a group is shown and kept under where this phone knows no address for them that is theirs
     * ([shown]): an address that is nobody's, made from their install's name [id] as a group's is ([address]), with no
     * digit, so no contact is ever found by it.
     */
    fun memberAddress(id: String) = id.map { if (it in '0'..'9') 'g' + (it - '0') else it }.joinToString("") + MEMBER

    /** What a stand-in from [memberAddress] is called: "Someone" and the start of their install's name; null for any other address. */
    fun memberName(address: String?): String? {
        val name = address?.takeIf { it.endsWith(MEMBER) }?.removeSuffix(MEMBER) ?: return null
        if (name.length != 32 || !name.all { it in 'a'..'p' }) return null
        return "Someone · " + name.take(4).map { if (it in 'g'..'p') '0' + (it - 'g') else it }.joinToString("")
    }

    /**
     * The address a member of a group is shown under, kept under and woken at here (found in review, 2026-11-23): the
     * one this phone's own record gives their key ([known]: the number encryption is on with them at, or a friend by
     * username's @name); else the one the group lists ([written], its admin's word), where it is nobody's here
     * ([listed]); else a stand-in that is nobody's ([memberAddress]). Never a number this phone holds a record for, nor
     * an @name, unless it is theirs: a stranger listed under Mom's number was shown as Mom, with her photo, in the
     * group's conversation and its notifications.
     */
    fun shownAddress(id: String, written: String, known: Map<String, String>, held: Set<String>): String =
        known[id] ?: listed(written, held).ifEmpty { memberAddress(id) }

    /**
     * Who this phone's own records say each install is, by its name: those encryption is on with, at their number, and
     * friends by username who said yes, as @name. A number before a username for one key.
     */
    fun known(context: Context): Map<String, String> {
        val out = HashMap<String, String>()
        runCatching {
            val list = JSONArray(Buddies.kept(context))
            for (i in 0 until list.length()) {
                val b = list.optJSONObject(i) ?: continue
                val id = b.optString("i")
                val u = b.optString("u")
                if (id.isNotEmpty() && u.isNotEmpty() && b.optString("s") == "yes") out[id] = "@$u"
            }
        }
        for ((id, address) in E2e.onIds(context)) out[id] = address
        return out
    }

    // --- the records ----------------------------------------------------------------------------------------------------

    /** A group's record by its id, or null; and every group's. */
    fun get(context: Context, id: String): JSONObject? =
        prefs(context).getString("g:$id", null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    fun all(context: Context): List<JSONObject> =
        prefs(context).all.keys.filter { it.startsWith("g:") }.mapNotNull { get(context, it.removePrefix("g:")) }

    /** Each group's record by its conversation. */
    fun byThread(context: Context): Map<Long, JSONObject> = all(context).filter { it.has("thread") }.associateBy { it.getLong("thread") }

    fun ofThread(context: Context, thread: Long): JSONObject? = byThread(context)[thread]

    private fun members(o: JSONObject): List<JSONObject> = o.optJSONArray("members")?.let { a -> (0 until a.length()).map { a.getJSONObject(it) } } ?: emptyList()

    /** This phone's name among the members: the name of its key (Net.idOf). */
    fun me(context: Context): String = Net.idOf(E2e.myPublic(context))

    /**
     * Keeps a group as lib/friends/groups.dart has decided it now is: `{id, name, v, members: [{i, k, a}], admins:
     * [i], gone}` (a member's name, key in base64 and number). Its conversation is made the first time and never
     * changed after. Returns it as the screens read it ([view]).
     */
    fun save(context: Context, state: JSONObject): Map<String, Any?> {
        val id = state.getString("id")
        require(isId(id)) { "Not a group's id" }
        val before = get(context, id)
        val thread = before?.optLong("thread", -1)?.takeIf { it > 0 } ?: Store(context).threadFor(listOf(address(id)))
        val o = JSONObject()
            .put("id", id)
            .put("name", state.optString("name").trim().take(Store.NAME_MOST))
            .put("v", state.optInt("v", 1))
            .put("members", state.optJSONArray("members") ?: JSONArray())
            .put("admins", state.optJSONArray("admins") ?: JSONArray())
            .put("gone", state.optBoolean("gone", false))
            .put("thread", thread)
        prefs(context).edit().putString("g:$id", o.toString()).apply()
        return view(context, o)
    }

    /** Forgets a group. Its conversation is left as it is, for the person to keep or delete. */
    fun forget(context: Context, id: String) {
        prefs(context).edit().remove("g:$id").apply()
    }

    /**
     * A group for the screens: its record, and each member with whether they are this phone, whether an admin, and
     * who they are: the address the record lists them under (`address`, which goes back into the record as it is
     * changed), and the one they are shown under here (`shown`, [shownAddress]) with the name and photo the phone's
     * contacts give that one.
     */
    fun view(context: Context, o: JSONObject): Map<String, Any?> {
        val mine = me(context)
        val admins = o.optJSONArray("admins")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
        val store = Store(context)
        val known = known(context)
        val held = E2e.held(context)
        return mapOf(
            "id" to o.getString("id"),
            "name" to o.optString("name"),
            "v" to o.optInt("v", 1),
            "thread" to o.optLong("thread", -1),
            "gone" to o.optBoolean("gone", false),
            "me" to mine,
            "members" to members(o).map { m ->
                val id = m.getString("i")
                val address = m.optString("a")
                val shown = if (id == mine) "" else shownAddress(id, address, known, held)
                val person = if (shown.isNotEmpty()) store.contact(shown) else emptyMap()
                mapOf(
                    "id" to id,
                    "key" to m.optString("k"),
                    "address" to address,
                    "shown" to shown,
                    "name" to person["name"],
                    "photo" to person["photo"],
                    "admin" to (id in admins),
                    "me" to (id == mine),
                )
            },
        )
    }

    fun views(context: Context): List<Map<String, Any?>> = all(context).map { view(context, it) }

    /**
     * A group this phone makes, out of [addresses]: people encryption is on with, whose keys are here. This phone is
     * its first member and its admin; its own number is not known to it and is left for the others to fill in (each
     * knows who sent them the group). Not kept: lib/friends/groups.dart keeps it ([save]) and tells the others.
     */
    fun draft(context: Context, id: String, name: String, addresses: List<String>): JSONObject {
        val mine = me(context)
        val members = JSONArray().put(JSONObject().put("i", mine).put("k", Base64.getEncoder().encodeToString(E2e.myPublic(context))).put("a", ""))
        val known = E2e.accepted(context)
        for (address in addresses) {
            val (theirs, pub, _) = known.firstOrNull { E2e.norm(it.first) == E2e.norm(address) } ?: throw IllegalStateException("No key is here for $address")
            val name1 = Net.idOf(pub)
            if ((0 until members.length()).any { members.getJSONObject(it).getString("i") == name1 }) continue
            members.put(JSONObject().put("i", name1).put("k", Base64.getEncoder().encodeToString(pub)).put("a", theirs))
        }
        return JSONObject().put("id", id).put("name", name).put("v", 1).put("members", members).put("admins", JSONArray().put(mine))
    }

    /** A person encryption is on with, as a member of a group: for adding them to one. */
    fun member(context: Context, address: String): JSONObject {
        val (theirs, pub, _) = E2e.accepted(context).firstOrNull { E2e.norm(it.first) == E2e.norm(address) } ?: throw IllegalStateException("No key is here for $address")
        return JSONObject().put("i", Net.idOf(pub)).put("k", Base64.getEncoder().encodeToString(pub)).put("a", theirs)
    }

    // --- its members, for the conversation and for the routes ----------------------------------------------------------

    /** Who a group's conversation is with, for the screens: every member but this phone, each as [shownAddress] has them. */
    fun people(context: Context, o: JSONObject): List<String> {
        val mine = me(context)
        val known = known(context)
        val held = E2e.held(context)
        return members(o).filter { it.getString("i") != mine }.map { shownAddress(it.getString("i"), it.optString("a"), known, held) }
    }

    /**
     * The members of this phone's groups as people the routes reach (Net.peers has those encryption is on with, and
     * Buddies.peers friends by username: each comes before these, under their own record's address): their name, the
     * address their group lists them under where it is no one else's ([listed]), and the key packets to and from them
     * are sealed with, made from their key and this phone's as a conversation's is. Members of a group this phone has
     * left are not among them.
     */
    fun peers(context: Context, already: Set<String>): List<Map<String, Any?>> {
        val mine = me(context)
        val held = E2e.held(context)
        val out = LinkedHashMap<String, Map<String, Any?>>()
        for (o in all(context)) {
            if (o.optBoolean("gone", false)) continue
            for (m in members(o)) {
                val id = m.getString("i")
                if (id == mine || id in already || id in out) continue
                val pub = runCatching { Base64.getDecoder().decode(m.optString("k")) }.getOrNull()?.takeIf { it.size == 33 && Net.idOf(it) == id } ?: continue
                val pair = E2e.pairKey(context, pub) ?: continue
                out[id] = mapOf("id" to id, "address" to listed(m.optString("a"), held), "key" to Net.netKey(pair))
            }
        }
        return out.values.toList()
    }

    /**
     * The address a member of a group is reached under on the routes: the one the group lists them under ([written],
     * whatever its admin wrote), unless it belongs to a record of this phone's own: a number it holds an encryption
     * record for ([held], by [E2e.norm]), or any `@username`, which only a friend by username's record gives. Then it
     * is nobody's to them, and they are reached by their key alone (found in review, 2026-11-23: an admin could list a
     * stranger under a friend's number, or as "@friend", and the routes found the stranger by it). What the group's
     * screens show is the record as it is ([view]).
     */
    fun listed(written: String, held: Set<String>): String =
        if (written.isEmpty() || written.startsWith("@") || E2e.norm(written) in held) "" else written

    /**
     * Whether [address] is someone this phone is in a group with, and that group's conversation: for the wake. By the
     * address each member is shown under ([shownAddress]): a group that lists someone under a friend's number doesn't
     * take that friend's wake.
     */
    fun threadWith(context: Context, address: String): Long? {
        val want = E2e.norm(address)
        val known = known(context)
        val held = E2e.held(context)
        return all(context).firstOrNull { o -> !o.optBoolean("gone", false) && members(o).any { E2e.norm(shownAddress(it.getString("i"), it.optString("a"), known, held)) == want } }?.optLong("thread", -1)?.takeIf { it > 0 }
    }

    // --- what is written in it -----------------------------------------------------------------------------------------

    /** A set of message rows kept under [name], and adding one to it: the newest [Friends.KEEP] are kept. */
    private fun ids(context: Context, name: String): Set<Long> =
        (prefs(context).getString(name, "") ?: "").split(',').mapNotNull { it.toLongOrNull() }.toSet()

    @Synchronized
    private fun mark(context: Context, name: String, id: Long) {
        val all = (prefs(context).getString(name, "") ?: "").split(',').filter { it.isNotEmpty() }.toMutableList()
        all.add(id.toString())
        prefs(context).edit().putString(name, Friends.kept(all, Friends.KEEP).joinToString(",")).apply()
    }

    /** The group messages that came or went by the routes, and those that are lines about a group, by their rows. */
    fun netIds(context: Context): Set<Long> = ids(context, "net")
    fun noteIds(context: Context): Set<Long> = ids(context, "notes")

    private fun uri(row: Long): Uri = ContentUris.withAppendedId(Telephony.Mms.CONTENT_URI, row)

    /** Writes [words] into the group's conversation in Android's database, as an MMS of one text part. */
    private fun insert(context: Context, o: JSONObject, box: Int, from: String?, words: String, at: Long): Uri? =
        Store(context).insertMms(
            box, o.getLong("thread"), from, listOf(address(o.getString("id"))), emptyList(),
            listOf(Pdu.Part("text/plain", words.toByteArray(), contentLocation = "text.txt", contentId = "text")),
            at / 1000, null, null, null, SubscriptionManager.getDefaultSmsSubscriptionId(),
        )

    /** Words this phone is sending to a group: kept as a group message on its way; its row, for [setRow]. */
    fun storeOut(context: Context, id: String, words: String): Long {
        val o = get(context, id) ?: throw IllegalStateException("No such group")
        val row = insert(context, o, Telephony.Mms.MESSAGE_BOX_OUTBOX, null, words, System.currentTimeMillis()) ?: throw IllegalStateException("Could not save the message")
        val mms = ContentUris.parseId(row)
        mark(context, "net", mms)
        Bus.changed(o.getLong("thread"))
        return mms
    }

    /** What became of a row from [storeOut]: "sent" (the routes took it for the members) or "failed". */
    fun setRow(context: Context, row: Long, state: String) {
        val store = Store(context)
        when (state) {
            "sent" -> store.setMmsBox(uri(row), Telephony.Mms.MESSAGE_BOX_SENT)
            "failed" -> store.setMmsBox(uri(row), Telephony.Mms.MESSAGE_BOX_FAILED)
            else -> return
        }
        Bus.changed(-1)
    }

    /**
     * Words that came to a group from the member named [from]: kept as a group message that arrived, and said, from the
     * address they are shown under ([shownAddress]). One the group listed under no address of theirs is kept too, under
     * a stand-in (it was dropped).
     */
    fun storeIn(context: Context, id: String, from: String, words: String, sentAt: Long) {
        val o = get(context, id) ?: return
        val m = members(o).firstOrNull { it.getString("i") == from } ?: return
        val sender = shownAddress(from, m.optString("a"), known(context), E2e.held(context))
        val row = insert(context, o, Telephony.Mms.MESSAGE_BOX_INBOX, sender, words, System.currentTimeMillis()) ?: return
        mark(context, "net", ContentUris.parseId(row))
        val thread = o.getLong("thread")
        Store(context).setArchived(thread, false)
        Notifier.incoming(context, thread)
        Bus.changed(thread)
    }

    /**
     * A line about the group itself ("Ann added Dan"), kept in its conversation where it happened. It is read
     * already: nothing is said aloud for one.
     */
    fun note(context: Context, id: String, words: String) {
        val o = get(context, id) ?: return
        val row = insert(context, o, Telephony.Mms.MESSAGE_BOX_SENT, null, words, System.currentTimeMillis()) ?: return
        mark(context, "notes", ContentUris.parseId(row))
        Bus.changed(o.getLong("thread"))
    }
}
