// The Discord half of the bridge (bridge/bridge.js's `discord`), with discord.js and @discordjs/voice: joining a voice
// channel (end-to-end encrypted with Discord's DAVE protocol through @snazzah/davey, which @discordjs/voice brings),
// each speaker's Opus packets out of the receiver, the Uplink mix played in, the people in the channel, the bot's
// nickname, and Uplink's chat posted through a webhook in the channel.
import { EndBehaviorType, VoiceConnectionStatus, entersState, joinVoiceChannel } from '@discordjs/voice';
import { ChannelType, PermissionFlagsBits, WebhookClient } from 'discord.js';
import { dcPeople, ghostToBotMessage, ghostToWebhook } from './bridge/mapping.js';

/** How long a voice connection has to become ready, joining or rejoining. */
const READY_MS = 20_000;
/** Discord's error code for a webhook that is no longer there. */
const UNKNOWN_WEBHOOK = 10015;

/** The permissions a bridged channel needs, by the names /discord/voice/join answers with. */
export const NEEDED = [
  ['View Channel', PermissionFlagsBits.ViewChannel],
  ['Connect', PermissionFlagsBits.Connect],
  ['Speak', PermissionFlagsBits.Speak],
];

/** What /discord/voice/join needs to know of a channel: null when it is not a voice channel of this server. */
export function channelInfo(client, guild, channelId) {
  const channel = guild.channels.cache.get(channelId);
  if (!channel || channel.type !== ChannelType.GuildVoice) return null;
  const me = guild.members.me;
  const perms = me ? channel.permissionsFor(me) : null;
  const missing = NEEDED.filter(([, flag]) => !perms?.has(flag)).map(([name]) => name);
  // Full, and the bot may not move members (which lets it in anyway).
  const full = Boolean(channel.full) && !perms?.has(PermissionFlagsBits.MoveMembers) && !channel.members.has(client.user.id);
  return { name: channel.name, missing, full };
}

/** The `discord` object bridge.js works through, for this gateway client. store: the BridgeStore, where each
 * channel's webhook is kept. */
