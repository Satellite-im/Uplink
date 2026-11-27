package com.infamousvague.ghostmessaging

import io.flutter.embedding.engine.FlutterEngine

/**
 * A conversation's bubble (GMFB-8, from @kevin: "message bubbles that just sit on the side of the screen like google
 * messages and facebook messenger"): opened by Android from a conversation's notification (Bubbles.metadata), it shows
 * that one conversation and nothing around it. MainActivity cannot be the bubble's screen (singleTask, a task of its
 * own), so this is a screen of its own (resizeable, embedded, a document for each bubble: AndroidManifest.xml).
 *
 * It is MainActivity's calls with an engine of its own, started at Dart's `bubbleMain` (lib/main.dart, lib/bubble.dart)
 * with the conversation's thread, and let go of with the bubble: the app's engine, which keeps Signal and Telegram
 * connected, is never taken from the app's screen.
 */
class BubbleActivity : MainActivity() {
    override val bubble: Boolean get() = true

    // No engine handed over: Flutter makes one for this screen, at the entrypoint and with the arguments below.
    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? = null

    override fun shouldDestroyEngineWithHost(): Boolean = true

    override fun getDartEntrypointFunctionName(): String = "bubbleMain"

    override fun getDartEntrypointArgs(): List<String> = listOf(bubbleThread.toString())
}
