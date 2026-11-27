import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/sms.dart' show Person;
import 'package:ghost_messaging/souls/souls_send.dart';
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/souls_send.dart';
import 'package:ghost_messaging/ui/thread.dart';

import 'support/list_harness.dart';
import 'support/space_call_harness.dart';

/// Souls sent to a friend from a chat (GMFB-39, "Payments between friends"; Matt, 2026-11-23: "Tip souls in a chat"):
/// the card as words an older build can read, the sending against a stand-in relay (it goes, there aren't enough, the
/// relay is one from before this), and when a card may say souls were sent.
///
/// The relay's own rules are tested in relay/test/souls_send_test.dart; this stand-in keeps counts and receipts the
/// same way, and answers as it does.
class _Relay {
  _Relay(this.souls);

  /// Souls by Uplink id, and the receipts by their names.
  final Map<String, int> souls;
  final Map<String, Map<String, Object?>> receipts = {};

  /// A relay from before the routes: every address it doesn't know is 200 and a line of text.
  bool old = false;

  /// How many of the next requests are taken and never answered (the answer lost on the way).
  int lose = 0;
  final asked = <String>[];

  Future<({int status, Map<String, String> headers, Uint8List body})> call(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) async {
    asked.add(url.path);
    ({int status, Map<String, String> headers, Uint8List body}) say(int status, Object body) =>
        (status: status, headers: const <String, String>{}, body: Uint8List.fromList(utf8.encode(body is String ? body : jsonEncode(body))));
    if (old) return say(200, 'Ghost Messaging relay\n');
    final asker = NetCrypto.idOf(base64Decode(headers['x-ghost-key']!));
    final j = jsonDecode(utf8.decode(body)) as Map;
    final id = j['id'] as String;
    if (url.path.endsWith('/souls/receipt')) {
      final r = receipts[id];
      return say(200, {'ok': true, 'receipt': r != null && (r['from'] == asker || r['to'] == asker) ? r : null});
    }
    final to = j['to'] as String, n = j['souls'] as int;
    var again = false;
    if (receipts[id] != null) {
      again = true;
    } else {
      if ((souls[asker] ?? 0) < n) return say(409, {'ok': false, 'error': 'not_enough', 'message': 'You don\'t have that many souls.'});
      souls[asker] = souls[asker]! - n;
      souls[to] = (souls[to] ?? 0) + n;
      receipts[id] = {'id': id, 'at': 1764000000000, 'from': asker, 'to': to, 'souls': n};
    }
    if (lose > 0) {
      lose--;
      throw StateError('the answer never came');
    }
    return say(200, {'ok': true, 'receipt': receipts[id], 'n': souls[asker], if (again) 'again': true});
  }
}

