// What crosses the bridge, worked out without discord.js: who is in the Discord channel as the space is told
// ({t:'dc', people}), the bot's nickname, and chat messages each way (with nothing echoed back where it came from).
import { avatarUrl, memberName } from '../state.js';

// A discord.js Collection (a Map) or a plain array, read alike: its values, and one of them by id.
const each = (collection) => (collection == null ? [] : typeof collection.values === 'function' ? [...collection.values()] : [...collection]);
const lookup = (collection, id) => (collection == null ? undefined : typeof collection.get === 'function' ? collection.get(id) : each(collection).find((x) => x.id === id));

/**
 * Everyone in voice channel [channelId] but the bot itself, for the space: [{ id, name, avatar, speaking, muted,
 * deafened, bot }], by name. guild is shaped as state.js reads it; speaking: a Set of user ids talking now.
 */
export function dcPeople(guild, channelId, { botId, speaking = new Set() } = {}) {
  const out = [];
  for (const vs of each(guild.voiceStates?.cache)) {
    const id = String(vs.id);
    if (String(vs.channelId) !== String(channelId) || id === String(botId)) continue;
    const member = vs.member ?? lookup(guild.members?.cache, id) ?? null;
    out.push({
      id,
      name: memberName(member),
      avatar: avatarUrl(String(guild.id), member, id),
      speaking: speaking.has(id),
      muted: Boolean(vs.selfMute || vs.serverMute),
      deafened: Boolean(vs.selfDeaf || vs.serverDeaf),
      bot: Boolean(member?.user?.bot),
    });
  }
  return out.sort((a, b) => a.name.localeCompare(b.name, 'en', { sensitivity: 'base' }) || (a.id < b.id ? -1 : 1));
}

const NICK_MAX = 32; // Discord's limit for a nickname

/** The bot's nickname for the Uplink people in its calls on a server: one by name, else how many; null for none. */
export function nicknameFor(names) {
  if (!names.length) return null;
  if (names.length === 1) {
    const name = String(names[0] || '').trim() || 'someone';
    const text = `Uplink · ${name}`;
    return text.length > NICK_MAX ? `${text.slice(0, NICK_MAX - 1)}…` : text;
  }
  return `Uplink · ${names.length} people`;
}

// The longest message passed on each way, in characters: 2000 is Discord's own limit for a message.
const GHOST_MAX = 4000;
const DISCORD_MAX = 2000;

/**
 * A Discord message for the space's chat, or null when it is not to be passed on: the bot's own, one sent through the
 * bridge's webhook (or any webhook of this bot's application), a system message, or one with nothing in it.
 * message: { author: { id, bot, username, globalName }, member?: { nickname }, webhookId, applicationId, system,
 *            content, attachments: [{ url }], stickers?: [{ name }] }.
 */
export function discordToGhost(message, { botId, webhookIds = new Set(), appId = null }) {
  if (!message || message.system) return null;
  if (String(message.author?.id) === String(botId)) return null;
  if (message.webhookId && (webhookIds.has(String(message.webhookId)) || (appId && String(message.applicationId) === String(appId)))) return null;
  const parts = [];
  const content = String(message.content ?? '').trim();
  if (content) parts.push(content);
  for (const a of each(message.attachments)) if (a?.url) parts.push(String(a.url));
  for (const s of each(message.stickers)) if (s?.name) parts.push(`[sticker: ${s.name}]`);
  const text = parts.join('\n').slice(0, GHOST_MAX);
  if (!text) return null;
  const name = message.member?.nickname || message.author?.globalName || message.author?.username || 'Discord';
  return { name: String(name).slice(0, 100), text };
}

/** A webhook's username: 1 to 80 characters, and Discord refuses any with "discord" or "clyde" in them. */
export function webhookName(name) {
  const clean = String(name ?? '').replace(/discord/gi, 'D1scord').replace(/clyde/gi, 'Clyd3').replace(/\s+/g, ' ').trim().slice(0, 80);
  return clean || 'Uplink';
}

/** Discord's allowed_mentions for "nobody": an @everyone or @name typed in Uplink shows as text and pings no one. */
const noMentions = { parse: [] };

/** An Uplink chat message as the webhook posts it: under the sender's name, pinging nobody. */
export function ghostToWebhook({ name, text }) {
  return { username: webhookName(name), content: String(text).slice(0, DISCORD_MAX), allowedMentions: noMentions };
}

/** Without Manage Webhooks: posted by the bot itself, the sender's name in bold. */
export function ghostToBotMessage({ name, text }) {
  const who = String(name || 'Uplink').replace(/([\\*_~`|>])/g, '\\$1').slice(0, 80);
  const body = `**${who}:** ${String(text)}`;
  return { content: body.slice(0, DISCORD_MAX), allowedMentions: noMentions };
}
