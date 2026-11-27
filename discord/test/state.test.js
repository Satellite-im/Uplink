import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildState, memberName, missingMembers } from '../src/state.js';
import { CATEGORY, STAGE, TEXT, VOICE, guild, member, voiceState } from './fakes.js';

// The /state answer (src/state.js), built from plain objects: which channels, in what order, and who is in them.

const G = '100000000000000001';

/** A server with channels in and out of categories, a hidden one, a text one, and people in voice in every state. */
function sample() {
  return guild({
    id: G,
    name: 'Ghosts',
    icon: 'abc123',
    channels: [
      { id: 'cat-b', name: 'Later', type: CATEGORY, rawPosition: 2 },
      { id: 'cat-a', name: 'First', type: CATEGORY, rawPosition: 1 },
      { id: 'v-b2', name: 'Late two', type: VOICE, rawPosition: 1, parentId: 'cat-b' },
      { id: 'v-b1', name: 'Late one', type: VOICE, rawPosition: 0, parentId: 'cat-b' },
      { id: 's-a', name: 'Stage', type: STAGE, rawPosition: 5, parentId: 'cat-a' },
      { id: 'v-top', name: 'Lobby', type: VOICE, rawPosition: 9, parentId: null },
      { id: 't-1', name: 'general', type: TEXT, rawPosition: 0, parentId: 'cat-a' },
      { id: 'v-hidden', name: 'Secret', type: VOICE, rawPosition: 0, parentId: 'cat-a', viewable: false },
    ],
    voiceStates: [
      voiceState('u1', 'v-b1', { selfMute: true }),
      voiceState('u2', 'v-b1', { serverDeaf: true, selfVideo: true }),
      voiceState('u3', 'v-top', { serverMute: true, selfDeaf: true, streaming: true }),
      voiceState('u4', null),
    ],
    members: [
      member('u1', { nickname: 'Zed', globalName: 'Global', username: 'user1', avatar: 'gav' }),
      member('u2', { globalName: 'Amy', username: 'amy_', userAvatar: 'uav' }),
      member('u3', { username: 'robot', bot: true }),
    ],
  });
}

test('the state: every visible voice and stage channel in Discord\'s order, empty ones too', () => {
  const state = buildState(sample(), 1234);
  assert.equal(state.at, 1234);
  assert.deepEqual(state.guild, { id: G, name: 'Ghosts', icon: `https://cdn.discordapp.com/icons/${G}/abc123.png` });
  assert.deepEqual(state.channels.map((c) => [c.id, c.kind, c.position]), [
    ['v-top', 'voice', 0],
    ['s-a', 'stage', 1],
    ['v-b1', 'voice', 2],
    ['v-b2', 'voice', 3],
  ]);
  assert.deepEqual(state.channels[1].members, []);
  assert.deepEqual(Object.keys(state.channels[0]), ['id', 'name', 'kind', 'position', 'members']);
});

test('members: name, avatar, and muted/deafened from self or server', () => {
  const state = buildState(sample(), 0);
  const [amy, zed] = state.channels[2].members;
  assert.deepEqual(amy, { id: 'u2', name: 'Amy', avatar: 'https://cdn.discordapp.com/avatars/u2/uav.png', muted: false, deafened: true, video: true, streaming: false, bot: false });
  assert.deepEqual(zed, { id: 'u1', name: 'Zed', avatar: `https://cdn.discordapp.com/guilds/${G}/users/u1/avatars/gav.png`, muted: true, deafened: false, video: false, streaming: false, bot: false });
  const [robot] = state.channels[0].members;
  assert.deepEqual(robot, { id: 'u3', name: 'robot', avatar: null, muted: true, deafened: true, video: false, streaming: true, bot: true });
});

test('a guild with no icon has icon null', () => {
  assert.equal(buildState(guild({ icon: null }), 0).guild.icon, null);
});

test('name: nickname, else display name, else username', () => {
  assert.equal(memberName(member('1', { nickname: 'Nick', globalName: 'Glob', username: 'usr' })), 'Nick');
  assert.equal(memberName(member('1', { globalName: 'Glob', username: 'usr' })), 'Glob');
  assert.equal(memberName(member('1', { username: 'usr' })), 'usr');
  assert.equal(memberName(null), 'Unknown');
});

test('a voice state\'s own member is used before the cache; missing ones are listed for fetching', () => {
  const g = guild({
    channels: [{ id: 'v', name: 'V', type: VOICE, rawPosition: 0 }],
    voiceStates: [voiceState('a', 'v', { member: member('a', { nickname: 'Inline' }) }), voiceState('b', 'v'), voiceState('c', null)],
  });
  assert.deepEqual(missingMembers(g), ['b']);
  assert.deepEqual(buildState(g, 0).channels[0].members.map((m) => m.name), ['Inline', 'Unknown']);
});
