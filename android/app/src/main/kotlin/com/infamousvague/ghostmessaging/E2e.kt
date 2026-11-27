package com.infamousvague.ghostmessaging

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import org.json.JSONObject
import java.security.KeyStore
import java.security.PrivateKey
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Uplink's own encryption between two phones that both run it: this phone's key, the keys other people
 * sent, and where each conversation stands. The cryptography is [E2eCrypto]'s; this is what Android keeps.
 *
 * A conversation with one person is in one of four states:
 * - none: nothing exchanged.
 * - offered: this phone sent its key and waits for theirs.
 * - pending: they sent a key and the person here has not said yes. Also where a conversation goes back to when a
 *   DIFFERENT key arrives from someone already exchanged with (`changed`): nothing is encrypted to a new key until
 *   the person accepts it, since a new key is what someone in the middle would send too.
 * - on: both keys held. Every text to that person goes out sealed, and theirs are opened.
 *
 * Sealed texts are kept sealed in Android's SMS database, which other apps with SMS access can read, and opened as
 * they are shown ([read]). This phone's private key is kept encrypted under a key in the Android Keystore, which
 * never leaves the phone's secure hardware.
 *
 * One person at a time: a group conversation and a picture message are MMS and go as they always have.
 */
object E2e {
    private const val TAG = "GhostMessaging"
    private const val PREFS = "e2e"
    private const val WRAP_ALIAS = "ghost_e2e_wrap"
    const val KEY_NOTE = "Uplink encryption key. With the app (gogho.st) our texts can be end-to-end encrypted."

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** A person's number as conversations are told apart by it: its last ten digits, or the address in lower case. */
    fun norm(address: String): String {
        val digits = address.filter { it.isDigit() }
        return if (digits.length >= 7) digits.takeLast(10) else address.trim().lowercase()
    }

    // --- this phone's key --------------------------------------------------------------------------------------------

