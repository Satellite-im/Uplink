package com.infamousvague.ghostmessaging

/**
 * How one of the app's stickers is named as it travels (Matt, 2026-11-13: "generate 4 sticker packs using our ghost
 * mascot"). A sticker goes as a picture message like any other, so that every phone can show it; its file's name,
 * `ghost-sticker-<pack>-<number>.png`, is all that tells this app to draw it as a sticker (small, on the page, with
 * no bubble) and to call it one in the list of conversations. To any other app it is a picture.
 */
object Stickers {
    private const val MARK = "ghost-sticker"

    /** The file name for the sticker [name] (its pack and number, `love-03`), with nothing in it a header could choke on. */
    fun file(name: String): String {
        val safe = name.filter { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' }.take(40).ifEmpty { "sticker" }
        return "$MARK-$safe.png"
    }

    /**
     * Whether [picture] is a sticker that moves: an animated PNG, which says so with an `acTL` chunk before its
     * picture begins (Matt, 2026-11-14: "Update the sticker pack to use the animated sprites from the desktop").
     */
    fun moves(picture: ByteArray): Boolean {
        val png = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte())
        if (picture.size < 64 || !picture.copyOfRange(0, 4).contentEquals(png)) return false
        // Chunks from the eighth byte: four of length, four of name, the data, four of checksum.
        var at = 8
        while (at + 8 <= picture.size) {
            val length = ((picture[at].toInt() and 0xFF) shl 24) or ((picture[at + 1].toInt() and 0xFF) shl 16) or ((picture[at + 2].toInt() and 0xFF) shl 8) or (picture[at + 3].toInt() and 0xFF)
            val name = String(picture, at + 4, 4, Charsets.US_ASCII)
            if (name == "acTL") return true
            if (name == "IDAT" || name == "IEND" || length < 0) return false
            at += 12 + length
        }
        return false
    }

    /** Whether a picture part called [name] is one of the app's stickers. */
    fun isSticker(name: String?): Boolean = name != null && name.substringAfterLast('/').startsWith(MARK)
}
