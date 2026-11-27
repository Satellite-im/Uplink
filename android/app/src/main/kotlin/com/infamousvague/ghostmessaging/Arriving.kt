package com.infamousvague.ghostmessaging

import android.app.Notification
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.provider.Telephony

/**
 * Coming to Uplink from another texting app (Matt, 2026-11-13: a friend's "messages disappeared they didn't
 * load into ghost messaging", "messages are also not coming through for him", then "can you detect this somehow and
 * then instruct the user how to fix it?").
 *
 * Two things catch people, and neither is this app's doing:
 * - RCS chats (Google Messages, Samsung Messages) are kept inside that app, not in Android's SMS store, where no other
 *   app may read them. They do not appear here, and they are not deleted: they show again when that app is the default.
 * - While RCS chats are on, the number stays registered for RCS. People whose phones use RCS go on sending chats to
 *   it, which never arrive as texts. Turning RCS chats off (in that app, or on Google's page with a code it texts)
 *   ends that.
 *
 * Android tells no other app whether RCS is on for a number, so that is never claimed. What can be seen is which app
 * is being left (the default SMS app before this one), whether it is still on the phone, how many texts Android's
 * store holds and how few of them are recent, and whether this copy came from a file, which is when Android 13 and
 * later may refuse it the SMS role or a permission until "Allow restricted settings" is chosen on its page.
 */
object Arriving {
    /** The texting apps known to keep RCS chats of their own. */
    val RCS_APPS = linkedMapOf(
        "com.google.android.apps.messaging" to "Google Messages",
        "com.samsung.android.messaging" to "Samsung Messages",
    )

    /** Google's page that turns RCS chats off for a number, with a code it sends by text. */
    const val RCS_OFF_URL = "https://messages.google.com/disable-chat"

    private const val OLD = "old_sms_app"
    private const val THIRTY_DAYS = 30L * 24 * 60 * 60 * 1000

    private fun prefs(context: Context) = context.getSharedPreferences("ghost", Context.MODE_PRIVATE)

    private fun installed(context: Context, pkg: String) = try { context.packageManager.getPackageInfo(pkg, 0); true } catch (_: Exception) { false }

    private fun label(context: Context, pkg: String): String = RCS_APPS[pkg] ?: try {
        context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    /**
     * The app being left: the default SMS app while it is another app's (and it is remembered then, for after the
     * switch), else the one remembered, else an RCS app that is on the phone.
     */
    fun oldApp(context: Context): String? {
        val now = try { Telephony.Sms.getDefaultSmsPackage(context) } catch (_: Exception) { null }
        if (now != null && now != context.packageName) {
            prefs(context).edit().putString(OLD, now).apply()
            return now
        }
        prefs(context).getString(OLD, null)?.let { return it }
        return RCS_APPS.keys.firstOrNull { installed(context, it) }
    }

    /** This copy was installed from a file, not by a store: what Android's restricted settings apply to. */
    fun sideloaded(context: Context): Boolean = try {
        val installer = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName
        else @Suppress("DEPRECATION") context.packageManager.getInstallerPackageName(context.packageName)
        installer == null || installer !in setOf("com.android.vending", "com.sec.android.app.samsungapps", "com.amazon.venezia")
    } catch (_: Exception) { true }

    /** How many rows a table has (that match [where]); null where Android will not let it be read. */
    private fun count(context: Context, uri: Uri, where: String? = null, args: Array<String>? = null): Int? = try {
        context.contentResolver.query(uri, arrayOf("_id"), where, args, null)?.use { it.count }
    } catch (_: Exception) { null }

    /** Where the person stands, for the setup screen and Settings › Android. Counts are null until the SMS role is held. */
    fun state(context: Context): Map<String, Any?> {
        val old = oldApp(context)
        val since = (System.currentTimeMillis() - THIRTY_DAYS).toString()
        return mapOf(
            "old" to old,
            "oldLabel" to old?.let { label(context, it) },
            "oldInstalled" to (old != null && installed(context, old)),
            // Known to keep RCS chats of its own. Whether they are on is Android's secret.
            "oldHasRcs" to (old != null && old in RCS_APPS),
            "texts" to count(context, Telephony.Sms.CONTENT_URI),
            "recentTexts" to count(context, Telephony.Sms.CONTENT_URI, "date >= ?", arrayOf(since)),
            "pictures" to count(context, Telephony.Mms.CONTENT_URI),
            "lastReceived" to try {
                context.contentResolver.query(Telephony.Sms.Inbox.CONTENT_URI, arrayOf("date"), null, null, "date DESC LIMIT 1")?.use { if (it.moveToFirst()) it.getLong(0) else null }
            } catch (_: Exception) { null },
            // Samsung Messages keeps its RCS chats at an address of its own: how many are there, where it will say.
            "samsungChats" to count(context, Uri.parse("content://im/chat")),
            "sideloaded" to sideloaded(context),
            "android" to Build.VERSION.SDK_INT,
        )
    }

    private fun start(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); true
    } catch (_: Exception) { false }

    /** The old app's own settings where it offers them (Google Messages does: RCS chats is one tap in), else the app. */
    fun openOld(context: Context): Boolean {
        val old = oldApp(context) ?: return false
        val settings = Intent(Intent.ACTION_MAIN).addCategory(Notification.INTENT_CATEGORY_NOTIFICATION_PREFERENCES).setPackage(old)
        if (settings.resolveActivity(context.packageManager) != null && start(context, settings)) return true
        return context.packageManager.getLaunchIntentForPackage(old)?.let { start(context, it) } ?: false
    }

    /** Android's page for this app: ⋮ at its top has "Allow restricted settings" for a copy that came from a file. */
    fun openAppInfo(context: Context) = start(context, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))

    /** Android's Default apps, to hand the SMS role back for a moment. */
    fun openDefaultApps(context: Context) = start(context, Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))

    fun openRcsOff(context: Context) = start(context, Intent(Intent.ACTION_VIEW, Uri.parse(RCS_OFF_URL)))

    /** Whether [url] is a web address: the only kind a message's link may open. */
    fun isWebAddress(url: String): Boolean {
        val lower = url.trim().lowercase()
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) return false
        val host = lower.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#').substringAfterLast('@').substringBefore(':')
        // A name of two parts or more, none of them empty: "www." and "localhost" are not addresses to open.
        val parts = host.split('.')
        return parts.size >= 2 && parts.none { it.isEmpty() } && host.none { it.isWhitespace() }
    }

    /** Opens a link pressed in a message in the phone's browser. False where it is no web address or nothing takes it. */
    fun openLink(context: Context, url: String): Boolean =
        isWebAddress(url) && start(context, Intent(Intent.ACTION_VIEW, Uri.parse(url.trim())).addCategory(Intent.CATEGORY_BROWSABLE))

}
