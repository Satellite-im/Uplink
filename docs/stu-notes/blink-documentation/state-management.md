> state management
---

# Overview
- The blink implementation needs to handle asynchronous events from the following sources:
    - webrtc-rs: SDP, ICE, track added, connection state update (pending, established, disconnected, etc)
    - signaling layer - call initiation: one IPFS topic is used per peer, allowing peers to offer calls to each other. 
        - all signals are encrypted using either the destination's public key or a call-specific key. 
        - when a call is offered, it will contain a symmetric key, specific to the call, to be used in the call specific signaling channel. 
    - signaling layer - call signaling: one IPFS topic is used per call, for peers to announce that they have joined/left the call
    - signaling layer - peer signaling: one IPFS topic is used per peer, allowing peers to exchange ICE candidates and SDP objects. 
    - this makes for 4 separate channels to read from (handled by two tasks), all of which can modify the state. 

# Idiosyncrasies  
- when webrtc-rs is used to connect to a peer, a `PeerConnection` is created. Internally, some state is maintained such that if the connection is terminated and then one attempts to reconnect to that peer before webrtc-rs emits a `Disconnected` event for that peer, webrtc-rs will go into a bad state and will be unable to connect to that peer. 
- webrtc-rs seems to use a singleton/global state behind the scenes. Creating a new `webrtc::API` is not sufficient to 'fix' a bad state. 
- when terminating a call, it seems necessary to wait for the `Disconnected` event to be emitted for all participants for whom a `PeerConnection` was created. 

# Modules
- The state for a call is split across the following modules: `warp-blink-wrtc` (global data in the lib.rs file), `host_media` (manages the source and sink tracks), and `simple_webrtc` (manages the PeerConnections and their source tracks)

## simple_webrtc
- a single "Track" is used for each media source. The track can be cloned and given to each peer connection. That way, audio input can be written to a single track and the data is automatically forwarded to all connected peers. 
- simple_webrtc simplifies the process of adding and removing tracks from peers. It also forwards events emitted by webrtc-rs to the library user (in this case the blink implementation). 
- simple_webrtc is also used to offer, accept, and terminate webrtc connections, with respect to the webrtc-rs library. 

## host_media
- when a WebRTC track is created, it is given to the host_media module. This module then creates a source or sink track. For source tracks, the module will read raw audio samples, process them, and write then to the source track. For sink tracks, the module will read and process RTP packets, and send the resulting audio samples to the output device. 

## warp-blink-wrtc
- there can be multiple offered calls but only one `ActiveCall` at a time. 
- when offering a call, that call becomes the active call. When accepting a call, a call is chosen from the list of pending calls. (todo: remote side hangs up and local side removes call from list of pending calls)
- an `ActiveCall` has a `CallState`. The state is "uninitialized" until at least one peer joins. Before that, cancelling the call requires no waiting. 
- once a call is "started", it is automatically ended once there are no more connected participants. That is, if a group call is offered and one participant joins then leaves, the call is over. (todo: make this not so)
- when a call is offered, an audio format is specified for the WebRTC communication. The peers need not use that format for their hardware, and the `host_media` module automatically converts between the hardware audio format and the WebRTC audio format. 