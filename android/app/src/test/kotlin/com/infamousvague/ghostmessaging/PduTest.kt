package com.infamousvague.ghostmessaging

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.ByteArrayOutputStream

/** The MMS encoder and decoder against each other and against bytes laid out by hand from the spec. */
class PduTest {
    @Test
    fun sendReqReadsBack() {
        val jpeg = ByteArray(5000) { (it * 7).toByte() }
        val parts = listOf(
            Pdu.Part("image/jpeg", jpeg, name = "image0.jpg", contentLocation = "image0.jpg", contentId = "image0"),
            Pdu.Part("text/plain", "Hello 👻 group".toByteArray(), contentLocation = "text0.txt", contentId = "text0"),
        )
        val bytes = Pdu.sendReq(listOf("+1 (555) 123-4567", "5559876543"), parts)
        val m = Pdu.parse(bytes)
        assertEquals(Pdu.SEND_REQ, m.type)
        assertEquals(listOf("+15551234567", "5559876543"), m.to)
        assertEquals("application/vnd.wap.multipart.related", m.contentType)
        assertEquals(3, m.parts.size)
        assertEquals("application/smil", m.parts[0].contentType)
        assertEquals("image/jpeg", m.parts[1].contentType)
        assertEquals("image0.jpg", m.parts[1].name)
        assertEquals("image0.jpg", m.parts[1].contentLocation)
        assertEquals("image0", m.parts[1].contentId)
        assertArrayEquals(jpeg, m.parts[1].data)
        assertEquals("text/plain", m.parts[2].contentType)
        assertEquals("Hello 👻 group", m.parts[2].text())
    }

    /** A voice message (Voice.kt): one audio part, which the message's layout names as sound, read back whole. */
    @Test
    fun aVoiceMessageReadsBack() {
        val sound = ByteArray(40_000) { (it * 13).toByte() }
        val name = Voice.fileName(1_794_600_000_000L)
        val bytes = Pdu.sendReq(listOf("+15551234567"), listOf(Pdu.Part("audio/mp4", sound, name = name, contentLocation = name, contentId = "voice")))
        val m = Pdu.parse(bytes)
        assertEquals(2, m.parts.size)
        assertEquals("application/smil", m.parts[0].contentType)
        val layout = String(m.parts[0].data)
        assertEquals("the layout plays it as sound: $layout", true, layout.contains("<audio src=\"$name\""))
        assertEquals("audio/mp4", m.parts[1].contentType)
        assertEquals(name, m.parts[1].name)
        assertArrayEquals(sound, m.parts[1].data)
    }

    /** A video in a message: the picture made of it for the conversation is never larger than it need be. */
    @Test
    fun aVideosPictureIsFittedToTheBubble() {
        assertEquals(720 to 405, Video.fitted(1920, 1080))
        assertEquals(405 to 720, Video.fitted(1080, 1920))
        assertEquals(320 to 240, Video.fitted(320, 240)) // never enlarged
        assertEquals(720 to 720, Video.fitted(2000, 2000))
        // Its own size is as it plays: one filmed upright is kept on its side.
        assertEquals(240 to 320, Video.turned(320, 240, 90))
        assertEquals(240 to 320, Video.turned(320, 240, 270))
        assertEquals(320 to 240, Video.turned(320, 240, 0))
        assertEquals(320 to 240, Video.turned(320, 240, 180))
        assertEquals(720 to 1, Video.fitted(4000, 2)) // never nothing
        assertEquals(0 to 0, Video.fitted(0, 0))
        // A video goes as its own part, named as one in the message's layout, and reads back whole.
        val clip = ByteArray(30_000) { (it * 31).toByte() }
        val m = Pdu.parse(Pdu.sendReq(listOf("+15551234567"), listOf(Pdu.Part("video/mp4", clip, name = "clip.mp4", contentLocation = "clip.mp4", contentId = "clip"))))
        assertEquals(true, String(m.parts[0].data).contains("<video src=\"clip.mp4\""))
        assertEquals("video/mp4", m.parts[1].contentType)
        assertArrayEquals(clip, m.parts[1].data)
    }

