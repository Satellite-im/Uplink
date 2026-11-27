#!/usr/bin/env node
/**
 * A client for Uplink's API (lib/api in the app; Settings › API, in developer mode). Matt, 2026-11-17: "build
 * an entire API that we can use to interact with every aspect of the app frontend and backend".
 *
 * On the phone, over USB (Settings › API › Serve the API, then `adb forward tcp:8765 tcp:8765`):
 *   node tool/ghost-api.mjs --token <token> app.info
 *   node tool/ghost-api.mjs --local http://192.168.1.20:8765 --token <token> conversations.list '{"limit": 5}'
 *
 * From anywhere, through the relay (Settings › API › Through the relay, then "Copy the connection string"):
 *   node tool/ghost-api.mjs --remote ghostapi1:<64 hex> app.info
 *   GHOST_API=ghostapi1:<64 hex> node tool/ghost-api.mjs networks.chats '{"network": "telegram"}'
 *
 * With no method it lists them all; `--doc <method>` shows one's documentation. The answer is printed as JSON; a
 * refusal goes to stderr and the exit status is 1.
 *
 * Through the relay, every request and answer is sealed with AES-256-GCM under a key made from the connection string's
 * secret (HKDF-SHA256, as lib/api/seal.dart makes it), and the relay channel and its token come from it too: the relay
 * passes the frames without being able to read them.
 */
import { createCipheriv, createDecipheriv, createHmac, randomBytes } from 'node:crypto';

const args = process.argv.slice(2);
// An option's value, taken out of the arguments so that what is left is the method and its parameters.
const flag = (name) => {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const doc = flag('--doc');
const token = flag('--token') ?? process.env.GHOST_API_TOKEN;
const remote = flag('--remote') ?? (process.env.GHOST_API?.startsWith('ghostapi1:') ? process.env.GHOST_API : undefined);
const local = flag('--local') ?? 'http://127.0.0.1:8765';
const relay = flag('--relay') ?? 'wss://gogho.st/relay';
const [method, paramsText] = args;

function fail(words) {
  console.error(words);
  process.exit(1);
}

let params = {};
if (paramsText) {
  try {
    params = JSON.parse(paramsText);
  } catch {
    fail('The parameters should be a JSON object, like \'{"limit": 5}\'.');
  }
}

// --- the remote link's keys, as lib/api/seal.dart makes them ---------------------------------------------------------
const hmac = (key, data) => createHmac('sha256', key).update(data).digest();
const hkdf = (salt, ikm, info) => hmac(hmac(salt, ikm), Buffer.concat([Buffer.from(info), Buffer.from([1])]));
// The relay channel, the token that opens it and the sealing key, all from the connection string's secret.
function keysOf(connection) {
  const m = /^ghostapi1:([0-9a-f]{64})$/.exec(connection.trim());
  if (!m) fail('That is not a connection string: it starts ghostapi1: and has 64 hex digits (Settings › API).');
  const secret = Buffer.from(m[1], 'hex');
  const salt = Buffer.from('ghost-api v1');
  return {
    channel: hkdf(salt, secret, 'relay channel').subarray(0, 16).toString('hex'),
    token: hkdf(salt, secret, 'relay token').toString('hex'),
    key: hkdf(salt, secret, 'seal key'),
  };
}
const aad = Buffer.from('ghost-api-v1');
// A sealed frame is a random 12-byte nonce, the ciphertext, then the 16-byte tag.
function seal(key, clear) {
  const nonce = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(aad);
  return Buffer.concat([nonce, c.update(clear), c.final(), c.getAuthTag()]);
}
// The clear bytes of a sealed frame, or null where it is too short or was not sealed with this key.
function open(key, sealed) {
  const b = Buffer.from(sealed);
  if (b.length < 28) return null;
  try {
    const d = createDecipheriv('aes-256-gcm', key, b.subarray(0, 12));
    d.setAAD(aad);
    d.setAuthTag(b.subarray(b.length - 16));
    return Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()]);
  } catch {
    return null;
  }
}

