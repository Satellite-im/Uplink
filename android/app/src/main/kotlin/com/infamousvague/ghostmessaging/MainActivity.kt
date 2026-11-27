package com.infamousvague.ghostmessaging

import android.Manifest
import android.app.role.RoleManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import java.io.File
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * The one screen, Flutter's. Two channels: `ghost_messaging/sms` (calls: the provider, sending, the SMS role,
 * permissions) and `ghost_messaging/events` (a conversation changed; a notification or another app asked for one).
 * Every provider call runs on one background thread, in order.
 */
open class MainActivity : FlutterActivity() {
    companion object {
        /** The conversation open on the screen (-1 for none) and whether the app is in front, for notifications. */
        @Volatile var openThread: Long = -1
        @Volatile var inFront = false

        /** The one Flutter engine, kept past the screen so Signal and Telegram stay connected (NetworksService). */
        private const val ENGINE = "main"

        /**
         * Dart's end of `ghost_messaging/events`, kept with the engine: a screen made again over a running engine is
         * not listened to afresh, so it speaks through the sink the first one was given.
         */
        @Volatile private var sharedEvents: EventChannel.EventSink? = null
        // Request codes: which of Android's screens an answer in onActivityResult or a permission result is from.
        private const val ROLE_REQUEST = 41
        private const val PERMS_REQUEST = 42
        private const val PICK_REQUEST = 43
        private const val SCAN_REQUEST = 44
        private const val MIC_REQUEST = 45
        private const val SAVE_REQUEST = 46
    }

    /**
     * This screen is a conversation's bubble (BubbleActivity, GMFB-8): an engine of its own that shows one
     * conversation, beside the app's. It answers the same calls, but leaves the app's own engine its events, its
     * open conversation and its place in front, and starts none of the app's background work.
     */
    protected open val bubble: Boolean = false

    private val io = Executors.newSingleThreadExecutor()

    /**
     * Translation (Translate.kt) on a thread of its own: identifying a language, loading a model and translating can
     * take a second or more, and the texts themselves (on [io]) must not wait behind them.
     */
    private val translating = Executors.newSingleThreadExecutor()

    /** Pictures and faces are read apart from everything else, so they do not wait behind a long read of the list. */
    private val pictures = Executors.newFixedThreadPool(3)

    /**
     * The list of conversations is read on a thread of its own, so a long read of it holds nothing else up: on a
     * phone with three thousand conversations it once held a conversation's messages back for five seconds.
     */
    private val lists = Executors.newSingleThreadExecutor()

