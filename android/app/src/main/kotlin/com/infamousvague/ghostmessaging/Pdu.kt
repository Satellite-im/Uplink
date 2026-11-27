package com.infamousvague.ghostmessaging

import java.io.ByteArrayOutputStream
import java.nio.charset.Charset

/**
 * The MMS wire format (OMA MMS Encapsulation 1.2 over WAP-230 WSP), as much of it as an SMS app needs: reading a
 * notification (m-notification-ind) and a downloaded message (m-retrieve-conf), and writing a message to send
 * (m-send-req) and the acknowledgement of a download (m-notifyresp-ind). Android does the radio and the MMSC's HTTP
 * (SmsManager.sendMultimediaMessage / downloadMultimediaMessage); it leaves the bytes to the app, and its own
 * encoder (com.google.android.mms) is not public.
 *
 * Every header value reads by one rule (WSP 8.4.1.2), which is how unknown headers are skipped safely:
 * 0..30 a length of that many bytes follows; 31 a uintvar length follows; 32..127 a NUL-terminated text; 128..255 a
 * one-byte short integer.
 */
object Pdu {
    // Message types (X-Mms-Message-Type).
    const val SEND_REQ = 0x80
    const val SEND_CONF = 0x81
    const val NOTIFICATION_IND = 0x82
    const val NOTIFYRESP_IND = 0x83
    const val RETRIEVE_CONF = 0x84
    /** The MMSC saying a message reached someone's phone (asked for with X-Mms-Delivery-Report). */
    const val DELIVERY_IND = 0x86
    /** Someone's phone saying they read a message (asked for with X-Mms-Read-Report; few phones answer). */
    const val READ_ORIG_IND = 0x88

    // Header codes, with the high bit set as they appear on the wire.
    private const val H_BCC = 0x81
    private const val H_CC = 0x82
    private const val H_CONTENT_LOCATION = 0x83
    private const val H_CONTENT_TYPE = 0x84
    private const val H_DATE = 0x85
    private const val H_DELIVERY_REPORT = 0x86
    private const val H_FROM = 0x89
    private const val H_MESSAGE_ID = 0x8B
    private const val H_MESSAGE_TYPE = 0x8C
    private const val H_MMS_VERSION = 0x8D
    private const val H_READ_REPORT = 0x90
    private const val H_STATUS = 0x95
    private const val H_RESPONSE_STATUS = 0x92
    private const val H_RESPONSE_TEXT = 0x93
    private const val H_READ_STATUS = 0x9B
    private const val H_SUBJECT = 0x96
    private const val H_TO = 0x97
    private const val H_TRANSACTION_ID = 0x98

    // Part header codes (WSP well-known header field names, high bit set).
    private const val P_CONTENT_LOCATION = 0x8E
    private const val P_CONTENT_ID = 0xC0

    /** WSP's well-known content types (WAP-230 Table 40), the ones an MMS carries. */
    private val CONTENT_TYPES = mapOf(
        0x00 to "*/*", 0x01 to "text/*", 0x02 to "text/html", 0x03 to "text/plain", 0x06 to "text/x-vcalendar",
        0x07 to "text/x-vcard", 0x08 to "text/vnd.wap.wml", 0x1C to "image/*", 0x1D to "image/gif",
        0x1E to "image/jpeg", 0x1F to "image/tiff", 0x20 to "image/png", 0x21 to "image/vnd.wap.wbmp",
        0x22 to "application/vnd.wap.multipart.*", 0x23 to "application/vnd.wap.multipart.mixed",
        0x24 to "application/vnd.wap.multipart.form-data", 0x25 to "application/vnd.wap.multipart.byteranges",
        0x26 to "application/vnd.wap.multipart.alternative", 0x33 to "application/vnd.wap.multipart.related",
        0x3E to "application/vnd.wap.mms-message", 0x0C to "multipart/mixed", 0x0D to "multipart/related",
        0x0E to "multipart/alternative", 0x10 to "application/octet-stream",
    )

