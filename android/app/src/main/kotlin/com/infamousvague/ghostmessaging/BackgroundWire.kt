package com.infamousvague.ghostmessaging

/**
 * A chat's background as it travels between phones that both run Uplink (Matt, 2026-11-13: "I want the
 * background to sync for everyone in a chat if they're all using ghost messaging"). There is no server: it goes as a
 * text in the conversation itself, which this app draws as a line ("Maya changed the chat background") and wears,
 * and which any other app would show as its letters. Pure JVM, so [BackgroundWireTest] holds it.
 *
 * `ghost:bg1:` and one of:
 * - `none`: the plain page.
 * - `preset:dusk`: one of the app's washes, by its name (lib/backgrounds.dart).
 * - `color:#RRGGBB`: one colour.
 * - `wash:#RRGGBB,#RRGGBB,#RRGGBB,#RRGGBB`: a wash's top and bottom in the light theme, then in the dark: what
 *   "Match my wallpaper" is on the phone that sent it, since the other phone's wallpaper is its own.
 * - `image`: the picture is the picture of the same message (an MMS).
 */
object BackgroundWire {
    const val TAG = "ghost:bg1:"
    const val NOTE = "Uplink chat background (gogho.st)"

    private val pattern = Regex("ghost:bg1:([a-z]+(?::[A-Za-z0-9#,]+)?)")
    private val hex = Regex("#[0-9A-Fa-f]{6}")

    /** Whether [value] is one of the forms above, whole. */
    fun valid(value: String): Boolean {
        if (value == "none" || value == "image") return true
        val at = value.indexOf(':')
        if (at <= 0) return false
        val rest = value.substring(at + 1)
        return when (value.substring(0, at)) {
            "preset" -> Regex("[a-z]{1,24}").matches(rest)
            "color" -> hex.matches(rest)
            "wash" -> rest.split(',').let { it.size == 4 && it.all(hex::matches) }
            else -> false
        }
    }

    /** The background a text carries, anywhere in it, or null. */
    fun valueIn(body: String): String? = pattern.find(body)?.groupValues?.get(1)?.takeIf(::valid)

    /**
     * The text that carries [value]. With [bare] it is the tag alone: what goes sealed to someone encryption is on
     * with, where a note for other apps to show would only make the sealed text longer.
     */
    fun text(value: String, bare: Boolean = false): String {
        require(valid(value)) { "Not a background: $value" }
        return if (bare) TAG + value else NOTE + "\n" + TAG + value
    }
}
