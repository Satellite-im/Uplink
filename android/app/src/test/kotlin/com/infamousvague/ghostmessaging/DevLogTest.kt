package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** What the log strikes out ([DevLog.scrub]): phone numbers, and nothing else that is made of digits. */
class DevLogTest {
    @Test
    fun aPhoneNumberIsStruckOutHoweverItIsWritten() {
        assertEquals("send to [number] failed", DevLog.scrub("send to +15551230001 failed"))
        assertEquals("send to [number] failed", DevLog.scrub("send to (555) 123-0001 failed"))
        assertEquals("send to [number] failed", DevLog.scrub("send to +1 555-123-0001 failed"))
        assertEquals("send to [number] failed", DevLog.scrub("send to 555.123.0001 failed"))
        assertFalse(DevLog.scrub("content://mms/part/5551230001").contains("5551230001"))
    }

    @Test
    fun sizesCodesAndTimesAreKept() {
        val line = "picture 4000x3000 2143 KB image/heic -> 1200x1600 q85 302 KB, limit 1024 KB, result 4 HTTP 413"
        assertEquals(line, DevLog.scrub(line))
        assertEquals("short code 28849 said no", DevLog.scrub("short code 28849 said no"))
        val other = "11-13 19:12:40 mms   send to 3: 8160x6120 5210 KB image/heic -> 1600x1200 q85 412 KB, words 14"
        assertEquals(other, DevLog.scrub(other))
    }
}
