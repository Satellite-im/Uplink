package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A group's notification is kept in the group, never in the one-to-one of whoever wrote (GmBridge.pickThread; Matt,
 * 2026-11-17: "When a user sends a message in an RCS group chat we get notified in our dm text conversation").
 */
class GroupNoticeTest {
    @Test
    fun aGroupGoesToItsGroupOrAThreadOfItsOwnNeverToTheWritersThread() {
        val dm = 4L
        // Google Messages named only the newest writer: their one-to-one is what the addresses come to.
        assertEquals(517L, GmBridge.pickThread(group = true, named = 517L, synthetic = -99L) { dm })
        assertEquals(-99L, GmBridge.pickThread(group = true, named = null, synthetic = -99L) { dm })
        // A one-to-one is still found by its person.
        assertEquals(dm, GmBridge.pickThread(group = false, named = 517L, synthetic = -99L) { dm })
    }

    @Test
    fun aGroupIsOneGoogleMessagesSaysIsOrOneWithTwoWriters() {
        assertTrue(GmBridge.looksLikeGroup(flagged = true, title = "Crew", senders = listOf("Jo")))
        assertTrue(GmBridge.looksLikeGroup(flagged = false, title = "Crew", senders = listOf("Jo", "Sam")))
        assertFalse(GmBridge.looksLikeGroup(flagged = false, title = "Mom", senders = listOf("Mom", "Mom")))
        // A contact kept under a nickname stays a one-to-one.
        assertFalse(GmBridge.looksLikeGroup(flagged = false, title = "Mama", senders = listOf("Mom")))
    }

    // Matt, 2026-11-18: "when i get messages in an RCS group chat it still shows me the "attachement" and "Sms message
    // from jade"": a picture message still coming down is told of with a stand-in, and kept only once it is had.
    @Test
    fun aPictureMessageStillComingDownIsNotKeptYet() {
        assertTrue(GmBridge.downloading("incoming_auto_downloading"))
        assertTrue(GmBridge.downloading("INCOMING_RETRYING_AUTO_DOWNLOAD"))
        assertTrue(GmBridge.downloading("incoming_manual_downloading"))
        assertTrue(GmBridge.downloading("incoming_awaiting_auto_download"))
        assertFalse(GmBridge.downloading("incoming_complete"))
        assertFalse("one that will not come by itself is said so instead", GmBridge.downloading("incoming_yet_to_manual_download"))
        assertFalse(GmBridge.downloading("outgoing_sending"))
        assertEquals(null, GmBridge.notDownloaded("incoming_complete"))
        assertTrue(GmBridge.notDownloaded("incoming_yet_to_manual_download")!!.contains("Google Messages"))
    }
}
