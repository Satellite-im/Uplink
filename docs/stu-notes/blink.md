> Blink description
---

# webrtc
- webrtc-rs was used for teleconferencing: https://github.com/webrtc-rs/webrtc
- this crate allows peers to specify an ICE server, perform an SDP exchange, and finally connect to each other. 
- for each peer connection, one may add an arbitrary number of tracks and data channels. A track is generally either an audio or video stream. a data channel is just a transport; this lets the library user define their own protocol. 
- the only hard thing to do with webrtc-rs was to figure out how to establish a connection between peers. The examples had to be consulted for this. There are a number of steps required regarding ICE, SDP, and then call offer/accept/reject. 
- note that webrtc-rs requires the library user to provide their own signal transport (ICE, SDP, call offer/answer/reject). Blink uses IPFS/libp2p for this. 

# warp-blink-wrtc
## special features
- automute
    - unless a headset is used, any sounds emitted by a speaker will be received by the microphone. Careful timing of the signals emitted by the speaker and received by the microphone is needed to use an autocorrelation to detect such an echo and remove it from the microphone input. It may be possible to do this but seems either unlikely or extremely difficult. For now, Blink calculates the root mean square of the audio amplitude for each received audio packet and if the other side is determined to be speaking (due to volume) then the microphone is automatically muted for some predetermined time, like 100ms. 
- time of flight calculator
    - to diagnose audio quality issues, a datachannel was added to `simple_webrtc`. periodically a peer will start a messaging sequence which involves each side exchanging a series of timestamps. This will allow each side to roughly calculate the network delay. 
- mp4 logger
    - the MPEG-4 specifications are in the handover package. We have parts 1, 3, 10, 12, and 14. Part 12 is most useful. 
    - recording calls requires saving audio/video to an mp4 file. Unless one wants to store the entire call in memory and then write out the MP4 file all at once, a fragmented MP4 file must be used. The number of tracks must be specified at the beginning, and that information is written in a sort of file header (the MP4 spec calls everything a box). Declare the maximum number of tracks needed at the beginning. Assume 1 audio track per peer for now, until video and screen sharing is implemented. 
- rtp_logger: this module was used for debugging at one time. it isn't included in `warp-blink-wrtc` on purpose and can be deleted if desired. This was added before the time of flight calculator and may no longer be needed. 

