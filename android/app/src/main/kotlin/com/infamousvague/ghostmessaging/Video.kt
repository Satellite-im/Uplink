package com.infamousvague.ghostmessaging

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.MediaController
import android.widget.TextView
import android.widget.VideoView
import java.io.ByteArrayOutputStream

/**
 * A video in a picture message (Matt, 2026-11-14: "mp4 files are not loading it just shows up as a string of text
 * for the filename"): a picture of where it starts and how long it runs, for the conversation to draw, and a screen
 * that plays it. A video was drawn as its file's name and nothing else.
 */
object Video {
    private const val TAG = "GhostMessaging"

    /** The longer side of the picture made of a video, in pixels: enough for a bubble on any screen. */
    const val SIDE = 720

    /** How large a picture [width] by [height] is drawn so that its longer side is [SIDE] at most, never enlarged. */
    fun fitted(width: Int, height: Int): Pair<Int, Int> {
        val longer = maxOf(width, height)
        if (longer <= SIDE || longer <= 0) return width to height
        val scale = SIDE.toDouble() / longer
        return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
    }

    /** A video's size as it plays: one kept on its side ([turn] 90 or 270 degrees) is as tall as it is kept wide. */
    fun turned(width: Int, height: Int, turn: Int): Pair<Int, Int> = if (turn == 90 || turn == 270) height to width else width to height

    /**
     * The video in the message part [part]: `picture` (a JPEG of where it starts, or null where none can be made:
     * a kind this phone cannot read, or sound alone), `millis` (how long it runs, 0 where unknown), and the picture's
     * `width` and `height`. And the video as it arrived (Matt, 2026-11-14: "the videos sent from iphone are
     * extremely low quality"; a phone that sends one as a picture message shrinks it to fit the carrier's limit, and
     * the conversation says how small it came): `videoWidth` and `videoHeight`, its own size as it plays, and
     * `bytes`, its file's; 0 where not known.
     */
    fun preview(context: Context, part: Long): Map<String, Any?> {
        val m = MediaMetadataRetriever()
        // One from Google Messages' connection (GmWeb) is a file in the cache, brought down first; the rest are MMS parts.
        val uri = if (GmWeb.isPart(part)) (GmWeb.file(context, part)?.let { Uri.fromFile(it) } ?: return mapOf("picture" to null, "millis" to 0L, "width" to 0, "height" to 0)) else Uri.parse("content://mms/part/$part")
        return try {
            m.setDataSource(context.applicationContext, uri)
            val millis = m.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val (videoWidth, videoHeight) = turned(
                m.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0,
                m.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0,
                m.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0,
            )
            val bytes = try {
                if (uri.scheme == "file") java.io.File(uri.path!!).length()
                else context.applicationContext.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L
            } catch (e: Exception) { 0L }
            // The first frame that can be drawn by itself: where the video starts, or just after.
            val frame = try { m.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC) } catch (e: Exception) { null }
            var picture: ByteArray? = null
            var width = 0
            var height = 0
            if (frame != null) {
                val (w, h) = fitted(frame.width, frame.height)
                val small = if (w != frame.width || h != frame.height) Bitmap.createScaledBitmap(frame, w, h, true) else frame
                val out = ByteArrayOutputStream()
                small.compress(Bitmap.CompressFormat.JPEG, 82, out)
                picture = out.toByteArray()
                width = w
                height = h
            }
            mapOf("picture" to picture, "millis" to millis, "width" to width, "height" to height, "videoWidth" to videoWidth, "videoHeight" to videoHeight, "bytes" to maxOf(0L, bytes))
        } catch (e: Exception) {
            Log.w(TAG, "video preview", e)
            mapOf("picture" to null, "millis" to 0L, "width" to 0, "height" to 0)
        } finally {
            try { m.release() } catch (_: Exception) {}
        }
    }
}

/**
 * A message's video as a file the app's own player can open (lib/ui/video_screen.dart): one from Google Messages'
 * connection is its cached file (GmWeb); an MMS part is copied to the cache once. Null where it cannot be had.
 * Blocks: never on the main thread.
 */
fun videoFile(context: Context, part: Long, ending: String?): String? {
    if (GmWeb.isPart(part)) return GmWeb.file(context, part)?.absolutePath
    val dir = java.io.File(context.cacheDir, "videos").apply { mkdirs() }
    val safe = (ending ?: "mp4").filter { it.isLetterOrDigit() }.ifEmpty { "mp4" }
    val f = java.io.File(dir, "$part.$safe")
    if (!f.exists() || f.length() == 0L) {
        try {
            context.contentResolver.openInputStream(Uri.parse("content://mms/part/$part"))?.use { inp -> f.outputStream().use { inp.copyTo(it) } } ?: return null
        } catch (_: Exception) { f.delete(); return null }
    }
    return f.absolutePath
}

/**
 * Plays the video in a message's part, the whole screen: Android's own player and its own controls (play, pause,
 * where it has got to), over black. It is read from where the message keeps it; nothing is copied anywhere.
 */
class VideoActivity : Activity() {
    companion object {
        const val PART = "part"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val part = intent.getLongExtra(PART, -1)
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        setContentView(root)
        if (part < 0) { finish(); return }
        val video = VideoView(this)
        root.addView(video, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER))
        val controls = MediaController(this)
        controls.setAnchorView(video)
        video.setMediaController(controls)
        video.setOnPreparedListener {
            video.start()
            // The controls show as it starts, so there is something to hold: they hide themselves after a moment.
            controls.show(2500)
        }
        video.setOnErrorListener { _, what, extra ->
            Log.w("GhostMessaging", "video play: $what/$extra")
            root.removeView(video)
            root.addView(TextView(this).apply {
                text = "This video can't be played on this phone."
                setTextColor(Color.WHITE)
                textSize = 16f
                gravity = Gravity.CENTER
            }, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            true
        }
        if (!GmWeb.isPart(part)) {
            video.setVideoURI(Uri.parse("content://mms/part/$part"))
            return
        }
        // From Google Messages' connection: brought down first (a moment, for a long one), then played from the file.
        val waiting = TextView(this).apply {
            text = "Getting the video…"
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
        }
        root.addView(waiting, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        Thread {
            val f = GmWeb.file(applicationContext, part)
            runOnUiThread {
                if (isFinishing) return@runOnUiThread
                if (f == null) {
                    waiting.text = "This video couldn't be brought down from Google Messages."
                } else {
                    root.removeView(waiting)
                    video.setVideoURI(Uri.fromFile(f))
                }
            }
        }.start()
    }
}
