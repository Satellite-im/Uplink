package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The colour shared with Ghost Keyboard ([AccentSync]): whose choice is taken, and the ids the two must agree on. */
class AccentSyncTest {
    @Test fun theNewerChoiceWins() {
        assertEquals("pink", AccentSync.take(mine = 100, theirId = "pink", theirs = 200))
        assertNull(AccentSync.take(mine = 200, theirId = "pink", theirs = 100))
        assertNull("the same time is the same choice", AccentSync.take(mine = 200, theirId = "pink", theirs = 200))
        assertNull("never chosen on the keyboard", AccentSync.take(mine = 0, theirId = "ghost", theirs = 0))
        assertNull("an id not known here", AccentSync.take(mine = 0, theirId = "chartreuse", theirs = 5))
    }

    @Test fun theKeyboardsIdsAreTheBubbleColours() {
        assertEquals(
            listOf("ghost", "ink", "wallpaper", "white", "silver", "gray", "graphite", "blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint"),
            AccentSync.IDS,
        )
    }
}
