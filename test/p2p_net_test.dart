import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/me/me.dart' show AppMeStore, Me;
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show FsStore, MemoryFsStore;
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/kept_files.dart';
import 'package:ghost_messaging/net/ledger.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/card.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/node_factory.dart' show p2pCoreHere;
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

import 'support/direct_world.dart' show HandEnd, LinkWords, PlainCarrier;
import 'support/fake_p2p.dart';

/// The direct route as the app holds it (lib/net/net.dart): there only where the build has the core
/// ([Net.p2pNode]), after the relay's hub in the order, linking with friends and nobody else the routes reach, kept in
/// step with the people, the person's mode, the app being put away and coming back and the relay in use, and deleted
/// from the device at sign-out. The phone under it is a stand-in channel, as test/net_want_test.dart's.

/// The choices of an app whose person has switched Direct on (Settings › Routes): Direct starts off.
AppState _directOn() => AppState()..set(Net.directName, 'on');

/// Waits for [ok], however long the machine takes (five seconds at most), not for a length of time.
Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = NetKeys.generate();
  // A friend by username, a friend by number, someone who has asked, and a member of a group this phone is in.
  final sam = NetKeys.generate(), nell = NetKeys.generate(), asker = NetKeys.generate(), member = NetKeys.generate();
  Uint8List keyWith(NetKeys them) => NetCrypto.netKey(NetCrypto.conversationKey(me, them.public)!);
  late Map<String, String> secrets;
  late List<String> secretWrites;
  late List<Map<String, Object?>> peers;
  late List<Map<String, Object?>> e2e;
  late List<Map<String, Object?>> buddies;
  late bool e2eFails, secretsLocked;

  /// Set, a read of the secret store waits on it, as a slow Keychain holds one.
  late Completer<void>? secretsHeld;
  late FakeP2pMesh mesh;
  late FakeP2pNode node;

  /// What the phone was asked, by method, in order.
  late List<String> asked;

  /// A friend by username as the phone keeps them (lib/friends/buddies.dart), where they stand with this phone.
  Map<String, Object?> buddy(String username, NetKeys keys, String state) => {'u': username, 'i': keys.id, 'k': base64Encode(keys.public), 's': state};

  setUp(() {
    HttpOverrides.global = null;
    secrets = {};
    secretWrites = [];
    // As Android's netPeers has them: those encryption is on with (Net.peers), the members of this phone's groups
    // (Groups.peers), and friends by username, asked or asking (Buddies.peers).
    peers = [
      {'id': sam.id, 'address': '@sam', 'key': keyWith(sam)},
      {'id': nell.id, 'address': '+1 (555) 000-0001', 'key': keyWith(nell)},
      {'id': asker.id, 'address': '', 'key': keyWith(asker)},
      {'id': member.id, 'address': '+15550000002', 'key': keyWith(member)},
    ];
    // The phone's own records of who is a friend: each by the id their key makes.
    e2e = [
      {'address': '+15550000001', 'state': 'on', 'friend': 'yes', 'id': nell.id},
      {'address': '+15550000002', 'state': 'on', 'friend': '', 'id': member.id},
    ];
    buddies = [buddy('sam', sam, 'yes'), buddy('asker', asker, 'asked')];
    e2eFails = false;
    secretsLocked = false;
    secretsHeld = null;
    mesh = FakeP2pMesh();
    node = mesh.node();
    asked = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final a = call.arguments is Map ? call.arguments as Map : const {};
      asked.add(call.method);
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (a['message'] as List).cast<int>());
        case 'netPeers':
          return peers;
        case 'e2eList':
          if (e2eFails) throw PlatformException(code: 'locked');
          return e2e;
        case 'buddiesKept':
          return jsonEncode(buddies);
        case 'netSmsDrain':
          return const <Object>[];
        case 'secretKeep':
          final value = '${a['value'] ?? ''}';
          secretWrites.add('${a['name']}');
          value.isEmpty ? secrets.remove('${a['name']}') : secrets['${a['name']}'] = value;
          return null;
        case 'secretRead':
          final held = secretsHeld;
          if (held != null) await held.future;
          if (secretsLocked) throw PlatformException(code: 'locked');
          return secrets['${a['name']}'];
      }
      return null;
    });
  });
  tearDown(() async {
    await Net.instance.shutdown();
    Net.p2pNode = null;
  });

  /// A card from Sam's device, sealed as his app seals it, as it comes by a route.
  Future<(DeviceCard, Uint8List)> samsCard() async {
    final card = await DeviceCard.make(KeysSigner(sam), device: NetCrypto.hex(NetCrypto.randomBytes(16)), nodeId: NetCrypto.hex(NetCrypto.randomBytes(32)), now: DateTime.now());
    final envelope = Envelope(kind: P2p.kind, body: {'t': 'card', 'c': card.toJson(), 'h': [?Net.instance.p2p?.card?.tag]}, ack: false);
    return (card, Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(keyWith(sam), envelope.encode())));
  }

  test('a build with no core has no direct route, and one whose core gives no node has none either', () async {
    expect(Net.p2pNode, isNull, reason: 'set where the app starts (main.dart), never under a test unless it says so');
    final hub = PlainCarrier('hub'), sms = PlainCarrier('sms');
    await Net.instance.start(_directOn(), carriers: [hub, sms]);
    expect([Net.instance.p2p, Net.instance.directOffered, Net.instance.directOn], [null, false, false]);
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'sms']);
    expect(secrets.keys, isNot(contains(P2p.keyName)));
    // Switched on all the same (a choice brought from another device): nothing, and nothing said.
    await Net.instance.setDirect(true);
    expect([Net.instance.p2p, Net.instance.directProblem], [null, null]);
    await Net.instance.shutdown();
    // A build that was to carry the core and left it out: switched on, it says so, and the other routes go on.
    Net.p2pNode = () => null;
    await Net.instance.start(_directOn(), carriers: [PlainCarrier('hub')]);
    expect(Net.instance.p2p, isNull);
    expect(Net.instance.board!.carrier('p2p'), isNull);
    expect(Net.instance.directProblem, contains('doesn\'t carry the direct network\'s core'));
  });

  // Matt's brief, 2026-11-23: Direct starts off in its first release, and "a person who never switches Direct on runs
  // none of it" (docs/OPEN_NETWORK.md, section 2). Once the app's start sets Net.p2pNode, the route was made at every
  // start: the core's library opened, a node key made, friends told this device's card, and Direct on for everyone,
  // 'p2p' being in nobody's net_off.
  test('Direct starts off: with a core and nothing chosen, nothing of the direct network is made or run, and its choice is its own, never in net_off', () async {
    var made = 0;
    Net.p2pNode = () {
      made++;
      return node;
    };
    final app = AppState();
    final hub = PlainCarrier('hub');
    await Net.instance.start(app, carriers: [hub, PlainCarrier('sms')]);
    expect([Net.instance.directOffered, Net.instance.directOn, Net.directByDefault], [true, false, false]);
    expect(made, 0, reason: 'the core was not asked for a node: its library is not so much as opened');
    expect([Net.instance.p2p, Net.instance.ledger, Net.instance.check, Net.instance.board!.log], [null, null, null, null]);
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'sms']);
    expect(Net.instance.board!.off, {'p2p'});
    expect(asked, isNot(anyOf(contains('buddiesKept'), contains('e2eList'))), reason: 'nobody was asked who is a friend');
    expect(Net.instance.friends, isEmpty);
    await pumpEventQueue(times: 20);
    expect(secrets.keys, isNot(contains(P2p.keyName)), reason: 'no node key was made');
    expect(app.withPrefix('p2p_'), isEmpty);
    expect(hub.to, isEmpty, reason: 'nobody was told a card');
    expect([node.starts, node.calls], [0, isEmpty]);
    // A card from a friend that comes meanwhile is nobody's to take.
    final (_, packet) = await samsCard();
    hub.take(packet, from: sam.id);
    await pumpEventQueue(times: 20);
    expect([node.calls, app.withPrefix('p2p_')], [isEmpty, isEmpty]);
    // Another route switched off is kept as ever, and Direct is never written among them.
    await Net.instance.setRoute('sms', false);
    expect([app.choice('net_off', ''), app.choice(Net.directName, '')], ['sms', '']);
    await Net.instance.shutdown();
    // Switched on before, whatever net_off says of it: on. Switched off: off, whatever it says.
    final chosen = AppState()
      ..set('net_off', 'p2p')
      ..set(Net.directName, 'on');
    await Net.instance.start(chosen, carriers: [PlainCarrier('hub')]);
    expect([Net.instance.directOn, Net.instance.p2p, Net.instance.board!.off], [true, isNotNull, isEmpty]);
    await Net.instance.shutdown();
    chosen
      ..set(Net.directName, 'off')
      ..set('net_off', '');
    await Net.instance.start(chosen, carriers: [PlainCarrier('hub')]);
    expect([Net.instance.directOn, Net.instance.p2p, Net.instance.board!.off], [false, null, {'p2p'}]);
  });

  // The second review, M3 (R2-K): the node and the direct network were made inside the one try that sets every route
  // up, so a core that failed to load took the relay's route down with it.
  test('a core that fails to load leaves the other routes as they are, and Settings is told why there is no Direct', () async {
    for (final broken in [
      FakeP2pMesh.broken(StateError('the direct network\'s library could not be loaded')),
      // One that loads and then breaks node.dart's word at once: its getters throw.
      () => node..throws.addAll({'state', 'paths', 'opened'}),
    ]) {
      Net.p2pNode = broken;
      final hub = PlainCarrier('hub'), sms = PlainCarrier('sms');
      await Net.instance.start(_directOn(), carriers: [hub, sms]);
      expect([Net.instance.board, Net.instance.error], [isNotNull, isNull], reason: 'the routes were set up');
      expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'sms']);
      expect(Net.instance.p2p, isNull);
      expect(Net.instance.directProblem, contains('could not be started'));
      // The relay's route carries as ever.
      await _until(() => hub.state.value == CarrierState.up, 'the relay\'s route started');
      final d = await Net.instance.send(Peer(id: sam.id, key: keyWith(sam)), Envelope(kind: 'ping', ack: false));
      expect(d.via, 'hub');
      await Net.instance.shutdown();
      expect(Net.instance.directProblem, isNull, reason: 'said of the routes as they were set up, and gone with them');
    }
  });

  test('with a core: the route comes after the relay\'s, its key is with the secrets, and only friends are told the card', () async {
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub'), sms = PlainCarrier('sms', traits: const CarrierTraits(maxPacket: 133, maxParts: 6, metered: true, live: false, wakes: true));
    final app = _directOn();
    await Net.instance.start(app, carriers: [hub, sms]);
    final p2p = Net.instance.p2p!;
    expect(Net.instance.board!.order, ['hub', 'p2p', 'lan', 'sms']);
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'p2p', 'sms']);
    expect(Net.instance.board!.carrier('p2p'), same(p2p.carrier));
    await _until(() => p2p.loaded && p2p.card != null, 'what the direct network keeps was read');
    // The node key where the install keeps its keys; the node id and the card with the app's choices.
    final key = (jsonDecode(secrets[P2p.keyName]!) as Map)['k'] as String;
    expect([key, (jsonDecode(secrets[P2p.keyName]!) as Map)['a']], [hasLength(64), me.id]);
    expect(p2p.nodeId, FakeP2pNode.idFor(NetCrypto.unhex(key)));
    expect(app.choice(P2p.idName, ''), contains(p2p.nodeId!));
    expect(app.withPrefix('p2p_').values.join(), isNot(contains(key)));
    final card = DeviceCard.fromJson(jsonDecode(app.choice(P2p.cardName, '')), now: DateTime.now().millisecondsSinceEpoch)!;
    expect([card.account, card.device, card.nodeId], [me.id, app.choice('hub_device', ''), p2p.nodeId]);
    expect(card, p2p.card, reason: 'signed through the phone, whose key it is');
    // A phone's policy: the node is not started for any of this.
    expect([p2p.policy.stayUp, node.starts], [false, 0]);

    // The people the routes reach are four; the friends are two. Only they were told anything, and by the relay's
    // route alone.
    expect(Net.instance.people.map((p) => p.id), unorderedEquals([sam.id, nell.id, asker.id, member.id]));
    expect(Net.instance.friends.map((p) => p.id), unorderedEquals([sam.id, nell.id]));
    await _until(() => hub.to.length >= 2, 'both friends were told');
    await pumpEventQueue();
    expect(hub.to, unorderedEquals([sam.id, nell.id]));
    expect(sms.carried, isEmpty);
    expect([p2p.mayLink(sam.id), p2p.mayLink(nell.id), p2p.mayLink(asker.id), p2p.mayLink(member.id)], [true, true, false, false]);

    // A card from a friend's device is taken; the same from the one who has only asked is not.
    final (theirs, packet) = await samsCard();
    hub.take(packet, from: sam.id);
    await _until(() => p2p.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');
    expect(p2p.devicesOf(sam.id).single.card, theirs);
    expect(node.allowed.keys, [theirs.nodeId]);
    final asking = await DeviceCard.make(KeysSigner(asker), device: 'ab' * 16, nodeId: 'cd' * 32, now: DateTime.now());
    hub.take(Packet.wrap(from: asker.id, sealed: true, payload: NetCrypto.seal(keyWith(asker), Envelope(kind: P2p.kind, body: {'t': 'card', 'c': asking.toJson()}, ack: false).encode())), from: asker.id);
    await pumpEventQueue();
    expect(p2p.devicesOf(asker.id), isEmpty);
    expect(hub.to.where((id) => id == asker.id), isEmpty, reason: 'nor answered');
    expect(Net.instance.direct.value, greaterThan(0), reason: 'Settings is told to draw again');
  });

  // The second review, M1: who counted as a friend came from the address the routes have for someone, and on Android
  // that includes the members of a group, whose addresses are whatever the group's admin wrote.
  test('friends are those the records say are, by the id their key makes: never a group member, whatever address an admin gave them, nor a pending request', () async {
    final atMember = NetKeys.generate(), numberMember = NetKeys.generate(), inviter = NetKeys.generate(), stranger = NetKeys.generate();
    peers.addAll([
      // Members of a group a friend admins, as Groups.peers has them: one the admin wrote as "@anything", one written
      // with the number of this phone's real friend, Nell.
      {'id': atMember.id, 'address': '@anything', 'key': keyWith(atMember)},
      {'id': numberMember.id, 'address': '+15550000001', 'key': keyWith(numberMember)},
      // Someone who asked to be a friend by username (Buddies.peers gives them no address).
      {'id': inviter.id, 'address': '', 'key': keyWith(inviter)},
    ]);
    buddies.add(buddy('inviter', inviter, 'invited'));
    // A record that says yes for someone the routes don't reach: no one to link with.
    e2e.add({'address': '+15550009999', 'state': 'on', 'friend': 'yes', 'id': stranger.id});
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub');
    await Net.instance.start(_directOn(), carriers: [hub]);
    final p2p = Net.instance.p2p!;
    await _until(() => p2p.loaded && p2p.card != null && hub.to.length >= 2, 'read, and the friends told');
    await pumpEventQueue();
    expect(Net.instance.people, hasLength(7));
    expect(Net.instance.friends.map((p) => p.id), unorderedEquals([sam.id, nell.id]));
    expect(hub.to, unorderedEquals([sam.id, nell.id]), reason: 'only friends are told the card, and where this device is');
    for (final who in [atMember, numberMember, asker, inviter, member]) {
      expect(p2p.mayLink(who.id), isFalse);
    }
    // What they say of themselves is not looked at: a card, or a meet that would bring the node up.
    for (final (i, who) in [atMember, numberMember].indexed) {
      final card = await DeviceCard.make(KeysSigner(who), device: '${i}d' * 16, nodeId: '${i}e' * 32, now: DateTime.now());
      for (final what in ['card', 'meet']) {
        hub.take(Packet.wrap(from: who.id, sealed: true, payload: NetCrypto.seal(keyWith(who), Envelope(kind: P2p.kind, body: {'t': what, 'c': card.toJson()}, ack: false).encode())), from: who.id);
      }
    }
    await pumpEventQueue(times: 50);
    expect([p2p.devicesOf(atMember.id), p2p.devicesOf(numberMember.id), node.allowed, node.starts], [isEmpty, isEmpty, isEmpty, 0]);
    expect(hub.to, hasLength(2), reason: 'nor answered');
    // The records change: Nell is a friend no longer, the inviter is one now. Read again, by id.
    e2e[0]['friend'] = '';
    buddies[2]['s'] = 'yes';
    await Net.instance.refresh();
    expect(Net.instance.friends.map((p) => p.id), unorderedEquals([sam.id, inviter.id]));
    // A record that can't be read now: whoever was a friend stays one.
    e2eFails = true;
    await Net.instance.refresh();
    expect(Net.instance.friends.map((p) => p.id), unorderedEquals([sam.id, inviter.id]));
  });

  test('kept in step: the people, how the person chose to be shown, the app put away and back, and shutting down', () async {
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub');
    await Net.instance.start(_directOn(), carriers: [hub]);
    final p2p = Net.instance.p2p!;
    await _until(() => p2p.loaded && p2p.card != null, 'what the direct network keeps was read');
    final (theirs, packet) = await samsCard();
    hub.take(packet, from: sam.id);
    await _until(() => p2p.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');

    // Invisible: no friend's device is let in. Seen again: let in again.
    Net.instance.setMode('invisible');
    expect([p2p.mayLink(sam.id), node.allowed], [false, isEmpty]);
    Net.instance.setMode('online');
    expect([p2p.mayLink(sam.id), node.allowed.keys], [true, [theirs.nodeId]]);

    // Put away, and back on the screen: the direct network knows which, and the node, where it is up, looks at its
    // paths again.
    expect(p2p.inUse, isTrue);
    Net.instance.setAway(true);
    expect(p2p.inUse, isFalse);
    Net.instance.setAway(false);
    expect(p2p.inUse, isTrue);
    await p2p.up();
    Net.instance.resume(const Duration(minutes: 2));
    expect(node.networkChanges, 1);

    // The friend by number is one no longer (the phone's own record says so): not a friend to the direct route.
    e2e[0]['friend'] = '';
    await Net.instance.refresh();
    expect(Net.instance.friends.map((p) => p.id), [sam.id]);
    // Sam is removed, or blocked: no longer among the people. His card goes, and his device is let in no longer.
    peers.removeWhere((p) => p['id'] == sam.id);
    await Net.instance.refresh();
    await _until(() => p2p.devicesOf(sam.id).isEmpty, 'Sam\'s card went with him');
    expect(node.allowed, isEmpty);

    // Shut down: the node stops, and the app holds no direct network.
    expect([node.state.value, p2p.loaded], [P2pState.up, true]);
    await Net.instance.shutdown();
    expect([node.state.value, Net.instance.p2p, p2p.loaded], [P2pState.off, null, false]);
    // And it hears nothing more: a card that comes now is nobody's to take.
    final before = Net.instance.direct.value;
    p2p.setHelpers(const ['https://late.example']);
    expect(Net.instance.direct.value, before, reason: 'no longer listened to');
  });

  test('a direct network made while the person is Invisible and the app put away starts so', () async {
    // As the app opens in the background with Invisible chosen before (Me tells Net as it starts).
    Net.instance.setMode('invisible');
    Net.instance.setAway(true);
    addTearDown(() {
      Net.instance.setMode('online');
      Net.instance.setAway(false);
    });
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub');
    await Net.instance.start(_directOn(), carriers: [hub]);
    final p2p = Net.instance.p2p!;
    await _until(() => p2p.loaded && p2p.card != null, 'what the direct network keeps was read');
    await pumpEventQueue();
    expect([p2p.inUse, p2p.mayLink(sam.id)], [false, false]);
    expect(hub.to, isEmpty, reason: 'Invisible, no friend is told anything');
    final (_, packet) = await samsCard();
    hub.take(packet, from: sam.id);
    await _until(() => p2p.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');
    expect(node.allowed, isEmpty, reason: 'and his device is not let in');
    // Seen again: let in, and told.
    Net.instance.setMode('online');
    expect(node.allowed, hasLength(1));
    await _until(() => hub.to.contains(sam.id), 'Sam was told once the person was seen again');
  });

  test('the relay in use names the link helpers as the app signs in to it, and another relay\'s take their place', () async {
    final one = Relay(hub: Hub(helpers: ['https://link.one.example'])), two = Relay(hub: Hub(helpers: ['https://link.two.example', 'https://link.three.example']));
    final first = 'ws://127.0.0.1:${await one.start(port: 0)}/hub', second = 'ws://127.0.0.1:${await two.start(port: 0)}/hub';
    addTearDown(one.stop);
    addTearDown(two.stop);
    Net.p2pNode = () => node;
    final app = _directOn()..set('net_hub', first);
    await Net.instance.start(app);
    final p2p = Net.instance.p2p!;
    await _until(() => Net.instance.hub!.state.value == CarrierState.up && p2p.loaded, 'signed in to the first relay');
    expect(Net.instance.hub!.helpers.value, ['https://link.one.example']);
    expect(p2p.helpers, ['https://link.one.example']);
    // Neither friend is connected to the relay: nothing of the direct network is said to them, so it keeps nothing
    // for them (second review, S13).
    await _until(() => p2p.card != null, 'this device\'s card was made');
    await pumpEventQueue(times: 50);
    expect([one.hub!.heldFor(sam.id), one.hub!.heldFor(nell.id)], [0, 0]);
    expect(jsonDecode(app.choice(P2p.helpersName, '')), ['https://link.one.example']);
    // Its next start is with them.
    await p2p.up();
    expect(node.config!.helpers, ['https://link.one.example']);

    // Moved to another relay: the first one's are used no longer, at once, and the second's once it has said.
    final starts = node.starts;
    await Net.instance.setHub(second);
    expect(p2p.helpers, isEmpty);
    await _until(() => p2p.helpers.isNotEmpty, 'signed in to the second relay');
    expect(p2p.helpers, ['https://link.two.example', 'https://link.three.example']);
    await _until(() => node.state.value == P2pState.up && node.config!.helpers.length == 2, 'the running node was started again with them');
    expect(node.starts, greaterThan(starts));
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'p2p', 'sms']);
  });

  // GMFB-21's copies (lib/friends/friends.dart, copyKind) went by the relay alone. With the relay away they now go
  // straight to the account's other device.
  test('a copy of a friend\'s words reaches the account\'s own other device directly when the relay can\'t be reached', () async {
    // An account on this install: its words where the install keeps its keys, which make the key its devices share.
    final words = AccountCrypto.newWords();
    secrets['account_words'] = words.join(' ');
    final mineKey = Me.mineKeyOf(words);
    // Sam as a friend by username, as the phone's records say (UsernameChats.states): by the install his key makes.
    e2e.add({'address': '@sam', 'state': 'on', 'friend': 'yes', 'id': sam.id});
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub');
    final app = _directOn();
    await Net.instance.start(app, carriers: [hub]);
    final p2p = Net.instance.p2p!;
    await _until(() => p2p.loaded && p2p.card != null, 'what the direct network keeps was read');
    await Friends.instance.start(app);
    addTearDown(() async {
      await Friends.instance.shutdown();
      Friends.instance = null;
    });

    // The account's other device: a node of its own, whose card it tells through the account's own name.
    final other = mesh.node();
    await other.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
    final card = await DeviceCard.make(KeysSigner(me), device: 'cd' * 16, nodeId: other.nodeId!, now: DateTime.now());
    final told = Envelope(kind: P2p.kind, body: {'t': 'card', 'c': card.toJson(), 'w': other.whereabouts.value!.toJson(), 'h': [p2p.card!.tag]}, ack: false);
    hub.take(Packet.wrap(from: me.id, sealed: true, payload: NetCrypto.seal(mineKey, told.encode())), from: me.id);
    await _until(() => p2p.ownDevices == 1, 'the account\'s other device is known');
    expect(p2p.friendsDevices, 0);
    // It answers a dial as the app's route does: its nonce, its proof once this device's has checked out, and then it
    // takes what comes.
    other.allow(p2p.nodeId!, {P2pChannel.packets});
    final ends = <HandEnd>[];
    other.opened.listen((s) => ends.add(HandEnd(s, linkKey: LinkWords.linkKey(mineKey), account: me.id, node: other.nodeId!, them: me.id)));
    List<Uint8List> taken() => [for (final e in ends) ...e.frames];

    // The relay can't be reached. A friend's words come all the same (by whatever way), and are copied on.
    hub.state.value = CarrierState.down;
    final byRelay = hub.to.length;
    final words_ = Envelope(kind: 'text', body: {'t': 'see you at 7'}, ack: false);
    hub.take(Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(keyWith(sam), words_.encode())), from: sam.id);
    await _until(() => taken().isNotEmpty, 'the copy came straight to the other device');
    expect(ends.single.proved, isTrue, reason: 'this device proved it is the account\'s');
    final packet = Packet.parse(taken().single)!;
    expect([packet.from, packet.sealed], [me.id, true]);
    final copy = Envelope.decode(NetCrypto.open(mineKey, packet.payload)!)!;
    expect(copy.kind, Friends.copyKind);
    expect([copy.body['a'], copy.body['t'], copy.body['i'], copy.body['o']], ['@sam', 'see you at 7', words_.id, false]);
    expect(hub.to, hasLength(byRelay), reason: 'nothing went by the relay, which was away');
    expect(node.pathTo(other.nodeId!)!.kind, P2pPathKind.direct);
  });

  // The second review, S5: Friends' "a route that costs nothing is up" was true whenever Direct was on, even with the
  // relay down and nothing linked: a text then tried the direct route for five seconds before going as SMS, a group's
  // message was marked failed rather than refused as offline, and what waited for an answer was sent again every ten
  // seconds.
  test('Friends counts the direct route as a way that costs nothing only while it reaches someone: a link to a friend\'s device open', () async {
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub');
    final app = _directOn();
    await Net.instance.start(app, carriers: [hub]);
    final p2p = Net.instance.p2p!;
    await _until(() => p2p.loaded && p2p.card != null, 'what the direct network keeps was read');
    await Friends.instance.start(app);
    addTearDown(() async {
      await Friends.instance.shutdown();
      Friends.instance = null;
    });
    expect(Friends.instance.online, isTrue, reason: 'the relay\'s route is up');
    await hub.stop();
    await pumpEventQueue();
    expect(p2p.carrier.state.value, CarrierState.up, reason: 'Direct is on, and ready to dial');
    expect(Friends.instance.online, isFalse, reason: 'but it reaches nobody now');
    // A friend's device linked: it reaches someone.
    final theirs = mesh.node();
    await theirs.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
    final card = await DeviceCard.make(KeysSigner(sam), device: 'ab' * 16, nodeId: theirs.nodeId!, now: DateTime.now());
    hub.state.value = CarrierState.up;
    hub.take(Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(keyWith(sam), Envelope(kind: P2p.kind, body: {'t': 'card', 'c': card.toJson(), 'w': theirs.whereabouts.value!.toJson(), 'h': [p2p.card!.tag]}, ack: false).encode())), from: sam.id);
    await _until(() => p2p.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');
    await hub.stop();
    theirs.allow(p2p.nodeId!, {P2pChannel.packets});
    final ends = <HandEnd>[];
    theirs.opened.listen((s) => ends.add(HandEnd(s, linkKey: LinkWords.linkKey(keyWith(sam)), account: sam.id, node: theirs.nodeId!, them: me.id)));
    expect(await p2p.carrier.send(Peer(id: sam.id, key: keyWith(sam)), Packet.wrap(from: me.id, sealed: true, payload: NetCrypto.seal(keyWith(sam), Envelope(kind: 'ping', ack: false).encode()))), Handed.passed);
    expect(ends.single.proved, isTrue);
    expect(Friends.instance.online, isTrue);
  });

  // The second review: hub_device travels in backed-up choices, so a backup restored onto another device gave the two
  // one device name (the hub's, forward secrecy's and the circles' keys are all per device).
  test('choices restored from another device\'s backup are known by the node key that did not come with them, and the device takes a name of its own', () async {
    Net.p2pNode = () => node;
    // A device the app ran on, with Direct: its name, and the direct network's word for its node.
    final first = _directOn();
    await Net.instance.start(first, carriers: [PlainCarrier('hub')]);
    await _until(() => Net.instance.p2p!.loaded, 'what the direct network keeps was read');
    final name = first.choice('hub_device', '');
    expect([name, first.choice(P2p.idName, '')], [hasLength(32), isNotEmpty]);
    await Net.instance.shutdown();
    // Started again where it ran: the same name.
    await Net.instance.start(first, carriers: [PlainCarrier('hub')]);
    expect(first.choice('hub_device', ''), name);
    await Net.instance.shutdown();
    // Its choices restored onto a new device: they come, the node key does not. A name of its own.
    final restored = _directOn();
    for (final k in ['hub_device', P2p.idName, P2p.cardName, P2p.toldName, P2p.cardsName]) {
      restored.set(k, first.choice(k, ''));
    }
    secrets.clear();
    node = mesh.node();
    await Net.instance.start(restored, carriers: [PlainCarrier('hub')]);
    final own = restored.choice('hub_device', '');
    expect(own, allOf(hasLength(32), isNot(name)));
    await _until(() => Net.instance.p2p!.loaded && Net.instance.p2p!.card != null, 'what the direct network keeps was read');
    expect(Net.instance.p2p!.card!.device, own);
    await Net.instance.shutdown();
    // And keeps it from then on.
    await Net.instance.start(restored, carriers: [PlainCarrier('hub')]);
    expect(restored.choice('hub_device', ''), own);
    await Net.instance.shutdown();
    // A secret store that can't be read yet says nothing either way: the name stays.
    secretsLocked = true;
    final locked = _directOn()
      ..set('hub_device', name)
      ..set(P2p.idName, first.choice(P2p.idName, ''));
    await Net.instance.start(locked, carriers: [PlainCarrier('hub')]);
    expect(locked.choice('hub_device', ''), name);
  });

  test('a device the account is gone from forgets its place on the direct network: the key, the cards and what was told', () async {
    Net.p2pNode = () => node;
    final hub = PlainCarrier('hub');
    final app = _directOn();
    await Net.instance.start(app, carriers: [hub]);
    final p2p = Net.instance.p2p!;
    await _until(() => p2p.loaded && p2p.card != null && hub.to.length >= 2, 'read, and the friends told');
    final (_, packet) = await samsCard();
    hub.take(packet, from: sam.id);
    await _until(() => p2p.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');
    await p2p.up();
    await pumpEventQueue();
    for (final name in [P2p.idName, P2p.cardName, P2p.cardsName, P2p.toldName]) {
      expect(app.choice(name, ''), isNotEmpty, reason: name);
    }
    expect(secrets[P2p.keyName], isNotNull);

    // The relay says this device is no longer the account's (removed from another device): what signing out does too.
    final account = Account(relay: _Gone(), port: SmsAccountPort(), store: AppMeStore(app), profiles: AppAccountProfiles());
    app.set('acct_address', '0x52908400098527886E0F7030069857D2E4169EE7');
    await account.check();
    expect(account.signedIn, isFalse);
    expect(secrets.keys, isNot(contains(P2p.keyName)));
    for (final name in P2p.keptNames) {
      expect(app.choice(name, ''), isEmpty, reason: name);
    }
    expect([p2p.loaded, p2p.card, p2p.nodeId, p2p.devicesOf(sam.id)], [false, null, null, isEmpty]);
    expect([node.state.value, node.allowed], [P2pState.off, isEmpty]);
    expect(p2p.carrier.reaches(Peer(id: sam.id, key: keyWith(sam))), isFalse);
  });

  // Checking the relay (lib/net/ledger.dart; docs/OPEN_NETWORK.md, section 3).
  test('the ledger the relay is checked by: made with the direct route, kept in its own files and never with the choices, told by the switchboard, listing friends as the records say each time, and forgotten at sign-out', () async {
    Net.p2pNode = () => node;
    // Its own files, out of any backup (lib/net/kept_files.dart; the review, D6): here a folder of the test's own.
    final folder = Directory.systemTemp.createTempSync('ledger');
    addTearDown(() => folder.deleteSync(recursive: true));
    final files = FilesFsStore(folder);
    Net.ledgerStore = () => files;
    addTearDown(() => Net.ledgerStore = Net.defaultLedgerStore);
    final hub = PlainCarrier('hub');
    final app = _directOn();
    await Net.instance.start(app, carriers: [hub]);
    final ledger = Net.instance.ledger!;
    await _until(() => ledger.loaded && Net.instance.p2p!.loaded, 'read');
    expect([Net.instance.board!.log, Net.instance.check], [same(ledger), isNotNull]);
    // To a friend: listed. To someone who has only asked: not.
    final toSam = Envelope(kind: 'text', body: {'t': 'hi'}), toAsker = Envelope(kind: 'text', body: {'t': 'hi'});
    await Net.instance.send(Net.instance.byId(sam.id)!, toSam, only: {'hub'});
    await Net.instance.send(Net.instance.byId(asker.id)!, toAsker, only: {'hub'});
    expect([for (final x in ledger.sentTo(sam.id)) [x.id, x.via]], [[toSam.id, 'hub']]);
    expect(ledger.sentTo(asker.id), isEmpty);
    // The records change (the asker said yes), read again: listed from now, as the records say now.
    buddies[1]['s'] = 'yes';
    await Net.instance.refresh();
    final again = Envelope(kind: 'text', body: {'t': 'hi again'});
    await Net.instance.send(Net.instance.byId(asker.id)!, again, only: {'hub'});
    expect([for (final x in ledger.sentTo(asker.id)) x.id], [again.id]);
    await ledger.flush();
    expect([for (final name in [Ledger.indexName, Ledger.bookName(sam.id), Ledger.bookName(asker.id)]) await files.read(name)], everyElement(isNotEmpty));
    expect(await files.read(Ledger.bookName(sam.id)), isNot(contains('hi')), reason: 'no words');
    // Nothing of it with the app's choices, which Android's backup copies.
    expect(app.withPrefix('ldg'), isEmpty);
    // Signing out (the relay says this device is no longer the account's): nothing of it is left.
    final account = Account(relay: _Gone(), port: SmsAccountPort(), store: AppMeStore(app), profiles: AppAccountProfiles());
    app.set('acct_address', '0x52908400098527886E0F7030069857D2E4169EE7');
    await account.check();
    expect(folder.listSync(), isEmpty);
    expect(ledger.sentTo(sam.id), isEmpty);
  });

  test('where no routes were ever set up, signing out still deletes what the direct network kept', () async {
    final app = AppState()
      ..set(P2p.cardsName, '{"x":[]}')
      ..set(P2p.toldName, '{"x":{}}')
      ..set(P2p.idName, '{"n":"x"}')
      ..set(P2p.cardName, '{}')
      ..set('acct_address', '0x52908400098527886E0F7030069857D2E4169EE7');
    secrets[P2p.keyName] = 'ab' * 32;
    expect(Net.instance.p2p, isNull);
    final account = Account(relay: _Gone(), port: SmsAccountPort(), store: AppMeStore(app), profiles: AppAccountProfiles());
    await account.check();
    expect(secrets.keys, isNot(contains(P2p.keyName)));
    for (final name in P2p.keptNames) {
      expect(app.choice(name, ''), isEmpty, reason: name);
    }
    expect(AccountCrypto.goodAddress('0x52908400098527886E0F7030069857D2E4169EE7'), isTrue);
  });

  // The second review: with no node, signing out wrote an empty node key to the secret store and five empty choices.
  test('with nothing of the direct network kept, signing out writes none of it', () async {
    final app = AppState()..set('acct_address', '0x52908400098527886E0F7030069857D2E4169EE7');
    expect(Net.instance.p2p, isNull);
    final account = Account(relay: _Gone(), port: SmsAccountPort(), store: AppMeStore(app), profiles: AppAccountProfiles());
    await account.check();
    expect(account.signedIn, isFalse);
    expect(secretWrites, isNot(contains(P2p.keyName)));
    expect(app.withPrefix('p2p_'), isEmpty);
    // And the direct network's own forgetting, where one ran, the same.
    final plain = MemoryFsStore(), kept = MemoryFsStore();
    await P2p.forget(kept, plain);
    expect([kept.writes, plain.writes], [0, 0]);
    plain.kept[P2p.cardsName] = '{}';
    await P2p.forget(kept, plain);
    expect([kept.writes, plain.writes, plain.kept[P2p.cardsName]], [0, 1, '']);
  });

  /// A card from [device]'s node, Sam's, saying where it is and that it holds [held] (this device's card's name).
  Uint8List samsCardFrom(FakeP2pNode device, DeviceCard card, {String? held}) => Packet.wrap(
        from: sam.id,
        sealed: true,
        payload: NetCrypto.seal(keyWith(sam), Envelope(kind: P2p.kind, body: {'t': 'card', 'c': card.toJson(), 'w': device.whereabouts.value!.toJson(), 'h': [?held]}, ack: false).encode()),
      );

  // Matt's brief, 2026-11-23: "Switching it on starts the node and the route without a restart; switching it off stops
  // the node and closes every link."
  test('switched on without a restart: the node, the route and the ledger are made, friends asked and told; switched off: every link closed, the node stopped and nobody let in, the route and the ledger gone; on again: the same node', () async {
    var made = 0;
    Net.p2pNode = () {
      made++;
      return node;
    };
    final kept = MemoryFsStore();
    Net.ledgerStore = () => kept;
    addTearDown(() => Net.ledgerStore = Net.defaultLedgerStore);
    final app = AppState();
    final hub = PlainCarrier('hub');
    await Net.instance.start(app, carriers: [hub, PlainCarrier('sms')]);
    expect([Net.instance.p2p, made], [null, 0]);

    // Switched on, as its switch in Settings › Routes does it.
    await Net.instance.setRoute('p2p', true);
    final p2p = Net.instance.p2p!;
    expect([made, app.choice(Net.directName, ''), app.choice('net_off', ''), Net.instance.board!.off], [1, 'on', '', isEmpty]);
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'p2p', 'sms'], reason: 'after the relay\'s, as ever');
    expect(Net.instance.friends.map((p) => p.id), unorderedEquals([sam.id, nell.id]));
    expect([Net.instance.ledger, Net.instance.check, Net.instance.board!.log], [isNotNull, isNotNull, same(Net.instance.ledger)]);
    await _until(() => p2p.loaded && p2p.card != null && hub.to.length >= 2, 'read, and the friends told');
    expect([p2p.on, p2p.carrier.state.value], [true, CarrierState.up]);
    // A friend's device: its card taken, it let in, and a link made for a send (a phone's node comes up for it).
    final theirs = mesh.node();
    await theirs.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
    final card = await DeviceCard.make(KeysSigner(sam), device: 'ab' * 16, nodeId: theirs.nodeId!, now: DateTime.now());
    hub.take(samsCardFrom(theirs, card, held: p2p.card!.tag), from: sam.id);
    await _until(() => p2p.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');
    expect(node.allowed.keys, [theirs.nodeId]);
    theirs.allow(p2p.nodeId!, {P2pChannel.packets});
    final ends = <HandEnd>[];
    theirs.opened.listen((s) => ends.add(HandEnd(s, linkKey: LinkWords.linkKey(keyWith(sam)), account: sam.id, node: theirs.nodeId!, them: me.id)));
    expect(await p2p.carrier.send(Peer(id: sam.id, key: keyWith(sam)), Packet.wrap(from: me.id, sealed: true, payload: NetCrypto.seal(keyWith(sam), Envelope(kind: 'ping', ack: false).encode()))), Handed.passed);
    expect([ends.single.proved, p2p.carrier.links.length, node.state.value], [true, 1, P2pState.up]);

    // Switched off: the link closed at both ends, the node stopped, nobody let in, the route and the ledger gone.
    await Net.instance.setRoute('p2p', false);
    expect([Net.instance.p2p, Net.instance.ledger, Net.instance.check, Net.instance.board!.log, Net.instance.board!.carrier('p2p')], [null, null, null, null, null]);
    expect([app.choice(Net.directName, ''), app.choice('net_off', ''), Net.instance.board!.off], ['off', '', {'p2p'}]);
    expect([node.state.value, node.streams, theirs.streams, node.allowed], [P2pState.off, 0, 0, isEmpty]);
    expect([p2p.loaded, p2p.carrier.lines], [false, 0]);
    // The ledger's lists stay, marked as kept no longer from now (Ledger.pause).
    expect((jsonDecode(kept.kept[Ledger.indexName]!) as Map)['p'], isA<int>());
    // Nothing of it hears anything now: a card that comes is nobody's to take, and the core is told nothing.
    final calls = Map.of(node.calls);
    hub.take(samsCardFrom(theirs, card), from: sam.id);
    await pumpEventQueue(times: 20);
    expect(node.calls, calls);

    // While it is off, Sam is a friend no longer. Switched on again: the same node, and his device not let in.
    peers.removeWhere((p) => p['id'] == sam.id);
    buddies.removeWhere((b) => b['i'] == sam.id);
    await Net.instance.refresh();
    await Net.instance.setRoute('p2p', true);
    final again = Net.instance.p2p!;
    expect([made, identical(again, p2p), identical(again.node, node)], [1, false, true]);
    await _until(() => again.loaded && again.card != null, 'read again');
    expect(node.allowed, isEmpty, reason: 'nobody the first one let in is let in still');
    expect(Net.instance.friends.map((p) => p.id), [nell.id]);
  });

  test('switched on after the relay was signed in to, the direct network has the link helpers the relay named at once, not at its next sign-in', () async {
    final one = Relay(hub: Hub(helpers: ['https://link.one.example']));
    final url = 'ws://127.0.0.1:${await one.start(port: 0)}/hub';
    addTearDown(one.stop);
    Net.p2pNode = () => node;
    await Net.instance.start(AppState()..set('net_hub', url));
    await _until(() => Net.instance.hub!.state.value == CarrierState.up, 'signed in to the relay');
    expect([Net.instance.relayHelpers, Net.instance.p2p], [['https://link.one.example'], null]);
    await Net.instance.setDirect(true);
    final p2p = Net.instance.p2p!;
    expect(p2p.helpers, ['https://link.one.example'], reason: 'the relay names them only as the app signs in to it');
    await _until(() => p2p.loaded, 'read');
    await p2p.up();
    expect(node.config!.helpers, ['https://link.one.example']);
  });

  test('switched off and on again at once, the second waits for the first: what the direct network going lets go of is never what the new one has let in', () async {
    Net.p2pNode = () => node;
    final slow = _SlowStore();
    Net.ledgerStore = () => slow;
    addTearDown(() => Net.ledgerStore = Net.defaultLedgerStore);
    final hub = PlainCarrier('hub');
    await Net.instance.start(_directOn(), carriers: [hub]);
    final first = Net.instance.p2p!;
    await _until(() => first.loaded && first.card != null, 'read');
    final (theirs, packet) = await samsCard();
    hub.take(packet, from: sam.id);
    await _until(() => first.devicesOf(sam.id).isNotEmpty, 'Sam\'s card was taken');
    expect(node.allowed.keys, [theirs.nodeId]);
    // The ledger going writes slowly, and meanwhile Direct is switched on again: given every chance to, nothing new is
    // made until the old one has gone.
    slow.hold = Completer<void>();
    final off = Net.instance.setDirect(false), on = Net.instance.setDirect(true);
    bool madeAgain() => Net.instance.p2p != null && !identical(Net.instance.p2p, first) && Net.instance.p2p!.loaded;
    for (var i = 0; i < 200 && !madeAgain(); i++) {
      await pumpEventQueue();
    }
    expect([Net.instance.p2p, slow.waiting], [null, greaterThan(0)], reason: 'not made while the one before was still going');
    slow.hold!.complete();
    slow.hold = null;
    await Future.wait([off, on]);
    final second = Net.instance.p2p!;
    await _until(() => second.loaded && node.allowed.isNotEmpty, 'the new one read what it keeps and let Sam\'s device in');
    expect(identical(first, second), isFalse);
    expect(node.allowed.keys, [theirs.nodeId], reason: 'let go of by the one going before the new one let it in');
    expect([for (final c in Net.instance.board!.carriers) if (c.id == 'p2p') identical(c, second.carrier)], [true]);
  });

  // The review of Direct's switch (2026-11-23): Net.start read Direct's choice at three points with awaits between,
  // and a switch before the switchboard was made only wrote the choice. Switched on while the routes were set up, no
  // direct network was ever made (Settings said "Starting…" for ever); switched off, it was made and held all the same.
  Future<void> switchedWhileStarting(AppState app, bool on) async {
    secretsHeld = Completer<void>();
    final starting = Net.instance.start(app, carriers: [PlainCarrier('hub')]);
    for (var i = 0; i < 200 && !asked.contains('secretRead'); i++) {
      await pumpEventQueue();
    }
    expect(asked, contains('secretRead'), reason: 'the start reached the secret store (forward secrecy\'s prekeys)');
    await Net.instance.setDirect(on);
    secretsHeld!.complete();
    secretsHeld = null;
    await starting;
  }

  test('Direct switched on while the routes are set up is made once they are, friends asked and the ledger kept', () async {
    var made = 0;
    Net.p2pNode = () {
      made++;
      return node;
    };
    await switchedWhileStarting(AppState(), true);
    expect([Net.instance.directOn, made, Net.instance.board!.off], [true, 1, isEmpty]);
    final p2p = Net.instance.p2p!;
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'p2p']);
    expect(Net.instance.friends.map((p) => p.id), unorderedEquals([sam.id, nell.id]));
    expect([Net.instance.ledger, Net.instance.check], [isNotNull, isNotNull]);
    await _until(() => p2p.loaded, 'it read what it keeps');
  });

  test('Direct switched off while the routes are set up makes nothing of the direct network: no node, no route, no ledger', () async {
    var made = 0;
    Net.p2pNode = () {
      made++;
      return node;
    };
    await switchedWhileStarting(_directOn(), false);
    await pumpEventQueue(times: 50);
    expect([Net.instance.directOn, made, Net.instance.p2p, Net.instance.ledger, Net.instance.check, Net.instance.board!.log], [false, 0, null, null, null, null]);
    expect(Net.instance.board!.off, {'p2p'});
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub']);
    expect(node.calls, isEmpty, reason: 'nothing was asked of a node');
  });

  test('the node goes with the routes at sign-out: the next account signed in on this device has a node of its own', () async {
    final made = <FakeP2pNode>[];
    Net.p2pNode = () {
      final n = mesh.node();
      made.add(n);
      return n;
    };
    await Net.instance.start(_directOn(), carriers: [PlainCarrier('hub')]);
    expect(made, hasLength(1));
    // Off and on again in one sign-in: the same node.
    await Net.instance.setDirect(false);
    await Net.instance.setDirect(true);
    expect([made.length, identical(Net.instance.p2p!.node, made.single)], [1, true]);
    await Net.instance.shutdown();
    expect(made.single.state.value, P2pState.off);
    await Net.instance.start(_directOn(), carriers: [PlainCarrier('hub')]);
    expect(made, hasLength(2), reason: 'the first account\'s node was started again for the next');
    expect(identical(Net.instance.p2p!.node, made.last), isTrue);
  });

  // Matt's brief: "Set Net.p2pNode = makeP2pNode where the app starts, for builds with the core." Not on an iPhone: no
  // core is packaged there.
  test('the app sets Net.p2pNode where it starts, where its builds carry the core, and nothing else does; an iPhone\'s carries none', () {
    final sets = RegExp(r'Net\.p2pNode\s*=');
    final where = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') && sets.hasMatch(f.readAsStringSync())) f.path.replaceAll('\\', '/'),
    ]..sort();
    expect(where, ['lib/desktop/main.dart', 'lib/main.dart']);
    for (final path in where) {
      expect(File(path).readAsStringSync(), contains('if (p2pCoreHere) Net.p2pNode = makeP2pNode;'), reason: path);
    }
    // These tests run on a computer whose builds carry it.
    expect(p2pCoreHere, isTrue);
    expect(File('lib/net/p2p/node_factory.dart').readAsStringSync(), contains('PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux'));
    // The iPhone's project links no core (tool/build-p2p.sh ios makes one it does not use yet): no Direct offered there.
    for (final f in Directory('ios').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.pbxproj') || f.path.endsWith('Podfile'))) {
      expect(f.readAsStringSync(), isNot(anyOf(contains('GhostP2p'), contains('ghost_p2p'))), reason: f.path);
    }
  });
}

/// A store whose writes wait while [hold] is set.
class _SlowStore implements FsStore {
  final kept = <String, String>{};
  Completer<void>? hold;
  @override
  Future<String?> read(String name) async => kept[name];

  /// How many writes are waiting now.
  int waiting = 0;
  @override
  Future<void> write(String name, String value) async {
    final h = hold;
    if (h != null) {
      waiting++;
      await h.future;
      waiting--;
    }
    kept[name] = value;
  }
}

/// A relay that says this device is not the account's any more.
class _Gone implements AccountRelay {
  @override
  String get hubId => '';
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async => {'known': false};
}
