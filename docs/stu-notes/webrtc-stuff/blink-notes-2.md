# 2022-07-19 Mp4Logger
- list of peer_ids for the call
    - each peer gets 2 tracks: audio and video...


# 2022-07-18 todo
- when cpal stream returns an error, signal to blink... - done
- init source/sink with channels for logging rtp headers and audio? 
    - or basically an output directory for the rtp headers
    - and for the mp4 file...definitely a channel

mp4 logger command
- what to do when peers change audio i/o devices, resulting in a new track?
    - log audio in webrtc format - number of channels, sample rate, and codec won't change for the call. 
    - same track id for same peer, even if the peer creates new audio tracks. 

RTP analyzer - separate thing
- analyze rtp headers and emit events if audio quality is bad
- additional thing for log files? 

Mp4Manager
    - start() -> (tx channel, abort)
    - pass that channel to everything in host_media

for special debugging tools - pass a debug config to blink? update global memory? 

for Mp4Manager - have function to get a channel so it doesn't have to be cloned every time? 
- init (list of peers) - create audio/video tracks
- re-init...
- should be fine. 

- same thing for rtp logger? seems to make sense. 

# 2022-06-29
- todo: show jon the webrtc-rs library and the blink implementation...

# 2022-06-08
things to do next
- refine audio quality for Blink
    - see if there's a way to get rid of the echo
        - there might be
        - https://docs.rs/webrtc-audio-processing/latest/webrtc_audio_processing/
        - https://github.com/tonarino/webrtc-audio-processing
        - https://github.com/tonarino/webrtc-audio-processing/blob/master/examples/simple.rs
    - handle scenario where an offered call doesn't get delivered
- figure out how to save audio to a .mp4 file
- refine the UI for audio calls
- figure out how to capture video with the OpenCV library

https://telecom.altanai.com/category/web-realtimecomm-webrtc/webrtc-media-stack/

# 2023-06-06
- add retry to ensure offered call goes through. sometimes it doesn't go through. 
- use MultiPass to detect when a user goes offline. If that happens, update the call participants accordingly. 
    - warning - don't use the peer status. the peer can change their status to offline when they are in fact online
    - use Ipfs::is_connected(DID)
- todo: show which chats have ongoing calls and let peers join call even after rejecting it. 
- volume controls might help
- fix echo

# 2023-05-31
- want to track rtp packet sequence number to detect dropped packets. rtp `Sample` has this information already. may want to log it. 
    - handle internally
- want to record source and sink tracks to a specified file and then merge the files afterwards...
    - need to start/stop recording arbitrarily. handle internally, provide API for this. 
    - SinkTrack and SourceTrack needs an Option<FileName> and stop/start recording needs to create a new source/sink track. 
    - the reference manuals for MP3 and MP4 are proprietary... may only be able to use simple formats...
    - need a way to synchronize the audio...use RTP packets? 
    - probably want a separate thread to do this. 
    - use the hound crate to make .wav files? 
- done: want to detect when user is talking and pass that to the UI
    - use event channel and separate processor for this

About recording audio, the specifications for MPEG-3 and MPEG-4 are proprietary. While they are likely available for purchase, I didn't find any Rust crates that allowed converting raw audio into one of these formats. I'm not entirely sure what our users would prefer, but I could save the audio in .wav format, which is similar to saving the raw samples. It would probably be very easy to convert .wav into something else later. 

The only problem with formats like .wav or .flac is that they don't include timestamps, so if there are multiple audio files to merge, there isn't a way to synchronize their times. However, the audio samples coming to/from webrtc are grouped into RTP packets which have a sequence number and timestamp. I believe I can forward these to a dedicated thread and have that thread save the audio samples. This would allow the thread to add padding as needed, such as when a peer experiences packet loss or someone joins the call late. That way, although the audio files won't have timestamps, they would all be synchronized and if someone merged them into say a single mp4 file, in theory all the tracks would be in sync. 

If later we find a way to convert audio into mp3/4 and save to such a file directly, having a centralized thread to process audio is probably what we'd need. Does this seem like a good approach? 

# 2023-05-24
next features to add
- done: detect when user is talking
    - AudioLevel rtp extension
    - have to calculate the audio level yourself. basically just use RMS. 
    - can calculate it on the receiving end, but it may be more efficient to have each peer calculate their own audio level. just use this? https://docs.rs/bs1770/1.0.0/bs1770/
- test group calls
- fix possible echo - speakers feeding into microphone
- try not using fec in webrtc codec parameters
- make bitrate configurable 
- add debugging for dropped rtp packets
- silence noisy logs about not sending audio but add debugging for when this is a persistent problem.
- save call audio to .mp4 file. 

todo: go through blink implementation and check for deadlocks...
    - seems fine.

- old
- todo: make WebRTC a singleton...
- also emit UI events
- make bitrate configurable
- don't clone did...
- compare what was done since 
    - looks like from may 9 to may 24 I got calling to work. 