    /** How long a voice message may run is what the carrier's limit on a message leaves room for. */
    @Test
    fun aVoiceMessagesLengthIsWhatFitsInAMessage() {
        // 300 KB, the least any carrier takes: about a minute and a half.
        assertEquals(true, Voice.maxSeconds(292L * 1024) in 85..95)
        // 1 MB: about five minutes.
        assertEquals(true, Voice.maxSeconds(1016L * 1024) in 300..330)
        // Never nothing, and never more than ten minutes whatever the carrier says.
        assertEquals(5, Voice.maxSeconds(0))
        assertEquals(600, Voice.maxSeconds(50L * 1024 * 1024))
        // What it is recorded at fits: the seconds allowed, at the bit rate, are under the budget.
        val budget = 292L * 1024
        assertEquals(true, Voice.maxSeconds(budget) * (Voice.BIT_RATE / 8L) < budget)
        assertEquals(true, Regex("voice-\\d{8}-\\d{6}\\.m4a").matches(Voice.fileName()))
    }

    @Test
    fun notifyRespInd() {
        val m = Pdu.parse(Pdu.notifyRespInd("abc123"))
        assertEquals(Pdu.NOTIFYRESP_IND, m.type)
        assertEquals("abc123", m.transactionId)
        assertEquals(0x81, m.status)
    }

    private fun text(o: ByteArrayOutputStream, s: String) { o.write(s.toByteArray()); o.write(0) }

    @Test
    fun notificationInd() {
        val o = ByteArrayOutputStream()
        o.write(0x8C); o.write(0x82)
        o.write(0x98); text(o, "TID1")
        o.write(0x8D); o.write(0x92)
        // From: length, address-present, text
        val from = "+15551112222/TYPE=PLMN"
        o.write(0x89); o.write(from.length + 2); o.write(0x80); text(o, from)
        o.write(0x8A); o.write(0x80) // message class personal
        o.write(0x8E); o.write(2); o.write(0x30); o.write(0x39) // message size, long-integer 12345
        o.write(0x88); o.write(5); o.write(0x81); o.write(3); o.write(0x02); o.write(0xA3); o.write(0x00) // expiry, relative
        o.write(0x83); text(o, "http://mmsc.example/abc?x=1")
        val m = Pdu.parse(o.toByteArray())
        assertEquals(Pdu.NOTIFICATION_IND, m.type)
        assertEquals("TID1", m.transactionId)
        assertEquals("+15551112222", m.from)
        assertEquals("http://mmsc.example/abc?x=1", m.contentLocation)
    }

    @Test
    fun retrieveConfFromACarrier() {
        // Laid out as carriers send them: encoded To with a charset, a date, multipart/related with type and start
        // parameters, a SMIL part, a text part with charset given as a long integer, and a picture with a name.
        val o = ByteArrayOutputStream()
        o.write(0x8C); o.write(0x84)
        o.write(0x98); text(o, "TID9")
        o.write(0x8D); o.write(0x92)
        o.write(0x8B); text(o, "MSGID")
        o.write(0x85); o.write(4); o.write(0x65); o.write(0x00); o.write(0x00); o.write(0x00) // date
        val from = "+15550001111/TYPE=PLMN"
        o.write(0x89); o.write(from.length + 2); o.write(0x80); text(o, from)
        val to1 = "+15550002222/TYPE=PLMN"
        o.write(0x97); o.write(to1.length + 2); o.write(0xEA); text(o, to1) // encoded string with utf-8
        o.write(0x97); text(o, "+15550003333/TYPE=PLMN")
        o.write(0x96); o.write(7); o.write(0xEA); text(o, "Hey!!")
        // Content-Type: related; type=application/smil; start=<smil>
        val ct = ByteArrayOutputStream()
        ct.write(0xB3); ct.write(0x89); text(ct, "application/smil"); ct.write(0x8A); text(ct, "<smil>")
        o.write(0x84); o.write(ct.size()); o.write(ct.toByteArray())

        fun uintvar(out: ByteArrayOutputStream, v: Int) {
            if (v >= 128) out.write(0x80 or (v shr 7)); out.write(v and 0x7F)
        }
        fun part(ctBytes: ByteArray, headers: ByteArray, data: ByteArray): ByteArray {
            val p = ByteArrayOutputStream()
            uintvar(p, ctBytes.size + headers.size); uintvar(p, data.size)
            p.write(ctBytes); p.write(headers); p.write(data)
            return p.toByteArray()
        }
        val smilData = "<smil/>".toByteArray()
        val smilCt = byteArrayOf(0x11) + "application/smil".toByteArray() + byteArrayOf(0)
        val txtData = "hi everyone".toByteArray(Charsets.UTF_8)
        val txtCt = byteArrayOf(0x04, 0x83.toByte(), 0x81.toByte(), 0x01, 0x6A) // text/plain; charset=106 as long int
        val txtHeaders = byteArrayOf(0x8E.toByte()) + "text_0.txt".toByteArray() + byteArrayOf(0)
        val img = ByteArray(300) { it.toByte() }
        val imgCt = byteArrayOf(0x0A, 0x9E.toByte(), 0x85.toByte()) + "pic.jpg".toByteArray() + byteArrayOf(0)
        val imgHeaders = byteArrayOf(0xC0.toByte(), 0x22) + "<pic>".toByteArray() + byteArrayOf(0)
        o.write(3)
        o.write(part(smilCt, byteArrayOf(), smilData))
        o.write(part(txtCt, txtHeaders, txtData))
        o.write(part(imgCt, imgHeaders, img))

        val m = Pdu.parse(o.toByteArray())
        assertEquals(Pdu.RETRIEVE_CONF, m.type)
        assertEquals("+15550001111", m.from)
        assertEquals(listOf("+15550002222", "+15550003333"), m.to)
        assertEquals("Hey!!", m.subject)
        assertEquals("MSGID", m.messageId)
        assertEquals(0x65000000L, m.date)
        assertEquals(3, m.parts.size)
        assertEquals("application/smil", m.parts[0].contentType)
        assertEquals("text/plain", m.parts[1].contentType)
        assertEquals("hi everyone", m.parts[1].text())
        assertEquals("text_0.txt", m.parts[1].contentLocation)
        assertEquals("image/jpeg", m.parts[2].contentType)
        assertEquals("pic.jpg", m.parts[2].name)
        assertEquals("pic", m.parts[2].contentId)
        assertArrayEquals(img, m.parts[2].data)
    }

