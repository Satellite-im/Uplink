package com.infamousvague.ghostmessaging

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Where an Uplink account's secrets are kept on the phone (lib/account in the app; Matt, 2026-11-17: "i also want accounts
 * to be generated based on ethereum type addresses with a recovery seed we can back up"): the recovery words, so the
 * phone can sign as the account (its devices, a new password) without asking for them. Sealed with AES-GCM under a key
 * of its own in the Android Keystore, as this phone's encryption key is (E2e.kt), in a preferences file of its own, so
 * resetting encryption does not take the account with it. Nothing here is ever logged.
 */
object AccountVault {
    private const val PREFS = "account_vault"
    private const val ALIAS = "ghost_account_wrap"

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** The Keystore's AES key that seals what is kept here, made the first time it is wanted. */
    private fun wrapKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as SecretKey?)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    /** Keeps [value] under [name], sealed; an empty one forgets it. */
    fun keep(context: Context, name: String, value: String) {
        if (value.isEmpty()) {
            prefs(context).edit().remove(name).commit()
            return
        }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrapKey())
        // Stored as the Keystore's 12-byte nonce, then the sealed words with their tag.
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        prefs(context).edit().putString(name, Base64.getEncoder().encodeToString(sealed)).commit()
    }

    /** What was kept under [name], or null where nothing is or it cannot be opened (the Keystore key lost). */
    fun read(context: Context, name: String): String? {
        val stored = prefs(context).getString(name, null) ?: return null
        return try {
            val raw = Base64.getDecoder().decode(stored)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrapKey(), GCMParameterSpec(128, raw, 0, 12))
            String(cipher.doFinal(raw, 12, raw.size - 12), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }
}
