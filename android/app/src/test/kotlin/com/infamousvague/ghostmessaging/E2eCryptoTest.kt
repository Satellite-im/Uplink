package com.infamousvague.ghostmessaging

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Two phones, and a third that should read nothing. */
class E2eCryptoTest {
    /** Texts that come plain from someone encryption is on with are counted, and the count is cleared when they seal again. */
    @Test
    fun plainTextsWhileEncryptedAreCounted() {
        val a = E2eCrypto.newKeyPair()
        val b = E2eCrypto.newKeyPair()
        val key = E2eCrypto.conversationKey(a.private, E2eCrypto.publicBytes(a.public), E2eCrypto.publicBytes(b.public))!!
        assertEquals("sealed", E2ePlain.kindOf(E2eCrypto.seal(key, "see you at 7")))
        assertEquals("plain", E2ePlain.kindOf("see you at 7"))
        assertEquals("plain", E2ePlain.kindOf("Your code is 482913"))
        // A key is the app's own text: it says nothing of whether their texts are sealed.
        assertEquals("ours", E2ePlain.kindOf(E2eCrypto.keyText(E2eCrypto.publicBytes(b.public))))
        // One plain text, then another: counted, and warned of until put away.
        var state = E2ePlain.next(0, 0, "plain")
        assertEquals(1 to 0, state)
        assertEquals(1, E2ePlain.unseen(state.first, state.second))
        state = E2ePlain.next(state.first, state.second, "plain")
        assertEquals(2 to 0, state)
        // Put away at two: nothing to show, until the next plain one comes.
        assertEquals(0, E2ePlain.unseen(2, 2))
        state = E2ePlain.next(2, 2, "plain")
        assertEquals(1, E2ePlain.unseen(state.first, state.second))
        // A key or a background in between changes nothing.
        assertEquals(state, E2ePlain.next(state.first, state.second, "ours"))
        // They seal again: there is nothing left to warn of.
        assertEquals(0 to 0, E2ePlain.next(state.first, state.second, "sealed"))
        assertEquals(0, E2ePlain.unseen(0, 0))
    }

    private val alice = E2eCrypto.newKeyPair()
    private val bob = E2eCrypto.newKeyPair()
    private val eve = E2eCrypto.newKeyPair()
    private val a = E2eCrypto.publicBytes(alice.public)
    private val b = E2eCrypto.publicBytes(bob.public)
    private val e = E2eCrypto.publicBytes(eve.public)

    @Test
    fun aKeyTravelsInATextAndComesBackTheSameKey() {
        assertEquals(33, a.size)
        val text = "Uplink encryption key.\n" + E2eCrypto.keyText(a)
        assertArrayEquals(a, E2eCrypto.keyIn(text))
        assertEquals(alice.public, E2eCrypto.publicFrom(a))
        // Many keys, so both parities of y are met.
        repeat(40) {
            val k = E2eCrypto.newKeyPair()
            assertEquals(k.public, E2eCrypto.publicFrom(E2eCrypto.publicBytes(k.public)))
        }
        assertNull(E2eCrypto.keyIn("no key here"))
        assertNull(E2eCrypto.keyIn("ghost:k1:" + "A".repeat(44))) // not a point on the curve (or not a valid prefix)
        assertNull(E2eCrypto.publicFrom(ByteArray(33)))
    }

    @Test
    fun bothPhonesMakeTheSameKeyAndReadEachOther() {
        val ka = E2eCrypto.conversationKey(alice.private, a, b)!!
        val kb = E2eCrypto.conversationKey(bob.private, b, a)!!
        assertArrayEquals(ka, kb)
        assertEquals(32, ka.size)
        val words = "See you at 7 👻 — bring the “cable”\nsecond line"
        val wire = E2eCrypto.seal(ka, words)
        assertTrue(wire.startsWith("ghost:e1:"))
        assertTrue(E2eCrypto.isSealed(wire))
        assertTrue("stays in an SMS's own alphabet", wire.all { it.code < 128 })
        assertEquals(words, E2eCrypto.open(kb, wire))
        // The same words twice are two different texts.
        assertNotEquals(wire, E2eCrypto.seal(ka, words))
    }

    @Test
    fun anotherPhoneReadsNothingAndAChangedTextIsRefused() {
        val ka = E2eCrypto.conversationKey(alice.private, a, b)!!
        val ke = E2eCrypto.conversationKey(eve.private, e, a)!!
        val wire = E2eCrypto.seal(ka, "for bob only")
        assertNull(E2eCrypto.open(ke, wire))
        val at = wire.length - 5
        val flipped = wire.substring(0, at) + (if (wire[at] == 'A') 'B' else 'A') + wire.substring(at + 1)
        assertNull(E2eCrypto.open(ka, flipped))
        assertNull(E2eCrypto.open(ka, "hello"))
        assertNull(E2eCrypto.open(ka, "ghost:e1:AAAA"))
        assertNull(E2eCrypto.open(ka, "ghost:e1:not base64 !!"))
    }

    @Test
    fun theSafetyNumberIsTheSameOnBothPhonesAndDiffersWithSomeoneInTheMiddle() {
        val ab = E2eCrypto.safetyNumber(a, b)
        assertEquals(ab, E2eCrypto.safetyNumber(b, a))
        assertTrue(Regex("^(\\d{5} ){5}\\d{5}$").matches(ab))
        // Eve in the middle: Alice holds Eve's key as Bob's, Bob holds Eve's as Alice's. The numbers differ.
        assertNotEquals(E2eCrypto.safetyNumber(a, e), E2eCrypto.safetyNumber(b, e))
        assertNotEquals(ab, E2eCrypto.safetyNumber(a, e))
        assertNotNull(E2eCrypto.fingerprint(a))
    }

    @Test
    fun aKeyPairSurvivesBeingStored() {
        val restored = E2eCrypto.privateFrom(alice.private.encoded)
        assertArrayEquals(E2eCrypto.conversationKey(alice.private, a, b), E2eCrypto.conversationKey(restored, a, b))
    }
}
