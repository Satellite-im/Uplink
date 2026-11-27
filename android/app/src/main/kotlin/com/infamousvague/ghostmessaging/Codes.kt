package com.infamousvague.ghostmessaging

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Build
import java.security.MessageDigest

/**
 * Sign-in codes handed to Ghost Keyboard (Matt, 2026-11-13: "The messaging app should also work with ghost kbd to
 * proxy verification codes"). The keyboard can read codes from texts by itself, but only with Android's permission
 * to receive texts, which Android 15 refuses an app from outside a store until "Allow restricted settings" is
 * chosen, and Android 17 holds code texts back from every app but the default SMS app for three hours. This app is
 * the default SMS app: it has the text the moment it arrives, and says the code to the keyboard, which shows it
 * above the keys to tap in.
 *
 * Nothing is kept for this. When the keyboard asks, the texts that arrived in the last [KEEP_MS] are looked through
 * for codes ([Notifier.otp], the same finder as the notification's Copy button) and the codes alone are answered:
 * never the words, never who sent them.
 */
object Codes {
    /** A code is offered this long from its text's arrival: Ghost Keyboard's own SmsCodes.KEEP_MS. */
    const val KEEP_MS = 10 * 60_000L
    /** And this many at most: a code asked for again arrives as a second text. */
    const val MAX = 3

    /** A sign-in code and when its text arrived (milliseconds). */
    class Held(val code: String, val at: Long)

    /**
     * The codes in [texts] (each a text's words and when it arrived, in milliseconds) that are still offered at
     * [now]: the newest first, the same code once, [MAX] at most.
     */
    fun pick(texts: List<Pair<String, Long>>, now: Long): List<Held> {
        val out = ArrayList<Held>()
        for ((words, at) in texts.sortedByDescending { it.second }) {
            if (now - at >= KEEP_MS || at > now + 60_000L) continue
            val code = Notifier.otp(words) ?: continue
            if (out.none { it.code == code }) out += Held(code, at)
            if (out.size == MAX) break
        }
        return out
    }

    /** Settings › Ghost Keyboard › Offer sign-in codes: on unless switched off. */
    fun on(context: Context): Boolean = context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString("kbd_codes", "on") != "off"

    fun uri(context: Context): Uri = Uri.parse("content://${context.packageName}.codes/latest")

    /** A text with a code in it has arrived: a keyboard that is watching asks again. */
    fun arrived(context: Context, words: String) {
        if (!on(context) || Notifier.otp(words) == null) return
        try { context.contentResolver.notifyChange(uri(context), null) } catch (_: Exception) {}
    }
}

/**
 * `content://com.infamousvague.ghostmessaging.codes/latest`: the codes of [Codes.pick], as `code` and `at` (when the
 * text arrived, milliseconds since 1970). Read-only.
 *
 * Who may ask: Ghost Keyboard alone, known by its package and the SHA-256 of its release certificate ([KEYBOARDS]),
 * as Ghost.md's KeyboardNotes knows it; a debug build of this app also lets a debug build of the keyboard in, for
 * trying the two on an emulator. Anyone else, and everyone while the switch is off, is answered with nothing.
 */
class CodesProvider : ContentProvider() {
    companion object {
        /** Ghost Keyboard's package and the SHA-256 of its release certificate (~/.config/devkeyboard/cert.sha256). */
        val KEYBOARDS = mapOf(
            "com.infamousvague.devkeyboard" to "92d8d1984e60c634fa5874ccb1770ed1fe63da8fb42135b69bb16849ccf0610a",
        )

        /** Whether one of [KEYBOARDS] is on this phone, signed as it should be: for Settings to say. */
        fun keyboardHere(context: Context): Boolean = KEYBOARDS.any { (pkg, pin) -> certificates(context.packageManager, pkg).any { it == pin || debuggable(context) } }

        private fun debuggable(context: Context) = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

        @Suppress("DEPRECATION")
        private fun certificates(pm: PackageManager, pkg: String): List<String> = runCatching {
            val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(pkg, PackageManager.GET_SIGNING_CERTIFICATES).signingInfo ?: return emptyList()
                if (info.hasMultipleSigners()) info.apkContentsSigners else info.signingCertificateHistory
            } else {
                pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES).signatures
            }
            signatures.orEmpty().map { sig -> MessageDigest.getInstance("SHA-256").digest(sig.toByteArray()).joinToString("") { "%02x".format(it) } }
        }.getOrDefault(emptyList())
    }

    override fun onCreate() = true

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? {
        val context = context ?: return null
        val cursor = MatrixCursor(arrayOf("code", "at"))
        if (uri.lastPathSegment != "latest" || !allowed(context) || !Codes.on(context)) return cursor
        val now = System.currentTimeMillis()
        // Under this app's own identity: the caller has no right to the texts, and is not given them.
        val token = Binder.clearCallingIdentity()
        try {
            val texts = Store(context).recentInbox(now - Codes.KEEP_MS)
            for (held in Codes.pick(texts, now)) cursor.addRow(arrayOf<Any>(held.code, held.at))
        } catch (_: Exception) {
        } finally {
            Binder.restoreCallingIdentity(token)
        }
        return cursor
    }

    /** The caller is Ghost Keyboard, signed with its own key (or, in a debug build of this app, any build of it). */
    private fun allowed(context: Context): Boolean {
        val pm = context.packageManager
        val packages = pm.getPackagesForUid(Binder.getCallingUid()) ?: return false
        return packages.any { pkg ->
            val pin = KEYBOARDS[pkg] ?: return@any false
            debuggable(context) || certificates(pm, pkg).any { it == pin }
        }
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
