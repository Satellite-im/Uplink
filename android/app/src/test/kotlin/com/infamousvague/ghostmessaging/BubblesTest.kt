package com.infamousvague.ghostmessaging

import android.app.Notification
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BubblesTest {
    @Test fun onUnlessSwitchedOffFromAndroidEleven() {
        assertTrue("never chosen: on", Bubbles.wanted(null, 30))
        assertTrue(Bubbles.wanted("on", 34))
        assertFalse("switched off in Settings › Notifications", Bubbles.wanted("off", 34))
        assertFalse("Android 10 has no conversation bubbles", Bubbles.wanted("on", 29))
    }

    @Test fun aReadConversationKeepsOnlyABubbleShowing() {
        assertTrue(Bubbles.keepsBubble(Notification.FLAG_BUBBLE or Notification.FLAG_AUTO_CANCEL, wanted = true))
        assertFalse("an ordinary notification goes as before", Bubbles.keepsBubble(Notification.FLAG_AUTO_CANCEL, wanted = true))
        assertFalse("bubbles switched off: it goes", Bubbles.keepsBubble(Notification.FLAG_BUBBLE, wanted = false))
    }

    @Test fun androidsOwnSettingInWords() {
        assertNull("before Android 11", Bubbles.systemState(29, null, true))
        assertEquals("all", Bubbles.systemState(31, 1, null))
        assertEquals("selected", Bubbles.systemState(31, 2, null))
        assertEquals("none", Bubbles.systemState(31, 0, null))
        assertEquals("Android 11, allowed: the chosen conversations", "selected", Bubbles.systemState(30, null, true))
        assertEquals("none", Bubbles.systemState(30, null, false))
    }
}
