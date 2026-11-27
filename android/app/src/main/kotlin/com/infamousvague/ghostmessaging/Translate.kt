package com.infamousvague.ghostmessaging

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.LruCache
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.languageid.LanguageIdentification
import com.google.mlkit.nl.languageid.LanguageIdentificationOptions
import com.google.mlkit.nl.languageid.LanguageIdentifier
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import java.util.concurrent.TimeUnit

/**
 * Texts in another language translated on the phone itself, for the Translate plugin (lib/plugins/translate.dart;
 * Matt, 2026-11-17: "add a translate plugin which can automatically translate texts when detected from another
 * language and show the original text dimmed in a card with the translated text for the actual message bubble").
 *
 * ML Kit's on-device Translation (com.google.mlkit:translate) and its Language Identification with the model inside the
 * app (com.google.mlkit:language-id): the words never leave the phone. A language's model, about 30 MB, is fetched once
 * from Google's servers the first time a text needs it (over Wi-Fi alone unless the person says otherwise), and from
 * then on everything is local. The models translate through English, so two other languages go by way of it.
 *
 * Asked by the screen's channel (MainActivity, on a thread of its own so a slow model never holds the texts up) and by a
 * paired computer over the desk link (Desk.kt's Phone, DeskCalls "translate"), both through [call]. Nothing here
 * waits on a download: a text whose language is not here yet answers "fetching" and Dart asks again a little later.
 */
object Translate {
    /**
     * Past this many letters the rest of a text is left as it came, after the translation: a translation is for reading
     * a text, not a book, and the bubble still holds every word that came.
     */
    private const val MOST = 2000

    /** At most this many translators stay open (each holds its two models in memory). */
    private const val OPEN = 3

    @Volatile private var identifier: LanguageIdentifier? = null

    /**
     * An open translator and how many translations are using it now. One let go (the oldest past [OPEN], memory asked
     * back, its language deleted) is closed only once nobody is in the middle of a translation with it: closed under a
     * running translation, that translation failed, on whichever thread (the screen's, or a computer's) it was.
     */
    private class Open(val translator: Translator) {
        var users = 0
        var retired = false
    }

    /** Open translators by pair ("es>en"), the one used longest ago first. Touched only while holding this object. */
    private val translators = LinkedHashMap<String, Open>(OPEN, 0.75f, true)

    /** What was worked out already while the app is open: scrolling back through a conversation asks again. */
    private val kept = LruCache<String, Map<String, Any?>>(400)

    /** Language pairs whose models are being fetched now ("es>en"). */
    private val fetching = java.util.Collections.synchronizedSet(HashSet<String>())

    /** One request from Dart or a computer: [op] is "text", "languages", "model" or "phoneLanguage". */
    fun call(context: Context, op: String, a: Map<String, Any?>): Any? = when (op) {
        "text" -> translate(
            context,
            text = a["text"] as? String ?: "",
            target = a["to"] as? String ?: phoneLanguage(context),
            known = (a["known"] as? List<*>)?.mapNotNull { it as? String } ?: emptyList(),
            wifiOnly = a["wifiOnly"] as? Boolean ?: true,
            fetch = a["fetch"] as? Boolean ?: true,
        )
        "languages" -> languages(context)
        "model" -> if (a["action"] == "delete") deleteModel(context, a["tag"] as? String ?: "") else fetchModel(context, a["tag"] as? String ?: "", a["wifiOnly"] as? Boolean ?: true)
        "phoneLanguage" -> phoneLanguage(context)
        else -> throw IllegalArgumentException("Not something translation does: $op")
    }

    /** The one language identifier, made the first time it is wanted. */
    private fun identifier(): LanguageIdentifier = identifier ?: synchronized(this) {
        // Every guess is wanted, however unsure: how sure is enough is decided below, by how long the text is.
        identifier ?: LanguageIdentification.getClient(LanguageIdentificationOptions.Builder().setConfidenceThreshold(0.01f).build()).also { identifier = it }
    }

    /**
     * A phone's language codes that are not the models' tags: Norwegian Bokmål and Nynorsk are both the models' "no",
     * Filipino is "tl", and Java's old codes for Hebrew, Indonesian and Yiddish. Without this a Norwegian phone took
     * itself to read no language there is a model for, and translated Norwegian texts into English.
     */
    private val aliases = mapOf("nb" to "no", "nn" to "no", "fil" to "tl", "iw" to "he", "in" to "id", "ji" to "yi")

