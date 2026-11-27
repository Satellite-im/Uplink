package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Friends.kt apart from Android: knowing the wake among the data texts, and which rows are remembered. */
class FriendsTest {
    private fun packet(flags: Int, json: String): ByteArray = byteArrayOf((0x10 or flags).toByte()) + ByteArray(16) { it.toByte() } + json.toByteArray()

    @Test fun theWakeIsKnown() {
        // As lib/net/packet.dart wraps an envelope of kind `wake` sent in the clear (test/friends_test.dart holds
        // the Dart side to the same shape).
        assertTrue(Friends.isWake(packet(0, """{"i":"0011223344556677","k":"wake","a":1794000000000,"n":1}""")))
    }

    @Test fun nothingElseIsTakenForIt() {
        // Another kind; one that is sealed (its bytes are not JSON, and it is not looked into); a piece of a longer
        // packet; a packet with no envelope; nothing at all.
        assertFalse(Friends.isWake(packet(0, """{"i":"0011223344556677","k":"ping","a":1}""")))
        assertFalse(Friends.isWake(packet(1, """{"i":"0011223344556677","k":"wake","a":1}""")))
        assertFalse(Friends.isWake(packet(2, """{"i":"0011223344556677","k":"wake","a":1}""")))
        assertFalse(Friends.isWake(packet(0, "not json")))
        assertFalse(Friends.isWake(ByteArray(17)))
        assertFalse(Friends.isWake(ByteArray(0)))
    }

    @Test fun theNewestRowsAreRemembered() {
        assertEquals(listOf("1", "2", "3"), Friends.kept(listOf("1", "2", "3"), 5))
        assertEquals(listOf("3", "4", "5"), Friends.kept(listOf("1", "2", "3", "4", "5"), 3))
    }
}
