package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The invisible hello between two copies of the app ([GhostMark]). */
class GhostMarkTest {
    @Test fun theMarkIsAddedOnceFoundAndTakenOff() {
        val marked = GhostMark.add("See you at 7")
        assertEquals("See you at 7" + GhostMark.MARK, marked)
        assertEquals(marked, GhostMark.add(marked))
        assertTrue(GhostMark.has(marked))
        assertFalse(GhostMark.has("See you at 7"))
        assertEquals("See you at 7", GhostMark.strip(marked))
        assertEquals("See you at 7", GhostMark.strip("See you at 7"))
        // A carrier or an app that adds a line end after it does not hide it.
        assertTrue(GhostMark.has(marked + "\n"))
        assertEquals("See you at 7", GhostMark.strip(marked + " \n"))
        // In the middle of a text (quoted, copied) it is not a hello.
        assertFalse(GhostMark.has(marked + " ok"))
    }

    @Test fun itIsThreeCharactersNoPhoneDraws() {
        assertEquals(3, GhostMark.MARK.length)
        assertTrue(GhostMark.MARK.all { it == '​' || it == '‌' })
    }

    @Test fun itRidesOnlyOnWordsSomeoneTyped() {
        assertTrue(GhostMark.mayCarry("See you at 7"))
        assertTrue(GhostMark.mayCarry("ok 👍"))
        // A reaction ends in the quoted message, and other phones match it to the letter.
        assertFalse(GhostMark.mayCarry("Loved “See you at 7”"))
        assertFalse(GhostMark.mayCarry("❤️ to \"See you at 7\""))
        // This app's own texts.
        assertFalse(GhostMark.mayCarry("ghost:bg1:preset:dusk"))
        assertFalse(GhostMark.mayCarry("Uplink encryption key.\nghost:k1:A5/eqOmibtM2OjJPdsSplFFwxOYeUu9eDqXfbBUfI5rC"))
        assertFalse(GhostMark.mayCarry("   "))
    }
}