- work from may 9 to 24
    - add IPFS signaling
    - add signal encryption
    - debug and fix audio issues
        - same audio format not supported across devices
        - transform audio formats
        - create module to manage media tracks 
        - create test tools to validate Opus codec
    - implement state management for call
    - debug webrtc issues arising from not listening to correct events from webrtc-rs library. 

# 2023-05-22
- done: if connection fails before peers are connected, can't terminate the call
- windows may require dual channel audio. need to fix that shit. 
- use "krisp" to remove echo from call audio. Discord uses it. 
- use multiple ICE/STUN services...
- detect when user is talking

# 2023-05-10
- leave call checklist
    - clear active_call
    - send leave signal
    - ipfs unsubscribe (deinit webrtc should do this automatically)
    - deinit webrtc
    - reset host media
- join call checklist
    - clear active_call
        - if active_call isn't none, leave the call
    - ipfs subscribe
    - start media
    - start webrtc
    - send join signal

- offer call checklist
    - leave current call
    - set active call
    - start media
    - ipfs subscribe
    - start webrtc
    - send offer signal

- upon receiving join signal
    - webrtc dial

- upon accepting a call
    - send join signal

- upon rec

- left off a big thing - adding test code to warp CLI

- how to add automatic reconnect? 
- how to remove media streams when a peer disconnects?
- if a peer disconnects, let them rejoin
- need a way to end the call from the threads

# 2022-05-08
- short term goal: audio calling
- note that video calling requires modifications to Dioxus to support video streaming. 
- blink tasks: https://docs.google.com/document/d/19GeeEXeG-b4DUyLjWz0pKtJkojkuwskj5kC9DLfMv2s/edit?usp=sharing
- blink dependencies: https://docs.google.com/spreadsheets/d/1nQyBN7l5fL6wim5zpUjaTsVZUGFcESq4BbHSsLtUyac/edit?usp=sharing

## L1 tasks
- Blink API
    - create an API which is decoupled from WebRTC, audio and video libraries.
- Blink implementation
    - uses webrtc-rs for WebRTC and CPAL for audio. 
    - create module to manage a WebRTC connection
        - needs to initiate, accept, and reject calls
        - Allow the local host to create a SourceTrack, representing an input device. 
        - Upon connecting to a peer, all source tracks should automatically be forwarded to the peer. 
        - When peers add a track, return this track via an event so that another module can connect the track to an output device.
    - create a module to manage audio i/o
        - CPAL streams are not Send, so they can't be stored in a struct which has `async` functions. Instead, use static variables and expose via an API that resembles a Singleton. 
        - Store the audio source track. Assumes the same source track can be used for multiple peer connections. If this is untrue, will need to store a source track for each peer. 
        - store the audio sink tracks
        - allow the user to specify the audio source and sink devices, and connect these devices to the source and sink tracks automatically. Need to handle at least the following events:  device change and track addition/removal. 
    - devise signaling schemes
        - call initiation
            - use one gossip channel per peer for call initiation
            - the message will contain the call uuid
        - call join/leave
            - use one gossip channel per call to announce when a peer joins/leaves a call
        - call signaling
            - use one gossip channel per peer per call to exchange WebRTC signals
    - spawn threads to manage signals
        - one thread to handle call initiation 
        - one thread to handle the join/leave and WebRTC signaling. 
    - devise scheme to share data between threads and Blink implementation, and to control the threads
        - use a static variable to store data needed by the various threads and the BlinkImpl
        - store the thread join handles in the BlinkImpl
    - implement the Blink API

## L1 Tasks for Blink 
- create module to manage a WebRTC connection (simple-webrtc module) 
- create a module to manage audio i/o (designed to allow the future addition of video i/o) (host_media.rs) 
- manage signaling via tasks (signaling.rs) 
- implement the Blink API 

## L2 Tasks for Blink

## L2: simple-webrtc
- handle WebRTC signaling
- handle WebRTC events
- media management - encoding and sending audio input, and decoding and playing audio output
- WebRTC state management

### signaling
- background information: the WebRTC library doesn't provide a signaling mechanism. The library relies on an external signaling layer for the at least the following: call initiation, ICE and SDP exchange. Certain events need to be relayed to the library user. An event stream shall be provided for this purpose. The signaling layer shall drive an internal state, which shall be used to automatically respond to the WebRTC events. 
- call initiation signals
    - Offer call
        - a call will be accepted via another signaling channel
    - Reject call
        - This signal may not be needed. It probably doesn't make sense for group calls but it might be nice to have for 2 person calls.
- call management signals
    - join call
        - a peer announces they have joined the call.
        - everyone else on the call will initiate the webrtc connection process with the peer
    - leave call
        - a peer announces they will leave a call. Without this, in the event of a webrtc disconnect, the library will assume the disconnection was due to a network error and will attempt to reconnect. 
- webrtc signaling
    - ICE
    - SDP
    - possibly more. 
