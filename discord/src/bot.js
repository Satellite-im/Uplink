// Uplink's Discord bot: one gateway connection, the /ghost commands, the HTTP routes in http.js on 127.0.0.1,
// and the bridge (bridge/): when an Uplink user presses a linked server's voice channel, the bot joins that channel and
// the matching Uplink space and carries sound and the channel's chat both ways.
//
// Intents: Guilds and GuildVoiceStates, and for the chat GuildMessages and MessageContent (privileged: switched on in
// the Developer Portal). If Discord refuses MessageContent the bot connects again without the two and carries no
// chat, saying so once in its log.
//
//   DISCORD_TOKEN    the bot's token (required)
//   DISCORD_APP_ID   the application's id (required: the invite link and the commands)
//   PORT             default 18788
//   DISCORD_DATA     where links.json and bridges.json live, default ./data
//   GHOST_HUB        the relay's hub, default ws://127.0.0.1:18787/hub (the relay on the same box)
//   GHOST_BRIDGE     "off" to run as the presence bot only
//   GHOST_RTC_PORTS  optional "min-max": the UDP ports WebRTC uses towards Uplink apps (for a firewall)
import { createServer } from 'node:http';
import { Client, Events, GatewayIntentBits, MessageFlags, PermissionFlagsBits } from 'discord.js';
import { Bridges } from './bridge/bridge.js';
import { Hub, makeIdentity } from './bridge/hub.js';
import { discordToGhost } from './bridge/mapping.js';
import { opusCodec } from './bridge/opus.js';
import { weriftPeers } from './bridge/rtc.js';
import { BridgeStore } from './bridge/store.js';
import { Codes } from './codes.js';
import { COMMAND, answer } from './commands.js';
import { createHandler, inviteUrl } from './http.js';
import { missingMembers } from './state.js';
import { TokenStore } from './store.js';
import { channelInfo, discordSide } from './voice.js';

/** One line to the service's log, with the time. */
const log = (message) => console.log(`${new Date().toISOString()} ${message}`);
/** A setting that is missing or wrong, or a login Discord turned down: said, and the process ends. */
const fail = (message) => { console.error(`x ${message}`); process.exit(1); };

const TOKEN = process.env.DISCORD_TOKEN ?? '';
const APP_ID = process.env.DISCORD_APP_ID ?? '';
const PORT = Number(process.env.PORT || 18788);
const DATA = process.env.DISCORD_DATA || './data';
const HUB = process.env.GHOST_HUB || 'ws://127.0.0.1:18787/hub';
const BRIDGE = (process.env.GHOST_BRIDGE ?? 'on') !== 'off';
const PORTS = /^(\d{4,5})-(\d{4,5})$/.exec(process.env.GHOST_RTC_PORTS ?? '');
if (!TOKEN) fail('DISCORD_TOKEN is not set.');
if (!/^\d{15,22}$/.test(APP_ID)) fail('DISCORD_APP_ID is not set, or is not an application id (digits).');
if (!Number.isInteger(PORT) || PORT < 1 || PORT > 65535) fail('PORT is not a port.');
if (!/^wss?:\/\//.test(HUB)) fail('GHOST_HUB is not a ws:// or wss:// address.');

const codes = new Codes();
const store = TokenStore.open(DATA);
const bridgeStore = BridgeStore.open(DATA);

// textBridge: whether chat is carried (off once Discord refuses the intent). client: the gateway client in use now;
// an older one, given up on, is told apart by not being this one.
const BASE_INTENTS = [GatewayIntentBits.Guilds, GatewayIntentBits.GuildVoiceStates];
const TEXT_INTENTS = [GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent];
let textBridge = BRIDGE;
let client = null;

/** The promise's value, or null if it has not settled within `ms`. */
const withTimeout = (promise, ms) => Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve(null), ms))]);

/** People in voice whose member is not cached (a voice state can come without one): fetched over REST, which needs no
 * privileged intent, a few at a time and never for longer than the request can wait. */
async function fetchMissing(guild) {
  const ids = missingMembers(guild).slice(0, 50);
  for (let i = 0; i < ids.length; i += 10) {
    await withTimeout(Promise.all(ids.slice(i, i + 10).map((id) => guild.members.fetch(id).catch(() => null))), 3000);
  }
}

/** How http.js finds a server: 'ok' with the guild, 'starting' while the gateway (or the guild) is not ready yet, or
 * 'gone' when the bot is no longer in it. With `members`, people in voice the cache lacks are fetched first. */
const guilds = {
  async lookup(id, { members }) {
    if (!client?.isReady()) return { status: 'starting' };
    const guild = client.guilds.cache.get(id);
    if (!guild) return { status: 'gone' };
    if (!guild.available) return { status: 'starting' };
    if (members) await fetchMissing(guild);
    return { status: 'ok', guild };
  },
};

// The bridge: one connection to Uplink's hub under the bridge's own kept key, and the bridges themselves. The Discord
// half is made for whichever client is current (a new one if Discord refused the chat's intent).
const me = makeIdentity(bridgeStore.identityPem(() => makeIdentity().pem));
const hub = new Hub({ url: HUB, me, log });
let sideFor = null;
let sideNow = null;
const side = () => {
  if (sideFor !== client) {
    sideFor = client;
    sideNow = discordSide({ client, store: bridgeStore, log });
  }
  return sideNow;
};
const bridges = new Bridges({
  store: bridgeStore,
  hub,
  peers: weriftPeers({ portRange: PORTS ? [Number(PORTS[1]), Number(PORTS[2])] : undefined }),
  codec: opusCodec,
  discord: {
    joinVoice: (...a) => side().joinVoice(...a),
    people: (...a) => side().people(...a),
    setNickname: (...a) => side().setNickname(...a),
    postText: (...a) => side().postText(...a),
  },
  log,
});
// What http.js may ask of the bridge (POST /join, and /state's "bridged" marks); null when the bridge is off.
const bridge = BRIDGE
  ? {
      channel: (guild, channelId) => channelInfo(client, guild, channelId),
      ensure: (guildId, channelId) => bridges.ensure(guildId, channelId),
      bridged: (guildId) => bridges.bridged(guildId),
    }
  : null;

