## audio
- use [cpal](https://github.com/RustAudio/cpal)? 
    - [raw audio parse](https://gstreamer.freedesktop.org/documentation/rawparse/rawaudioparse.html?gi-language=c)
    - send from gstreamer to [audio sink](https://gstreamer.freedesktop.org/documentation/tutorials/playback/digital-audio-pass-through.html?gi-language=c) (different ones per platform)
    - also send from gstreamer to some sort of file sink

## video
- [opencv](https://github.com/opencv/opencv)
    - [video capture](https://github.com/twistedfall/opencv-rust/blob/master/examples/video_capture.rs) 
    - [raw video parse](https://gstreamer.freedesktop.org/documentation/rawparse/rawvideoparse.html?gi-language=c)
    - send from gstreamer to [video sink](https://gstreamer.freedesktop.org/documentation/tutorials/basic/platform-specific-elements.html?gi-language=c)
    - just save video for now. figure out how to turn frames into [images](https://github.com/alexcambose/webcam-base64-streaming) for rendering in dioxus later

## screen
- [scrap](https://github.com/quadrupleslap/scrap)

## WebRTC
- how to set up the WebRTC stuff so that it supports multiple audio/video formats? 
    - negotiate formats during signaling 
- stream management
    - should forward streams to something that combines them, for displaying unified audio/video 
    - register callbacks for each track? 
    - could pass one of these: `Arc<Mutex<dyn webrtc::media::io::Writer + Send + Sync>>,`
    - associate a name/peer id with each track
    - peer_connection.on_track 
        + possibly store a pointer to the RTCRtpReceiver
        + recieve bytes
        + check for registered callbacks
        + if they exist, pass bytes to the cb. 
- signaling needed
    - send sdp
    - send ice candidate (local discovers their ice candidates and sends them to remote)
    - add track
    - remove track
- Facade
    - run the WebRTC stuff on its own thread
    - provide API to start/end call
        - participant list - ids used for signaling at least
    - mute/unmute
    - record streams
    - select media format for audio/video (used in negotiation and for saving raw media which originates locally)
    - register/unregister observers (via channels) 
        - example use: a Dioxus Element wants to receive frames to render in an img tag

# tasks

## video
- use opencv to capture raw camera on 
    - Windows
    - Linux
    - Mac
    - IOS
    - Android
- use opencv to capture screen on 
    - Windows
    - Linux
    - Mac
- figure out how to send raw video (from opencv) to GStreamer

## audio
- use cpal to capture raw audio on
    - Windows
    - Linux
    - Mac
    - IOS
    - Android
- figure out how to send raw audio (from cpal) to GStreamer

## GStreamer
- combine multiple audio streams into one
    - dynamically add a sink to the pipeline which allows for saving the individual or combined audio streams
- send audio stream to speakers on
    - Windows
    - Linux
    - Mac
    - IOS
    - Android
- receive video stream
    - save to file
    - parse into frames which can be individually viewed like a picture (so they can be passed to an HTMl `<img>` tag)

## WebRTC
- tbd

## Warp
- add WebRTC component
- add media capture components (video and audio)
- tbd