- simple-webrtc events
    - background information: simple-webrtc emits events which may include data that needs to be exchanged with peers via signaling. 
    - SDP
    - ICE
    - call initiation
    - call termination
    - add media track
    - possibly remove media track (Not currently included in webrtc-rs. May need to be added)

### media management
- background information: a common interface is needed to allow using various codecs. The interface shall connect a cpal::Device with one or more RTP streams. The implementation is responsible for passing data between the audio i/o devices, the codecs, and the RTP streams.
- Source Track trait
    - API: pause, play, change input device
    - Initialized with input device, codec, and RTP track.
    - Changing the input device automatically updates the RTP track.
    - SourceTrack implementations include code to turn audio samples into RTP packets.
- SinkTrack trait
    - API: pause, play, change output device
    - Initialized with output device, codec, and RTP track.
    - Changing the output device automatically updates the RTP track.
    - SinkTrack implementations include code to turn RTP packets into audio samples

### WebRTC state management
- background information: the webrtc-rs crate provides a WebRTC API. The objects created during the initialization process need to be saved for future use. 
- manage RTP source tracks (TrackLocalStaticRTP)
    - upon connecting to a peer, automatically connect it to the local source tracks.
    - when a source track is added or removed, all peer connections need to be updated accordingly. 
- manage peer connections (one RTCPeerConnection and a collection of RTCRtpSender)
    - RTCPeerConnection: used to set the SDP and remove all tracks on disconnect
    - RTCRtpSender: used to remove tracks and read incoming RTP packets

## L2: host_media
- background information: audio I/O depends on the CPAL library. An output device is associated with multiple input streams. An input device needs to have its audio forwarded to all connected peers. A singleton pattern makes sense here. 
- audio input
    - add/remove audio input device (and update the SourceTrack accordingly)
    - read audio input and send to a SourceTrack
- audio output
    - add/remove audio output device (and update the SinkTracks accordingly)
    - read audio output and send to the output device.
    - add audio output stream (one output stream is needed per peer)

## L2: Signaling
- background information: the signals need to be handled by their respective tasks. A mechanism is needed to 
control these tasks and allow them to communicate both with each other and with the Blink implementation. This will likely involve static variables controlled by mutexes and mpsc channels, stored in static memory and in the blink implementation. 
- state management for call initiation signals
- state management for call-wide broadcasts and WebRTC signals

## L2: implement the Blink API
- involves connecting the above components. 

# 2023-05-05
## call offer task
- send 3 types of messages: offer, accept, decline
- can only have one outgoing offer at a time.
- store some kind of state in static memory...
- don't want to have to store the SDP object for each pending call.... so deny all webrtc CallInitiated events if the sender isn't in the active call participants list

## webrtc task
- only accept call_initiated if the sender is in the participants list for the current call
- on disconnect, retry unless disconnect signal was received

## locks
- webrtc, static_data, and host_media all have locks. need to always lock in the same order to prevent deadlocks
- always lock static_data, then webrtc, then call host_media

## other stuff
- need to handle WebRTC events and peer signals....
- move webrtc to static data. it doesn't seem to need the peer id
- figure out how to encrypt/decrypt data which gets sent over IPFS
    - example of sending: FriendsStore::broadcast_request()
    - example of receiving: MessageStore::new()
    - both use Sata and to_ipld
    - for sending: ipfs.pubsub_publish(), giving it the topic and byte array

## encrypting
- use ecdh directly: https://github.com/Satellite-im/Warp/blob/main/extensions/warp-rg-ipfs/src/store/mod.rs#L187-L227

# todo as of 2023-05-02
- call_broadcast_stream - events from IPFS which pertain to the call
- call_signaling_stream - events from IPFS pertaining to a specific peer on the call
- webrtc_event_stream - webrtc events
- blink api - let the user dial, mute, unmute, add and remove media streams
- need to emit events for the UI (BlinkEventKind) --> implement get_event_stream() --> copy from simple_webrtc
- implement media_track::manage_tracks
    - close it down by dropping the tx channel. use spawn_blocking
    - maybe use an WebRTC event to add a source track...

need to store cpal host id and device id for audio and video...use this to construct the cpal::Device needed by the SourceTrack and SinkTrack. 

how to change output device?
- am reading bytes from the RTP tracks and writing them to the output device, in a separate thread...

media needs
- local audio input
    - called SourceTrack - create, remove, change device
- local audio output
    - called SinkTrack - create, remove, change device
- remote audio input (gets fed to the output)
    - add stream to SinkTrack

codec is really more of a codec_config
if a track gets closed, close the corresponding stream

use Stream.pause() and Stream.play() to mute/unmute participants and self

for webrtc
need to always listen to the IPFS topic for initiating calls
need to listen to a possibly changing topic for controlling an ongoing call
need to listen to an unchanging stream from webrtc struct, unless the struct gets overwritten

separate thread per stream? seems like it