export function discordSide({ client, store, log }) {
  const hooks = new Map(); // "guild:channel" -> WebhookClient

  /** The channel's webhook, made and kept the first time; null when the bot may not manage webhooks there. */
  async function webhookFor(guild, channel) {
    const key = `${guild.id}:${channel.id}`;
    if (hooks.has(key)) return hooks.get(key);
    let saved = store.webhook(guild.id, channel.id);
    if (!saved) {
      const perms = guild.members.me ? channel.permissionsFor(guild.members.me) : null;
      if (!perms?.has(PermissionFlagsBits.ManageWebhooks)) return null;
      const made = await channel.createWebhook({ name: 'Uplink', reason: 'Uplink: messages from the Uplink side of this call' });
      saved = { id: made.id, token: made.token };
      store.setWebhook(guild.id, channel.id, saved);
      log(`webhook made in ${guild.id}/${channel.id}`);
    }
    const hook = new WebhookClient({ id: saved.id, token: saved.token });
    hooks.set(key, hook);
    return hook;
  }

  return {
    async joinVoice(guildId, channelId, on) {
      const guild = client.guilds.cache.get(guildId);
      if (!guild) throw new Error('server gone');
      const conn = joinVoiceChannel({ guildId, channelId, adapterCreator: guild.voiceAdapterCreator, selfDeaf: false, selfMute: false });
      try {
        await entersState(conn, VoiceConnectionStatus.Ready, READY_MS);
      } catch (e) {
        conn.destroy();
        throw new Error(`voice did not connect: ${e?.message ?? e}`);
      }

      // Each speaker's packets are subscribed to when they first talk; the stream ends after a second of silence and
      // is opened again the next time they do.
      const listening = new Map(); // user id -> receive stream
      const listen = (userId) => {
        if (listening.has(userId) || userId === client.user.id) return;
        const stream = conn.receiver.subscribe(userId, { end: { behavior: EndBehaviorType.AfterSilence, duration: 1000 } });
        listening.set(userId, stream);
        stream.on('data', (packet) => on.opus(userId, packet));
        stream.on('error', () => {});
        stream.once('close', () => { if (listening.get(userId) === stream) listening.delete(userId); });
        stream.once('end', () => { if (listening.get(userId) === stream) listening.delete(userId); });
      };
      const started = (userId) => { listen(userId); on.speaking(userId, true); };
      const ended = (userId) => on.speaking(userId, false);
      conn.receiver.speaking.on('start', started);
      conn.receiver.speaking.on('end', ended);

      // A connection lost any other way than by the bridge's own destroy(): one rejoin, then on.lost(), said once.
      let ours = false; // destroyed by the bridge itself
      let rejoined = false;
      let gaveUp = false;
      const giveUp = (why) => {
        if (gaveUp || ours) return;
        gaveUp = true;
        log(`voice ${guildId}/${channelId}: ${why}`);
        try { conn.destroy(); } catch {}
        on.lost();
      };
      conn.on('stateChange', async (_, next) => {
        if (ours) return;
        if (next.status === VoiceConnectionStatus.Disconnected) {
          // Moved, or Discord changing the voice server: it reconnects by itself within a few seconds.
          try {
            await Promise.race([entersState(conn, VoiceConnectionStatus.Signalling, 5000), entersState(conn, VoiceConnectionStatus.Connecting, 5000)]);
            return;
          } catch {}
          if (rejoined) return giveUp('disconnected again; leaving');
          rejoined = true;
          log(`voice ${guildId}/${channelId}: disconnected; rejoining once`);
          try {
            conn.rejoin();
            await entersState(conn, VoiceConnectionStatus.Ready, READY_MS);
          } catch {
            giveUp('the rejoin failed; leaving');
          }
        } else if (next.status === VoiceConnectionStatus.Destroyed) {
          giveUp('the connection was destroyed');
        }
      });
      conn.on('error', (e) => log(`voice ${guildId}/${channelId}: ${e?.message ?? e}`));

      return {
        play: (opus) => conn.playOpusPacket(opus),
        quiet: () => conn.setSpeaking(false),
        destroy() {
          ours = true;
          conn.receiver.speaking.off('start', started);
          conn.receiver.speaking.off('end', ended);
          for (const s of listening.values()) s.destroy();
          listening.clear();
          try { conn.destroy(); } catch {}
        },
      };
    },

    people(guildId, channelId, speaking) {
      const guild = client.guilds.cache.get(guildId);
      return guild ? dcPeople(guild, channelId, { botId: client.user?.id, speaking }) : [];
    },

    async setNickname(guildId, text) {
      const me = client.guilds.cache.get(guildId)?.members.me;
      if (!me?.permissions.has(PermissionFlagsBits.ChangeNickname)) return;
      await me.setNickname(text, 'Uplink: who is talking from Uplink').catch(() => {});
    },

    /** An Uplink member's message into the channel's chat: through the webhook, under their name, else as the bot. */
    async postText(guildId, channelId, message) {
      const guild = client.guilds.cache.get(guildId);
      const channel = guild?.channels.cache.get(channelId);
      if (!channel) return;
      for (let attempt = 0; attempt < 2; attempt++) {
        const hook = await webhookFor(guild, channel).catch(() => null);
        if (!hook) {
          await channel.send(ghostToBotMessage(message));
          return;
        }
        try {
          await hook.send(ghostToWebhook(message));
          return;
        } catch (e) {
          if (e?.code !== UNKNOWN_WEBHOOK) throw e;
          // Someone deleted it: forget it, and make a new one once.
          hooks.delete(`${guildId}:${channelId}`);
          store.setWebhook(guildId, channelId, null);
        }
      }
    },
  };
}
