package com.infamousvague.ghostmessaging

import android.content.Context
import java.security.MessageDigest
import java.util.Base64

/**
 * What the phone holds for the app's routes (lib/net in Dart; Matt, 2026-11-14: "implement a full relay system for
 * the app that's replacable and swappable", "multiple sources to feed data to eachother from wifi locally, p2p,
 * internet, sms, etc"): who this phone is to the others, who they are, and the key each pair seals with.
 *
 * Nothing new is made for it. This phone's key pair is the one its encryption has ([E2e]), so the people the routes
 * can reach are the people encryption is on with, and exchanging keys by text is what introduces two phones. The
 * private key stays where [E2e] keeps it: Dart is given the public half, a signature when a hub asks for one, and
 * for each person a key made from the conversation's key for the routes alone ([netKey]), never the key texts are
 * sealed with.
 *
 * The arithmetic is here and pure, and agrees with lib/net/crypto.dart (NetCryptoTest and test/net_test.dart hold
 * the same bytes).
 */
object Net {
    /** A name for a public key: the first 16 bytes of its SHA-256, in hex. What a hub and the other phones call it. */
    fun idOf(publicKey: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(publicKey).take(16).joinToString("") { "%02x".format(it) }

    /** A key for one purpose made from another: the same words on both phones give the same key. */
    fun derive(key: ByteArray, label: String): ByteArray = E2eCrypto.hmac(key, "ghost-net $label".toByteArray() + byteArrayOf(1))

    /** What two phones seal the routes' packets with, from the key their conversation has. */
    fun netKey(conversationKey: ByteArray): ByteArray = derive(conversationKey, "pair")

    /**
     * A signature as the routes carry it, r then s in 64 bytes, from one as Android writes it (DER: a sequence of
     * two integers, each with a zero in front where its top bit is set). Null when [der] is not that.
     */
    fun rawSignature(der: ByteArray): ByteArray? {
        fun fixed(bytes: ByteArray): ByteArray? {
            val trimmed = bytes.dropWhile { it == 0.toByte() }
            if (trimmed.size > 32) return null
            return ByteArray(32 - trimmed.size) + trimmed.toByteArray()
        }
        try {
            var at = 0
            if (der[at++] != 0x30.toByte()) return null
            // The sequence's length: one byte, or 0x81 and one byte.
            if (der[at].toInt() and 0x80 != 0) at += 1 + (der[at].toInt() and 0x7f) else at += 1
            if (der[at++] != 0x02.toByte()) return null
            val rLen = der[at++].toInt() and 0xff
            val r = fixed(der.copyOfRange(at, at + rLen)) ?: return null
            at += rLen
            if (der[at++] != 0x02.toByte()) return null
            val sLen = der[at++].toInt() and 0xff
            val s = fixed(der.copyOfRange(at, at + sLen)) ?: return null
            if (at + sLen != der.size) return null
            return r + s
        } catch (_: Exception) {
            return null
        }
    }

    /** Who this phone is: its name and its public key. */
    fun identity(context: Context): Map<String, Any?> {
        val pub = E2e.myPublic(context)
        return mapOf("id" to idOf(pub), "key" to Base64.getEncoder().encodeToString(pub))
    }

    /** Everyone the routes can reach: their name, their number, and the key packets to and from them are sealed with. */
    fun peers(context: Context): List<Map<String, Any?>> = E2e.accepted(context).map { (address, pub, conversation) ->
        mapOf("id" to idOf(pub), "address" to address, "key" to netKey(conversation))
    }

    /** This phone's signature over [message], r then s: what a hub asks for before it lets a name in. */
    fun sign(context: Context, message: ByteArray): ByteArray =
        rawSignature(E2e.sign(context, message)) ?: throw IllegalStateException("the signature could not be read")
}
