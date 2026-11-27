package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A number's key ([ContactKey.of]): one number however it is written, and none for what is nobody's number. */
class ContactKeyTest {
    @Test
    fun oneNumberWrittenThreeWaysSharesAKey() {
        assertEquals("1230001", ContactKey.of("+1 (555) 123-0001"))
        assertEquals("1230001", ContactKey.of("5551230001"))
        assertEquals("1230001", ContactKey.of("123-0001"))
        // With a country's trunk 0, or without.
        assertEquals(ContactKey.of("07700 900123"), ContactKey.of("+44 7700 900123"))
    }

    @Test
    fun aShortCodeIsItsOwnDigits() {
        assertEquals("28849", ContactKey.of("28849"))
        assertEquals("611", ContactKey.of("611"))
    }

    @Test
    fun whatIsNobodysNumberHasNoKey() {
        assertNull(ContactKey.of("AMAZON"))
        assertNull(ContactKey.of("Verify24"))
        assertNull(ContactKey.of("maya@example.com"))
        assertNull(ContactKey.of(""))
        assertNull(ContactKey.of("+ - ()"))
    }

    @Test
    fun whatIsDialledAfterTheNumberIsNoPartOfIt() {
        assertEquals("1230001", ContactKey.of("555-123-0001,123"))
        assertEquals("1230001", ContactKey.of("(555) 123-0001 x42"))
        assertEquals("1230001", ContactKey.of("5551230001;9"))
        assertEquals("555-123-0001", ContactKey.main("555-123-0001,123"))
        // A sender's name that begins with one of those letters is still a name.
        assertNull(ContactKey.of("PayPal"))
        assertNull(ContactKey.of("Wells Fargo"))
    }

    @Test
    fun digitsOfAnotherScriptAreDigits() {
        assertEquals("1230001", ContactKey.of("\u0665\u0665\u0665\u0661\u0662\u0663\u0660\u0660\u0660\u0661"))
    }
}
