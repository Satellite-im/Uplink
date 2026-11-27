package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Matt, 2026-11-26: "The most recent message doesnt match what's actually sent as the last message on chats and some
 * RCS images are just displaying as "attachment"". Google Messages' notification for a picture says "Photo" or
 * "Attachment" in place of it; kept as words, that was a bubble of its own and the list's last line.
 */
class BridgedPictureTest {
    @Test fun standInsAreKnown() {
        for (s in listOf("Photo", "Attachment", "📷 Photo", "Image", "Sent an image", "Sent a photo.", "SMS message from Jade", "MMS message from +1 555 0100", "Video", "Sticker"))
            assertTrue(s, GmBridge.standIn(s))
    }

    @Test fun wordsAreNotStandIns() {
        for (s in listOf("photo of the dog", "look at this attachment I made", "", "ok", "Sent you the photo yesterday"))
            assertFalse(s, GmBridge.standIn(s))
    }

    @Test fun aPictureIsTheNotificationsPhoto() {
        // The notification said "Photo"; the on-phone connection has the picture, with no words.
        assertTrue(GmBridge.sameMessage("Photo", notedMedia = false, web = "", webMedia = true))
        assertTrue(GmBridge.sameMessage("", notedMedia = true, web = "", webMedia = true))
        assertTrue(GmBridge.sameMessage("look", notedMedia = false, web = "look", webMedia = false))
        // Words are not a picture, nor a picture words.
        assertFalse(GmBridge.sameMessage("ok", notedMedia = false, web = "", webMedia = true))
        assertFalse(GmBridge.sameMessage("Photo", notedMedia = false, web = "", webMedia = false))
    }

    @Test fun theListSaysWhatItIs() {
        assertEquals("Picture", GmBridge.summary("Attachment", listOf("image/jpeg")))
        assertEquals("Picture", GmBridge.summary("", listOf("image/png")))
        assertEquals("Video", GmBridge.summary("", listOf("video/mp4")))
        assertEquals("Voice message", GmBridge.summary("", listOf("audio/ogg")))
        assertEquals("Picture", GmBridge.summary("Photo", emptyList()))
        assertEquals("Picture message", GmBridge.summary("SMS message from Jade", emptyList()))
        assertEquals("nice!", GmBridge.summary("nice!", listOf("image/jpeg")))
        assertEquals("", GmBridge.summary("", emptyList()))
    }

    @Test fun aGroupsRowHasItsStandInsNewest() {
        val rows = mutableListOf<Map<String, Any?>>(
            mapOf("id" to 7L, "date" to 1_000L, "snippet" to "older", "unread" to false),
            mapOf("id" to 8L, "date" to 5_000L, "snippet" to "other", "unread" to false),
        )
        val n = Store.Newest()
        n.carry(7L, 3_000L, "the newest", unread = true)
        n.carry(7L, 2_000L, "between", unread = false)
        n.carry(8L, 4_000L, "older than its own", unread = false)
        assertTrue(n.into(rows))
        assertEquals("the newest", rows[0]["snippet"])
        assertEquals(3_000L, rows[0]["date"])
        assertEquals(true, rows[0]["unread"])
        assertEquals("other", rows[1]["snippet"])
        assertEquals(5_000L, rows[1]["date"])
    }
}
