> simple-webrtc
---

# notes
- `media.register_default_codecs()` contains Opus at 48000Hz with 2 channels. that's why SDP said Opus used 2 channels when I created a codec params with 1. 

# todo
- use webrtc::rtp::packetizer to turn raw samples into RTP packets
- use webrtc::media::io::sample_builder to turn RTP packets back into samples 
- allow for sides to pick a media format? 