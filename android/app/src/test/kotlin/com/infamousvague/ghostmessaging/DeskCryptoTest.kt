package com.infamousvague.ghostmessaging

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The phone's sealing for a paired computer, held to examples a third implementation made (tool/desk_vectors.mjs,
 * Node's own cryptography): the Mac's Dart is held to the same file (test/desk_crypto_test.dart), so the two agree.
 */
class DeskCryptoTest {
    private val v = JSONObject(File("../../test/desk_vectors.json").readText())
    private val input = v.getJSONObject("input")
    private fun bytes(name: String) = DeskCrypto.unhex(v.getString(name))
    private fun given(name: String) = DeskCrypto.unhex(input.getString(name))

    private val phonePrivate = DeskCrypto.privateFromScalar(given("phonePrivate"))
    private val deskPrivate = DeskCrypto.privateFromScalar(given("deskPrivate"))
    private val pairKey = DeskCrypto.pairKey(phonePrivate, bytes("phonePublic"), bytes("deskPublic"), given("secret"))!!

    @Test
    fun thePairingsKeyIsTheExamplesAndTheSameFromBothSides() {
        assertEquals(v.getString("pairKey"), DeskCrypto.hex(pairKey))
        val fromTheDesk = DeskCrypto.pairKey(deskPrivate, bytes("deskPublic"), bytes("phonePublic"), given("secret"))!!
        assertArrayEquals(pairKey, fromTheDesk)
        assertEquals(v.getString("id"), DeskCrypto.id(pairKey))
        assertEquals(v.getString("relayChannel"), DeskCrypto.relayChannel(pairKey))
        assertEquals(v.getString("relayToken"), DeskCrypto.relayToken(pairKey))
        assertEquals(v.getString("code"), DeskCrypto.code(pairKey))
        assertEquals(6, DeskCrypto.code(pairKey).length)
    }

    @Test
    fun withoutTheQrCodesSecretTheKeyIsAnother() {
        // Someone who carried the phone's public key and swapped nothing, but never saw the screen: same two public
        // keys, no secret, another key.
        val other = DeskCrypto.pairKey(phonePrivate, bytes("phonePublic"), bytes("deskPublic"), ByteArray(16))!!
        assertFalse(pairKey.contentEquals(other))
        // And one who swapped the phone's key for their own: the computer's key with them is not the phone's.
        val eve = E2eCrypto.newKeyPair()
        val swapped = DeskCrypto.pairKey(deskPrivate, bytes("deskPublic"), E2eCrypto.publicBytes(eve.public), given("secret"))!!
        assertFalse(pairKey.contentEquals(swapped))
        assertNull(DeskCrypto.pairKey(phonePrivate, bytes("phonePublic"), ByteArray(33), given("secret")))
    }

    @Test
    fun whatTheSecretAloneMakesIsTheExamples() {
        assertEquals(v.getString("pairingId"), DeskCrypto.pairingId(given("secret")))
        assertEquals(v.getString("pairingChannel"), DeskCrypto.pairingChannel(given("secret")))
        assertEquals(v.getString("pairingToken"), DeskCrypto.pairingToken(given("secret")))
    }

