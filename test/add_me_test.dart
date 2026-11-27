import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/pending_link.dart';
import 'package:ghost_messaging/desktop/links.dart';
import 'package:ghost_messaging/friends/add_link.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/net/relay_choice.dart' show relayHostForLinks;
import 'package:ghost_messaging/ui/add_me.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/profile.dart';

import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/shell.dart' show AppShell;

import 'support/list_harness.dart';
import 'support/space_call_harness.dart';

/// The add-me link (GMFB-34: "A gogho.st/add/<username> link and QR code that opens a friend request").
class _Friends implements BuddiesPort {
  final asked = <String>[];
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async {
    asked.add(username);
    return (id: 'b' * 32, key: base64Encode(List.filled(65, 4)));
  }

  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => '[]';
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

/// A directory that answers with a real key pair for each username it holds, and a friends list that writes down what
/// it keeps and sends.
class _Keyed implements BuddiesPort {
  final names = <String, NetKeys>{};
  final sent = <Envelope>[];
  String list = '[]';
  @override
  Future<({String id, String key})> me() async => (id: 'a' * 32, key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async {
    final k = names[username];
    return k == null ? null : (id: k.id, key: base64Encode(k.public));
  }

  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async {
    sent.add(envelope);
    return true;
  }

  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

void main() {
  test('the link carries the account\'s whole name after #, never sent to a server; the app refuses the relay\'s answer where its key doesn\'t make that name, and keeps and sends nothing', () async {
    final maya = NetKeys.generate(), mallory = NetKeys.generate();
    final link = addMeLink('maya', id: maya.id);
    // All 32 hex digits (the review, S3): eight were 32 bits, which a relay could search out a key to match.
    expect(link, 'https://gogho.st/add/maya#${maya.id}');
    expect(keyDigits, 32);
    expect([addLinkUsername(link), addLinkKey(link)], ['maya', maya.id]);
    expect(addLinkKey('ghostmsg://add/maya#${maya.id.toUpperCase()}'), maya.id, reason: 'the page passes it on as it is');
    // A link from before, with eight, is still taken as it says.
    expect(addLinkKey('https://gogho.st/add/maya#${maya.id.substring(0, 8)}'), maya.id.substring(0, 8));
    expect([addLinkKey('https://gogho.st/add/maya'), addLinkKey('https://gogho.st/add/maya#1234'), addLinkKey('https://gogho.st/add/maya#not-a-key'), addLinkKey('https://evil.example/add/maya#${maya.id.substring(0, 8)}')], [isNull, isNull, isNull, isNull]);
    expect(addMeLink('maya'), 'https://gogho.st/add/maya', reason: 'with no account name, a link from before');

    final port = _Keyed()..names['maya'] = mallory;
    final b = Buddies(port);
    await b.start();
    // The relay gives @maya to someone else: refused, nothing kept, nothing sent.
    await expectLater(b.add('maya', keyPrefix: addLinkKey(link)), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('different key'))));
    expect([b.all, port.sent, port.list], [isEmpty, isEmpty, '[]']);
    // The key the link names: asked.
    port.names['maya'] = maya;
    final got = await b.add('maya', keyPrefix: addLinkKey(link));
    expect([got.id, got.state, port.sent.single.kind], [maya.id, 'asked', 'hello']);
    // A link from before, with no key: as ever.
    port.names['sam'] = mallory;
    expect((await b.add('sam')).id, mallory.id);
    expect(Buddies.keyMatches((id: maya.id, key: base64Encode(mallory.public)), maya.id.substring(0, 8)), isFalse, reason: 'a name that is not its key\'s');
    b.dispose();
  });

  test('on a computer an add-me link is known for one, not taken for a circle\'s (GMFB-34)', () {
    expect(DeskLinks.isAddLink('ghostmsg://add/maya#0123456789abcdef0123456789abcdef'), isTrue);
    expect(DeskLinks.isAddLink(' https://gogho.st/add/maya '), isTrue);
    expect(DeskLinks.isAddLink('ghostmsg://join/#c.abc'), isFalse);
    expect(DeskLinks.isAddLink('ghostmsg://relay?a=x'), isFalse);
    expect(DeskLinks.isAddLink('ghostmsg://add/'), isFalse);
  });

  test('an add-me link that started the app (Linux, an iPhone, a Mac or a PC not running) is taken on "ghost_desktop/links" and held until the frame is up, once (GMFB-34)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const link = 'ghostmsg://add/maya#0123456789abcdef0123456789abcdef';
    final asked = <String>[];
    // What linux/runner/links.cc, ios/Runner/SceneDelegate.swift, the Mac's AppDelegate and windows/runner/links.cpp
    // answer: "take", with the links that came before the app asked, the fragment (the account's name) kept whole.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_desktop/links'), (call) async {
      asked.add(call.method);
      return call.method == 'take' ? <String>[link] : null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_desktop/links'), null));
    await DeskLinks.start();
    expect(asked, ['take']);
    expect(DeskLinks.takeHeldAdd(), link, reason: 'no frame yet: held for it');
    expect(DeskLinks.takeHeldAdd(), isNull, reason: 'asked about once');
  });