    /** The Keystore's AES key that seals this phone's private key where it is kept; made the first time it's wanted. */
    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(WRAP_ALIAS, null) as SecretKey?)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(WRAP_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    @Volatile private var identity: Pair<PrivateKey, ByteArray>? = null
    private val sessions = HashMap<String, ByteArray>()

    /** This phone's key pair, made the first time it is asked for. */
    @Synchronized
    private fun identity(context: Context): Pair<PrivateKey, ByteArray> {
        identity?.let { return it }
        val p = prefs(context)
        val stored = p.getString("identity", null)
        val pub = p.getString("identity_pub", null)
        if (stored != null && pub != null) {
            try {
                val raw = Base64.getDecoder().decode(stored)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, raw, 0, 12))
                val pair = E2eCrypto.privateFrom(cipher.doFinal(raw, 12, raw.size - 12)) to Base64.getDecoder().decode(pub)
                identity = pair
                return pair
            } catch (e: Exception) { Log.e(TAG, "e2e identity unreadable; a new one is made", e) }
        }
        val pair = E2eCrypto.newKeyPair()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        val sealed = cipher.iv + cipher.doFinal(pair.private.encoded)
        val public = E2eCrypto.publicBytes(pair.public)
        p.edit().putString("identity", Base64.getEncoder().encodeToString(sealed)).putString("identity_pub", Base64.getEncoder().encodeToString(public)).apply()
        return (pair.private to public).also { identity = it }
    }

    fun hasIdentity(context: Context) = prefs(context).contains("identity")

    /**
     * This phone's private key as its 32 bytes, for an Uplink account's sealed backup (lib/account in the app; Matt,
     * 2026-11-17: "We need to have a way to login to existing accounts"): an account made on a phone that had its own key
     * keeps that key, and a new device signing in gets it back. It goes from here only to be sealed by the app.
     */
    fun exportScalar(context: Context): ByteArray {
        val d = (identity(context).first as java.security.interfaces.ECPrivateKey).s
        val raw = d.toByteArray()
        val out = ByteArray(32)
        val from = maxOf(0, raw.size - 32)
        System.arraycopy(raw, from, out, 32 - (raw.size - from), raw.size - from)
        return out
    }

    /**
     * Makes [scalar] (its public key [public], 33 bytes, worked out by the app) this phone's key: a device signing in to
     * an account. As [reset] does, every conversation's encryption ends, since the people in them hold the old key; the
     * app restarts straight after so nothing goes on as the old one.
     */
    @Synchronized
    fun importScalar(context: Context, scalar: ByteArray, public: ByteArray) {
        require(scalar.size == 32 && public.size == 33) { "not a key" }
        val params = E2eCrypto.curve
        val d = java.math.BigInteger(1, scalar)
        require(d.signum() > 0 && d < params.order) { "not a key" }
        val secret = java.security.KeyFactory.getInstance("EC").generatePrivate(java.security.spec.ECPrivateKeySpec(d, params))
        // The two have to be one pair before anything is reset: a signature by the one that the other checks. Else the
        // phone would lose its key for one that is no use (or that others know by another public key).
        val publicKey = E2eCrypto.publicFrom(public) ?: throw IllegalArgumentException("not a key")
        val probe = "ghost identity import check".toByteArray()
        val sig = java.security.Signature.getInstance("SHA256withECDSA").apply { initSign(secret); update(probe) }.sign()
        require(java.security.Signature.getInstance("SHA256withECDSA").apply { initVerify(publicKey); update(probe) }.verify(sig)) { "not a pair" }
        reset(context)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        val sealed = cipher.iv + cipher.doFinal(secret.encoded)
        // commit, not apply: the app is restarted right after, and the key must be on the disk by then.
        prefs(context).edit().putString("identity", Base64.getEncoder().encodeToString(sealed)).putString("identity_pub", Base64.getEncoder().encodeToString(public)).commit()
            .also { check(it) { "the key could not be written" } }
        identity = null
    }

    fun myFingerprint(context: Context): String = E2eCrypto.fingerprint(identity(context).second)

    // --- the people ----------------------------------------------------------------------------------------------------

    /** What is kept of encryption with [address], under their number as [norm] has it; null where nothing is. */
    private fun peer(context: Context, address: String): JSONObject? =
        prefs(context).getString("peer:${norm(address)}", null)?.let { runCatching { JSONObject(it) }.getOrNull() }

    /** Keeps [address]'s record, and lets go of the conversation key made from the one before. */
    private fun save(context: Context, address: String, o: JSONObject) {
        prefs(context).edit().putString("peer:${norm(address)}", o.toString()).apply()
        synchronized(sessions) { sessions.remove(norm(address)) }
    }

    fun isOn(context: Context, address: String): Boolean = peer(context, address)?.optString("state") == "on"

    /**
     * The numbers this phone holds an encryption record for, whatever each stands at, by [norm]: who is at one of them
     * is that record's to say (its key), never a group's (Groups.peers).
     */
    fun held(context: Context): Set<String> =
        prefs(context).all.keys.filter { it.startsWith("peer:") }.map { it.removePrefix("peer:") }.toSet()

    /**
     * Each install encryption is on with, by its name (Net.idOf its key), at the number its record is for: who this
     * phone's own records say an install is (Groups.known). One key on two numbers goes to the lower, as Dart's
     * Friends.whoIs has it.
     */
    fun onIds(context: Context): Map<String, String> {
        val out = HashMap<String, String>()
        for (name in prefs(context).all.keys.filter { it.startsWith("peer:") }) {
            val o = peer(context, name.removePrefix("peer:")) ?: continue
            if (o.optString("state") != "on") continue
            val pub = runCatching { Base64.getDecoder().decode(o.optString("pub", "")) }.getOrNull()?.takeIf { it.size == 33 } ?: continue
            val address = o.optString("address", name.removePrefix("peer:"))
            val id = Net.idOf(pub)
            val had = out[id]
            if (had == null || norm(address) < norm(had)) out[id] = address
        }
        return out
    }

    // --- friends (Friends.kt, lib/friends/friends.dart) -----------------------------------------------------------------

    /**
     * Where being friends with [address] stands: "" (not), "want" (this phone means to ask, once keys are exchanged),
     * "asked" (it asked), "invited" (they asked), "yes" (both said so). Kept on their encryption record: it ends
     * when encryption with them does, and with a key of theirs that is not the one it was made with.
     */
    fun friend(context: Context, address: String): String = peer(context, address)?.optString("friend", "") ?: ""

    fun setFriend(context: Context, address: String, state: String) {
        val o = peer(context, address) ?: return
        if (state.isEmpty()) o.remove("friend") else o.put("friend", state)
        save(context, address, o)
    }

    /**
     * The key this phone and the holder of [publicKey] share, made as a conversation's is: for a member of a group
     * this phone is in, whose key came with the group and not by text (Groups.peers).
     */
    fun pairKey(context: Context, publicKey: ByteArray): ByteArray? = try {
        val (mine, minePub) = identity(context)
        E2eCrypto.conversationKey(mine, minePub, publicKey)
    } catch (e: Exception) { Log.e(TAG, "pair key", e); null }

    // --- for the app's routes (Net.kt) ---------------------------------------------------------------------------------

    /** This phone's public key, 33 bytes: what the routes know it by. Made if there is none yet. */
    fun myPublic(context: Context): ByteArray = identity(context).second

    /** This phone's signature over [message] (ECDSA over its SHA-256), as Android writes one. */
    fun sign(context: Context, message: ByteArray): ByteArray =
        java.security.Signature.getInstance("SHA256withECDSA").apply { initSign(identity(context).first); update(message) }.sign()

    /** Everyone encryption is on with: their number, their public key, and the conversation's key. */
    fun accepted(context: Context): List<Triple<String, ByteArray, ByteArray>> =
        prefs(context).all.keys.filter { it.startsWith("peer:") }.mapNotNull { name ->
            val o = peer(context, name.removePrefix("peer:")) ?: return@mapNotNull null
            if (o.optString("state") != "on") return@mapNotNull null
            val address = o.optString("address", name.removePrefix("peer:"))
            val pub = runCatching { Base64.getDecoder().decode(o.optString("pub", "")) }.getOrNull()?.takeIf { it.size == 33 } ?: return@mapNotNull null
            Triple(address, pub, key(context, address) ?: return@mapNotNull null)
        }

    // --- finding each other (GhostMark.kt) ---------------------------------------------------------------------------

    private const val DAY = 24L * 60 * 60 * 1000

    /** Settings › Encryption › Find people who have Uplink: on unless switched off. */
    fun detect(context: Context): Boolean = context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("e2e_detect", "on") != "off"

    /** The person turned encryption off with [address]: it is not offered to them again until they offer it. */
    fun declined(context: Context, address: String) = prefs(context).getBoolean("declined:${norm(address)}", false)

    /**
     * Whether a text to [address] should carry the invisible mark that says this phone has the app: only while
     * nothing has been exchanged with them, and at most once a day.
     */
    fun wantsMark(context: Context, address: String): Boolean {
        if (!detect(context) || declined(context, address)) return false
        if ((peer(context, address)?.optString("state", "none") ?: "none") != "none") return false
        return System.currentTimeMillis() - prefs(context).getLong("marked:${norm(address)}", 0) >= DAY
    }

    /** A text to [address] has just carried the mark: [wantsMark] says no for a day. */
    fun marked(context: Context, address: String) {
        prefs(context).edit().putLong("marked:${norm(address)}", System.currentTimeMillis()).apply()
    }

    /** Whether a key of [address]'s is here: they have the app, whatever was done about the key. */
    fun hasTheirKey(context: Context, address: String): Boolean = peer(context, address)?.optString("pub", "")?.isNotEmpty() == true

    /** Where the conversation with [address] stands, for the screen. */
    fun state(context: Context, address: String): Map<String, Any?> {
        val o = peer(context, address)
        val state = o?.optString("state", "none") ?: "none"
        val pub = o?.optString("pub", "")?.takeIf { it.isNotEmpty() }?.let { Base64.getDecoder().decode(it) }
        return mapOf(
            "address" to (o?.optString("address", address) ?: address),
            "state" to state,
            "verified" to (o?.optBoolean("verified", false) ?: false),
            "changed" to (o?.optBoolean("changed", false) ?: false),
            "safety" to (if (pub != null && hasIdentity(context)) E2eCrypto.safetyNumber(identity(context).second, pub) else null),
            "theirKey" to pub?.let { E2eCrypto.fingerprint(it) },
            // They are known to have the app (a text only it writes came from them): the conversation offers
            // encryption in a banner, unless the person turned it off with them.
            "hasGhost" to Backgrounds.allKnown(context, listOf(address)),
            "declined" to declined(context, address),
            "friend" to (o?.optString("friend", "") ?: ""),
            // Their install's name, made from the key held for them: what Dart decides who is a friend by (the direct
            // route links only with friends: lib/net/net.dart), never the address, which a group's admin can write.
            "id" to pub?.let { Net.idOf(it) },
            // Texts that came from them plain while encryption is on, and have not been put away ([arrived]).
            "plain" to (if (state == "on") E2ePlain.unseen(o?.optInt("plain", 0) ?: 0, o?.optInt("plainSeen", 0) ?: 0) else 0),
        )
    }

    /**
     * A text came from [address]. Where encryption is on with them and it came plain, it is counted on their record
     * (Matt, 2026-11-14: "we need to be able to detect if a user is sending us unencrypted messages and let us know
     * so we can disable it"): they may have turned it off, changed phones or left the app, and then cannot read what
     * goes to them sealed. One that comes sealed again clears the count. True when this is the first plain one since
     * the last sealed one, which is the moment to say so.
     */
    fun arrived(context: Context, address: String, body: String): Boolean {
        val o = peer(context, address) ?: return false
        if (o.optString("state") != "on") return false
        val count = o.optInt("plain", 0)
        val seen = o.optInt("plainSeen", 0)
        val (nextCount, nextSeen) = E2ePlain.next(count, seen, E2ePlain.kindOf(body))
        if (nextCount == count && nextSeen == seen) return false
        o.put("plain", nextCount)
        o.put("plainSeen", nextSeen)
        save(context, address, o)
        return count == 0 && nextCount == 1
    }

    /** The warning that their texts are coming plain was put away: it comes back with the next plain one. */
    fun plainSeen(context: Context, address: String) {
        val o = peer(context, address) ?: return
        o.put("plainSeen", o.optInt("plain", 0))
        save(context, address, o)
    }

    /** Everyone something has been exchanged with, each as [state] gives them (the screens' `e2eList`). */
    fun list(context: Context): List<Map<String, Any?>> =
        prefs(context).all.keys.filter { it.startsWith("peer:") }.mapNotNull { k ->
            val o = runCatching { JSONObject(prefs(context).getString(k, "") ?: "") }.getOrNull() ?: return@mapNotNull null
            state(context, o.optString("address", k.removePrefix("peer:")))
        }.filter { it["state"] != "none" }

    /** The text that carries this phone's key. */
    fun keyMessage(context: Context): String = KEY_NOTE + "\n" + E2eCrypto.keyText(identity(context).second)

    /**
     * This phone sends its key to [address] (the caller sends [keyMessage]): turning encryption on where their key is
     * already here, waiting for it where it is not.
     */
    fun offered(context: Context, address: String) {
        val o = peer(context, address) ?: JSONObject()
        o.put("address", address)
        o.put("sent", true)
        o.put("changed", false)
        o.put("state", if (o.optString("pub", "").isNotEmpty()) "on" else "offered")
        save(context, address, o)
        // Offered again: whatever "no" was said before is over.
        prefs(context).edit().remove("declined:${norm(address)}").apply()
    }

    /** A key arrived from [address]. Returns true when the conversation is now on. */
    fun received(context: Context, address: String, publicKey: ByteArray): Boolean {
        val o = peer(context, address) ?: JSONObject()
        val b64 = Base64.getEncoder().encodeToString(publicKey)
        val before = o.optString("pub", "")
        o.put("address", address)
        if (before == b64) {
            // The key already held, sent again: nothing changes but that a conversation waiting for it is on.
            if (o.optString("state") == "offered") o.put("state", "on")
        } else if (before.isNotEmpty()) {
            // A different key from someone already exchanged with: back to asking, and no longer verified.
            o.put("pub", b64); o.put("state", "pending"); o.put("changed", true); o.put("verified", false); o.put("sent", false)
            // Whoever holds the new key is not who was made a friend of.
            o.remove("friend")
        } else {
            o.put("pub", b64)
            o.put("state", if (o.optBoolean("sent", false)) "on" else "pending")
        }
        save(context, address, o)
        return o.optString("state") == "on"
    }

    fun setVerified(context: Context, address: String, verified: Boolean) {
        val o = peer(context, address) ?: return
        o.put("verified", verified)
        save(context, address, o)
    }

    /** Encryption off with [address]: their key is let go, and texts go as plain SMS again. */
    fun off(context: Context, address: String) {
        // And it stays off: the conversation does not offer it again, nor is the hello sent to them, until it is
        // offered by hand.
        prefs(context).edit().remove("peer:${norm(address)}").putBoolean("declined:${norm(address)}", true).apply()
        synchronized(sessions) { sessions.remove(norm(address)) }
    }

    /** A new key for this phone: every conversation's encryption ends, and each is exchanged again to go on. */
    @Synchronized
    fun reset(context: Context) {
        prefs(context).edit().clear().apply()
        identity = null
        synchronized(sessions) { sessions.clear() }
        runCatching { KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.deleteEntry(WRAP_ALIAS) }
    }

    // --- texts ---------------------------------------------------------------------------------------------------------

    /** The key texts with [address] are sealed under, made from both phones' keys, then held; null without theirs. */
    private fun key(context: Context, address: String): ByteArray? {
        val n = norm(address)
        synchronized(sessions) { sessions[n]?.let { return it } }
        val pub = peer(context, address)?.optString("pub", "")?.takeIf { it.isNotEmpty() } ?: return null
        return try {
            val (mine, minePub) = identity(context)
            E2eCrypto.conversationKey(mine, minePub, Base64.getDecoder().decode(pub))?.also { synchronized(sessions) { sessions[n] = it } }
        } catch (e: Exception) { Log.e(TAG, "e2e key", e); null }
    }

    /** [text] as it should go to [address]: sealed where encryption is on with them, else null (send it as it is). */
    fun wire(context: Context, address: String, text: String): String? {
        if (!isOn(context, address) || E2eCrypto.keyIn(text) != null) return null
        val k = key(context, address) ?: return null
        return E2eCrypto.seal(k, text)
    }

    /** A stored text for the screen: its words, and what it was ("encrypted", "undecryptable", "key", or null). */
    fun read(context: Context, address: String, body: String): Pair<String, String?> {
        if (E2eCrypto.isSealed(body)) {
            val k = key(context, address)
            val words = k?.let { E2eCrypto.open(it, body) }
            return if (words != null) words to "encrypted" else "" to "undecryptable"
        }
        if (E2eCrypto.keyIn(body) != null) return "" to "key"
        // The invisible hello between two copies of the app (GhostMark) is not part of the words.
        return GhostMark.strip(body) to null
    }

    /** One line for a conversation's preview. */
    fun preview(context: Context, address: String?, body: String): String {
        if (address == null) return body
        val (words, kind) = read(context, address, body)
        return when (kind) {
            "undecryptable" -> "Encrypted message"
            "key" -> "Encryption key"
            else -> words
        }
    }
}

/**
 * The count of texts that came plain from someone encryption is on with ([E2e.arrived]), apart from Android so it is
 * tested: how a text is told, and how the count moves.
 */
object E2ePlain {
    /** `sealed`, `plain`, or `ours`: a key or a chat background, which the app writes itself and says nothing either way. */
    fun kindOf(body: String): String = when {
        E2eCrypto.isSealed(body) -> "sealed"
        E2eCrypto.keyIn(body) != null || BackgroundWire.valueIn(body) != null -> "ours"
        else -> "plain"
    }

    /** The count and how much of it has been put away, after a text of [kind] comes. */
    fun next(count: Int, seen: Int, kind: String): Pair<Int, Int> = when (kind) {
        // They are sealing again: there is nothing to warn of.
        "sealed" -> 0 to 0
        "plain" -> (count + 1) to seen
        else -> count to seen
    }

    /** How many have come that the person has not put away: more than none is a warning to show. */
    fun unseen(count: Int, seen: Int): Int = (count - seen).coerceAtLeast(0)
}
