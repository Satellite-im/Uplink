package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** A chat background as a text between two phones with the app ([BackgroundWire]). */
class BackgroundWireTest {
    private val values = listOf("none", "image", "preset:dusk", "color:#DCE8FB", "wash:#EEF2F7,#DCE5F0,#0F141B,#172230")

    @Test fun everyFormIsReadBackFromItsText() {
        for (v in values) {
            assertTrue(v, BackgroundWire.valid(v))
            assertEquals(v, BackgroundWire.valueIn(BackgroundWire.text(v)))
            assertEquals(v, BackgroundWire.valueIn(BackgroundWire.text(v, bare = true)))
        }
    }

    @Test fun theBareTextIsTheTagAlone() {
        assertEquals("ghost:bg1:preset:mint", BackgroundWire.text("preset:mint", bare = true))
        assertTrue(BackgroundWire.text("preset:mint").startsWith(BackgroundWire.NOTE))
    }

    @Test fun aTextWithItsNoteFitsOneSms() {
        // 160 GSM characters is one SMS; the longest form is the wash.
        for (v in values) assertTrue(v, BackgroundWire.text(v).length <= 160)
    }

    @Test fun whatIsNotABackgroundIsNotTaken() {
        for (bad in listOf("", "preset:", "preset:Dusk9", "color:blue", "color:#12345", "wash:#EEF2F7,#DCE5F0", "image:/data/x.jpg", "picture", "preset:dusk:extra")) {
            assertFalse(bad, BackgroundWire.valid(bad))
        }
        assertNull(BackgroundWire.valueIn("See you at 7"))
        assertNull(BackgroundWire.valueIn("ghost:bg1:color:blue"))
        assertNull(BackgroundWire.valueIn("ghost:k1:A5/eqOmibtM2OjJPdsSplFFwxOYeUu9eDqXfbBUfI5rC"))
        assertThrows(IllegalArgumentException::class.java) { BackgroundWire.text("color:blue") }
    }

    @Test fun itIsFoundAmongOtherWords() {
        assertEquals("color:#1B2433", BackgroundWire.valueIn("hey\nghost:bg1:color:#1B2433\nbye"))
        // What follows a whole value is not part of it.
        assertEquals("none", BackgroundWire.valueIn("ghost:bg1:none."))
    }
}
