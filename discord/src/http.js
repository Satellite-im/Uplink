// The HTTP side: what the app asks of the bot. No discord.js here: the bot hands in `guilds`, which finds a server by
// id ({ status: 'ok', guild } | { status: 'gone' } | { status: 'starting' }), and everything else is this folder's.
//
//   POST /discord/claim   {"code":"ABC123"} -> {token, guild}       (404 unknown code, 429 too many tries)
//   GET  /discord/state?token=<token>       -> {guild, channels, at} (401 not linked, 410 gone)
//   POST /discord/voice/join {"token","channel"} -> {seed, name, guild, channel, bridge}
//                                           (401 not linked, 404 unknown channel, 410 gone, 403 no permission)
//   GET  /discord/invite                    -> {url}
//   GET  /discord/                          -> {ok: true}            (the deploy's health check)
//
// Caddy passes https://ghost-sms.com/discord/* on with the prefix kept; the same routes answer without it.
import { buildState, guildInfo } from './state.js';
import { RateLimit } from './ratelimit.js';

/** The longest request body read, in bytes: a code or a token and a channel id need far less. */
export const MAX_BODY = 4 * 1024;

/** The bot's permissions, by Discord's names for them (the bits are Discord's: discord.js's PermissionFlagsBits). */
export const PERMISSIONS = {
  ViewChannel: 1n << 10n,
  SendMessages: 1n << 11n,
  ReadMessageHistory: 1n << 16n,
  Connect: 1n << 20n,
  Speak: 1n << 21n,
  UseVAD: 1n << 25n,
  ChangeNickname: 1n << 26n,
  ManageWebhooks: 1n << 29n,
};
/** What the invite asks for: everything the bridge uses, nothing else. */
export const INVITE_PERMISSIONS = Object.values(PERMISSIONS).reduce((a, b) => a | b, 0n).toString();
/** The link that adds the bot, with its commands, to a server. */
export const inviteUrl = (appId) => `https://discord.com/oauth2/authorize?client_id=${appId}&scope=bot%20applications.commands&permissions=${INVITE_PERMISSIONS}`;
const SNOWFLAKE = /^\d{15,22}$/;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Access-Control-Max-Age': '600',
};

/** One answer: JSON (or nothing, for a null body), open to any origin and never cached. */
function send(res, status, body, extra = {}) {
  const text = body === null ? '' : JSON.stringify(body);
  res.writeHead(status, {
    ...CORS,
    ...(body === null ? {} : { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(text) }),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extra,
  });
  res.end(text);
}

/** The body, at most MAX_BODY bytes; null when it was longer (the rest is not read). */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (Number.isFinite(declared) && declared > MAX_BODY) return resolve(null);
    const chunks = [];
    let size = 0;
    let done = false;
    req.on('data', (chunk) => {
      if (done) return;
      size += chunk.length;
      if (size > MAX_BODY) {
        done = true;
        resolve(null);
        req.pause();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => { if (!done) { done = true; resolve(Buffer.concat(chunks)); } });
    req.on('error', (e) => { if (!done) { done = true; reject(e); } });
  });
}

/** The asker's address. Behind Caddy every request comes from loopback, and Caddy's X-Forwarded-For ends with the
 * address it was itself connected from (it does not trust one a client sent), so the last entry is the asker. */
export function clientIp(req) {
  const remote = req.socket?.remoteAddress ?? '';
  const loopback = remote === '127.0.0.1' || remote === '::1' || remote === '::ffff:127.0.0.1';
  const forwarded = req.headers['x-forwarded-for'];
  if (loopback && typeof forwarded === 'string' && forwarded.trim()) {
    const parts = forwarded.split(',').map((s) => s.trim()).filter(Boolean);
    if (parts.length) return parts[parts.length - 1];
  }
  return remote || 'unknown';
}

/**
 * The request handler. codes: Codes; store: TokenStore; guilds: { lookup(id, { members }) }; appId: for /invite.
 * bridge (optional, null while the bridge is off): { channel(guild, channelId) -> { name, missing, full } | null,
 * ensure(guildId, channelId) -> { seed, bridge } (throws { code: 'busy' | 'voice' | 'hub' }), bridged(guildId) -> Set }.
 * log(message) gets counts and outcomes only, never a token, a code, a seed or a name.
 */
