// Fixed examples of the desktop link's sealing (docs/desktop.md), made with Node's own cryptography so that neither
// the phone's Kotlin (DeskCrypto.kt) nor the Mac's Dart (lib/desktop/link/crypto.dart) is checked against itself.
// Both test suites read what this writes: `node tool/desk_vectors.mjs > test/desk_vectors.json`.
import { createECDH, createHmac, createCipheriv } from 'node:crypto';

const hex = (b) => Buffer.from(b).toString('hex');
const b64 = (b) => Buffer.from(b).toString('base64');
const hmac = (key, data) => createHmac('sha256', key).update(data).digest();
/** HKDF-SHA256 with one block of output, as E2eCrypto.conversationKey makes a key. */
const hkdf = (salt, ikm, info) => hmac(hmac(salt, ikm), Buffer.concat([Buffer.from(info), Buffer.from([1])]));
/** A value made from a key that is already uniform: the pairing's id, its relay channel, its code. */
const derive = (key, label) => hmac(key, Buffer.concat([Buffer.from('ghost-desk ' + label), Buffer.from([1])]));
/** Two byte strings joined smaller first, so both ends make the same salt whichever key is theirs. */
const ordered = (a, b) => (Buffer.compare(a, b) <= 0 ? Buffer.concat([a, b]) : Buffer.concat([b, a]));

/** A P-256 key pair from a fixed private key: the ECDH object and the public key, compressed. */
function pair(privHex) {
  const e = createECDH('prime256v1');
  e.setPrivateKey(Buffer.from(privHex, 'hex'));
  return { e, pub: e.getPublicKey(null, 'compressed') };
}

const input = {
  deskPrivate: '1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020101',
  phonePrivate: '2122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40',
  secret: 'a0a1a2a3a4a5a6a7a8a9aaabacadaeaf',
  deskEphemeral: '4142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f60',
  phoneEphemeral: '6162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f01',
  deskNonce: 'd0d1d2d3d4d5d6d7d8d9dadbdcdddedf',
  phoneNonce: 'e0e1e2e3e4e5e6e7e8e9eaebecedeeef',
};

// The pairing: the two long-lived keys agree, and the key of the pair is made from that and the offer's secret.
const desk = pair(input.deskPrivate);
const phone = pair(input.phonePrivate);
const secret = Buffer.from(input.secret, 'hex');
const shared = desk.e.computeSecret(phone.pub);
const pairKey = hkdf(ordered(phone.pub, desk.pub), Buffer.concat([shared, secret]), 'ghost-messaging desktop v1');

const code = String(derive(pairKey, 'code').readUInt32BE(0) % 1000000).padStart(6, '0');
/** A value made from the offer's secret alone, which both ends hold before they have each other's key. */
const fromSecret = (label) => hkdf(Buffer.from('ghost-desk pairing'), secret, label);

// A session: two one-time keys agree, and with the pair's key and both nonces give a key for each direction.
const de = pair(input.deskEphemeral);
const pe = pair(input.phoneEphemeral);
const ee = de.e.computeSecret(pe.pub);
const prk = hmac(Buffer.concat([Buffer.from(input.deskNonce, 'hex'), Buffer.from(input.phoneNonce, 'hex')]), Buffer.concat([pairKey, ee]));
const expand = (label) => hmac(prk, Buffer.concat([Buffer.from(label), Buffer.from([1])]));
const deskKey = expand('d2p');
const phoneKey = expand('p2d');

/** One frame sealed with AES-256-GCM: the nonce is the frame's counter in its last eight bytes; the tag follows. */
function seal(key, counter, text) {
  const nonce = Buffer.alloc(12);
  nonce.writeBigUInt64BE(BigInt(counter), 4);
  const c = createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(Buffer.from('ghost-desk-v1'));
  return Buffer.concat([c.update(Buffer.from(text, 'utf8')), c.final(), c.getAuthTag()]);
}

const offer = { k: b64(desk.pub), s: b64(secret), n: "Matt's MacBook", m: 'both', r: 'wss://ghost-sms.com/relay' };
const frames = [
  { from: 'desk', counter: 0, text: '{"t":"req","id":1,"m":"conversations"}' },
  { from: 'desk', counter: 1, text: '{"t":"req","id":2,"m":"send","a":{"key":"k1","addresses":["+15550100"],"body":"On my way 👻"}}' },
  { from: 'phone', counter: 0, text: '{"t":"res","id":1,"ok":true,"r":[]}' },
  { from: 'phone', counter: 1, text: '{"t":"ev","m":"changed","a":{"thread":42}}' },
].map((f) => ({ ...f, sealed: hex(seal(f.from === 'desk' ? deskKey : phoneKey, f.counter, f.text)) }));

console.log(JSON.stringify({
  note: 'Made by tool/desk_vectors.mjs with Node. Do not edit by hand.',
  input,
  deskPublic: hex(desk.pub),
  phonePublic: hex(phone.pub),
  pairKey: hex(pairKey),
  id: hex(derive(pairKey, 'id').subarray(0, 8)),
  relayChannel: hex(derive(pairKey, 'relay channel').subarray(0, 16)),
  relayToken: hex(derive(pairKey, 'relay token')),
  code,
  pairingId: hex(fromSecret('id').subarray(0, 8)),
  pairingChannel: hex(fromSecret('relay channel').subarray(0, 16)),
  pairingToken: hex(fromSecret('relay token')),
  deskEphemeralPublic: hex(de.pub),
  phoneEphemeralPublic: hex(pe.pub),
  deskKey: hex(deskKey),
  phoneKey: hex(phoneKey),
  offer,
  offerText: 'GHOSTPAIR1:' + Buffer.from(JSON.stringify(offer), 'utf8').toString('base64url'),
  // The same, as the link the Mac's QR code holds, which a phone's own camera can open in the app.
  offerLink: 'ghostmsg://pair/' + Buffer.from(JSON.stringify(offer), 'utf8').toString('base64url'),
  frames,
}, null, 2));
