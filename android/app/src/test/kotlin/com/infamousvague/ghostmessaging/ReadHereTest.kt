package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A conversation read in Uplink is read in its list, whatever Android's database says: beside Google Messages it takes
 * no writes from Uplink (Matt, 2026-11-16: "Rcs messages are not being marked as read when i view the message group").
 */
class ReadHereTest {
    private fun row(id: Long, date: Long, unread: Boolean) = mapOf<String, Any?>("id" to id, "date" to date, "unread" to unread)

    @Test
    fun readHereClearsWhatCameBeforeAndKeepsWhatCameAfter() {
        val rows = mutableListOf(row(750, 1_000, true), row(751, 3_000, true), row(752, 1_000, true), row(753, 500, false))
        Store.readHere(rows, mapOf(750L to 2_000L, 751L to 2_000L, 753L to 2_000L))
        assertEquals(listOf(false, true, true, false), rows.map { it["unread"] })
    }

    @Test
    fun nothingReadHereChangesNothing() {
        val rows = mutableListOf(row(1, 1_000, true))
        Store.readHere(rows, emptyMap())
        assertEquals(true, rows.single()["unread"])
    }
}
