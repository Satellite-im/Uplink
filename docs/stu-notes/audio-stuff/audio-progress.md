# audio notes (2023-07-31)
- warp-blink-webrtc has a module called source/framer.rs which uses a loudness_calculator to calculate the root mean square of a window. it then checks if that value is greater than 0.01 (multiplies it by 1000 to convert to a u8 and then checks if it is at least 10).
- according to this https://blog.demofox.org/2015/04/14/decibels-db-and-amplitude/ you can convert from db to amplitude as follows: db = 20*log10(amplitude). 
- 20*log10(0.01) is -40db. silence is around -60db. This heuristic seems to be pretty good. Note that it's using RMS instead of mean but rms probably assigns a higher weight to larger values and this is probably good for audio. 
- amplitude = 10^(db/20). 
- increasing by 6db doubles the amplitude. decreasing by 6db halves it. 
- to do today: make a program to test increasing loudness and add that to blink. 
    - branch: `feat/adjust-loudness`

# Audio Progress (2023-06-28)
- [webrtc-rs](https://github.com/webrtc-rs/webrtc) is being used to establish a connection and exchange packets. 
- Blink allows the user's hardware to use different configurations. Audio inputs are transformed to a common format before being sent over WebRTC. 
- the Opus codec is used. Other codecs are not yet supported and probably unneeded. 
- Audio features which would be nice to have include
    - echo cancellation - did some work here but the feature is not done. 
    - automatic gain adjustment (for loudness/volume)
    - background noise cancellation
    - saving Opus packets to a .mp4 file
- see branch feat/echo-cancellation

## Echo Cancellation work
- Tried using PulseAudio's [audio processing module](https://docs.rs/webrtc-audio-processing/0.4.0/webrtc_audio_processing/). It's very difficult to build this for windows. The PulseAudio documentation claims that someone is building it for Windows but their developer documentation only has instructions for building on Mac OSX - https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/Developer/
- It may be possible to cross compile for Windows. This is likely a multi-day effort. 
- Was able to use the module on Linux/Mac to cancel some background noise but have not gotten echo cancellation to work yet - if a laptop is used for an audio call and the volume is too high, there will be an echo. This could be a limitation of the library or it could be due to a mismatch in the input/ouput signals (which are passed to the echo cancellation module). 

## Other options for echo cancellation

### Re-implement echo cancellation
- the technique is called Acoustic Echo Cancellation (AEC)
- example using adaptive filter: https://www.mathworks.com/help/audio/ug/acoustic-echo-cancellation-aec.html
- example using autocorrelation: https://www.mathworks.com/help/signal/ug/echo-cancelation.html
- with some time I could probably figure this stuff out but there's probably already a better version of this that's open sourced, though perhaps not written in Rust. 

### use Google's C++ library
- https://webrtc.googlesource.com/src
- specifically the audio processing module: https://webrtc.googlesource.com/src/+/HEAD/modules/audio_processing/g3doc/audio_processing_module.md
- figuring out how to use the code in the audio_processing module would take some time.
- this library has audio and video codecs for just about everything.
- rust bindings for Google's WebRTC library: https://docs.rs/batrachia/0.1.1/batrachia/
    - only contains bindings for webrtc communication - does not contain bindings for the audio/video processing features
    - relies on (libRTC)[https://github.com/mycrl/librtc] to provide C bindings for WebRTC. This library doesn't include much. 
    - There are surprisingly few `extern "C"` statements in WebRTC. 

