package com.infamousvague.ghostmessaging

import android.content.Context
import com.google.mlkit.genai.common.DownloadCallback
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.summarization.Summarization
import com.google.mlkit.genai.summarization.SummarizationRequest
import com.google.mlkit.genai.summarization.Summarizer
import com.google.mlkit.genai.summarization.SummarizerOptions
import java.util.concurrent.TimeUnit

/**
 * Summaries of unread conversations, made on the phone itself (Matt, 2026-11-14: "Use a local AI to summarize unread
 * message conversations like apple does"). The model is Android's own (Gemini Nano, kept by AICore), asked through
 * ML Kit's GenAI Summarization API (com.google.mlkit:genai-summarization 1.0.0-beta1): nothing leaves the phone, and
 * nothing of ours is downloaded. A phone without it says so ([status] "unavailable") and the list shows the texts as
 * it always has. Called off the main thread (MainActivity's bg).
 *
 * The words come as a conversation, one line a text, "<name>: <words>", which is the input the API's conversation
 * mode reads; the answer is one bullet, which is a line under the conversation's name.
 */
object Summaries {
    @Volatile private var summarizer: Summarizer? = null
    @Volatile private var downloading = false

    /** The one summarizer, made the first time it is wanted: a conversation in, one bullet out, in English. */
    private fun client(context: Context): Summarizer = summarizer ?: synchronized(this) {
        summarizer ?: Summarization.getClient(
            SummarizerOptions.builder(context.applicationContext)
                .setInputType(SummarizerOptions.InputType.CONVERSATION)
                .setOutputType(SummarizerOptions.OutputType.ONE_BULLET)
                .setLanguage(SummarizerOptions.Language.ENGLISH)
                .setLongInputAutoTruncationEnabled(true)
                .build(),
        ).also { summarizer = it }
    }

    /** Where the model stands on this phone: "available", "downloading", "downloadable" or "unavailable". */
    fun status(context: Context): String = try {
        when (client(context).checkFeatureStatus().get(15, TimeUnit.SECONDS)) {
            FeatureStatus.AVAILABLE -> "available"
            FeatureStatus.DOWNLOADING -> "downloading"
            FeatureStatus.DOWNLOADABLE -> if (downloading) "downloading" else "downloadable"
            else -> "unavailable"
        }
    } catch (e: Throwable) {
        DevLog.add(context, "summary", "status: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
        "unavailable"
    }

    /** Asks AICore for the model where it can be had and is not here yet. It comes over Wi-Fi in the background. */
    fun prepare(context: Context): String {
        val now = status(context)
        if (now != "downloadable") return now
        downloading = true
        try {
            client(context).downloadFeature(object : DownloadCallback {
                override fun onDownloadStarted(bytesToDownload: Long) {}
                override fun onDownloadProgress(totalBytesDownloaded: Long) {}
                override fun onDownloadCompleted() { downloading = false }
                override fun onDownloadFailed(e: GenAiException) {
                    downloading = false
                    DevLog.add(context, "summary", "download failed: ${e.message ?: ""}".take(200))
                }
            })
        } catch (e: Throwable) {
            downloading = false
            DevLog.add(context, "summary", "download: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
        }
        return "downloading"
    }

    /** One line saying what [conversation] is about, or null where the model is not here or could not say. */
    fun summarize(context: Context, conversation: String): String? {
        if (conversation.isBlank() || status(context) != "available") return null
        return try {
            val said = client(context).runInference(SummarizationRequest.builder(conversation).build()).get(60, TimeUnit.SECONDS).summary
            tidy(said)
        } catch (e: Throwable) {
            DevLog.add(context, "summary", "summarize: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
            null
        }
    }

    /** The one bullet as a line: its mark and its spaces taken off. */
    fun tidy(said: String?): String? {
        val line = (said ?: return null).lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: return null
        return line.removePrefix("*").removePrefix("•").removePrefix("-").trim().ifEmpty { null }
    }
}
