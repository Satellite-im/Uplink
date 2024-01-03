
# process audio input from microphone
- read raw samples using CPAL
    - todo: allow user to select input device
    - CPAL receives a callback function which provides an array of samples
    - example: https://github.com/RustAudio/cpal/blob/master/examples/feedback.rs
- feed raw samples to a codec
    - for example: an OPUS codec
    - configure it with the agreed sample rate
    - tell the codec how many samples to pack into a frame 
    - OPUS encoder documentation: https://www.opus-codec.org/docs/html_api/group__opusencoder.html
    - rust bindings: https://github.com/Lakelezz/audiopus/blob/master/src/coder/encoder.rs
    - the `encode` function takes an input array and an output array, and returns the number of samples written to the output array. 
- put the OPUS output in an RTP packet
    - create a [PacketizerImpl](https://github.com/webrtc-rs/webrtc/blob/master/rtp/src/packetizer/mod.rs)
    - give it a [payloader (for OPUS)](https://github.com/webrtc-rs/webrtc/blob/master/rtp/src/codecs/opus/mod.rs)
    - call `packetize` and get a vec of RTP packets
- send RTP packets via the connection

# process audio input from peer (send to speakers)
- receive a track from WebRTC
    - read bytes from the track
    - turn the bytes into RTP packets via `webrtc::rtp::packet::Packet::unmarshal`
    - the RTP payload should be the encoded audio data
    - todo: use signaling to tell the recipient the parameters needed to decode the audio (sample rate, ect)
- decode the payload using a [decoder](https://github.com/Lakelezz/audiopus/blob/master/src/coder/decoder.rs)
    - writes samples to an output buffer
    - copy samples to a channel for CPAL to retrieve them 
- read from the channel within the callback function passed to the CPAL output device
    - todo: allow the user to change output devices (speakers, headphones, ect)

# alternatives
- use GStreamer
    - different audio source for each platform
        - alsa for linux
        - not sure about windows or mac
    - use plugins to build a pipeline
    - possibly even use GStreamer for WebRTC