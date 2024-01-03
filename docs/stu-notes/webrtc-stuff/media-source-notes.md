> media-source notes
- https://www.w3.org/TR/media-source/
- https://developer.mozilla.org/en-US/docs/Web/API/MediaSource
- https://developer.mozilla.org/en-US/docs/Web/API/Media_Source_Extensions_API
---

# overview
- lets javascript dynamically construct streams for <audio> and <video> elements
- objects
    - MediaSource
    - SourceBuffer
- in the video/audio tag, replace source with media source
- common codecs
    - H.264 video codec, AAC audio codec, and MP4 container format

# examples
- https://gist.github.com/skrater/eecebed67a26a1b107dd447e3165d4d4
- https://flashphoner.com/how-to-broadcast-webrtc-rtsp-and-rtmp-streams-to-media-source-extensions-via-the-websocket-protocol/
- https://github.com/kevinGodell/live-stream-media-source-extensions/blob/master/index.html

# using the wrong API?
- https://developer.mozilla.org/en-US/docs/Web/API/Media_Capture_and_Streams_API

# use gstreamer to send to browser
- https://gist.github.com/tetkuz/0c038321d05586841897
- https://4youngpadawans.com/stream-live-video-to-browser-using-gstreamer/
- https://gstreamer.freedesktop.org/documentation/tutorials/basic/gstreamer-tools.html

# gstreamer with chrome
- https://github.com/janoglezcampos/GstreamerChromeBridge

MSE may require mp4 which may not support live streaming

https://github.com/Charles-Schleich/WebRTC-in-Rust
https://github.com/Charles-Schleich/WebRTC-in-Rust/blob/master/wasm_client/src/common.rs#L517