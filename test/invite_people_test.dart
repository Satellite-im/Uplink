import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/inbox/people.dart';
import 'package:ghost_messaging/invites/invite_relay.dart';
import 'package:ghost_messaging/invites/invite_seal.dart';
import 'package:ghost_messaging/invites/pending_invites.dart';
import 'package:ghost_messaging/invites/text_invites.dart';
import 'package:ghost_messaging/kit/semantic_colors.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostLogo;
import 'package:ghost_messaging/ui/invite_people.dart';
import 'package:ghost_messaging/ui/space_invite.dart';
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

// Adding people to a space or circle (lib/ui/invite_people.dart, lib/invites/; Matt, 2026-11-17: "when adding people
// to the space we should have a suggested list of our contacts to add if they're not on ghost yet it should send them
// a text saying they've been invited to join a space in ghost with a link that eventually follows through after they
// setup their account sort the list by friends on ghost first").
//
// Pictures, with THEME_SHOTS=1: build/invite_people/<look>-<brightness>-<width>-<state>.png.

class _KeptBuddies implements BuddiesPort {
  _KeptBuddies(this.list);
  final List<Buddy> list;
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => jsonEncode([for (final b in list) b.toJson()]);
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

const _friends = [
  Buddy(username: 'maya', id: 'maya-id', key: 'k', name: 'Maya Chen'),
  Buddy(username: 'sam', id: 'sam-id', key: 'k', name: 'Sam Ortiz'),
  Buddy(username: 'riley', id: 'riley-id', key: 'k', name: 'Riley Fox'),
];

/// The phone's contacts: one a friend by number (on Uplink), the rest not on it.
final _contacts = gather(const [
  PhoneContact(address: '+15550100142', name: 'Alex Rivera', label: 'Mobile'),
  PhoneContact(address: '(555) 010-0177', name: 'Bea Okafor'),
  PhoneContact(address: '+447700900123', name: 'Callum Reid'),
  PhoneContact(address: '+15550100155', name: 'Theo Park', friend: true),
  PhoneContact(address: '+15550100166', name: 'Dana Whit'),
], const []);

final _channel = VoiceChannel(seed: 'a' * 64, name: 'Friday hang');

/// The inviting install's key, which signs each copy left.
final _inviter = NetKeys.generate();

/// The relay's keeper of invites, in memory, as relay/lib/invites.dart answers: the install that verified [verified]
/// is the one handed its invites.
class _Relay {
  _Relay({this.verified});
  String? verified;
  final waiting = <String, List<Map<String, Object>>>{};
  final asked = <Map<String, Object?>>[];
  var next = 0;

  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    asked.add(what);
    switch (what['dir']) {
      case 'invite':
        for (final e in what['list'] as List) {
          final m = e as Map;
          final list = waiting[m['h'] as String] ??= [];
          list.removeWhere((x) => m['t'] != null && x['t'] == m['t']);
          list.add({'i': 'i${next++}', 'b': m['b'] as String, 'at': 1763380800000, if (m['t'] != null) 't': m['t'] as String});
        }
        return {'dir': 'invite', 'left': (what['list'] as List).length};
      case 'invites':
        if (verified == null || numberHash(verified!) != what['h']) throw const InviteRelayError('Verify this number first.');
        return {'dir': 'invites', 'h': what['h'], 'list': [for (final e in waiting[what['h']] ?? const <Map<String, Object>>[]) {'i': e['i'], 'b': e['b'], 'at': e['at']}]};
      case 'invites-drop':
        final ids = (what['ids'] as List).toSet();
        waiting[what['h'] as String]?.removeWhere((e) => ids.contains(e['i']));
        return {'dir': 'invites-drop', 'left': waiting[what['h']]?.length ?? 0};
    }
    throw StateError('${what['dir']}');
  }
}

class _Offers implements InviteOffers {
  final offered = <WaitingInvite>[];
  bool holds = true;
  @override
  bool offer(WaitingInvite invite) {
    offered.add(invite);
    return holds;
  }
}