    /** IANA MIBenum charsets an MMS uses. */
    fun charsetOf(mib: Int): Charset = when (mib) {
        3 -> Charsets.US_ASCII
        4 -> Charsets.ISO_8859_1
        1000, 1015 -> Charsets.UTF_16
        1013 -> Charsets.UTF_16BE
        1014 -> Charsets.UTF_16LE
        else -> Charsets.UTF_8
    }

    /** One part of a multipart body: a text, a picture, the SMIL layout. [charset] is an IANA MIBenum (106: UTF-8). */
    class Part(
        val contentType: String,
        val data: ByteArray,
        val charset: Int = 106,
        val name: String? = null,
        val contentLocation: String? = null,
        val contentId: String? = null,
    ) {
        val isText get() = contentType.startsWith("text/plain")
        val isSmil get() = contentType == "application/smil"
        fun text(): String = String(data, charsetOf(charset))
    }

    /** A message as read: [type] is one of the message types above, and only the headers that kind carries are set. */
    class Message(
        val type: Int,
        val transactionId: String? = null,
        val contentLocation: String? = null,
        val messageId: String? = null,
        val from: String? = null,
        val to: List<String> = emptyList(),
        val cc: List<String> = emptyList(),
        val subject: String? = null,
        /** Seconds since 1970, as the MMS provider keeps it. */
        val date: Long? = null,
        val contentType: String? = null,
        val status: Int? = null,
        val parts: List<Part> = emptyList(),
        /** X-Mms-Read-Status of a read report: 0x80 read, 0x81 deleted without being read. */
        val readStatus: Int? = null,
        /** X-Mms-Response-Status of a carrier's answer to a message sent: 0x80 accepted, anything else refused. */
        val responseStatus: Int? = null,
        /** The carrier's own words with it (X-Mms-Response-Text), where it gave any. */
        val responseText: String? = null,
    )

    // --- reading -----------------------------------------------------------------------------------------------------

    /** Reads WSP's value forms out of [b], moving [i] past each one read. */
    private class Reader(val b: ByteArray) {
        var i = 0
        fun more() = i < b.size
        fun u8(): Int = b[i++].toInt() and 0xFF
        fun peek(): Int = b[i].toInt() and 0xFF

        /** A variable-length integer: seven bits a byte, most significant first, the high bit on all but the last. */
        fun uintvar(): Int {
            var v = 0
            while (true) {
                val c = u8()
                v = (v shl 7) or (c and 0x7F)
                if (c and 0x80 == 0) return v
            }
        }

        /** A Value-length (WSP 8.4.2.2). */
        fun valueLength(): Int {
            val c = u8()
            return if (c < 31) c else if (c == 31) uintvar() else throw IllegalStateException("not a value length: $c")
        }

        /** A NUL-terminated text, read as UTF-8, without the marks WSP may put in front of it. */
        fun text(): String {
            if (more() && peek() == 0x7F) i++ // Quote: the text starts with a byte >= 128
            if (more() && peek() == 0x22) i++ // Quoted-string's leading quote
            val start = i
            while (i < b.size && b[i].toInt() != 0) i++
            val s = String(b, start, i - start, Charsets.UTF_8)
            if (i < b.size) i++
            return s
        }

        /** Long-integer or short-integer. */
        fun integer(): Long {
            val c = peek()
            if (c >= 0x80) return (u8() and 0x7F).toLong()
            val n = u8()
            var v = 0L
            repeat(n) { v = (v shl 8) or u8().toLong() }
            return v
        }

        /** Skips one value by the general rule. */
        fun skipValue() {
            val c = peek()
            when {
                c < 31 -> { i++; i += c }
                c == 31 -> { i++; val n = uintvar(); i += n }
                c < 128 -> text()
                else -> i++
            }
        }

