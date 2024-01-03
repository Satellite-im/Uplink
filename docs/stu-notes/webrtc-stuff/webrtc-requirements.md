
# sending
- can create a video and audio track, and can add these tracks to any peer connection
- if a peer doesn't support a track, what do? 

# receiving 
- want to receive multiple tracks and combine into one 

# error handling
- reconnect on failure

# termination
- remote side terminated
- local side terminated

# signalling
- look at example `play-from-disk-renegotiation`

# gstreamer
- use video overlay interface to display a window. need to create a window with a UI toolkit and pass the window to GStreamer
- GstVideoOverlay: https://gstreamer.freedesktop.org/documentation/video/gstvideooverlay.html?gi-language=c
- gst_video_overlay_set_window_handle can tell the video sink to render onto an existing window surface 
- need to get a window handle in 
    - windows
    - IOS
    - linux
    - Android
- tao::window::Window? https://docs.rs/tao/latest/tao/window/struct.Window.html


# tasks
## Make easy way to connect to peers
- add/remove video and audio streams 
    - signaling (Manuel is adding this to Warp)
    - track peer connections
- set destinations (to file, speaker, screen) 

## play audio/video stream
- create window using tao and tell gstreamer to display in that window
    - NOPE! according to packages/desktop/src/desktop_context.rs in the Dioxus source code, Dioxus currently only supports one window. 
    ```
    // currently dioxus-desktop supports a single window only,
    // so we can grab the only webview from the map;
    // on wayland it is possible that a user event is emitted
    // before the webview is initialized. ignore the event.
    ```
- use Javascript...make the webview/browser establish a WebRTC connection with Dioxus. it's probably the only way. 
- media-source-extensions with websockets
    - sockets.io for websockets?
    - https://www.w3.org/TR/media-source/
    - todo: create a websocket server and send stuff to dioxus

## for later
- multi-person calls require playing and saving multiple audio tracks
- same for video

# todo: create websocket server and send stuff to dioxus

## manage WebRTC connections and associated streams
- dynamically add/remove video and audio streams 
- signaling (Manuel is adding this to Warp)
- handle multiple peer connections
    - combine streams to play/display simultaneously
- set destinations (to file, speaker, screen) 

## play audio/video streams
- media-source-extensions with websockets
    - https://www.w3.org/TR/media-source/
    - proof of concept: create a websocket server and send stuff to dioxus
- alternative is connecting to the WebView via another WebRTC stream (undesirable)
- dioxus doesn't support multiple windows so using tao to create a new window for displaying a stream is not an option. 


# components
- websocket server for audio and video stream
- signaling 
    - to configure a connection (the audio/video codecs)
    - open the configured connection
    -  close/renegotiate
- start GStreamer and possibly send to UDP port
- handle a connection
    - configure callbacks when tracks are added
    - connect GStreamer to WebRTC track
    - configure where bytes go (the WebSockets server and optionally a file)