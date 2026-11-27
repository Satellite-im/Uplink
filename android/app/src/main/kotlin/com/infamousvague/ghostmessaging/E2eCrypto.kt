package com.infamousvague.ghostmessaging

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The cryptography of Uplink's own end-to-end encryption over SMS (Matt, 2026-11-13: "an additional level
 * of E2E encryption by allowing users to exchange keys somehow and then encrypt all messages so only others with the
 * app can read them"). Nothing here touches Android, so it is tested on the JVM (E2eCryptoTest).
 *
 * - Each phone has one P-256 key pair. Its public half travels in a text as `ghost:k1:` and 33 bytes (the point,
 *   compressed) in base64.
 * - Two phones that hold each other's public halves share a secret (ECDH), from which the conversation's key is made
 *   with HKDF-SHA256, salted with both public halves in a fixed order so both sides make the same key.
 * - A message is AES-256-GCM under that key with a fresh random 96-bit nonce: `ghost:e1:` and nonce, ciphertext and
 *   tag in base64. A changed or foreign message fails its tag and is not shown as text.
 * - The safety number is a digest of both public halves, the same on both phones: compared in person or on a call,
 *   it shows nobody put their own key in the middle of the exchange (a carrier could, since the keys go by SMS).
 *
 * What it is not: there is no ratchet, so no forward secrecy (a phone's key, once taken, reads that phone's past
 * encrypted texts), and the length of a message and who it is to are as visible to the carrier as any SMS's.
 */
object E2eCrypto {
    const val KEY_TAG = "ghost:k1:"
    const val MSG_TAG = "ghost:e1:"
    private val INFO = "ghost-messaging e2e v1".toByteArray()
    private val AAD = "ghost-e2e-v1".toByteArray()
    private val random = SecureRandom()

    internal val curve: ECParameterSpec by lazy {
        AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    }
    private val p: BigInteger by lazy { (curve.curve.field as java.security.spec.ECFieldFp).p }

    fun newKeyPair(): KeyPair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1"), random) }.generateKeyPair()

    fun privateFrom(pkcs8: ByteArray): PrivateKey = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(pkcs8))

    /** [n] as exactly 32 bytes, most significant first: zeros in front where it is shorter, a sign byte dropped. */
    private fun fixed(n: BigInteger): ByteArray {
        val raw = n.toByteArray()
        val out = ByteArray(32)
        val from = maxOf(0, raw.size - 32)
        System.arraycopy(raw, from, out, 32 - (raw.size - from), raw.size - from)
        return out
    }

    /** The public key as 33 bytes: 02 or 03 for its y's parity, then x. */
    fun publicBytes(key: PublicKey): ByteArray {
        val w = (key as ECPublicKey).w
        return byteArrayOf(if (w.affineY.testBit(0)) 3 else 2) + fixed(w.affineX)
    }

    /** The public key those 33 bytes name, or null when they are not a point on the curve. */
    fun publicFrom(bytes: ByteArray): PublicKey? {
        if (bytes.size != 33 || (bytes[0].toInt() != 2 && bytes[0].toInt() != 3)) return null
        return try {
            val x = BigInteger(1, bytes.copyOfRange(1, 33))
            if (x >= p) return null
            // y^2 = x^3 + ax + b; p is 3 mod 4, so a square root is rhs^((p+1)/4).
            val rhs = x.pow(3).add(curve.curve.a.multiply(x)).add(curve.curve.b).mod(p)
            var y = rhs.modPow(p.add(BigInteger.ONE).shiftRight(2), p)
            if (y.multiply(y).mod(p) != rhs) return null
            if (y.testBit(0) != (bytes[0].toInt() == 3)) y = p.subtract(y)
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), curve))
        } catch (_: Exception) { null }
    }

    internal fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(key, "HmacSHA256")) }.doFinal(data)

    /** The two joined, the lesser first, so both sides make the same bytes whichever of them is "mine". */
    internal fun ordered(a: ByteArray, b: ByteArray): ByteArray {
        for (i in a.indices) {
            val d = (a[i].toInt() and 0xFF) - (b[i].toInt() and 0xFF)
            if (d != 0) return if (d < 0) a + b else b + a
        }
        return a + b
    }

    /** The conversation's key between the holder of [mine] and the holder of [theirs]: the same on both phones. */
    fun conversationKey(mine: PrivateKey, minePublic: ByteArray, theirs: ByteArray): ByteArray? {
        val peer = publicFrom(theirs) ?: return null
        val shared = KeyAgreement.getInstance("ECDH").apply { init(mine); doPhase(peer, true) }.generateSecret()
        val prk = hmac(ordered(minePublic, theirs), shared)
        return hmac(prk, INFO + byteArrayOf(1))
    }

    /** [text] as it goes out: `ghost:e1:` and base64 of nonce, ciphertext and tag. */
    fun seal(key: ByteArray, text: String): String {
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(AAD)
        return MSG_TAG + Base64.getEncoder().withoutPadding().encodeToString(nonce + cipher.doFinal(text.toByteArray(Charsets.UTF_8)))
    }

    /** The words inside [wire], or null when it is not one of ours, was changed, or was made under another key. */
    fun open(key: ByteArray, wire: String): String? {
        val body = wire.trim()
        if (!body.startsWith(MSG_TAG)) return null
        return try {
            val raw = Base64.getDecoder().decode(body.substring(MSG_TAG.length).trim())
            if (raw.size < 12 + 16) return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, raw, 0, 12))
            cipher.updateAAD(AAD)
            String(cipher.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
        } catch (_: Exception) { null }
    }

    /** Whether a text is one of the app's sealed ones, by its opening tag. */
    fun isSealed(body: String): Boolean = body.trimStart().startsWith(MSG_TAG)

    private val keyPattern = Regex("ghost:k1:([A-Za-z0-9+/]{44})")

    /** The public key a text carries, anywhere in it, or null. */
    fun keyIn(body: String): ByteArray? {
        val m = keyPattern.find(body) ?: return null
        return try { Base64.getDecoder().decode(m.groupValues[1]).takeIf { publicFrom(it) != null } } catch (_: Exception) { null }
    }

    /** A public key as a text carries it: the tag, then the key in base64. [keyIn] reads it back. */
    fun keyText(publicKey: ByteArray): String = KEY_TAG + Base64.getEncoder().encodeToString(publicKey)

    /** Thirty digits in six groups, from both public keys in a fixed order: the same on both phones. */
    fun safetyNumber(a: ByteArray, b: ByteArray): String {
        var digest = MessageDigest.getInstance("SHA-256").digest("ghost-safety-v1".toByteArray() + ordered(a, b))
        repeat(1000) { digest = MessageDigest.getInstance("SHA-256").digest(digest) }
        return (0 until 6).joinToString(" ") { g ->
            val n = BigInteger(1, digest.copyOfRange(g * 5, g * 5 + 5)).mod(BigInteger.valueOf(100000))
            n.toString().padStart(5, '0')
        }
    }

    /** A short name for one key, to tell it from another: eight hex digits of its digest. */
    fun fingerprint(publicKey: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(publicKey).take(4).joinToString("") { "%02X".format(it) }.chunked(4).joinToString(" ")
}
