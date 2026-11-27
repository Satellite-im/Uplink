package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The list of conversations is read a lot at a time (Store.conversationsPage), and every lot is whole in itself (Matt,
 * 2026-11-26: "right now they don't always show the last message"): a conversation Google Messages' bridge has newer
 * words for is on the lot its newest message's date falls in, once, whichever lot Android's own row of it is on. Only
 * the first lot was brought up to date by the bridge, and a later lot's row of the same conversation, as Android has it
 * (its last SMS, however old), was laid over it.
 */
class ListLotTest {
    @Test
    fun aDateIsOnOneLotAndOnlyOne() {
        // Three lots, newest first: down to 500, from below 500 down to 200, and the rest.
        val lots = listOf<Pair<Long?, Long?>>(500L to null, 200L to 500L, null to 200L)
        for (time in listOf(900L, 500L, 499L, 200L, 199L, 0L)) {
            assertEquals("a message dated $time", 1, lots.count { (lower, upper) -> Store.onLot(time, lower, upper) })
        }
        assertTrue(Store.onLot(500, 500, null))
        assertFalse("the row a lot ends on is that lot's, not the next's", Store.onLot(500, 200, 500))
        assertTrue("a list read in one lot has everything", Store.onLot(1, null, null))
    }

    @Test
    fun theBridgesNewerConversationsAreBroughtUpToTheLotTheirDateFallsOn() {
        // Thread 7's last SMS is old (Android lists it on a later lot), and its newest RCS message is dated 800.
        val bridged = listOf(7L to 800L, 3L to 650L, -12L to 620L, 9L to 100L)
        // The first lot has thread 3 already and runs down to 600.
        assertEquals(listOf(7L, -12L), Store.bridgedOnLot(bridged, setOf(3L, 4L), 600, null))
        // The lot after it, down to 50: thread 9 alone, though it isn't among its rows.
        assertEquals(listOf(9L), Store.bridgedOnLot(bridged, setOf(5L), 50, 600))
        // The last lot: nothing of the bridge's is left for it.
        assertEquals(emptyList<Long>(), Store.bridgedOnLot(bridged, setOf(1L), null, 50))
        // Read in one lot: whatever the list's rows don't have.
        assertEquals(listOf(-12L), Store.bridgedOnLot(bridged, setOf(3L, 7L, 9L), null, null))
    }
}