    /** A language tag as the models name it: "pt-BR" and "pt_BR" are "pt", and the [aliases] are followed. */
    private fun base(tag: String): String = tag.substringBefore('-').substringBefore('_').lowercase().let { aliases[it] ?: it }

    /** The phone's own language, as its base subtag ("en"). */
    fun phoneLanguage(context: Context): String {
        val locales = context.resources.configuration.locales
        return if (locales.isEmpty) "en" else base(locales[0].toLanguageTag())
    }

    /**
     * [text] in [target], when it is plainly in another language: `state` is "done" (with `text` and `from`), "same"
     * (in [target] or one of [known], the languages the person reads), "und" (not sure which language), "unsupported"
     * (a language, or a way of writing one, with no model: Japanese in Latin letters), "fetching" (its model is coming),
     * "waiting-wifi" (its model waits for Wi-Fi), "needs-model" (not here and [fetch] false) or "failed".
     */
    fun translate(context: Context, text: String, target: String, known: List<String>, wifiOnly: Boolean, fetch: Boolean): Map<String, Any?> {
        val whole = text.trim()
        val words = whole.take(MOST)
        val rest = whole.drop(MOST)
        if (words.isEmpty()) return mapOf("state" to "und")
        val to = base(target)
        val reads = (known.map { base(it) } + to).toSet()
        val key = "$to|${reads.sorted().joinToString(",")}|$whole"
        kept.get(key)?.let { return it }
        return try {
            val found = Tasks.await(identifier().identifyPossibleLanguages(words), 5, TimeUnit.SECONDS)
                .filter { it.languageTag != "und" }
                .sortedByDescending { it.confidence }
            val top = found.firstOrNull() ?: return keep(key, mapOf("state" to "und"))
            // A short text is easily mistaken: one of a few words must be plainly one language.
            val count = words.split(Regex("\\s+")).count { it.isNotEmpty() }
            if (top.confidence < (if (count < 7) 0.7f else 0.5f)) return keep(key, mapOf("state" to "und"))
            // Any real chance it is a language the person reads, and it is left alone.
            if (found.any { it.confidence >= 0.15f && base(it.languageTag) in reads }) return keep(key, mapOf("state" to "same", "from" to base(top.languageTag)))
            if (top.languageTag.contains("-Latn")) return keep(key, mapOf("state" to "unsupported", "from" to base(top.languageTag)))
            val from = base(top.languageTag)
            val source = TranslateLanguage.fromLanguageTag(from) ?: return keep(key, mapOf("state" to "unsupported", "from" to from))
            val into = TranslateLanguage.fromLanguageTag(to) ?: return keep(key, mapOf("state" to "unsupported", "from" to from))
            val pair = "$source>$into"
            val here = downloaded()
            if (source !in here || into !in here) {
                if (!fetch) return mapOf("state" to "needs-model", "from" to from)
                // Keyed by how it was asked for: a fetch held for Wi-Fi does not stop one on any network once the
                // person turns "Wi-Fi only" off; it would have waited for Wi-Fi however long that took.
                val asked = "$pair|${if (wifiOnly) "wifi" else "any"}"
                val coming = fetching.contains("$pair|any") || (wifiOnly && fetching.contains(asked))
                if (!coming) {
                    fetching.add(asked)
                    val conditions = DownloadConditions.Builder().apply { if (wifiOnly) requireWifi() }.build()
                    // The models themselves, not through a translator, which may be let go while they come.
                    val models = RemoteModelManager.getInstance()
                    val gets = listOf(source, into).filter { it !in here }.map { models.download(TranslateRemoteModel.Builder(it).build(), conditions) }
                    Tasks.whenAll(gets)
                        .addOnSuccessListener { fetching.remove(asked) }
                        .addOnFailureListener { e ->
                            fetching.remove(asked)
                            DevLog.add(context, "translate", "fetch $pair: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
                        }
                }
                // Asked for on Wi-Fi alone, and not on it: the model comes when the phone is.
                return mapOf("state" to if (wifiOnly && !onWifi(context)) "waiting-wifi" else "fetching", "from" to from)
            }
            val open = take(source, into)
            val said = try { Tasks.await(open.translator.translate(words), 15, TimeUnit.SECONDS) } finally { give(open) }
            if (said.isNullOrBlank()) return mapOf("state" to "failed", "from" to from)
            // What was past [MOST] follows the translation as it came, so the bubble loses none of the text.
            keep(key, mapOf("state" to "done", "text" to (if (rest.isEmpty()) said else "$said $rest"), "from" to from))
        } catch (e: Throwable) {
            DevLog.add(context, "translate", "${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
            mapOf("state" to "failed")
        }
    }

    private fun keep(key: String, answer: Map<String, Any?>): Map<String, Any?> { kept.put(key, answer); return answer }

    /** The pair's translator, opened if it is not, counted as in use until [give]; the oldest past [OPEN] let go. */
    @Synchronized
    private fun take(source: String, target: String): Open {
        val open = translators.getOrPut("$source>$target") {
            Open(Translation.getClient(TranslatorOptions.Builder().setSourceLanguage(source).setTargetLanguage(target).build()))
        }
        open.users++
        while (translators.size > OPEN) {
            val eldest = translators.entries.first()
            translators.remove(eldest.key)
            retire(eldest.value)
        }
        return open
    }

    /** A translator [take] handed out is done with: closed now if it was let go while in use. */
    @Synchronized
    private fun give(open: Open) {
        open.users--
        if (open.retired && open.users <= 0) close(open)
    }

    /** Lets a translator go: closed now if nobody is using it, else by the last [give]. Called holding this object. */
    private fun retire(open: Open) {
        open.retired = true
        if (open.users <= 0) close(open)
    }

    private fun close(open: Open) {
        try { open.translator.close() } catch (_: Throwable) {}
    }

    /** The languages whose models are on the phone; none where ML Kit does not say within five seconds. */
    private fun downloaded(): Set<String> = try {
        Tasks.await(RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java), 5, TimeUnit.SECONDS).map { it.language }.toSet()
    } catch (_: Throwable) { emptySet() }

    private fun onWifi(context: Context): Boolean = try {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
        // Wi-Fi itself, as the models' requireWifi() means it: an unmetered phone network or a cable is not, and the card
        // said "Getting it ready" there for good while the model waited for Wi-Fi.
        caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
    } catch (_: Throwable) { false }

    /** Every language there is a model for: its tag, and whether its model is on the phone (Dart names them). */
    fun languages(context: Context): List<Map<String, Any?>> {
        val here = downloaded()
        return TranslateLanguage.getAllLanguages().sorted().map { mapOf("tag" to it, "downloaded" to (it in here), "fetching" to fetching.any { f -> f.substringBefore('|').split('>').contains(it) }) }
    }

    /** Fetches a language's model ahead of a text needing it. */
    fun fetchModel(context: Context, tag: String, wifiOnly: Boolean): Boolean {
        val lang = TranslateLanguage.fromLanguageTag(base(tag)) ?: return false
        val conditions = DownloadConditions.Builder().apply { if (wifiOnly) requireWifi() }.build()
        RemoteModelManager.getInstance().download(TranslateRemoteModel.Builder(lang).build(), conditions)
            .addOnFailureListener { e -> DevLog.add(context, "translate", "fetch $lang: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200)) }
        return true
    }

    /**
     * Deletes a language's model to give its 30 MB back. The phone's own language, and English (every translation goes
     * through it), are not deleted: the next text would only fetch them again.
     */
    fun deleteModel(context: Context, tag: String): Boolean {
        val lang = TranslateLanguage.fromLanguageTag(base(tag)) ?: return false
        if (lang == TranslateLanguage.ENGLISH || lang == base(phoneLanguage(context))) return false
        synchronized(this) {
            val gone = translators.keys.filter { it.startsWith("$lang>") || it.endsWith(">$lang") }
            for (k in gone) translators.remove(k)?.let { retire(it) }
        }
        kept.evictAll()
        return try {
            Tasks.await(RemoteModelManager.getInstance().deleteDownloadedModel(TranslateRemoteModel.Builder(lang).build()), 10, TimeUnit.SECONDS)
            true
        } catch (e: Throwable) {
            DevLog.add(context, "translate", "delete $lang: ${e.javaClass.simpleName} ${e.message ?: ""}".take(200))
            false
        }
    }

    /** Lets the open translators go, when Android asks for memory back. */
    @Synchronized
    fun release() {
        for (open in translators.values) retire(open)
        translators.clear()
    }
}