export function createHandler({ codes, store, guilds, bridge = null, appId = null, now = Date.now, log = () => {}, perIp = 10, overall = 300, joinsPerIp = 30 }) {
  // A minute's allowance each: claims from one address, claims from everyone, joins from one address.
  const ipLimit = new RateLimit({ limit: perIp, now });
  const allLimit = new RateLimit({ limit: overall, now });
  const joinLimit = new RateLimit({ limit: joinsPerIp, now });

  /** The body as a JSON object; null when it was too long or not one, and the 413 or 400 is already sent. */
  async function readJson(req, res) {
    const raw = await readBody(req);
    if (raw === null) {
      send(res, 413, { error: 'too large' }, { Connection: 'close' });
      return null;
    }
    try {
      const body = JSON.parse(raw.toString('utf8'));
      if (body && typeof body === 'object') return body;
    } catch {}
    send(res, 400, { error: 'bad json' });
    return null;
  }

  /** POST /voice/join: the bridge is brought into the channel and its space, and the app gets the space's seed to
   * join with. */
  async function voiceJoin(req, res) {
    const ip = clientIp(req);
    if (!joinLimit.hit(ip)) return send(res, 429, { error: 'slow down' }, { 'Retry-After': String(joinLimit.retryAfter(ip)) });
    const body = await readJson(req, res);
    if (!body) return;
    const guildId = store.guildOf(typeof body.token === 'string' ? body.token : '');
    if (!guildId) return send(res, 401, { error: 'not linked' });
    const channelId = typeof body.channel === 'string' ? body.channel : '';
    if (!SNOWFLAKE.test(channelId)) return send(res, 404, { error: 'unknown channel' });
    const found = await guilds.lookup(guildId, { members: false });
    if (found.status === 'gone') return send(res, 410, { error: 'gone' });
    if (found.status !== 'ok' || !bridge) return send(res, 503, { error: 'starting' }, { 'Retry-After': '5' });
    const info = bridge.channel(found.guild, channelId);
    if (!info) return send(res, 404, { error: 'unknown channel' });
    if (info.missing.length) {
      log(`voice/join: guild ${guildId} lacks ${info.missing.length} permissions`);
      return send(res, 403, { error: 'no permission', missing: info.missing });
    }
    if (info.full) return send(res, 409, { error: 'full' });
    let joined;
    try {
      joined = await bridge.ensure(guildId, channelId);
    } catch (e) {
      log(`voice/join: guild ${guildId} channel ${channelId} failed (${e?.code ?? 'error'})`);
      if (e?.code === 'busy') return send(res, 409, { error: 'busy' });
      if (e?.code === 'voice') return send(res, 502, { error: 'voice failed' });
      return send(res, 503, { error: 'relay unreachable' }, { 'Retry-After': '5' });
    }
    log(`voice/join: guild ${guildId} channel ${channelId} bridged`);
    return send(res, 200, { seed: joined.seed, name: info.name, guild: guildId, channel: channelId, bridge: joined.bridge });
  }

  /** POST /claim: a link code traded, once, for a token that reads its server. A wrong guess still uses up some of
   * the address's allowance. */
  async function claim(req, res) {
    const ip = clientIp(req);
    if (!ipLimit.hit(ip)) return send(res, 429, { error: 'slow down' }, { 'Retry-After': String(ipLimit.retryAfter(ip)) });
    if (!allLimit.hit('*')) return send(res, 429, { error: 'slow down' }, { 'Retry-After': String(allLimit.retryAfter('*')) });
    const raw = await readBody(req);
    if (raw === null) return send(res, 413, { error: 'too large' }, { Connection: 'close' });
    let body;
    try {
      body = JSON.parse(raw.toString('utf8'));
    } catch {
      return send(res, 400, { error: 'bad json' });
    }
    const guildId = codes.take(body?.code);
    if (!guildId) {
      log('claim: unknown code');
      return send(res, 404, { error: 'unknown code' });
    }
    const found = await guilds.lookup(guildId, { members: false });
    if (found.status === 'gone') return send(res, 410, { error: 'gone' });
    if (found.status !== 'ok') return send(res, 503, { error: 'starting' }, { 'Retry-After': '5' });
    const token = store.add(guildId);
    log(`claim: linked guild ${guildId} (${store.countGuild(guildId)} links)`);
    return send(res, 200, { token, guild: guildInfo(found.guild) });
  }

  /** GET /state: the token's server, its voice channels and who is in them now. */
  async function state(req, res, url) {
    const guildId = store.guildOf(url.searchParams.get('token') ?? '');
    if (!guildId) return send(res, 401, { error: 'not linked' });
    const found = await guilds.lookup(guildId, { members: true });
    if (found.status === 'gone') return send(res, 410, { error: 'gone' });
    if (found.status !== 'ok') return send(res, 503, { error: 'starting' }, { 'Retry-After': '5' });
    return send(res, 200, buildState(found.guild, now(), { bridged: bridge?.bridged(guildId) }));
  }

  return async function handle(req, res) {
    try {
      const url = new URL(req.url ?? '/', 'http://localhost');
      // With Caddy's /discord prefix or without it, and with or without a slash at the end.
      let path = url.pathname;
      if (path === '/discord' || path.startsWith('/discord/')) path = path.slice('/discord'.length) || '/';
      if (path.length > 1 && path.endsWith('/')) path = path.slice(0, -1);
      const method = req.method ?? 'GET';

      if (method === 'OPTIONS') return send(res, 204, null);
      if (path === '/claim') return method === 'POST' ? await claim(req, res) : send(res, 405, { error: 'method' }, { Allow: 'POST, OPTIONS' });
      if (path === '/state') return method === 'GET' ? await state(req, res, url) : send(res, 405, { error: 'method' }, { Allow: 'GET, OPTIONS' });
      if (path === '/voice/join') return method === 'POST' ? await voiceJoin(req, res) : send(res, 405, { error: 'method' }, { Allow: 'POST, OPTIONS' });
      if (path === '/invite') {
        if (method !== 'GET') return send(res, 405, { error: 'method' }, { Allow: 'GET, OPTIONS' });
        return appId ? send(res, 200, { url: inviteUrl(appId) }) : send(res, 503, { error: 'starting' });
      }
      if (path === '/' && method === 'GET') return send(res, 200, { ok: true, service: 'ghost-discord' });
      return send(res, 404, { error: 'not found' });
    } catch (e) {
      log(`error: ${e?.message ?? e}`);
      if (!res.headersSent) send(res, 500, { error: 'server' });
      else res.destroy();
    }
  };
}
