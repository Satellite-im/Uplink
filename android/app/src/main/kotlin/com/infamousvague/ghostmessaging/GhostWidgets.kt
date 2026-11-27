package com.infamousvague.ghostmessaging

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.format.DateUtils
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService

/**
 * The home screen widgets (Matt, 2026-11-25: "Create a few android widgets at multiple sizes for the ghost app"), three
 * of them, each drawn to the size it is given:
 *
 * - **Unread** ([UnreadWidget]): how many conversations are waiting. A count beside the mark at its smallest; the
 *   count and who from across four cells; the count over a few names at two by two and larger.
 * - **Conversations** ([ChatsWidget]): the newest conversations in a list that scrolls, each with its face, its last
 *   words and when; a press opens that one. As many rows as its height holds. Nothing but the rows, and those large
 *   (Matt, 2026-11-25: "increase the size of the items in the ghost messaging widget and remove the ghost messaging
 *   title on it").
 * - **People** ([PeopleWidget]): the faces of who was written with last: four in a row, eight in two rows, twelve
 *   where there is the width (a Fold's inner screen).
 *
 * All three read the phone's own conversations (Store.conversationsPage: texts, and Google Messages' beside it), so
 * they are right while the app is closed. Chats on other networks and with friends by username are kept by the app's
 * Dart side and are not in them yet. Nothing is read where texts may not be: the widget then says nothing is here.
 * Redrawn when a notification is shown or put away and when the app is left ([refresh]), and every half hour.
 */
object GhostWidgets {
    data class Chat(val thread: Long, val name: String, val snippet: String, val date: Long, val unread: Boolean, val photo: String?, val many: Boolean)

    /** The newest conversations as the app's own list has them, without the archived and the blocked. */
    fun chats(context: Context, limit: Int): List<Chat> = try {
        @Suppress("UNCHECKED_CAST")
        val items = Store(context).conversationsPage(limit = limit * 2 + 8)["items"] as List<Map<String, Any?>>
        items.filter { it["archived"] != true && it["blocked"] != true }.take(limit).map { c ->
            @Suppress("UNCHECKED_CAST")
            val people = (c["people"] as? List<Map<String, Any?>>).orEmpty()
            val names = people.map { (it["name"] as? String)?.takeIf { n -> n.isNotBlank() } ?: (it["address"] as? String ?: "") }
            Chat(
                thread = c["id"] as Long,
                name = (c["name"] as? String)?.takeIf { it.isNotBlank() } ?: names.joinToString(", ").ifBlank { "Conversation" },
                snippet = ((c["snippet"] as? String) ?: "").replace('\n', ' ').trim(),
                date = (c["date"] as? Long) ?: 0L,
                unread = c["unread"] == true,
                photo = if (people.size == 1) people[0]["photo"] as? String else null,
                many = people.size > 1 || c["group"] != null,
            )
        }
    } catch (e: Exception) {
        emptyList()
    }