    /** Told when the phone's contacts change: who a number is is asked again from then (Store.contactsChanged). */
    private val contactsWatcher = object : android.database.ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { if (::store.isInitialized) { store.contactsChanged(); Desk.contactsChanged(); Bus.changed(-1) } }
    }
    private val main = Handler(Looper.getMainLooper())
    /** A bubble's own end of `ghost_messaging/events`: the app's engine keeps [sharedEvents]. */
    private var bubbleEvents: EventChannel.EventSink? = null
    private var events: EventChannel.EventSink?
        get() = if (bubble) bubbleEvents else sharedEvents
        set(v) { if (bubble) bubbleEvents = v else sharedEvents = v }

    /** A bubble's ears on what changed (Bus.others), taken away with its engine. */
    private var bubbleChanged: ((Long) -> Unit)? = null
    private var bubblePrefs: (() -> Unit)? = null
    private var pendingOpen: Map<String, Any?>? = null
    private var updateListener: ((Updater.State) -> Unit)? = null
    private var roleResult: MethodChannel.Result? = null
    private var permsResult: MethodChannel.Result? = null
    private var pickResult: MethodChannel.Result? = null
    private var scanResult: MethodChannel.Result? = null
    private var micResult: MethodChannel.Result? = null
    private var saveResult: MethodChannel.Result? = null
    private var saveFrom: File? = null

    /**
     * Files shared into the app from another (a Files space's "Add to", lib/ui/files_space/share_in.dart): their content
     * addresses, held until Dart asks for them when it was not yet listening.
     */
    private var pendingShared: List<String>? = null

    /** Answer pressed on a friend's call (IncomingCall.kt, GMFB-28) before Dart was listening: told as it listens. */
    private var pendingRing: String? = null

    /** A friend's call's notification pressed (IncomingCall.kt, GMFB-28): over the lock screen while it rings, and
     *  Answer said to Dart. */
    private fun ringIntent(intent: Intent?) {
        val what = intent?.getStringExtra(IncomingCall.EXTRA) ?: return
        intent.removeExtra(IncomingCall.EXTRA)
        IncomingCall.overLock(this, true)
        if (what != "answer") return
        IncomingCall.end(this)
        val sink = sharedEvents
        if (sink != null) main.post { sink.success(mapOf("type" to "ringAction", "do" to "answer")) } else pendingRing = "answer"
    }
    private lateinit var store: Store

    /**
     * One engine for the app's life, not the screen's (Matt, 2026-11-16, on Signal and Telegram messages while Uplink is
     * out of sight: "Yes, build them"): Dart, and with it Signal's helper and Telegram's TDLib, goes on when Android
     * closes the screen (swiped away from Recents), for as long as NetworksService keeps the process. A screen opened
     * again takes up the running app where it was.
     */
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        FlutterEngineCache.getInstance().get(ENGINE)?.let { return it }
        return FlutterEngine(context.applicationContext).also {
            it.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            FlutterEngineCache.getInstance().put(ENGINE, it)
        }
    }

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        store = Store(applicationContext)
        try { contentResolver.registerContentObserver(android.provider.ContactsContract.Contacts.CONTENT_URI, true, contactsWatcher) } catch (_: Exception) {}
        if (bubble) return configureBubble(flutterEngine)
        // Over an engine already running (the screen closed and opened again, by a notification): Dart has asked for
        // its first open request long ago, so what this screen was opened for is told as an event.
        ringIntent(intent)
        val asked = openRequest(intent, fresh = true)
        if (sharedEvents != null && asked != null) main.post { sharedEvents?.success(mapOf("type" to "open") + asked) } else pendingOpen = asked
        sharedFiles(intent)?.let { uris -> if (sharedEvents != null) main.post { sharedEvents?.success(mapOf("type" to "sharedFiles", "uris" to uris)) } else pendingShared = uris }
        // The computers this phone is paired with (Desk.kt): the service that keeps it reachable by them runs while
        // there is one, and is started here if Android stopped it since.
        DeskService.sync(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "ghost_messaging/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                Bus.listener = { thread -> events?.success(mapOf("type" to "changed", "thread" to thread)) }
                Bus.prefsListener = { events?.success(mapOf("type" to "prefs")) }
                CallService.onLeave = { runOnUiThread { events?.success(mapOf("type" to "leaveCall")) } }
                IncomingCall.onAction = { what -> main.post { events?.success(mapOf("type" to "ringAction", "do" to what)) } }
                pendingRing?.let { what -> pendingRing = null; main.post { events?.success(mapOf("type" to "ringAction", "do" to what)) } }
                Desk.listener = { events?.success(mapOf("type" to "desk")) }
                Voice.listener = { state -> main.post { events?.success(state) } }
                // A data text for the app's routes (NetSms.kt): to Dart, which opens it.
                NetSms.listener = { address, bytes -> main.post { events?.success(mapOf("type" to "netSms", "address" to address, "bytes" to bytes)) } }
                updateListener = { state -> events?.success(mapOf("type" to "update") + state.toMap(applicationContext)) }
                Updater.addListener(updateListener!!)
            }
            override fun onCancel(arguments: Any?) { events = null; Bus.listener = null; Bus.prefsListener = null; Desk.listener = null; Voice.listener = null; NetSms.listener = null; updateListener?.let { Updater.removeListener(it) }; updateListener = null }
        })

        // The on-phone Google Messages connection, where one was paired (GmWeb.kt).
        if (GmWeb.hasSession(applicationContext)) GmWeb.start(applicationContext)

        // The microphone's processing in calls (VoiceFx.kt).
        VoiceFx.register(messenger)
        // A circle's music played here without loss (MusicSink.kt).
        MusicSink.register(applicationContext, messenger)
        // Recording a call (CallRecorder.kt, lib/voice/recorder.dart).
        CallRecorder.register(messenger)
        // A call's picture in picture (CallPip.kt, lib/ui/call_pip.dart; GMFB-64), with what Dart last said set again
        // on this screen.
        CallPip.register(this, messenger)
        CallPip.apply(this)
        // Words from a recorded call, by the phone's own speech recognition (Scribe.kt, lib/voice/scribe.dart).
        Scribe.register(applicationContext, messenger)
        // A call's captions: this phone's own voice written out as it is said (LiveCaptions.kt, lib/voice/captions.dart).
        LiveCaptions.register(applicationContext, messenger)
        // The interface sounds (Sounds.kt, lib/sounds.dart).
        Sounds.register(this, messenger)
        // The walkthrough's voice (GuideVoice.kt).
        GuideVoice.register(this, messenger)
        // The direct network's core is handed the app's context when Dart starts its first node, and not before
        // (P2pCore.kt): registering the channel it asks through loads nothing.
        P2pCore.register(applicationContext, messenger)
        // The local network route hears what is said to a whole Wi-Fi network only while Android is told it listens
        // (LanEar.kt): asked for by Dart as the route opens, and held no longer than it is open.
        LanEar.register(applicationContext, messenger)

        val calls = MethodChannel(messenger, "ghost_messaging/sms")
        // What a paired computer asks that only Dart knows (DartAsk.kt) goes down the same channel.
        DartAsk.channel = calls
        handleCalls(calls)
    }

    /**
     * A conversation's bubble (BubbleActivity): the same calls as the app's screen, and of the events only what
     * changed and the choices changing, through ears of its own (Bus.others) so the app's engine keeps hearing them.
     * Nothing a computer, a call or the app's open request needs: those stay the app's.
     */
    private fun configureBubble(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "ghost_messaging/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
                bubbleChanged?.let { Bus.others.remove(it) }
                bubblePrefs?.let { Bus.prefsOthers.remove(it) }
                val changed: (Long) -> Unit = { thread -> events?.success(mapOf("type" to "changed", "thread" to thread)) }
                val prefs: () -> Unit = { events?.success(mapOf("type" to "prefs")) }
                Bus.others.add(changed)
                Bus.prefsOthers.add(prefs)
                bubbleChanged = changed
                bubblePrefs = prefs
            }
            override fun onCancel(arguments: Any?) { events = null; dropBubbleEars() }
        })
        // The interface sounds (Sounds.kt, lib/sounds.dart): a message sent from the bubble sounds as it does in the app.
        Sounds.register(this, messenger)
        P2pCore.register(applicationContext, messenger)
        handleCalls(MethodChannel(messenger, "ghost_messaging/sms"))
    }

    /** Stops a bubble hearing what changed, as its events are cancelled or its screen goes. */
    private fun dropBubbleEars() {
        bubbleChanged?.let { Bus.others.remove(it) }
        bubblePrefs?.let { Bus.prefsOthers.remove(it) }
        bubbleChanged = null
        bubblePrefs = null
    }

    /** The conversation a bubble shows, from the intent it was opened with (Bubbles.metadata); -1 where none. */
    protected val bubbleThread: Long get() = intent?.getLongExtra(Notifier.EXTRA_THREAD, -1) ?: -1

    /** Answers Dart's calls on "ghost_messaging/sms", for the app's engine and a bubble's alike. */
    private fun handleCalls(calls: MethodChannel) {
        calls.setMethodCallHandler { call, result ->
            // How long each call takes is written to Android's log when asked for
            // (`adb shell setprop log.tag.GhostPerf VERBOSE`): the call's name and its milliseconds, never what it carried.
            val timed = android.util.Log.isLoggable("GhostPerf", android.util.Log.VERBOSE)
            fun on(executor: java.util.concurrent.Executor, work: () -> Any?) = executor.execute {
                val began = android.os.SystemClock.elapsedRealtime()
                try { val v = work(); main.post { result.success(v) } }
                catch (e: Exception) {
                    // What a call could not do goes in the app's own log (Settings › Developer) as well as back to the screen.
                    DevLog.add(applicationContext, "call", "${call.method}: ${e.javaClass.simpleName}: ${e.message ?: ""}")
                    main.post { result.error("failed", e.message ?: e.toString(), null) }
                }
                if (timed) android.util.Log.v("GhostPerf", "${call.method} ${android.os.SystemClock.elapsedRealtime() - began} ms")
            }
            fun bg(work: () -> Any?) = on(io, work)
            when (call.method) {
                "status" -> result.success(status())
                // Android's own question whether the app may run while the phone sleeps (Reach.kt, GMFB-28).
                "askBattery" -> result.success(Reach.ask(this))
                "requestDefault" -> requestDefault(result)
                // Beside Google Messages (GmBridge): Android's page for notification access, and the SMS permissions.
                "bridgeAccess" -> { startActivity(GmBridge.accessIntent(this)); result.success(true) }
                "openGm" -> result.success(GmBridge.open(this))
                "openGmNotifications" -> result.success(GmBridge.openNotificationSettings(this))
                "gmChannels" -> result.success(GmBridge.channelList(this))
                // The on-phone Google Messages connection (GmWeb.kt): how it stands, pairing, unpairing.
                "gmWebState" -> { if (GmWeb.available(this)) GmWeb.start(applicationContext); result.success(GmWeb.state(this)) }
                "gmWebPair" -> bg { GmWeb.start(applicationContext); GmWeb.pair(); GmWeb.state(applicationContext) }
                "gmWebUnpair" -> bg { GmWeb.unpair(); GmWeb.state(applicationContext) }
                "gmWebPairGoogle" -> bg {
                    GmWeb.start(applicationContext)
                    val why = GmWeb.pairGoogle(call.argument<Map<String, String>>("cookies") ?: emptyMap())
                    GmWeb.state(applicationContext) + mapOf("error" to why)
                }
                "openGmChannel" -> result.success(GmBridge.openChannel(this, call.argument<String>("id")!!, call.argument<String>("conversation")))
                "requestSms" -> requestSms(result)
                "requestPermissions" -> requestPermissions(result)
                "openRequest" -> { result.success(pendingOpen); pendingOpen = null }
                "conversations" -> on(lists) { store.conversations() }
                "conversationsPage" -> on(lists) {
                    store.conversationsPage(
                        limit = call.argument<Int>("limit") ?: 0,
                        offset = call.argument<Int>("offset") ?: 0,
                        pinnedToo = call.argument<Boolean>("pinned") ?: false,
                        only = if (call.argument<Boolean>("archived") == true) store.archivedThreads() else null,
                    )
                }
                // Sending a picture message again: its own pictures, read back from Android's store.
                "resendMms" -> bg { Sender.resendMms(applicationContext, call.argument<Number>("id")!!.toLong(), call.argument<String>("body")) }
                // Settings › Developer: the app's own log, to read, copy, share and clear (DevLog.kt).
                "devLog" -> { DevLog.add(applicationContext, call.argument<String>("tag") ?: "app", call.argument<String>("line") ?: ""); result.success(null) }
                "devLogRead" -> bg { mapOf("lines" to DevLog.lines(applicationContext), "report" to DevLog.report(applicationContext, call.argument<String>("version") ?: "")) }
                "devLogClear" -> bg { DevLog.clear(applicationContext); null }
                "shareText" -> {
                    try {
                        startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                            putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        }, call.argument<String>("subject") ?: "Share"))
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "mmsStatus" -> bg { MmsDiag.status(applicationContext) }
                "mmsRetry" -> bg { MmsPushReceiver.retryWaiting(applicationContext) }
                "conversation" -> bg { store.conversation(call.argument<Number>("thread")!!.toLong()) }
                "archivedCount" -> on(lists) { (store.conversationsPage(only = store.archivedThreads())["items"] as List<*>).size }
                "perfOn" -> result.success(timed)
                "messages" -> bg { store.messages(call.argument<Number>("thread")!!.toLong(), call.argument<Int>("limit") ?: 300) }
                "people" -> bg { store.threadPeople(call.argument<Number>("thread")!!.toLong()) }
                "threadFor" -> bg { store.threadFor(call.argument<List<String>>("addresses")!!) }
                "send" -> bg {
                    Sender.send(applicationContext, call.argument<List<String>>("addresses")!!, call.argument<String>("body") ?: "", call.argument<List<String>>("attachments") ?: emptyList())
                }
                // Voice messages (Voice.kt): the microphone is asked for the first time one is recorded.
                "voiceStart" -> {
                    if (granted(Manifest.permission.RECORD_AUDIO)) startVoice(result)
                    else { micResult = result; requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST) }
                }
                "voiceLevel" -> result.success(Voice.level())
                "voiceCancel" -> { Voice.cancel(); result.success(null) }
                "voiceSend" -> bg {
                    val recorded = Voice.stop() ?: throw IllegalStateException("That was too short to send")
                    try {
                        mapOf("thread" to Sender.sendVoice(applicationContext, call.argument<List<String>>("addresses")!!, recorded.first), "millis" to recorded.second)
                    } finally { recorded.first.delete() }
                }
                "voicePlay" -> { Voice.play(applicationContext, call.argument<Number>("part")!!.toLong()); result.success(null) }
                "voicePause" -> { Voice.pause(); result.success(null) }
                "voiceStop" -> { Voice.halt(); result.success(null) }
                "voiceLength" -> on(pictures) { Voice.length(applicationContext, call.argument<Number>("part")!!.toLong()) }
                // A video in a message (Video.kt): a picture of where it starts and how long it runs, and playing it.
                "videoPreview" -> on(pictures) { Video.preview(applicationContext, call.argument<Number>("part")!!.toLong()) }
                "videoFile" -> on(pictures) { videoFile(applicationContext, call.argument<Number>("part")!!.toLong(), call.argument<String>("ending")) }
                "videoPlay" -> {
                    startActivity(Intent(this, VideoActivity::class.java).putExtra(VideoActivity.PART, call.argument<Number>("part")!!.toLong()))
                    result.success(null)
                }
                // Try again, on a picture message that could not be brought down (Store.insertMmsNotice).
                "retryDownload" -> bg { MmsPushReceiver.retry(applicationContext, call.argument<Number>("id")!!.toLong()); null }
                // A friend by username wrote (lib/standalone/overlay.dart keeps their words in Dart): said as a
                // text from a contact would be, unless that conversation is on the screen.
                "notifyChat" -> bg {
                    Notifier.chat(applicationContext, call.argument<Number>("thread")!!.toLong(), call.argument<String>("who") ?: "", call.argument<String>("body") ?: "")
                    null
                }
                "cancelChat" -> bg { Notifier.seen(applicationContext, call.argument<Number>("thread")!!.toLong()); null }
                "markRead" -> bg {
                    val t = call.argument<Number>("thread")!!.toLong()
                    // Read, its notification goes; a bubble of it stays on the side of the screen (Notifier.seen).
                    store.markRead(t); Notifier.seen(applicationContext, t); null
                }
                "deleteThread" -> bg { val t = call.argument<Number>("thread")!!.toLong(); store.deleteThread(t); Notifier.cancel(applicationContext, t); null }
                "deleteMessage" -> bg { store.deleteMessage(call.argument<String>("kind")!!, call.argument<Number>("id")!!.toLong()); null }
                "editMessage" -> bg {
                    store.editMessage(call.argument<String>("kind")!!, call.argument<Number>("id")!!.toLong(), call.argument<String>("body") ?: "")
                    Bus.changed(-1); null
                }
                "threadFlag" -> bg {
                    store.setThreadFlag(call.argument<String>("name")!!, call.argument<Number>("thread")!!.toLong(), call.argument<Boolean>("on") ?: true)
                    Bus.changed(-1); null
                }
                // A conversation's name, this phone's own: a group's (Store.setThreadName).
                // An RCS group's is everyone's: given to Google Messages too (GmWeb.renameGroup), which renames it for all in it.
                "rcsGroup" -> bg { GmWeb.isRcsGroup(call.argument<Number>("thread")!!.toLong()) }
                "threadName" -> bg {
                    val t = call.argument<Number>("thread")!!.toLong(); val name = call.argument<String>("name") ?: ""
                    store.setThreadName(t, name); Bus.changed(-1)
                    GmWeb.renameGroup(t, name)
                }
                "draft" -> bg { store.draft(call.argument<Number>("thread")!!.toLong()) }
                "setDraft" -> bg { store.setDraft(call.argument<Number>("thread")!!.toLong(), call.argument<String>("text") ?: ""); null }
                "setBlocked" -> bg { store.setBlocked(call.argument<String>("address")!!, call.argument<Boolean>("blocked") ?: true); Bus.changed(-1); null }
                "update" -> { Updater.restore(applicationContext); result.success(Updater.state.toMap(applicationContext)) }
                "updateCheck" -> { Updater.check(applicationContext, install = call.argument<Boolean>("install") ?: false); result.success(null) }
                "updateInstall" -> { Updater.installNow(applicationContext); result.success(null) }
                "updateBackground" -> { Updater.backgroundCheck(applicationContext); result.success(null) }
                "updatePage" -> { Updater.pageCheck(applicationContext); result.success(null) }
                "setAutoUpdate" -> { Updater.setAuto(applicationContext, call.argument<Boolean>("on") ?: true); result.success(null) }
                "allowInstalls" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")))
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "e2e" -> bg { E2e.state(applicationContext, call.argument<String>("address")!!) }
                "e2eList" -> bg { E2e.list(applicationContext).map { it + ("person" to store.contact(it["address"] as String)) } }
// The app's routes (lib/net; Net.kt, NetSms.kt): who this phone is, who it can reach, a signature for a
                // hub, and data texts.
                "netIdentity" -> bg { Net.identity(applicationContext) }
                // Each once, by id: those encryption is on with (Net.peers), friends by username (Buddies.peers), then the
                // members of this phone's groups, whose keys came with the group (Groups.peers). A friend who is in a group
                // too is under their own record's address, never the one the group lists (found in review, 2026-11-23).
                "netPeers" -> bg {
                    Net.peers(applicationContext).let { known -> known + Buddies.peers(applicationContext, known.map { it["id"] as String }.toSet()) }
                        .let { known -> known + Groups.peers(applicationContext, known.map { it["id"] as String }.toSet()) }
                }
                // Friends by username (Buddies.kt).
                "buddiesKeep" -> bg { Buddies.keep(applicationContext, call.argument<String>("json") ?: "[]"); null }
                "buddiesKept" -> bg { Buddies.kept(applicationContext) }
                "netSign" -> bg { Net.sign(applicationContext, call.argument<ByteArray>("message")!!) }
                "netSmsAvailable" -> bg { NetSms.available(applicationContext) }
                "netSmsSend" -> bg { NetSms.send(applicationContext, call.argument<String>("address")!!, call.argument<ByteArray>("bytes")!!); null }
                "netSmsDrain" -> bg { NetSms.drain(applicationContext) }
                // Groups of friends (Groups.kt): the records, and what is written in one kept in its conversation.
                "groups" -> bg { Groups.views(applicationContext) }
                "groupOf" -> bg { Groups.ofThread(applicationContext, call.argument<Number>("thread")!!.toLong())?.let { Groups.view(applicationContext, it) } }
                "groupDraft" -> bg { Groups.draft(applicationContext, call.argument<String>("id")!!, call.argument<String>("name") ?: "", call.argument<List<String>>("addresses") ?: emptyList()).toString() }
                "groupMember" -> bg { Groups.member(applicationContext, call.argument<String>("address")!!).toString() }
                "groupSave" -> bg { Groups.save(applicationContext, org.json.JSONObject(call.argument<String>("state")!!)).also { Bus.prefsChanged(); Bus.changed(-1) } }
                "groupForget" -> bg { Groups.forget(applicationContext, call.argument<String>("id")!!); Bus.prefsChanged(); Bus.changed(-1); null }
                "groupTextOut" -> bg { Groups.storeOut(applicationContext, call.argument<String>("id")!!, call.argument<String>("body")!!) }
                "groupTextState" -> bg { Groups.setRow(applicationContext, (call.argument<Number>("row")!!).toLong(), call.argument<String>("state")!!); null }
                "groupTextIn" -> bg { Groups.storeIn(applicationContext, call.argument<String>("id")!!, call.argument<String>("from")!!, call.argument<String>("body")!!, (call.argument<Number>("at") ?: 0).toLong()); null }
                "groupNote" -> bg { Groups.note(applicationContext, call.argument<String>("id")!!, call.argument<String>("body")!!); null }
                // Friends (Friends.kt): where the two stand, and a friend's words kept with the phone's messages.
                "friendSet" -> bg { E2e.setFriend(applicationContext, call.argument<String>("address")!!, call.argument<String>("state") ?: ""); Bus.prefsChanged(); Bus.changed(-1); null }
                "netTextOut" -> bg { Friends.storeOut(applicationContext, call.argument<String>("address")!!, call.argument<String>("body")!!) }
                "netTextState" -> bg { Friends.setRow(applicationContext, (call.argument<Number>("id")!!).toLong(), call.argument<String>("state")!!); null }
                "netTextDrop" -> bg { Friends.dropRow(applicationContext, (call.argument<Number>("id")!!).toLong()); null }
                "netTextIn" -> bg { Friends.storeIn(applicationContext, call.argument<String>("address")!!, call.argument<String>("body")!!, (call.argument<Number>("at") ?: 0).toLong()); null }
                "e2eMine" -> bg { if (E2e.hasIdentity(applicationContext)) E2e.myFingerprint(applicationContext) else null }
                "e2eOffer" -> bg {
                    // This phone's key goes to them as a plain text; where theirs is already here, encryption is on.
                    val address = call.argument<String>("address")!!
                    Sender.send(applicationContext, listOf(address), E2e.keyMessage(applicationContext), plain = true)
                    E2e.offered(applicationContext, address)
                    Bus.changed(-1)
                    E2e.state(applicationContext, address)
                }
                "e2eOff" -> bg { E2e.off(applicationContext, call.argument<String>("address")!!); Bus.changed(-1); null }
                // The warning that their texts are coming without encryption was put away (E2e.arrived).
                "e2ePlainSeen" -> bg { E2e.plainSeen(applicationContext, call.argument<String>("address")!!); Bus.changed(-1); null }
                "e2eVerify" -> bg { E2e.setVerified(applicationContext, call.argument<String>("address")!!, call.argument<Boolean>("verified") ?: true); null }
                "e2eReset" -> bg { E2e.reset(applicationContext); Bus.changed(-1); null }
                // An Uplink account (lib/account; Matt, 2026-11-17: "We need to have a way to login to existing accounts"):
                // this phone's key to seal into its backup, a restored key put in its place, the account's words kept
                // in the Keystore-sealed vault (AccountVault.kt), and a clean restart once a device has signed in.
                "identityExport" -> bg { E2e.exportScalar(applicationContext) }
                "identityImport" -> bg { E2e.importScalar(applicationContext, call.argument<ByteArray>("scalar")!!, call.argument<ByteArray>("public")!!); Bus.changed(-1); null }
                "secretKeep" -> bg { AccountVault.keep(applicationContext, call.argument<String>("name")!!, call.argument<String>("value") ?: ""); null }
                "secretRead" -> bg { AccountVault.read(applicationContext, call.argument<String>("name")!!) }
                // The app's own lock (AppLock.kt, GMFB-46): the fingerprint or face, and the app switcher kept blank.
                "lockBioCan" -> result.success(AppLock.canBiometric(this))
                "lockBioAsk" -> AppLock.askBiometric(this, call.argument<String>("reason") ?: "Unlock Uplink") { ok -> try { result.success(ok) } catch (_: Exception) {} }
                "lockSecure" -> { AppLock.secure(this, call.argument<Boolean>("on") ?: false); result.success(null) }
                "restartApp" -> {
                    // Every choice on the disk first (an empty commit writes what apply() still holds), then this task
                    // started again and the process ended, so the new identity is read from nothing.
                    getSharedPreferences("ui", MODE_PRIVATE).edit().commit()
                    val again = packageManager.getLaunchIntentForPackage(packageName)?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    if (again == null) {
                        result.success(false)
                    } else {
                        result.success(true)
                        Handler(Looper.getMainLooper()).postDelayed({
                            startActivity(again)
                            android.os.Process.killProcess(android.os.Process.myPid())
                        }, 250)
                    }
                }
                "blockedNumbers" -> bg { store.blockedNumbers() }
                // A frame of the video at `path` as a PNG, for its preview in a Files space (Matt, 2026-11-18: "videos
                // having a frame from the first minute of the video"): a tenth of the way in, at least a second, never
                // past the first minute; at most 480 across. Null where Android can't read it.
                "videoFrame" -> bg {
                    val path = call.argument<String>("path")
                    if (path == null) null else try {
                        val r = android.media.MediaMetadataRetriever()
                        try {
                            r.setDataSource(path)
                            val dur = r.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                            val atMs = if (dur > 0) minOf(maxOf(dur / 10, minOf(1000L, dur / 2)), 60_000L) else 1000L
                            val frame = r.getScaledFrameAtTime(atMs * 1000, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC, 480, 480)
                                ?: r.getFrameAtTime(atMs * 1000)
                            if (frame == null) null else java.io.ByteArrayOutputStream().also { frame.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it); frame.recycle() }.toByteArray()
                        } finally {
                            r.release()
                        }
                    } catch (_: Exception) {
                        null
                    }
                }
                // Android's page for the "Paired with…" notification alone, where it can be turned off.
                "deskNotificationSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                            .putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                            .putExtra(android.provider.Settings.EXTRA_CHANNEL_ID, DeskService.CHANNEL))
                    } catch (_: Exception) {
                        try { startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)) } catch (_: Exception) {}
                    }
                    result.success(null)
                }
                // Settings › Notifications › Bubbles (GMFB-8): Android's own page for the app's bubbles, where it decides
                // which conversations may bubble; the app's notification page before Android 11.
                "bubbleSettings" -> {
                    try {
                        startActivity(
                            if (android.os.Build.VERSION.SDK_INT >= 30) Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_BUBBLE_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                            else Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName),
                        )
                    } catch (_: Exception) {
                        try { startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)) } catch (_: Exception) {}
                    }
                    result.success(null)
                }
                // A bubble's "Open in Uplink": the whole app, on the same conversation, as its notification
                // opens it. The bubble folds away as the app comes up.
                "openInApp" -> {
                    val t = call.argument<Number>("thread")?.toLong() ?: -1
                    try {
                        startActivity(Intent(applicationContext, MainActivity::class.java).apply {
                            action = Intent.ACTION_VIEW
                            if (t >= 0) putExtra(Notifier.EXTRA_THREAD, t)
                            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                        })
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "notificationSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName))
                    } catch (_: Exception) {}
                    result.success(null)
                }
                "archive" -> bg { store.setArchived(call.argument<Number>("thread")!!.toLong(), call.argument<Boolean>("archived") ?: true); null }
                "searchContacts" -> bg { store.searchContacts(call.argument<String>("query") ?: "") }
                "contact" -> bg { store.contact(call.argument<String>("address")!!) }
                "photo" -> on(pictures) { store.photo(call.argument<String>("uri")!!) }
                "part" -> on(pictures) { store.readPart(call.argument<Number>("id")!!.toLong()) }
                "pickImages" -> pickImages(result)
                // Telegram's attachments (lib/inbox/telegram.dart): any file, pictures and videos among them; a picked
                // one copied to a file of this app's own, which TDLib sends from; a recording ended as a file; and a
                // file that came opened in whichever app reads it.
                "pickFiles" -> pickImages(result, any = true)
                // A helper of the app's, by its name, in the native libraries Android unpacks (the Signal helper,
                // libsignalsidecar.so): its path where it is there.
                "helperPath" -> result.success(java.io.File(applicationInfo.nativeLibraryDir, "lib${call.argument<String>("name")}.so").takeIf { it.exists() }?.path)
                // The folder of this installed app's that Android's backup never takes (lib/net/kept_files_io.dart: the
                // ledger the relay is checked by keeps its files under it), as Android gives it.
                "keptDir" -> result.success(noBackupFilesDir.absolutePath)
                // A call in a space (CallService.kt): going on with the phone locked, until it ends.
                "callStarted" -> { CallService.start(this, call.argument<String>("name") ?: "", call.argument<Boolean>("video") ?: false, call.argument<Boolean>("screen") ?: false); result.success(null) }
                "callEnded" -> { CallService.stop(this); result.success(null) }
                // A friend calling (lib/voice/friend_calls.dart, GMFB-28): the app's own card says it while it is in
                // front; otherwise a call's notification, full screen on a locked phone.
                "ringIncoming" -> { if (!inFront) IncomingCall.show(this, call.argument<String>("from") ?: "", call.argument<Boolean>("video") ?: false); result.success(null) }
                "ringEnded" -> { IncomingCall.end(this); IncomingCall.overLock(this, false); result.success(null) }
                // Signal and Telegram (lib/inbox/alerts.dart): a new message's notification, taken away once read, and
                // the service that keeps them connected while there are any signed in.
                "notifyInbox" -> bg {
                    Notifier.inbox(applicationContext, call.argument<String>("key")!!, call.argument<String>("network") ?: "", call.argument<String>("title") ?: "",
                        call.argument<String>("body") ?: "", call.argument<Boolean>("group") ?: false)
                    null
                }
                "cancelInbox" -> bg { Notifier.cancelInbox(applicationContext, call.argument<String>("key")!!); null }
                "keepNetworks" -> { NetworksService.keep(applicationContext, call.argument<List<String>>("names").orEmpty(), call.argument<Boolean>("calls") ?: false); result.success(null) }
                // Uplink's own lists of what was deleted beside Google Messages, kept on the account too (lib/kept_lists.dart).
                "hiddenLists" -> bg { mapOf("threads" to store.hiddenThreads().mapKeys { it.key.toString() }, "msgs" to store.hiddenMessages().toList()) }
                "addHiddenLists" -> bg {
                    val threads = (call.argument<Map<String, Number>>("threads") ?: emptyMap()).mapNotNull { (k, v) -> k.toLongOrNull()?.let { it to v.toLong() } }.toMap()
                    val added = store.addHidden(threads, call.argument<List<String>>("msgs") ?: emptyList())
                    if (added) Bus.changed(-1)
                    added
                }
                "cacheCopy" -> bg { cacheCopy(Uri.parse(call.argument<String>("uri")!!)) }
                "voiceFinish" -> bg {
                    val recorded = Voice.stop() ?: throw IllegalStateException("That was too short to send")
                    val out = File(File(cacheDir, "outgoing").apply { mkdirs() }, recorded.first.name)
                    recorded.first.copyTo(out, overwrite = true); recorded.first.delete()
                    mapOf("path" to out.path, "millis" to recorded.second)
                }
                "openFile" -> bg { openFile(File(call.argument<String>("path")!!), call.argument<String>("name")); null }
                // A Files space (lib/files/file_platform.dart): a picked file copied into the app's own folder, so it can
                // go up after the app is closed and opened again (the picker's permission ends with the app); a file
                // saved where the person chooses; one shared to another app; and files shared into this one.
                "keepFile" -> bg { keepFile(Uri.parse(call.argument<String>("uri")!!)) }
                "saveFile" -> saveFile(result, File(call.argument<String>("path")!!), call.argument<String>("name") ?: "file", call.argument<String>("mime") ?: "application/octet-stream")
                "shareFile" -> bg { shareFile(File(call.argument<String>("path")!!), call.argument<String>("name"), call.argument<String>("mime")); null }
                "sharedFiles" -> { result.success(pendingShared ?: emptyList<String>()); pendingShared = null }
                // What files shared in are, read before any is copied, so the "Add … to" sheet can name them (Matt,
                // 2026-11-17: "Finish the missing pieces that went unfinished"): copying waits for a space to be chosen.
                "describeFiles" -> bg { describeFiles(call.argument<List<String>>("uris") ?: emptyList()) }
                // A bubble's conversation is its own (Bubbles.showing, kept as it comes and goes from the screen): the
                // app's open conversation and the keyboard's colour stay the app's.
                "setOpenThread" -> if (bubble) {
                    val t = call.argument<Number>("thread")?.toLong() ?: -1
                    if (t >= 0) io.execute { Notifier.seen(applicationContext, t) }
                    result.success(null)
                } else {
                    openThread = call.argument<Number>("thread")?.toLong() ?: -1
                    if (openThread >= 0) { val t = openThread; io.execute { Notifier.seen(applicationContext, t) } }
                    // Ghost Keyboard wears the open conversation's colour (AccentSync.now).
                    AccentSync.nowChanged(this)
                    result.success(null)
                }
                "dial" -> {
                    try { startActivity(Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", call.argument<String>("address")!!, null))) } catch (_: Exception) {}
                    result.success(null)
                }
                // Things to do with what a message says (lib/plugins/actions.dart): an event for the calendar, a place
                // for the map. Each opens the app Android has for it, with the details filled in, for the person to save.
                "addEvent" -> {
                    val ok = try {
                        val begin = (call.argument<Number>("begin") ?: 0).toLong()
                        startActivity(Intent(Intent.ACTION_INSERT).setData(android.provider.CalendarContract.Events.CONTENT_URI)
                            .putExtra(android.provider.CalendarContract.EXTRA_EVENT_BEGIN_TIME, begin)
                            .putExtra(android.provider.CalendarContract.EXTRA_EVENT_END_TIME, begin + 60 * 60 * 1000L)
                            .putExtra(android.provider.CalendarContract.EXTRA_EVENT_ALL_DAY, call.argument<Boolean>("allDay") == true)
                            .putExtra(android.provider.CalendarContract.Events.TITLE, call.argument<String>("title") ?: "")
                            .putExtra(android.provider.CalendarContract.Events.DESCRIPTION, call.argument<String>("notes") ?: ""))
                        true
                    } catch (_: Exception) { false }
                    result.success(ok)
                }
                "remind" -> result.success(Reminders.schedule(this, (call.argument<Number>("thread") ?: -1).toLong(), call.argument<String>("title") ?: "Reminder", call.argument<String>("body") ?: "", (call.argument<Number>("at") ?: 0).toLong()))
                // Android's new contact with a number filled in (lib/plugins/strangers.dart), for the person to name.
                "addContact" -> {
                    val ok = try {
                        startActivity(Intent(android.provider.ContactsContract.Intents.Insert.ACTION).setType(android.provider.ContactsContract.RawContacts.CONTENT_TYPE)
                            .putExtra(android.provider.ContactsContract.Intents.Insert.PHONE, call.argument<String>("address") ?: ""))
                        true
                    } catch (_: Exception) { false }
                    result.success(ok)
                }
                "openMap" -> {
                    val ok = try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(call.argument<String>("place") ?: ""))))
                        true
                    } catch (_: Exception) { false }
                    result.success(ok)
                }
                "systemPalette" -> result.success(systemPalette())
                // Coming from another texting app (Arriving.kt): what can be seen of it, and the ways out of its traps.
                "arriving" -> bg { Arriving.state(applicationContext) }
