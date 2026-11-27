package com.infamousvague.ghostmessaging

import org.json.JSONArray
import org.json.JSONObject
import java.util.regex.Pattern

/**
 * Whether a text's notification is held back because the list hides it (GMFB-18, Matt, Android 0.12.3: "Spam messages
 * still sending notifications. If we dont have a specific kind of message enabled like political messages we shouldn't
 * get notified via sms for those messages").
 *
 * The rules are the app's own, written by lib/plugins/notify_hush.dart into the "ui" preferences (`notify_hush`) from
 * the person's choices: the Kinds of text plugin's kinds that are on, each hidden or shown by the filter, and the Spam
 * filter's signs while Spam is hidden; and the conversations filed by hand ("Not political", "Move to Spam"). Nothing
 * here knows a pattern of its own: they are read from that choice, and this and the Dart side are held to
 * test/notify_hush_vectors.json. Before the app has written them (its first start) nothing is held back.
 */
object NotifyHush {
    /** The key the rules are kept under in the "ui" preferences. */
    const val PREF = "notify_hush"

    // The rules as last read, and the text they were read from: read again only when that changes. Each pattern is
    // compiled once.
    private var parsedFrom: String? = null
    private var parsed: JSONObject? = null
    private val patterns = HashMap<String, Pattern?>()

    /** The rules [raw] holds; null where there are none yet or they cannot be read. */
    private fun rules(raw: String?): JSONObject? {
        if (raw.isNullOrBlank()) return null
        if (raw != parsedFrom) {
            parsed = try { JSONObject(raw) } catch (_: Exception) { null }
            parsedFrom = raw
        }
        return parsed
    }

    /** A pattern as Dart's RegExp(source, caseSensitive: false) reads it; null where Java cannot read it. */
    private fun pattern(source: String): Pattern? = synchronized(patterns) {
        patterns.getOrPut(source) {
            try { Pattern.compile(source, Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE) } catch (_: Exception) { null }
        }
    }

    /** Whether the pattern is found anywhere in [text]; never where it could not be read. */
    private fun has(source: String, text: String) = pattern(source)?.matcher(text)?.find() == true

    /** A word or pattern of its own, never part of a longer word: TextKind._re's wrap, and spam.dart's _hasWord. */
    private fun word(source: String, text: String) = has("(?<![a-z0-9])(?:$source)(?![a-z0-9])", text)

    private fun JSONArray?.strings(): List<String> = if (this == null) emptyList() else (0 until length()).mapNotNull { optString(it, null) }

    /** Whether one of [senders] is on [list]: a number by its last ten digits, anything else by its words (senderListed). */
    fun listed(senders: List<String>, list: List<String>): Boolean {
        for (want in list) {
            val digits = want.filter { it.isDigit() }
            for (s in senders) {
                val have = s.filter { it.isDigit() }
                if (digits.length >= 4 && have.length >= 4) {
                    if (digits.takeLast(10) == have.takeLast(10)) return true
                } else if (s.lowercase().contains(want.lowercase())) {
                    return true
                }
            }
        }
        return false
    }

    /** judgeSpam (lib/plugins/spam.dart) on [text] from [senders], by the rules written out. */
    fun spam(s: JSONObject, text: String, senders: List<String>): Boolean {
        if (listed(senders, s.optJSONArray("neverSenders").strings())) return false
        if (s.optJSONArray("neverWords").strings().any { word(it, text) }) return false
        if (listed(senders, s.optJSONArray("alwaysSenders").strings())) return true
        if (s.optJSONArray("alwaysWords").strings().any { word(it, text) }) return true
        // Otherwise by its signs: each one found counts one (a strong one two, where that is on), against what is
        // needed. A short code is a sender of four to six digits.
        val short = senders.any { Regex("^\\d{4,6}$").matches(it.replace(Regex("[\\s-]"), "")) }
        val double = s.optBoolean("strongDouble", true)
        var score = 0
        val rules = s.optJSONArray("rules") ?: JSONArray()
        for (i in 0 until rules.length()) {
            val r = rules.getJSONObject(i)
            // A company naming itself from its own short code is just the company.
            if (short && r.optString("id") == "brand") continue
            val words = if (r.isNull("words")) null else r.optString("words")
            val sender = if (r.isNull("sender")) null else r.optString("sender")
            val hit = (words != null && has(words, text)) || (sender != null && senders.any { has(sender, it) })
            if (hit) score += if (r.optBoolean("strong") && double) 2 else 1
        }
        // signInCode in Dart is Notifier.otp here; both are held to test/code_vectors.json.
        val needed = s.optInt("base", 2) +
            (if (s.optBoolean("codesLenient") && Notifier.otp(text) != null) 1 else 0) +
            (if (s.optBoolean("shortLenient") && short) 1 else 0)
        return score >= needed
    }

