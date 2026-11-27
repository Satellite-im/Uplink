package com.infamousvague.ghostmessaging

/**
 * What a phone number is found by among the contacts (Store.knownNumbers; Matt, 2026-11-13: "Users with a ton of
 * messages stored on their phone are taking forever to load"). The contacts' numbers are read once and kept by this
 * key, so that naming a conversation's number is a look in a table and not a question to Android; the numbers under
 * one key are then compared whole (Store.sameNumber), since a key is only where to look.
 */
object ContactKey {
    /** [number] without what is dialled after it: a pause, a wait or an extension, and what follows. */
    fun main(number: String): String = number.takeWhile { it !in ",;pPwWxX" }

    /**
     * [number]'s last seven digits, or all of them where it has fewer: "+1 (555) 123-0001", "5551230001" and
     * "123-0001" share one, as Android's own comparison takes them for one number. Null for what is nobody's phone
     * number: a sender's name ("AMAZON"), an email address, nothing at all.
     */
    fun of(number: String): String? {
        if (number.contains('@')) return null
        val main = main(number)
        if (main.any { it.isLetter() }) return null
        val digits = StringBuilder()
        for (ch in main) {
            val d = Character.digit(ch, 10)   // digits of any script, as a contact may be written
            if (d >= 0) digits.append(d)
        }
        if (digits.isEmpty()) return null
        return if (digits.length > 7) digits.substring(digits.length - 7) else digits.toString()
    }
}