// A link pressed in a message (lib/links.dart): the phone's browser, and only for a web address.
                "openLink" -> result.success(Arriving.openLink(this, call.argument<String>("url") ?: ""))
                // Summaries of unread conversations by the phone's own model (Summaries.kt).
                "summaryStatus" -> bg { Summaries.status(this) }
                "summaryPrepare" -> bg { Summaries.prepare(this) }
                "summarize" -> bg { Summaries.summarize(this, call.argument<String>("text") ?: "") }
                // Replies to choose from, by a small model inside the app that reads the conversation (SmartReplies.kt).
                @Suppress("UNCHECKED_CAST")
                "smartReplies" -> bg { SmartReplies.suggest(this, (call.argument<List<Map<String, Any?>>>("messages") ?: emptyList())) }
                // Texts in another language, translated on the phone (Translate.kt, lib/plugins/translate.dart).
                "translate" -> on(translating) { Translate.call(applicationContext, "text", argsOf(call.arguments)) }
                "translateLanguages" -> on(translating) { Translate.call(applicationContext, "languages", emptyMap()) }
                "translateModel" -> on(translating) { Translate.call(applicationContext, "model", argsOf(call.arguments)) }
                "openOldApp" -> result.success(Arriving.openOld(this))
                "openAppInfo" -> result.success(Arriving.openAppInfo(this))
                "openDefaultApps" -> result.success(Arriving.openDefaultApps(this))
                "openRcsOff" -> result.success(Arriving.openRcsOff(this))
                "deleteThreads" -> bg {
                    val threads = (call.argument<List<Number>>("threads") ?: emptyList()).map { it.toLong() }
                    for (t in threads) { store.deleteThread(t); Notifier.cancel(applicationContext, t) }
                    Bus.changed(-1)
                    threads.size
                }
                "sendSticker" -> bg {
                    Sender.sendSticker(applicationContext, call.argument<List<String>>("addresses")!!, call.argument<ByteArray>("picture")!!, call.argument<String>("name") ?: "sticker")
                }
                "keyboardHere" -> bg { CodesProvider.keyboardHere(applicationContext) }
                "ghostPeers" -> bg { Backgrounds.allKnown(applicationContext, call.argument<List<String>>("addresses") ?: emptyList()) }
                "shareBackground" -> bg {
                    // A conversation's background goes to its people as a text (BackgroundWire): the picture with it
                    // where it is one (an MMS), and the tag alone where the text goes sealed.
                    val addresses = call.argument<List<String>>("addresses")!!
                    val thread = call.argument<Number>("thread")!!.toLong()
                    val raw = call.argument<String>("raw")!!
                    val path = raw.removePrefix("image:").takeIf { raw.startsWith("image:") }
                    val bare = path == null && addresses.size == 1 && E2e.isOn(applicationContext, addresses[0])
                    val text = BackgroundWire.text(if (path != null) "image" else raw, bare = bare)
                    Sender.send(applicationContext, addresses, text, if (path != null) listOf(Uri.fromFile(java.io.File(path)).toString()) else emptyList())
                    Backgrounds.sent(applicationContext, thread, raw)
                    null
                }
                "importBackground" -> bg { importBackground(call.argument<String>("uri")!!, call.argument<String>("name") ?: "all") }
                "deleteBackground" -> bg { backgroundFiles(call.argument<String>("name") ?: "all").forEach { it.delete() }; null }
                "prefs" ->result.success(getSharedPreferences("ui", MODE_PRIVATE).all.mapValues { it.value.toString() })
                "setPref" -> {
                    getSharedPreferences("ui", MODE_PRIVATE).edit().putString(call.argument<String>("key")!!, call.argument<String>("value")).apply()
                    // Your bubbles' colour: stamped, and Ghost Keyboard told, to keep the two in step (AccentSync.kt).
                    if (call.argument<String>("key") == "bubble") AccentSync.chosen(this)
                    // A look's nearest keyboard colour, while your bubbles are the look's own: a new look is a new colour.
                    else if (call.argument<String>("key") == "theme_bubble" && getSharedPreferences("ui", MODE_PRIVATE).getString("bubble", null) == "theme") AccentSync.chosen(this)
                    else if (call.argument<String>("key")?.startsWith("bubble_") == true) AccentSync.nowChanged(this)
                    result.success(null)
                }
                // Paired computers (Desk.kt, docs/desktop.md): the list, a pairing being made, and how each connects.
                "deskList" -> bg { Desk.list() }
                "deskAddresses" -> bg { Desk.addresses() }
                "deskState" -> result.success(Desk.state())
                "deskPeek" -> bg { Desk.peek(call.argument<String>("code") ?: "") }
                "deskScan" -> {
                    scanResult = result
                    @Suppress("DEPRECATION")
                    startActivityForResult(Intent(this, ScanActivity::class.java), SCAN_REQUEST)
                }
                "deskBegin" -> bg {
                    val state = Desk.begin(call.argument<String>("code") ?: "", call.argument<String>("mode"))
                    DeskService.sync(applicationContext)
                    state
                }
                "deskPendingMode" -> bg { Desk.setPendingMode(call.argument<String>("mode") ?: "both"); Desk.state() }
                "deskConfirm" -> { Desk.confirm(); result.success(null) }
                "deskCancel" -> { Desk.cancel(); result.success(null) }
                "deskDone" -> { Desk.done(); result.success(null) }
                "deskUnpair" -> bg { Desk.unpair(call.argument<String>("id")!!); null }
                "deskSetMode" -> bg { Desk.setMode(call.argument<String>("id")!!, call.argument<String>("mode") ?: "both"); DeskService.sync(applicationContext); null }
                // Whether Android lets the app use the network in deep sleep (its battery setting "Unrestricted").
                "deskUnrestricted" -> result.success(try { getSystemService(android.os.PowerManager::class.java).isIgnoringBatteryOptimizations(packageName) } catch (_: Exception) { false })
                "ownNumber" -> bg { store.ownNumbers().firstOrNull() }
                "setOwnNumber" -> {
                    getSharedPreferences("ghost", MODE_PRIVATE).edit().putString("own_number", call.argument<String>("number")).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** While the app is in front it looks for an update: as it comes forward, then every ten minutes it stays. */
    private val focusChecks = object : Runnable {
        override fun run() {
            try { Updater.focusCheck(applicationContext) } catch (_: Exception) {}
            main.postDelayed(this, 10 * 60 * 1000L)
        }
    }

    override fun onResume() {
        super.onResume()
        // While the app's own lock has a PIN set the app switcher shows nothing of the app, a bubble's screen too
        // (AppLock.kt, GMFB-46): set again each time, since a screen made anew starts without it.
        AppLock.secure(this, AppLock.isSet(this))
        // A bubble on the screen: its conversation's messages come in quietly (Notifier.incoming). The app's place in
        // front, and what it does as it comes forward, are the app's.
        if (bubble) { if (bubbleThread >= 0) Bubbles.showing.add(bubbleThread); return }
        inFront = true
        // Open: what was said after a restart about opening it has been done (Reach.kt).
        Reach.opened(this)
        // Ghost Keyboard's colour, if chosen there since, and watched while in front (AccentSync.kt).
        io.execute { AccentSync.pull(this) }
        // A look every fifteen minutes for what friends by username wrote while closed; open now, so any "New
        // message" from a look is taken down (HubPeek.kt).
        io.execute { HubPeek.schedule(this); HubPeek.opened(this) }
        accentWatch = AccentSync.watch(this)
        main.removeCallbacks(focusChecks)
        focusChecks.run()
        // Picture messages announced and never fetched are asked for again as the app comes forward.
        io.execute {
            try { MmsPushReceiver.retryWaiting(applicationContext) } catch (_: Exception) {}
            // Ones fetched that could not be read are read again, and ones left on Sending are let go of.
            try { MmsResultReceiver.readKept(applicationContext) } catch (_: Exception) {}
            try {
                val stale = store.failStale()
                if (stale > 0) { DevLog.add(applicationContext, "send", "$stale left on Sending for a quarter of an hour marked not sent"); Bus.changed(-1) }
            } catch (_: Exception) {}
        }
    }

    /** What Dart sent, as a map of plain values; nothing where it sent none. */
    @Suppress("UNCHECKED_CAST")
    private fun argsOf(arguments: Any?): Map<String, Any?> = (arguments as? Map<String, Any?>) ?: emptyMap()

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        // Translators hold their models in memory: given back when Android asks, opened again by the next text.
        if (level >= android.content.ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) Translate.release()
    }

    override fun onDestroy() {
        // The engine goes on without the screen (provideFlutterEngine): what a computer asks of Dart still reaches it.
        try { contentResolver.unregisterContentObserver(contactsWatcher) } catch (_: Exception) {}
        if (bubble) dropBubbleEars()
        super.onDestroy()
    }
    private var accentWatch: android.database.ContentObserver? = null

    override fun onPause() {
        // What was read or sent while the app was open shows on the home screen's widgets (GhostWidgets.kt).
        GhostWidgets.refresh(this)
        super.onPause()
        if (bubble) {
            Bubbles.showing.remove(bubbleThread)
            // A voice message being recorded in the bubble is thrown away as it folds, as the app's is as it leaves.
            if (Voice.recording) { Voice.cancel(); events?.success(mapOf("type" to "voiceStopped")) }
            Voice.pause()
            return
        }
        inFront = false
        AccentSync.unwatch(this, accentWatch)
        accentWatch = null
        main.removeCallbacks(focusChecks)
        // The microphone is open only while the person is recording with the app in front: leaving throws the
        // recording away, and the screen is told so.
        if (Voice.recording) {
            Voice.cancel()
            events?.success(mapOf("type" to "voiceStopped"))
        }
        Voice.pause()
    }

    /** Starts recording a voice message, and answers how many seconds one may run on this carrier. */
    private fun startVoice(result: MethodChannel.Result) {
        try { result.success(mapOf("ok" to true, "seconds" to Voice.start(applicationContext, Sender.voiceBudget(applicationContext)))) }
        catch (e: Exception) { result.error("failed", e.message ?: "The microphone could not be started", null) }
    }

    /** Leaving the app during a call with a picture: into picture in picture, below Android 12 (CallPip.kt). */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!bubble) CallPip.leaving(this)
    }

    /** In and out of picture in picture: Dart draws the call's picture alone while in (lib/ui/call_pip.dart). */
    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (!bubble) CallPip.changed(isInPictureInPictureMode)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Each bubble is a screen of its own (documentLaunchMode="always"), opened on its one conversation.
        if (bubble) return
        setIntent(intent)
        ringIntent(intent)
        sharedFiles(intent)?.let { uris ->
            if (events != null) events?.success(mapOf("type" to "sharedFiles", "uris" to uris)) else pendingShared = uris
            return
        }
        val req = openRequest(intent) ?: return
        if (events != null) events?.success(mapOf("type" to "open") + req) else pendingOpen = req
    }

    /** What the intent asks to open: a conversation (a notification), or a new message to someone (sms: links, shares). */
    private fun openRequest(intent: Intent?, fresh: Boolean = false): Map<String, Any?>? {
        intent ?: return null
        val thread = intent.getLongExtra(Notifier.EXTRA_THREAD, -1)
        if (thread >= 0) return mapOf("thread" to thread)
        // A Signal or Telegram message's notification (Notifier.inbox): its chat.
        intent.getStringExtra(Notifier.EXTRA_INBOX)?.let { return mapOf("inbox" to it) }
        // The "Paired with …" notification: Settings › Computers.
        if (intent.getBooleanExtra("desk", false)) return mapOf("desk" to true)
        // A computer's pairing link, opened by the phone's camera or anything else: the pairing page, which asks
        // before it does anything with a code that came from outside the app.
        intent.data?.let { link -> if (link.scheme.equals("ghostmsg", ignoreCase = true) && link.host == "pair") return mapOf("pair" to link.toString()) }
        // A circle's invite link (https://gogho.st/join/#c.…) opened here: the app raises the circle's invite, with Join
        // and Not now (lib/ui/circles/circle_invite_card.dart). Matt, 2026-11-17: "Finish the missing pieces that went
        // unfinished". A shared text holding one is still a text to send, as any shared text is.
        // The invite page's Open in Uplink (site/join): ghostmsg://join/#c.…, the https link's words.
        intent.data?.let { link ->
            if (link.scheme.equals("ghostmsg", ignoreCase = true) && link.host == "join") {
                setIntent(Intent(intent).setData(null))
                if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
                val fragment = link.encodedFragment ?: ""
                return if (fragment.startsWith("c.")) mapOf("circle" to "https://gogho.st/join/#$fragment") else null
            }
        }
        intent.data?.let { link ->
            // Someone's add-me link (https://gogho.st/add/maya, or the page's ghostmsg://add/maya; GMFB-34): the app
            // asks whether to send them a friend request (lib/friends/add_link.dart).
            val add = (link.scheme == "https" && link.host == "gogho.st" && (link.path ?: "").startsWith("/add/")) ||
                (link.scheme.equals("ghostmsg", ignoreCase = true) && link.host == "add")
            if (add) {
                setIntent(Intent(intent).setData(null))
                if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
                return mapOf("add" to link.toString())
            }
        }
        intent.data?.let { link ->
            // A relay's link (ghostmsg://relay?a=…, what the QR code of a relay hosted from someone's app holds): the app
            // asks whether to use it, and what it means, before anything changes (lib/ui/relay_host_section.dart).
            if (link.scheme.equals("ghostmsg", ignoreCase = true) && link.host == "relay") {
                setIntent(Intent(intent).setData(null))
                if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
                return mapOf("relay" to link.toString())
            }
        }
        intent.data?.let { link ->
            // A circle's invite word (https://gogho.st/c/bookclub): the app asks the relay for the circle it is
            // (lib/circles/invite_word.dart), as it does for one typed into Join a circle.
            if (link.scheme == "https" && link.host == "gogho.st" && (link.path ?: "").startsWith("/c/")) {
                setIntent(Intent(intent).setData(null))
                if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
                return mapOf("circle" to link.toString())
            }
            if (link.scheme == "https" && link.host == "gogho.st" && (link.path ?: "").startsWith("/join")) {
                // Handled once. The link is taken off the intent as it is read, since Android hands the same intent
                // back when the screen is made again (after its process was stopped) and when the app is reopened
                // from Recents, which raised the circle's invite, or threw up the browser, each time. One reopened
                // from Recents is not the link being opened again.
                setIntent(Intent(intent).setData(null))
                if ((intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return null
                if ((link.fragment ?: "").startsWith("c.")) return mapOf("circle" to link.toString())
                // Any other /join link is a space's. With the filter verified as an App Link (assetlinks.json; Matt,
                // 2026-11-17: invites texted to contacts open the app straight away) Android no longer offers the
                // browser for it, and the app has no page for a space's link opened from outside yet: it goes on to a
                // browser, where the space opens as it always did (site/join). The App Link fragment is not matched by
                // a filter, so this is the one place the two are told apart. Where the app was opened only for the
                // link, it steps back out of the way rather than staying behind the browser.
                openInBrowser(link)
                if (fresh && isTaskRoot) moveTaskToBack(true)
                return null
            }
        }
        val data = intent.data
        if (data != null && data.scheme in setOf("sms", "smsto", "mms", "mmsto")) {
            val to = data.schemeSpecificPart.substringBefore('?').split(',', ';').map { Uri.decode(it).trim() }.filter { it.isNotEmpty() }
            val body = intent.getStringExtra("sms_body") ?: intent.getStringExtra(Intent.EXTRA_TEXT) ?: data.getQueryParameterSafe("body")
            return mapOf("addresses" to to, "body" to body)
        }
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain" && sharedFiles(intent) == null) {
            return mapOf("addresses" to emptyList<String>(), "body" to intent.getStringExtra(Intent.EXTRA_TEXT))
        }
        return null
    }

    /** [link] in a browser, never back in this app: the selector lets only a browser answer it. */
    private fun openInBrowser(link: Uri) {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, link).apply {
                selector = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_BROWSER)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        } catch (e: Exception) {
            DevLog.add(this, "links", "no browser for a space's link: ${e.message}")
        }
    }

    /** A query parameter of an address of any scheme: Android's own reading throws on one that is not hierarchical. */
    private fun Uri.getQueryParameterSafe(name: String): String? = try {
        Uri.parse("x://h?" + (toString().substringAfter('?', ""))).getQueryParameter(name)
    } catch (_: Exception) { null }

    /**
     * The colours Android takes from the wallpaper (Material You, Android 12 on): what the phone's own apps wear, so a
     * chat background made of them follows the phone as theirs do. Null before Android 12.
     */
    private fun systemPalette(): Map<String, Int>? {
        if (android.os.Build.VERSION.SDK_INT < 31) return null
        return try {
            mapOf(
                "accent1_50" to android.R.color.system_accent1_50, "accent1_100" to android.R.color.system_accent1_100,
                "accent1_200" to android.R.color.system_accent1_200, "accent1_600" to android.R.color.system_accent1_600,
                "accent1_800" to android.R.color.system_accent1_800, "accent1_900" to android.R.color.system_accent1_900,
                "accent2_100" to android.R.color.system_accent2_100, "accent2_800" to android.R.color.system_accent2_800,
                "accent3_100" to android.R.color.system_accent3_100, "accent3_800" to android.R.color.system_accent3_800,
                "neutral1_50" to android.R.color.system_neutral1_50, "neutral1_900" to android.R.color.system_neutral1_900,
            ).mapValues { getColor(it.value) }
        } catch (_: Exception) { null }
    }

    /** The chat background files kept under [name] (its letters and digits; "all" for none). */
    private fun backgroundFiles(name: String): List<java.io.File> {
        val safe = name.filter { it.isLetterOrDigit() }.ifEmpty { "all" }
        return java.io.File(filesDir, "backgrounds").listFiles { f -> f.name.startsWith("$safe-") }?.toList() ?: emptyList()
    }

    /**
     * A chat background from the person's pictures: read once through the picker's grant, turned the way its EXIF
     * says, scaled to at most 2400 on its longer side and kept in the app's own files, since the grant ends with the
     * app. Each copy has a new name, so the screen never draws the one before it from its cache.
     */
    private fun importBackground(uri: String, name: String): String? {
        val source = Uri.parse(uri)
        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // Asked for its size alone, decodeStream answers null by design: the size is in [bounds].
        (contentResolver.openInputStream(source) ?: return null).use { android.graphics.BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= 2400) sample *= 2
        var bitmap = contentResolver.openInputStream(source)?.use {
            android.graphics.BitmapFactory.decodeStream(it, null, android.graphics.BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val turn = try {
            contentResolver.openInputStream(source)?.use {
                when (android.media.ExifInterface(it).getAttributeInt(android.media.ExifInterface.TAG_ORIENTATION, 1)) {
                    android.media.ExifInterface.ORIENTATION_ROTATE_90 -> 90f
                    android.media.ExifInterface.ORIENTATION_ROTATE_180 -> 180f
                    android.media.ExifInterface.ORIENTATION_ROTATE_270 -> 270f
                    else -> 0f
                }
            } ?: 0f
        } catch (_: Exception) { 0f }
        val longer = maxOf(bitmap.width, bitmap.height)
        if (turn != 0f || longer > 2400) {
            val m = android.graphics.Matrix()
            if (longer > 2400) m.postScale(2400f / longer, 2400f / longer)
            if (turn != 0f) m.postRotate(turn)
            bitmap = android.graphics.Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, true)
        }
        val safe = name.filter { it.isLetterOrDigit() }.ifEmpty { "all" }
        val dir = java.io.File(filesDir, "backgrounds").apply { mkdirs() }
        val file = java.io.File(dir, "$safe-${System.currentTimeMillis()}.jpg")
        file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 88, it) }
        backgroundFiles(name).forEach { if (it != file) it.delete() }
        return file.absolutePath
    }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** Where the app stands with Android, for the screens: whether it is the default SMS app, and what it may do. */
    private fun status(): Map<String, Any?> {
        val role = getSystemService(RoleManager::class.java)
        return mapOf(
            "isDefault" to (role.isRoleAvailable(RoleManager.ROLE_SMS) && role.isRoleHeld(RoleManager.ROLE_SMS)),
            "contacts" to granted(Manifest.permission.READ_CONTACTS),
            "notifications" to (android.os.Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)),
            "phone" to granted(Manifest.permission.READ_PHONE_NUMBERS),
            // Beside Google Messages (GmBridge): whether it is there, whether its notifications may be read, and
            // whether the SMS database may be read and texts sent (granted by asking, when Uplink is not the default).
            "gmInstalled" to GmBridge.isInstalled(this),
            "bridge" to GmBridge.hasAccess(this),
            "gmDefault" to GmBridge.isGmDefault(this),
            "sms" to (granted(Manifest.permission.READ_SMS) && granted(Manifest.permission.SEND_SMS)),
            // Android's own bubble setting for the app (Bubbles.systemState): all, selected, none, or null before 11.
            "bubbles" to Bubbles.systemState(this),
            // Whether Android lets the app run while the phone sleeps (Reach.kt): a call can ring then.
            "battery" to Reach.exempt(this),
        )
    }

    /** Asks Android to make this the default SMS app; [result] is answered when its screen closes (ROLE_REQUEST). */
    private fun requestDefault(result: MethodChannel.Result) {
        val role = getSystemService(RoleManager::class.java)
        if (role.isRoleHeld(RoleManager.ROLE_SMS)) { result.success(true); return }
        roleResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(role.createRequestRoleIntent(RoleManager.ROLE_SMS), ROLE_REQUEST)
    }

    /** Reading the SMS database and sending texts, which a default SMS app has without asking. */
    private fun requestSms(result: MethodChannel.Result) {
        val missing = listOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.RECEIVE_SMS).filter { !granted(it) }
        if (missing.isEmpty()) { result.success(status()); return }
        permsResult = result
        requestPermissions(missing.toTypedArray(), PERMS_REQUEST)
    }

    /** Contacts, this phone's number and, from Android 13, notifications: asked together, answered with [status]. */
    private fun requestPermissions(result: MethodChannel.Result) {
        val want = mutableListOf(Manifest.permission.READ_CONTACTS, Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_PHONE_NUMBERS)
        if (android.os.Build.VERSION.SDK_INT >= 33) want += Manifest.permission.POST_NOTIFICATIONS
        val missing = want.filter { !granted(it) }
        if (missing.isEmpty()) { result.success(status()); return }
        permsResult = result
        requestPermissions(missing.toTypedArray(), PERMS_REQUEST)
    }

    /** A picked file, by its content address, copied into this app's cache under its own name: its path. */
    private fun cacheCopy(uri: Uri): String {
        val name = contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }?.replace('/', '_') ?: "file-${System.currentTimeMillis()}"
        val out = File(File(cacheDir, "outgoing").apply { mkdirs() }, name)
        contentResolver.openInputStream(uri)!!.use { input -> out.outputStream().use { input.copyTo(it) } }
        return out.path
    }

    /** App packages, which [openFile] never hands to ACTION_VIEW. */
    private val installers = setOf("apk", "xapk", "apks", "apkm")

    /** Opens [file] in the app that reads its kind, through the provider MMS files go by. */
    private fun openFile(file: File, name: String?) {
        val shown = File(MmsFileProvider.dir(this), cleanFileName(name ?: file.name))
        val ext = shown.extension.lowercase()
        // An app package from a Files space is never opened: ACTION_VIEW would take it straight to the installer, with
        // this app's own grant to install packages, past the step that asks. It can be saved and opened from there.
        if (ext in installers) {
            DevLog.add(this, "files", "open: refused an installer (.$ext)")
            return
        }
        if (shown.path != file.path) file.copyTo(shown, overwrite = true)
        val type = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val i = Intent(Intent.ACTION_VIEW).setDataAndType(MmsFileProvider.uriFor(this, shown), type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        runOnUiThread { try { startActivity(Intent.createChooser(i, "Open with").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (e: Exception) { DevLog.add(this, "files", "open: ${e.message}") } }
    }

    /** The content addresses an ACTION_SEND or ACTION_SEND_MULTIPLE carries as files; null for a share of words alone. */
    private fun sharedFiles(intent: Intent?): List<String>? {
        intent ?: return null
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) return null
        val uris = ArrayList<String>()
        @Suppress("DEPRECATION")
        if (intent.action == Intent.ACTION_SEND) (intent.getParcelableExtra<android.os.Parcelable>(Intent.EXTRA_STREAM) as? Uri)?.let { uris += it.toString() }
        else intent.getParcelableArrayListExtra<android.os.Parcelable>(Intent.EXTRA_STREAM)?.forEach { (it as? Uri)?.let { u -> uris += u.toString() } }
        if (uris.isEmpty()) intent.clipData?.let { clip -> for (k in 0 until clip.itemCount) clip.getItemAt(k).uri?.let { uris += it.toString() } }
        // Only another app's content: a file:// address, or one of this app's own providers, would be read with this
        // app's rights, so another app could share this app's private files (its keys, its choices) into a Files space.
        return uris.filter { foreign(Uri.parse(it)) }.ifEmpty { null }
    }

    /** A content:// address served by another app, not one of this app's own providers. */
    private fun foreign(uri: Uri): Boolean {
        if (uri.scheme != "content") return false
        val authority = uri.authority ?: return false
        return authority != packageName && !authority.startsWith("$packageName.")
    }

    /** A file name as it is kept and shown: no folders, no control or direction marks (a name that shows as
     *  "invoiceexe.pdf" but ends ".exe"), no name of only dots. */
    private fun cleanFileName(name: String): String {
        val plain = name.replace('/', '_').replace('\\', '_').filter { c -> !Character.isISOControl(c) && Character.getType(c) != Character.FORMAT.toInt() }.trim().trimEnd('.', ' ')
        return if (plain.isEmpty() || plain.all { it == '.' }) "file" else plain
    }

    /**
     * Each shared file's name, size and type, asked of the app that shares it (its provider's OpenableColumns), without
     * opening the file itself: nothing is copied until the person picks a Files space. A size the provider does not
     * give is -1. Only another app's content addresses are described, as [keepFile] only copies those.
     */
    private fun describeFiles(uris: List<String>): List<Map<String, Any?>> = uris.mapNotNull { s ->
        val uri = Uri.parse(s)
        if (!foreign(uri)) return@mapNotNull null
        var name: String? = null
        var size = -1L
        try {
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    val z = c.getColumnIndex(android.provider.OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    if (z >= 0 && !c.isNull(z)) size = c.getLong(z)
                }
            }
        } catch (e: Exception) {
            // A provider that refuses the question still lets the file be read; it is named from its address.
            DevLog.add(this, "files", "describe: ${e.message}")
        }
        // Named exactly as keepFile will name its copy, so the sheet shows the name the space will.
        val type = try { contentResolver.getType(uri) } catch (_: Exception) { null }
        val mime = type ?: "application/octet-stream"
        val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(type ?: "")
        val shown = cleanFileName(name ?: uri.lastPathSegment ?: "file")
        val named = if (shown.contains('.') || ext == null) shown else "$shown.$ext"
        mapOf("uri" to s, "name" to named, "size" to size, "mime" to mime)
    }

    /**
     * A picked or shared file copied into the app's own files, each in a folder of its own under its own name: its path,
     * name and size. Streamed, never read whole; the copy goes once the file is up (lib/files/files_store.dart).
     */
    private fun keepFile(uri: Uri): Map<String, Any?> {
        require(foreign(uri)) { "Only another app's files can be added" }
        var name: String? = null
        var size = -1L
        contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0)
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        val ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri) ?: "")
        val shown = cleanFileName(name ?: uri.lastPathSegment ?: "file")
        val named = if (shown.contains('.') || ext == null) shown else "$shown.$ext"
        val dir = File(filesDir, "space-files/outbox/${System.nanoTime()}").apply { mkdirs() }
        val out = File(dir, named)
        contentResolver.openInputStream(uri)!!.use { input -> out.outputStream().use { input.copyTo(it, 1 shl 16) } }
        return mapOf("path" to out.path, "name" to named, "size" to (if (size >= 0) size else out.length()))
    }

    /** Asks where to save [file] (Android's own "Save to" page), and copies it there: true where it was saved. */
    private fun saveFile(result: MethodChannel.Result, file: File, name: String, mime: String) {
        saveResult?.success(false)
        saveResult = result
        saveFrom = file
        val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(i, SAVE_REQUEST)
        } catch (e: Exception) {
            saveResult = null
            result.error("failed", e.message ?: "Nothing on this phone saves files", null)
        }
    }

    /** Shares [file] with another app, through the provider MMS files go by. */
    private fun shareFile(file: File, name: String?, mime: String?) {
        // Copies shared before, an hour old or more, go: nothing else ever deleted them.
        val hourAgo = System.currentTimeMillis() - 3_600_000L
        MmsFileProvider.dir(this).listFiles { f -> f.name.startsWith("share-") && f.lastModified() < hourAgo }?.forEach { it.delete() }
        val shown = File(MmsFileProvider.dir(this), "share-${System.nanoTime()}-${cleanFileName(name ?: file.name)}")
        file.copyTo(shown, overwrite = true)
        val type = mime ?: android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(shown.extension.lowercase()) ?: "application/octet-stream"
        val i = Intent(Intent.ACTION_SEND).apply {
            this.type = type
            putExtra(Intent.EXTRA_STREAM, MmsFileProvider.uriFor(this@MainActivity, shown))
            clipData = android.content.ClipData.newRawUri(name ?: file.name, MmsFileProvider.uriFor(this@MainActivity, shown))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runOnUiThread { try { startActivity(Intent.createChooser(i, name ?: "Share").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) } catch (e: Exception) { DevLog.add(this, "files", "share: ${e.message}") } }
    }

    /** Android's chooser for pictures, or with [any] for any files, several at once; answered in PICK_REQUEST. */
    private fun pickImages(result: MethodChannel.Result, any: Boolean = false) {
        pickResult = result
        val i = Intent(Intent.ACTION_GET_CONTENT).apply {
            type = if (any) "*/*" else "image/*"
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(Intent.createChooser(i, "Add a picture"), PICK_REQUEST)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            ROLE_REQUEST -> {
                roleResult?.success(getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_SMS)); roleResult = null
            }
            SCAN_REQUEST -> {
                scanResult?.success(mapOf("text" to data?.getStringExtra(ScanActivity.RESULT_TEXT), "denied" to (data?.getBooleanExtra("denied", false) ?: false)))
                scanResult = null
            }
            SAVE_REQUEST -> {
                val asked = saveResult ?: return
                val from = saveFrom
                saveResult = null
                saveFrom = null
                val to = data?.data
                if (resultCode != RESULT_OK || to == null || from == null) { asked.success(false); return }
                io.execute {
                    val ok = try {
                        contentResolver.openOutputStream(to)!!.use { out -> from.inputStream().use { it.copyTo(out, 1 shl 16) } }
                        true
                    } catch (e: Exception) { DevLog.add(this, "files", "save: ${e.message}"); false }
                    main.post { asked.success(ok) }
                }
            }
            PICK_REQUEST -> {
                val uris = ArrayList<String>()
                if (resultCode == RESULT_OK && data != null) {
                    val clip = data.clipData
                    if (clip != null) for (k in 0 until clip.itemCount) uris += clip.getItemAt(k).uri.toString()
                    else data.data?.let { uris += it.toString() }
                }
                pickResult?.success(uris); pickResult = null
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMS_REQUEST) { store.contactsChanged(); permsResult?.success(status()); permsResult = null }
        if (requestCode == MIC_REQUEST) {
            val asked = micResult ?: return
            micResult = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startVoice(asked) else asked.success(mapOf("ok" to false, "denied" to true))
        }
    }
}
