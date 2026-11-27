package com.infamousvague.ghostmessaging

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * The app's own updates, from the box: `apk.json` and the APK it names under [BASE], published by tool/release.mjs
 * (Matt, 2026-11-13: "add auto update and serve it over ghost-sms.com"). Ghost Keyboard's Updater.kt, less its Offline
 * guard: this is the one place Uplink opens a connection to, and nothing of the person's goes with it.
 *
 * What makes it safe to install what was downloaded:
 * - the file is handed on only at exactly the size and SHA-256 that apk.json gives;
 * - it must be this app (same package) at the version code apk.json gives;
 * - it must be signed by the same certificate as the installed app, checked here before Android's installer, which
 *   refuses an update signed by any other key in any case. So a changed file on the box can at worst offer an update
 *   that is never installed.
 *
 * Debug builds never look. A build signed by another key than the release's (one made on a machine without the
 * release key) looks, and is told the download is not signed by its key: it is replaced once by the release from
 * gogho.st (ghost-sms.com before 2026-11-15, which still serves the copies installed then), and updates itself from then on.
 *
 * The release found last is written down ([FOUND]), so it is still on offer after the app has been restarted
 * ([restore]).
 */
object Updater {
    const val BASE = "https://gogho.st"
    private const val ACTION_INSTALLED = "com.infamousvague.ghostmessaging.INSTALL_STATUS"
    private const val PREFS = "updates"
    private const val CHECKED_AT = "checked_at"
    /** The newest release a check has seen, so Settings can say one is waiting until it is installed. */
    private const val LATEST_CODE = "latest_code"
    /** The release a check found last, as JSON (version, code, sha256, bytes, url), until it is installed. */
    private const val FOUND = "found"
    private const val BACKGROUND_EVERY_MS = 12 * 60 * 60 * 1000L
    private const val PAGE_EVERY_MS = 5 * 60 * 1000L
    private const val FOCUS_FLOOR_MS = 60 * 1000L

    /** What apk.json says of the newest release: its version and code, the APK's hash and size, and where it is. */
    data class Release(val version: String, val code: Long, val sha256: String, val bytes: Long, val url: String)

    /** Where an update stands, as the settings app shows it. */
    data class State(
        val phase: String = "idle", // idle, disabled, checking, upToDate, available, downloading, ready, installing, failed
        val available: Release? = null,
        val progress: Double? = null,
        val error: String? = null,
    ) {
        fun toMap(context: Context): Map<String, Any?> = mapOf(
            "phase" to phase,
            "current" to currentVersion(context),
            "currentCode" to currentCode(context),
            "available" to available?.version,
            "availableCode" to available?.code,
            "progress" to progress,
            "error" to error,
            "source" to BASE,
            "auto" to auto(context),
            "waiting" to waiting(context),
            "canInstall" to context.packageManager.canRequestPackageInstalls(),
            // The release's file is here at its full size: installing it needs no connection.
            "downloaded" to (available != null && whole(context, available)),
        )
    }

    @Volatile var state = State()
        private set

    private val listeners = mutableSetOf<(State) -> Unit>()
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    @Volatile private var busy = false

    fun addListener(l: (State) -> Unit) { listeners += l }
    fun removeListener(l: (State) -> Unit) { listeners -= l }

    /** The new state, kept and told to every listener on the main thread. */
    private fun set(next: State) {
        state = next
        main.post { listeners.toList().forEach { it(next) } }
    }

    fun isDebuggable(context: Context) = context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    fun currentVersion(context: Context): String = packageInfo(context).versionName ?: "?"

    fun currentCode(context: Context): Long {
        val info = packageInfo(context)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
    }

    private fun packageInfo(context: Context): PackageInfo = context.packageManager.getPackageInfo(context.packageName, 0)

