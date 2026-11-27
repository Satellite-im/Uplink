package com.infamousvague.ghostmessaging

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A link pressed in a message opens only where it is a web address (Arriving.openLink; lib/links.dart finds them). */
class LinksTest {
    @Test
    fun onlyAWebAddressIsOpened() {
        assertTrue(Arriving.isWebAddress("https://example.com/tickets"))
        assertTrue(Arriving.isWebAddress("http://example.com"))
        assertTrue(Arriving.isWebAddress(" HTTPS://Example.com/a?b=1#c "))
        assertTrue(Arriving.isWebAddress("https://user@example.com:8443/x"))
        for (no in listOf("", "example.com", "javascript:alert(1)", "tel:+15551230001", "file:///etc/passwd", "intent://x#Intent;end", "content://sms/1", "https://", "https://www.", "http://localhost", "ghostmsg://pair/abc", "https://exa mple.com")) {
            assertFalse(no, Arriving.isWebAddress(no))
        }
    }
}
