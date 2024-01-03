
## MVP API (Public)

### Call Initiation API
- OfferCall(raygun::Conversation, CallConfig) 
    - Sender announces that a call is available upon request
- AcceptCall(call_id)
   - Recipient requests the offered call (initiates the WebRTC connection process)
   - audio automatically connects
- RejectCall(call_id)
    - recipient indicates they will not join
- LeaveCall
    - if everyone leaves then the call ends
    - also used to revoke `OfferCall`

### Stream Management API
- OfferStream(StreamConfig) 
    - there must be an ongoing call 
    - Sender announces that a stream is available upon request
- RevokeStream(StreamConfig)
    - the sender stops offering the stream and closes all connections to it
- RequestStream(stream_id)
    - Recipient requests offered stream (initiates the WebRTC connection process) TODO: can SDP be skipped for subsequent streams? 
- CloseStream(stream_id)
    - if called by the recipient, the stream can be re-requested
    - not sure if the sender would need this. the sender could just use RevokeOffer

## MVP API (Internal)
- WebRTC signaling 
    - relies on an Ipfs<T>
    - see the simple-webrtc repository
- Blink signaling
    - relies on an Ipfs<T>

## Pseudocode 
struct CallConfig {
    call_id,
    audio_config, // codec and sample rate
    video_config // codec and sample rate
}

struct StreamConfig {
    stream_id,
    // may not need this
    call_id,
    subtype // audio or video
}

// Call would provide the functions listed in the "Stream Management API"
struct Call {
    call_id,

    // may not need this
    config: CallConfig, 
   
    // outgoing streams are forwarded to recipients
    outgoing_audio_stream: ?,
    outgoing_video_stream: ?,

    audio_recipients: ?,
    video_recipients: ?,

    incoming_audio_streams: ?,
    incoming_video_streams: ?,

    incoming_video_offers: ?,
    incoming_audio_offers: ?,    
}

// Blink would provide the functions listed in the "Call Initiation API" and the "Stream Management API"
struct Blink {
    current_call: Option<Call>,
    incoming_call_offers: ? 
    outgoing_call_offer: ? 
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Warp notes
- raygun::MessageEvent could be extended to include the blink and WebRTC signaling. 
    - nope 
- make new warp library: Blink 
- the implementation could use an Ipfs<T> for signaling 
    - Raygun has peers pubsub on <did>/messaging. 