  test('a pairing link opened into the app (an iPhone\'s camera) is let go, not held as a circle\'s or an add-me link', () async {
    final wrote = <String>[];
    final read = PendingCircleLink.readPrefs, write = PendingCircleLink.writePref;
    PendingCircleLink.readPrefs = () async => {};
    PendingCircleLink.writePref = (k, v) async => wrote.add('$k=$v');
    addTearDown(() {
      PendingCircleLink.readPrefs = read;
      PendingCircleLink.writePref = write;
    });
    await DeskLinks.opened('ghostmsg://pair/eyJ2IjoxfQ');
    expect(wrote, isEmpty);
    expect(DeskLinks.takeHeldAdd(), isNull);
  });

  test('the link and the names it can carry', () {
    expect(addMeLink('maya'), 'https://gogho.st/add/maya');
    expect(addLinkUsername('https://gogho.st/add/maya'), 'maya');
    expect(addLinkUsername('https://gogho.st/add/@Maya.Chen/'), 'maya.chen');
    expect(addLinkUsername('ghostmsg://add/maya_c'), 'maya_c', reason: 'the page\'s Open in Uplink');
    expect(addLinkUsername('https://gogho.st/add/ab'), isNull, reason: 'too short to be a username');
    expect(addLinkUsername('https://evil.example/add/maya'), isNull);
    expect(addLinkUsername('https://gogho.st/c/maya'), isNull, reason: 'a circle\'s invite word');
  });

  // GMFB-25: a username is a name on one relay, and a link named none, so on a relay of one's own it found whoever held
  // the name there, or nobody.
  test('a link from someone on a relay of their own says which, after the key; one that names none is Uplink\'s', () {
    final id = 'ab' * 16;
    expect(addMeLink('maya', id: id), 'https://gogho.st/add/maya#$id');
    expect(addMeLink('maya', id: id, relay: 'Relay.Example.com'), 'https://gogho.st/add/maya#$id@relay.example.com');
    expect(addMeLink('maya', id: id, relay: 'relay.example.com:8443'), 'https://gogho.st/add/maya#$id@relay.example.com:8443');
    expect(addMeLink('maya', id: id, relay: 'not a host'), 'https://gogho.st/add/maya#$id', reason: 'nothing that could not be a host');
    expect(addMeLink('maya', relay: 'relay.example.com'), 'https://gogho.st/add/maya', reason: 'never a relay without the key that holds its answer');
    final link = addMeLink('maya', id: id, relay: 'relay.example.com');
    expect([addLinkUsername(link), addLinkKey(link), addLinkRelay(link)], ['maya', id, 'relay.example.com']);
    expect([addLinkKey('ghostmsg://add/maya#$id@Relay.Example.com:8443'), addLinkRelay('ghostmsg://add/maya#$id@Relay.Example.com:8443')], [id, 'relay.example.com:8443'], reason: 'as the page hands it to the app');
    expect([addLinkKey('https://gogho.st/add/maya#$id'), addLinkRelay('https://gogho.st/add/maya#$id')], [id, null]);
    expect(addLinkRelay('https://gogho.st/add/maya#@relay.example.com'), isNull, reason: 'no key, no relay');
    expect([addLinkKey('https://gogho.st/add/maya#$id@'), addLinkRelay('https://gogho.st/add/maya#$id@')], [id, null]);
    expect(addLinkRelay('https://gogho.st/add/maya#$id@localhost'), isNull);
    expect(addLinkRelay('https://gogho.st/add/maya#$id@relay.example.com/../x'), isNull);
    // The relay in use, as a link names it.
    expect(relayHostForLinks('wss://gogho.st/hub'), isNull);
    expect(relayHostForLinks('wss://relay.example.com/hub'), 'relay.example.com');
    expect(relayHostForLinks('wss://Relay.Example.com:8443/hub'), 'relay.example.com:8443');
    expect(relayHostForLinks('wss://relay.example.com:443/hub'), 'relay.example.com');
    expect(relayHostForLinks('ws://192.168.1.20:7787/hub'), isNull, reason: 'nobody elsewhere could dial it');
    expect(relayHostForLinks('ghost-relay://${'c' * 32}?n=${'d' * 64}'), isNull);
  });