        /** Encoded-string-value: a text, or a length, a charset and a text. */
        fun encodedString(): String {
            val c = peek()
            if (c >= 32) return text()
            val len = valueLength()
            val end = i + len
            val mib = integer().toInt()
            val start = i
            var stop = start
            while (stop < end && b[stop].toInt() != 0) stop++
            val s = String(b, start, stop - start, charsetOf(mib))
            i = end
            return s
        }

        /** A content type, short, text or general form, with its charset and name parameters. */
        fun contentType(): Triple<String, Int, String?> {
            val c = peek()
            if (c >= 0x80) return Triple(CONTENT_TYPES[u8() and 0x7F] ?: "application/octet-stream", 106, null)
            if (c >= 32) return Triple(text(), 106, null)
            val len = valueLength()
            val end = i + len
            val type = if (peek() >= 0x80) CONTENT_TYPES[u8() and 0x7F] ?: "application/octet-stream"
            else if (peek() >= 32) text() else { val n = valueLength(); val v = (CONTENT_TYPES[integerOfLength(n)] ?: "application/octet-stream"); v }
            var charset = 106
            var name: String? = null
            while (i < end) {
                val p = peek()
                if (p >= 0x80) {
                    i++
                    when (p and 0x7F) {
                        0x01 -> charset = if (peek() == 0x80 || peek() == 0x00) { i++; 106 } else integer().toInt() // charset ("Any" -> utf-8)
                        0x05, 0x17 -> name = text() // name, name (encoded)
                        0x06, 0x18 -> text() // filename
                        0x09, 0x0A, 0x19, 0x1A -> text() // type, start, start (encoded)
                        else -> skipValue()
                    }
                } else {
                    text(); skipValue() // a token-text parameter
                }
            }
            i = end
            return Triple(type, charset, name)
        }

        private fun integerOfLength(n: Int): Int {
            var v = 0
            repeat(n) { v = (v shl 8) or u8() }
            return v
        }
    }

    /** An address as people write it: "+15551234567/TYPE=PLMN" on the wire is "+15551234567". */
    private fun bareAddress(a: String): String = a.substringBefore("/TYPE=").trim()

    /**
     * Reads a whole MMS message: its headers, then, after the content type, the parts of a multipart body. Headers it
     * does not know are skipped by the general rule; bytes cut short may throw, which is the caller's to catch.
     */
    fun parse(bytes: ByteArray): Message {
        val r = Reader(bytes)
        var type = 0
        var tid: String? = null
        var location: String? = null
        var mid: String? = null
        var from: String? = null
        val to = mutableListOf<String>()
        val cc = mutableListOf<String>()
        var subject: String? = null
        var date: Long? = null
        var status: Int? = null
        var readStatus: Int? = null
        var responseStatus: Int? = null
        var responseText: String? = null
        var contentType: String? = null
        var parts: List<Part> = emptyList()

        while (r.more()) {
            val code = r.u8()
            if (code < 0x80) {
                // An application header: its name and its value, both texts.
                r.i--; r.text(); r.text(); continue
            }
            when (code) {
                H_MESSAGE_TYPE -> type = r.u8()
                H_TRANSACTION_ID -> tid = r.text()
                H_CONTENT_LOCATION -> location = r.text()
                H_MESSAGE_ID -> mid = r.text()
                H_SUBJECT -> subject = r.encodedString()
                H_TO -> to += bareAddress(r.encodedString())
                H_CC -> cc += bareAddress(r.encodedString())
                H_BCC -> r.encodedString()
                H_DATE -> date = r.integer()
                H_STATUS -> status = r.u8()
                H_READ_STATUS -> readStatus = r.u8()
                H_RESPONSE_STATUS -> responseStatus = r.u8()
                H_RESPONSE_TEXT -> responseText = r.encodedString()
                H_FROM -> {
                    val len = r.valueLength()
                    val end = r.i + len
                    val token = r.u8()
                    // 0x80: an address follows. 0x81: the MMSC is to fill in the sender, and nothing follows.
                    if (token == 0x80 && r.i < end) from = bareAddress(r.encodedString())
                    r.i = end
                }
                H_CONTENT_TYPE -> {
                    contentType = r.contentType().first
                    // The content type is the last header: the body follows.
                    if (contentType.contains("multipart")) parts = parseMultipart(r)
                    break
                }
                else -> r.skipValue()
            }
        }
        return Message(type, tid, location, mid, from, to, cc, subject, date, contentType, status, parts, readStatus, responseStatus, responseText)
    }

