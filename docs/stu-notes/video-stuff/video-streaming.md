apparently mp4 (ISO BMFF) is used by the media source extensions browser API
https://w3c.github.io/mse-byte-stream-format-isobmff/

need to add hint tracks for the streaming to work...

DASH or HLS may work
https://github.com/gpac/gpac/wiki/mp4box-other-opts

BAD! H.264 or HEVC is required for HLS..... (HTTP live streaming)

https://bitmovin.com/av1-playback-support/

MSE vs WebRTC
hopefully the WebRTC stream can be sent directly to a MediaStream object which would then be assigned to a `<video>` element. 
https://stackoverflow.com/questions/36416344/comparing-media-source-extensions-mse-with-webrtc