package com.infamousvague.ghostmessaging

import android.content.Context
import org.json.JSONArray
import java.util.Base64

/**
 * Friends by username (lib/friends/buddies.dart; Matt, 2026-11-14: "create a profile and username under "me" to
 * register a username and add friends on the platform"): the list Dart keeps, here so the key each pair seals the
 * routes' packets with is made where this phone's private key is ([E2e.pairKey]). Only friends who said yes, and
 * those this phone asked (so their yes, which comes sealed, can be opened), are reached.
 */
object Buddies {
    private fun prefs(context: Context) = context.getSharedPreferences("buddies", Context.MODE_PRIVATE)

    /** The list as Dart hands it over, a JSON array, kept whole; [kept] gives it back ("[]" for none). */
    fun keep(context: Context, json: String) {
        prefs(context).edit().putString("list", json).apply()
    }

    fun kept(context: Context): String = prefs(context).getString("list", "[]") ?: "[]"

    /** Those the routes can reach: their name, their `@username` where a number would be, and the sealing key. */
    fun peers(context: Context, already: Set<String>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val list = runCatching { JSONArray(kept(context)) }.getOrNull() ?: return out
        for (i in 0 until list.length()) {
            val o = list.optJSONObject(i) ?: continue
            val id = o.optString("i")
            val state = o.optString("s")
            if (id.isEmpty() || id in already || (state != "yes" && state != "asked" && state != "invited")) continue
            val pub = runCatching { Base64.getDecoder().decode(o.optString("k")) }.getOrNull()?.takeIf { it.size == 33 && Net.idOf(it) == id } ?: continue
            val pair = E2e.pairKey(context, pub) ?: continue
            // A friend who said yes is a conversation, addressed by username (lib/standalone/chats.dart): what they
            // write is kept in Dart, and Friends carries it as it does a phone-number friend's.
            val username = o.optString("u")
            val address = if (state == "yes" && username.isNotEmpty()) "@$username" else ""
            out.add(mapOf("id" to id, "address" to address, "key" to Net.netKey(pair)))
        }
        return out
    }
}
