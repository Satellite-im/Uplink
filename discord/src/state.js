// The /state answer, built from a guild-like object shaped as discord.js's Guild is (only the fields read here), so
// it can be tested with plain objects and never imports discord.js.
//
//   guild.id, guild.name, guild.icon (hash or null)
//   guild.channels.cache: iterable of { id, name, type, rawPosition, parentId, viewable? }
//   guild.voiceStates.cache: iterable of { id, channelId, member?, selfMute, serverMute, selfDeaf, serverDeaf,
//                                          selfVideo, streaming }
//   guild.members.cache.get(id) -> { id, nickname, avatar, user: { id, username, globalName, avatar, bot } }

/** discord.js's ChannelType values, written out so this file needs nothing of discord.js. */
export const CHANNEL_TYPES = { GuildVoice: 2, GuildCategory: 4, GuildStageVoice: 13 };
const CDN = 'https://cdn.discordapp.com';

// A discord.js Collection (a Map) or a plain array, read alike: its values, one of them by id, a channel's place.
const each = (collection) => (collection == null ? [] : typeof collection.values === 'function' ? [...collection.values()] : [...collection]);
const lookup = (collection, id) => (collection == null ? undefined : typeof collection.get === 'function' ? collection.get(id) : each(collection).find((x) => x.id === id));
const position = (channel) => (Number.isInteger(channel?.rawPosition) ? channel.rawPosition : Number.isInteger(channel?.position) ? channel.position : 0);

/** The server's icon on Discord's CDN, or null where it has none. */
export function iconUrl(guild) {
  return guild.icon ? `${CDN}/icons/${guild.id}/${guild.icon}.png` : null;
}

/** The server as every answer names it: id, name and icon. */
export function guildInfo(guild) {
  return { id: String(guild.id), name: String(guild.name ?? ''), icon: iconUrl(guild) };
}

/** Their nickname on this server, else their display name, else their username. */
export function memberName(member) {
  const user = member?.user;
  return member?.nickname || user?.globalName || user?.username || 'Unknown';
}

/** The server avatar they set here, else their own, else none. */
export function avatarUrl(guildId, member, userId) {
  if (member?.avatar) return `${CDN}/guilds/${guildId}/users/${userId}/avatars/${member.avatar}.png`;
  if (member?.user?.avatar) return `${CDN}/avatars/${userId}/${member.user.avatar}.png`;
  return null;
}

/** Discord's own order: channels outside a category first, then each category in its order; within, by position. */
function sortKey(channel, channels) {
  const parent = channel.parentId ? lookup(channels, channel.parentId) : null;
  return [parent ? 1 : 0, parent ? position(parent) : 0, parent ? String(parent.id) : '', position(channel), String(channel.id)];
}
function compareKeys(a, b) {
  for (let i = 0; i < a.length; i++) {
    if (a[i] < b[i]) return -1;
    if (a[i] > b[i]) return 1;
  }
  return 0;
}
/** Discord ids are numbers too long for a Number: the shorter string is the smaller, then by text. */
const compareIds = (a, b) => (a.length - b.length) || (a < b ? -1 : a > b ? 1 : 0);

// The /state answer: the server, its voice and stage channels the bot can see, in Discord's order, and who is in
// each (by name), with `at`, the time it was built.
/** bridged: the channel ids the bridge is in now (each gets "bridged": true). */
export function buildState(guild, now = Date.now(), { bridged = null } = {}) {
  const channels = guild.channels?.cache;
  const voice = each(channels)
    .filter((c) => (c.type === CHANNEL_TYPES.GuildVoice || c.type === CHANNEL_TYPES.GuildStageVoice) && c.viewable !== false)
    .map((c) => ({ c, key: sortKey(c, channels) }))
    .sort((a, b) => compareKeys(a.key, b.key))
    .map(({ c }) => c);

  const byChannel = new Map();
  for (const vs of each(guild.voiceStates?.cache)) {
    if (!vs.channelId) continue;
    const id = String(vs.id);
    const member = vs.member ?? lookup(guild.members?.cache, id) ?? null;
    const entry = {
      id,
      name: memberName(member),
      avatar: avatarUrl(String(guild.id), member, id),
      muted: Boolean(vs.selfMute || vs.serverMute),
      deafened: Boolean(vs.selfDeaf || vs.serverDeaf),
      video: Boolean(vs.selfVideo),
      streaming: Boolean(vs.streaming),
      bot: Boolean(member?.user?.bot),
    };
    const list = byChannel.get(String(vs.channelId)) ?? [];
    list.push(entry);
    byChannel.set(String(vs.channelId), list);
  }

  return {
    guild: guildInfo(guild),
    channels: voice.map((c, i) => ({
      id: String(c.id),
      name: String(c.name ?? ''),
      kind: c.type === CHANNEL_TYPES.GuildStageVoice ? 'stage' : 'voice',
      position: i,
      members: (byChannel.get(String(c.id)) ?? []).sort((a, b) => a.name.localeCompare(b.name, 'en', { sensitivity: 'base' }) || compareIds(a.id, b.id)),
      ...(bridged?.has(String(c.id)) ? { bridged: true } : {}),
    })),
    at: now,
  };
}

/** Ids of people in voice whose member object is not cached: the bot fetches those before building the state. */
export function missingMembers(guild) {
  return each(guild.voiceStates?.cache)
    .filter((vs) => vs.channelId && !(vs.member ?? lookup(guild.members?.cache, String(vs.id))))
    .map((vs) => String(vs.id));
}