    @Test
    fun aQrCodeIsReadAndOnesThatAreNotOursAreRefused() {
        val offer = DeskCrypto.parseOffer(v.getString("offerText"))!!
        assertArrayEquals(bytes("deskPublic"), offer.key)
        assertArrayEquals(given("secret"), offer.secret)
        assertEquals("Matt's MacBook", offer.name)
        assertEquals("both", offer.mode)
        assertEquals("wss://ghost-sms.com/relay", offer.relay)
        // Written here and read back.
        val again = DeskCrypto.parseOffer(DeskCrypto.offerText(offer))!!
        assertArrayEquals(offer.key, again.key)
        assertEquals(offer.relay, again.relay)
        // As the link the computer's QR code holds, which the phone's camera opens: the same offer.
        val linked = DeskCrypto.parseOffer(v.getString("offerLink"))!!
        assertArrayEquals(offer.key, linked.key)
        assertArrayEquals(offer.secret, linked.secret)
        assertEquals(offer.name, linked.name)
        assertTrue(DeskCrypto.isOffer(v.getString("offerLink")) && DeskCrypto.isOffer(v.getString("offerText")) && DeskCrypto.isOffer(" GhostMsg://pair/abc"))
        assertFalse(DeskCrypto.isOffer("https://example.com/pair/abc"))
        assertNull(DeskCrypto.parseOffer("ghostmsg://pair/"))
        assertNull(DeskCrypto.parseOffer("ghostmsg://other/" + v.getString("offerLink").substringAfterLast('/')))
        assertNull(DeskCrypto.parseOffer("https://example.com"))
        assertNull(DeskCrypto.parseOffer("GHOSTPAIR1:not base64 !!"))
        assertNull(DeskCrypto.parseOffer("GHOSTPAIR1:e30")) // {}
        // A key that is no point on the curve, a secret of the wrong length, a way of connecting there is not.
        val bad = { change: (JSONObject) -> Unit ->
            val o = JSONObject(v.getJSONObject("offer").toString()).also(change)
            DeskCrypto.OFFER_TAG + java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(o.toString().toByteArray())
        }
        assertNull(DeskCrypto.parseOffer(bad { it.put("k", java.util.Base64.getEncoder().encodeToString(ByteArray(33))) }))
        assertNull(DeskCrypto.parseOffer(bad { it.put("s", "AAAA") }))
        assertNull(DeskCrypto.parseOffer(bad { it.put("m", "carrier pigeon") }))
        assertNotNull(DeskCrypto.parseOffer(bad { it.put("m", "local") }))
    }

    @Test
    fun aConnectionsKeysAndFramesAreTheExamples() {
        val phoneEphemeral = DeskCrypto.privateFromScalar(given("phoneEphemeral"))
        val keys = DeskCrypto.sessionKeys(pairKey, given("deskNonce"), given("phoneNonce"), phoneEphemeral, bytes("deskEphemeralPublic"))!!
        assertEquals(v.getString("deskKey"), DeskCrypto.hex(keys.first))
        assertEquals(v.getString("phoneKey"), DeskCrypto.hex(keys.second))
        // The computer makes the same two from its side.
        val deskEphemeral = DeskCrypto.privateFromScalar(given("deskEphemeral"))
        val theirs = DeskCrypto.sessionKeys(pairKey, given("deskNonce"), given("phoneNonce"), deskEphemeral, bytes("phoneEphemeralPublic"))!!
        assertArrayEquals(keys.first, theirs.first)
        assertArrayEquals(keys.second, theirs.second)

        val phone = DeskCrypto.Channel(sendKey = keys.second, receiveKey = keys.first)
        val frames = v.getJSONArray("frames")
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            val sealed = DeskCrypto.unhex(f.getString("sealed"))
            if (f.getString("from") == "desk") assertEquals(f.getString("text"), phone.open(sealed))
            else assertArrayEquals(sealed, phone.seal(f.getString("text")))
        }
    }

    @Test
    fun aFrameRepeatedReorderedOrChangedDoesNotOpen() {
        val a = ByteArray(32) { 1 }
        val b = ByteArray(32) { 2 }
        val desk = DeskCrypto.Channel(sendKey = a, receiveKey = b)
        val phone = DeskCrypto.Channel(sendKey = b, receiveKey = a)
        val first = desk.seal("send this text")
        val second = desk.seal("and this one")
        assertEquals("send this text", phone.open(first))
        assertNull("the same frame again", phone.open(first))
        assertEquals("and this one", phone.open(second))
        // Out of order: the third before... there is no third yet; make two and give the later first.
        val third = desk.seal("three")
        val fourth = desk.seal("four")
        assertNull(phone.open(fourth))
        assertEquals("three", phone.open(third))
        assertEquals("four", phone.open(fourth))
        // Changed on the way.
        val fifth = desk.seal("five")
        fifth[2] = (fifth[2].toInt() xor 1).toByte()
        assertNull(phone.open(fifth))
        // The phone's own frames do not open on the phone: each direction has its own key.
        val mine = phone.seal("from the phone")
        assertNull(phone.open(mine))
        assertEquals("from the phone", desk.open(mine))
        assertTrue(first.size == "send this text".length + 16)
    }
}
