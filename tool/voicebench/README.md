# voicebench: voice and video channels with many members

Matt, 2026-11-14: "do performance testing for video calls and voice calls across multiple instances".

`bench.html` is one member of a channel, in a browser, speaking the app's own protocol (the hub's greeting and
signature, the room's name, token and sealing, the newcomer offering, `highestOpus`, `videoFor`). `run.mjs` starts
this branch's relay on this machine, puts 2 to 8 members in one channel as Chromium pages with a made-up camera and
microphone, and reads WebRTC's own numbers from each.

    PLAYWRIGHT=~/.npm/_npx/<hash>/node_modules/playwright/index.mjs node tool/voicebench/run.mjs
    … --only voice-4,video-3   --seconds 20   --settle 20   --fixed (video as it was sent before)   --hub wss://…

It writes `results.json` (not kept in git). Everything runs on one Mac, so it measures the app's load and bit rates,
not a network; all members' encoding shares that one machine's CPU, where on real devices each does its own.

## 2026-11-15, MacBook Air (10 cores), local relay

**Voice**, Opus 510 kb/s stereo, each member connected to each:

| members | connected | to join | audio a peer | up a member | loss | concealed | CPU a member |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 2 | 2/2 | 255 ms | 510 kb/s | 0.51 Mb/s | 0 | 0% | 6% |
| 4 | 12/12 | 256 ms | 510 kb/s | 1.53 Mb/s | 0 | 0% | 12% |
| 6 | 30/30 | 257 ms | 510 kb/s | 2.55 Mb/s | 0 | 0% | 17% |
| 8 | 56/56 | 260 ms | 510 kb/s | 3.57 Mb/s | 0 | 0% | 18% |

**Video as first sent** (1080p and 12 Mb/s to everyone, resolution held): 2 members 1080p at 11–19 fps; **3 members
1 fps; 4 members 0–1 fps**. Each connection encodes its own copy, so three members is two 1080p encodes each.

**Video sized by call size** (`videoFor`: 1080p/12 Mb/s one to one, 720p/4 Mb/s with two others, 540p/2 Mb/s with
three or four, 360p/1 Mb/s beyond; balanced degradation):

| members | sent | fps | CPU a member | loss |
| --- | --- | --- | --- | --- |
| 2 | 1920×1080 | 15–19 | 356% (software VP8) | 0 |
| 3 | 1280×720 | 21 | 37% | 0 |
| 4 | 960×540, 640×360 | 10–17 (CPU-bound: 12 encodes on one Mac) | 155% | 0 |
| 6 | 640×360, 427×240 | 9–20 | 29% | 0 |

The made-up camera is a test pattern, so video used well under its caps (about 0.6 Mb/s at 1080p); a real camera
will reach them. What a member uploads at most, all copies together: 12 Mb/s one to one, 8 Mb/s with two to four
others, 5 Mb/s with five, plus 0.51 Mb/s of sound a peer. A phone encodes in hardware, so its CPU is far below these
software numbers, but it has only a few hardware encoders: past four or five people, a server that forwards one
upload to everyone (an SFU) is the way to keep 1080p.