## audio quirks
- if you try not sending audio packets that have a near-zero volume (where someone isn't speaking) you will have problems on the other side if there is network delay - the packets will be queued up and received all at once and then the audio will be played too fast. Omitting silent audio packets requires adding timing information to ensure adequate delay between each packet. 
- [cpal](https://docs.rs/cpal/latest/cpal/) is used for audio I/O. It provides callbacks where samples must be read from or written to a buffer. For audio output, the cpal callback expects audio samples to be copied to a buffer which it then provided to the speakers. A `HeapRb` is used for speed. if that buffer is too small and network delay occurs, all the audio packets will be received all at once, the ring buffer will run out of space and the earliest samples will be overwritten, and the audio will sound choppy. Make sure that the audio buffer for the speaker is large enough. I tried detecting when it is full and then just dropping packets but if the packets all arrive at once, due to a network delay, then a large number of packets will be discarded and the audio will still sound choppy. 

## simple_webrtc
- uses `webrtc-rs` to create connections between peers. 
- for the current call, manages all peer connections and related streams/datachannels. 
- communicates with the library user by emitting events. This was needed because the library user is responsible for exchanging signals.

### time_of_flight
- used to detect/debug audio problems due to network delay. 
- in time_of_flight/mod.rs there's a `msg_timer` which is used to periodically initiate the time of flight sequence. 
- in simple_webrtc/mod.rs, in the `connect()` function, a callback is passed to `peer_connection.on_data_channel` that handles the message exchange. 
- if a round trip time of 300ms or more is detected, an AudioDegradation event will be emitted because it is assumed that there was a network delay. 

## host_media
- handles connecting webrtc audio streams (later video too) to hardware. For audio, [cpal](https://docs.rs/cpal/latest/cpal/) is used. Note that a `cpal::Device` is not `Send` so a struct containing said device can't be given to a tokio task. The options were to create a thread that is controlled via channels or to store the devices in static memory and use a mutex. I opted for the unsafe code but if someone really insists on the safe approach, the branch `feat/safe-host-media-controller` will help them get started. Note that blink has been refactored since the time this branch was created and code will likely have to be copied over rather than merged. 
- the `default_controller.rs` uses the `host_media/audio` module while the `loopback_controller` uses `host_media/loopback` (for audio loopback, described below under blink-repl). 

### audio I/O
- audio I/O uses the concept of source and sink tracks. A source track comes from the microphone and is sent to peers. Sink tracks are received from peers and are sent to the speakers. These correspond to the `source` and `sink` modules within `host_media/audio`. 
- the audio encoding/decoding process is currently performed on separate tasks. I assumed it was a CPU intensive process and didn't want to hold up the tokio async runtime. Maybe it's ok to perform lots of opus decoding from within a tokio task but I've avoided that for now. 
- rayon is used to decode audio packets in parallel, if possible. 
- note that the Opus codec doesn't work with all combinations of parameters, but it seems to work with a sampling rate of 48Khz with a 10ms window. This results in audio packets containing 480 samples. That's why you see the numbers 480 and 48000 in audio/sink and audio/source. The mp4_logger also expects opus packets of 480 samples at 48000. 
- also note that the opus codec internally converts to 48KHz and it seems that any modern device would support that frequency. Because of this, it seemed unnecessarily complicated to abstract the sampling rate away (which it was at one point). 
- the thresholds for the speech detector were chosen after examining data gathered using the `audio-codec-repl` found in `warp/tools`. 

### mp4 logger
- whenever a call is started, the mp4_logger spawns a task which communicates with the library user via channels. The task receives MP4 fragments via a channel and writes them to a file. At startup, the task writes the mp4 header file via `write_mp4_header`. It uses a fork of the [mp4 crate](https://docs.rs/mp4/latest/mp4/) which has been modified to allow writing fragmented mp4 files and to support the opus codec. Extending the mp4 crate to support the opus codec required adding a new box and giving that box the correct header/metadata. Something similar may be needed to support the AV1 codec. Satellite's fork is [here](https://github.com/Satellite-im/mp4-rust/tree/master2)

## blink_impl
- `mod.rs` implements the `Blink` trait, defined in warp/src/blink
- spawns tasks to listen to IPFS/libp2p gossip channels, and to listen for events generated by simple_webrtc. This folder has a readme with more information. 
    - To deal with peers dynamically joining and leaving a call, `gossipsub_sender` periodically announces the peer's presence on the gossip channel. This information is used to determine which peer sends the `dial` signal. 
    - To deal with messages failing to send (such as due to the recipient not being online), `gossipsub_sender` retrys sending all commands until all the recipients receive it. 
- for gossip channels, see blink_impl/signaling.rs
- for encryption/decryption, see blink_impl/store.rs

# warp/tools
- opencv-test: no longer needed. was used to quickly get camera capture up and running but it isn't worth the trouble to use it because it has too many dependencies (things which would increase the effort to cross compile) and the binary is too large (due to features we don't need). 
- blink-repl: a read-evaluate-print loop that allows two peers to call each other. 
    - the warp branch `feat/blink-loopback2` has a modified version of blink-repl - it enables the `loopback` feature of `warp-blink-wrtc`, which makes blink connect the incoming and outgoing audio channels. Run this version of `blink-repl` on a droplet, hosted in another location such as New York or Sydney Australia, and you can talk to yourself. This allows testing Blink with network latency, and allows calculating the network latency. 
    - use as follows:
        - `path/to/repl /path/to/empty-folder`. The folder will be automatically created the first time blink-repl runs. it creates a warp instance and uses a password of `abcd` or the like. This allows the same DID to be used across instances of the repl and doesn't hassle the tester with logging in. 
        - start the repl on 2 machines. a `did:key:<identifier>` is printed in the terminal. copy that from one terminal and in the other type `dial did:key:<identifier>`. When the recipient receives the call, it will display a message in the terminal. you can do `answer did:key:<identifier>` or `answer` for short. the shorthand command will answer the most recently received call. You can then talk. Other commands are available and you can see via the `--help` command (from within the repl). 
- audio-codec-repl: allows one to record raw audio and then perform operations on those files, such as encoding, decoding, and adjusting loudness. There are options to modify the raw audio format and the opus codec configuration. 
- video-codec-cli: this was moved to satellite-im/video-streaming-prototype. the one in Warp just tested camera capture and using libaom to encode (after converting from RGB to YUV). 

# audio
- the cross platform audio library crate is used for audio I/O. https://docs.rs/cpal/latest/cpal/
- decided to use the Opus codec because it's high quality and free to use. Note that Opus is C code (as is most any audio/video codec) and requires special care when cross compiling. Documentation:
    - header file for encoder and decoder: https://github.com/xiph/opus/blob/master/include/opus.h
    - Opus website https://opus-codec.org/

# video
- decided to use the AV1 codec (produced by the Alliance for Open Media) because it's a high quality and free to use. Decided on the [libaom crate](https://docs.rs/libaom/latest/libaom/) because it's simple and seems to work. AOM Documentation:
    - encoder header file: https://aomedia.googlesource.com/aom/+/refs/heads/main/aom/aom_encoder.h
    - decoder header file: https://aomedia.googlesource.com/aom/+/refs/heads/main/aom/aom_decoder.h
    - Alliance of Open Media website https://aomedia.org/av1-features/get-started/
- for RGB <-> YUV: https://web.archive.org/web/20180423091842/http://www.equasys.de/colorconversion.html

# forked repositories
- libaom
    - needed to modify the build script to allow either a shared library or statically linked library. It seems that libaom isn't available on MacOs and Windows and those platforms require a statically linked library. 
- mp4-rust
    - needed to implement fragmented mp4 files to allow recording a conversation in real time. 
    - needed a box added (like a class for Opus) to allow saving opus audio. 
    - need to declare the number of tracks when the file is created, so assumed 1 track per person since at the time only audio was implemented. 
    - if video is added later, can declare 2 tracks per person - 1 for audio and 1 for video. It's ok to have a track with no data. 
    - the repository maintainer didn't respond to my pull requests. maybe the repository has since been updated but it hadn't been for months. 
- opus
    - needed to point to different fork of audiopus-sys
- audiopus-sys
    - needed to modify the build script regarding static linking. When libopus is cross compiled, the build script needed a better way to input the location of the .a file. see the build.rs file and Dockerfile.aarch64-android (in warp) for more information. You have to set some environment variables to tell the build script to use static linking and to tell it where to find the library. The dockerfile provides an example of how to cross compile libopus and tell audiopus-sys to use the resulting .a file. 
- dioxus
    - this one is for uplink, not blink.
    - There were some crashes in Uplink due to Dioxus. Evan (one of the project maintainers) fixed them and opened pull requests but even now, months later, those PRs have not been merged (not his fault). One was related to event bubbling and one was related to updating the version of wry. Dioxus was forked and the needed PRs were merged there. 

# cross compiling
- see the Dockerfile.aarch64-android in Warp and Uplink