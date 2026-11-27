package com.infamousvague.ghostmessaging

/**
 * A message's words without their formatting markers, for a notification's preview (GMFB-35): "**bold**" reads
 * "bold", a "> " quote loses its marker, a ||spoiler|| shows as ▒s, a [words](https://…) link as its words. The app
 * draws the formatting (lib/message_format.dart, whose rules these follow); a notification can't, so it says the words
 * plainly. Code and links are left as they are written: nothing in them is a marker. Pure JVM ([MarkdownPlainTest]).
 */
object MarkdownPlain {
    // What is set aside before any marker is looked for: a fenced block, a [words](address) link, a code span, a
    // bare address.
    private val fence = Regex("```[A-Za-z0-9+#.\\-]*\\n?([\\s\\S]*?)\\n?```")
    private val masked = Regex("\\[([^\\[\\]\\n]+)]\\((https?://[^\\s)]+)\\)")
    private val code = Regex("`([^`\\n]+)`")
    private val link = Regex("(?i)(https?://\\S+|www\\.\\S+)")
    // The markers. One only counts hard against the words it wraps; a single * or _ never inside a word.
    private val spoiler = Regex("\\|\\|(?=\\S)([^\\n]*?\\S)\\|\\|")
    private val bold = Regex("\\*\\*(?=\\S)([^\\n]*?\\S)\\*\\*")
    private val strike = Regex("~~(?=\\S)([^\\n]*?\\S)~~")
    private val star = Regex("(?<![\\p{L}\\p{N}*])\\*(?=[^\\s*])([^\\n*]*?[^\\s*])\\*(?![\\p{L}\\p{N}*])")
    private val under = Regex("(?<![\\p{L}\\p{N}_])_(?=[^\\s_])([^\\n_]*?[^\\s_])_(?![\\p{L}\\p{N}_])")
    private val quote = Regex("(?m)^> (?=\\S)")
    // A marker with a backslash before it is the character itself; and the place of something held, which is its
    // number between two characters no message is written with.
    private val escape = Regex("\\\\([*_~`|\\[\\]>\\\\])")
    private val held = Regex("(\\d+)")

    /** [text] as a notification says it. */
    fun strip(text: String): String {
        if (text.length > 20000 || text.none { it in "*_~`|[>\\" }) return text
        // Code, links and escaped characters are taken out first and put back last, so no marker is found in them.
        val kept = mutableListOf<String>()
        fun hold(s: String): String { kept.add(s); return "${kept.size - 1}" }
        var s = text
        s = fence.replace(s) { m -> if (m.groupValues[1].isBlank()) m.value else hold(m.groupValues[1]) }
        s = masked.replace(s) { m ->
            val words = m.groupValues[1]
            // Words that are an address themselves stay as written, as the app draws them.
            if (link.containsMatchIn(words) || Regex("\\S\\.[A-Za-z]{2,}").containsMatchIn(words)) m.value else words
        }
        s = code.replace(s) { m -> hold(m.groupValues[1]) }
        s = link.replace(s) { m ->
            // Markers after a link close formatting round it, as the app reads them.
            val whole = m.value
            val end = whole.trimEnd { it in "*_~|`.,;:!?'\"" }.length
            hold(whole.substring(0, end)) + whole.substring(end)
        }
        s = escape.replace(s) { m -> hold(m.groupValues[1]) }
        s = spoiler.replace(s) { m -> "▒".repeat(minOf(m.groupValues[1].length, 8)) }
        // Twice, for one kind of formatting inside another.
        repeat(2) {
            s = bold.replace(s) { m -> m.groupValues[1] }
            s = strike.replace(s) { m -> m.groupValues[1] }
            s = star.replace(s) { m -> m.groupValues[1] }
            s = under.replace(s) { m -> m.groupValues[1] }
        }
        s = quote.replace(s, "")
        // What was held, put back (a code span may hold a link that was held first).
        repeat(3) { s = held.replace(s) { m -> kept.getOrNull(m.groupValues[1].toInt()) ?: "" } }
        return s
    }
}