// --- calling ---------------------------------------------------------------------------------------------------------
// Straight to the app's own server: one POST a call, with the token as a bearer.
async function callLocal(name, p) {
  if (!token) fail('The token is needed: --token <token> (Settings › API › Copy the token), or GHOST_API_TOKEN.');
  let r;
  try {
    r = await fetch(`${local.replace(/\/$/, '')}/api/${encodeURIComponent(name)}`, {
      method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify(p),
    });
  } catch (e) {
    fail(`Couldn't reach ${local}: ${e.cause?.code ?? e.message}. Is the API served (Settings › API) and the port forwarded (adb forward tcp:8765 tcp:8765)?`);
  }
  return r.json();
}

// Through the relay: joins the channel as the desk side, waits for the relay to say the phone is there, sends the
// sealed request, and takes the first sealed answer that carries the request's id.
function callRemote(name, p) {
  const k = keysOf(remote);
  return new Promise((resolve) => {
    const ws = new WebSocket(`${relay}/${k.channel}`);
    ws.binaryType = 'arraybuffer';
    const id = Math.floor(Math.random() * 1e9);
    let sent = false;
    // Twenty seconds for the phone to be there, then a minute for its answer.
    let give = setTimeout(() => {
      ws.close();
      fail('The phone is not on the relay: is "Through the relay" on in Settings › API, and the app running?');
    }, 20000);
    const send = () => {
      if (sent) return;
      sent = true;
      clearTimeout(give);
      give = setTimeout(() => {
        ws.close();
        fail('The phone did not answer in 60 s.');
      }, 60000);
      ws.send(seal(k.key, Buffer.from(JSON.stringify({ id, method: name, params: p }))));
    };
    ws.onopen = () => ws.send(JSON.stringify({ auth: k.token, role: 'desk' }));
    ws.onmessage = (e) => {
      if (typeof e.data === 'string') {
        const m = JSON.parse(e.data);
        if (m.ok === false) fail(`The relay refused the link: ${m.err ?? 'no reason given'}`);
        if (m.peer === true) send();
        if (m.dropped) fail('The phone left the relay before the request reached it.');
        return;
      }
      const clear = open(k.key, e.data);
      if (!clear) return;
      const answer = JSON.parse(clear.toString('utf8'));
      if (answer.id !== id) return;
      clearTimeout(give);
      ws.close();
      resolve(answer);
    };
    ws.onerror = () => fail(`Couldn't reach the relay at ${relay}.`);
  });
}

const call = (name, p) => (remote ? callRemote(name, p) : callLocal(name, p));

// With no method, or with --doc, the call is api.describe, and what is printed is made from its list of methods.
const answer = await call(method && !doc ? method : 'api.describe', method && !doc ? params : {});
if (!answer.ok) fail(`${answer.error?.code}: ${answer.error?.message}`);
if (method && !doc) {
  console.log(JSON.stringify(answer.result, null, 2));
} else {
  const methods = answer.result.methods;
  if (doc) {
    const m = methods.find((x) => x.name === doc);
    if (!m) fail(`No method called ${doc}.`);
    console.log(`${m.name}${m.danger ? '  (changes or removes something)' : ''}\n  ${m.summary}\n`);
    for (const p of m.params) console.log(`  ${p.name}${p.required ? '' : '?'}: ${p.type}  ${p.doc}${p.example !== undefined ? `  e.g. ${JSON.stringify(p.example)}` : ''}`);
    console.log(`\n  answers: ${m.returns}`);
    if (m.example) console.log(`  try: node tool/ghost-api.mjs ${m.name} '${JSON.stringify(m.example)}'`);
  } else {
    let group = '';
    for (const m of methods) {
      if (m.group !== group) console.log(`\n${(group = m.group)}`);
      console.log(`  ${m.name.padEnd(28)} ${m.danger ? '⚠ ' : ''}${m.summary}`);
    }
    console.log(`\n${methods.length} methods. --doc <method> for one in full.`);
  }
}
