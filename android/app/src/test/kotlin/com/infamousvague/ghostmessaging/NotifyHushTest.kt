package com.infamousvague.ghostmessaging

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * No notification for a text the list hides (GMFB-18, Matt, Android 0.12.3: "If we dont have a specific kind of message
 * enabled like political messages we shouldn't get notified via sms for those messages"). The rules and the answers
 * are the Dart side's (lib/plugins/notify_hush.dart), written to test/notify_hush_vectors.json by test/notify_hush_test.dart.
 */
class NotifyHushTest {
    private val scenarios = JSONObject(File("../../test/notify_hush_vectors.json").readText()).getJSONArray("scenarios")

    @Test fun everyPatternTheAppWritesReadsInJava() {
        for (i in 0 until scenarios.length()) {
            val s = scenarios.getJSONObject(i)
            assertEquals(s.getString("name"), emptyList<String>(), NotifyHush.unreadable(s.getString("rules")))
        }
    }

    @Test fun theNotificationIsHeldBackWhereTheListHidesTheText() {
        assertTrue(scenarios.length() >= 3)
        for (i in 0 until scenarios.length()) {
            val s = scenarios.getJSONObject(i)
            val rules = s.getString("rules")
            val cases = s.getJSONArray("cases")
            for (j in 0 until cases.length()) {
                val c = cases.getJSONObject(j)
                val senders = c.getJSONArray("senders").let { a -> (0 until a.length()).map { a.getString(it) } }
                val got = NotifyHush.hushes(rules, c.getLong("thread"), senders, c.getBoolean("group"), c.getBoolean("stranger"), c.getString("text"))
                assertEquals("${s.getString("name")}: ${c.getString("text")} (thread ${c.getLong("thread")})", c.getBoolean("hush"), got)
            }
        }
    }

    @Test fun nothingIsHeldBackBeforeTheAppHasWrittenItsRules() {
        assertFalse(NotifyHush.hushes(null, 7, listOf("+15559870001"), false, true, "Paid for by Friends of Pat Rivera"))
        assertFalse(NotifyHush.hushes("not json", 7, listOf("+15559870001"), false, true, "Paid for by Friends of Pat Rivera"))
    }

    @Test fun aNumberIsListedByItsLastTenDigits() {
        assertTrue(NotifyHush.listed(listOf("+1 (555) 987-0001"), listOf("5559870001")))
        assertFalse(NotifyHush.listed(listOf("+15559870002"), listOf("5559870001")))
        assertTrue(NotifyHush.listed(listOf("promo@example.com"), listOf("EXAMPLE")))
    }
}
