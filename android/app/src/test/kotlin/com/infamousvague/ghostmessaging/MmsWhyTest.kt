package com.infamousvague.ghostmessaging

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Why a picture message did not go or come, in words ([MmsWhy]): from Android's code and the carrier's answer. */
class MmsWhyTest {
    @Test
    fun mobileDataOffIsSaidAsThat() {
        assertTrue(MmsWhy.send(11).startsWith("mobile data is off"))
        assertTrue(MmsWhy.send(8).contains("mobile data"))
    }

    @Test
    fun theCarriersHttpAnswerIsKept() {
        assertTrue(MmsWhy.send(4, 403).contains("HTTP 403"))
        // No answer at all is not a refusal.
        assertTrue(MmsWhy.send(4, 0).contains("couldn't be reached"))
    }

    @Test
    fun aCodeNobodyKnowsIsStillSaid() {
        assertTrue(MmsWhy.send(99).contains("code 99"))
    }

    @Test
    fun aMessageTheCarrierNoLongerHasIsNotAFault() {
        assertTrue(MmsWhy.download(4, 404).contains("no longer has it"))
        assertEquals(MmsWhy.send(11), MmsWhy.download(11))
    }

    @Test
    fun aLostConnectionIsTriedAgainAndARefusalIsNot() {
        // No route to the carrier, the carrier asking for patience, its server in trouble or not answering.
        assertTrue(MmsWhy.worthAnotherTry(3, 0))
        assertTrue(MmsWhy.worthAnotherTry(6, 0))
        assertTrue(MmsWhy.worthAnotherTry(8, 0))
        assertTrue(MmsWhy.worthAnotherTry(4, 503))
        assertTrue(MmsWhy.worthAnotherTry(4, 0))
        // What the person has to mend, or the carrier said no to: asking again changes nothing.
        assertFalse(MmsWhy.worthAnotherTry(11, 0))
        assertFalse(MmsWhy.worthAnotherTry(12, 0))
        assertFalse(MmsWhy.worthAnotherTry(13, 0))
        assertFalse(MmsWhy.worthAnotherTry(4, 413))
        assertFalse(MmsWhy.worthAnotherTry(5, 0))
        assertTrue(MmsWhy.waitBefore(2) < MmsWhy.waitBefore(3))
    }

    @Test
    fun anAcceptedMessageIsNotRefused() {
        assertNull(MmsWhy.refused(null, null))
        assertNull(MmsWhy.refused(0x80, "OK"))
    }

    @Test
    fun aRefusalCarriesTheCarriersOwnWords() {
        assertEquals("the carrier doesn't know the number it is for: \"Unknown subscriber\"", MmsWhy.refused(0x84, " Unknown subscriber "))
        assertTrue(MmsWhy.refused(0xE2, null)!!.endsWith("(status 0xE2)"))
        assertTrue(MmsWhy.refused(0xC0, "")!!.startsWith("the carrier couldn't take it just now"))
    }

    /** Some carriers announce an address that stops at "=" and want the announcement's transaction id after it. */
    @Test
    fun theFetchAddressFollowsTheCarriersSettings() {
        val location = "http://mms.example-carrier.net/servlets/mms?message-id="
        assertEquals(location, MmsWhy.fetchAddress(location, "T19a2f", append = false))
        assertEquals(location + "T19a2f", MmsWhy.fetchAddress(location, "T19a2f", append = true))
        // Nothing to add: as it is.
        assertEquals(location, MmsWhy.fetchAddress(location, null, append = true))
        assertEquals(location, MmsWhy.fetchAddress(location, "  ", append = true))
        // An address that does not stop at an equals sign is whole, whatever the settings say.
        val whole = "http://mmsc.example.net/mms/wapenc?location=15551230001_abc123"
        assertEquals(whole, MmsWhy.fetchAddress(whole, "T19a2f", append = true))
        // The log names the server and nothing after it.
        assertEquals("mms.example-carrier.net", MmsWhy.hostOf(location + "T19a2f"))
        assertEquals("10.0.2.2", MmsWhy.hostOf("http://10.0.2.2:18765/mms/abc"))
        assertEquals("an address with no server in it", MmsWhy.hostOf("nonsense"))
    }

    /**
     * Matt's report, on Verizon: "not fetched … (result 4, HTTP 404)" on a picture just sent. Where the phone's
     * settings did not say the carrier wants the id, "not found" at such an address is asked for once more with it.
     */
    @Test
    fun notFoundWithoutTheIdIsAskedForOnceMoreWithIt() {
        val location = "http://mms.example-carrier.net/servlets/mms?message-id="
        assertTrue(MmsWhy.worthAskingWithId(404, location, "T19a2f", wentWithId = false))
        // Once is enough: with the id and still not found, the carrier no longer has it.
        assertFalse(MmsWhy.worthAskingWithId(404, location, "T19a2f", wentWithId = true))
        // Only "not found", only an address that takes an id, only where there is an id.
        assertFalse(MmsWhy.worthAskingWithId(500, location, "T19a2f", wentWithId = false))
        assertFalse(MmsWhy.worthAskingWithId(404, "http://mmsc.example.net/mms?location=abc", "T19a2f", wentWithId = false))
        assertFalse(MmsWhy.worthAskingWithId(404, location, null, wentWithId = false))
        assertFalse(MmsWhy.worthAskingWithId(404, null, "T19a2f", wentWithId = false))
    }
}