    /**
     * Looks for a newer release. With [install], goes on to download and install it. With [silentOnly] (the look
     * as the app opens), installs only where Android lets this app update itself with no prompt, and
     * otherwise leaves the download ready for the settings app.
     */
    fun check(context: Context, install: Boolean, silentOnly: Boolean = false) {
        val app = context.applicationContext
        if (isDebuggable(app)) { set(State(phase = "disabled", error = "Updates are off in debug builds.")); return }
        if (busy) return
        busy = true
        set(state.copy(phase = "checking", error = null))
        io.execute {
            try {
                app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(CHECKED_AT, System.currentTimeMillis()).apply()
                val release = fetchRelease(app)
                app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putLong(LATEST_CODE, release.code.toLong()).apply()
                if (release.code <= currentCode(app)) {
                    forget(app)
                    set(State(phase = "upToDate"))
                    return@execute
                }
                remember(app, release)
                set(State(phase = "available", available = release))
                if (install) downloadAndInstall(app, release, silentOnly)
            } catch (e: Exception) {
                failed(app, e)
            } finally {
                busy = false
            }
        }
    }

    /**
     * The app's look as it opens, at most twice a day: installs where automatic updates are on, and otherwise only
     * notes the release, so Settings can say one is waiting.
     */
    fun backgroundCheck(context: Context) {
        val app = context.applicationContext
        if (isDebuggable(app)) return
        val last = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(CHECKED_AT, 0L)
        if (System.currentTimeMillis() - last < BACKGROUND_EVERY_MS) return
        check(app, install = auto(app), silentOnly = true)
    }

    /**
     * The look as a page of the app opens (Matt, 2026-11-13: "the app should auto check for updates on load of any
     * page so it pops the banner"): asked for by every page, answered no oftener than every five minutes, so walking
     * through the app is one question to the site and not one a page. What it finds is on the banner over every
     * page (lib/ui/update_banner.dart); it installs by itself only where automatic updates are on and Android lets
     * the app update with no prompt, as the look at opening does.
     */
    fun pageCheck(context: Context) {
        val app = context.applicationContext
        if (isDebuggable(app)) return
        val last = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(CHECKED_AT, 0L)
        if (System.currentTimeMillis() - last < PAGE_EVERY_MS) return
        check(app, install = auto(app), silentOnly = true)
    }

    /**
     * The look whenever the app is in front (Matt, 2026-11-14: "it should auto check for updates when the app is in
     * focus"): each time it comes forward, and every ten minutes while it stays there (MainActivity.focusChecks).
     * No oftener than once a minute, so flicking between apps is not a question to the site each time. What it
     * finds is on the banner over every page; it installs by itself only where automatic updates are on and
     * Android lets the app update with no prompt, as every other look does.
     */
    fun focusCheck(context: Context) {
        val app = context.applicationContext
        if (isDebuggable(app)) return
        val last = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(CHECKED_AT, 0L)
        if (System.currentTimeMillis() - last < FOCUS_FLOOR_MS) return
        check(app, install = auto(app), silentOnly = true)
    }

    /** Automatic updates: on unless switched off in Settings. */
    fun auto(context: Context): Boolean = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("auto", true)

    fun setAuto(context: Context, on: Boolean) {
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("auto", on).apply()
    }

    /** Whether a release newer than this build has been seen. */
    fun waiting(context: Context): Boolean =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getLong(LATEST_CODE, 0L) > currentCode(context)

    /** Settings' "Update now": install the release already found (or look again first). */
    fun installNow(context: Context) {
        restore(context)
        val release = state.available
        if (release == null) { check(context, install = true); return }
        val app = context.applicationContext
        if (busy) return
        busy = true
        io.execute {
            try {
                downloadAndInstall(app, release, silentOnly = false)
            } catch (e: Exception) {
                failed(app, e)
            } finally {
                busy = false
            }
        }
    }

    /** Whether [release]'s file is here at its full size. Its hash is checked when it comes to be installed. */
    private fun whole(context: Context, release: Release): Boolean = apkFile(context, release).length() == release.bytes

    /** Writes down the release a check found, so it outlives the process. */
    private fun remember(context: Context, release: Release) {
        val json = JSONObject().put("version", release.version).put("code", release.code).put("sha256", release.sha256).put("bytes", release.bytes).put("url", release.url)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(FOUND, json.toString()).apply()
    }

    /** Lets go of the release written down: it was installed, or the box no longer has a newer one. */
    private fun forget(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(FOUND).apply()
    }

