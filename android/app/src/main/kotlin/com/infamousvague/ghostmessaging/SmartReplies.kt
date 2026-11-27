package com.infamousvague.ghostmessaging

import android.content.Context
import com.google.mlkit.nl.smartreply.SmartReply
import com.google.mlkit.nl.smartreply.SmartReplyGenerator
import com.google.mlkit.nl.smartreply.SmartReplySuggestionResult
import com.google.mlkit.nl.smartreply.TextMessage
import com.google.android.gms.tasks.Tasks
import java.util.concurrent.TimeUnit

/**
 * Replies to choose from, made on the phone by a small model that reads the conversation (Matt, 2026-11-26: "add more
 * intelligent auto replies using a very lightweight local AI"). The model is ML Kit's Smart Reply, inside the app
 * (com.google.mlkit:smart-reply, a few megabytes): it works on every phone, with no download and nothing sent
 * anywhere, and reads the last ten texts of a conversation, whose they are and when, to say three replies to the
 * newest. English only: in another language it says nothing and lib/plugins/replies.dart keeps its own replies.
 * Called off the main thread (MainActivity's bg).
 */
object SmartReplies {
    @Volatile private var generator: SmartReplyGenerator? = null

    private fun client(): SmartReplyGenerator = generator ?: synchronized(this) {
        generator ?: SmartReply.getClient().also { generator = it }
    }

    /**
     * Three replies to the newest of [messages] (oldest first; each `{mine, who, text, at}`), or an empty list where
     * the model has none: the newest is the person's own, the language isn't English, or nothing fits.
     */
    fun suggest(context: Context, messages: List<Map<String, Any?>>): List<String> {
        val talk = messages.takeLast(10).mapNotNull { m ->
            val text = (m["text"] as? String)?.trim().orEmpty()
            if (text.isEmpty()) return@mapNotNull null
            val at = (m["at"] as? Number)?.toLong() ?: System.currentTimeMillis()
            if (m["mine"] == true) TextMessage.createForLocalUser(text, at)
            else TextMessage.createForRemoteUser(text, at, (m["who"] as? String)?.ifEmpty { null } ?: "them")
        }
        if (talk.isEmpty()) return emptyList()
        return try {
            val r = Tasks.await(client().suggestReplies(talk), 10, TimeUnit.SECONDS)
            if (r.status != SmartReplySuggestionResult.STATUS_SUCCESS) emptyList()
            else r.suggestions.map { it.text.trim() }.filter { it.isNotEmpty() }.distinct().take(3)
        } catch (e: Throwable) {
            DevLog.add(context, "replies", "suggest: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
            emptyList()
        }
    }
}
