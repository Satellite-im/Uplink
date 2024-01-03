
# management's perspective
- core features
    - 1 on 1 chat, calls, video calls
    - group chats, calls, video calls
- must work on Windows platform (gamers almost exclusively use windows)

I know the main focus for the short term is Uplink-UI but I would like to gather some high level requirements for the teleconferencing feature. This would help when we re-visit the Blink interface and implementation. I'll post some questions and notes in this thread and after gathering feedback move it to a wiki. 


# MVP
- need to be able to receive multiple incoming calls, answer at most one and reject the others
- also need to be able to leave one call for another, then re-join the old call. 
- need in-call text messaging 
- need to add/drop streams
    - turning a webcam on and off
    - screen sharing
    - possibly when switching the codec or sample rate

- option to change audio/video sample rate of the incoming stream
    - use a default codec and sample rate
    - have a "low bandwidth" sample rate which can be requested
- option to record calls
    - allow codecs to be specified at the start of the call

- possibility of live streaming
    - option to forward audio and video (like someone's screen) to a live streaming API

# teleconferencing
- need to be able to receive multiple incoming calls, answer at most one and reject the others
- it might be nice to be able to leave one call for another, then re-join the old call. 
- do we need to allow participants to be added to a call after it has started? (maybe not, maybe later)
- probably want in-call text messaging 
- need to add/drop streams
    - turning a webcam on and off
    - screen sharing
    - possibly when switching the codec or sample rate

- should a call be tied to a RayGun Conversation?
    - RayGun could provide text-based communications during the call
    - would allow for leaving and re-joining a call as well as joining late -> just select the conversation from the sidebar and press a button to join the call
    - would restrict the number of participants to those present in the conversation -> adding new participants to the call would require starting a new group chat

- possibly the ability to change audio/video sample rate of the incoming stream
    - allowing this has the potential to create more work for the sender - the sender would have to encode their audio/video multiple times. despite that, this could be helpful for participants with limited network bandwidth or for large calls. It may be beneficial to support two resolution settings - one for regular bandwidth  and low bandwidth. 

- option to record calls
    - when recording a call, especially for content creators, it may be helpful to specify the codecs and sample rates used
    - letting every participant pick their own codec and sample rate is probably too complex. 
    - the options seem to be allowing the codecs to be specified when the call is initiated and/or when a participant starts recording the call
   - may want to save the configuration, allowing faster set-up in the future

- possibility of live streaming
    - will Uplink eventually interface with Twitch, Facebook Gaming, or Youtube and will blink need to know about this? 
    - for example, would there be an option to forward audio and video (like someone's screen) to a live streaming API? 


# blink - high level
- what high level features does Blink need to support
- dial -> accept/reject
- hang up 
- add/remove voice/video stream
    - should video communications be different for 1 on 1 calls and group calls? for example, default to accepting a video stream for 1-1 calls (for webcam) but for group calls let the participants offer a stream which others can open/close at their discretion. 
- questions about media resolution
    - should participants be allowed to specify what resolution and format they want to receive voice/video at? allowing this has the potential to create more work for the sender - the sender would have to encode the stream multiple times. despite that potential difficulty, this could be helpful for participants with limited network bandwidth or for large calls. It may be beneficial to support two resolution settings - one for regular bandwidth (higher sample rate) and low bandwidth (lower sample rate). 
    - should participants be allowed to specify what voice/video codec is used? perhaps use a default but allow a participant to specify a different codec when initiating a call. or perhaps only expose this feature when recording a call, since that's the only time it matters
- potential other features
    - change sample rate for high resolution and low resolution (maybe only allow this if someone starts recording a call)
    - change codec for voice/video (maybe only allow this if someone starts recording a call)
    - possibility to offer a stream (say for screen sharing) which isn't sent to everyone on the call (only those who accept it)

## other questions
- will Uplink eventually interface with Twitch, Facebook Gaming, or Youtube and will blink need to know about this? 
    - for example, would there be an option to forward audio and a video window (like someone's screen) to a game streaming API? 


# video display
- want my own window for displaying video, not just for the popout player. i think this could help with rendering video -> can probably use GTK to do it. 
- would have to create a new window and set the size and position relative to that of the parent window, and update it whenever the parent window moves.
- would want it to be in front of the parent window but not the popout window. 
- --> or wait for Dioxus to create a video stream element

---
# Steam Management 
- happens once a stream is created

## needs
- start, stop/pause, and close the stream
- forward the output to a device 
    - audio can be handled transparently 
    - video will probably require something custom -> tell a specific stream to render in a specific window 
- forward the input over the network 
    - can be handled transparently 


---
# difficulties
- selecting and reading from audio input device seems to be library specific. 
- same thing for selecting and playing to an output device
- same for video input/output 
- needs
    - select audio input device 
    - select audio output device
    - select video input (webcam)
    - select video input (screen/window) -> later if ever
    - video output
        - either use a library that can render video to a window
        - or pass frames through a callback

Warp requires traits. Needs to be able to change the implementation in the future. 
Teleconferencing currently relies on webrtc-rs. This library also provides codecs. 
cpal is used for audio


# Media Requirements
- select audio input device 
- select audio output device
- select video input (webcam)
- select video input (screen/window) -> later
- video output
    - either use a library that can render video to a window, given a window ID
    - or pass frames through a callback
- select audio codec
- select video codec
- save stream to file






----
Misc Pseudocode for Call Management



// Communicate during a call

// create a source track
fn publish_stream(&mut self, media_type: MediaType);
// tell the remote side to forward their stream to you
// a webrtc connection will start in response to this
fn subscribe_stream(&mut self, peer_id: Self::PeerId, stream_id: StreamId);
// stop offering the stream and close existing connections to it
fn unpublish_stream(&mut self, stream_id: StreamId);
// called by the remote side
fn close_stream(&mut self, stream_id: StreamId);
// when joining a call late, used to interrogate each peer about their published streams
fn query_published_streams(&mut self, peer_id: Self::PeerId);

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