    /**
     * Whether the text [text] arriving in [thread] (from [senders], a group where [group]) is one the list hides, so
     * no notification is made for it. Only where every sender is a stranger ([stranger]): a contact's texts are never
     * sorted. [raw] is the `notify_hush` choice.
     */
    fun hushes(raw: String?, thread: Long, senders: List<String>, group: Boolean, stranger: Boolean, text: String): Boolean {
        val rules = rules(raw) ?: return false
        // Filed by hand: "Not …" lets it through for good, a move into a hidden kind keeps it silent.
        val filed = rules.optJSONObject("filed")
        if (filed != null && filed.has(thread.toString())) return filed.optBoolean(thread.toString())
        if (!stranger || text.isBlank()) return false
        // A sign-in code is the Codes section's, asked before any kind.
        if (Notifier.otp(text) != null) return false
        // A conversation from a linked network (not a text) has a thread number at or below minus 2^40. Each set of
        // rules says whether it looks at groups and at networks.
        val network = thread <= -(1L shl 40)
        fun looks(o: JSONObject) = !(group && !o.optBoolean("groups", true)) && !(network && !o.optBoolean("networks", true))
        val spam = if (rules.isNull("spam")) null else rules.optJSONObject("spam")
        val kinds = if (rules.isNull("kinds")) null else rules.optJSONObject("kinds")
        var looksSpam: Boolean? = null
        fun isSpam() = looksSpam ?: (spam != null && spam(spam, text, senders)).also { looksSpam = it }
        if (kinds != null && looks(kinds)) {
            val weakNeeded = kinds.optInt("weakNeeded", 2)
            val spamFirst = kinds.optBoolean("spamFirst", true)
            val list = kinds.optJSONArray("list") ?: JSONArray()
            for (i in 0 until list.length()) {
                val k = list.getJSONObject(i)
                if (!kindMatches(k, text, weakNeeded)) continue
                // A shown kind does not take a text the Spam filter would call spam: it goes on to Spam.
                if (spamFirst && k.optBoolean("notSpam") && isSpam()) continue
                return k.optBoolean("hide")
            }
        }
        if (spam != null && looks(spam) && isSpam()) return spam.optBoolean("hide")
        return false
    }

    /** TextKind.matches: one strong sign, one of the person's words, or [weakNeeded] of the others (none where 0). */
    fun kindMatches(k: JSONObject, text: String, weakNeeded: Int): Boolean {
        if (k.optJSONArray("strong").strings().any { word(it, text) }) return true
        if (k.optJSONArray("words").strings().any { word(it, text) }) return true
        if (weakNeeded <= 0) return false
        var n = 0
        for (w in k.optJSONArray("weak").strings()) if (word(w, text) && ++n >= weakNeeded) return true
        return false
    }

    /** Every pattern in [raw] Java could not read: none, or the two sides do not agree. For the tests. */
    fun unreadable(raw: String): List<String> {
        val out = ArrayList<String>()
        val r = JSONObject(raw)
        r.optJSONObject("kinds")?.optJSONArray("list")?.let { list ->
            for (i in 0 until list.length()) {
                val k = list.getJSONObject(i)
                for (s in k.optJSONArray("strong").strings() + k.optJSONArray("weak").strings() + k.optJSONArray("words").strings()) {
                    if (pattern("(?<![a-z0-9])(?:$s)(?![a-z0-9])") == null) out.add(s)
                }
            }
        }
        r.optJSONObject("spam")?.optJSONArray("rules")?.let { rules ->
            for (i in 0 until rules.length()) {
                val o = rules.getJSONObject(i)
                for (f in listOf("words", "sender")) if (!o.isNull(f) && pattern(o.getString(f)) == null) out.add(o.getString(f))
            }
        }
        return out
    }
}
