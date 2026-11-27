package com.infamousvague.ghostmessaging

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.view.WindowManager

/**
 * Android's part of the app's own lock (GMFB-46, Kevin: "allow for users to lock their app with biometrics, password,
 * pin, or pattern"; lib/app_lock/app_lock.dart, which holds the lock itself: the PIN's hash, the wrong tries, how long
 * away locks). Here is only what Dart can't do:
 *
 * - the fingerprint or face, by the phone's own prompt (the framework's BiometricPrompt: no library added). It only
 *   ever answers yes or no; the PIN is checked in Dart and is always the other way in.
 * - FLAG_SECURE on the app's window while a PIN is set, so the app switcher's picture of the app is blank (and
 *   screenshots of it are off). It has to be on before the app leaves the screen, which is when Android takes that
 *   picture, so it follows "a PIN is set", not "locked now".
 * - notifications without their words while the app is locked ([hidesWords]).
 *
 * How the lock stands is read from the choice Dart writes ([PREF]): nothing with no PIN, "on" locked, "open" in use,
 * or the time in milliseconds at which the app, away now, counts as locked.
 */
object AppLock {
    const val PREF = "app_lock_hide"

    private fun state(ui: SharedPreferences): String = ui.getString(PREF, "") ?: ""

    /** A PIN is set. */
    fun isSet(context: Context): Boolean = state(context.getSharedPreferences("ui", Context.MODE_PRIVATE)).isNotEmpty()

    /**
     * The app is locked, or has been away long enough to be when it is next opened: a notification says "New message"
     * in place of the message's words (Notifier.kt). Who it is from is still said.
     */
    fun hidesWords(ui: SharedPreferences, now: Long = System.currentTimeMillis()): Boolean {
        val s = state(ui)
        if (s == "on") return true
        val at = s.toLongOrNull() ?: return false
        return now >= at
    }

    /** FLAG_SECURE on [activity]'s window, or off it. */
    fun secure(activity: Activity, on: Boolean) {
        try {
            if (on) activity.window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
            else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } catch (_: Exception) {}
    }

    /** Whether this phone has a fingerprint or a face enrolled that the prompt can ask for. */
    @Suppress("DEPRECATION")
    fun canBiometric(context: Context): Boolean = try {
        val bm = context.getSystemService(BiometricManager::class.java)
        when {
            bm == null -> false
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) == BiometricManager.BIOMETRIC_SUCCESS
            else -> bm.canAuthenticate() == BiometricManager.BIOMETRIC_SUCCESS
        }
    } catch (_: Exception) { false }

    /**
     * The phone's prompt for a fingerprint or a face, saying [reason]; [done] once, on the main thread, with whether one
     * was taken. "Use PIN" puts it away. Never the phone's own PIN or pattern: the app's PIN is the other way in.
     */
    fun askBiometric(activity: Activity, reason: String, done: (Boolean) -> Unit) {
        var told = false
        fun tell(ok: Boolean) { if (!told) { told = true; done(ok) } }
        try {
            val exec = activity.mainExecutor
            val b = BiometricPrompt.Builder(activity)
                .setTitle(reason)
                .setNegativeButton("Use PIN", exec) { _, _ -> tell(false) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) b.setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            b.build().authenticate(CancellationSignal(), exec, object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult?) = tell(true)
                override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) = tell(false)
                // A finger not recognised: the prompt stays up and asks again, and ends in one of the two above.
                override fun onAuthenticationFailed() {}
            })
        } catch (_: Exception) {
            tell(false)
        }
    }
}
