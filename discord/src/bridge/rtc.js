// One WebRTC connection to one Uplink member, with werift (WebRTC written in TypeScript: no native code). Sound only:
// the member's Opus packets come out of onAudio, and the bridge's mix for them goes in through send(). A picture the
// app offers is turned down in the answer (port 0), which the app handles as any refused section.
//
// The same signalling as lib/voice/rtc.dart: the newcomer offers, the other answers; candidates as {candidate, sdpMid,
// sdpMLineIndex}, held until the other side's description is in.
import { createRequire } from 'node:module';
import { highestOpus } from './protocol.js';

const require = createRequire(import.meta.url);
const werift = require('werift');

/** The STUN servers the bridge learns its public address from. */
export const DEFAULT_ICE = [{ urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun1.l.google.com:19302' }];

/**
 * The factory GhostSpace calls for each member: (id, { onCandidate, onAudio, onState }) -> peer.
 * portRange: [min, max] for the UDP ports ICE uses (so a firewall can let exactly those in), or undefined.
 */
export function weriftPeers({ iceServers = DEFAULT_ICE, portRange } = {}) {
  return (id, { onCandidate, onAudio, onState = () => {} }) => {
    const pc = new werift.RTCPeerConnection({
      iceServers,
      ...(portRange ? { icePortRange: portRange } : {}),
      codecs: {
        audio: [werift.useOPUS({ parameters: 'minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1' })],
        video: [],
      },
    });
    const track = new werift.MediaStreamTrack({ kind: 'audio' });
    // early: candidates that came before the other side's description. seq and ts: the RTP sequence number and
    // timestamp of the packets sent, begun at random as RTP asks.
    const early = [];
    let described = false;
    let seq = Math.floor(Math.random() * 65536);
    let ts = Math.floor(Math.random() * 2 ** 32);
    let closed = false;

    pc.onicecandidate = (e) => {
      const c = e.candidate;
      if (!c) return;
      const j = typeof c.toJSON === 'function' ? c.toJSON() : c;
      if (j.candidate) onCandidate({ candidate: j.candidate, sdpMid: j.sdpMid ?? null, sdpMLineIndex: j.sdpMLineIndex ?? 0 });
    };
    pc.ontrack = (e) => {
      if (e.track.kind !== 'audio') return;
      e.track.onReceiveRtp.subscribe((rtp) => {
        if (rtp?.payload?.length) onAudio(rtp.payload);
      });
    };
    pc.onconnectionstatechange = () => onState(pc.connectionState);

    /** The other side's description is in: the candidates held for it are added now. */
    async function settled() {
      described = true;
      for (const c of early.splice(0)) await pc.addIceCandidate(c).catch(() => {});
    }

    return {
      async makeOffer() {
        pc.addTransceiver(track, { direction: 'sendrecv' });
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        return highestOpus(pc.localDescription.sdp);
      },
      async takeOffer(sdp) {
        await pc.setRemoteDescription({ type: 'offer', sdp });
        await settled();
        for (const t of pc.getTransceivers()) {
          if (t.kind !== 'audio') continue;
          await t.sender.replaceTrack(track);
          t.setDirection('sendrecv');
        }
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        return highestOpus(pc.localDescription.sdp);
      },
      async takeAnswer(sdp) {
        await pc.setRemoteDescription({ type: 'answer', sdp });
        await settled();
      },
      async addCandidate(c) {
        if (!c || typeof c.candidate !== 'string') return;
        const cand = { candidate: c.candidate, sdpMid: c.sdpMid ?? undefined, sdpMLineIndex: c.sdpMLineIndex ?? undefined };
        if (!described) early.push(cand);
        else await pc.addIceCandidate(cand).catch(() => {});
      },
      /** One Opus packet (20 ms) of the bridge's mix for this member. */
      send(opus) {
        if (closed) return;
        const header = new werift.RtpHeader({ payloadType: 111, sequenceNumber: seq, timestamp: ts, marker: false });
        // 960 samples (20 ms at 48 kHz) a packet; both counters wrap round.
        seq = (seq + 1) & 0xffff;
        ts = (ts + 960) >>> 0;
        track.writeRtp(new werift.RtpPacket(header, Buffer.from(opus)));
      },
      get state() {
        return pc.connectionState;
      },
      async close() {
        if (closed) return;
        closed = true;
        try {
          track.stop?.();
        } catch {}
        await pc.close().catch(() => {});
      },
    };
  };
}
