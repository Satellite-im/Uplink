package com.infamousvague.ghostmessaging

/**
 * Why a picture message did not go or did not come, in plain words (Matt, 2026-11-13: "It seems like picture sending
 * is also not working at all almost like MMS isn't working"). On an emulator with a stand-in for a carrier both ways
 * work, so what stops one on a phone is the phone's or the carrier's: this is how the app says which, under the
 * message and in Settings › Android, where it used to say only "Not sent". Pure, so it is tested on the JVM.
 */
object MmsWhy {
    /**
     * Why Android could not send one: [code] is SmsManager's MMS_ERROR_* (what the sent broadcast's result is when it
     * is not OK), [http] the carrier's HTTP answer where there was one. Each reads after "Not sent: ".
     */
    fun send(code: Int, http: Int = 0): String = when (code) {
        2 -> "this phone has no picture-message settings (APN) for its SIM"
        3 -> "the carrier's picture-message service couldn't be reached. Check mobile data"
        4 -> if (http > 0) "the carrier's server refused it (HTTP $http)" else "the carrier's server couldn't be reached. Check mobile data"
        5 -> "Android couldn't read the message from this app"
        6 -> "the carrier asked for it to be tried again later"
        7 -> "this phone's picture-message settings are incomplete"
        8 -> "there is no mobile data connection. Picture messages need mobile data, even on Wi-Fi"
        9, 10 -> "the SIM it would go from isn't active"
        11 -> "mobile data is off. Picture messages need it, even on Wi-Fi"
        12 -> "the carrier has picture messaging switched off for this SIM"
        13 -> "it is too large for the carrier"
        else -> "Android gave no reason (code $code)"
    }

    /**
     * Whether a send that failed this way is worth trying again unasked: the phone could not reach the carrier, or
     * the carrier's server was in trouble, either of which a minute often mends. Not where the person has to do
     * something first (mobile data off, no SIM) or where the carrier said no to the message itself.
     */
    fun worthAnotherTry(code: Int, http: Int): Boolean = when (code) {
        3, 6, 8 -> true
        4 -> http == 0 || http >= 500
        else -> false
    }

    /** How long to wait before try number [next] (the second, the third): long enough for a connection to come back. */
    fun waitBefore(next: Int): Long = if (next <= 2) 20_000L else 90_000L

    /** How many times a picture message is sent before the person is told it did not go. */
    const val TRIES = 3

    /** Why Android could not fetch one that was announced. Reads after "Couldn't download a picture message: ". */
    fun download(code: Int, http: Int = 0): String = when (code) {
        4 -> if (http == 404 || http == 410) "the carrier no longer has it (it kept it for a few days)" else if (http > 0) "the carrier's server refused (HTTP $http)" else "the carrier's server couldn't be reached. Check mobile data"
        5 -> "Android couldn't write the message for this app"
        13 -> "it is too large"
        else -> send(code, http)
    }

    /**
     * Where an announced picture message is fetched from (Matt, 2026-11-14, on Verizon: "Im getting this error on
     * freshly sent photos", with his report's `not fetched … (result 4, HTTP 404)`). It is the address the
     * announcement gave; but some carriers announce an address that stops at an equals sign
     * (`…/servlets/mms?message-id=`) and expect the announcement's transaction id after it: their settings say so
     * (Android's `enabledTransID`), and their server answers "not found" without. Android's own texting apps add
     * the id where the carrier's settings ask and the address ends that way (PushReceiver in the platform's Mms
     * app); this app did not, so on such a carrier no picture could be fetched. [append] is that setting, or that
     * the address as announced has just been answered "not found". An address that does not end in an equals sign
     * is whole, and is left as it is.
     */
    fun fetchAddress(location: String, transactionId: String?, append: Boolean): String {
        val id = transactionId?.trim().orEmpty()
        if (!append || id.isEmpty() || !location.endsWith("=")) return location
        return location + id
    }

    /**
     * Whether a fetch that was answered "not found" should be asked for once more with the transaction id on the
     * address: where it went without one, and the address is of the kind that takes one. For a phone whose
     * settings for its carrier do not say what the carrier's server expects.
     */
    fun worthAskingWithId(http: Int, location: String?, transactionId: String?, wentWithId: Boolean): Boolean =
        http == 404 && !wentWithId && location != null && fetchAddress(location, transactionId, true) != location

    /** The server a picture message is fetched from, for the log: its name alone, never the rest of the address. */
    fun hostOf(location: String): String =
        Regex("^[a-zA-Z]+://([^/:?#]+)").find(location.trim())?.groupValues?.get(1) ?: "an address with no server in it"

    /**
     * A carrier's refusal of a message it took delivery of: X-Mms-Response-Status in its answer (OMA MMS encapsulation
     * 7.3.48), with its own words where it gave any. Null where the answer says the message was accepted (or says
     * nothing). Android reports such a message as sent; it is not.
     */
    fun refused(status: Int?, text: String?): String? {
        if (status == null || status == 0x80) return null
        val what = when (status) {
            0x82, 0xE1 -> "the carrier denied the service (this line may not have picture messaging)"
            0x83, 0xE2 -> "the carrier couldn't read the message"
            0x84, 0xC1, 0xE3 -> "the carrier doesn't know the number it is for"
            0x86, 0xC3 -> "the carrier had a network problem"
            0x87, 0xE5 -> "the carrier won't carry what is in it"
            0x88 -> "the carrier doesn't support this kind of message"
            0xEB -> "the line has no credit for it"
            in 0xC0..0xDF -> "the carrier couldn't take it just now"
            else -> "the carrier refused it"
        }
        val said = text?.trim().orEmpty()
        return if (said.isEmpty()) "$what (status ${"0x%02X".format(status)})" else "$what: \"$said\""
    }
}
