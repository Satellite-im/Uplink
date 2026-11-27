import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/ledger.dart';
import 'package:ghost_messaging/net/name_watch.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/ui/name_watch_words.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsModel;
import 'package:glacier/glacier.dart';

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';

/// Settings › Routes › Checking the relay (lib/ui/network.dart; docs/OPEN_NETWORK.md, section 3): in a build with no
/// direct route, the name watch alone, saying so, and nothing to dial; with one, when the relay was last checked and
/// with how many devices, what matched and was made up for, each thing it got wrong with its day, and "Check now" once a
/// minute.

/// Every piece of text drawn in the row keyed [key].
List<String> _words(WidgetTester tester, String key) => [for (final t in tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))) ?t.data];

Future<void> _pump(WidgetTester tester, AppState state, Listenable listenable, List<Widget> Function(BuildContext) rows) async {
  tester.view.physicalSize = const Size(412, 3600) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
  installSettingsStyles(sheet);
  await tester.pumpWidget(AppScope(
    state: state,
    child: WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
      home: ListenableBuilder(listenable: listenable, builder: (context, _) => ListView(children: rows(context))),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

/// A name watch that has seen what a test gives it: a friend's username given to another key, its own, and a friend's
/// word about its own, as kept.
NameWatch _watch({required String me, required List<WatchedName> friends, Map<String, String>? kept}) {
  final store = kept ?? <String, String>{};
  final clock = FakeClock();
  return NameWatch(me: () => me, username: () => 'matt', friends: () => friends, whois: (_) async => null, tell: (_, _) async {}, read: (n) => store[n] ?? '', write: (n, v) => store[n] = v, now: clock.now, timer: clock.timer)..start();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('what the rows say', () {
    final now = DateTime(2026, 11, 23, 12).millisecondsSinceEpoch;
    expect(relayCheckedWords(0, 0, now: now), 'Not checked yet');
    expect(relayCheckedWords(now - 5 * 60000, 1, now: now), 'Last checked 5 min ago, with 1 device');
    expect(relayCheckedWords(now - 3 * 3600000, 3, now: now), 'Last checked 3 h ago, with 3 devices');
    expect([relayMatchedWords(1), relayMatchedWords(212)], ['1 message matched this week', '212 messages matched this week']);
    // Only what came straight is said to have (the review, D7), and what was lost to a restart is said as that.
    expect(relayMadeUpWords(0), 'None had to come straight.');
    expect([relayMadeUpWords(1), relayMadeUpWords(2, restarts: 2), relayMadeUpWords(3, restarts: 1)], [
      '1 came straight after the relay didn\'t bring it.',
      '2 came straight after the relay didn\'t bring them, lost when it started again.',
      '3 came straight after the relay didn\'t bring them (1 lost when it started again).',
    ]);
    // Whose word each is (D5).
    expect([for (final k in LedgerWrongKind.values) relayWrongWords(LedgerWrong(k, now, 'x'), 'Maya')], [
      'Maya\'s device says the relay passed on a message to you, and it never came by the relay',
      'Maya\'s device says the relay kept a message for you, and it never handed it over',
      'Maya\'s device says the relay told it you were away while you were connected',
      'The relay said Maya was gone while their device said it was connected',
    ]);
    expect(dayWords(DateTime(2026, 11, 21, 9).millisecondsSinceEpoch), '21 Nov');
    expect([nameWatchWords(0), nameWatchWords(1), nameWatchWords(4)], ['No friends added by username yet', 'Asks the relay about 1 friend\'s username each day', 'Asks the relay about 4 friends\' usernames each day']);
    // Calm, and the usual reason named (the review, M1 and M2).
    expect(friendNameChangedWords('maya', 'Maya Chen'), '@maya now belongs to another account on the relay. If Maya changed or gave up their username, that\'s why. You\'re still talking to the Maya Chen you added.');
    NameChange own(NameKind k) => NameChange(username: 'matt', other: 'c' * 32, at: now, kind: k);
    expect([for (final k in [NameKind.none, NameKind.changed, NameKind.old, NameKind.contradicts]) ownNameWords(own(k))], [
      '@matt now belongs to another account on this relay',
      '@matt now belongs to another account on this relay',
      '@matt is still held by this device\'s old key',
      'The relay says @matt is yours, yet gives it to another account when others ask',
    ]);
    expect(ownNameHint(own(NameKind.none)), 'That happens when you gave it up or changed it on another of your devices, made a new key, or use another relay.');
    for (final k in NameKind.values) {
      expect('${ownNameWords(own(k))} ${ownNameHint(own(k))}', isNot(contains('still reach you')), reason: 'not said: after a new key it is not so');
    }
  });

  group('as the app holds the routes', () {
    final me = NetKeys.generate(), sam = NetKeys.generate();
    late Map<String, String> secrets;

    setUp(() {
      secrets = {};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
        final a = call.arguments is Map ? call.arguments as Map : const {};
        switch (call.method) {
          case 'netIdentity':
            return {'id': me.id, 'key': base64Encode(me.public)};
          case 'netSign':
            return NetCrypto.sign(me, (a['message'] as List).cast<int>());
          case 'netPeers':
            return [
              {'id': sam.id, 'address': '@sam', 'key': NetCrypto.netKey(NetCrypto.conversationKey(me, sam.public)!)},
            ];
          case 'netSmsDrain':
            return const <Object>[];
          case 'secretKeep':
            final value = '${a['value'] ?? ''}';
            value.isEmpty ? secrets.remove('${a['name']}') : secrets['${a['name']}'] = value;
            return null;
          case 'secretRead':
            return secrets['${a['name']}'];
        }
        return null;
      });
    });
    tearDown(() async {
      await Net.instance.shutdown();
      Net.p2pNode = null;
      NameWatch.instance = null;
    });

    Future<void> open(WidgetTester tester, AppState state) async {
      await tester.runAsync(() async {
        await Net.instance.start(state, carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
        final p2p = Net.instance.p2p;
        for (var i = 0; i < 400 && p2p != null && !(p2p.loaded && p2p.card != null); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final model = SettingsModel(state);
      addTearDown(model.dispose);
      await _pump(tester, state, Listenable.merge([Net.instance, Net.instance.direct]), (context) => networkPane(context, model));
    }

    testWidgets('no core: the relay is checked by the name watch alone, which says what it found; nothing to dial, no ledger kept', (tester) async {
      final mallory = NetKeys.generate();
      final kept = {
        NameWatch.keptName: jsonEncode({
          'me': me.id,
          'r': {
            '': {
              'c': {sam.id: DateTime.now().millisecondsSinceEpoch - 2 * 3600000},
              'b': {sam.id: DateTime.now().millisecondsSinceEpoch - 3 * 86400000},
              'x': {sam.id: ['sam', mallory.id, DateTime(2026, 11, 22).millisecondsSinceEpoch, 'friend']},
              'o': ['matt', mallory.id, DateTime(2026, 11, 21).millisecondsSinceEpoch, 'none'],
            },
          },
          'm': [['matt', mallory.id, DateTime.now().millisecondsSinceEpoch, 'told', sam.id]],
        }),
      };
      NameWatch.instance = _watch(me: me.id, friends: [WatchedName('sam', sam.id, base64Encode(sam.public))], kept: kept);
      await open(tester, AppState());
      expect([Net.instance.p2p, Net.instance.ledger, Net.instance.check, Net.instance.board?.log], [null, null, null, null], reason: 'nothing could compare it: nothing is listed');
      expect(find.text('CHECKING THE RELAY'), findsOneWidget);
      expect(find.textContaining('This device has no direct route, so the relay is checked only by the name watch'), findsOneWidget);
      for (final key in ['relay-checked', 'relay-matched', 'relay-check-now']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(_words(tester, 'names-watched'), ['Asks the relay about 1 friend\'s username each day', startsWith('Last asked 2 h ago.')]);
      expect(_words(tester, 'names-own'), ['@matt now belongs to another account on this relay', '21 Nov. That happens when you gave it up or changed it on another of your devices, made a new key, or use another relay.']);
      expect(_words(tester, 'names-told-0'), ['@sam\'s app saw the relay give your username @matt to another account', '${dayWords(DateTime.now().millisecondsSinceEpoch)}. If you changed or gave it up, or made a new key, that\'s why.']);
      expect(_words(tester, 'names-changed-0'), ['@sam now belongs to another account on the relay', '22 Nov. If @sam changed or gave up their username, that\'s why. You\'re still talking to the @sam you added.']);
      // With Direct off nothing goes over a direct link, and the footer says how a friend is told (the review, S8).
      expect(find.textContaining('over a direct link'), findsNothing);
      expect(find.text('Only the relay you use is asked. A friend whose username it now gives to another account is told, sealed, through the relay.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    // Direct starts off (Matt's brief, 2026-11-23): with a core and Direct not switched on, nothing could compare the
    // ledger either, so none is kept, and the section says why and how to compare too.
    testWidgets('with a core and Direct off: the relay is checked by the name watch alone, and the section says Direct is off; no ledger kept', (tester) async {
      Net.p2pNode = FakeP2pMesh().node;
      NameWatch.instance = _watch(me: me.id, friends: const []);
      await open(tester, AppState());
      expect([Net.instance.p2p, Net.instance.ledger, Net.instance.check, Net.instance.board?.log], [null, null, null, null]);
      expect(find.text('Direct is off, so the relay is checked only by the name watch: friends\' usernames are asked of it again each day, and your own each time you connect. Switch Direct on above to compare what went between your devices and your friends\' over direct links too.'), findsOneWidget);
      expect(find.textContaining('This device has no direct route'), findsNothing);
      for (final key in ['relay-checked', 'relay-matched', 'relay-check-now']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(_words(tester, 'names-watched').first, 'No friends added by username yet');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with a core: the ledger is kept and compared, the section says it has not checked yet, and Check now is there', (tester) async {
      Net.p2pNode = FakeP2pMesh().node;
      NameWatch.instance = _watch(me: me.id, friends: const []);
      await open(tester, AppState()..set(Net.directName, 'on'));
      expect(Net.instance.ledger, isNotNull);
      expect(Net.instance.board!.log, same(Net.instance.ledger));
      expect(find.textContaining('compare what went between them, over direct links'), findsOneWidget);
      expect(_words(tester, 'relay-checked'), ['Not checked yet', 'Of Uplink\'s relay (gogho.st), over direct links with your friends\' devices.']);
      expect(find.byKey(const ValueKey('relay-matched')), findsNothing);
      expect(_words(tester, 'relay-check-now'), ['Check now', 'Dials the friends the relay says are here, and compares.']);
      expect(_words(tester, 'names-watched').first, 'No friends added by username yet');
      await tester.runAsync(() => Net.instance.shutdown());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('over devices that compare', () {
    testWidgets('with links: when it was checked and with how many devices, what matched, nothing wrong; Check now dials, then waits a minute', (tester) async {
      final w = World(ledgers: true);
      late Install a, b;
      await tester.runAsync(() async {
        a = w.install(w.account('maya'), computer: true);
        b = w.install(w.account('sam'), computer: true);
        w.friends(a, b);
        await a.start();
        await b.start();
        await a.text(b.account, 'hello');
        await w.clock.pass(const Duration(minutes: 3));
        await a.text(b.account, 'straight', only: {'p2p'});
        await w.until(() => (a.ledger!.relays[w.memory.url]?.checks.length ?? 0) > 0, 'compared');
      });
      addTearDown(() => tester.runAsync(w.stop));
      await _pump(tester, AppState(), Listenable.merge([a.ledger!, a.check!]), (context) => [relayCheckSection(context, ledger: a.ledger, check: a.check, watch: null, relay: w.memory.url, nameOf: (id) => id == b.account.id ? 'Sam' : '', now: w.clock.ms)]);
      expect(_words(tester, 'relay-checked').first, 'Last checked just now, with 1 device');
      expect(_words(tester, 'relay-matched'), ['1 message matched this week', 'None had to come straight.']);
      expect(_words(tester, 'relay-wrong-none'), ['It got nothing wrong']);
      expect(_words(tester, 'relay-check-now'), ['Check now', 'Dials the friends the relay says are here, and compares.']);
      await tester.tap(find.byKey(const ValueKey('relay-check-now')));
      await tester.runAsync(w.settle);
      await tester.pump(const Duration(milliseconds: 50));
      expect(a.check!.checkedNow, w.clock.ms);
      expect(_words(tester, 'relay-check-now'), ['Check now', 'Checked a moment ago. Again in a minute.']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('results: each thing the relay got wrong, with its day, and what was made up for', (tester) async {
      final w = World(ledgers: true);
      late Install a, b;
      await tester.runAsync(() async {
        a = w.install(w.account('maya'), computer: true);
        b = w.install(w.account('sam'), computer: true);
        w.friends(a, b);
        await a.start();
        await b.start();
        await a.text(b.account, 'hello');
        await w.clock.pass(const Duration(seconds: 20));
        // The relay drops one it says it passed on to Sam's computer.
        var dropped = false;
        b.pair!.dropToApp = (said) {
          if (dropped || said is! List<int> || said.isEmpty || said[0] != 1) return false;
          return dropped = true;
        };
        final lost = a.text(b.account, 'lost');
        await w.clock.pass(const Duration(seconds: 5));
        await lost;
        await w.clock.pass(const Duration(seconds: 15));
        await a.text(b.account, 'after');
        await w.clock.pass(const Duration(minutes: 3));
        await a.text(b.account, 'straight', only: {'p2p'});
        await w.until(() => b.texts.contains('lost'), 'came straight');
      });
      addTearDown(() => tester.runAsync(w.stop));
      await _pump(tester, AppState(), b.ledger!, (context) => [relayCheckSection(context, ledger: b.ledger, check: b.check, watch: null, relay: w.memory.url, nameOf: (id) => id == a.account.id ? 'Maya' : '', now: w.clock.ms)]);
      expect(_words(tester, 'relay-matched'), ['2 messages matched this week', '1 came straight after the relay didn\'t bring it.']);
      expect(_words(tester, 'relay-wrong-0'), ['Maya\'s device says the relay passed on a message to you, and it never came by the relay', dayWords(w.clock.ms)]);
      expect(find.byKey(const ValueKey('relay-wrong-none')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