class _Opener extends StatefulWidget {
  const _Opener(this.open);
  final void Function(BuildContext context) open;
  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// The page under a sheet drawn on its own, with the scrim its route would lay.
class _Under extends StatelessWidget {
  const _Under(this.child);
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(color: t.color('app-paper'), child: ColoredBox(color: t.sheetScrim, child: child));
  }
}

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The slow sealing done in place: a widget test's clock is its own, and another isolate's answer would wait on it.
  setUpAll(() => inviteWorker = <R>(work) async => await work());
  setUp(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    m.setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
  });

  group('the sealed copy', () {
    const hers = '+15550100199';
    final invite = WaitingInvite(kind: 'space', link: _channel.link, name: 'Friday hang', by: 'Matt');

    test('opens for the number it was sealed for, and for no other; the relay\'s hash is not its key', () {
      final blob = sealInvite(hers, invite);
      final back = openInvite(hers, blob)!;
      expect((back.kind, back.link, back.name, back.by), ('space', _channel.link, 'Friday hang', 'Matt'));
      expect(back.signer, isNull, reason: 'not signed');
      expect(openInvite('+15550100198', blob), isNull);
      expect(utf8.decode(base64Decode(blob), allowMalformed: true), isNot(contains('Friday')), reason: 'sealed, not encoded');
      final salt = base64Decode(blob).sublist(1, 17);
      expect(NetCrypto.hex(sealKey(hers, salt)), isNot(numberHash(hers)));
      expect(sealInvite(hers, invite), isNot(blob), reason: 'a fresh salt each time: one guess at a number opens one blob');
    });

    test('a signature names the install that signed it for this number, and no other number', () {
      final keys = NetKeys.generate();
      final sig = NetCrypto.sign(keys, inviteSigned(hers, invite));
      final blob = sealInvite(hers, invite, publicKey: keys.public, signature: sig);
      expect(openInvite(hers, blob)!.signer, keys.id);
      // The same signature moved to another number's invite does not check out.
      final moved = sealInvite('+15550100198', invite, publicKey: keys.public, signature: sig);
      expect(openInvite('+15550100198', moved)!.signer, isNull);
      // A friend's name is shown only where the friend's install signed it.
      final buddies = Buddies(_KeptBuddies([Buddy(username: 'maya', id: keys.id, key: 'k', name: 'Maya Chen')]));
      expect(inviteFrom(openInvite(hers, blob)!, buddies: buddies), isNot('Maya Chen'), reason: 'before the friends are read');
      return buddies.start().then((_) {
        expect(inviteFrom(openInvite(hers, blob)!, buddies: buddies), 'Maya Chen');
        final forged = sealInvite(hers, const WaitingInvite(kind: 'space', link: 'https://gogho.st/join/#x', name: 'Family', by: 'Mom'));
        expect(inviteFrom(openInvite(hers, forged)!, buddies: buddies), 'Someone (not a friend)', reason: 'never the name written in it');
      });
    });

    test('kept by the hash the relay links a verified number by (Handles.keyOf), however the number is written', () {
      expect(numberHash(hers), NetCrypto.hex(NetCrypto.sha256(utf8.encode('ghost-handle v1|phone|$hers'))));
      expect(numberHash(hers), handleKey('phone', hers));
      for (final written in ['(555) 010-0199', '555.010.0199', '1 555 010 0199', '+1 555 010 0199']) {
        expect(inviteNumber(written), hers, reason: written);
      }
      expect(inviteNumber('07700 900123'), isNull, reason: 'a local number abroad has no country to key it by');
      expect(inviteNumber('+447700900123'), '+447700900123');
    });

    test('a contact saved without a country is taken as North American only where the inviter\'s own number is', () {
      expect(copyNumber('+447700900123'), '+447700900123', reason: 'a "+" says its country');
      expect(copyNumber('(555) 010-0177', own: '+15550100100'), '+15550100177');
      expect(copyNumber('(555) 010-0177'), isNull, reason: 'the inviter\'s country unknown');
      expect(copyNumber('98765 43210', own: '+919800000000'), isNull, reason: 'an Indian mobile is not an American number');
      expect(copyNumber('138 1234 5678', own: '+8613800000000'), isNull, reason: 'nor a Chinese one');
    });

    test('only an invite to a place in the app opens: another address is not offered', () {
      final salt = List.filled(16, 7);
      final odd = base64Encode([2, ...salt, ...NetCrypto.seal(sealKey(hers, salt), utf8.encode(jsonEncode({'v': 1, 'k': 'space', 'l': 'https://example.com/x', 'n': 'X', 'by': ''})))]);
      expect(openInvite(hers, odd), isNull);
    });

    test('the text says who invited them, to what, and the link; without a name, nobody\'s', () {
      expect(inviteText(me: 'Matt', name: 'Friday hang', link: 'L'), 'Matt invited you to join Friday hang on Uplink: L');
      expect(inviteText(me: ' ', name: 'Book club', link: 'L'), 'You\'re invited to join Book club on Uplink: L');
    });
  });

  group('texts and copies', () {
    test('one text each, and a copy left for each reached who has a whole number and is not on the app', () async {
      final sent = <(List<String>, String)>[];
      final relay = _Relay();
      final texts = TextInvites(
        sendText: (to, words) async {
          if (to.single == '+15550100166') throw Exception('no signal');
          sent.add((to, words));
          return 1;
        },
        ask: relay.ask,
        ownNumber: () async => '+15550100100',
        signer: () => KeysSigner(_inviter),
      );
      final invite = WaitingInvite(kind: 'circle', link: 'https://gogho.st/join/#c.${'b' * 64}.Qm9vaw', name: 'Book club', by: 'Matt');
      final failed = await texts.send(const [
        TextInvitee('Alex', '+15550100142'),
        TextInvitee('Bea', '(555) 010-0177'),
        TextInvitee('Local', '07700 900123'),
        TextInvitee('Theo', '+15550100155', onGhost: true),
        TextInvitee('Dana', '+15550100166'),
      ], invite, 'words');
      expect(failed.map((f) => f.name), ['Dana']);
      expect(sent.map((s) => s.$1.single), ['+15550100142', '(555) 010-0177', '07700 900123', '+15550100155'], reason: 'never one group text');
      expect(await texts.left, 2, reason: 'Alex and Bea: not the local number, not Theo on the app, not Dana unreached');
      expect(relay.waiting.keys.toSet(), {numberHash('+15550100142'), numberHash('+15550100177')});
      expect(jsonEncode(relay.asked), isNot(contains('5550100142')), reason: 'the relay is told no number');
      // The same invite again replaces the copy before.
      await texts.leave(const [TextInvitee('Alex', '+15550100142')], invite);
      expect(relay.waiting[numberHash('+15550100142')], hasLength(1));
      // Signed by this install for each number.
      expect(openInvite('+15550100142', relay.waiting[numberHash('+15550100142')]!.single['b'] as String)!.signer, _inviter.id);
      // Where the inviter's own country is not known, the contact saved without one gets no copy.
      final unsure = TextInvites(sendText: (_, _) async => 1, ask: relay.ask, ownNumber: () async => null);
      expect(await unsure.leave(const [TextInvitee('Bea', '(555) 010-0188'), TextInvitee('Alex', '+15550100143')], invite), 1);
    });
  });

  group('taken once the number is verified', () {
    const hers = '+15550100199';
    final space = WaitingInvite(kind: 'space', link: _channel.link, name: 'Friday hang', by: 'Matt');
    final circle = WaitingInvite(kind: 'circle', link: 'https://gogho.st/join/#c.${'b' * 64}.Qm9vaw', name: 'Book club', by: 'Maya');

    test('fetched, opened, offered, and dropped from the relay once held; one not held stays', () async {
      final relay = _Relay(verified: hers);
      await TextInvites(sendText: (_, _) async => 1, ask: relay.ask, ownNumber: () async => null).leave(const [TextInvitee('her', hers)], space);
      await TextInvites(sendText: (_, _) async => 1, ask: relay.ask, ownNumber: () async => null).leave(const [TextInvitee('her', hers)], circle);
      // Something sealed for another number under hers: dropped, never offered.
      relay.waiting[numberHash(hers)]!.add({'i': 'junk', 'b': sealInvite('+15550100198', space), 'at': 0});
      final offers = _Offers();
      final p = PendingInvites(ask: relay.ask, offers: offers);
      expect(await p.take(hers), 2);
      expect(offers.offered.map((o) => (o.kind, o.name, o.by)), [('space', 'Friday hang', 'Matt'), ('circle', 'Book club', 'Maya')]);
      expect(relay.waiting[numberHash(hers)], isEmpty);

      await TextInvites(sendText: (_, _) async => 1, ask: relay.ask, ownNumber: () async => null).leave(const [TextInvitee('her', hers)], space);
      offers.holds = false;
      expect(await p.take(hers), 0);
      expect(relay.waiting[numberHash(hers)], hasLength(1), reason: 'not held here: asked for again next time');
    });

    test('a space from a waiting invite is offered, not joined: not among the spaces until Join', () async {
      final v = Voice.instance;
      final c = VoiceChannel(seed: 'c' * 64, name: 'Stranger\'s room', kind: SpaceKind.text);
      final invite = WaitingInvite(kind: 'space', link: c.link, name: c.name, by: 'Mom');
      expect(const AppInviteOffers().offer(invite), isTrue, reason: 'held here, so the relay\'s copy can go');
      expect(v.own.any((o) => o.seed == c.seed), isFalse, reason: 'nothing joined, named or held before Join');
      expect(v.offers.map((o) => o.channel.seed), [c.seed]);
      expect((v.ringing?.offer, v.ringing?.from), (true, 'Someone (not a friend)'), reason: 'never the name written in it');
      // Not now keeps it, for the next time the app opens; it is still not among the spaces.
      v.dismissRing();
      expect(v.ringing, isNull);
      expect(v.offers, hasLength(1));
      expect(v.own.any((o) => o.seed == c.seed), isFalse);
      // Join puts it among the spaces.
      await v.acceptOffer(v.offers.single);
      expect(v.own.any((o) => o.seed == c.seed), isTrue);
      expect(v.offers, isEmpty);
      v.own = [for (final o in v.own) if (o.seed != c.seed) o];
    });

    test('asked when the number is verified and the relay met, not before; not again within the hour', () async {
      final relay = _Relay(verified: hers);
      final me = Me.forTest();
      final places = ValueNotifier(0);
      var clock = DateTime(2026, 11, 17, 12);
      final p = PendingInvites(me: me, ask: relay.ask, offers: _Offers(), now: () => clock, waitFor: places);
      p.start();
      int asks() => relay.asked.where((a) => a['dir'] == 'invites').length;
      me.ready = true;
      me.setProfile();
      await Future<void>.delayed(Duration.zero);
      expect(asks(), 0, reason: 'no number verified');
      me.links = {'phone': hers};
      me.setProfile();
      await Future<void>.delayed(Duration.zero);
      expect(asks(), 0, reason: 'the circles and spaces have not started: an offer would be written over');
      places.value++;
      await Future<void>.delayed(Duration.zero);
      expect(asks(), 1);
      me.setProfile();
      await Future<void>.delayed(Duration.zero);
      expect(asks(), 1, reason: 'not again within the hour');
      clock = clock.add(const Duration(minutes: 61));
      me.setProfile();
      await Future<void>.delayed(Duration.zero);
      expect(asks(), 2);
    });
  });

  group('the sheet', () {
    late Buddies buddies;

    Future<void> open(WidgetTester tester, {List<Buddy> friends = _friends, List<Someone>? contacts, TextInvites? texts, bool canText = true, Set<String> inSpace = const {'riley-id'}, List<List<String>>? sent}) async {
      tester.view.physicalSize = const Size(412, 892) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      buddies = Buddies(_KeptBuddies(friends));
      await tester.runAsync(buddies.start);
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final state = AppState();
      await tester.pumpWidget(AppScope(
        state: state,
        child: WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
          home: _Opener((context) => showSpaceInvite(
                context,
                _channel,
                buddies: buddies,
                inSpace: inSpace,
                contacts: () async => contacts ?? _contacts,
                texts: texts,
                canText: canText,
                send: (c, fs) async {
                  sent?.add([for (final f in fs) f.username]);
                  return const [];
                },
              )),
        ),
      ));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('friends on Uplink first, marked, then the contacts; a search narrows both', (tester) async {
      await open(tester);
      final order = [for (final name in ['Maya Chen', 'Riley Fox', 'Sam Ortiz', 'Theo Park', 'Alex Rivera', 'Bea Okafor', 'Callum Reid', 'Dana Whit']) tester.getTopLeft(find.text(name)).dy];
      expect(order, [...order]..sort(), reason: 'friends (by username and by number) by name, then the contacts');
      expect(find.text('On Uplink'), findsOneWidget);
      expect(find.text('Contacts · invited by text'), findsOneWidget);
      expect(find.byType(GhostLogo), findsNWidgets(4), reason: 'the mark beside each on the app');
      expect(find.bySemanticsLabel(RegExp(r'^Theo Park, on Uplink')), findsOneWidget);
      expect(find.text('In the space'), findsOneWidget, reason: 'Riley is in it');
      await tester.enterText(find.byType(EditableText), 'bea');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Bea Okafor'), findsOneWidget);
      expect(find.text('Maya Chen'), findsNothing);
      // A whole number nobody has is offered to text.
      await tester.enterText(find.byType(EditableText), '555 010 0188');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Not in your contacts · by text'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a friend and two contacts: asked first, then the friend sent it in the app and each contact texted', (tester) async {
      final texted = <(String, String)>[];
      final relay = _Relay();
      final sent = <List<String>>[];
      await open(tester, sent: sent, texts: TextInvites(sendText: (to, words) async {
            texted.add((to.single, words));
            return 1;
          }, ask: relay.ask, ownNumber: () async => '+15550100100'));
      await tester.tap(find.text('Maya Chen'));
      await tester.tap(find.text('Alex Rivera'));
      await tester.tap(find.text('Bea Okafor'));
      await tester.pump();
      expect(find.text('Send 3 invites'), findsOneWidget);
      expect(find.text('1 in the app, 2 by text'), findsOneWidget);
      await tester.tap(find.text('Send 3 invites'));
      await tester.pump();
      expect(find.text('Send 2 invites by text?'), findsOneWidget);
      expect(sent, isEmpty, reason: 'nothing goes before the texts are agreed to');
      expect(texted, isEmpty);
      // Back, then again, and Send.
      await tester.tap(find.text('Back'));
      await tester.pump();
      expect(find.text('Send 2 invites by text?'), findsNothing);
      await tester.tap(find.text('Send 3 invites'));
      await tester.pump();
      await tester.tap(find.text('Send 2 texts'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(sent, [
        ['maya'],
      ]);
      // Under the name this install goes by (none in a test: "You're invited …").
      final words = inviteText(me: inviterName(), name: 'Friday hang', link: _channel.link);
      expect(texted, [('+15550100142', words), ('(555) 010-0177', words)]);
      expect(relay.waiting.keys.toSet(), {numberHash('+15550100142'), numberHash('+15550100177')}, reason: 'waiting for them on the relay');
      expect(find.text('Invited 3'), findsWidgets);
      expect(find.text('Invite people'), findsNothing, reason: 'the sheet goes');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with no texts here (an iPhone of its own) the share sheet opens with the words', (tester) async {
      final shared = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
        if (call.method == 'shareText') shared.add((call.arguments as Map)['text'] as String);
        return null;
      });
      final relay = _Relay();
      await open(tester, canText: false, texts: TextInvites(sendText: (_, _) async => throw StateError('no texts here'), ask: relay.ask));
      await tester.tap(find.text('Alex Rivera'));
      await tester.pump();
      await tester.tap(find.text('Send invite'));
      await tester.pump();
      expect(find.text('Share the invite with Alex Rivera?'), findsOneWidget);
      await tester.tap(find.text('Share invite'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(shared, [inviteText(me: inviterName(), name: 'Friday hang', link: _channel.link)]);
      expect(relay.asked, isEmpty, reason: 'no copies: the share sheet does not say whether it went, or to whom');
      await tester.pumpWidget(const SizedBox());
    });

    /// The sheet drawn on its own, for what the route does not change.
    Future<void> bare(WidgetTester tester, {Buddy? Function(String number)? buddyOf, TextInvites? texts, List<List<String>>? sent}) async {
      tester.view.physicalSize = const Size(412, 892) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      buddies = Buddies(_KeptBuddies(_friends));
      await tester.runAsync(buddies.start);
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final state = AppState();
      final target = InviteTarget.space(_channel, send: (_, fs) async {
        sent?.add([for (final f in fs) f.username]);
        return const [];
      }, words: spaceInviteWords(_channel));
      await tester.pumpWidget(AppScope(
        state: state,
        child: WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
          home: InvitePeopleSheet(target: target, buddies: buddies, contacts: () async => _contacts, texts: texts, compose: (_) {}, me: '', canText: true, buddyOf: buddyOf),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('a friend by number drawn as a friend, saying a text opens in the app; one who is a username friend is listed once', (tester) async {
      await bare(tester, buddyOf: (_) => null);
      expect(find.text('+15550100155 · text, opens in the app'), findsOneWidget);
      expect(find.text('+15550100155 · by text'), findsNothing, reason: '"by text" is for contacts not on the app');
      await tester.pumpWidget(const SizedBox());

      // Theo's number is Maya's install: one row, Maya's, sent it in the app.
      final sent = <List<String>>[];
      await bare(tester, buddyOf: (n) => n == '+15550100155' ? _friends.first : null, sent: sent);
      expect(find.text('Theo Park'), findsNothing);
      await tester.tap(find.text('Maya Chen'));
      await tester.pump();
      await tester.tap(find.text('Send invite'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(sent, [
        ['maya'],
      ]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('two presses on Send in one frame send once', (tester) async {
      final texted = <String>[];
      await bare(tester, buddyOf: (_) => null, texts: TextInvites(sendText: (to, _) async {
            texted.add(to.single);
            return 1;
          }, ask: _Relay().ask, ownNumber: () async => null));
      await tester.tap(find.text('Alex Rivera'));
      await tester.pump();
      await tester.tap(find.text('Send invite'));
      await tester.pump();
      // Pressed twice before the button can be built again greyed: the press itself, twice over.
      final press = tester.widget<GlacierPressable>(find.descendant(of: find.byKey(const ValueKey('invite-confirm')), matching: find.byType(GlacierPressable))).onPressed!;
      press();
      press();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(texted, ['+15550100142'], reason: 'one text, not two');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('nobody at all: says so, offers a friend, and no button for nobody', (tester) async {
      await open(tester, friends: const [], contacts: const []);
      expect(find.textContaining('No friends here yet'), findsOneWidget);
      expect(find.text('Add a friend'), findsOneWidget);
      expect(find.text('Send invites'), findsNothing);
      expect(find.text('Copy invite link'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // The pictures: friends first, contacts, three chosen, and the question before the texts, in Uplink light and dark and
  // Dial-Up, on a phone, a Fold open and a computer's window. Each drawn without an exception (an overflow is one).
  testWidgets('drawn in Uplink light and dark and Dial-Up, at a phone\'s, a Fold\'s and a computer\'s width', (tester) async {
    final shots = Platform.environment['THEME_SHOTS'] == '1';
    await tester.runAsync(_fonts);
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final buddies = Buddies(_KeptBuddies(_friends));
    await tester.runAsync(buddies.start);
    final target = InviteTarget.space(_channel, send: (_, _) async => const [], inside: () => {'riley-id'}, words: spaceInviteWords(_channel));
    const chosen = {'b:maya-id', 'n:5550100142', 'n:5550100177'};
    final widths = {'phone': const Size(412, 892), 'fold': const Size(884, 1060), 'desktop': const Size(1280, 820)};
    for (final (look, b) in [(Look.ghost, 'light'), (Look.ghost, 'dark'), (Look.dialup, 'light')]) {
      for (final w in widths.entries) {
        for (final (name, asking) in [('chosen', false), ('confirm', true)]) {
          tester.view.physicalSize = w.value * 2.0;
          tester.view.devicePixelRatio = 2.0;
          tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
          final state = AppState()
            ..setTheme(b)
            ..setLook(look);
          final shot = '${look.name}-$b-${w.key}-$name';
          await tester.pumpWidget(AppScope(
            state: state,
            child: WidgetsApp(
              key: ValueKey(shot),
              color: const Color(0xFF000000),
              debugShowCheckedModeBanner: false,
              pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder bb) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => bb(c)),
              builder: (context, child) => GlacierTheme(
                sheet: sheet,
                attrs: ghostAttrs(state, w.key == 'desktop' ? 'desktop' : 'mobile'),
                typography: ghostTypography('noto'),
                child: InkOverrides(child: GlacierToastProvider(child: child!)),
              ),
              home: _Under(InvitePeopleSheet(
                target: target,
                buddies: buddies,
                contacts: () async => _contacts,
                compose: (_) {},
                me: 'Matt',
                canText: true,
                chosen: chosen,
                asking: asking,
              )),
            ),
          ));
          for (var i = 0; i < 10; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(tester.takeException(), isNull, reason: shot);
          expect(find.text(asking ? 'Send 2 invites by text?' : 'Send 3 invites'), findsOneWidget, reason: shot);
          if (shots) {
            final element = find.byType(WidgetsApp).evaluate().single;
            await tester.runAsync(() async {
              final image = await captureImage(element);
              final png = await image.toByteData(format: ui.ImageByteFormat.png);
              image.dispose();
              File('build/invite_people/$shot.png')
                ..parent.createSync(recursive: true)
                ..writeAsBytesSync(png!.buffer.asUint8List());
            });
          }
        }
      }
    }
    tester.view.reset();
  });
}
