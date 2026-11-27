import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/p2p/card.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/net/p2p/p2p_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_relay/hub.dart';

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';
import 'support/hub_pair.dart';

/// The direct route (lib/net/p2p; docs/OPEN_NETWORK.md, section 2; Matt, 2026-11-22: "p2p delivery with the relay as
/// a primary source but have p2p as a secondary back up"): installs wired as the app wires them (support/
/// direct_world.dart), over a real hub in memory and a stand-in for the direct network's core, on a clock the tests
/// move by hand. Nothing here waits on the machine.

const _helper = 'https://link.example';
const _packets = {P2pChannel.packets};
const _second = Duration(seconds: 1);
const _minute = Duration(minutes: 1);

/// A `p2p` envelope as a device makes one, at the world's time.
Envelope _said(World w, Map<String, dynamic> body) => Envelope(kind: P2p.kind, body: body, ack: false, at: w.clock.ms);

/// What a device that holds [to]'s card says to tell it [card] (or to ask it to meet): the card, and that it holds
/// theirs, so nothing needs answering.
Map<String, dynamic> _telling(Install to, DeviceCard card, {String what = 'card', Map<String, dynamic>? where}) => {'t': what, 'c': card.toJson(), 'w': ?where, 'h': [to.p2p.card!.tag]};

/// A card [account] signed for a device that is not one of the installs: for a test of what is taken and what is not.
Future<DeviceCard> _cardOf(World w, Account account, {String? device, String? node}) =>
    DeviceCard.make(KeysSigner(account.keys), device: device ?? NetCrypto.hex(NetCrypto.randomBytes(16)), nodeId: node ?? NetCrypto.hex(NetCrypto.randomBytes(32)), now: w.clock.now());

Map<String, dynamic> _kept(Install i, String name) => (jsonDecode(i.plain.kept[name] ?? '{}') as Map).cast<String, dynamic>();

/// The node key [i] keeps in its secret store: with the account it was made under.
Uint8List _nodeKey(Install i) => NetCrypto.unhex((jsonDecode(i.secrets.kept[P2p.keyName]!) as Map)['k'] as String);

/// A route of live links that reaches this account's other devices by its word, and can link with none of them now.
class _DeadLinks implements Carrier, LiveLinks {
  @override
  String get id => 'p2p';
  @override
  String get name => 'Direct';
  @override
  String get about => '';
  @override
  CarrierTraits get traits => const CarrierTraits(maxPacket: 60 * 1024);
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;
  final _arrived = StreamController<Arrived>.broadcast();
  final asked = <Uint8List>[];
  @override
  Stream<Arrived> get arrived => _arrived.stream;
  @override
  Future<void> start() async => state.value = CarrierState.up;
  @override
  Future<void> stop() async => state.value = CarrierState.off;
  @override
  bool reaches(Peer peer) => true;
  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    asked.add(packet);
    throw CarrierError('none of their devices could be reached directly');
  }

  @override
  bool linked(Peer peer) => false;
  @override
  bool get linkedToSomeone => false;
  @override
  Future<Handed> sendLinked(Peer peer, Uint8List packet) async => throw CarrierError('no link to them is open now');
  @override
  Future<Handed> sendOn(Peer peer, Object? line, Uint8List packet) async => throw CarrierError('no link to them is open now');
  void take(Uint8List packet, {String? from}) => _arrived.add(Arrived(id, packet, from: from));
}