    /**
     * After a restart: the release a check found before is on offer again, "ready" where its file is here whole and
     * "available" where it is not. Opens no connection, and changes nothing while an update is already known or under
     * way. Called as the app starts, and before "Update now".
     */
    fun restore(context: Context) {
        if (state.available != null || busy || state.phase != "idle") return
        val app = context.applicationContext
        if (isDebuggable(app)) return
        val release = runCatching {
            val o = JSONObject(app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(FOUND, null) ?: return)
            Release(o.getString("version"), o.getLong("code"), o.getString("sha256"), o.getLong("bytes"), o.getString("url"))
        }.getOrNull() ?: return
        if (release.code <= currentCode(app)) { forget(app); return }
        set(State(phase = if (whole(app, release)) "ready" else "available", available = release))
    }

    /** A check or a download that did not finish. */
    /**
     * What went wrong, for Settings › Updates. Two of them the screen says in its own words rather than Java's:
     * "offline" (this phone has no connection) and "notServing" (the site is not there to ask: no certificate, no
     * such name, nothing answering, or no release published yet).
     */
    private fun failed(context: Context, e: Exception) {
        val error = when {
            !online(context) -> "offline"
            e is NotServing || e is javax.net.ssl.SSLException || e is java.net.UnknownHostException || e is java.net.ConnectException -> "notServing"
            else -> e.message ?: e.javaClass.simpleName
        }
        set(state.copy(phase = "failed", progress = null, error = error))
    }

    /** The update server has no release to offer (it answered 404), which is not the same as it being unreachable. */
    private class NotServing(message: String) : IllegalStateException(message)

