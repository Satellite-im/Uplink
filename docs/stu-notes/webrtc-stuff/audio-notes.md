
# todo
- use cpal::Sample https://docs.rs/cpal/0.15.2/cpal/trait.Sample.html
- use cpal example: https://github.com/RustAudio/cpal/blob/master/examples/synth_tones.rs

# audio test tools
- voicemeter bananna and voicemeter audio cable

# more concepts
- https://developer.mozilla.org/en-US/docs/Web/Media/Formats/Audio_concepts
- bandwidth: the range of represented frequencies
- bitrate: the number of bits used to encode said frequencies. too few bits can result in lossy compression. 

# audio concepts
- https://larsimmisch.github.io/pyalsaaudio/terminology.html
- https://techpubs.jurassic.nl/manuals/0650/developer/DMSDK_PG/sgi_html/ch08.html

# audio over the web
- https://developer.mozilla.org/en-US/docs/Web/Media/Formats/Audio_concepts
- https://developer.mozilla.org/en-US/docs/Web/Media/Formats/Audio_codecs

- https://developer.mozilla.org/en-US/docs/Web/Media/Formats/Audio_codecs#opus


# misc
Sample rate = number of samples / second
Frame = 1 sample from each channel (PCM)
Frame Size = Sample size * Channels
Frame Rate = frames / second.
For PCM the sample rate and the frame rate are the same since a frame consists of a a sample from each channel
a sampling rate of at least 44.1KHz captures the entire audible range


# crates
- cpal
- rodio: https://docs.rs/rodio/latest/rodio/

# examples
- https://chromium.googlesource.com/chromium/deps/opus/+/1.1.1/doc/trivial_example.c
- https://github.com/kyranet/astral-player/blob/main/crates/audio/src/stream.rs
    - https://github.com/kyranet/astral-player/blob/main/crates/audio/src/track.rs
- https://github.com/RustAudio/rodio/blob/master/src/stream.rs
- https://github.com/RustAudio/rodio/blob/master/src/dynamic_mixer.rs
- https://github.com/Patryk27/doome/blob/main/crates/lib/bevy/src/audio.rs