package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The bridge's copy of a message is the same as Android's (Store.androidCopyOf): Matt, 2026-11-16, of pictures sent
 * beside Google Messages: "they don't show up in the app properly after closing and re opening and they get stuck on
 * sending never sent".
 */
class BridgedCopyTest {
    private val min = 60_000L

    @Test
    fun aPictureThatWentAsMmsMinutesLaterIsTheSameMessage() {
        // Google Messages told of the picture at 0; RCS gave up and Android's MMS is dated 4 minutes on.
        val have = listOf(Store.AndroidCopy(out = true, words = "", time = 4 * min, media = true))
        assertEquals(0, Store.androidCopyOf(have, out = true, text = "", time = 0, media = true, used = HashSet()))
    }

    @Test
    fun wordsAloneStillNeedThreeMinutesAndPicturesFifteen() {
        val text = listOf(Store.AndroidCopy(true, "on my way", 4 * min, false))
        assertNull(Store.androidCopyOf(text, true, "on my way", 0, false, HashSet()))
        val picture = listOf(Store.AndroidCopy(true, "", 20 * min, true))
        assertNull(Store.androidCopyOf(picture, true, "", 0, true, HashSet()))
    }

    @Test
    fun eachOfAndroidsIsTheSameAsOneOnlyTheNearestFirst() {
        // Three pictures sent one after another, Android's three copies a little later each.
        val have = listOf(Store.AndroidCopy(true, "", 3 * min, true), Store.AndroidCopy(true, "", 1 * min, true), Store.AndroidCopy(true, "", 2 * min, true))
        val used = HashSet<Int>()
        val got = listOf(0L, 1 * min, 2 * min).map { Store.androidCopyOf(have, true, "", it, true, used) }
        assertEquals(3, got.toSet().size)
        assertNull(Store.androidCopyOf(have, true, "", 0, true, used))
    }

    @Test
    fun aCopyToldOfWithNoPictureIsTheSameAsAndroidsPictureMessage() {
        // Matt, 2026-11-19: "sometimes I don't see my outbound messages just the delivered tag". Google Messages told of
        // the picture and never gave its id, so the bridge's copy has nothing in it; Android's MMS went 4 minutes on.
        val have = listOf(Store.AndroidCopy(out = true, words = "", time = 4 * min, media = true))
        assertEquals(0, Store.androidCopyOf(have, out = true, text = "", time = 0, media = false, used = HashSet()))
        // Words are still words: a text is not a picture message minutes later.
        assertNull(Store.androidCopyOf(have, out = true, text = "ok", time = 0, media = false, used = HashSet()))
    }

    @Test
    fun theirsIsNeverYours() {
        val have = listOf(Store.AndroidCopy(out = false, words = "", time = 0, media = true))
        assertNull(Store.androidCopyOf(have, out = true, text = "", time = 0, media = true, used = HashSet()))
    }
}
