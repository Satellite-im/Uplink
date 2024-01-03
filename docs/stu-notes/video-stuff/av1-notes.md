use av1, not h.264
- https://aomedia.org/
- no fees or royalties

https://aomedia.googlesource.com/aom

# specs
- writing to mp4: https://aomediacodec.github.io/av1-isobmff/
- https://aomedia.org/av1/specification/
- https://aomediacodec.github.io/av1-avif/


# rust code
- rust-av
    - https://github.com/rust-av/aom-rs/blob/master/src/encoder.rs
    - https://docs.rs/av-data/0.4.1/av_data/frame/index.html#structs
- av-codec (actually is just a trait)
    - https://docs.rs/av-codec/0.3.0
- rav1e
    - https://docs.rs/rav1e/0.6.6/rav1e/
- svt-av1
    - https://github.com/rust-av/svt-av1-rs
    - really want https://github.com/rust-av/svt-av1-rs/tree/master/svt-av1-sys


# example code
- https://aomedia.googlesource.com/aom/+/refs/tags/v3.6.1/examples/simple_encoder.c
- https://aomedia.googlesource.com/aom/+/refs/tags/v3.6.1/examples/

# rustav website
- https://rustav.org/blog/2020-03-30-rav1e-and-av-metrics/
- they produced the `rust-av` crate

# SVT-AV1
- https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/README.md
- https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/svt-av1_encoder_user_guide.md


# if only could capture YUV format from camera
- maybe convert with this? https://github.com/frankpapenmeier/libyuv
- https://docs.rs/libyuv/0.1.2/libyuv/fn.argb_to_i420.html

# misc
- x264 supports 4:4:4 aka YUV444. That's why the encoding looks so much better. 
- need an AV1 codec supporting 444