/** Hooks a gateway client's events up: the /ghost commands, voice and chat for the bridges, and Discord's refusals. */
function attach(c) {
  c.once(Events.ClientReady, async (ready) => {
    log(`ready in ${ready.guilds.cache.size} servers; ${store.links.size} links on file; chat bridge ${textBridge ? 'on' : 'off'}`);
    try {
      await ready.application.commands.set([COMMAND]);
      log('/ghost registered globally');
    } catch (e) {
      log(`registering /ghost failed: ${e?.message ?? e}`);
    }
  });

  c.on(Events.InteractionCreate, async (interaction) => {
    if (!interaction.isChatInputCommand() || interaction.commandName !== 'ghost') return;
    const sub = interaction.options.getSubcommand(false);
    const content = answer(
      { sub, guildId: interaction.guildId, canManage: Boolean(interaction.memberPermissions?.has(PermissionFlagsBits.ManageGuild)) },
      { codes, store },
    );
    log(`/ghost ${sub} in ${interaction.guildId ?? 'a DM'}`);
    try {
      await interaction.reply({ content, flags: MessageFlags.Ephemeral });
    } catch (e) {
      log(`reply failed: ${e?.message ?? e}`);
    }
  });

  c.on(Events.VoiceStateUpdate, (before, after) => {
    const guildId = after.guild?.id ?? before.guild?.id;
    if (!guildId) return;
    // The bot itself moved to another channel by someone: that bridge ends (it would carry the wrong channel).
    if (after.id === c.user?.id && before.channelId && after.channelId && before.channelId !== after.channelId) {
      bridges.find(guildId, before.channelId)?.stop('moved to another channel');
    }
    if (before.channelId && before.channelId !== after.channelId) bridges.voiceChanged(guildId, before.channelId);
    if (after.channelId) bridges.voiceChanged(guildId, after.channelId);
  });

  c.on(Events.MessageCreate, (message) => {
    if (!textBridge || !message.guildId) return;
    if (!bridges.find(message.guildId, message.channelId)) return;
    const mapped = discordToGhost(message, { botId: c.user?.id, webhookIds: bridgeStore.webhookIds(), appId: APP_ID });
    if (mapped) bridges.discordText(message.guildId, message.channelId, mapped);
  });

  c.on(Events.GuildCreate, (guild) => log(`added to server ${guild.id}`));
  c.on(Events.GuildDelete, (guild) => {
    // Its links stay on file (they answer 410 gone, and work again if the bot is added back); its codes go.
    codes.dropGuild(guild.id);
    log(`removed from server ${guild.id} (${store.countGuild(guild.id)} links now answer gone)`);
  });
  c.on(Events.ShardDisconnect, (event) => {
    if (event?.code === 4014) withoutText(c);
  });
  c.on(Events.Error, (e) => {
    if (disallowed(e)) return withoutText(c);
    log(`discord error: ${e?.message ?? e}`);
  });
}

/** Whether an error is Discord refusing an intent (gateway close code 4014). */
const disallowed = (e) => /disallowed intents/i.test(String(e?.message ?? e)) || e?.code === 4014;

/** Discord refused the Message Content intent: connect again without the chat's intents. Said once. */
let fellBack = false;
function withoutText(old) {
  if (fellBack || old !== client || !textBridge) return;
  fellBack = true;
  textBridge = false;
  log('Discord refused the Message Content intent (Developer Portal › Bot › Privileged Gateway Intents); the chat bridge is off, voice goes on');
  old.destroy().catch(() => {});
  connect(BASE_INTENTS);
}

/** A new gateway client with these intents becomes the current one and logs in. A failed login ends the process,
 * unless it is the Message Content refusal, which falls back to voice alone. */
function connect(intents) {
  const c = new Client({ intents });
  client = c;
  attach(c);
  c.login(TOKEN).catch((e) => {
    if (disallowed(e) && textBridge) return withoutText(c);
    if (c !== client) return; // an old client given up on
    fail(`logging in to Discord failed: ${e?.message ?? e}`);
  });
}

const server = createServer(createHandler({ codes, store, guilds, bridge, appId: APP_ID, log }));
server.headersTimeout = 10_000;
server.requestTimeout = 30_000;
server.listen(PORT, '127.0.0.1', () => {
  log(`listening on 127.0.0.1:${PORT}; bridge ${BRIDGE ? `on (Uplink hub id ${me.id.slice(0, 6)}…)` : 'off'}`);
  log(`invite: ${inviteUrl(APP_ID)}`);
});

// Stopping: no new requests, every bridge leaves its channel and space, then the hub and Discord are let go; five
// seconds at most.
let stopping = false;
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    if (stopping) return;
    stopping = true;
    log(`${signal}: stopping`);
    server.close();
    bridges.stopAll('stopping').finally(() => {
      hub.stop();
      (client?.destroy() ?? Promise.resolve()).finally(() => process.exit(0));
    });
    setTimeout(() => process.exit(0), 5000).unref();
  });
}

if (BRIDGE) hub.start();
connect(textBridge ? [...BASE_INTENTS, ...TEXT_INTENTS] : BASE_INTENTS);