  test('where a link\'s person is asked for: here where they are on this app\'s relay, of their own relay where they are on another, and of Uplink\'s after this one where the link names none', () {
    const own = 'wss://relay.example.com/hub';
    bool nowhere(String _) => false;
    // On Uplink's relay, a link that names none: as ever.
    expect(addPlan('maya', theirs: null, mine: null, onDefault: true, hubUrl: 'wss://gogho.st/hub', hasKey: true, here: nowhere), (ask: 'maya', then: null, note: null));
    // On Uplink's relay, a link from someone on their own.
    final other = addPlan('maya', theirs: 'relay.example.com', mine: null, onDefault: true, hubUrl: 'wss://gogho.st/hub', hasKey: true, here: nowhere);
    expect([other.ask, other.then], ['maya@relay.example.com', null]);
    expect(other.note, '@maya is on relay.example.com, another relay than yours. The request goes from your relay to theirs, where both pass messages to each other; if they don\'t yet, it is sent again by itself for two weeks.');
    // On a relay of one's own, a link from someone on the same one: looked up here, nothing to say.
    expect(addPlan('maya', theirs: 'relay.example.com', mine: 'relay.example.com', onDefault: false, hubUrl: own, hasKey: true, here: nowhere), (ask: 'maya', then: null, note: null));
    // The same relay under another of its names.
    expect(addPlan('maya', theirs: 'www.relay.example.com', mine: 'relay.example.com', onDefault: false, hubUrl: own, hasKey: true, here: (h) => h == 'www.relay.example.com').ask, 'maya');
    // On a relay of one's own, a link that names none: here first, then Uplink's, both held to the key.
    final unnamed = addPlan('maya', theirs: null, mine: 'relay.example.com', onDefault: false, hubUrl: own, hasKey: true, here: nowhere);
    expect([unnamed.ask, unnamed.then], ['maya', 'maya@gogho.st']);
    expect(unnamed.note, contains('this link names no relay. @maya is looked for there first, then on Uplink\'s relay'));
    // With no key to hold an answer to (a link from before): here alone, with the warning there always was.
    final old = addPlan('maya', theirs: null, mine: 'relay.example.com', onDefault: false, hubUrl: own, hasKey: false, here: nowhere);
    expect([old.ask, old.then, old.note], ['maya', null, addMeElsewhereWords(own, 'maya')]);
  });

  testWidgets('an opened link whose key the relay\'s answer doesn\'t match is refused on screen, and nothing is sent', (tester) async {
    final maya = NetKeys.generate(), mallory = NetKeys.generate();
    final port = _Keyed()..names['maya'] = mallory;
    Buddies.instance = Buddies(port);
    addTearDown(() => Buddies.instance = null);
    await tester.runAsync(() => Buddies.instance.start());
    final h = await SpaceHarness.load(tester);
    await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'matt'), ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
    await h.shoot(tester, const GhostPage(title: 'Messages', body: SizedBox()), 'add-me-wrong-key');
    askToAdd(tester.element(find.text('Messages')), addMeLink('maya', id: maya.id));
    await tester.pump(const Duration(milliseconds: 400));
    await h.again(tester, 'add-me-wrong-key-open');
    await tester.tap(find.text('Send a friend request'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('The relay gave @maya to a different key than the link names'), findsOneWidget);
    expect([port.sent, Buddies.instance.all], [isEmpty, isEmpty]);
    await tester.pump(const Duration(seconds: 5));
  });

  group('on screen', () {
    late _Friends friends;
    setUp(() async {
      friends = _Friends();
      Buddies.instance = Buddies(friends);
      await Buddies.instance.start();
    });
    tearDown(() => Buddies.instance = null);

    testWidgets('an opened link asks first, then sends the request', (tester) async {
      final h = await SpaceHarness.load(tester);
      await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'matt'), ValueNotifier(0), () => null));
      addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
      await h.shoot(tester, const GhostPage(title: 'Messages', body: SizedBox()), 'add-me-ask');
      askToAdd(tester.element(find.text('Messages')), 'https://gogho.st/add/maya');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Send @maya a friend request?'), findsOneWidget);
      expect(friends.asked, isEmpty, reason: 'nothing sent before the yes');
      await h.again(tester, 'add-me-ask-open');
      await tester.tap(find.text('Send a friend request'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 400));
      expect(friends.asked, ['maya']);
      expect(Buddies.instance.all.single.username, 'maya');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('an add-me link held from before the frame was up is asked about once the frame is on the screen (GMFB-34)', (tester) async {
      ListPhone(const []).install();
      await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'matt'), ValueNotifier(0), () => null));
      addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
      await DeskLinks.opened('ghostmsg://add/maya');
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppShell(), AppState());
      await settle(tester);
      expect(find.text('Send @maya a friend request?'), findsOneWidget);
      expect(friends.asked, isEmpty, reason: 'nothing sent before the yes');
      expect(DeskLinks.takeHeldAdd(), isNull, reason: 'taken by the frame');
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Profile has the add-me link and its QR code', (tester) async {
      final h = await SpaceHarness.load(tester);
      await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'matt'), ValueNotifier(0), () => null));
      addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
      await h.shoot(tester, const ProfileScreen(), 'add-me-profile', size: const Size(412, 3400));
      expect(find.text('gogho.st/add/matt'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('add-me-qr')));
      await tester.tap(find.byKey(const ValueKey('add-me-qr')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('add-me-code')), findsOneWidget);
      await h.again(tester, 'add-me-code');
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