    private fun parseMultipart(r: Reader): List<Part> {
        val out = mutableListOf<Part>()
        if (!r.more()) return out
        // A count, then for each part: the length of its headers, the length of its data, the headers (content type
        // first), the data.
        val count = r.uintvar()
        repeat(count) {
            if (!r.more()) return out
            val headersLen = r.uintvar()
            val dataLen = r.uintvar()
            val headersEnd = r.i + headersLen
            val (ct, charset, name) = r.contentType()
            var location: String? = null
            var cid: String? = null
            while (r.i < headersEnd) {
                val code = r.peek()
                if (code >= 0x80) {
                    r.i++
                    when (code) {
                        P_CONTENT_LOCATION -> location = r.text()
                        P_CONTENT_ID -> cid = r.text().trim('<', '>')
                        else -> r.skipValue()
                    }
                } else {
                    r.text(); r.text()
                }
            }
            r.i = headersEnd
            val end = minOf(r.i + dataLen, r.b.size)
            val data = r.b.copyOfRange(r.i, end)
            r.i = end
            out += Part(ct, data, charset, name, location, cid)
        }
        return out
    }

    // --- writing -----------------------------------------------------------------------------------------------------

    /** Writes the same value forms the [Reader] reads. */
    private class Writer {
        val o = ByteArrayOutputStream()
        fun u8(v: Int) = o.write(v and 0xFF)
        fun bytes(b: ByteArray) = o.write(b)
        fun uintvar(value: Int) {
            var v = value
            val tmp = ArrayList<Int>()
            tmp += v and 0x7F
            v = v ushr 7
            while (v > 0) { tmp += (v and 0x7F) or 0x80; v = v ushr 7 }
            for (k in tmp.indices.reversed()) u8(tmp[k])
        }
        fun valueLength(n: Int) { if (n < 31) u8(n) else { u8(31); uintvar(n) } }
        fun text(s: String) {
            val b = s.toByteArray(Charsets.UTF_8)
            if (b.isNotEmpty() && (b[0].toInt() and 0xFF) >= 0x80) u8(0x7F)
            bytes(b); u8(0)
        }
        fun toByteArray(): ByteArray = o.toByteArray()
    }

    /** WSP's one-byte code for a content type, where it has one. */
    private fun wellKnown(type: String): Int? = CONTENT_TYPES.entries.firstOrNull { it.value == type }?.key

    /** A part's content type in the general form: the type, UTF-8 as the charset of a text, and the part's name. */
    private fun Writer.partContentType(part: Part) {
        val inner = Writer()
        val code = wellKnown(part.contentType)
        if (code != null) inner.u8(code or 0x80) else inner.text(part.contentType)
        if (part.contentType.startsWith("text/")) { inner.u8(0x81); inner.u8(0xEA) } // charset=utf-8 (106)
        if (part.name != null) { inner.u8(0x85); inner.text(part.name) }
        val b = inner.toByteArray()
        valueLength(b.size); bytes(b)
    }

