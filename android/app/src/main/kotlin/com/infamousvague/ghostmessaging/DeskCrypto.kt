package com.infamousvague.ghostmessaging

import org.json.JSONObject
import java.math.BigInteger
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.ECPrivateKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The sealing between this phone and a paired computer (Matt, 2026-11-13: "a companion desktop app that can proxy
 * messages encrypted from my phone to my desktop and then send back to the phone to send again"; docs/desktop.md).
 * Nothing here touches Android, so it is tested on the JVM (DeskCryptoTest), against examples made by a third
 * implementation (tool/desk_vectors.mjs) that the Mac's Dart is held to as well.
 *
 * It is [E2eCrypto]'s construction, P-256 ECDH into HKDF-SHA256 into AES-256-GCM, with three things added:
 *
 * - **The pairing's key** also takes in the sixteen random bytes the computer showed in its QR code, which cross no
 *   network. Whoever carried the phone's public key to the computer (a relay, the local network) and swapped it for
 *   their own ends up without the key.
 * - **A key for each connection, in each direction**, from the pairing's key, a fresh random number from each side
 *   and a throwaway key pair from each side. A pairing key taken later does not open what was recorded earlier.
 * - **A counter on every frame**, used as its nonce and never sent. A frame that is repeated, dropped, reordered or
 *   changed does not open, and the connection ends: a relay that replayed "send this text" would otherwise make the
 *   phone text someone twice.
 */
object DeskCrypto {
    const val OFFER_TAG = "GHOSTPAIR1:"

    /**
     * The same code as a link, which is what the computer's QR code holds (Matt, 2026-11-13, pointing his phone's
     * camera at it: "linking the Qr code said it can't be used by any app on my phone"). A phone's own camera opens
     * a link in the app that takes it; plain words it can only show.
     */
    const val OFFER_LINK = "ghostmsg://pair/"

    /** Whether [text] looks like a pairing code, in either form: before it is read. */
    fun isOffer(text: String): Boolean = text.trim().let { it.startsWith(OFFER_TAG) || it.startsWith(OFFER_LINK, ignoreCase = true) }

    /** The first byte of a frame: a hello, in the clear (it carries nothing but random numbers and public keys), or sealed. */
    const val HELLO: Byte = 1
    const val SEALED: Byte = 2

    /** The largest frame either side sends or takes. A picture crosses in pieces smaller than this. */
    const val MAX_FRAME = 1 shl 20

    private val PAIR_INFO = "ghost-messaging desktop v1".toByteArray()
    private val PAIRING_SALT = "ghost-desk pairing".toByteArray()
    private val AAD = "ghost-desk-v1".toByteArray()

    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    fun unhex(text: String): ByteArray = ByteArray(text.length / 2) { text.substring(it * 2, it * 2 + 2).toInt(16).toByte() }

    /** HKDF-SHA256 with one block of output, as [E2eCrypto.conversationKey] makes a conversation's key. */
    fun hkdf(salt: ByteArray, ikm: ByteArray, info: ByteArray): ByteArray = E2eCrypto.hmac(E2eCrypto.hmac(salt, ikm), info + byteArrayOf(1))

    /** A value made from the pairing's key, which is already uniform: its id, its relay channel, its code. */
    fun derive(key: ByteArray, label: String): ByteArray = E2eCrypto.hmac(key, "ghost-desk $label".toByteArray() + byteArrayOf(1))

    /** A private key from its 32 bytes: the examples' fixed keys (a phone's own are made by [E2eCrypto.newKeyPair]). */
    fun privateFromScalar(scalar: ByteArray): PrivateKey = KeyFactory.getInstance("EC").generatePrivate(ECPrivateKeySpec(BigInteger(1, scalar), E2eCrypto.curve))

    /** The ECDH secret of this side's private key and the other's public one; null where theirs is no key. */
    private fun agree(mine: PrivateKey, theirs: ByteArray): ByteArray? {
        val peer = E2eCrypto.publicFrom(theirs) ?: return null
        return KeyAgreement.getInstance("ECDH").apply { init(mine); doPhase(peer, true) }.generateSecret()
    }

    // --- what the computer's QR code says ---------------------------------------------------------------------------

    /** [key]: the computer's public key for this pairing. [secret]: sixteen random bytes. [mode]: both, local, relay. */
    class Offer(val key: ByteArray, val secret: ByteArray, val name: String, val mode: String, val relay: String)

    val MODES = setOf("both", "local", "relay")

    /** What a scanned or pasted code offers, or null when it is not one of ours or is not whole. */
    fun parseOffer(text: String): Offer? {
        val body = text.trim()
        val payload = when {
            body.startsWith(OFFER_TAG) -> body.substring(OFFER_TAG.length)
            body.startsWith(OFFER_LINK, ignoreCase = true) -> body.substring(OFFER_LINK.length)
            else -> return null
        }
        return try {
            val o = JSONObject(String(Base64.getUrlDecoder().decode(payload.trim().trimEnd('=')), Charsets.UTF_8))
            val key = Base64.getDecoder().decode(o.getString("k"))
            val secret = Base64.getDecoder().decode(o.getString("s"))
            val mode = o.optString("m", "both")
            if (E2eCrypto.publicFrom(key) == null || secret.size != 16 || mode !in MODES) return null
            Offer(key, secret, o.optString("n", "A computer").take(60).ifBlank { "A computer" }, mode, o.optString("r", "").trim())
        } catch (_: Exception) { null }
    }

    /** The code a computer shows for [offer]: the computer's side, here for the tests. */
    fun offerText(offer: Offer): String {
        val o = JSONObject()
        o.put("k", Base64.getEncoder().encodeToString(offer.key))
        o.put("s", Base64.getEncoder().encodeToString(offer.secret))
        o.put("n", offer.name)
        o.put("m", offer.mode)
        o.put("r", offer.relay)
        return OFFER_TAG + Base64.getUrlEncoder().withoutPadding().encodeToString(o.toString().toByteArray(Charsets.UTF_8))
    }

    /** What both sides can make from the QR code's secret alone, to find each other before there is a key. */
    fun fromSecret(secret: ByteArray, label: String): ByteArray = hkdf(PAIRING_SALT, secret, label.toByteArray())

    /** While pairing: the name a hello goes under, and the relay channel and its token, all from the code's secret. */
    fun pairingId(secret: ByteArray): String = hex(fromSecret(secret, "id").copyOf(8))
    fun pairingChannel(secret: ByteArray): String = hex(fromSecret(secret, "relay channel").copyOf(16))
    fun pairingToken(secret: ByteArray): String = hex(fromSecret(secret, "relay token"))

    // --- the pairing's key -------------------------------------------------------------------------------------------

    /** The key the phone and the computer keep: the same on both, and nobody's who lacks the QR code's [secret]. */
    fun pairKey(mine: PrivateKey, minePublic: ByteArray, theirs: ByteArray, secret: ByteArray): ByteArray? {
        val shared = agree(mine, theirs) ?: return null
        return hkdf(E2eCrypto.ordered(minePublic, theirs), shared + secret, PAIR_INFO)
    }

    /** The pairing's name on the wire: it says which key a hello is under, and nothing of the key. */
    fun id(pairKey: ByteArray): String = hex(derive(pairKey, "id").copyOf(8))
    /** Once paired: the relay channel the two meet on and the token that opens it, from the pairing's key. */
    fun relayChannel(pairKey: ByteArray): String = hex(derive(pairKey, "relay channel").copyOf(16))
    fun relayToken(pairKey: ByteArray): String = hex(derive(pairKey, "relay token"))

    /** Six digits, the same on both when they hold the same key: what is compared by eye as they pair. */
    fun code(pairKey: ByteArray): String {
        val d = derive(pairKey, "code")
        val n = ((d[0].toLong() and 0xFF) shl 24) or ((d[1].toLong() and 0xFF) shl 16) or ((d[2].toLong() and 0xFF) shl 8) or (d[3].toLong() and 0xFF)
        return (n % 1000000).toString().padStart(6, '0')
    }

    // --- one connection ----------------------------------------------------------------------------------------------

    /**
     * The two keys of one connection, the computer's (what it seals with) first and the phone's second: from the
     * pairing's key, each side's random number and the secret their throwaway keys agree on.
     */
    fun sessionKeys(pairKey: ByteArray, deskNonce: ByteArray, phoneNonce: ByteArray, mine: PrivateKey, theirs: ByteArray): Pair<ByteArray, ByteArray>? {
        val shared = agree(mine, theirs) ?: return null
        val prk = E2eCrypto.hmac(deskNonce + phoneNonce, pairKey + shared)
        return E2eCrypto.hmac(prk, "d2p".toByteArray() + byteArrayOf(1)) to E2eCrypto.hmac(prk, "p2d".toByteArray() + byteArrayOf(1))
    }

    /** One side of a connection: what it seals goes out under [sendKey], what arrives is opened under [receiveKey]. */
    class Channel(private val sendKey: ByteArray, private val receiveKey: ByteArray) {
        private var sent = 0L
        private var received = 0L

        private fun nonce(counter: Long) = ByteArray(12).also { for (i in 0 until 8) it[11 - i] = (counter ushr (8 * i)).toByte() }

        /** [text] sealed as the next frame this side sends. Frames must go out in the order they were sealed. */
        @Synchronized
        fun seal(text: String): ByteArray {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(sendKey, "AES"), GCMParameterSpec(128, nonce(sent)))
            cipher.updateAAD(AAD)
            sent++
            return cipher.doFinal(text.toByteArray(Charsets.UTF_8))
        }

        /** The words of the next frame to arrive, or null when [sealed] is not it: repeated, out of order, changed. */
        @Synchronized
        fun open(sealed: ByteArray): String? = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(receiveKey, "AES"), GCMParameterSpec(128, nonce(received)))
            cipher.updateAAD(AAD)
            val text = String(cipher.doFinal(sealed), Charsets.UTF_8)
            received++
            text
        } catch (_: Exception) { null }
    }
}
