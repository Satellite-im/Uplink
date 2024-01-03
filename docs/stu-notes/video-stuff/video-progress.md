# Video Progress (2023-06-28)
- Researched methods of capturing video. Need to do a proof of concept (involves making a small test program, probably in Warp/tools). 
- Plan to use opencv. it has Rust bindings [here](https://lib.rs/crates/opencv). The opencv documentation describes how to capture video [here](https://docs.opencv.org/4.x/dd/d43/tutorial_py_video_display.html). 
- [h.264 codec](https://docs.rs/openh264/latest/openh264/)
- I don't believe that Dioxus supports video streaming yet, but I can try updating an `img` tag at 30-60hz until support for video streaming is added. 