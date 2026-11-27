package com.infamousvague.ghostmessaging

/**
 * How two phones with Uplink find each other (Matt, 2026-11-13: "I'd like to instead be able to detect if
 * both users are using ghost messaging and enable encryption in the chat", then "If we detect both users are using
 * ghost it should show a banner that can be dismissed asking the user to enable encryption for better security").
 * There is no server to ask, so the app says it is there in the texts themselves: three invisible characters at the
 * end of a text, which another copy of the app recognises and every other app draws as nothing. Pure JVM
 * ([GhostMarkTest]).
 *
 * The mark rides only where it costs nothing: on a text that stays the same number of SMS with it (the sender
 * checks), at most once a day to a person, and never on a text another phone reads to the letter (a reaction, one of
 * this app's own `ghost:` texts). It is only a hello: it carries no key, proves nothing, and nothing is sent because
 * of it. A phone that sees it remembers that the person has the app, and their conversation then offers encryption
 * in a banner, which the person turns on or dismisses.
 */
object GhostMark {
    /** Zero-width space, zero-width non-joiner, zero-width space: drawn as nothing by every phone's texting app. */
    const val MARK = "​‌​"

    private val quotes = setOf('"', '”', '“', '\'', '’')

    fun has(text: String): Boolean = text.trimEnd(' ', '\n', '\r', '\t').endsWith(MARK)

    /** [text] without the mark, as it is shown and searched. */
    fun strip(text: String): String = if (has(text)) text.trimEnd(' ', '\n', '\r', '\t').removeSuffix(MARK) else text

    fun add(text: String): String = if (has(text)) text else text + MARK

    /**
     * Whether [text] may carry the mark at all: words someone typed, not one of this app's own texts (a key, a sealed
     * text, a background), and not a reaction, which ends in the quoted message and which other phones match to the
     * letter.
     */
    fun mayCarry(text: String): Boolean {
        val words = text.trimEnd()
        if (words.isEmpty() || text.contains("ghost:")) return false
        return words.last() !in quotes
    }
}