/// Who a switchboard knows, by name.
class _Book implements PeerBook {
  _Book(this.by);
  final Map<String, Peer> by;
  @override
  Peer? byId(String id) => by[id];
}

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.stop());

  group('telling each other where we are', () {
    test('two installs that are friends tell each other their cards through the relay once, and not again when they start again', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      final cardA = a.p2p.card!, cardB = b.p2p.card!;
      // Each made its node key, kept it with its secrets, and its card names the node id that key makes.
      final key = _nodeKey(a);
      expect(key, hasLength(32));
      expect([cardA.account, cardA.device, cardA.nodeId], [a.account.id, a.device, FakeP2pNode.idFor(key)]);
      expect(a.plain.kept.values.join(), isNot(contains(NetCrypto.hex(key))), reason: 'the node key is in no choice');
      // And each holds the other's, heard once.
      expect(a.p2p.devicesOf(b.account.id).single.card, cardB);
      expect(b.p2p.devicesOf(a.account.id).single.card, cardA);
      expect([a.heard, b.heard], [['card from sam'], ['card from maya']]);
      expect([a.p2p.friendsDevices, a.p2p.ownDevices], [1, 0]);
      // The node lets in the devices cards are held for, on the packets channel, and nobody else.
      expect(a.node.allowed, {cardB.nodeId: _packets});
      expect(b.node.allowed, {cardA.nodeId: _packets});
      // A phone's node was started for none of it, and nothing was dialled.
      expect([a.node.starts, b.node.starts, w.mesh.dials], [0, 0, isEmpty]);
      expect(_kept(a, P2p.toldName)[b.account.id], containsPair('c', cardA.tag));

      // Both apps close and open again: the cards are still held, the nodes let the same devices in, and nothing more
      // is said.
      await a.restart();
      await b.restart();
      await w.clock.pass(const Duration(minutes: 5));
      expect([a.heard, b.heard], [['card from sam'], ['card from maya']], reason: 'told once, not at every start');
      expect([a.p2p.card, b.p2p.card], [cardA, cardB]);
      expect(a.p2p.devicesOf(b.account.id).single.card, cardB);
      expect(a.node.allowed, {cardB.nodeId: _packets});
      expect(a.node.starts, 0);
    });

    test('one who starts while the other is away is told when they come, each still once', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      expect(w.memory.hub.heldFor(b.account.id), 0, reason: 'nothing is kept for them by the relay: they are told when they come');
      // A while later the other opens the app: told as it signs in, whether or not it has read its own yet.
      await w.clock.pass(const Duration(seconds: 20));
      await b.start();
      expect(b.p2p.devicesOf(a.account.id).single.card, a.p2p.card);
      expect(a.p2p.devicesOf(b.account.id).single.card, b.p2p.card);
      expect([a.heard, b.heard], [['card from sam'], ['card from maya']]);
      await w.clock.pass(const Duration(days: 2));
      expect([a.heard, b.heard], [['card from sam'], ['card from maya']], reason: 'each holds the other\'s: nothing more to say or ask');
    });

    test('two that tell each other at the same moment each answer once, and then nothing more is said, at any later start either', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      // The relay is not there as they start, and comes back for both at once.
      w.memory.down = true;
      await a.start();
      await b.start();
      expect([a.heard, b.heard], [isEmpty, isEmpty]);
      await w.relayBack();
      // Each told the other not yet holding theirs, so each was answered: a card and an answer each way.
      expect([a.heard, b.heard], [['card from sam', 'card from sam'], ['card from maya', 'card from maya']]);
      expect(a.got.map((r) => r.envelope.body['h']), [isEmpty, [a.p2p.card!.tag]], reason: 'the answer says it holds this device\'s card');
      await w.clock.pass(const Duration(days: 2));
      await a.restart();
      await b.restart();
      await w.clock.pass(const Duration(days: 2));
      expect([a.heard.length, b.heard.length], [2, 2]);
    });

    test('someone told who never says theirs is asked half a minute on and once a week after; when they do say it, it is taken and not answered', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      // Sam has Direct switched off.
      await a.start();
      await b.start();
      await b.board.setOn('p2p', false);
      await w.settle();
      a.friends.remove(b.account);
      await a.p2p.refresh();
      a.friends.add(b.account);
      await a.p2p.refresh();
      await w.settle();
      final heard = b.heard.length;
      expect(a.p2p.devicesOf(b.account.id), isEmpty, reason: 'switched off, a device says nothing of itself');
      expect(b.p2p.devicesOf(a.account.id), hasLength(1), reason: 'but takes what it is told, to have it when it is switched on');
      await w.clock.pass(const Duration(seconds: 30));
      expect(b.heard.sublist(heard), isEmpty);
      await w.clock.pass(const Duration(seconds: 2));
      expect(b.heard.sublist(heard), ['card? from maya']);
      // Not again that week, however often the app starts.
      await w.clock.pass(const Duration(days: 6));
      await a.restart();
      expect(b.heard.sublist(heard), ['card? from maya']);
      await w.clock.pass(const Duration(days: 1, minutes: 1));
      await a.restart();
      expect(b.heard.sublist(heard), ['card? from maya', 'card? from maya']);
      expect(a.p2p.devicesOf(b.account.id), isEmpty);
      // Switched on: it tells its card, holding Maya's already, and that is the end of it.
      final before = a.heard.length;
      await b.board.setOn('p2p', true);
      await w.settle();
      expect(a.heard.sublist(before), ['card from sam']);
      expect(a.p2p.devicesOf(b.account.id).single.card, b.p2p.card);
      await w.clock.pass(const Duration(minutes: 5));
      expect(b.heard.sublist(heard), hasLength(2));
    });

    // The second review, S13: cards and asks go through the relay, which keeps them for someone away (a mailbox of 200
    // packets or a MiB, refusing new ones when full); and once asked, a "card?" went every week for ever, so a friend on
    // an old build got one a week from every friend with Direct on.
    test('a friend who never answers is asked three times and no more; nothing is said to a friend the relay says is away, and they are told when they come', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      // Sam is not there as Maya's app starts: nothing is kept for him by the relay.
      await a.start();
      await w.clock.pass(_minute);
      expect(w.memory.hub.heldFor(b.account.id), 0);
      // He comes, with Direct switched off (as a build with none would be): told, and never answering.
      b.startOff = true;
      await b.start();
      await w.settle();
      expect(b.heard, ['card from maya']);
      for (var week = 0; week < 6; week++) {
        await w.clock.pass(const Duration(days: 7, minutes: 1));
        await a.restart();
      }
      expect(b.heard.where((h) => h == 'card? from maya'), hasLength(P2p.mostAsks));
      // He goes away: a card made anew is not told him, nor kept for him; he is told when he comes back.
      await b.stop();
      await w.settle();
      a.secrets.kept.remove(P2p.keyName);
      await a.restart();
      await w.clock.pass(_minute);
      expect(w.memory.hub.heldFor(b.account.id), 0);
      final heard = b.heard.length;
      await b.start();
      await w.settle();
      expect(b.heard.sublist(heard), ['card from maya']);
      // Once his own card comes, he may be asked again if it is ever needed: what was counted of him starts over.
      await b.board.setOn('p2p', true);
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id), hasLength(1));
    });

    test('a card is taken only from a sealed envelope whose sender is the account it names, and only from a friend', () async {
      final maya = w.account('maya'), sam = w.account('sam'), dan = w.account('dan'), eve = w.account('eve');
      final a = w.install(maya), b = w.install(sam), d = w.install(dan), e = w.install(eve);
      w.friends(a, b);
      // Dan has asked to be a friend: a key is held for him and the routes reach him, but he is not one. He holds Maya
      // to be his.
      a.known.add(dan);
      d.friends.add(maya);
      // Eve is nobody to Maya, and tries all the same.
      e.friends.add(maya);
      for (final i in [a, b, d, e]) {
        await i.start();
      }
      expect(a.got.where((r) => r.peer.id == dan.id && r.envelope.kind == P2p.kind), hasLength(1), reason: 'Dan\'s card came, sealed with his key');
      expect(a.p2p.devicesOf(dan.id), isEmpty, reason: 'and was not taken: he is not a friend');
      expect(a.p2p.devicesOf(eve.id), isEmpty);
      expect(a.node.allowed.keys, [b.p2p.nodeId]);
      // Nor were they told anything: where this device is goes to friends only.
      expect([d.heard, e.heard], [isEmpty, isEmpty]);
      expect([d.p2p.devicesOf(maya.id), e.p2p.devicesOf(maya.id)], [isEmpty, isEmpty]);

      // From a friend, but not sealed: a card for another device of his, good in itself.
      final second = await _cardOf(w, sam);
      await b.board.send(b.to(maya), _said(w, _telling(a, second)), sealed: false, only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(sam.id), hasLength(1), reason: 'in the clear, it is anyone\'s');
      // From a friend and sealed, but naming another account: Eve's own card, and one for Maya's own account.
      for (final card in [e.p2p.card!, a.p2p.card!]) {
        for (final what in ['card', 'meet']) {
          await b.board.send(b.to(maya), _said(w, _telling(a, card, what: what)), only: {'hub'});
        }
      }
      await w.settle();
      expect(a.p2p.devicesOf(eve.id), isEmpty);
      expect(a.p2p.devicesOf(maya.id), isEmpty);
      expect(a.p2p.devicesOf(sam.id), hasLength(1));
      expect(a.node.allowed.keys, [b.p2p.nodeId]);
      expect(a.node.starts, 0, reason: 'a meet with someone else\'s card brings nothing up');
      // What it takes: his own card, in his own sealed envelope.
      await b.board.send(b.to(maya), _said(w, _telling(a, second)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(sam.id).map((x) => x.card), containsAll([b.p2p.card, second]));
      expect(a.node.allowed.keys, unorderedEquals([b.p2p.nodeId, second.nodeId]));
    });

    test('a friend removed or blocked: their cards go, their devices are let in no longer, and they are told nothing more', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      expect((await a.text(b.account, 'before')).acked, isTrue);
      expect(a.p2p.carrier.lines, greaterThan(0));
      // Removed, or blocked: no longer among the people.
      a.friends.remove(b.account);
      await a.p2p.refresh();
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id), isEmpty);
      expect(a.node.allowed, isEmpty);
      expect([a.p2p.carrier.lines, b.p2p.carrier.lines], [0, 0], reason: 'the stream between them was closed');
      expect(_kept(a, P2p.cardsName), isEmpty);
      expect(_kept(a, P2p.toldName).keys, [a.account.id], reason: 'only its own account is still down as told');
      // Their device is turned away from now on.
      final sending = b.text(a.account, 'hello?', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await sending).sent, isFalse);
      // Friends again: told again, as holding none of theirs, so their device says its card again.
      await w.relayBack();
      final heard = [a.heard.length, b.heard.length];
      a.friends.add(b.account);
      await a.p2p.refresh();
      await w.settle();
      expect([a.heard.sublist(heard[0]), b.heard.sublist(heard[1])], [['card from sam'], ['card from maya']]);
      expect(a.p2p.devicesOf(b.account.id).single.card, b.p2p.card);
      expect(a.node.allowed.keys, [b.p2p.nodeId]);
    });

    test('at most eight devices are kept for one friend, the one heard from longest ago going first, and its node is let in no longer', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      final cards = <DeviceCard>[];
      for (var i = 0; i < 9; i++) {
        await w.clock.pass(_minute);
        cards.add(await _cardOf(w, b.account));
        await b.board.send(b.to(a.account), _said(w, _telling(a, cards.last)), only: {'hub'});
        await w.settle();
      }
      final held = a.p2p.devicesOf(b.account.id);
      expect(held, hasLength(P2p.mostDevices));
      // The eight heard from latest stay: the last eight made up. His real device, heard from first, went when the
      // ninth card came.
      expect(held.map((d) => d.card), unorderedEquals(cards.sublist(1)));
      expect(a.node.allowed.keys, unorderedEquals(cards.sublist(1).map((c) => c.nodeId)));
      expect((jsonDecode(a.plain.kept[P2p.cardsName]!) as Map)[b.account.id], hasLength(8));
      // Maya's device asks, as it does once a week, saying which of his cards it holds. His real device is not among
      // them, so it says its card again and is back, in place of the longest unheard: only a device that says nothing
      // more is forgotten.
      await w.clock.pass(_minute);
      final heard = a.heard.length;
      await a.board.send(a.to(b.account), _said(w, {'t': 'card?', 'h': [for (final d in a.p2p.devicesOf(b.account.id)) d.card.tag]}), only: {'hub'});
      await w.settle();
      expect(a.heard.sublist(heard), ['card from sam']);
      expect(a.p2p.devicesOf(b.account.id).map((d) => d.card), unorderedEquals([b.p2p.card, ...cards.sublist(2)]));
      // Asked again now that it is held, it says nothing.
      await a.board.send(a.to(b.account), _said(w, {'t': 'card?', 'h': [b.p2p.card!.tag]}), only: {'hub'});
      await w.settle();
      expect(a.heard.sublist(heard), ['card from sam']);
      // An older card for a device than the one held, for the same node, is a copy from before: not taken. One for
      // another node is taken (a device whose clock went back), and Sam's account asked at once in case it is a copy.
      final device = cards.last.device;
      final sameNode = await DeviceCard.make(KeysSigner(b.account.keys), device: device, nodeId: cards.last.nodeId, now: w.clock.now().subtract(const Duration(hours: 1)));
      await b.board.send(b.to(a.account), _said(w, _telling(a, sameNode)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id).firstWhere((d) => d.card.device == device).card, cards.last);
      final asked = b.heard.length;
      final otherNode = await DeviceCard.make(KeysSigner(b.account.keys), device: device, nodeId: NetCrypto.hex(NetCrypto.randomBytes(32)), now: w.clock.now().subtract(const Duration(hours: 1)));
      await b.board.send(b.to(a.account), _said(w, _telling(a, otherNode)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id).firstWhere((d) => d.card.device == device).card, otherNode);
      expect(b.heard.sublist(asked), ['card? from maya']);
    });

    test('a card that runs out is dropped and its node let in no longer; a device makes its own again with a week left and tells it once', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      final first = a.p2p.card!;
      // A card of a device that is never heard from again.
      final gone = await _cardOf(w, b.account);
      await b.board.send(b.to(a.account), _said(w, _telling(a, gone)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id), hasLength(2));
      expect([a.heard.length, b.heard.length], [2, 1]);
      // Twenty-three days on a week is left: each makes a new card and tells the other, once.
      await w.clock.pass(const Duration(days: 22));
      expect([a.p2p.card, a.heard.length, b.heard.length], [first, 2, 1]);
      await w.clock.pass(const Duration(days: 1, minutes: 1));
      final next = a.p2p.card!;
      expect(next, isNot(first));
      expect([next.nodeId, next.device, next.made > first.made], [first.nodeId, first.device, true]);
      expect(b.p2p.devicesOf(a.account.id).single.card, next);
      expect([a.heard.length, b.heard.length], [3, 2], reason: 'the new card, told once and not answered');
      expect(jsonDecode(a.plain.kept[P2p.cardName]!), next.toJson());
      // Thirty days after it was made the other device's card has run out.
      await w.clock.pass(const Duration(days: 7));
      expect(a.p2p.devicesOf(b.account.id).map((d) => d.card.device), [b.device]);
      expect(a.node.allowed.keys, [b.p2p.nodeId]);
      expect(a.plain.kept[P2p.cardsName], isNot(contains(gone.nodeId)));
    });

    // From the second review's notes: a device whose clock went back could not replace its card for up to 30 days, and
    // the cards of a friend's earlier installs were dialled for as long.
    test('an "older" card for another node is taken, and the account asked at once in case it is a copy from before; an install not heard from in sixteen days, while another of theirs has been, is not dialled', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      final current = b.p2p.card!;
      // A device of Sam's made itself a new node key while its clock was ten days behind: its new card is "older" than
      // the one held for it. (Here no device of his contradicts it: his has Direct switched off for the moment.)
      await b.board.setOn('p2p', false);
      final behind = await DeviceCard.make(KeysSigner(b.account.keys), device: b.device, nodeId: 'ab' * 32, now: w.clock.now().subtract(const Duration(days: 10)));
      final heard = b.heard.length;
      await b.board.send(b.to(a.account), _said(w, _telling(a, behind)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id).single.nodeId, 'ab' * 32, reason: 'taken: another node');
      // And Sam's account was asked at once, saying which card is held, in case it is a copy from before.
      expect(b.heard.sublist(heard), ['card? from maya']);
      // A copy from before, older still and naming yet another node: taken, asked, and Sam's device, whose own card is
      // newer, says it again. That is the one held.
      await b.board.setOn('p2p', true);
      final before = await DeviceCard.make(KeysSigner(b.account.keys), device: b.device, nodeId: 'cd' * 32, now: w.clock.now().subtract(const Duration(days: 12)));
      await b.board.send(b.to(a.account), _said(w, _telling(a, before)), only: {'hub'});
      await w.settle();
      expect(b.heard.sublist(heard), ['card? from maya', 'card? from maya']);
      expect(a.p2p.devicesOf(b.account.id).single.card, current);
      // The same card for the same node, older than the one held: a copy from before, and nothing is asked.
      final older = await DeviceCard.make(KeysSigner(b.account.keys), device: b.device, nodeId: current.nodeId, now: w.clock.now().subtract(const Duration(days: 2)));
      await b.board.send(b.to(a.account), _said(w, _telling(a, older)), only: {'hub'});
      await w.settle();
      expect([a.p2p.devicesOf(b.account.id).single.card, b.heard.sublist(heard).length], [current, 2]);

      // An install of Sam's from before (the app put back on a phone): its card is good for weeks, nobody is there.
      final gone = w.mesh.node();
      await gone.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
      w.mesh.unreachable(gone);
      await b.board.send(b.to(a.account), _said(w, _telling(a, await _cardOf(w, b.account, node: gone.nodeId), where: gone.whereabouts.value!.toJson())), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id), hasLength(2));
      await w.clock.pass(const Duration(days: 17));
      // Sam's real device is heard from again (a link with it, proved), the other not.
      await w.relayGone();
      expect((await b.text(a.account, 'still me', only: {'p2p'})).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 3));
      final dials = w.mesh.dialsTo(gone.nodeId!);
      final d = await a.text(b.account, 'to his devices', only: {'p2p'});
      expect(d.acked, isTrue);
      await w.clock.pass(const Duration(seconds: 5));
      expect(w.mesh.dialsTo(gone.nodeId!) - dials, 0, reason: 'not dialled: not heard from in seventeen days, while his other device was today');
    });

    test('a card that can\'t be signed (a keystore that refuses) is tried again ten minutes on, not at once, and told then', () async {
      final a = w.install(w.account('maya'))..signFails = true, b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      expect([a.p2p.card, a.signs, b.heard], [null, 1, isEmpty]);
      expect(a.p2p.devicesOf(b.account.id), hasLength(1), reason: 'what it is told is taken all the same');
      expect(a.p2p.carrier.state.value, CarrierState.up);
      // Nothing it hears makes it ask the keystore again before its time.
      await b.board.send(b.to(a.account), _said(w, const {'t': 'card?'}), only: {'hub'});
      await w.clock.pass(const Duration(minutes: 9, seconds: 58));
      expect([a.p2p.card, a.signs], [null, 1]);
      a.signFails = false;
      await w.clock.pass(const Duration(seconds: 4));
      expect(a.signs, 2);
      expect(a.p2p.card!.account, a.account.id);
      expect(b.p2p.devicesOf(a.account.id).single.card, a.p2p.card, reason: 'and told once it was made');
      expect(a.signs, 2, reason: 'signed once for as long as the card is good');
      await a.restart();
      await w.clock.pass(const Duration(days: 1));
      expect(a.signs, 2);
    });

    test('a node key made again makes another node id and another card, told again; the friend lets the new node in and not the old', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      final old = a.p2p.card!;
      await w.clock.pass(const Duration(minutes: 2));
      a.secrets.kept.remove(P2p.keyName);
      await a.restart();
      final now = a.p2p.card!;
      expect(now.nodeId, isNot(old.nodeId));
      expect(now.nodeId, FakeP2pNode.idFor(_nodeKey(a)));
      expect(b.p2p.devicesOf(a.account.id).single.card, now, reason: 'in place of the old one: the same device');
      expect(b.node.allowed.keys, [now.nodeId]);
      // The friend's card was kept through it, and the new card said so: there was nothing to answer.
      expect(a.heard, ['card from sam']);
      expect(a.p2p.devicesOf(b.account.id).single.card, b.p2p.card);
    });

    test('asked, a device says its card; what it says to one account in an hour has a limit, whatever is asked of it', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.clock.pass(const Duration(hours: 2));
      for (var i = 0; i < 20; i++) {
        await b.board.send(b.to(a.account), _said(w, const {'t': 'card?'}), only: {'hub'});
      }
      await w.settle();
      expect(b.heard.where((h) => h == 'card from maya'), hasLength(1 + const P2pPolicy().saysAnHour));
      // An hour on it answers again.
      await w.clock.pass(const Duration(hours: 1));
      await b.board.send(b.to(a.account), _said(w, const {'t': 'card?'}), only: {'hub'});
      await w.settle();
      expect(b.heard.where((h) => h == 'card from maya'), hasLength(2 + const P2pPolicy().saysAnHour));
    });

    test('no more than thirty of one friend\'s cards are looked at in an hour, however many they send', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.clock.pass(const Duration(hours: 2));
      final checked = NetCrypto.verifications, writes = a.plain.writes;
      DeviceCard? last;
      for (var i = 0; i < 40; i++) {
        last = await _cardOf(w, b.account);
        await b.board.send(b.to(a.account), _said(w, _telling(a, last)), only: {'hub'});
      }
      await w.settle();
      // (Each card made above was checked once as it was made, by its maker.)
      expect(NetCrypto.verifications - checked, 40 + 30, reason: 'thirty looked at here, and the rest passed over unchecked');
      expect(a.plain.writes - writes, 2 * 30, reason: 'and what is kept (the cards, and the seal on them) was written as often, no more');
      expect(a.p2p.devicesOf(b.account.id).map((d) => d.card), isNot(contains(last)));
      // An hour on, they are looked at again.
      await w.clock.pass(const Duration(hours: 1));
      await b.board.send(b.to(a.account), _said(w, _telling(a, last!)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id).map((d) => d.card), contains(last));
    });

    // The second review, S15: every kept card's signature was checked again at each start, friends times devices P-256
    // checks on every cold start of a phone.
    test('what was checked is not checked again at each start: the kept cards carry a seal only this device can make, and any change to them has each checked anew', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      for (var i = 0; i < 4; i++) {
        await b.board.send(b.to(a.account), _said(w, _telling(a, await _cardOf(w, b.account))), only: {'hub'});
      }
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id), hasLength(5));
      var checked = NetCrypto.verifications;
      await a.restart();
      expect(NetCrypto.verifications - checked, 1, reason: 'its own card alone, as ever; none of the five it holds');
      expect(a.p2p.devicesOf(b.account.id), hasLength(5));
      // One of them changed while the app was closed (a device's word put in its place): the seal no longer fits, every
      // card is checked again, and the one whose signature is not its account's goes.
      await a.stop();
      final kept = jsonDecode(a.plain.kept[P2p.cardsName]!) as Map;
      final list = (kept[b.account.id] as List).cast<Map>();
      final forged = Map<String, dynamic>.from(list.last['c'] as Map)..['n'] = 'ee' * 32;
      list.last['c'] = forged;
      a.plain.kept[P2p.cardsName] = jsonEncode(kept);
      checked = NetCrypto.verifications;
      await a.start();
      expect(NetCrypto.verifications - checked, 1 + 5);
      expect(a.p2p.devicesOf(b.account.id), hasLength(4));
      expect(a.p2p.devicesOf(b.account.id).map((d) => d.nodeId), isNot(contains('ee' * 32)));
      // Sealed anew for what is kept now: the next start checks none again.
      checked = NetCrypto.verifications;
      await a.restart();
      expect(NetCrypto.verifications - checked, 1);
      // A seal made with another key (another node key: another account, or a key made again) fits nothing.
      a.plain.kept[P2p.checkedName] = 'ab' * 32;
      checked = NetCrypto.verifications;
      await a.restart();
      expect([NetCrypto.verifications - checked, a.p2p.devicesOf(b.account.id).length], [1 + 4, 4]);
    });

    // The second review: friends' addresses sat in plain choices (p2p_cards), which a device's backup copies.
    test('where friends\' devices are is kept where the install keeps its keys, not with its choices, so no backup carries it', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      final where = b.node.whereabouts.value!.addresses.single;
      expect(a.p2p.devicesOf(b.account.id).single.where!.addresses, [where]);
      expect(a.plain.kept.values.join(), isNot(contains(where)));
      expect(a.secrets.kept[P2p.whereName], contains(where));
      // And it is there after a start.
      await a.restart();
      expect(a.p2p.devicesOf(b.account.id).single.where!.addresses, [where]);
      // Signing out takes it with the rest.
      await a.p2p.wipe();
      expect(a.secrets.kept[P2p.whereName] ?? '', isEmpty);
    });

    test('nothing is said of where a phone is while its node is down; a computer says it with its card; never by a route of small packets', () async {
      // A route of small packets that costs nothing, so that it is its size alone that keeps cards off it.
      const small = CarrierTraits(maxPacket: 133, maxParts: 6, live: false);
      final sms = (PlainCarrier('sms', traits: small), PlainCarrier('sms', traits: small));
      sms.$1.twin = sms.$2;
      sms.$2.twin = sms.$1;
      final a = w.install(w.account('maya'), also: [sms.$1]), b = w.install(w.account('sam'), computer: true, also: [sms.$2]);
      w.friends(a, b);
      // The relay is not there as they start: only the route of data texts is up.
      w.memory.down = true;
      await a.start();
      await b.start();
      await w.clock.pass(_minute);
      expect([sms.$1.state.value, sms.$1.carried, sms.$2.carried], [CarrierState.up, isEmpty, isEmpty], reason: 'a card is never sent in small packets');
      expect([a.heard, b.heard], [isEmpty, isEmpty]);
      await w.relayBack();
      expect([a.heard.toSet(), b.heard.toSet()], [{'card from sam'}, {'card from maya'}]);
      expect(sms.$1.carried, isEmpty);
      expect(b.p2p.devicesOf(a.account.id).single.where, isNull, reason: 'a phone\'s node is down: it is nowhere to be found');
      final where = a.p2p.devicesOf(b.account.id).single.where!;
      expect(where.addresses, b.node.whereabouts.value!.addresses);
      expect(where.helper, isNull);
      // A card that comes by the route of small packets is not looked at, though it is sealed and a friend's.
      final second = await _cardOf(w, b.account);
      await b.board.send(b.to(a.account), _said(w, _telling(a, second)), only: {'sms'});
      await w.settle();
      expect(sms.$2.carried, isNotEmpty);
      expect(a.got.last.via, 'sms');
      expect(a.p2p.devicesOf(b.account.id), hasLength(1));
      // The same by the relay is taken.
      await b.board.send(b.to(a.account), _said(w, _telling(a, second)), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(b.account.id), hasLength(2));
    });

    test('where a device says it is, is held to what a node can use: addresses that are addresses, a link helper only of this device\'s own relay', () async {
      w = World(helpers: [_helper]);
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      expect(a.p2p.helpers, [_helper]);
      Future<Whereabouts?> told(Map<String, dynamic> where) async {
        await w.clock.pass(_second);
        await b.board.send(b.to(a.account), _said(w, _telling(a, b.p2p.card!, where: where)), only: {'hub'});
        await w.settle();
        final d = a.p2p.devicesOf(b.account.id).single;
        return a.p2p.hintFor(d);
      }

      // Nothing said: this device's own link helper is what there is to try.
      expect(a.p2p.devicesOf(b.account.id).single.where, isNull);
      expect(a.p2p.hintFor(a.p2p.devicesOf(b.account.id).single), const Whereabouts(helper: _helper));
      var hint = await told({'r': 'https://evil.example', 'a': ['10.1.2.3:4000', 'not an address', '10.1.2.3', '10.1.2.3:99999', '[2001:db8::7]:4001', 'example.com:80', '300.1.1.1:5'], 't': w.clock.ms});
      expect(hint!.addresses, ['10.1.2.3:4000', '[2001:db8::7]:4001']);
      expect(hint.helper, _helper, reason: 'a server someone else names is never connected to');
      hint = await told({'r': _helper, 'a': ['192.168.1.9:1234'], 't': w.clock.ms});
      expect([hint!.helper, hint.addresses], [_helper, ['192.168.1.9:1234']]);
      // Older word of where it is does not take the place of newer.
      hint = await told({'a': ['192.168.1.1:1'], 't': w.clock.ms - 60000});
      expect(hint!.addresses, ['192.168.1.9:1234']);
      // "Only through link helpers": no address of theirs is dialled, and none of this device's own is told.
      await a.p2p.setHelpersOnly(true);
      expect(a.p2p.hintFor(a.p2p.devicesOf(b.account.id).single), const Whereabouts(helper: _helper));
      expect(P2p.isAddress('1.2.3.4:5'), isTrue);
      for (final bad in ['1.2.3.4', '1.2.3.4:', '1.2.3.4:0', '1.2.3.4:+5', ':5', 'host:5', '[::1]', '1.2.3:5', '[zz::1]:5']) {
        expect(P2p.isAddress(bad), isFalse, reason: bad);
      }
      expect(P2p.tidyHelpers(['https://a.example', 'http://b.example', 'https://', 'https://user:pw@c.example', 7, 'https://${'x' * 200}.example', 'https://a.example', 'https://d.example', 'https://e.example', 'https://f.example', 'https://g.example']),
          ['https://a.example', 'https://d.example', 'https://e.example', 'https://f.example']);
    });
  });

  // The second review, S9 (R2-I): any IP and port a friend's device said was dialled, loopback, multicast and the
  // cloud's metadata address among them.
  test('only addresses a device can be reached at are dialled: not loopback, unspecified, multicast, broadcast or link-local, in any form; a private network is', () {
    for (final bad in [
      '127.0.0.1:22', '127.1.2.3:80', '0.0.0.0:1', '0.1.2.3:5', '255.255.255.255:9', '224.0.0.251:5353', '239.255.255.250:1900', '169.254.169.254:80', '169.254.1.1:5',
      '240.0.0.1:5', // reserved, as the broadcast address is
      '[::1]:6379', '[::]:1', '[ff02::1]:5353', '[ff05::2]:5', '[fe80::1]:5', '[febf::1]:5',
      '[::ffff:127.0.0.1]:80', '[::ffff:169.254.169.254]:80', '[::ffff:224.0.0.1]:5', '[::ffff:0.0.0.0]:5', '[::ffff:7f00:1]:80', '[::127.0.0.1]:80',
    ]) {
      expect(P2p.isAddress(bad), isFalse, reason: bad);
    }
    for (final good in ['10.1.2.3:4000', '192.168.1.9:1234', '172.16.0.1:5', '100.64.0.1:5', '8.8.8.8:53', '[2001:db8::7]:4001', '[fd00::1]:5', '[fec0::1]:5', '[::ffff:192.168.1.9]:5']) {
      expect(P2p.isAddress(good), isTrue, reason: good);
    }
  });

  group('the route', () {
    test('is called Direct, comes after the relay, and reaches only those a good card is held for', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      final stranger = w.account('zed');
      w.friends(a, b);
      await a.start();
      final c = a.p2p.carrier;
      expect([c.id, c.name], ['p2p', 'Direct']);
      // What switching it on means (Matt's brief, 2026-11-23): who learns this device's address, who is told, and what a
      // link helper sees. The row drawn before the route is made says the same (Settings › Routes).
      expect(c.about, 'Straight between your devices and your friends\', for when the relay server can\'t carry something. Their devices learn this device\'s network address, and nobody else is told it. A link helper sees which devices link and how much they send, never who they are or what is said.');
      expect([c.id, c.name, c.about], [P2pCarrier.routeId, P2pCarrier.label, P2pCarrier.aboutWords]);
      expect([c.traits.maxPacket, c.traits.metered, c.traits.live, c.traits.wakes], [HubCarrier.maxPacket, false, true, false]);
      expect(a.board.carriers.map((r) => r.id), ['hub', 'p2p']);
      expect(c.state.value, CarrierState.up, reason: 'ready, though a phone\'s node is down until there is something to say');
      expect(c.reaches(a.to(b.account)), isFalse, reason: 'no card held for them yet');
      await b.start();
      expect(c.reaches(a.to(b.account)), isTrue);
      expect(c.reaches(Peer(id: stranger.id)), isFalse);
      expect(c.reaches(a.mine), isFalse, reason: 'no other device of this account');
      // Switched off, it reaches nobody and its node is stopped; on again, it is as it was.
      await a.board.setOn('p2p', false);
      expect([c.state.value, c.reaches(a.to(b.account))], [CarrierState.off, false]);
      await expectLater(c.send(a.to(b.account), Uint8List(20)), throwsA(isA<CarrierError>()));
      await a.board.setOn('p2p', true);
      expect([c.state.value, c.reaches(a.to(b.account))], [CarrierState.up, true]);
    });

    test('with the relay taken away, a text goes by the direct route and is answered, and one comes back the same way', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      expect([a.hub.state.value, b.hub.state.value], [CarrierState.down, CarrierState.down]);
      final d = await a.text(b.account, 'are you there');
      expect([d.via, d.handed, d.acked], ['p2p', Handed.passed, true]);
      expect(d.tried, ['p2p']);
      expect(b.texts, ['are you there']);
      expect(b.got.last.via, 'p2p');
      expect(b.got.last.peer.id, a.account.id);
      // Dialled once, by where their card said they were, and the path is straight.
      expect(w.mesh.dials, hasLength(1));
      expect(w.mesh.dials.single.hint!.addresses, b.node.whereabouts.value!.addresses);
      expect(a.node.pathTo(b.p2p.nodeId!)!.kind, P2pPathKind.direct);
      expect(a.p2p.carrier.links.single, (account: b.account.id, nodeId: b.p2p.nodeId!, kind: P2pPathKind.direct));
      // The answer comes back on the stream that is open: nothing more is dialled.
      final back = await b.text(a.account, 'here');
      expect([back.via, back.acked], ['p2p', true]);
      expect(a.texts, ['here']);
      expect(w.mesh.dials, hasLength(1));
      // What crossed is sealed: none of the words are in any frame, and the node saw nothing but frames.
      expect(a.got.last.sealed, isTrue);
    });

    test('two phones with a link helper find each other once the relay has been gone fifteen seconds, with the app in use', () async {
      w = World(helpers: [_helper]);
      final a = w.install(w.account('maya')), b = w.install(w.account('sam')), c = w.install(w.account('cleo'));
      w.friends(a, b);
      w.friends(a, c);
      for (final i in [a, b, c]) {
        await i.start();
      }
      // Cleo's phone has the app put away.
      c.p2p.setAway(true);
      await w.relayGone();
      await w.clock.pass(const Duration(seconds: 14));
      expect([a.node.starts, b.node.starts, c.node.starts], [0, 0, 0]);
      await w.clock.pass(const Duration(seconds: 1));
      expect([a.node.state.value, b.node.state.value, c.node.state.value], [P2pState.up, P2pState.up, P2pState.off], reason: 'each in use brought its node up by itself');
      expect(a.node.config!.helpers, [_helper]);
      // Neither had said where it is (a phone's node is down as it tells its card): each tried the other through the
      // link helper their relay named to both.
      expect(a.p2p.carrier.linked(a.to(b.account)), isTrue);
      expect(a.node.pathTo(b.p2p.nodeId!)!.kind, P2pPathKind.helper);
      expect(a.p2p.carrier.linked(a.to(c.account)), isFalse);
      final d = await a.text(b.account, 'the relay is down');
      expect([d.via, d.acked], ['p2p', true]);
      expect(b.texts, ['the relay is down']);
      // The relay back: it carries again, and the node was told the network changed each time.
      await w.relayBack();
      expect((await a.text(b.account, 'and back')).via, 'hub');
      expect(a.node.networkChanges, greaterThan(0));
    });

    test('with the relay gone and the app in use a phone\'s node stays up, as there is nothing else to be reached by; put away, it stops two minutes later', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      await w.clock.pass(const Duration(seconds: 15));
      expect([a.node.now, a.p2p.carrier.linked(a.to(b.account))], [P2pState.up, isTrue]);
      // Ten minutes on, nothing said either way: still up.
      for (var i = 0; i < 10; i++) {
        await w.clock.pass(_minute);
      }
      expect([a.node.now, a.node.stops], [P2pState.up, 0]);
      expect((await b.text(a.account, 'still there?', only: {'p2p'})).acked, isTrue);
      // Put away: two minutes later it stops.
      a.p2p.setAway(true);
      await w.clock.pass(const Duration(seconds: 119));
      expect(a.node.now, P2pState.up);
      await w.clock.pass(_second);
      expect(a.node.now, P2pState.off);
    });

    test('a packet goes to both devices of a friend; one unreachable still counts as passed; none reachable throws, and the switchboard goes on', () async {
      final lan = PlainCarrier.pair('lan');
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true, also: [lan.$1]);
      final b1 = w.install(sam, computer: true, also: [lan.$2]), b2 = w.install(sam, computer: true);
      for (final b in [b1, b2]) {
        w.friends(a, b);
      }
      for (final i in [a, b1, b2]) {
        await i.start();
      }
      expect(a.p2p.devicesOf(sam.id).map((d) => d.nodeId), unorderedEquals([b1.p2p.nodeId, b2.p2p.nodeId]));
      expect([b1.p2p.ownDevices, b2.p2p.ownDevices], [1, 1], reason: 'and the two know each other as their account\'s own');
      // (Nobody is at any of the three: none goes looking for the others by itself once the relay has been gone a
      // while, so what is dialled below is dialled for a send.)
      for (final i in [a, b1, b2]) {
        i.p2p.setAway(true);
      }
      await w.relayGone();
      var d = await a.text(sam, 'to both');
      expect([d.via, d.acked], ['p2p', true]);
      await w.settle();
      expect([b1.texts, b2.texts], [['to both'], ['to both']]);
      expect(a.p2p.carrier.links.map((l) => l.nodeId), unorderedEquals([b1.p2p.nodeId, b2.p2p.nodeId]));

      // One of them falls off the network: the other takes it at once, and that is passed.
      w.mesh.unreachable(b2.node);
      d = await a.text(sam, 'to one');
      expect([d.via, d.handed, d.acked], ['p2p', Handed.passed, true]);
      expect([b1.texts.last, b2.texts.last], ['to one', 'to both']);
      // The other was still being tried, for the five seconds a send has.
      expect(a.dialled(b2), 2);
      await w.clock.pass(const Duration(seconds: 5));
      // And is not dialled again for a while: what is sent meanwhile does not wait on it.
      d = await a.text(sam, 'again');
      expect(d.acked, isTrue);
      await w.clock.pass(const Duration(seconds: 5));
      expect(a.dialled(b2), 2);

      // Neither can be reached: the route says so after its five seconds, and the next route carries it.
      w.mesh.unreachable(b1.node);
      final sending = a.text(sam, 'by another way');
      await w.clock.pass(const Duration(milliseconds: 4999));
      expect(b1.texts.last, 'again', reason: 'still trying the direct way');
      await w.clock.pass(const Duration(milliseconds: 1));
      d = await sending;
      expect(d.tried, ['p2p: none of their devices could be reached directly', 'lan']);
      expect([d.via, d.acked], ['lan', true]);
      expect(b1.texts.last, 'by another way');
      expect(a.dialled(b2), 2, reason: 'a quarter of a minute after it could not be reached, the other is still left alone');
      // Half a minute on they are dialled again; found, the route carries once more.
      w.mesh.unreachable(b1.node, false);
      w.mesh.unreachable(b2.node, false);
      await w.clock.pass(const Duration(seconds: 30));
      d = await a.text(sam, 'found again');
      expect([d.via, d.acked], ['p2p', true]);
      await w.settle();
      expect(a.dialled(b2), 3);
      expect([b1.texts.last, b2.texts.last], ['found again', 'found again']);
    });

    test('sending by the links that are open dials nobody and starts nothing', () async {
      final sam = w.account('sam');
      final a = w.install(w.account('maya'), computer: true), b1 = w.install(sam, computer: true), b2 = w.install(sam, computer: true);
      final phone = w.install(w.account('cleo'));
      for (final other in [b1, b2, phone]) {
        w.friends(a, other);
      }
      for (final i in [a, b1, b2, phone]) {
        await i.start();
      }
      // (Cleo's phone is in her pocket: it does not go looking for its friends when the relay goes.)
      phone.p2p.setAway(true);
      await w.relayGone();
      // One of Sam's devices is linked; the other has fallen off the network.
      w.mesh.unreachable(b2.node);
      expect((await a.text(sam, 'to whoever is there')).acked, isTrue);
      await w.clock.pass(const Duration(seconds: 40));
      expect([a.p2p.carrier.linkedTo(sam.id, b1.p2p.nodeId!), a.p2p.carrier.linkedTo(sam.id, b2.p2p.nodeId!)], [true, false]);
      // Long enough since it could not be reached for a send to dial it again; by the open links, nothing is dialled.
      final dials = a.dialled(b2);
      final packet = Packet.wrap(from: a.account.id, sealed: true, payload: NetCrypto.seal(a.to(sam).key!, Envelope(kind: 'text', body: {'t': 'by the open link'}, ack: false).encode()));
      expect(a.p2p.carrier.linked(a.to(sam)), isTrue);
      expect(await a.p2p.carrier.sendLinked(a.to(sam), packet), Handed.passed);
      await w.clock.pass(const Duration(seconds: 6));
      expect(b1.texts.last, 'by the open link');
      expect(a.dialled(b2), dials);
      // A send by the route's own way, meanwhile, would dial it.
      expect(await a.p2p.carrier.send(a.to(sam), packet), Handed.passed);
      expect(a.dialled(b2), dials + 1);
      await w.clock.pass(const Duration(seconds: 6));
      // A phone with nobody linked: nothing to send by, and its node is not started to find out.
      expect(phone.p2p.carrier.linked(phone.to(a.account)), isFalse);
      await expectLater(phone.p2p.carrier.sendLinked(phone.to(a.account), packet), throwsA(isA<CarrierError>()));
      expect([phone.node.starts, phone.dialled(a)], [0, 0]);
    });

    test('a frame from a friend\'s device that says it is from another friend is dropped: what arrives is vouched for', () async {
      final maya = w.account('maya'), sam = w.account('sam'), cleo = w.account('cleo');
      final a = w.install(maya, computer: true), b = w.install(sam, computer: true), c = w.install(cleo, computer: true);
      w.friends(a, b);
      w.friends(a, c);
      for (final i in [a, b, c]) {
        await i.start();
      }
      await w.relayGone();
      final vouched = <String?>[];
      a.p2p.carrier.arrived.listen((x) => vouched.add(x.from));
      // A packet Cleo's own device would send, sealed with the key she and Maya share: good in every way.
      final words = Envelope(kind: 'text', body: {'t': 'from cleo'}, ack: false);
      final packet = Packet.wrap(from: cleo.id, sealed: true, payload: NetCrypto.seal(a.to(cleo).key!, words.encode()));
      // Sam's device puts it on its own stream to Maya: not handed on at all, a packet in another name than the one the
      // stream proved to be.
      expect(await b.p2p.carrier.send(b.to(maya), packet), Handed.passed);
      await w.settle();
      expect(vouched, isEmpty);
      expect(a.texts, isEmpty);
      // The same bytes from Cleo's device are taken, and the route says whose device brought them.
      expect(await c.p2p.carrier.send(c.to(maya), packet), Handed.passed);
      await w.settle();
      expect(vouched, [cleo.id]);
      expect(a.texts, ['from cleo']);
    });

    test('a node no card is held for can\'t open a stream; one let in by mistake is closed on; one that can\'t prove whose it is hears nothing', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      final arrived = <Arrived>[];
      a.p2p.carrier.arrived.listen(arrived.add);
      final where = a.node.whereabouts.value;
      // A stranger's node, told where Maya's device is: turned away by the node itself.
      final stranger = w.mesh.node();
      await stranger.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
      await expectLater(stranger.open(a.p2p.nodeId!, P2pChannel.packets, hint: where), throwsA(isA<P2pError>()));
      // Were the node to let it in all the same, the route closes the stream: no card says whose it is.
      a.node.allow(stranger.nodeId!, _packets);
      var stream = await stranger.open(a.p2p.nodeId!, P2pChannel.packets, hint: where);
      var done = false;
      stream.frames.listen((_) {}, onDone: () => done = true);
      await w.settle();
      expect([done, a.p2p.carrier.lines], [true, 0]);
      // A node a friend's card names, that does not hold the friend's key (the card is only the account's word): it
      // says a packet without proving itself, then a proof made with another key. Nothing is taken, and it is closed on.
      final keyless = w.mesh.node();
      final secret = NetCrypto.randomBytes(32);
      await keyless.start(P2pConfig(secret: secret));
      final lie = await _cardOf(w, b.account, node: keyless.nodeId);
      await b.board.send(b.to(a.account), _said(w, _telling(a, lie)), only: {'hub'});
      await w.settle();
      expect(a.node.allowed.keys, contains(keyless.nodeId));
      final packet = Packet.wrap(from: b.account.id, sealed: true, payload: NetCrypto.seal(a.to(b.account).key!, Envelope(kind: 'text', body: {'t': 'unproved'}).encode()));
      for (final first in [packet, Uint8List.fromList([0, 1, ...NetCrypto.hmac(NetCrypto.randomBytes(32), utf8.encode('ghost-p2p link v1\n'))])]) {
        stream = await keyless.open(a.p2p.nodeId!, P2pChannel.packets, hint: where);
        done = false;
        stream.frames.listen((_) {}, onDone: () => done = true);
        await stream.add(first);
        await w.settle();
        expect(done, isTrue);
        await expectLater(stream.add(packet), throwsA(isA<P2pError>()));
      }
      expect(arrived, isEmpty);
      expect(a.texts, isEmpty);
      expect(a.p2p.carrier.links, isEmpty);
      // One that says nothing at all is let go after the five seconds a dial has.
      stream = await keyless.open(a.p2p.nodeId!, P2pChannel.packets, hint: where);
      done = false;
      stream.frames.listen((_) {}, onDone: () => done = true);
      await w.clock.pass(const Duration(milliseconds: 4999));
      expect([done, a.p2p.carrier.lines], [false, 1]);
      await w.clock.pass(const Duration(milliseconds: 1));
      expect([done, a.p2p.carrier.lines], [true, 0]);
    });

    test('the proof is held to its bytes: a nonce from each end, then both accounts and both nodes in role order under the pair\'s key; a friend who names another friend\'s node as their own is sent nothing there', () async {
      final maya = w.account('maya'), xan = w.account('xan'), yara = w.account('yara');
      final a = w.install(maya, computer: true), x = w.install(xan, computer: true), y = w.install(yara, computer: true);
      w.friends(a, x);
      w.friends(a, y);
      for (final i in [a, x, y]) {
        await i.start();
      }
      // The link key, made from what the two accounts seal their packets with.
      final linkKey = LinkWords.linkKey(a.to(yara).key!);
      expect(a.p2p.linkKey(yara.id), linkKey);
      expect(y.p2p.linkKey(maya.id), linkKey, reason: 'both arrive at one key');
      expect(a.p2p.linkKey(xan.id), isNot(linkKey));
      // By hand, as Yara's device: its nonce and Maya's device's cross, then its proof, then a packet. Taken, and vouched
      // for as hers.
      final arrived = <Arrived>[];
      a.p2p.carrier.arrived.listen(arrived.add);
      final raw = w.mesh.node();
      await raw.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
      final hers = await _cardOf(w, yara, node: raw.nodeId);
      await y.board.send(y.to(maya), _said(w, _telling(a, hers)), only: {'hub'});
      await w.settle();
      final end = HandEnd(await raw.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value), linkKey: linkKey, account: yara.id, node: raw.nodeId!, them: maya.id);
      await w.settle();
      expect(end.heard, hasLength(2), reason: 'its nonce, then its proof');
      expect([end.heard.first.length, end.heard.first[0], end.heard.first[1]], [18, 0, 2]);
      expect(end.heard.last, LinkWords.proof(linkKey, fromAccount: maya.id, fromNode: a.p2p.nodeId!, toAccount: yara.id, toNode: raw.nodeId!, toNonce: end.nonce, fromNonce: end.theirs!), reason: 'answered with this device\'s own, the roles the other way round');
      expect(end.proved, isTrue);
      final packet = Packet.wrap(from: yara.id, sealed: true, payload: NetCrypto.seal(a.to(yara).key!, Envelope(kind: 'text', body: {'t': 'by hand'}, ack: false).encode()));
      await end.add(packet);
      await w.settle();
      expect([arrived.single.from, arrived.single.carrier, arrived.single.bytes], [yara.id, 'p2p', packet]);
      expect(a.texts, ['by hand']);
      // What proves nothing: the proof this device sent back, said back to it; one with the accounts the other way round;
      // one made for a nonce of before (a stream's proof is good on that stream alone); and one that leaves the
      // accounts out, as the first version did.
      Uint8List v1(String from, String to) => Uint8List.fromList([0, 1, ...NetCrypto.hmac(linkKey, [...utf8.encode('ghost-p2p link v1\n'), ...NetCrypto.unhex(from), ...NetCrypto.unhex(to)])]);
      final stale = end;
      for (final bad in <Uint8List Function(Uint8List mine, Uint8List theirs)>[
        (mine, theirs) => LinkWords.proof(linkKey, fromAccount: maya.id, fromNode: a.p2p.nodeId!, toAccount: yara.id, toNode: raw.nodeId!, toNonce: mine, fromNonce: theirs),
        (mine, theirs) => LinkWords.proof(linkKey, fromAccount: maya.id, fromNode: raw.nodeId!, toAccount: yara.id, toNode: a.p2p.nodeId!, toNonce: theirs, fromNonce: mine),
        (mine, theirs) => LinkWords.proof(linkKey, fromAccount: yara.id, fromNode: raw.nodeId!, toAccount: maya.id, toNode: a.p2p.nodeId!, toNonce: stale.theirs!, fromNonce: stale.nonce),
        (mine, theirs) => v1(raw.nodeId!, a.p2p.nodeId!),
      ]) {
        final s = await raw.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value);
        final said = <Uint8List>[];
        var closed = false;
        s.frames.listen(said.add, onDone: () => closed = true);
        final mine = NetCrypto.randomBytes(16);
        await s.add(LinkWords.nonce(mine));
        await w.settle();
        await s.add(bad(mine, said.single.sublist(2)));
        await w.settle();
        expect([closed, said.length], [true, 1], reason: 'closed on, and never proved to');
      }

      // Xan says Yara's device is his: a card for his account naming her node, and where it is. It is only his word.
      final lie = await _cardOf(w, xan, node: y.p2p.nodeId);
      await x.board.send(x.to(maya), _said(w, _telling(a, lie, where: y.node.whereabouts.value!.toJson())), only: {'hub'});
      // And another of "his": a device that takes a dial, says its nonce, and never proves.
      final mute = w.mesh.node();
      await mute.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
      mute.allow(a.p2p.nodeId!, _packets);
      final muted = <HandEnd>[];
      mute.opened.listen((s) => muted.add(HandEnd(s, linkKey: a.p2p.linkKey(xan.id)!, account: xan.id, node: mute.nodeId!, them: maya.id, proves: false)));
      await x.board.send(x.to(maya), _said(w, _telling(a, await _cardOf(w, xan, node: mute.nodeId), where: mute.whereabouts.value!.toJson())), only: {'hub'});
      await w.settle();
      expect(a.p2p.devicesOf(xan.id).map((d) => d.nodeId), containsAll([y.p2p.nodeId, mute.nodeId]));
      await w.relayGone();
      // His own device is off the network, so the only devices of "his" in reach are hers and the mute one.
      w.mesh.unreachable(x.node);
      final heard = <Arrived>[];
      y.p2p.carrier.arrived.listen(heard.add);
      final frames = w.mesh.frames;
      final sending = a.text(xan, 'for xan alone', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await sending).sent, isFalse, reason: 'neither could prove it is his, and nothing was said to either');
      expect([w.mesh.dialsTo(y.p2p.nodeId!), w.mesh.dialsTo(mute.nodeId!)], [1, 1], reason: 'each was dialled as his, and let this device in');
      // The mute one heard this device's nonce and its proof, made for Xan, and nothing after: no packet goes on a stream
      // before the device at the other end has proved whose it is, however long it takes about it.
      final m = muted.single;
      expect(m.heard, [LinkWords.nonce(m.theirs!), LinkWords.proof(a.p2p.linkKey(xan.id)!, fromAccount: maya.id, fromNode: a.p2p.nodeId!, toAccount: xan.id, toNode: mute.nodeId!, toNonce: m.nonce, fromNonce: m.theirs!)]);
      expect(w.mesh.frames - frames, 6, reason: 'on each stream the two nonces and Maya\'s proof, made for Xan (Yara\'s device closed on it, and the mute one said nothing): not a packet');
      expect(mute.streams, 0, reason: 'and the stream was let go when the five seconds were up');
      expect(heard, isEmpty);
      expect(y.got.where((r) => r.envelope.kind == 'text'), isEmpty);
      // Her device is still hers to Maya, both ways.
      expect((await y.text(maya, 'still me')).acked, isTrue);
      expect((await a.text(yara, 'I know')).acked, isTrue);
      expect(a.p2p.carrier.links.map((l) => l.account).toSet(), {yara.id}, reason: 'no device is linked as his');
    });

    // The second review, S2 (R2-A): the proof said "holds the pair's key", and both ends of a pair hold it. A friend's
    // card naming this account's own devices made them link with each other "as his", and a text for him was "passed"
    // to a device of one's own.
    test('a friend\'s cards naming this account\'s own devices as his: they do not link with each other as his, and nothing for him is passed to them', () async {
      final maya = w.account('maya'), xan = w.account('xan');
      // Two devices of Maya's that have not heard of each other as hers (no account signed in to either yet): the
      // proof alone stands between them.
      final a1 = w.install(maya, computer: true)..signedIn = false, a2 = w.install(maya, computer: true)..signedIn = false, x = w.install(xan, computer: true);
      w.friends(a1, x);
      w.friends(a2, x);
      for (final i in [a1, a2, x]) {
        await i.start();
      }
      // Xan tells Maya's account that each of her devices is his, and where it is: each takes the one naming the other.
      for (final other in [a2, a1]) {
        final lie = await _cardOf(w, xan, node: other.p2p.nodeId);
        await x.board.send(x.to(maya), _said(w, {'t': 'card', 'c': lie.toJson(), 'w': {...other.node.whereabouts.value!.toJson(), 't': w.clock.ms}, 'h': [a1.p2p.card!.tag, a2.p2p.card!.tag]}), only: {'hub'});
      }
      await w.settle();
      expect(a1.p2p.devicesOf(xan.id).map((d) => d.nodeId), contains(a2.p2p.nodeId), reason: 'his word is taken as his word');
      await w.relayGone();
      w.mesh.unreachable(x.node);
      final sending = a1.text(xan, 'for xan only', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      final d = await sending;
      expect(d.sent, isFalse, reason: 'not "passed" to a device of Maya\'s own');
      expect(a1.p2p.carrier.linkedTo(xan.id, a2.p2p.nodeId!), isFalse);
      expect([a1.p2p.carrier.links, a2.p2p.carrier.links], [isEmpty, isEmpty]);
      expect(a2.got.where((r) => r.envelope.kind == 'text'), isEmpty);

      // Once they know each other as Maya's (an account signed in to both), a friend's word that one of them is his is
      // not even taken; and one taken before goes when the account's own card for that node comes.
      final cardsBefore = a1.p2p.devicesOf(xan.id).length;
      await w.relayBack();
      for (final i in [a1, a2]) {
        i.signedIn = true;
      }
      await a1.p2p.refresh();
      await a2.p2p.refresh();
      await w.settle();
      expect(a1.p2p.devicesOf(maya.id).map((d) => d.nodeId), [a2.p2p.nodeId]);
      expect(a1.p2p.devicesOf(xan.id).map((d) => d.nodeId), isNot(contains(a2.p2p.nodeId)), reason: 'dropped as Maya\'s own card for it came');
      expect(a1.p2p.devicesOf(xan.id), hasLength(cardsBefore - 1));
      final again = await _cardOf(w, xan, node: a2.p2p.nodeId);
      await x.board.send(x.to(maya), _said(w, _telling(a1, again)), only: {'hub'});
      await w.settle();
      expect(a1.p2p.devicesOf(xan.id).map((d) => d.nodeId), isNot(contains(a2.p2p.nodeId)));
    });

    // The second review, S3 (R2-E): what was known of a dial was kept by node, for whichever account it was dialled
    // for. A dial "for Xan" to Yara's node that failed his proof marked her node unreachable for half a minute, and a
    // new stream to it closed the oldest, whoever had proved it.
    test('a friend who names another friend\'s node as his costs only his own route: her device is dialled at once after, and her proved links are never closed for his', () async {
      final maya = w.account('maya'), xan = w.account('xan'), yara = w.account('yara');
      final a = w.install(maya, computer: true), x = w.install(xan, computer: true), y = w.install(yara, computer: true);
      w.friends(a, x);
      w.friends(a, y);
      for (final i in [a, x, y]) {
        await i.start();
      }
      await w.clock.pass(_minute);
      final lie = await _cardOf(w, xan, node: y.p2p.nodeId);
      await x.board.send(x.to(maya), _said(w, _telling(a, lie, where: {...y.node.whereabouts.value!.toJson(), 't': w.clock.ms})), only: {'hub'});
      await w.settle();
      await w.relayGone();
      w.mesh.unreachable(x.node);
      final toXan = a.text(xan, 'for xan', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await toXan).sent, isFalse);
      // At once, something for Yara: her device is dialled and takes it.
      final dials = w.mesh.dialsTo(y.p2p.nodeId!);
      final toYara = a.text(yara, 'for yara', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 1));
      final d = await toYara;
      expect([d.sent, d.acked, w.mesh.dialsTo(y.p2p.nodeId!) - dials], [true, true, 1]);
      expect(y.texts, ['for yara']);
      // Two proved links with her device now (her device opens a second, as a device may).
      final second = HandEnd(await y.node.open(a.p2p.nodeId!, P2pChannel.packets), linkKey: y.p2p.linkKey(maya.id)!, account: yara.id, node: y.p2p.nodeId!, them: maya.id);
      await w.settle();
      expect(second.proved, isTrue);
      expect(a.p2p.carrier.lines, 2);
      // Half a minute on, another dial "for Xan" to her node: it fails his proof, and closes neither of hers.
      await w.clock.pass(const Duration(seconds: 31));
      final dialsNow = w.mesh.dialsTo(y.p2p.nodeId!);
      final again = a.text(xan, 'for xan again', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await again).sent, isFalse);
      expect(w.mesh.dialsTo(y.p2p.nodeId!) - dialsNow, 1, reason: 'dialled as his again');
      expect([second.done, a.p2p.carrier.lines, a.p2p.carrier.linkedTo(yara.id, y.p2p.nodeId!)], [false, 2, true]);
      expect((await a.text(yara, 'still linked', only: {'p2p'})).acked, isTrue);
    });

    test('a frame longer than the relay\'s packet is refused both ways, and a stream is let go after ninety seconds with nothing said', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      expect(P2pCarrier.maxPacket, 60 * 1024);
      await expectLater(a.p2p.carrier.send(a.to(b.account), Uint8List(P2pCarrier.maxPacket + 1)), throwsA(isA<CarrierError>()));
      expect(w.mesh.dials, isEmpty, reason: 'refused before anything is dialled');
      expect(await a.p2p.carrier.send(a.to(b.account), Uint8List(P2pCarrier.maxPacket)..[0] = 0x11), Handed.passed);
      await w.settle();
      expect([a.p2p.carrier.lines, b.p2p.carrier.lines], [1, 1]);
      await expectLater(a.p2p.carrier.sendLinked(a.to(b.account), Uint8List(P2pCarrier.maxPacket + 1)), throwsA(isA<CarrierError>()));
      // Kept open while things are said on it: eighty seconds on, a text; eighty more, still open.
      await w.clock.pass(const Duration(seconds: 80));
      expect((await a.text(b.account, 'still talking')).acked, isTrue);
      await w.clock.pass(const Duration(seconds: 80));
      expect([a.p2p.carrier.lines, b.p2p.carrier.lines, w.mesh.dials.length], [1, 1, 1]);
      // Ten more with nothing said: ninety in all, and both ends let it go.
      await w.clock.pass(const Duration(seconds: 10));
      expect([a.p2p.carrier.lines, b.p2p.carrier.lines], [0, 0]);
      expect([a.node.streams, b.node.streams], [0, 0]);
      expect(a.p2p.carrier.linked(a.to(b.account)), isFalse);
      // A device that sends a longer frame on a proved stream is closed on, and nothing of it is passed on.
      final arrived = <Arrived>[];
      b.p2p.carrier.arrived.listen(arrived.add);
      final raw = HandEnd(await a.node.open(b.p2p.nodeId!, P2pChannel.packets, hint: b.node.whereabouts.value), linkKey: a.p2p.linkKey(b.account.id)!, account: a.account.id, node: a.p2p.nodeId!, them: b.account.id);
      await w.settle();
      expect([raw.proved, raw.done], [true, false]);
      await raw.add(Uint8List(P2pCarrier.maxPacket + 1)..[0] = 0x11);
      await w.settle();
      expect([raw.done, arrived], [true, isEmpty]);
    });

    // The second review, S11: a put was given what was left of the five seconds, as little as a millisecond near the
    // end, and the stream was closed when it ran out: a real core's add across FFI often takes longer than that.
    test('a frame is given at least a second to go, and a stream slow to take one is not closed for it', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      // A dial that takes most of the five seconds, and a core that takes a while over each frame it sends.
      w.mesh.slow(b.node, const Duration(milliseconds: 4000));
      a.node.addTakes = const Duration(milliseconds: 600);
      final sending = a.text(b.account, 'slow but sure', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 6));
      final d = await sending;
      expect([d.sent, b.texts], [true, ['slow but sure']], reason: 'proved with less than the time a frame takes left, and given its second all the same');
      expect(a.p2p.carrier.lines, 1);
      // A frame that never goes: given its time, and the stream is not closed on for it.
      a.node.hangsOn.add('add');
      final packet = Packet.wrap(from: a.account.id, sealed: true, payload: NetCrypto.seal(a.to(b.account).key!, Envelope(kind: 'text', body: {'t': 'stuck'}, ack: false).encode()));
      final linked = a.p2p.carrier.sendLinked(a.to(b.account), packet);
      final failed = expectLater(linked, throwsA(isA<CarrierError>()));
      await w.clock.pass(const Duration(seconds: 5));
      await failed;
      expect([a.p2p.carrier.lines, a.p2p.carrier.linkedTo(b.account.id, b.p2p.nodeId!)], [1, true]);
    });

    // The second review, S12: nothing limited the frames on a stream, and every one joined the switchboard's arrivals.
    test('what one stream, and one account\'s devices together, can push in a while is limited: the rest is dropped and counted', () async {
      final maya = w.account('maya'), sam = w.account('sam');
      final a = w.install(maya, computer: true), b = w.install(sam, computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      final handed = <Arrived>[];
      a.p2p.carrier.arrived.listen(handed.add);
      // Two devices of Sam's, by hand, each with a stream to Maya's device.
      final ends = <HandEnd>[];
      for (var i = 0; i < 2; i++) {
        final raw = w.mesh.node();
        await raw.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
        await b.board.send(b.to(maya), _said(w, _telling(a, await _cardOf(w, sam, node: raw.nodeId))), only: {'hub'});
        await w.settle();
        ends.add(HandEnd(await raw.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value), linkKey: b.p2p.linkKey(maya.id)!, account: sam.id, node: raw.nodeId!, them: maya.id));
        await w.settle();
        expect(ends.last.proved, isTrue);
      }
      Uint8List packet() => Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.randomBytes(40));
      // One floods: no more than a stream's hundred go on at once.
      for (var i = 0; i < 300; i++) {
        await ends[0].add(packet());
      }
      await w.settle();
      expect([handed.length, a.p2p.carrier.dropped], [P2pCarrier.lineBurst, 300 - P2pCarrier.lineBurst]);
      // The other device of the same account: what is left of the account's hundred and fifty.
      for (var i = 0; i < 300; i++) {
        await ends[1].add(packet());
      }
      await w.settle();
      expect(handed.length, P2pCarrier.accountBurst);
      // Ten seconds on, a stream has its hundred again and the account a hundred and fifty: so many more go on.
      await w.clock.pass(const Duration(seconds: 10));
      final before = handed.length;
      for (var i = 0; i < 300; i++) {
        await ends[0].add(packet());
      }
      await w.settle();
      expect(handed.length - before, P2pCarrier.lineBurst);
      expect(ends.every((e) => !e.done), isTrue, reason: 'dropped, not closed on');
    });

    test('no more than two streams are held with one device, and a stream on another channel is not this route\'s to touch', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      final linkKey = b.p2p.linkKey(a.account.id)!;
      // Sam's device opens stream after stream, each proved: the third takes the place of the first.
      final ends = <HandEnd>[];
      for (var i = 0; i < 3; i++) {
        ends.add(HandEnd(await b.node.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value), linkKey: linkKey, account: b.account.id, node: b.p2p.nodeId!, them: a.account.id));
        await w.settle();
        expect(ends.last.proved, isTrue);
        expect(a.p2p.carrier.lines, i < 2 ? i + 1 : 2);
      }
      expect([for (final e in ends) e.done], [true, false, false]);
      final proof = LinkWords.nonce(NetCrypto.randomBytes(16));
      expect(a.p2p.carrier.links, hasLength(1), reason: 'one device, however many streams');

      // A relay hosted on this device would open another channel to anyone. Such a stream is someone else's: the
      // direct route neither closes it nor takes what is said on it for packets.
      final arrived = <Arrived>[];
      a.p2p.carrier.arrived.listen(arrived.add);
      a.node.openToAll({P2pChannel.hub});
      final stranger = w.mesh.node();
      await stranger.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
      final other = await stranger.open(a.p2p.nodeId!, P2pChannel.hub, hint: a.node.whereabouts.value);
      var done = false;
      other.frames.listen((_) {}, onDone: () => done = true);
      await other.add(proof);
      await other.add(Packet.wrap(from: b.account.id, sealed: true, payload: NetCrypto.seal(a.to(b.account).key!, Envelope(kind: 'text', body: {'t': 'on the wrong channel'}).encode())));
      await w.clock.pass(const Duration(minutes: 5));
      expect([done, arrived, a.texts], [false, isEmpty, isEmpty]);
      expect(a.node.streams, 1, reason: 'still open, for whoever it is for; the proved ones were let go for being quiet');
    });

    test('the relay only kept it and a link is open: it goes straight too, once, and is taken once; with no link nothing is dialled or started', () async {
      w = World(helpers: [_helper]);
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      // A link between the two phones, made by a send that went the direct way.
      expect((await a.text(b.account, 'first', only: {'p2p'})).acked, isTrue);
      expect(a.p2p.carrier.linked(a.to(b.account)), isTrue);
      // Sam's phone loses the relay, and only the relay.
      await b.hub.stop();
      await w.settle();
      // (What Sam's phone said to its own account's name is kept there for his other devices, whatever else is.)
      final kept = w.memory.hub.heldFor(b.account.id);
      final frames = w.mesh.frames, dials = w.mesh.dials.length;
      final acked = <String>[];
      a.board.acked.listen(acked.add);
      final e = Envelope(kind: 'text', body: {'t': 'kept, and straight'});
      var d = await a.board.send(a.to(b.account), e);
      expect([d.via, d.handed, d.acked], ['hub', Handed.held, false], reason: 'the relay\'s word is the answer: the link was not waited for');
      expect(d.tried, ['hub', 'p2p']);
      expect(w.memory.hub.heldFor(b.account.id), kept + 1);
      await w.settle();
      expect(b.texts, ['first', 'kept, and straight']);
      expect(b.got.last.via, 'p2p');
      expect(acked, [e.id], reason: 'answered over the link');
      expect(w.mesh.frames - frames, 2, reason: 'one packet over, one answer back');
      expect(w.mesh.dials, hasLength(dials), reason: 'by the stream that was open: nothing was dialled');
      // Back on the relay, Sam's phone is handed what it kept: the same envelope, passed on once.
      await b.hub.start();
      await w.until(() => b.hub.state.value == CarrierState.up, 'Sam\'s phone signed in again');
      await w.settle();
      expect(w.memory.hub.heldFor(b.account.id), kept);
      expect(b.texts, ['first', 'kept, and straight']);

      // The link is let go, and both phones' nodes stop. The relay keeps the next one: nothing else happens.
      await w.clock.pass(const Duration(minutes: 4));
      expect([a.p2p.carrier.lines, a.node.state.value, b.node.state.value], [0, P2pState.off, P2pState.off]);
      await b.hub.stop();
      await w.settle();
      final starts = [a.node.starts, b.node.starts];
      d = await a.text(b.account, 'kept only');
      await w.clock.pass(const Duration(seconds: 10));
      expect([d.via, d.handed], ['hub', Handed.held]);
      expect(d.tried, ['hub']);
      expect(w.mesh.dials, hasLength(dials));
      expect([a.node.starts, b.node.starts], starts);
      expect(b.texts, hasLength(2));
    });

    // The second review, S7 (R2-G): an answer to a packet that came straight went by the route's own send, to every
    // device of the sender, dialling the ones not linked.
    test('an answer to something that came straight goes back on the stream it came by, dials nobody, and is no reason for a phone\'s node to stay up', () async {
      final maya = w.account('maya'), sam = w.account('sam');
      final a = w.install(maya, computer: true), b1 = w.install(sam, computer: true), b2 = w.install(sam, computer: true);
      w.friends(a, b1);
      w.friends(a, b2);
      for (final i in [a, b1, b2]) {
        await i.start();
      }
      await w.clock.pass(_minute);
      await w.relayGone();
      w.mesh.unreachable(b2.node);
      final dials = a.dialled(b2);
      final sending = b1.text(maya, 'hello from b1', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 6));
      final d = await sending;
      expect([d.via, d.acked, a.texts], ['p2p', true, ['hello from b1']]);
      expect(a.dialled(b2) - dials, 0, reason: 'answered on the stream it came by');
      // A phone answering a friend's packets: the answers keep nothing up.
      final phone = w.install(w.account('cleo'));
      w.friends(phone, b1);
      await w.relayBack();
      await phone.start();
      await b1.p2p.refresh();
      await w.settle();
      expect((await phone.text(sam, 'mine', only: {'p2p'})).acked, isTrue);
      for (var i = 1; i <= 5; i++) {
        await w.clock.pass(const Duration(seconds: 20));
        if (phone.node.now == P2pState.up) expect((await b1.text(phone.account, 'yours $i', only: {'p2p'})).acked, isTrue);
      }
      await w.clock.pass(const Duration(seconds: 19));
      expect(phone.node.now, P2pState.up);
      await w.clock.pass(_second);
      expect([phone.node.now, phone.texts], [P2pState.off, ['yours 1', 'yours 2', 'yours 3', 'yours 4', 'yours 5']]);
    });

    // The second review, S1 (R2-H): when the relay passed something and no answer came in time, the next route was the
    // direct one with a full send: a phone's node started, a dial, and a meet that started the friend's phone's node too.
    test('the relay passed it and the answer was late: the direct route is used only by a link that is open, and nothing is started or dialled', () async {
      final maya = w.account('maya'), sam = w.account('sam');
      final a = w.install(maya), b = w.install(sam);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.clock.pass(_minute);
      // Sam's phone takes what comes by the relay, but its answers by the relay don't come back in time (here they can't
      // go by it at all; a slow phone's would do the same after four seconds).
      b.board.off.add('hub');
      final starts = [a.node.starts, b.node.starts], heard = b.heard.length, dials = w.mesh.dials.length;
      final sending = a.text(sam, 'an ordinary text');
      await w.clock.pass(const Duration(seconds: 4));
      final d = await sending;
      expect([d.via, d.handed, d.acked, d.tried], ['hub', Handed.passed, false, ['hub']]);
      expect(b.texts, ['an ordinary text']);
      await w.clock.pass(const Duration(seconds: 10));
      expect([a.node.starts, b.node.starts], starts, reason: 'neither phone\'s node was started');
      expect([w.mesh.dials.length - dials, b.heard.sublist(heard)], [0, isEmpty], reason: 'nothing dialled, no meet');
      // With a link open (made while Sam's phone could answer by the relay), it goes by that link too.
      b.board.off.remove('hub');
      expect((await a.text(sam, 'straight', only: {'p2p'})).acked, isTrue);
      b.board.off.add('hub');
      final second = a.text(sam, 'and by the link');
      await w.clock.pass(const Duration(seconds: 4));
      final again = await second;
      expect([again.via, again.acked, again.tried], ['p2p', true, ['hub', 'p2p']]);
      // With the relay down, the direct route is a route like any other: it starts the node and dials as it must.
      await w.clock.pass(const Duration(minutes: 5));
      b.board.off.remove('hub');
      await w.relayGone();
      a.p2p.setAway(true);
      b.p2p.setAway(true);
      final before = [a.node.starts, w.mesh.dialsTo(b.p2p.nodeId!)];
      final relayDown = a.text(sam, 'with the relay down');
      await w.clock.pass(const Duration(seconds: 5));
      expect((await relayDown).tried, ['p2p: none of their devices could be reached directly'], reason: 'Sam\'s phone is in his pocket, its node down');
      expect([a.node.starts - before[0], w.mesh.dialsTo(b.p2p.nodeId!) - before[1]], [1, 1]);
    });

    // The second review, S6: a ring with the relay down went by the direct route before the text that wakes a closed
    // app, waiting up to five seconds for a dial.
    test('something urgent with the relay down, and a route that wakes a closed app after the direct one: the direct route by an open link only, and the waking route at once', () async {
      const small = CarrierTraits(maxPacket: 133, maxParts: 6, metered: true, live: false, wakes: true);
      final sms = (PlainCarrier('sms', traits: small), PlainCarrier('sms', traits: small));
      sms.$1.twin = sms.$2;
      sms.$2.twin = sms.$1;
      final a = w.install(w.account('maya'), also: [sms.$1]), b = w.install(w.account('sam'), also: [sms.$2]);
      w.friends(a, b);
      await a.start();
      await b.start();
      // A link between the two phones, made while the relay was there; then both are put away, and the relay goes.
      expect((await a.text(b.account, 'linked', only: {'p2p'})).acked, isTrue);
      for (final i in [a, b]) {
        i.p2p.setAway(true);
      }
      await w.relayGone();
      // A link open: the ring goes by it and is answered, and no text is spent.
      final texts = sms.$1.carried.length;
      final d = await a.board.send(a.to(b.account), Envelope(kind: 'voice', body: {'t': 'call', 'i': 'abc'}), metered: true, urgent: true);
      expect([d.via, d.acked, d.tried, sms.$1.carried.length], ['p2p', true, ['p2p'], texts]);
      // The link let go and the nodes down: the direct route is not even tried, and the text that wakes goes at once.
      await w.clock.pass(const Duration(minutes: 3));
      expect([a.p2p.carrier.lines, a.node.now], [0, P2pState.off]);
      final starts = a.node.starts, dials = w.mesh.dials.length;
      final d2 = await a.board.send(a.to(b.account), Envelope(kind: 'voice', body: {'t': 'call', 'i': 'abd'}), metered: true, urgent: true);
      expect([d2.via, d2.tried], ['sms', ['sms']]);
      expect([a.node.starts - starts, w.mesh.dials.length - dials], [0, 0]);
      // With no route that wakes after it (a computer's), the direct route dials for it as it must.
      final c = w.install(w.account('cleo'), computer: true), e = w.install(w.account('dev'), computer: true);
      w.friends(c, e);
      await w.relayBack();
      await c.start();
      await e.start();
      await w.relayGone();
      final d3 = await c.board.send(c.to(e.account), Envelope(kind: 'voice', body: {'t': 'call', 'i': 'abe'}), metered: true, urgent: true);
      expect([d3.via, d3.acked], ['p2p', true]);
    });

    test('a copy to the account\'s own name reaches its other device directly when the relay is away', () async {
      final maya = w.account('maya');
      final desk = w.install(maya, computer: true), laptop = w.install(maya, computer: true);
      await desk.start();
      await laptop.start();
      // The two told each other through the account's own name.
      expect(desk.heard, ['card from maya']);
      expect(desk.p2p.devicesOf(maya.id).single.card, laptop.p2p.card);
      expect(laptop.p2p.devicesOf(maya.id).single.card, desk.p2p.card);
      expect([desk.p2p.ownDevices, desk.p2p.friendsDevices], [1, 0]);
      expect(desk.p2p.carrier.reaches(desk.mine), isTrue);
      await w.relayGone();
      // As Friends sends a copy of a conversation to the account's other devices (lib/friends/friends.dart, copyKind).
      final copy = Envelope(kind: 'mine', body: {'a': '@sam', 't': 'see you at 7', 'i': 'abcd', 'at': 1, 'o': true});
      final d = await desk.board.send(desk.mine, copy, only: const {'hub', 'p2p'});
      expect([d.via, d.acked], ['p2p', true]);
      final got = laptop.got.where((r) => r.envelope.kind == 'mine').single;
      expect([got.peer.id, got.via, got.envelope.body['t']], [maya.id, 'p2p', 'see you at 7']);
      expect(desk.p2p.carrier.links.single.account, maya.id);
      // With no account signed in here there are no own devices, and what was held of them goes.
      desk.signedIn = false;
      await desk.p2p.refresh();
      expect(desk.p2p.devicesOf(maya.id), isEmpty);
      expect(desk.p2p.carrier.reaches(desk.mine), isFalse);
    });
  });

  group('the switchboard and the direct route', () {
    // The second review, S4 (R2-D): a forward-secret packet that came straight and is not for this device was passed on
    // by the route it came by alone; with no sibling linked that failed unsaid, and it was already marked passed on, so
    // the relay's own copy was never passed on either, and the sibling never got it from this device.
    test('a packet for another device of this account that came straight is passed on by the relay first, and marked passed on only once a route took it', () async {
      ForwardSecrecy.offThread = false;
      final me = NetKeys.generate(), sam = NetKeys.generate();
      final pair = NetCrypto.netKey(NetCrypto.conversationKey(me, sam.public)!);
      final book = _Book({me.id: Peer(id: me.id, key: NetCrypto.randomBytes(32)), sam.id: Peer(id: sam.id, key: pair)});
      final fs = ForwardSecrecy(device: NetCrypto.hex(NetCrypto.randomBytes(16)), secrets: MemoryFsStore(), plain: MemoryFsStore());
      await fs.load();
      final hub = PlainCarrier('hub', traits: const CarrierTraits(maxPacket: 60 * 1024)), direct = _DeadLinks();
      final board = Switchboard(me: me.id, peers: book, carriers: [hub, direct], fs: fs);
      addTearDown(board.dispose);
      await board.start();
      await pumpEventQueue();
      Uint8List forSibling(String words) => Packet.wrap(
            from: sam.id,
            sealed: true,
            fs: true,
            payload: ForwardSecrecy.seal(from: sam.id, to: me.id, pairKey: pair, clear: Envelope(kind: 'text', body: {'t': words}).encode(), targets: [FsBundle(device: NetCrypto.hex(NetCrypto.randomBytes(16)), prekey: 'aabbccdd', key: NetKeys.generate().public, made: DateTime.now().millisecondsSinceEpoch)]),
          );
      bool passed(Uint8List p) => Packet.parse(p)?.passed ?? false;
      // It comes straight (the relay only kept its own copy): passed on by the relay, which keeps it for the sibling.
      final first = forSibling('for the sibling');
      direct.take(first, from: sam.id);
      await pumpEventQueue();
      expect([hub.carried.where(passed).length, direct.asked.where(passed).length], [1, 0]);
      // The relay's own copy, handed over later: passed on already, not again.
      hub.take(first, from: sam.id);
      await pumpEventQueue();
      expect(hub.carried.where(passed).length, 1);
      // With the relay down, the direct route is tried and can't: not marked passed on, so the relay's own copy, when it
      // comes, is passed on by it.
      await hub.stop();
      final second = forSibling('while the relay was down');
      direct.take(second, from: sam.id);
      await pumpEventQueue();
      expect([hub.carried.where(passed).length, direct.asked.where(passed).length], [1, 1]);
      await hub.start();
      hub.take(second, from: sam.id);
      await pumpEventQueue();
      expect(hub.carried.where(passed).length, 2);
      expect(fs.wasPassed(NetCrypto.hex(NetCrypto.sha256(Packet.parse(second)!.payload).sublist(0, 8))), isTrue);
      await board.stop();
    });

    test('no more than so many arrivals from the direct route wait to be opened at once: the rest are dropped and counted, and the relay\'s are never held up behind more', () async {
      final me = NetKeys.generate(), sam = NetKeys.generate();
      final pair = NetCrypto.netKey(NetCrypto.conversationKey(me, sam.public)!);
      final hub = PlainCarrier('hub'), direct = _DeadLinks();
      final board = Switchboard(me: me.id, peers: _Book({sam.id: Peer(id: sam.id, key: pair)}), carriers: [hub, direct]);
      addTearDown(board.dispose);
      await board.start();
      final got = <Received>[];
      board.received.listen(got.add);
      Uint8List text(String t) => Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(pair, Envelope(kind: 'text', body: {'t': t}, ack: false).encode()));
      // Opening takes a while (a forward-secret packet is opened on an isolate of its own): what comes meanwhile waits.
      final held = Completer<void>();
      board.holdArrivals(held.future);
      for (var i = 0; i < 300; i++) {
        direct.take(text('straight $i'), from: sam.id);
        await pumpEventQueue(times: 2);
      }
      hub.take(text('by the relay'), from: sam.id);
      await pumpEventQueue();
      expect(board.droppedArrivals, 300 - Switchboard.mostQueued);
      held.complete();
      await pumpEventQueue(times: 400);
      expect(got.where((r) => r.via == 'p2p'), hasLength(Switchboard.mostQueued));
      expect(got.last.envelope.body['t'], 'by the relay', reason: 'opened after no more than the ones let wait');
      await board.stop();
    });
  });

  group('when the node runs', () {
    test('a phone\'s is down until needed, up for a send, and down two minutes after the send, whatever is open; a computer\'s stays up', () async {
      w = World(helpers: [_helper]);
      final a = w.install(w.account('maya')), b = w.install(w.account('sam')), c = w.install(w.account('cleo'), computer: true);
      w.friends(a, b);
      w.friends(a, c);
      for (final i in [a, b, c]) {
        await i.start();
      }
      await w.clock.pass(const Duration(minutes: 10));
      expect([a.node.state.value, a.node.starts, b.node.starts], [P2pState.off, 0, 0], reason: 'down until there is something to say');
      expect([c.node.state.value, c.node.starts, c.node.stops], [P2pState.up, 1, 0], reason: 'a computer\'s is up whenever Direct is on');

      // A send that reaches the direct route: the node is started for it, the other is asked to meet and brings its
      // own up, and the two link.
      final d = await a.text(b.account, 'by the direct route', only: {'p2p'});
      expect([d.via, d.acked], ['p2p', true]);
      expect([a.node.state.value, a.node.starts, b.node.state.value, b.node.starts], [P2pState.up, 1, P2pState.up, 1]);
      expect(b.heard.last, 'meet from maya');
      expect(a.heard.last, 'card from sam', reason: 'answered with where it is now');
      expect(a.p2p.devicesOf(b.account.id).single.where!.addresses, b.node.whereabouts.value!.addresses);
      expect(b.p2p.devicesOf(a.account.id).single.where!.addresses, a.node.whereabouts.value!.addresses);
      expect(a.node.config!.helpers, [_helper]);

      // Ninety seconds with nothing said and the streams are let go; two minutes after the send (and after the meet it
      // answered, for the other), the node stops, whatever is open then.
      await w.clock.pass(const Duration(seconds: 89));
      expect(a.p2p.carrier.lines, greaterThan(0));
      await w.clock.pass(_second);
      expect([a.p2p.carrier.lines, b.p2p.carrier.lines], [0, 0]);
      await w.clock.pass(const Duration(seconds: 29));
      expect([a.node.state.value, b.node.state.value], [P2pState.up, P2pState.up]);
      await w.clock.pass(_second);
      expect([a.node.state.value, a.node.stops, b.node.state.value, b.node.stops], [P2pState.off, 1, P2pState.off, 1]);
      expect([c.node.state.value, c.node.stops], [P2pState.up, 0]);
      // A stream opened to a computer is let go the same, and its node stays.
      expect((await a.text(c.account, 'to a computer', only: {'p2p'})).acked, isTrue);
      await w.clock.pass(const Duration(minutes: 10));
      expect([c.p2p.carrier.lines, c.node.state.value, c.node.stops, a.node.state.value], [0, P2pState.up, 0, P2pState.off]);
    });

    test('a meet brings a phone\'s node up and is answered with where it is; the seventh in an hour is not, nor any while Invisible or switched off', () async {
      w = World(helpers: [_helper]);
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      // As Maya's device asks: its card, by the relay. (Sent by hand, past the limit her own device keeps to.)
      Future<void> meet() async {
        await a.board.send(a.to(b.account), _said(w, {'t': 'meet', 'c': a.p2p.card!.toJson(), 'h': [b.p2p.card!.tag]}), only: {'hub'});
        await w.settle();
      }

      int answers() => a.heard.where((h) => h == 'card from sam').length;
      expect([b.node.starts, answers()], [0, 1]);
      for (var i = 1; i <= 6; i++) {
        await meet();
        expect([b.node.state.value, b.node.starts, answers()], [P2pState.up, i, 1 + i], reason: 'meet $i');
        expect(a.p2p.devicesOf(b.account.id).single.where!.addresses, b.node.whereabouts.value!.addresses, reason: 'where it is now, each time');
        expect(w.mesh.dialsTo(a.p2p.nodeId!), i, reason: 'and it dials the one that asked');
        // Nothing comes of it (Maya's node is down): Sam's stops again, two minutes after it came up.
        await w.clock.pass(const Duration(minutes: 5));
        expect(b.node.state.value, P2pState.off);
      }
      // The seventh within the hour: nothing.
      await meet();
      await w.clock.pass(const Duration(minutes: 5));
      expect([b.node.starts, answers(), w.mesh.dialsTo(a.p2p.nodeId!)], [6, 7, 6]);
      // An hour after the first, it is answered again.
      await w.clock.pass(const Duration(minutes: 25));
      await meet();
      expect([b.node.starts, answers()], [7, 8]);
      await w.clock.pass(const Duration(hours: 2));

      // Invisible: not answered at all, and the friend's device is let in no longer, since a link says "here".
      b.p2p.setMode('invisible');
      expect(b.node.allowed, isEmpty);
      await meet();
      await w.clock.pass(const Duration(minutes: 5));
      expect([b.node.starts, answers()], [7, 8]);
      expect(b.p2p.carrier.reaches(b.to(a.account)), isFalse);
      final dials = w.mesh.dials.length;
      expect((await b.text(a.account, 'not while invisible', only: {'p2p'})).sent, isFalse);
      expect(w.mesh.dials, hasLength(dials), reason: 'nothing is dialled while Invisible');
      // Seen again: let in again, and answered.
      b.p2p.setMode('online');
      expect(b.node.allowed.keys, [a.p2p.nodeId]);
      await meet();
      expect([b.node.starts, answers()], [8, 9]);
      await w.clock.pass(const Duration(hours: 2));

      // Direct switched off: not at all.
      await b.board.setOn('p2p', false);
      await meet();
      await w.clock.pass(const Duration(minutes: 5));
      expect([b.node.starts, answers()], [8, 9]);
      // One the relay kept for ten minutes is no longer "I am up": not answered either. (Sam's phone is in his pocket
      // meanwhile, or it would look for its friends itself once the relay had been gone a while.)
      await b.board.setOn('p2p', true);
      b.p2p.setAway(true);
      await b.hub.stop();
      await w.settle();
      await meet();
      await w.clock.pass(const Duration(minutes: 10));
      await b.hub.start();
      await w.until(() => b.hub.state.value == CarrierState.up, 'Sam\'s phone signed in again');
      await w.settle();
      expect(b.heard.last, 'meet from maya');
      expect([b.node.starts, answers()], [8, 9]);
      // Nor a fresh one while the phone is in his pocket; in use, as ever.
      await meet();
      expect([b.node.starts, answers()], [8, 9]);
      b.p2p.setAway(false);
      await meet();
      expect([b.node.starts, answers()], [9, 10]);
    });

    // The second review, M2 (R2-B): any frame whose first byte wasn't 0 reset a stream's quiet timer, and a phone's node
    // was not stopped while any stream was open: one junk byte a minute kept a phone's node up for three hours.
    test('a friend\'s device can\'t keep a phone\'s node up: junk is not something said, and the node stops two minutes after its own last reason, whatever is open', () async {
      final maya = w.account('maya'), sam = w.account('sam');
      final a = w.install(maya), b = w.install(sam, computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      // A device of Sam's account, by hand: it asks Maya's phone to meet, proves itself when the phone dials it, and
      // then says one junk byte a minute.
      final raw = w.mesh.node();
      await raw.start(P2pConfig(secret: NetCrypto.randomBytes(32)));
      raw.allow(a.p2p.nodeId!, _packets);
      final ends = <HandEnd>[];
      raw.opened.listen((s) => ends.add(HandEnd(s, linkKey: b.p2p.linkKey(maya.id)!, account: sam.id, node: raw.nodeId!, them: maya.id)));
      final card = await _cardOf(w, sam, node: raw.nodeId);
      await b.board.send(b.to(maya), _said(w, {'t': 'meet', 'c': card.toJson(), 'w': raw.whereabouts.value!.toJson(), 'h': [a.p2p.card!.tag]}), only: {'hub'});
      await w.settle();
      expect([a.node.now, ends.single.proved], [P2pState.up, true]);
      final end = ends.single;
      await w.clock.pass(const Duration(seconds: 60));
      await end.add(Uint8List.fromList([0x55]));
      await end.add(Packet.wrap(from: maya.id, sealed: true, payload: Uint8List(40)));
      await w.clock.pass(const Duration(seconds: 29));
      expect(a.p2p.carrier.lines, 1);
      await w.clock.pass(const Duration(seconds: 1));
      expect([a.p2p.carrier.lines, end.done], [0, true], reason: 'ninety seconds after the proof: junk, or a packet in another\'s name, is not something said');
      // And however it keeps linking and saying things, the node stops two minutes after the meet it answered.
      final stops = a.node.stops;
      for (var i = 0; i < 6; i++) {
        await w.clock.pass(const Duration(seconds: 5));
        if (a.node.now == P2pState.up) {
          ends.add(HandEnd(await raw.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value), linkKey: b.p2p.linkKey(maya.id)!, account: sam.id, node: raw.nodeId!, them: maya.id));
          await w.settle();
          // (Asking no answer: what a phone answers is the next test's.)
          await ends.last.add(Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(a.to(sam).key!, Envelope(kind: 'text', body: {'t': 'hi $i'}, ack: false).encode())));
        }
      }
      await w.clock.pass(const Duration(seconds: 1));
      expect([a.node.now, a.node.stops - stops], [P2pState.off, 1]);
      expect(a.texts, isNotEmpty, reason: 'what it said was taken; it kept nothing up');
      for (var minute = 0; minute < 60; minute++) {
        await w.clock.pass(_minute);
      }
      expect([a.node.now, a.node.stops - stops], [P2pState.off, 1]);
    });

    test('nor can packets a friend sends it: a phone\'s node is up for its own sends and meets, and stops two minutes after the last of them', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      // A send of the phone's own brings its node up and links.
      expect((await a.text(b.account, 'mine', only: {'p2p'})).acked, isTrue);
      // The computer then writes every twenty seconds, straight: taken, and none of it keeps the node up. (Asking no
      // answer here: the phone's answers go back on the stream they answer, and are no reason either: see S7's test.)
      for (var i = 1; i <= 5; i++) {
        await w.clock.pass(const Duration(seconds: 20));
        if (a.node.now == P2pState.up) expect((await b.board.send(b.to(a.account), Envelope(kind: 'text', body: {'t': 'yours $i'}, ack: false), only: {'p2p'})).sent, isTrue);
      }
      await w.clock.pass(const Duration(seconds: 19));
      expect(a.node.now, P2pState.up);
      await w.clock.pass(const Duration(seconds: 1));
      expect([a.node.now, a.texts], [P2pState.off, ['yours 1', 'yours 2', 'yours 3', 'yours 4', 'yours 5']]);
      // Another send of its own: up again, for two minutes more from then.
      expect((await a.text(b.account, 'mine again', only: {'p2p'})).acked, isTrue);
      await w.clock.pass(const Duration(seconds: 119));
      expect(a.node.now, P2pState.up);
      await w.clock.pass(_second);
      expect(a.node.now, P2pState.off);
    });

    // The second review, M2 (R2-F): meets were limited for each friend alone, and answered with the app put away; three
    // friends at six an hour each kept a phone's node up 54 minutes of 60.
    test('meets are answered no more than twelve times an hour from all friends together, and a phone\'s node is up for each no longer than two minutes', () async {
      final maya = w.account('maya');
      final a = w.install(maya);
      final others = [for (var i = 0; i < 3; i++) w.install(w.account('f$i'), computer: true)];
      for (final o in others) {
        w.friends(a, o);
      }
      await a.start();
      for (final o in others) {
        await o.start();
      }
      await w.clock.pass(_minute);
      int answers() => [for (final o in others) o.heard.where((h) => h == 'card from maya').length].fold(0, (n, x) => n + x);
      final before = answers();
      var minutesUp = 0;
      // Each asks every ten minutes, six an hour (as many as one friend may), the three spread across the ten minutes.
      for (var minute = 0; minute < 60; minute++) {
        for (final (i, o) in others.indexed) {
          if (minute % 10 == (i * 10 ~/ others.length)) {
            await o.board.send(o.to(maya), _said(w, {'t': 'meet', 'c': o.p2p.card!.toJson(), 'w': o.node.whereabouts.value?.toJson(), 'h': [a.p2p.card!.tag]}), only: {'hub'});
            await w.settle();
          }
        }
        await w.clock.pass(const Duration(seconds: 30));
        if (a.node.now == P2pState.up) minutesUp++;
        await w.clock.pass(const Duration(seconds: 30));
      }
      expect(answers() - before, const P2pPolicy().meetsInAllAnHour, reason: 'eighteen asked: twelve answered');
      expect(minutesUp, lessThanOrEqualTo(2 * const P2pPolicy().meetsInAllAnHour));
      expect(a.node.starts, const P2pPolicy().meetsInAllAnHour);
    });

    test('a phone with the app put away is not brought up for a meet, and says where it is only while the app is in use', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      // Sam's phone is in his pocket.
      b.p2p.setAway(true);
      final heard = a.heard.length;
      await a.board.send(a.to(b.account), _said(w, {'t': 'meet', 'c': a.p2p.card!.toJson(), 'w': a.node.whereabouts.value!.toJson(), 'h': [b.p2p.card!.tag]}), only: {'hub'});
      await w.settle();
      await w.clock.pass(const Duration(seconds: 10));
      expect([b.node.starts, a.heard.length - heard], [0, 0], reason: 'not brought up, and not answered: Maya\'s device holds its card already');
      // Asked by a device that doesn't hold its card, it says its card, and nothing of where it is.
      await a.board.send(a.to(b.account), _said(w, {'t': 'meet', 'c': a.p2p.card!.toJson(), 'w': a.node.whereabouts.value!.toJson(), 'h': const []}), only: {'hub'});
      await w.settle();
      expect([b.node.starts, a.heard.sublist(heard)], [0, ['card from sam']]);
      expect(a.got.last.envelope.body.containsKey('w'), isFalse);
      // Its node up for a send of its own while the app is away: still nothing of where it is goes with its card.
      await b.p2p.up();
      expect(b.node.whereabouts.value, isNotNull);
      await a.board.send(a.to(b.account), _said(w, {'t': 'card?', 'h': const []}), only: {'hub'});
      await w.settle();
      expect(a.got.last.envelope.body.containsKey('w'), isFalse);
      // In use: a meet brings it up and is answered with where it is.
      b.p2p.setAway(false);
      await w.clock.pass(const Duration(hours: 1));
      await a.board.send(a.to(b.account), _said(w, {'t': 'meet', 'c': a.p2p.card!.toJson(), 'w': a.node.whereabouts.value!.toJson(), 'h': [b.p2p.card!.tag]}), only: {'hub'});
      await w.settle();
      expect([b.node.now, a.got.last.envelope.body['w']?['a']], [P2pState.up, b.node.whereabouts.value!.addresses]);
    });

    test('no more than ten streams a minute are taken from one node', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      // Sam's device opens stream after stream and says nothing on any: each taken one is answered with a nonce.
      final answered = <int>[];
      for (var i = 0; i < 14; i++) {
        final s = await b.node.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value);
        s.frames.listen((_) => answered.add(i));
        await w.settle();
      }
      expect(answered.toSet(), hasLength(P2pCarrier.opensAMinute));
      // A minute on, it is taken again.
      await w.clock.pass(_minute);
      final s = await b.node.open(a.p2p.nodeId!, P2pChannel.packets, hint: a.node.whereabouts.value);
      var heard = false;
      s.frames.listen((_) => heard = true);
      await w.settle();
      expect(heard, isTrue);
    });

    test('asked to meet, a device says where it is now and is dialled again by that, inside the same five seconds', () async {
      // Two phones on one network with no link helper: neither has ever said where it is.
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      expect(a.p2p.hintFor(a.p2p.devicesOf(b.account.id).single), isNull);
      // Maya's router lets nothing in: Sam's phone can't dial hers, so it is her dial that has to get through.
      w.mesh.inbound(a.node, false);
      final began = w.clock.ms;
      final d = await a.text(b.account, 'found by the answer', only: {'p2p'});
      expect([d.via, d.acked], ['p2p', true]);
      expect(w.clock.ms, began, reason: 'no time had to pass: the first dial was not waited out');
      // Dialled first knowing nothing of where it is, then again by what its answer to the meet said.
      final dials = [for (final x in w.mesh.dials) if (x.to == b.p2p.nodeId) x.hint?.addresses];
      expect(dials, [null, b.node.whereabouts.value!.addresses]);
      expect(b.heard.last, 'meet from maya');
      expect(a.p2p.carrier.links.single.kind, P2pPathKind.direct);
      await w.clock.pass(const Duration(seconds: 5));
      expect(w.mesh.dialsTo(b.p2p.nodeId!), 2);
    });

    test('Invisible: this account\'s own devices go on linking, friends\' do not', () async {
      final maya = w.account('maya');
      final desk = w.install(maya, computer: true), laptop = w.install(maya, computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(desk, b);
      w.friends(laptop, b);
      for (final i in [desk, laptop, b]) {
        await i.start();
      }
      await w.relayGone();
      expect((await desk.text(b.account, 'seen')).acked, isTrue);
      // Invisible, as the person chose, on both their devices.
      desk.p2p.setMode('invisible');
      laptop.p2p.setMode('invisible');
      await w.settle();
      expect(desk.node.allowed.keys, [laptop.p2p.nodeId]);
      expect([desk.p2p.carrier.linked(desk.to(b.account)), b.p2p.carrier.linkedTo(maya.id, desk.p2p.nodeId!)], [false, false], reason: 'the link with the friend\'s device was closed');
      // The friend's device is turned away, and none of theirs is dialled.
      final sending = b.text(maya, 'are you there?', only: {'p2p'});
      await w.clock.pass(const Duration(seconds: 5));
      expect((await sending).sent, isFalse);
      expect((await desk.text(b.account, 'unseen', only: {'p2p'})).sent, isFalse);
      // The account's own other device is reached as ever.
      final d = await desk.board.send(desk.mine, Envelope(kind: 'mine', body: const {'t': 'to myself'}), only: const {'p2p'});
      expect([d.via, d.acked], ['p2p', true]);
      expect(laptop.got.last.envelope.body['t'], 'to myself');
    });

    test('the relay\'s link helpers reach the node\'s config, are kept for a start while it is away, and a change restarts a running node', () async {
      w = World(helpers: [_helper, 'http://not.https.example', 'https://two.example']);
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'));
      w.friends(a, b);
      await a.start();
      await b.start();
      expect(a.hub.helpers.value, [_helper, 'https://two.example']);
      expect(a.p2p.helpers, [_helper, 'https://two.example']);
      expect(a.node.config!.helpers, [_helper, 'https://two.example']);
      expect(a.node.whereabouts.value!.helper, _helper);
      expect(jsonDecode(a.plain.kept[P2p.helpersName]!), [_helper, 'https://two.example']);
      // A phone's node is down: nothing is started for the news, and its next start has them.
      expect([b.p2p.helpers, b.node.starts], [[_helper, 'https://two.example'], 0]);

      // The relay names another: the computer's running node is started again with it; the phone's is left down.
      var starts = a.node.starts, stops = a.node.stops;
      w.memory = MemoryHub(Hub(helpers: ['https://other.example']));
      for (final i in [a, b]) {
        i.hub.nudge(away: const Duration(minutes: 5));
      }
      await w.until(() => a.hub.state.value == CarrierState.up && b.hub.state.value == CarrierState.up, 'both signed in to the relay again');
      await w.settle();
      expect(a.hub.helpers.value, ['https://other.example']);
      expect([a.node.starts, a.node.stops], [starts + 1, stops + 1]);
      expect([a.node.state.value, a.node.config!.helpers], [P2pState.up, ['https://other.example']]);
      expect(b.node.starts, 0);
      // The same again changes nothing.
      for (final p in w.memory.pairs.toList()) {
        p.cut();
      }
      a.hub.nudge();
      await w.until(() => a.hub.state.value == CarrierState.up, 'signed in again');
      await w.settle();
      expect(a.node.starts, starts + 1);

      // The app starts while the relay is away: the helpers it last named are what the node is given.
      await w.relayGone();
      await a.restart();
      expect(a.hub.helpers.value, isEmpty);
      expect(a.node.config!.helpers, ['https://other.example']);
      // Told by itself, with the relay as it was (the app moving to another relay lets the old one's go at once): a
      // running node is started again for that too.
      starts = a.node.starts;
      a.p2p.setHelpers(const ['https://third.example']);
      await w.settle();
      expect([a.node.starts, a.node.config!.helpers], [starts + 1, ['https://third.example']]);
      a.p2p.setHelpers(const ['https://third.example']);
      await w.settle();
      expect(a.node.starts, starts + 1);
      a.p2p.setHelpers(const ['https://other.example']);
      await w.settle();
      // A relay that names none: none are used.
      w.memory = MemoryHub(Hub());
      a.hub.nudge();
      await w.until(() => a.hub.state.value == CarrierState.up, 'signed in to a relay with no helpers');
      await w.settle();
      expect([a.p2p.helpers, a.node.config!.helpers, a.plain.kept[P2p.helpersName]], [isEmpty, isEmpty, '[]']);
      expect(a.node.whereabouts.value!.helper, isNull);
    });

    test('"Only through link helpers" reaches the node, restarts one that is running, and is kept', () async {
      w = World(helpers: [_helper]);
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      expect([a.p2p.helpersOnly, a.node.config!.helpersOnly], [false, false]);
      final starts = a.node.starts;
      await a.p2p.setHelpersOnly(true);
      await w.settle();
      expect([a.p2p.helpersOnly, a.node.config!.helpersOnly, a.node.starts], [true, true, starts + 1]);
      expect(a.plain.kept[P2p.helpersOnlyName], 'on');
      expect(a.node.whereabouts.value!.addresses, isEmpty);
      // The path is the helper's, and what the other is told of where this device is has no address in it.
      await w.relayGone();
      expect((await a.text(b.account, 'through the helper')).acked, isTrue);
      expect(a.node.pathTo(b.p2p.nodeId!)!.kind, P2pPathKind.helper);
      await w.relayBack();
      await a.board.send(a.to(b.account), _said(w, const {'t': 'card?'}), only: {'hub'});
      await b.board.send(b.to(a.account), _said(w, const {'t': 'card?'}), only: {'hub'});
      await w.settle();
      final told = b.p2p.devicesOf(a.account.id).single.where!;
      expect([told.helper, told.addresses], [_helper, isEmpty]);
      // Kept: the app started again still has it, and the node is started with it.
      await a.restart();
      expect([a.p2p.helpersOnly, a.node.config!.helpersOnly], [true, true]);
      await a.p2p.setHelpersOnly(false);
      await w.settle();
      expect([a.node.config!.helpersOnly, a.plain.kept[P2p.helpersOnlyName], a.node.whereabouts.value!.addresses.length], [false, 'off', 1]);
    });

    // The second review, S14: switching "Only through link helpers" on told no friend, and a friend kept the old
    // addresses whenever what came next said nothing of where the device is.
    test('switching "Only through link helpers" tells friends at once, and anything newer that says nothing of where a device is clears the addresses held for it', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      // Maya's phone, in use, answers a meet from Sam's computer with where it is.
      await b.board.send(b.to(a.account), _said(w, {'t': 'meet', 'c': b.p2p.card!.toJson(), 'w': b.node.whereabouts.value!.toJson(), 'h': [a.p2p.card!.tag]}), only: {'hub'});
      await w.settle();
      expect(b.p2p.devicesOf(a.account.id).single.where!.addresses, a.node.whereabouts.value!.addresses);
      // Only through link helpers: Sam's computer is told at once, and holds no address of hers after.
      final heard = b.heard.length;
      await a.p2p.setHelpersOnly(true);
      await w.settle();
      expect(b.heard.sublist(heard), ['card from maya']);
      expect(b.p2p.devicesOf(a.account.id).single.where, isNull);
      // And switched off again: told again, with where it is now that it says it.
      await w.clock.pass(_minute);
      await a.p2p.setHelpersOnly(false);
      await w.settle();
      expect(b.heard.sublist(heard), ['card from maya', 'card from maya']);
      // A newer word that says nothing of where it is (its node down) clears what was held; an older one doesn't.
      await b.board.send(b.to(a.account), _said(w, {'t': 'meet', 'c': b.p2p.card!.toJson(), 'w': b.node.whereabouts.value!.toJson(), 'h': [a.p2p.card!.tag]}), only: {'hub'});
      await w.settle();
      expect(b.p2p.devicesOf(a.account.id).single.where, isNotNull);
      final cardNow = a.p2p.card!;
      await a.board.send(a.to(b.account), Envelope(kind: P2p.kind, body: {'t': 'card', 'c': cardNow.toJson(), 'h': [b.p2p.card!.tag]}, ack: false, at: w.clock.ms - 60000), only: {'hub'});
      await w.settle();
      expect(b.p2p.devicesOf(a.account.id).single.where, isNotNull, reason: 'older than what is held');
      await w.clock.pass(_second);
      await a.board.send(a.to(b.account), Envelope(kind: P2p.kind, body: {'t': 'card', 'c': cardNow.toJson(), 'h': [b.p2p.card!.tag]}, ack: false, at: w.clock.ms), only: {'hub'});
      await w.settle();
      expect(b.p2p.devicesOf(a.account.id).single.where, isNull);
    });

    test('a node that can\'t start: the route is down and says why, a send goes on to the next route, and it is tried again after a while', () async {
      final lan = PlainCarrier.pair('lan');
      final a = w.install(w.account('maya'), computer: true, also: [lan.$1]), b = w.install(w.account('sam'), computer: true, also: [lan.$2]);
      w.friends(a, b);
      a.startFails = 'The direct network\'s port is taken';
      await a.start();
      await b.start();
      expect([a.p2p.carrier.state.value, a.p2p.carrier.problem], [CarrierState.down, 'The direct network\'s port is taken']);
      expect(a.node.starts, 1, reason: 'not tried over and over');
      final d = await a.text(b.account, 'another way', only: {'p2p', 'lan'});
      expect([d.via, d.tried], ['lan', ['lan']], reason: 'a route that is down is passed over');
      // Nothing that wants the node meanwhile starts it again: the people changing, a card asked for, a meet.
      await a.p2p.refresh();
      await b.board.send(b.to(a.account), _said(w, {'t': 'meet', 'c': b.p2p.card!.toJson(), 'h': [a.p2p.card!.tag]}), only: {'hub'});
      await expectLater(a.p2p.up(), throwsA(isA<CarrierError>()));
      await w.clock.pass(const Duration(seconds: 20));
      expect([a.node.starts, a.p2p.carrier.state.value], [1, CarrierState.down]);
      await w.clock.pass(const Duration(seconds: 9));
      // Half a minute on it is tried again, by itself on a computer.
      a.node.failStarts = null;
      await w.clock.pass(const Duration(seconds: 2));
      expect([a.node.state.value, a.p2p.carrier.state.value, a.p2p.carrier.problem], [P2pState.up, CarrierState.up, null]);
      expect(a.node.starts, 2);
    });
  });

  group('a core that does not answer', () {
    test('a node that has not come up in the time a dial has is taken to have failed: the send goes on, and it is tried again later', () async {
      final lan = PlainCarrier.pair('lan');
      final a = w.install(w.account('maya'), also: [lan.$1]), b = w.install(w.account('sam'), computer: true, also: [lan.$2]);
      w.friends(a, b);
      await a.start();
      await b.start();
      a.node.startTakes = const Duration(minutes: 1);
      final sending = a.text(b.account, 'not held up', only: {'p2p', 'lan'});
      await w.clock.pass(const Duration(milliseconds: 4999));
      expect([a.node.state.value, b.texts], [P2pState.starting, isEmpty]);
      await w.clock.pass(const Duration(milliseconds: 1));
      final d = await sending;
      expect(d.tried, ['p2p: The direct network did not start', 'lan']);
      expect([d.via, b.texts], ['lan', ['not held up']]);
      expect([a.p2p.carrier.state.value, a.p2p.carrier.problem], [CarrierState.down, 'The direct network did not start']);
      // The next thing sent does not wait on it again.
      final next = await a.text(b.account, 'at once', only: {'p2p', 'lan'});
      expect([next.tried, a.node.starts], [['lan'], 1]);
      // Half a minute on the route is ready to try again.
      await w.clock.pass(const Duration(seconds: 30));
      expect(a.p2p.carrier.state.value, CarrierState.up);
    });

    test('a node that never answers a stop does not hold up signing out, and one that never says what a key makes holds up nothing but itself', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      a.node.hangs = true;
      var wiped = false;
      unawaited(a.p2p.wipe().then((_) => wiped = true));
      await w.clock.pass(const Duration(milliseconds: 4999));
      expect(wiped, isFalse);
      await w.clock.pass(const Duration(milliseconds: 1));
      expect([wiped, a.secrets.kept[P2p.keyName], a.plain.kept[P2p.cardsName]], [true, isEmpty, isEmpty]);
      // An install whose core never says what its key makes: nothing is read, and nothing waits on it.
      final c = w.install(w.account('cleo'))..coreHangs = true;
      w.friends(c, b);
      var started = false;
      final timers = w.clock.waiting;
      unawaited(c.start().then((_) => started = true));
      await w.until(() => w.clock.waiting > timers, 'the core was asked what the key makes');
      await w.clock.pass(const Duration(seconds: 9));
      expect(started, isFalse);
      await w.clock.pass(const Duration(seconds: 2));
      expect([started, c.p2p.loaded, c.p2p.carrier.state.value], [true, false, CarrierState.connecting]);
      expect((await c.text(b.account, 'by the relay all the same')).via, 'hub');
      // Once it answers, the next try reads it.
      c.node.hangs = false;
      expect(await c.p2p.tryLoad(), isTrue);
    });
  });

  group('signing out', () {
    test('wipes the node key, the node id, the cards and what was told; the node stops and lets nobody in; what comes after is a new node', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      expect((await a.text(b.account, 'before')).acked, isTrue);
      final was = a.p2p.nodeId!;
      for (final name in [P2p.idName, P2p.cardName, P2p.cardsName, P2p.toldName]) {
        expect(a.plain.kept[name], isNotEmpty, reason: name);
      }
      expect(_nodeKey(a), hasLength(32));
      await a.p2p.setHelpersOnly(true);

      await a.p2p.wipe();
      await w.settle();
      expect(a.secrets.kept[P2p.keyName], isEmpty);
      for (final name in P2p.keptNames) {
        expect(a.plain.kept[name] ?? '', isEmpty, reason: name);
      }
      expect(a.plain.kept[P2p.helpersOnlyName], 'on', reason: 'a choice, not the account\'s');
      expect([a.node.state.value, a.node.allowed, a.p2p.carrier.lines, b.p2p.carrier.lines], [P2pState.off, isEmpty, 0, 0]);
      expect([a.p2p.loaded, a.p2p.card, a.p2p.nodeId, a.p2p.devicesOf(b.account.id)], [false, null, null, isEmpty]);
      expect(a.p2p.carrier.reaches(a.to(b.account)), isFalse);
      // The app starts again as it does after signing out: a new key, another node id, nothing held.
      await a.restart();
      expect(a.p2p.nodeId, isNot(was));
      expect(_nodeKey(a), hasLength(32));
    });

    // The second review, S10 (R2-J): wipe() called the core's disallow unguarded before anything else, so one that threw
    // stopped signing out's wipe with the node running, the key kept and the cards held.
    test('signing out with a core that throws: the node is stopped first and each call into it guarded, so nothing is left; shutting down the same', () async {
      final a = w.install(w.account('maya'), computer: true), b = w.install(w.account('sam'), computer: true);
      w.friends(a, b);
      await a.start();
      await b.start();
      await w.relayGone();
      expect((await a.text(b.account, 'before')).acked, isTrue);
      a.node.throws.addAll({'disallow', 'allow', 'close', 'networkChanged', 'pathTo', 'openToAll'});
      await a.p2p.wipe();
      expect([a.node.now, a.secrets.kept[P2p.keyName], a.plain.kept[P2p.cardsName]], [P2pState.off, isEmpty, isEmpty]);
      expect([a.p2p.devicesOf(b.account.id), a.p2p.carrier.lines, a.p2p.card], [isEmpty, 0, null]);
      expect(a.node.calls['stop'], 1, reason: 'stopped, before anything else was asked of it');
      // A core that throws from its getters and its stop too: the app closing is not held up, nor broken.
      b.node.throws.addAll({'state', 'whereabouts', 'stop', 'close', 'disallow', 'paths'});
      await b.stop();
      expect(b.running, isFalse);
    });

    // The second review, S16: the link helpers were written after a wipe, and a read of what is kept still under way
    // as the wipe ran wrote a new node key after it.
    test('nothing is written after signing out: not the link helpers the relay names, nor what a read under way as it signed out would make', () async {
      final a = w.install(w.account('maya'), computer: true);
      await a.start();
      await a.p2p.wipe();
      a.p2p.setHelpers(const ['https://after.example']);
      await w.settle();
      expect(a.plain.kept[P2p.helpersName] ?? '', isEmpty);
      // A slow secret store: the app starts, its read of the node key is under way, and it signs out meanwhile.
      final b = w.install(w.account('sam'));
      b.secrets.gate = Completer<void>();
      final starting = b.start();
      await w.until(() => b.secrets.waiting > 0, 'the read of the node key is under way');
      expect(b.p2p.loaded, isFalse);
      final wiping = b.p2p.wipe();
      await w.settle();
      b.secrets.gate!.complete();
      b.secrets.gate = null;
      await wiping;
      await starting;
      await w.settle();
      for (final name in [P2p.idName, P2p.cardName, P2p.cardsName, P2p.toldName, P2p.helpersName]) {
        expect(b.plain.kept[name] ?? '', isEmpty, reason: name);
      }
      expect([b.secrets.kept[P2p.keyName] ?? '', b.p2p.loaded, b.p2p.nodeId], [isEmpty, false, null]);
    });

    test('a node key made under one account is never carried to another', () async {
      final a = w.install(w.account('maya'));
      await a.start();
      final was = a.p2p.nodeId!;
      final key = a.secrets.kept[P2p.keyName];
      await a.stop();
      // The same install, now another account's (signed in to one, with the choices and secrets it had).
      final other = w.install(w.account('someone else'));
      other.secrets.kept.addAll(a.secrets.kept);
      other.plain.kept.addAll(a.plain.kept);
      await other.start();
      expect(other.secrets.kept[P2p.keyName], isNot(key));
      expect(other.p2p.nodeId, isNot(was));
      expect(other.p2p.card!.account, other.account.id);
    });

    // The second review, S8 (R2-C): whose a node key is was kept in the choices (p2p_id) alone; on an iPhone or a Mac the
    // Keychain outlives a deleted app and its choices don't, so a reinstall signing in to another account used the key.
    test('a node key is kept with the account it was made under, and one left by another account is never used, choices or none', () async {
      final first = w.install(w.account('one'));
      await first.start();
      final kept = jsonDecode(first.secrets.kept[P2p.keyName]!) as Map;
      expect([kept['a'], kept['k']], [first.account.id, hasLength(64)]);
      final id = first.p2p.nodeId;
      await first.stop();
      // The app deleted and put back: the Keychain still has the key, the choices are gone. Another account signs in.
      final second = w.install(w.account('two'));
      second.secrets.kept[P2p.keyName] = first.secrets.kept[P2p.keyName]!;
      await second.start();
      expect(second.p2p.nodeId, isNot(id));
      expect((jsonDecode(second.secrets.kept[P2p.keyName]!) as Map)['a'], second.account.id);
      // A key kept with no account named (as the first version kept them) is not taken either.
      final third = w.install(w.account('three'));
      third.secrets.kept[P2p.keyName] = 'ab' * 32;
      await third.start();
      expect(third.p2p.nodeId, isNot(FakeP2pNode.idFor(NetCrypto.unhex('ab' * 32))));
      // The same account after a reinstall keeps its node: the key is its own.
      final again = Install.again(first);
      again.secrets.kept[P2p.keyName] = first.secrets.kept[P2p.keyName]!;
      await again.start();
      expect(again.p2p.nodeId, id);
    });

    test('the node key can\'t be read (a locked secret store): nothing is made or carried until it can', () async {
      final a = w.install(w.account('maya')), b = w.install(w.account('sam'));
      w.friends(a, b);
      await b.start();
      a.secrets.locked = true;
      await a.start();
      expect([a.p2p.loaded, a.p2p.carrier.state.value, a.p2p.nodeId], [false, CarrierState.connecting, null]);
      expect(a.secrets.kept, isEmpty);
      expect(a.p2p.carrier.reaches(a.to(b.account)), isFalse);
      // Sam's card came meanwhile, and is looked at once the store opens.
      expect(a.got.where((r) => r.envelope.kind == P2p.kind), hasLength(1));
      a.secrets.locked = false;
      expect(await a.p2p.tryLoad(), isTrue);
      await w.settle();
      expect([a.p2p.loaded, a.p2p.carrier.state.value], [true, CarrierState.up]);
      expect(a.p2p.devicesOf(b.account.id).single.card, b.p2p.card);
      expect(b.p2p.devicesOf(a.account.id).single.card, a.p2p.card);
    });
  });
}
