> Opus Codec
- https://www.rfc-editor.org/rfc/rfc6716
---

# 2
- bandwidth can theoretically be as large as half the sampling rate but Opus never codes audio above 20kHz because that is the generally accepted upper limit of human hearing
- 24Khz sampling rate is what Opus uses for super-wideband. 
- for conferencing software, want a low latency to reduce echo effect (from requirements https://www.rfc-editor.org/rfc/rfc6366)
- Opus can be decoded to different sample rates. 
- the higher the bandwidth, the higher the required bitrate to achieve good audio quality
    - 8-12 kbit/s for narrow band speech
    - 16-20 kbit/s for wide band speech 
    - 28-40 kbit/s for full band speech
- frame duration: opus encodes frames based on duration - 2.5, 5, 10, 20, 40, or 60ms. 
    - multiple frames can be combined into packets of up to 120ms. 
    - try 20ms frames to start...

# 3 framing
- the opus encoder produces "packets" which are contiguous bytes meant to be transmitted as a single unit. Each packet consists of multiple audio frames encoded with the same parameters. 
- a well-formed opus packet must contain at least one byte - the table of contents header, also known as the TOC byte. see page 15 for mroe information. 

# 4 decoder
- 



----
RTP has an audio level extension that shows the audio volume and if it's voice. 
- https://www.rfc-editor.org/rfc/rfc6464
- combat packet loss with this: https://www.rfc-editor.org/rfc/rfc2198