/// A list of friends kept nowhere and reached by nothing: the test puts Maya in it.
class _NoBuddies implements BuddiesPort {
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: '');
  @override
  String? get username => 'me';
  @override
  String get displayName => 'Me';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => '[]';
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => false;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const hub = 'wss://relay.example/hub';
  final me = KeysSigner(NetKeys.generate()), maya = KeysSigner(NetKeys.generate()), other = KeysSigner(NetKeys.generate());
  const id = '0123456789abcdef0123456789abcdef';

  test('a card is carried as words an older build shows as a message, and read back whole', () {
    const card = SoulsCard(souls: 20, id: id, note: 'Thanks for the fix');
    expect(card.words, 'I sent you 20 souls.\nThanks for the fix\nSouls receipt: $id');
    final back = SoulsCard.of(card.words)!;
    expect((back.souls, back.note, back.id), (20, 'Thanks for the fix', id));
    expect(const SoulsCard(souls: 1, id: id).words, 'I sent you 1 soul.\nSouls receipt: $id');
    expect(SoulsCard.of('I sent you 1 soul.\nSouls receipt: $id')!.souls, 1);
    // Never a word or a mark that says souls are anything but souls.
    for (final w in ['\$', '€', '£', 'pay', 'money', 'cash', 'coin', 'buy', 'worth', 'price', 'credit']) {
      expect(card.words.toLowerCase().contains(w), isFalse, reason: w);
    }
    // A note is one line, and short.
    expect(SoulsCard.tidyNote('  two\nlines  '), 'two lines');
    expect(SoulsCard.tidyNote('x' * 200).length, soulsNoteMost);
    expect(SoulsCard.of(SoulsCard(souls: 5, id: id, note: 'a\nSouls receipt: ${'f' * 32}').words)!.id, id, reason: 'a note can\'t carry a receipt of its own');
  });

  test('a list\'s preview of a card leaves its receipt line out, whole or cut short; other words are left alone', () {
    final words = SoulsCard(souls: 20, id: 'ab' * 16, note: 'thanks').words;
    expect(SoulsCard.preview(words), 'I sent you 20 souls.\nthanks');
    expect(SoulsCard.preview(words.substring(0, words.length - 20)), 'I sent you 20 souls.\nthanks');
    expect(SoulsCard.preview('Souls receipt: abc is what it said'), 'Souls receipt: abc is what it said');
    expect(SoulsCard.preview('I sent you the file'), 'I sent you the file');
  });

  test('other words are a message and no card', () {
    expect(SoulsCard.of('I sent you 20 souls.'), isNull, reason: 'no receipt');
    expect(SoulsCard.of('I sent you 20 souls.\nSouls receipt: abc'), isNull);
    expect(SoulsCard.of('I sent you 0 souls.\nSouls receipt: $id'), isNull);
    expect(SoulsCard.of('I sent you 500 souls.\nSouls receipt: $id'), isNull, reason: 'more than a sending moves');
    expect(SoulsCard.of('Look: I sent you 20 souls.\nSouls receipt: $id'), isNull, reason: 'the whole message, or none of it');
    expect(SoulsCard.of('I sent you 20 souls.\nSouls receipt: $id\nand more'), isNull);
    expect(SoulsCard.of('I sent you 20 souls.\none\ntwo\nSouls receipt: $id'), isNull);
  });

  test('where the relay takes it', () {
    expect('${soulsUrlFor(hub, 'send')}', 'https://relay.example/souls/send');
    expect('${soulsUrlFor('ws://127.0.0.1:8787/hub', 'receipt')}', 'http://127.0.0.1:8787/souls/receipt');
  });

  group('sending', () {
    late _Relay relay;
    late SoulsApi api;
    late SoulsReceipts receipts;
    late List<String> written;

    setUp(() {
      relay = _Relay({me.id: 100});
      api = SoulsApi(hubUrl: hub, signer: me, transport: relay.call);
      receipts = SoulsReceipts(app: AppState());
      written = [];
    });

    Future<bool> write(String words) async {
      written.add(words);
      return true;
    }

    test('the souls go, then the card is written, and the sender\'s card is true at once', () async {
      final done = await sendSoulsCard(api: api, to: maya.id, souls: 20, id: id, note: ' Thanks ', write: write, receipts: receipts);
      expect(done.n, 80);
      expect(done.written, isTrue);
      expect(relay.souls, {me.id: 80, maya.id: 20});
      expect(written.single, 'I sent you 20 souls.\nThanks\nSouls receipt: $id');
      expect(receipts.stateOf(done.card, from: me.id, to: maya.id), SoulsCardState.confirmed);
      expect(relay.asked, ['/souls/send'], reason: 'no asking about a receipt this device was given');
    });

    test('not enough souls: said, nothing sent, no card', () async {
      await expectLater(
        sendSoulsCard(api: api, to: maya.id, souls: 100 + 1, id: id, write: write, receipts: receipts),
        throwsA(isA<SoulsSendError>().having((e) => e.code, 'code', 'not_enough').having((e) => e.message, 'message', 'You don\'t have that many souls.')),
      );
      expect(relay.souls, {me.id: 100});
      expect(written, isEmpty);
    });

    test('a relay from before this: "not available yet", nothing sent, no card', () async {
      relay.old = true;
      await expectLater(
        sendSoulsCard(api: api, to: maya.id, souls: 20, id: id, write: write, receipts: receipts),
        throwsA(isA<SoulsSendError>().having((e) => e.code, 'code', 'not_here').having((e) => e.message, 'message', contains('isn\'t available yet'))),
      );
      expect(relay.souls, {me.id: 100});
      expect(written, isEmpty);
      expect(receipts.stateOf(const SoulsCard(souls: 20, id: id), from: me.id, to: maya.id), SoulsCardState.unknown);
    });

    test('an answer lost on the way: asked again under the same name, and sent once', () async {
      relay.lose = 1;
      final done = await sendSoulsCard(api: api, to: maya.id, souls: 20, id: id, write: write, receipts: receipts);
      expect(relay.asked, ['/souls/send', '/souls/send']);
      expect(relay.souls, {me.id: 80, maya.id: 20}, reason: 'once');
      expect(done.n, 80);
      expect(written, hasLength(1));
    });

    test('the relay never reached: nothing known to be sent, and no card', () async {
      relay.lose = 2;
      await expectLater(sendSoulsCard(api: api, to: maya.id, souls: 20, id: id, write: write, receipts: receipts), throwsA(isA<SoulsSendError>().having((e) => e.code, 'code', 'unreachable')));
      expect(written, isEmpty);
      // Send pressed again asks for the same sending: still once.
      await sendSoulsCard(api: api, to: maya.id, souls: 20, id: id, write: write, receipts: receipts);
      expect(relay.souls, {me.id: 80, maya.id: 20});
    });

    test('the souls went and the message didn\'t: said so, not sent again', () async {
      final done = await sendSoulsCard(api: api, to: maya.id, souls: 20, id: id, write: (_) async => false, receipts: receipts);
      expect(done.written, isFalse);
      expect(relay.souls[maya.id], 20);
    });

    test('an answer that says ok and is no receipt for what was asked is not taken', () async {
      final lying = SoulsApi(
        hubUrl: hub,
        signer: me,
        transport: (m, u, h, b, {required most}) async =>
            (status: 200, headers: const <String, String>{}, body: Uint8List.fromList(utf8.encode(jsonEncode({'ok': true, 'n': 80, 'receipt': {'id': id, 'at': 1, 'from': me.id, 'to': other.id, 'souls': 20}})))),
      );
      await expectLater(sendSoulsCard(api: lying, to: maya.id, souls: 20, id: id, write: write, receipts: receipts), throwsA(isA<SoulsSendError>()));
      expect(written, isEmpty);
    });
  });

  group('a card is true only where the relay\'s receipt agrees', () {
    late _Relay relay;
    late AppState app;
    late SoulsReceipts receipts;
    // This device is Maya's friend, who is sent souls: it asks the relay as itself.
    late SoulsApi mine;

    setUp(() async {
      relay = _Relay({maya.id: 100, other.id: 100});
      app = AppState();
      receipts = SoulsReceipts(app: app);
      mine = SoulsApi(hubUrl: hub, signer: me, transport: relay.call);
      // Maya really sent 20.
      await SoulsApi(hubUrl: hub, signer: maya, transport: relay.call).send(to: me.id, souls: 20, id: id);
    });

    test('what she sent: unknown until asked, then true, and kept', () async {
      const card = SoulsCard(souls: 20, id: id);
      expect(receipts.stateOf(card, from: maya.id, to: me.id), SoulsCardState.unknown);
      expect(await receipts.check(card, from: maya.id, to: me.id, api: mine), isTrue);
      expect(receipts.stateOf(card, from: maya.id, to: me.id), SoulsCardState.confirmed);
      // Kept with the app's choices: not asked again, on this run or the next.
      final asked = relay.asked.length;
      final next = SoulsReceipts(app: app);
      expect(await next.check(card, from: maya.id, to: me.id, api: mine), isTrue);
      expect(relay.asked.length, asked);
    });

    test('words anyone could write are not souls: a made-up receipt, a bigger number, someone else\'s sending', () async {
      // A receipt the relay never gave.
      final made = SoulsCard(souls: 20, id: 'f' * 32);
      expect(await receipts.check(made, from: maya.id, to: me.id, api: mine), isFalse);
      expect(receipts.stateOf(made, from: maya.id, to: me.id), SoulsCardState.refused);
      // A real receipt with a bigger number written over it.
      const more = SoulsCard(souls: 90, id: id);
      expect(await receipts.check(more, from: maya.id, to: me.id, api: mine), isFalse);
      expect(receipts.stateOf(more, from: maya.id, to: me.id), SoulsCardState.refused);
      // Maya's real card, pasted into a chat by someone else: it is from whoever wrote the message.
      const hers = SoulsCard(souls: 20, id: id);
      expect(await SoulsReceipts(app: AppState()).check(hers, from: other.id, to: me.id, api: mine), isFalse);
      // A sending between two other people: the relay gives this account no receipt of it.
      await SoulsApi(hubUrl: hub, signer: other, transport: relay.call).send(to: maya.id, souls: 30, id: 'a' * 32);
      final theirs = SoulsCard(souls: 30, id: 'a' * 32);
      expect(await receipts.check(theirs, from: other.id, to: me.id, api: mine), isFalse);
      // And the true one, once confirmed, is not true of anyone else, or of another number.
      expect(await receipts.check(hers, from: maya.id, to: me.id, api: mine), isTrue);
      expect(receipts.stateOf(hers, from: other.id, to: me.id), SoulsCardState.refused);
      expect(receipts.stateOf(more, from: maya.id, to: me.id), SoulsCardState.refused);
    });

    test('a relay that can\'t be asked, or is from before this: not confirmed, and asked again later', () async {
      var now = DateTime(2026, 11, 23, 12);
      final r = SoulsReceipts(app: app, now: () => now);
      const card = SoulsCard(souls: 20, id: id);
      relay.old = true;
      expect(await r.check(card, from: maya.id, to: me.id, api: mine), isFalse);
      expect(r.stateOf(card, from: maya.id, to: me.id), SoulsCardState.unknown, reason: 'not refused: nobody answered');
      relay.old = false;
      final asked = relay.asked.length;
      expect(await r.check(card, from: maya.id, to: me.id, api: mine), isFalse);
      expect(relay.asked.length, asked, reason: 'not again within a minute');
      now = now.add(const Duration(minutes: 2));
      expect(await r.check(card, from: maya.id, to: me.id, api: mine), isTrue);
    });
  });

  test('what a card says, by where it stands', () {
    const card = SoulsCard(souls: 20, id: id, note: 'Thanks');
    expect(soulsCardWords(card, SoulsCardState.confirmed, mine: false, name: 'Maya'), (title: 'Maya sent you 20 souls', line: 'Thanks'));
    expect(soulsCardWords(card, SoulsCardState.confirmed, mine: true, name: 'Maya').title, 'You sent Maya 20 souls');
    expect(soulsCardWords(const SoulsCard(souls: 1, id: id), SoulsCardState.confirmed, mine: false, name: 'Maya'), (title: 'Maya sent you 1 soul', line: null));
    expect(soulsCardWords(card, SoulsCardState.unknown, mine: false, name: 'Maya').line, contains('Not confirmed yet'));
    expect(soulsCardWords(card, SoulsCardState.refused, mine: false, name: 'Maya').title, 'Not confirmed');
    expect(soulsCardWords(card, SoulsCardState.confirmed, mine: false, name: 'Maya', repeat: true).line, contains('Nothing more was sent'));
  });

  testWidgets('the card in a chat: not confirmed until the relay agrees, then who sent how many, with the note', (tester) async {
    final h = await SpaceHarness.load(tester);
    final relay = _Relay({maya.id: 100});
    final receipts = SoulsReceipts(app: AppState());
    final mine = SoulsApi(hubUrl: hub, signer: me, transport: relay.call);
    await SoulsApi(hubUrl: hub, signer: maya, transport: relay.call).send(to: me.id, souls: 20, id: id);
    await h.shoot(
      tester,
      Column(children: [
        SoulsSentCard(card: const SoulsCard(souls: 20, id: id, note: 'Thanks for the fix'), mine: false, name: 'Maya', from: maya.id, to: me.id, api: mine, receipts: receipts),
        // The same words again further down, and a card nobody's relay knows of.
        SoulsSentCard(card: const SoulsCard(souls: 20, id: id), mine: false, name: 'Maya', from: maya.id, to: me.id, repeat: true, api: mine, receipts: receipts),
        SoulsSentCard(card: SoulsCard(souls: 90, id: 'e' * 32), mine: false, name: 'Maya', from: maya.id, to: me.id, api: mine, receipts: receipts),
      ]),
      'souls-cards',
    );
    expect(find.text('Maya sent you 20 souls'), findsOneWidget);
    expect(find.text('Thanks for the fix'), findsOneWidget);
    expect(find.text('Souls card, repeated'), findsOneWidget);
    expect(find.text('Not confirmed'), findsOneWidget);
    expect(find.textContaining('90 souls, but the relay has no record of it'), findsOneWidget);
    expect(find.textContaining('sent you 90'), findsOneWidget, reason: 'only inside "This says ..."');
  });

  testWidgets('the page: a number within what you have, asked once more, sent, and your souls updated', (tester) async {
    final h = await SpaceHarness.load(tester);
    Me.instance.seedSouls(50);
    final relay = _Relay({me.id: 50});
    final written = <String>[];
    final receipts = SoulsReceipts(app: AppState());
    await h.shoot(
      tester,
      SendSoulsScreen(
        to: maya.id,
        name: 'Maya',
        api: SoulsApi(hubUrl: hub, signer: me, transport: relay.call),
        receipts: receipts,
        write: (words) async {
          written.add(words);
          return true;
        },
      ),
      'souls-send',
    );
    SettingRow send() => tester.widget<SettingRow>(find.byKey(const ValueKey('send-souls-send')));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    expect(find.textContaining('You have 50 souls'), findsOneWidget);
    expect(send().onPress, isNull, reason: 'no number yet');
    await tester.enterText(find.byKey(const ValueKey('send-souls-amount')), '80');
    await settle();
    expect(send().onPress, isNull);
    expect(find.text('You have 50 souls.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('send-souls-amount')), '20');
    await tester.enterText(find.byKey(const ValueKey('send-souls-note')), 'Thanks');
    await settle();
    expect(send().label, 'Send 20 souls to Maya');
    send().onPress!();
    await settle();
    expect(find.textContaining('Send 20 souls to Maya? They can\'t be taken back.'), findsOneWidget);
    expect(relay.asked, isEmpty, reason: 'nothing goes before the second yes');
    await tester.tap(find.text('Send 20 souls'));
    await settle();
    expect(relay.souls, {me.id: 30, maya.id: 20});
    expect(written.single, startsWith('I sent you 20 souls.\nThanks\n'));
    expect(Me.instance.souls, 30);
    expect(find.byType(SendSoulsScreen), findsNothing, reason: 'back in the chat');
    await tester.pump(const Duration(seconds: 5));
    Me.instance.seedSouls(0);
  });

  testWidgets('the page against a relay from before this: says it isn\'t available yet, and nothing is sent', (tester) async {
    final h = await SpaceHarness.load(tester);
    Me.instance.seedSouls(50);
    final relay = _Relay({me.id: 50})..old = true;
    final written = <String>[];
    await h.shoot(
      tester,
      SendSoulsScreen(
        to: maya.id,
        name: 'Maya',
        api: SoulsApi(hubUrl: hub, signer: me, transport: relay.call),
        receipts: SoulsReceipts(app: AppState()),
        write: (words) async {
          written.add(words);
          return true;
        },
      ),
      'souls-send-old',
    );
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.enterText(find.byKey(const ValueKey('send-souls-amount')), '20');
    await settle();
    tester.widget<SettingRow>(find.byKey(const ValueKey('send-souls-send'))).onPress!();
    await settle();
    await tester.tap(find.text('Send 20 souls'));
    await settle();
    expect(find.text('Sending souls isn\'t available yet. Try again later.'), findsOneWidget);
    expect(find.byType(SendSoulsScreen), findsOneWidget);
    expect(written, isEmpty);
    expect(relay.souls, {me.id: 50});
    expect(Me.instance.souls, 50);
    Me.instance.seedSouls(0);
  });

  group('in a conversation', () {
    const receipt = '0123456789abcdef0123456789abcdef';
    late List<Map<String, Object?>> messages;

    setUp(() {
      messages = [];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
        switch (call.method) {
          case 'status':
            return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
          case 'messages':
            return messages;
          case 'e2e':
            return {'address': (call.arguments as Map)['address'], 'state': 'none', 'verified': false, 'changed': false};
          case 'prefs':
            return <String, String>{};
          case 'ghostPeers' || 'netSmsAvailable':
            return false;
          default:
            return null;
        }
      });
      Buddies.instance = Buddies(_NoBuddies())..all = [Buddy(username: 'maya', id: maya.id, key: base64Encode(maya.publicKey), name: 'Maya')];
    });
    tearDown(() => Buddies.instance = null);

    Map<String, Object?> message(int id, String body, {bool outgoing = false}) =>
        {'id': id, 'kind': 'sms', 'address': '@maya', 'body': body, 'date': DateTime(2026, 11, 23, 12, id).millisecondsSinceEpoch, 'outgoing': outgoing, 'state': outgoing ? 'sent' : 'received', 'read': true};

    testWidgets('with a friend by username the + offers Send souls, and a souls message is a card that isn\'t taken on its word', (tester) async {
      final sheet = await loadSheet(tester);
      messages = [message(2, 'I sent you 20 souls.\nSouls receipt: $receipt'), message(1, 'Hello')];
      await pumpScreen(tester, sheet, const ThreadScreen(thread: 51, people: [Person(address: '@maya', name: 'Maya')]), AppState());
      await settle(tester);
      // No relay in a test answers: the card stands as not confirmed, and never says souls were sent.
      expect(find.byKey(const ValueKey('souls-card-$receipt')), findsOneWidget);
      expect(find.text('20 souls from Maya'), findsOneWidget);
      expect(find.textContaining('Not confirmed yet'), findsOneWidget);
      expect(find.text('Maya sent you 20 souls'), findsNothing);
      expect(find.textContaining('Souls receipt'), findsNothing, reason: 'the card, not its words');
      final plus = tester.widget<IconTap>(find.byKey(const ValueKey('composer-plus')));
      expect(plus.onPressed, isNotNull);
      plus.onPressed!();
      await settle(tester);
      expect(find.text('Send souls'), findsOneWidget);
      await tester.tap(find.text('Send souls'));
      await settle(tester);
      expect(find.byType(SendSoulsScreen), findsOneWidget);
    });

    testWidgets('someone who is no friend by username: the same words are a message, and there is nothing to send souls from', (tester) async {
      final sheet = await loadSheet(tester);
      messages = [
        {...message(1, 'I sent you 20 souls.\nSouls receipt: $receipt'), 'address': '+15551230042'},
      ];
      await pumpScreen(tester, sheet, const ThreadScreen(thread: 52, people: [Person(address: '+15551230042', name: 'Dad')]), AppState());
      await settle(tester);
      expect(find.byKey(const ValueKey('souls-card-$receipt')), findsNothing);
      expect(find.textContaining('Souls receipt', findRichText: true), findsOneWidget);
    });
  });
}
