// Plain objects shaped as the parts of discord.js's Guild that state.js reads.
// Discord's channel type numbers.
export const VOICE = 2, CATEGORY = 4, TEXT = 0, STAGE = 13;

/** A server member: `avatar` is the one set on this server, `userAvatar` their own. */
export function member(id, { nickname = null, globalName = null, username = `user${id}`, avatar = null, userAvatar = null, bot = false } = {}) {
  return { id, nickname, avatar, user: { id, username, globalName, avatar: userAvatar, bot } };
}

/** Someone in a voice channel (null: in none), unmuted and with nothing on unless `extra` says so. */
export function voiceState(id, channelId, extra = {}) {
  return { id, channelId, selfMute: false, serverMute: false, selfDeaf: false, serverDeaf: false, selfVideo: false, streaming: false, ...extra };
}

/** A server, its lists turned into the Maps discord.js keeps them in. */
export function guild({ id = '100000000000000001', name = 'Test server', icon = null, channels = [], voiceStates = [], members = [] } = {}) {
  return {
    id,
    name,
    icon,
    channels: { cache: new Map(channels.map((c) => [c.id, c])) },
    voiceStates: { cache: new Map(voiceStates.map((v) => [v.id, v])) },
    members: { cache: new Map(members.map((m) => [m.id, m])) },
  };
}
