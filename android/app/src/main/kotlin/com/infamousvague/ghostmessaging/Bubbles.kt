package com.infamousvague.ghostmessaging

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import java.util.concurrent.ConcurrentHashMap

/**
 * Conversation bubbles (GMFB-8, from @kevin: "It would be nice to have message bubbles that just sit on the side of
 * the screen like google messages and facebook messenger"; Matt asked for it to be built). A conversation's
 * notification carries Android's bubble metadata, which opens [BubbleActivity] on that one conversation; Android
 * decides whether it shows as a bubble, by its own setting for the app and for each conversation (Android 11 and
 * later). Uplink's own switch is Settings › Notifications › Bubbles ("notif_bubbles", on unless switched off).
 */
object Bubbles {
    /** The key of Uplink's own switch in the "ui" preferences: "off", or anything else for on. */
    const val PREF = "notif_bubbles"

    /** Android's bubbles are the conversation kind from Android 11 (API 30); on 10 they were a developer option. */
    const val MIN_SDK = 30

    /** Whether a conversation's notification offers a bubble: Android 11 or later, and Uplink's switch not off. */
    fun wanted(pref: String?, sdk: Int): Boolean = sdk >= MIN_SDK && pref != "off"

    /** The same, read from this phone: its Android and the switch as kept. */
    fun wanted(context: Context): Boolean =
        wanted(context.getSharedPreferences("ui", Context.MODE_PRIVATE).getString(PREF, "on"), Build.VERSION.SDK_INT)

    /**
     * A conversation was read (opened, marked read, answered from its notification): its notification goes, unless
     * it is showing as a bubble ([flags] has Android's FLAG_BUBBLE) and bubbles are wanted. Then it stays, taken out
     * of the shade only, since taking the notification away takes its bubble off the side of the screen with it.
     */
    fun keepsBubble(flags: Int, wanted: Boolean): Boolean = wanted && (flags and Notification.FLAG_BUBBLE) != 0

    /**
     * What Android's own bubble setting for the app is, for Settings › Notifications: "all" (every conversation
     * may bubble), "selected" (only the ones the person chose, from a notification's bubble button), "none", or
     * null where the phone has no conversation bubbles (before Android 11). Android 12 says it as a preference
     * ([preference], NotificationManager.BUBBLE_PREFERENCE_*: 0 none, 1 all, 2 selected); Android 11 only as allowed
     * or not ([allowed]), where allowed means the conversations the person chose.
     */
    fun systemState(sdk: Int, preference: Int?, allowed: Boolean?): String? = when {
        sdk < MIN_SDK -> null
        preference != null -> when (preference) { 1 -> "all"; 2 -> "selected"; else -> "none" }
        allowed == true -> "selected"
        else -> "none"
    }

    /** The same, asked of this phone; null too where Android would not say. */
    fun systemState(context: Context): String? {
        if (Build.VERSION.SDK_INT < 30) return null
        val nm = context.getSystemService(NotificationManager::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= 31) systemState(Build.VERSION.SDK_INT, nm.bubblePreference, null)
            else @Suppress("DEPRECATION") systemState(Build.VERSION.SDK_INT, null, nm.areBubblesAllowed())
        } catch (_: Exception) { null }
    }

    /**
     * The conversations whose bubble is open on the screen now ([BubbleActivity] resumed): a message that comes into
     * one is not put in the shade again, and only its sound says it came, as with a conversation open in the app.
     */
    val showing: MutableSet<Long> = ConcurrentHashMap.newKeySet()

    /**
     * The bubble for [thread]: [BubbleActivity] on that conversation, the conversation's face as the bubble's.
     * [quiet] keeps the notification out of the shade (the conversation is open in its bubble, or was read), leaving
     * the bubble where it is. Null where bubbles are not wanted.
     */
    fun metadata(context: Context, thread: Long, icon: Icon, quiet: Boolean): Notification.BubbleMetadata? {
        if (Build.VERSION.SDK_INT < 30 || !wanted(context)) return null
        val intent = Intent(context, BubbleActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            // A data address of its own for each conversation, so their intents (and so their pending intents and
            // documents, documentLaunchMode="always") are never taken for one another.
            data = android.net.Uri.parse("ghostmsg://bubble/$thread")
            putExtra(Notifier.EXTRA_THREAD, thread)
        }
        // Mutable, as Android asks of a bubble's intent: it adds its own extras as it opens the bubble.
        val pending = PendingIntent.getActivity(context, thread.toInt() + 3_000_000, intent, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.BubbleMetadata.Builder(pending, icon)
            .setDesiredHeight(640)
            .setSuppressNotification(quiet)
            .build()
    }

    /**
     * [thread] was read with its notification showing as a bubble: the same notification again, out of the shade and
     * without a sound, so the bubble stays on the side of the screen. False where it is not a bubble (or bubbles are
     * not wanted), for the notification to be taken away as before.
     */
    fun quieten(context: Context, thread: Long): Boolean {
        if (Build.VERSION.SDK_INT < 30) return false
        val nm = context.getSystemService(NotificationManager::class.java)
        val shown = try { nm.activeNotifications.firstOrNull { it.id == thread.toInt() && it.tag == null } } catch (_: Exception) { null } ?: return false
        val n = shown.notification
        val bubble = n.bubbleMetadata ?: return false
        if (!keepsBubble(n.flags, wanted(context))) return false
        if (bubble.isNotificationSuppressed) return true
        val again = Notification.Builder.recoverBuilder(context, n)
            .setOnlyAlertOnce(true)
            .setBubbleMetadata(rebuilt(bubble, quiet = true))
            .build()
        return try { nm.notify(thread.toInt(), again); true } catch (_: SecurityException) { false }
    }

    /** [old] with the same screen, face and height, and its notification in or out of the shade as [quiet] says. */
    private fun rebuilt(old: Notification.BubbleMetadata, quiet: Boolean): Notification.BubbleMetadata? {
        if (Build.VERSION.SDK_INT < 30) return old
        val intent = old.intent ?: return old
        val icon = old.icon ?: return old
        return Notification.BubbleMetadata.Builder(intent, icon)
            .setDesiredHeight(old.desiredHeight.takeIf { it > 0 } ?: 640)
            .setSuppressNotification(quiet)
            .build()
    }
}
