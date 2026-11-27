package com.infamousvague.ghostmessaging

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Asks the app's Dart side something and waits for its answer: what a paired computer asks that only Dart knows
 * (Settings › Me, whose conversation with the relay server is Dart's: lib/me/me.dart). Matt, 2026-11-14: "on desktop
 * the phone number reads as unknown and is not proxying the verification process".
 *
 * Dart answers only while the app's screen has an engine ([channel], set by MainActivity). Without one the computer
 * is told to open the app on the phone. Called from the computers' worker threads, never the main one.
 */
object DartAsk {
    @Volatile var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    /** There is no engine to ask: its message is the computer's to show. */
    class NotOpen : IllegalStateException("Open Uplink on your phone, then try again.")

    /**
     * Calls [method] in Dart on the main thread and waits here for its answer, [seconds] at most. Throws, in words for
     * the computer, where Dart said no, does not know the method (an older app) or did not answer in time.
     */
    fun ask(method: String, args: Any?, seconds: Long = 40): Any? {
        val ch = channel ?: throw NotOpen()
        val done = CountDownLatch(1)
        var answer: Any? = null
        var problem: String? = null
        main.post {
            try {
                ch.invokeMethod(method, args, object : MethodChannel.Result {
                    override fun success(result: Any?) { answer = result; done.countDown() }
                    override fun error(code: String, message: String?, details: Any?) { problem = message ?: "That did not work."; done.countDown() }
                    override fun notImplemented() { problem = "Update Uplink on your phone first."; done.countDown() }
                })
            } catch (e: Exception) {
                problem = "Open Uplink on your phone, then try again."
                done.countDown()
            }
        }
        if (!done.await(seconds, TimeUnit.SECONDS)) throw IllegalStateException("The phone did not answer in time.")
        problem?.let { throw IllegalStateException(it) }
        return answer
    }
}
