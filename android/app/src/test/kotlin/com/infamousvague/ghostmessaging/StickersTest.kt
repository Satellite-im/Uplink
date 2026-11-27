package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A sticker's file name ([Stickers]): how it is made, how it is known again, and which stickers move. */
class StickersTest {
    @Test
    fun aStickerIsNamedForItsPackAndNumber() {
        assertEquals("ghost-sticker-love-03.png", Stickers.file("love-03"))
        assertTrue(Stickers.isSticker(Stickers.file("sweet-16")))
    }

    @Test
    fun aNameCarriesNothingAHeaderCouldChokeOn() {
        assertEquals("ghost-sticker-love03.png", Stickers.file("lo\"ve\r\n/0 3"))
        assertEquals("ghost-sticker-sticker.png", Stickers.file("../\u0000"))
        assertTrue(Stickers.file("x".repeat(500)).length < 64)
    }

    @Test
    fun aStickerThatMovesSaysSoBeforeItsPicture() {
        fun chunk(name: String, data: ByteArray) = byteArrayOf(0, 0, 0, data.size.toByte()) + name.toByteArray() + data + ByteArray(4)
        val head = byteArrayOf(0x89.toByte(), 'P'.code.toByte(), 'N'.code.toByte(), 'G'.code.toByte(), 13, 10, 26, 10)
        val still = head + chunk("IHDR", ByteArray(13)) + chunk("PLTE", ByteArray(30)) + chunk("IDAT", ByteArray(40)) + chunk("IEND", ByteArray(0))
        val moving = head + chunk("IHDR", ByteArray(13)) + chunk("acTL", ByteArray(8)) + chunk("PLTE", ByteArray(30)) + chunk("IDAT", ByteArray(40)) + chunk("IEND", ByteArray(0))
        assertFalse(Stickers.moves(still))
        assertTrue(Stickers.moves(moving))
        // Not a PNG at all, and too short to be anything.
        assertFalse(Stickers.moves("RIFF....WEBP".toByteArray() + ByteArray(80)))
        assertFalse(Stickers.moves(ByteArray(3)))
    }

    @Test
    fun anyOtherPictureIsNotASticker() {
        assertFalse(Stickers.isSticker(null))
        assertFalse(Stickers.isSticker("image0.jpg"))
        assertFalse(Stickers.isSticker("my-ghost-sticker.png"))
        // A part's name may arrive with a folder before it.
        assertTrue(Stickers.isSticker("parts/ghost-sticker-party-01.png"))
    }
}
