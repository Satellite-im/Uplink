- https://lib.rs/crates/opencv
- https://github.com/twistedfall/opencv-rust
- https://docs.opencv.org/3.4/d8/dfe/classcv_1_1VideoCapture.html

Warp branch feat/blink-video

# OpenCV video capture guide
- https://docs.opencv.org/4.x/dd/d43/tutorial_py_video_display.html
- create the VideoCapture object
    - https://docs.rs/opencv/latest/opencv/videoio/struct.VideoCapture.html
- `.read()` captures each frame.
- can play a video from a file too

# example video project using rust
- https://github.com/hanguk0726/Avatar-Vision/blob/main/rust/Cargo.toml
    - cool libraries
        - rayon - parallelism
        - openh264
        - nokhwa: webcam capture library
        - image: an image codec

# opencv source code probably shows how to write to mp4 file

# data transformation
- use openh264 crate (requires YUV format) - https://docs.rs/openh264/0.4.1/openh264/
- opencv reads data into a mat https://docs.rs/opencv/0.82.1/opencv/core/struct.Mat.html
- opencv can supposedly transform to YUV
    - opencv::core::transform - requires a transformation matrix: https://en.wikipedia.org/wiki/YUV