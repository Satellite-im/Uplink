package com.infamousvague.ghostmessaging

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigInteger
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECPrivateKeySpec

/**
 * The phone's arithmetic for the app's routes (Net.kt) against the same two key pairs lib/net/crypto.dart is held
 * to in test/net_test.dart: a phone and a computer must make the same names and the same keys.
 */
class NetCryptoTest {
    private fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun private(scalar: ByteArray) = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), E2eCrypto.curve))

    // The private keys are bytes 01..20 and a0..bf; these are their public halves, as the Dart test has them.
    private val a = private(ByteArray(32) { (it + 1).toByte() })
    private val b = private(ByteArray(32) { (0xa0 + it).toByte() })
    private val aPub = unhex("02515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f")
    private val bPub = unhex("020d0918a04198474605615b6df90fdcb34791fb3ecb822f4b26eb6e4fc4511b9d")

    @Test
    fun aNameAndAPairsKeyAreTheOnesDartMakes() {
        assertEquals("d284f0626fd0836ce4b1731793fa6905", Net.idOf(aPub))
        val conversation = E2eCrypto.conversationKey(a, aPub, bPub)!!
        assertEquals("c6e3cd9e9784467bdff6aafce3d2c1864597a24c4cf9f78e0634b9b6aa8fa5d4", hex(conversation))
        assertArrayEquals(conversation, E2eCrypto.conversationKey(b, bPub, aPub))
        assertEquals("d150804ceef8aff0a7bf0a5c383fa178430f5d7bc5e81f8f79851bf26d283c57", hex(Net.netKey(conversation)))
    }

    /** Android writes a signature as DER; the routes carry r then s. The same signature either way. */
    @Test
    fun aSignatureAsTheRoutesCarryIt() {
        val message = "ghost-hub v1 abc".toByteArray()
        repeat(40) {
            val der = Signature.getInstance("SHA256withECDSA").apply { initSign(a); update(message) }.sign()
            val raw = Net.rawSignature(der)!!
            assertEquals(64, raw.size)
            // Put back as DER, it is still a's signature over the message.
            fun int(bytes: ByteArray): ByteArray {
                val v = BigInteger(1, bytes).toByteArray()
                return byteArrayOf(0x02, v.size.toByte()) + v
            }
            val body = int(raw.copyOfRange(0, 32)) + int(raw.copyOfRange(32, 64))
            val again = byteArrayOf(0x30, body.size.toByte()) + body
            assertTrue(Signature.getInstance("SHA256withECDSA").apply { initVerify(E2eCrypto.publicFrom(aPub)); update(message) }.verify(again))
        }
        assertNull(Net.rawSignature(byteArrayOf(1, 2, 3)))
        assertNull(Net.rawSignature(ByteArray(0)))
    }
}