    /**
     * An m-send-req to [recipients] with [parts], as application/vnd.wap.multipart.related with a SMIL slide in front
     * (what phones lay out; a bare mixed body is shown by most but not all).
     */
    fun sendReq(recipients: List<String>, parts: List<Part>, subject: String? = null, deliveryReport: Boolean = false, readReport: Boolean = false): ByteArray {
        val w = Writer()
        w.u8(H_MESSAGE_TYPE); w.u8(SEND_REQ)
        w.u8(H_TRANSACTION_ID); w.text("T" + java.lang.Long.toHexString(System.currentTimeMillis()))
        w.u8(H_MMS_VERSION); w.u8(0x92) // 1.2
        w.u8(H_FROM); w.u8(1); w.u8(0x81) // insert-address: the MMSC fills in this phone's number
        for (r in recipients) { w.u8(H_TO); w.text(addressForWire(r)) }
        if (!subject.isNullOrBlank()) { w.u8(H_SUBJECT); w.text(subject) }
        w.u8(H_DELIVERY_REPORT); w.u8(if (deliveryReport) 0x80 else 0x81)
        w.u8(H_READ_REPORT); w.u8(if (readReport) 0x80 else 0x81)

        val all = listOf(smil(parts)) + parts

        // Content-Type: multipart/related; type="application/smil"; start="<smil>"
        val ct = Writer()
        ct.u8(0x33 or 0x80)
        ct.u8(0x89); ct.text("application/smil")
        ct.u8(0x8A); ct.text("<smil>")
        val ctb = ct.toByteArray()
        w.u8(H_CONTENT_TYPE); w.valueLength(ctb.size); w.bytes(ctb)

        w.uintvar(all.size)
        for (p in all) {
            val h = Writer()
            h.partContentType(p)
            val cid = p.contentId ?: p.contentLocation ?: "part"
            h.u8(P_CONTENT_ID); h.u8(0x22); h.bytes("<$cid>".toByteArray()); h.u8(0)
            h.u8(P_CONTENT_LOCATION); h.text(p.contentLocation ?: cid)
            val hb = h.toByteArray()
            w.uintvar(hb.size)
            w.uintvar(p.data.size)
            w.bytes(hb)
            w.bytes(p.data)
        }
        return w.toByteArray()
    }

    /** One slide holding every picture and text, in order. */
    private fun smil(parts: List<Part>): Part {
        val body = StringBuilder()
        for (p in parts) {
            val src = p.contentLocation ?: continue
            when {
                p.contentType.startsWith("image/") -> body.append("<img src=\"$src\" region=\"Image\"/>")
                p.contentType.startsWith("video/") -> body.append("<video src=\"$src\" region=\"Image\"/>")
                p.contentType.startsWith("audio/") -> body.append("<audio src=\"$src\"/>")
                p.isText -> body.append("<text src=\"$src\" region=\"Text\"/>")
                else -> body.append("<ref src=\"$src\"/>")
            }
        }
        val smil = "<smil><head><layout><root-layout/><region id=\"Image\" fit=\"meet\" top=\"0\" left=\"0\" height=\"80%\" width=\"100%\"/>" +
            "<region id=\"Text\" top=\"80%\" left=\"0\" height=\"20%\" width=\"100%\"/></layout></head><body><par dur=\"5000ms\">$body</par></body></smil>"
        return Part("application/smil", smil.toByteArray(), contentId = "smil", contentLocation = "smil.xml")
    }

    /** The acknowledgement an MMSC waits for once a message has been fetched (status: retrieved). */
    fun notifyRespInd(transactionId: String): ByteArray {
        val w = Writer()
        w.u8(H_MESSAGE_TYPE); w.u8(NOTIFYRESP_IND)
        w.u8(H_TRANSACTION_ID); w.text(transactionId)
        w.u8(H_MMS_VERSION); w.u8(0x92)
        w.u8(H_STATUS); w.u8(0x81) // retrieved
        return w.toByteArray()
    }

    /** An address as the MMSC wants it: an email address as it is, a phone number as its digits marked "/TYPE=PLMN". */
    private fun addressForWire(a: String): String {
        if (a.contains('@')) return a
        val digits = a.filter { it.isDigit() || it == '+' }
        return "$digits/TYPE=PLMN"
    }
}
