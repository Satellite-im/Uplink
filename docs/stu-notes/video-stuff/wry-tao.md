[wry](https://github.com/tauri-apps/wry) connects the web engine on each platform and provides a unified interface to render webview. It creates windows. wry relies on tao. 

[tao](https://github.com/tauri-apps/tao) is a cross platform application window creation library in rust. 

# tao
- https://docs.rs/tao/latest/tao/
- `raw_window_handle`, `raw_display_handle` can be used with OpenGL to render graphics. 

# webview
- https://docs.rs/crate/webview/latest/source/library/webview.h

# gnome
[gtk](https://gitlab.gnome.org/GNOME/gtkf)

# webkit
- https://github.com/WebKit/WebKit
- https://trac.webkit.org/wiki
- https://webkit.org/blog/114/webcore-rendering-i-the-basics/

# tauri
https://github.com/tauri-apps/wry/blob/dev/examples/wgpu.rs

basically use opengl or webgl and render a texture. a texture is just an image and is usually used when creating animations programmatically, but a single video frame could be treated as a texture that is rendered on a 2d scene directly in front of the camera. 

there's a rust crate called wgpu that could help. 

# webgl
https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Tutorial/Getting_started_with_WebGL

ipc summary
https://github.com/tauri-apps/wry/issues/767

# custom protocol in wry for video
- https://github.com/DioxusLabs/dioxus/issues/933#issuecomment-1624034655
- https://github.com/tauri-apps/wry/blob/87b331a7d4c169814d2b6a1f8a06d976ad7565bc/examples/stream_range.rs#L25

- make a window using wry (I guess) and render it within an existing window so that to the user, it appears as part of the same page. 
- receive a video stream and use something like wgpu to render the frames within the window. I found an example of using wgpu with wry here https://github.com/tauri-apps/wry/blob/dev/examples/wgpu.rs. 
- somehow request a redraw when a new frame is available


task list
- extend the MP4 Logger, allowing it to save AV1 encoded video. 
- extend Blink, allowing it to send video streams as well. 
- possibly add timing information to blink audio and video packets (or extract it from the RTP packets) to aid in synchronizing audio and video tracks. 
- take prototype code and extend host_media to capture video. 
- find way to render video frames in Dioxus. Perhaps using wgpu or other OpenGL like library. Must support multiple video streams at once. 
    - https://discord.com/channels/899851952891002890/1185284618711203850/1185284618711203850

alternatively, serve an rtp stream
- maybe use a custom protocol? 

video-js looks interesting

https://ossrs.io/lts/en-us/docs/v4/doc/webrtc
- need to get RTMP. can apparently go from RTP to RTMP

# rust rtp to RTMP
- https://crates.io/crates/rtmp - part of xiu
    - https://github.com/harlanc/xiu/tree/master/protocol/rtmp
- https://github.com/harlanc/xiu - looks very impressive
- https://docs.rs/rml_rtmp/latest/rml_rtmp/ 

webrtc whip/whep - use whep for the client side
- cloudflare has a whip and a whep client

- https://blog.cloudflare.com/webrtc-whip-whep-cloudflare-stream/

# rtmp server
- https://github.com/harlanc/xiu/blob/master/protocol/rtmp/src/session/server_session.rs#L230C26-L230C26
- give it a stream_id and give it RtmpMessageData, which could be AudioData or VideoData. 
- actually looks like StreamHub is used for this https://github.com/harlanc/xiu/tree/master/library/streamhub

golang media server:
- https://github.com/bluenviron/mediamtx
to test:
    - use ffmpeg to publish a file to the server
    - give a video tag the url to the server
    - rtsp seems to not work. rtmp to hls might work. https://stackoverflow.com/questions/60124729/how-to-show-rtmp-live-stream-in-web-browser

- https://github.com/video-dev/hls.js

- apparently mp4 fragments are used by HLS and DASH. i'm already generating those, they might be useful. 