    /** Whether Android says there is a connection at all; true where it will not say. */
    private fun online(context: Context): Boolean = try {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        cm.getNetworkCapabilities(cm.activeNetwork)?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) ?: false
    } catch (_: Exception) { true }

    // --- the steps --------------------------------------------------------------------------------------------------

    /** A GET of the box, uncached, over https, following no redirect. */
    private fun open(url: String): HttpURLConnection {
        if (!url.startsWith("https://")) throw IllegalStateException("Updates come over https only.")
        return (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 30_000
            useCaches = false
            instanceFollowRedirects = false
            setRequestProperty("Cache-Control", "no-cache")
        }
    }

    /**
     * Reads apk.json and refuses anything odd in it: more than 64 KB, a hash that is not a SHA-256, or a file that is
     * neither an https address nor a bare name beside it.
     */
    private fun fetchRelease(context: Context): Release {
        val conn = open("$BASE/apk.json?t=${System.currentTimeMillis()}")
        try {
            if (conn.responseCode == 404) throw NotServing("The update server answered 404.")
            if (conn.responseCode != 200) throw IllegalStateException("The update server answered ${conn.responseCode}.")
            val body = conn.inputStream.use { it.readBytes() }
            if (body.size > 64 * 1024) throw IllegalStateException("apk.json is too large.")
            val json = JSONObject(String(body, Charsets.UTF_8))
            val url = json.getString("url")
            if (!url.startsWith("https://") && !Regex("^[A-Za-z0-9._-]+$").matches(url)) throw IllegalStateException("apk.json names a bad file.")
            val sha = json.getString("sha256").lowercase()
            if (!Regex("^[0-9a-f]{64}$").matches(sha)) throw IllegalStateException("apk.json has a bad hash.")
            return Release(json.getString("version"), json.getLong("versionCode"), sha, json.getLong("bytes"), url)
        } finally {
            conn.disconnect()
        }
    }

    /** Where a release's APK is kept: the app's cache, named by its version code. */
    private fun apkFile(context: Context, release: Release) =
        File(File(context.cacheDir, "updates").apply { mkdirs() }, "ghost-messaging-${release.code}.apk")

    /**
     * Downloads [release] unless a whole copy is here already, checks it, and hands it to Android's installer. With
     * [silentOnly] it stops at "ready" where Android would ask the person; without it, where installs are not allowed.
     */
    private fun downloadAndInstall(context: Context, release: Release, silentOnly: Boolean) {
        val file = apkFile(context, release)
        if (!(file.exists() && file.length() == release.bytes && sha256(file) == release.sha256)) {
            // The right size and the wrong hash is not the release: it goes, so it is never taken for a download that is ready.
            if (file.exists() && file.length() == release.bytes) file.delete()
            download(context, release, file)
        }
        verifyArchive(context, file, release)
        if (silentOnly && !canUpdateSilently(context)) {
            set(State(phase = "ready", available = release))
            return
        }
        if (!silentOnly && !context.packageManager.canRequestPackageInstalls()) {
            set(State(phase = "ready", available = release, error = "needsPermission"))
            return
        }
        set(State(phase = "installing", available = release))
        commit(context, file)
    }

    private fun download(context: Context, release: Release, file: File) {
        // One release kept at a time: older downloads go.
        file.parentFile?.listFiles()?.forEach { if (it != file) it.delete() }
        val url = if (release.url.startsWith("https://")) release.url else "$BASE/${release.url}"
        val part = File(file.path + ".part")
        val digest = MessageDigest.getInstance("SHA-256")
        val conn = open(url)
        try {
            if (conn.responseCode != 200) throw IllegalStateException("The download answered ${conn.responseCode}.")
            var got = 0L
            var lastShown = -1
            conn.inputStream.use { input ->
                part.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        got += n
                        if (got > release.bytes) throw IllegalStateException("The download is larger than the release says.")
                        digest.update(buf, 0, n)
                        out.write(buf, 0, n)
                        val pct = (got * 100 / release.bytes).toInt()
                        if (pct != lastShown) {
                            lastShown = pct
                            set(State(phase = "downloading", available = release, progress = got.toDouble() / release.bytes))
                        }
                    }
                }
            }
            if (got != release.bytes) throw IllegalStateException("The download stopped short.")
            if (digest.digest().toHex() != release.sha256) throw IllegalStateException("The download does not match the release's hash.")
            if (!part.renameTo(file)) throw IllegalStateException("Could not keep the download.")
        } finally {
            conn.disconnect()
            part.delete()
        }
    }

    /** The download is this app, at the release's version, signed by the installed app's certificate. */
    private fun verifyArchive(context: Context, file: File, release: Release) {
        val pm = context.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        @Suppress("DEPRECATION")
        val archive = pm.getPackageArchiveInfo(file.path, flags) ?: throw IllegalStateException("The download is not an app.")
        if (archive.packageName != context.packageName) throw IllegalStateException("The download is another app (${archive.packageName}).")
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) archive.longVersionCode else @Suppress("DEPRECATION") archive.versionCode.toLong()
        if (code != release.code) throw IllegalStateException("The download is version $code, not ${release.code}.")
        val ours = signers(pm.getPackageInfo(context.packageName, flags))
        val theirs = signers(archive)
        // An archive whose signers this Android cannot read is left to the installer, which checks them itself.
        if (theirs.isNotEmpty() && ours.isNotEmpty() && theirs != ours) throw IllegalStateException("The download is not signed by this app's key.")
    }

    /** The SHA-256 of each certificate a package is signed with, as hex. */
    private fun signers(info: PackageInfo): Set<String> {
        val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
        } else {
            @Suppress("DEPRECATION") info.signatures
        }
        return sigs.orEmpty().filterNotNull().map { MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).toHex() }.toSet()
    }

    /** Android 12+ lets an app update itself with no prompt once it installed its own last version. */
    private fun canUpdateSilently(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        if (!context.packageManager.canRequestPackageInstalls()) return false
        val source = runCatching { context.packageManager.getInstallSourceInfo(context.packageName).installingPackageName }.getOrNull()
        return source == context.packageName
    }

    /** Copies the APK into an install session and commits it; Android answers through [InstallReceiver]. */
    private fun commit(context: Context, file: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("base.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val intent = Intent(context, InstallReceiver::class.java).setAction(ACTION_INSTALLED)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            session.commit(PendingIntent.getBroadcast(context, id, intent, flags).intentSender)
        }
    }

    /**
     * What the installer said of the session: its own prompt to show, done, or why not. An install the person turned
     * down goes back to "available"; any other failure is "failed".
     */
    internal fun onInstallStatus(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)?.let { runCatching { context.startActivity(it) } }
            }
            PackageInstaller.STATUS_SUCCESS -> { forget(context); set(State(phase = "upToDate")) }
            else -> {
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                set(state.copy(phase = if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "available" else "failed", progress = null, error = message ?: "The install did not finish ($status)."))
            }
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) { val n = input.read(buf); if (n < 0) break; digest.update(buf, 0, n) }
        }
        return digest.digest().toHex()
    }

    private fun ByteArray.toHex() = joinToString("") { "%02x".format(it) }
}

/** Where Android's installer reports on a session [Updater] committed. */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Updater.onInstallStatus(context, intent)
}
