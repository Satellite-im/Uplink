package com.infamousvague.ghostmessaging

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The direct network's core (native/p2p, libghost_p2p.so; docs/OPEN_NETWORK.md, section 2), as far as Kotlin has
 * anything to do with it: Dart opens the library and drives it (lib/net/p2p/node_ffi.dart), but only Android's own
 * code can tell it which DNS servers the phone uses, and that takes the app's context. So when Dart starts its first
 * node, and not before, it asks here (the channel `ghost_messaging/p2p`, method `install`), and the library is
 * loaded through Java and handed the context through its one JNI function. A person who never switches the direct
 * route on runs nothing of the library at all: the app's start loads none of it.
 *
 * The library is named (libghost_p2p.so, its SONAME too), so the system loads it once: the copy Kotlin hands the
 * context to is the one Dart opened, which Dart checks (`ghost_p2p_ready`) before it makes a node.
 *
 * Without the context a link helper's name could not be looked up at all: the core asks the phone's own DNS servers
 * and no public one in their place. A build that does not carry the library (the direct route is simply not there)
 * answers false.
 */
object P2pCore {
    private const val TAG = "GhostP2p"
    @Volatile private var installed = false

    /** The channel Dart asks through, on an engine's messenger (the app's own and a bubble's). Loads nothing. */
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "ghost_messaging/p2p").setMethodCallHandler { call, result ->
            when (call.method) {
                "install" -> result.success(install(app))
                else -> result.notImplemented()
            }
        }
    }

    /** Loads the core where the build has it and gives it the app's context; true once it has it. Again, nothing. */
    @Synchronized
    fun install(context: Context): Boolean {
        if (installed) return true
        try {
            System.loadLibrary("ghost_p2p")
            installed = nativeInstall(context.applicationContext)
            Log.i(TAG, if (installed) "the direct network's core was loaded on first use and given the app's context" else "the direct network's core did not take the app's context")
            if (!installed) DevLog.add(context, "p2p", "the direct network's core did not take the app's context")
        } catch (_: UnsatisfiedLinkError) {
            // Not in this build.
            Log.i(TAG, "the direct network's core is not in this build")
        } catch (e: Throwable) {
            Log.w(TAG, "the direct network's core was not given the app's context: ${e.javaClass.simpleName}")
            DevLog.add(context, "p2p", "the direct network's core was not given the app's context: ${e.message ?: e.javaClass.simpleName}")
        }
        return installed
    }

    /** `Java_com_infamousvague_ghostmessaging_P2pCore_nativeInstall` in native/p2p/src/ffi.rs; true once the context is in place. */
    private external fun nativeInstall(context: Context): Boolean
}
