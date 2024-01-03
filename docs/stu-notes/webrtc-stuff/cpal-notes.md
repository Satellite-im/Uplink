> cpal notes
---

# input
- retrieves a stream of raw audio in various sizes (1-4 bytes)
- can use `hound` to convert to a `.wav` file
- can use `gstreamer` [rawaudioparse](https://gstreamer.freedesktop.org/documentation/rawparse/rawaudioparse.html?gi-language=c) to parse and timestamp the data
- can use `gstreamer` [wavparse](https://gstreamer.freedesktop.org/documentation/wavparse/index.html?gi-language=c) to parse wav files
- `gstreamer` [mp4mux](https://gstreamer.freedesktop.org/documentation/isomp4/mp4mux.html?gi-language=c) to save to mp4 file

