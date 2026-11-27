// What crosses the bridge: the Discord people for {t:'dc'}, the nickname, and chat each way with no echo.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { dcPeople, discordToGhost, ghostToBotMessage, ghostToWebhook, nicknameFor, webhookName } from '../src/bridge/mapping.js';
import { VOICE, guild, member, voiceState } from './fakes.js';

const G = '100000000000000001';
const BOT = '300000000000000003';

test('dc people: everyone in that channel but the bot, by name, with speaking from the speaking set', () => {
  const g = guild({
    id: G,
    channels: [{ id: 'v1', name: 'Lounge', type: VOICE }, { id: 'v2', name: 'Other', type: VOICE }],
    voiceStates: [voiceState('u1', 'v1', { selfMute: true }), voiceState('u2', 'v1', { serverDeaf: true }), voiceState(BOT, 'v1'), voiceState('u3', 'v2')],
    members: [member('u1', { nickname: 'Zed', userAvatar: 'za' }), member('u2', { globalName: 'Amy', bot: true }), member(BOT, { bot: true })],
  });
  const people = dcPeople(g, 'v1', { botId: BOT, speaking: new Set(['u1']) });
  assert.deepEqual(people, [
    { id: 'u2', name: 'Amy', avatar: null, speaking: false, muted: false, deafened: true, bot: true },
    { id: 'u1', name: 'Zed', avatar: 'https://cdn.discordapp.com/avatars/u1/za.png', speaking: true, muted: true, deafened: false, bot: false },
  ]);
  assert.deepEqual(dcPeople(g, 'v9', { botId: BOT }), []);
});

test('nickname: "Uplink · <name>" for one, "Uplink · N people" for more, none for nobody; at most 32 characters', () => {
  assert.equal(nicknameFor(['Matt']), 'Uplink · Matt');
  assert.equal(nicknameFor(['Matt', 'Casper']), 'Uplink · 2 people');
  assert.equal(nicknameFor(['a', 'b', 'c']), 'Uplink · 3 people');
  assert.equal(nicknameFor([]), null);
  assert.equal(nicknameFor(['']), 'Uplink · someone');
  const long = nicknameFor(['A really very long display name here']);
  assert.equal(long.length, 32);
  assert.ok(long.startsWith('Uplink · A really') && long.endsWith('…'));
});

const msg = (extra = {}) => ({ author: { id: 'u1', bot: false, username: 'amy_', globalName: 'Amy' }, member: { nickname: null }, content: 'hello', attachments: [], webhookId: null, ...extra });

test('Discord -> Uplink: the author\'s name and the text, attachments as links; nothing from the bot or its webhooks', () => {
  const opts = { botId: BOT, webhookIds: new Set(['w1']), appId: '200000000000000002' };
  assert.deepEqual(discordToGhost(msg(), opts), { name: 'Amy', text: 'hello' });
  assert.deepEqual(discordToGhost(msg({ member: { nickname: 'Ames' } }), opts), { name: 'Ames', text: 'hello' });
  assert.deepEqual(discordToGhost(msg({ content: '', attachments: new Map([['a', { url: 'https://cdn.discordapp.com/x.png' }]]) }), opts), { name: 'Amy', text: 'https://cdn.discordapp.com/x.png' });
  assert.equal(discordToGhost(msg({ author: { id: BOT, bot: true, username: 'Uplink' } }), opts), null, 'the bot itself');
  assert.equal(discordToGhost(msg({ webhookId: 'w1', author: { id: 'w1', bot: true, username: 'Matt' } }), opts), null, 'the bridge\'s webhook');
  assert.equal(discordToGhost(msg({ webhookId: 'w2', applicationId: '200000000000000002' }), opts), null, 'any webhook of this app');
  assert.deepEqual(discordToGhost(msg({ webhookId: 'w9', author: { id: 'w9', bot: true, username: 'GitHub' } }), opts), { name: 'GitHub', text: 'hello' }, 'someone else\'s webhook is channel content');
  assert.equal(discordToGhost(msg({ system: true }), opts), null);
  assert.equal(discordToGhost(msg({ content: '   ' }), opts), null);
  assert.equal(discordToGhost(msg({ content: 'x'.repeat(5000) }), opts).text.length, 4000);
});

test('Uplink -> Discord: a webhook post under the sender\'s name that pings nobody; without webhooks, the name in bold', () => {
  assert.deepEqual(ghostToWebhook({ name: 'Matt', text: 'hi @everyone' }), { username: 'Matt', content: 'hi @everyone', allowedMentions: { parse: [] } });
  assert.equal(ghostToWebhook({ name: 'Matt', text: 'x'.repeat(2500) }).content.length, 2000);
  assert.equal(webhookName('My Discord pal'), 'My D1scord pal');
  assert.equal(webhookName('clyde'), 'Clyd3');
  assert.equal(webhookName('   '), 'Uplink');
  assert.equal(webhookName('x'.repeat(100)).length, 80);
  assert.deepEqual(ghostToBotMessage({ name: 'M*tt_', text: 'hi' }), { content: '**M\\*tt\\_:** hi', allowedMentions: { parse: [] } });
});