    @Test
    fun reportsAskedForAndReadBack() {
        val parts = listOf(Pdu.Part("text/plain", "hi".toByteArray(), contentLocation = "text0.txt", contentId = "text0"))
        // X-Mms-Delivery-Report (0x86) and X-Mms-Read-Report (0x90): 0x80 yes, 0x81 no.
        fun flag(bytes: ByteArray, header: Int): Int { val at = bytes.indexOfFirst { (it.toInt() and 0xFF) == header }; return bytes[at + 1].toInt() and 0xFF }
        val asked = Pdu.sendReq(listOf("+15551234567"), parts, deliveryReport = true, readReport = true)
        val plain = Pdu.sendReq(listOf("+15551234567"), parts)
        assertEquals(Pdu.SEND_REQ, Pdu.parse(asked).type)
        assertEquals(1, Pdu.parse(asked).parts.count { it.isText })
        assert(asked.size == plain.size)
        assert(!asked.contentEquals(plain))

        // m-delivery-ind: type, version, message id, to, date, status retrieved.
        val d = ByteArrayOutputStream()
        d.write(0x8C); d.write(0x86); d.write(0x8D); d.write(0x92)
        d.write(0x8B); text(d, "MSG-42")
        d.write(0x97); text(d, "+15551234567/TYPE=PLMN")
        d.write(0x85); d.write(4); d.write(0x65); d.write(0); d.write(0); d.write(0)
        d.write(0x95); d.write(0x81)
        val delivered = Pdu.parse(d.toByteArray())
        assertEquals(Pdu.DELIVERY_IND, delivered.type)
        assertEquals("MSG-42", delivered.messageId)
        assertEquals(0x81, delivered.status)

        // m-read-orig-ind: type, version, message id, to, from, date, read-status read.
        val r = ByteArrayOutputStream()
        r.write(0x8C); r.write(0x88); r.write(0x8D); r.write(0x92)
        r.write(0x8B); text(r, "MSG-42")
        r.write(0x97); text(r, "+15550009999/TYPE=PLMN")
        val from = "+15551234567/TYPE=PLMN"
        r.write(0x89); r.write(from.length + 2); r.write(0x80); text(r, from)
        r.write(0x85); r.write(4); r.write(0x65); r.write(0); r.write(0); r.write(0)
        r.write(0x9B); r.write(0x80)
        val read = Pdu.parse(r.toByteArray())
        assertEquals(Pdu.READ_ORIG_IND, read.type)
        assertEquals("MSG-42", read.messageId)
        assertEquals(0x80, read.readStatus)
    }

    @Test
    fun signInCodes() {
        assertEquals("482913", Notifier.otp("Your verification code is 482913. Don't share it with anyone."))
        assertEquals("123456", Notifier.otp("123-456 is your Example login code"))
        assertEquals("9041", Notifier.otp("Use PIN 9041 to sign in"))
        assertEquals(null, Notifier.otp("Call me at 5551234567 when you land"))
        assertEquals(null, Notifier.otp("See you at 7"))
        assertEquals(null, Notifier.otp("Your order 48291333 has shipped"))
    }
}
