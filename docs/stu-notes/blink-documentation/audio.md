> Audio notes, pertaining to Blink
- Opus RFC: https://www.rfc-editor.org/rfc/rfc6716
- Homepage for Opus Codec: https://opus-codec.org/
- libOpus bindings: https://docs.rs/opus/0.3.0/opus/
- WebRTC implementation: https://docs.rs/webrtc/0.7.3/webrtc/
- Audio I/O: https://docs.rs/cpal/0.15.2/cpal/
---

## Background information
- Opus encodes a set of raw audio samples at a given number of channels (1 or 2), sampling rate and bit rate into a packet, per rfc6716. An Opus packet can be decoded into audio samples at a different sampling rate and number of channels. 
- The webrtc-rs library transports Opus packets differently based on the codec parameters. An Opus packet is transported in possibly multiple RTP packets and the frame size (number of samples per Opus packet) and sampling rate are used to reconstruct the RTP packets to yield the Opus packet. 
- For some reason, when an Opus packet is transported via the webrtc-rs library, decoding the Opus packet using different parameters than those used to transport it yields an unsatisfactory result. This is believed to be due to the webrtc-rs library as Opus itself can encode and decode audio to arbitrary formats. 
- To support devices with different hardware such that they require different sampling rates or number of channels, the audio signal is transformed before being Opus encoding and after Opus decoding. 

## Requirements
- The Opus codec requires specific frame sizes such that for a given sampling rate, an Opus packet spans 2.5, 5, 10, 20, 40, or 60 milliseconds. 
- A mechanism is needed to collect audio samples and pass them to the Opus codec. Likewise, a mechanism is needed to decode Opus packets and pass the raw audio samples to the hardware. 
- It is preferred that this mechanism be abstracted so that another codec could be used if desired. 
- The mechanism should work in conjunction with the webrtc library, which provides "Tracks" for local (source) and remote (sink). Opus packets should be written to the source track and retrieved from the sink tracks. 
- The SourceTrack and SinkTrack need to be told the audio format to be used for the WebRTC transport, as well as the audio format required by the hardware. 
- The SourceTrack should also retrieve raw audio from the input device and the SinkTrack should send raw audio to the output device. 

# Audio configuration and manipulation
- the CPAl crate provides a list of supported configurations. A configuration specifies the min and max sampling rate, sample format (i16 or f32), and hardware buffer size. It is assumed that all devices support f32 and that will be used across the board. 
- By default, the webrtc library will use single channel audio at a sample rate of 48kHz. 
- By default, the audio input and output configurations will copy the config used by webrtc.
- Blink will validate the audio configs to ensure it is supported by the hardware. If needed, a different sample rate and/or number of channels will be used. This will require transforming the audio samples. 

## Audio pipeline
- input: microphone -> CPAL input stream -> Opus packetizer (called a framer) -> webrtc packetizer -> write to RTC track
    - the Opus packetizer mixes audio channels and resamples audio if needed. It then packs the samples into an opus frame and encodes them. 
- output: read from RTC track -> unpack RTP packet and recombine into an Opus packet -> decode Opus packet -> mix audio channels and resample if needed -> send to speakers


## Misc
- The Opus codec allows specifying a bit rate. Should make this configurable in the future. A higher bit rate could mean better quality audio. 

## CPAL notes
- CPAL provides an InputStream and an OutStream, neither of which are `Send`. This means that storing these streams in a struct which has `async` functions is not possible.
- the Blink implementation stores these streams in global memory within the `host_media` module. 