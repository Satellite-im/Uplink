package com.infamousvague.ghostmessaging

import android.content.Context
import android.os.Build
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The app's own short record of what went wrong and how its picture messages went, for Settings › Developer (Matt,
 * 2026-11-13: "Maybe it would be good to include a developer setting with copying errors and reporting"). A phone
 * that is not plugged into a computer has no other way to say why something failed.
 *
 * It keeps the last [KEEP] lines in the app's own files and nothing leaves the phone unless the person copies or
 * shares it. No message's words go in it, and anything that looks like a phone number is struck out ([scrub]).
 */
object DevLog {
    private const val KEEP = 300
    private val stamp = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    private fun file(context: Context) = File(context.filesDir, "devlog.txt")

    /**
     * What looks like a phone number is struck out: seven or more digits in a row, or a number written with its
     * breaks ("(555) 123-0001", "+1 555-123-0001"). Sizes, codes and times ("4000x3000 2143 KB", "HTTP 413") are not.
     */
    private val number = Regex("(\\+?\\d{7,})|((\\+?\\d{1,3}[\\s.-])?\\(?\\d{3}\\)?[\\s.-]\\d{3}[\\s.-]\\d{4})")

    /** [line] with every phone number in it replaced by "[number]". */
    fun scrub(line: String): String = number.replace(line, "[number]")

    /** One line, under [tag]: what was tried and what came of it. */
    @Synchronized
    fun add(context: Context, tag: String, line: String) {
        try {
            val f = file(context)
            f.appendText("${stamp.format(Date())} ${tag.padEnd(5)} ${scrub(line.replace('\n', ' ')).take(600)}\n")
            if (f.length() > 96 * 1024) f.writeText(f.readLines().takeLast(KEEP).joinToString("\n", postfix = "\n"))
        } catch (_: Exception) {}
    }

    /** The lines, the newest last. */
    @Synchronized
    fun lines(context: Context): List<String> = try { file(context).readLines().takeLast(KEEP) } catch (_: Exception) { emptyList() }

    @Synchronized
    fun clear(context: Context) { try { file(context).delete() } catch (_: Exception) {} }

    /** Everything worth sending to whoever is helping: the phone, the app, picture messages as they stand, the lines. */
    fun report(context: Context, version: String): String {
        val mms = try { MmsDiag.status(context) } catch (_: Exception) { emptyMap() }
        fun last(key: String): String {
            @Suppress("UNCHECKED_CAST") val m = mms[key] as Map<String, Any?>? ?: return "none yet"
            return "${if (m["ok"] == true) "worked" else "failed"}: ${m["detail"]} (${stamp.format(Date(m["at"] as Long))})"
        }
        val head = listOf(
            "Uplink $version",
            "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "Carrier: ${mms["carrier"] ?: "not said"} · mobile data: ${when (mms["dataOn"]) { true -> "on"; false -> "off"; else -> "not said" }} · picture messages allowed: ${when (mms["allowed"]) { true -> "yes"; false -> "no"; else -> "not said" }} · largest: ${(mms["maxBytes"] as Int?)?.let { "${it / 1024} KB" } ?: "not said"}",
            "Last picture message sent: ${last("lastSend")}",
            "Last picture message received: ${last("lastDownload")}",
            "Waiting to be fetched: ${mms["waiting"] ?: 0}",
            "",
        )
        val body = lines(context)
        return (head + (if (body.isEmpty()) listOf("(nothing in the log)") else body)).joinToString("\n")
    }
}
