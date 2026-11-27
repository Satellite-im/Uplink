package com.infamousvague.ghostmessaging

import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A computer's QR code, drawn here as a camera would see it (brightness alone), read back and taken as an offer. */
class ScanTest {
    // What the Mac's QR code holds: the code as a link.
    private val code = JSONObject(File("../../test/desk_vectors.json").readText()).getString("offerLink")

    /** [text] as a QR code in the middle of a grey frame, each module [scale] pixels, turned a quarter if [turned]. */
    private fun frame(text: String, width: Int, height: Int, scale: Int, turned: Boolean = false): ByteArray {
        val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0)
        val side = matrix.width * scale
        val left = (width - side) / 2
        val top = (height - side) / 2
        val out = ByteArray(width * height) { 0xB0.toByte() }
        for (y in 0 until side) for (x in 0 until side) {
            val dark = if (turned) matrix.get(y / scale, matrix.width - 1 - x / scale) else matrix.get(x / scale, y / scale)
            out[(top + y) * width + left + x] = if (dark) 0x18 else 0xF0.toByte()
        }
        return out
    }

    @Test
    fun aPairingCodeIsReadFromAFrameAndIsAnOffer() {
        val text = Scan.read(frame(code, 1280, 720, 5), 1280, 720)
        assertEquals(code, text)
        assertTrue(DeskCrypto.isOffer(text!!))
        val offer = DeskCrypto.parseOffer(text)
        assertNotNull(offer)
        assertEquals("Matt's MacBook", offer!!.name)
        // Held sideways, and small in the frame.
        assertEquals(code, Scan.read(frame(code, 1280, 720, 4, turned = true), 1280, 720))
        assertEquals(code, Scan.read(frame(code, 1280, 720, 3), 1280, 720))
    }

    @Test
    fun aFrameWithNoCodeReadsAsNothingAndAnotherCodeIsNoOffer() {
        assertNull(Scan.read(ByteArray(1280 * 720) { 0x80.toByte() }, 1280, 720))
        val other = Scan.read(frame("https://example.com/menu", 640, 480, 6), 640, 480)
        assertEquals("https://example.com/menu", other)
        assertNull(DeskCrypto.parseOffer(other!!))
    }
}
