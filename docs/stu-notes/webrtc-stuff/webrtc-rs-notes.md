> webrtc-rs notes
---

# audio io
- the webrtc-rs Opus payloader just wraps raw bytes. could use this for CPAL easily. but doesn't include timestamps or allow sending multiple frames :(
- there's a SampleBuilder in media/src/io, which has a template impl for every Depacketizer (in rtp/src/packetizer)

--> doesn't have good audio codec
--> libopus: https://chromium.googlesource.com/chromium/deps/opus/+/1.1.1/doc/trivial_example.c
- libopus wiki: https://wiki.xiph.org/OpusFAQ
    - libopus probably runs on everything


# absctactions
- core uses a `SimplePeer` library that makes WebRTC easier to use

# RTCIceTransport


# RTCIceCandidatePair
- has a local and remote RTCIceCandidate

# offer answer example
## offer
- gets an offer and answer address
- makes an RTCConfiguration --> gives it the address of an IceServer (uses a google STUN server)
- creates a MediaEngine to configure the supported codec 
- creates a webrtc API

# webrtc
- https://datatracker.ietf.org/doc/html/rfc8825
- RTP is the transport. SRTP is required. 
- [sdp](https://datatracker.ietf.org/doc/html/rfc3264) offer answer model
- webrtc requirements: https://www.rfc-editor.org/rfc/rfc7478

# transports for webrtc
- https://datatracker.ietf.org/doc/html/rfc8835
- For data transport over the WebRTC data channel [RFC8831], WebRTC
   endpoints MUST support SCTP over DTLS over ICE.  This encapsulation
   is specified in [RFC8261].  Negotiation of this transport in the
   Session Description Protocol (SDP) is defined in [RFC8841].  The SCTP
   extension for I-DATA [RFC8260] MUST be supported.
- webRTC data channel establishment protocol: https://datatracker.ietf.org/doc/html/rfc8832
- webrtc data channels https://datatracker.ietf.org/doc/html/rfc8831

other things to look at
-  https://w3c.github.io/webrtc-pc/




# best sources for webrtc
- [transports for webrtc](https://datatracker.ietf.org/doc/html/rfc8835)
- [w3c webrtc spec](https://w3c.github.io/webrtc-pc/) 
    - latest version https://www.w3.org/TR/webrtc/

# sources for ortc
- [architecture](https://ortc.org/architecture/)
- [2016 publication](http://publications.ortc.org/2016/20161202/)

# what discord does
- https://discord.com/blog/how-discord-handles-two-and-half-million-concurrent-voice-users-using-webrtc
- custom webrtc with shorter SDP and no ICE. 
- Salsa20 instead of DTLS/SRTP

# rtp transceivers
- https://www.rfc-editor.org/rfc/rfc8829#name-rtptransceivers
- seem to allow modifying SDP
- the reference to "m=" sections is regarding the SDP object

# TrackLocalStaticRTP
- has a stream_id and an id (which is a track id)
- one stream can have multiple tracks 