    /** A press that opens the app at [thread], as its notification does (Notifier.open). */
    fun open(context: Context, thread: Long): PendingIntent =
        PendingIntent.getActivity(context, thread.toInt(), Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(Notifier.EXTRA_THREAD, thread)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** A press that opens the app where it was. */
    fun openApp(context: Context): PendingIntent =
        PendingIntent.getActivity(context, 9_100_001, Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    /** Every widget on the home screen drawn again: something came, was read, or the app was left. */
    fun refresh(context: Context) {
        val app = context.applicationContext
        Thread {
            try {
                val manager = AppWidgetManager.getInstance(app)
                for (kind in listOf(UnreadWidget::class.java, ChatsWidget::class.java, PeopleWidget::class.java)) {
                    val ids = manager.getAppWidgetIds(ComponentName(app, kind))
                    if (ids.isEmpty()) continue
                    app.sendBroadcast(Intent(app, kind).apply {
                        action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                        putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                    })
                }
            } catch (_: Exception) {
            }
        }.start()
    }

    /** "3m", "2h", "Tue", "Nov 3": when, as short as a row has room for. */
    fun whenShort(date: Long): String {
        if (date <= 0) return ""
        val ago = System.currentTimeMillis() - date
        return when {
            ago < 60_000 -> "now"
            ago < 3_600_000 -> "${ago / 60_000}m"
            ago < 86_400_000 -> "${ago / 3_600_000}h"
            ago < 6 * 86_400_000L -> DateUtils.formatDateTime(null, date, DateUtils.FORMAT_SHOW_WEEKDAY or DateUtils.FORMAT_ABBREV_WEEKDAY)
            else -> DateUtils.formatDateTime(null, date, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_ABBREV_MONTH or DateUtils.FORMAT_NO_YEAR)
        }
    }

    private val hues = intArrayOf(0xFF5B8DEF.toInt(), 0xFFE08A1E.toInt(), 0xFF3AA675.toInt(), 0xFFC45BD6.toInt(), 0xFFD9534F.toInt(), 0xFF2AA7B8.toInt(), 0xFF8A7BE8.toInt())

    /** [chat]'s face, round: the contact's photo where the phone has one, else their initials on a colour of their own. */
    fun face(context: Context, chat: Chat, px: Int = 132): Bitmap {
        val out = Bitmap.createBitmap(px, px, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val photo = chat.photo?.let { uri ->
            try {
                context.contentResolver.openInputStream(Uri.parse(uri))?.use { BitmapFactory.decodeStream(it) }
            } catch (_: Exception) {
                null
            }
        }
        if (photo != null) {
            val side = minOf(photo.width, photo.height)
            val square = Bitmap.createBitmap(photo, (photo.width - side) / 2, (photo.height - side) / 2, side, side)
            val scaled = Bitmap.createScaledBitmap(square, px, px, true)
            paint.shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            canvas.drawCircle(px / 2f, px / 2f, px / 2f, paint)
            return out
        }
        val hue = hues[Math.floorMod(chat.name.hashCode(), hues.size)]
        paint.color = Color.argb(46, Color.red(hue), Color.green(hue), Color.blue(hue))
        canvas.drawCircle(px / 2f, px / 2f, px / 2f, paint)
        val words = chat.name.split(' ', ',').filter { it.isNotBlank() && it[0].isLetterOrDigit() }
        val letters = when {
            chat.many -> words.take(2).joinToString("") { it.take(1) }
            words.size >= 2 -> "${words.first().take(1)}${words.last().take(1)}"
            else -> words.firstOrNull()?.take(1) ?: "#"
        }.uppercase()
        paint.color = hue
        paint.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        paint.textAlign = Paint.Align.CENTER
        paint.textSize = px * (if (letters.length > 1) 0.36f else 0.44f)
        canvas.drawText(letters, px / 2f, px / 2f - (paint.descent() + paint.ascent()) / 2f, paint)
        return out
    }

    /** One of [layouts] for each size the launcher may give (Android 12 and later); before that, the one that fits now. */
    fun sized(manager: AppWidgetManager, id: Int, layouts: List<Pair<SizeF, RemoteViews>>): RemoteViews {
        if (Build.VERSION.SDK_INT >= 31) return RemoteViews(layouts.toMap())
        val options = manager.getAppWidgetOptions(id)
        val w = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        val h = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
        return layouts.lastOrNull { it.first.width <= w && it.first.height <= h }?.second ?: layouts.first().second
    }
}

/** How many conversations are waiting, and who from. */
class UnreadWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        Thread {
            try {
                val unread = GhostWidgets.chats(context, 60).filter { it.unread }
                val count = unread.size
                fun views(layout: Int, names: Int): RemoteViews = RemoteViews(context.packageName, layout).apply {
                    setTextViewText(R.id.widget_count, "$count")
                    setTextViewText(R.id.widget_label, if (count == 0) "All read" else if (layout == R.layout.widget_unread_small) "unread" else if (count == 1) "unread conversation" else "unread conversations")
                    if (layout != R.layout.widget_unread_small) {
                        val who = unread.take(names).map { it.name }
                        val more = count - who.size
                        val joined = if (layout == R.layout.widget_unread_tall) who.joinToString("\n") else who.joinToString(", ")
                        setTextViewText(R.id.widget_who, if (count == 0) "Nothing is waiting" else if (more > 0) "$joined${if (layout == R.layout.widget_unread_tall) "\n" else ", "}and $more more" else joined)
                    }
                    // One waiting: a press opens it. Otherwise the app, where the unread are at the top.
                    setOnClickPendingIntent(R.id.widget_root, if (count == 1) GhostWidgets.open(context, unread[0].thread) else GhostWidgets.openApp(context))
                }
                for (id in ids) {
                    manager.updateAppWidget(id, GhostWidgets.sized(manager, id, listOf(
                        SizeF(100f, 40f) to views(R.layout.widget_unread_small, 0),
                        SizeF(230f, 40f) to views(R.layout.widget_unread_wide, 3),
                        SizeF(100f, 110f) to views(R.layout.widget_unread_tall, 3),
                        SizeF(230f, 110f) to views(R.layout.widget_unread_tall, 4),
                    )))
                }
            } catch (_: Exception) {
            } finally {
                pending.finish()
            }
        }.start()
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = onUpdate(context, manager, intArrayOf(id))
}

/** The newest conversations, in a list. */
class ChatsWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_chats).apply {
                setRemoteAdapter(R.id.widget_list, Intent(context, ChatsWidgetService::class.java).apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
                })
                setEmptyView(R.id.widget_list, R.id.widget_empty)
                setOnClickPendingIntent(R.id.widget_empty, GhostWidgets.openApp(context))
                // Each row fills in which conversation; the list itself knows only that a press opens the app.
                setPendingIntentTemplate(R.id.widget_list, PendingIntent.getActivity(context, 9_100_002, Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_VIEW
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }, PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
            manager.updateAppWidget(id, views)
        }
        @Suppress("DEPRECATION")
        manager.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
    }
}

class ChatsWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = object : RemoteViewsFactory {
        private var chats: List<GhostWidgets.Chat> = emptyList()
        override fun onCreate() {}
        override fun onDestroy() {}
        override fun onDataSetChanged() { chats = GhostWidgets.chats(applicationContext, 25) }
        override fun getCount() = chats.size
        override fun getItemId(position: Int) = chats.getOrNull(position)?.thread ?: position.toLong()
        override fun hasStableIds() = true
        override fun getViewTypeCount() = 1
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewAt(position: Int): RemoteViews {
            val views = RemoteViews(packageName, R.layout.widget_chat_row)
            val c = chats.getOrNull(position) ?: return views
            views.setTextViewText(R.id.widget_name, c.name)
            views.setTextViewText(R.id.widget_snippet, c.snippet)
            views.setTextViewText(R.id.widget_time, GhostWidgets.whenShort(c.date))
            views.setImageViewBitmap(R.id.widget_face, GhostWidgets.face(applicationContext, c, 150))
            views.setViewVisibility(R.id.widget_unread_dot, if (c.unread) View.VISIBLE else View.INVISIBLE)
            views.setOnClickFillInIntent(R.id.widget_row, Intent().putExtra(Notifier.EXTRA_THREAD, c.thread))
            return views
        }
    }
}

/** The faces of who was written with last. */
class PeopleWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        Thread {
            try {
                val chats = GhostWidgets.chats(context, 12)
                val faces = chats.map { GhostWidgets.face(context, it, 132) }
                // [across] faces a row, in one row or two; with names under them where [named].
                fun views(across: Int, rows: Int, named: Boolean): RemoteViews = RemoteViews(context.packageName, R.layout.widget_people).apply {
                    removeAllViews(R.id.widget_people_one)
                    removeAllViews(R.id.widget_people_two)
                    val shown = chats.take(across * rows)
                    setViewVisibility(R.id.widget_empty, if (shown.isEmpty()) View.VISIBLE else View.GONE)
                    setViewVisibility(R.id.widget_people_one, if (shown.isEmpty()) View.GONE else View.VISIBLE)
                    setViewVisibility(R.id.widget_people_two, if (rows > 1 && shown.size > across) View.VISIBLE else View.GONE)
                    for ((i, c) in shown.withIndex()) {
                        val person = RemoteViews(context.packageName, R.layout.widget_person).apply {
                            setImageViewBitmap(R.id.widget_face, faces[i])
                            setTextViewText(R.id.widget_name, c.name.substringBefore(' ').substringBefore(','))
                            setViewVisibility(R.id.widget_name, if (named) View.VISIBLE else View.GONE)
                            setOnClickPendingIntent(R.id.widget_person, GhostWidgets.open(context, c.thread))
                        }
                        addView(if (i < across) R.id.widget_people_one else R.id.widget_people_two, person)
                    }
                    setOnClickPendingIntent(R.id.widget_root, GhostWidgets.openApp(context))
                }
                for (id in ids) {
                    manager.updateAppWidget(id, GhostWidgets.sized(manager, id, listOf(
                        SizeF(100f, 40f) to views(2, 1, false),
                        SizeF(230f, 40f) to views(4, 1, false),
                        SizeF(230f, 70f) to views(4, 1, true),
                        SizeF(100f, 110f) to views(2, 2, false),
                        SizeF(230f, 150f) to views(4, 2, true),
                        SizeF(360f, 70f) to views(6, 1, true),
                        SizeF(360f, 150f) to views(6, 2, true),
                    )))
                }
            } catch (_: Exception) {
            } finally {
                pending.finish()
            }
        }.start()
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = onUpdate(context, manager, intArrayOf(id))
}
