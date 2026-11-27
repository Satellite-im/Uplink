import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/groups.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show MemoryFsStore;
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/routes_kept.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:glacier/glacier.dart';

import 'support/direct_world.dart' show PlainCarrier;

/// Which route each conversation is on, kept from one run to the next and listed by conversation (GMFB-24: "Settings ›
/// Network shows which route each conversation is using"; checked against the code on 2026-11-25: "per person, not per
/// conversation, and forgets on close"). What is kept and for how long (lib/net/routes_kept.dart), how the switchboard
/// takes it back, the app keeping it across a start and deleting it at sign-out, and Settings › Routes' list with a
/// group in it.

/// Every piece of text drawn in the row keyed [key].
List<String> _words(WidgetTester tester, String key) => [for (final t in tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))) ?t.data];

class _Book implements PeerBook {
  _Book(this.peers);
  final Map<String, Peer> peers;
  @override
  Peer? byId(String id) => peers[id];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = NetKeys.generate(), sam = NetKeys.generate(), nell = NetKeys.generate(), zed = NetKeys.generate();
  final now = DateTime.utc(2026, 11, 26, 12);
  DateTime ago(Duration d) => now.subtract(d);

  group('what is kept', () {
    test('each person\'s routes and times, read back the longest quiet first; written a moment after a change, once', () async {
      final store = MemoryFsStore();
      final kept = RoutesKept(store: store, me: me.id, now: () => now, after: const Duration(milliseconds: 20));
      var used = {
        sam.id: RouteUse(sentBy: 'hub', sentAt: ago(const Duration(minutes: 5)), cameBy: 'lan', cameAt: ago(const Duration(minutes: 2))),
        nell.id: RouteUse(cameBy: 'sms', cameAt: ago(const Duration(hours: 30))),
      };
      kept.changed(() => used);
      kept.changed(() => used);
      expect(store.writes, 0, reason: 'not at once');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await kept.flush();
      expect(store.writes, 1, reason: 'many changes, one write; and nothing more to write');
      final text = store.kept[RoutesKept.name]!;
      expect(text, isNot(anyOf(contains('text'), contains('@'))), reason: 'names of installs, names of routes and times: nothing else');
      final back = await RoutesKept(store: store, me: me.id, now: () => now).read();
      expect(back.keys, [nell.id, sam.id], reason: 'the longest quiet first, as the switchboard keeps them');
      expect([back[sam.id]!.sentBy, back[sam.id]!.cameBy, back[sam.id]!.sentAt, back[sam.id]!.cameAt], ['hub', 'lan', ago(const Duration(minutes: 5)).toLocal(), ago(const Duration(minutes: 2)).toLocal()]);
      expect([back[nell.id]!.sentBy, back[nell.id]!.cameBy], [null, 'sms']);
      // Put away at once: written without waiting.
      used = {...used, zed.id: RouteUse(sentBy: 'p2p', sentAt: now)};
      kept.changed(() => used);
      await kept.flush();
      expect(store.writes, 2);
      expect((await RoutesKept(store: store, me: me.id, now: () => now).read()).keys, [nell.id, sam.id, zed.id]);
    });

    test('another account\'s is not read; someone not sent to or heard from in a week is left out; what is no such file is nothing', () async {
      final store = MemoryFsStore();
      final kept = RoutesKept(store: store, me: me.id, now: () => now);
      kept.changed(() => {
            sam.id: RouteUse(sentBy: 'hub', sentAt: ago(const Duration(days: 6))),
            nell.id: RouteUse(sentBy: 'hub', sentAt: ago(const Duration(days: 8))),
          });
      await kept.flush();
      expect((await RoutesKept(store: store, me: me.id, now: () => now).read()).keys, [sam.id]);
      expect(jsonDecode(store.kept[RoutesKept.name]!)['u'], hasLength(1), reason: 'and is not written again either');
      // Read a day later, Sam's is a week old too.
      expect(await RoutesKept(store: store, me: me.id, now: () => now.add(const Duration(days: 2))).read(), isEmpty);
      // Signed in as someone else on this device: nothing of the account before.
      expect(await RoutesKept(store: store, me: sam.id, now: () => now).read(), isEmpty);
      for (final junk in ['', 'not json', '[]', '{"v":2}', jsonEncode({'v': 1, 'me': me.id, 'u': 'x'})]) {
        store.kept[RoutesKept.name] = junk;
        expect(await RoutesKept(store: store, me: me.id, now: () => now).read(), isEmpty, reason: junk);
      }
      // An entry that is not one is passed over, and the rest read: a name that is no install's, a route's name that is
      // no route's, a time from a clock two days ahead, a list of the wrong length.
      final at = now.millisecondsSinceEpoch;
      store.kept[RoutesKept.name] = jsonEncode({
        'v': 1,
        'me': me.id,
        'u': {
          'not-an-id': ['hub', at, null, null],
          sam.id: ['hub', at, null, null],
          nell.id: ['../../etc', at, null, null],
          zed.id: ['hub', at + 2 * 86400000, null, null],
          me.id: ['hub', at],
        },
      });
      expect((await RoutesKept(store: store, me: me.id, now: () => now).read()).keys, [sam.id]);
    });

    test('signing out deletes it, and nothing is written after', () async {
      final store = MemoryFsStore();
      final kept = RoutesKept(store: store, me: me.id, now: () => now, after: const Duration(milliseconds: 10));
      kept.changed(() => {sam.id: RouteUse(sentBy: 'hub', sentAt: now)});
      await kept.flush();
      expect(store.kept[RoutesKept.name], isNotEmpty);
      kept.changed(() => {sam.id: RouteUse(sentBy: 'lan', sentAt: now)});
      await kept.wipe();
      expect(store.kept[RoutesKept.name], '');
      kept.changed(() => {sam.id: RouteUse(sentBy: 'lan', sentAt: now)});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await kept.flush();
      expect(store.kept[RoutesKept.name], '');
    });
  });

  test('the switchboard takes what was kept behind what it has seen this run, and never in its place', () async {
    final key = NetCrypto.netKey(NetCrypto.conversationKey(me, sam.public)!);
    final hub = PlainCarrier('hub');
    final board = Switchboard(me: me.id, peers: _Book({sam.id: Peer(id: sam.id, key: key)}), carriers: [hub]);
    await board.start();
    await board.send(Peer(id: sam.id, key: key), Envelope(kind: 'text', ack: false));
    var changes = 0;
    board.usedChanged.addListener(() => changes++);
    board.seedUsed({
      nell.id: RouteUse(cameBy: 'sms', cameAt: ago(const Duration(hours: 3))),
      sam.id: RouteUse(sentBy: 'lan', sentAt: ago(const Duration(hours: 1)), cameBy: 'lan', cameAt: ago(const Duration(hours: 1))),
    });
    expect(changes, 1);
    expect(board.used.keys, [nell.id, sam.id], reason: 'the one from before is let go first');
    expect([board.used[sam.id]!.sentBy, board.used[sam.id]!.cameBy], ['hub', 'lan'], reason: 'what went this run by the relay; what last came is still what was kept');
    expect(board.used[sam.id]!.cameAt, ago(const Duration(hours: 1)));
    expect(board.used[nell.id]!.cameBy, 'sms');
    board.seedUsed(const {});
    expect(changes, 1);
    board.clearUsed();
    expect([board.used, changes], [isEmpty, 2]);
    await board.dispose();
  });

  group('as the app holds the routes', () {
    late MemoryFsStore store;

    setUp(() {
      HttpOverrides.global = null;
      store = MemoryFsStore();
      Net.routesStore = () => store;
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
        }
        return null;
      });
    });
    tearDown(() async {
      await Net.instance.shutdown();
      Net.routesStore = Net.defaultRoutesStore;
    });

    test('which route a person was on is there again after the app is closed and opened, and gone after signing out', () async {
      await Net.instance.start(AppState(), carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
      expect(Net.instance.board!.used, isEmpty);
      await Net.instance.send(Net.instance.byId(sam.id)!, Envelope(kind: 'text', ack: false), only: {'hub'});
      expect(Net.instance.board!.used[sam.id]!.sentBy, 'hub');
      // Put away: written at once, since the app may not come back.
      Net.instance.setAway(true);
      await pumpEventQueue(times: 20);
      expect(store.kept[RoutesKept.name], contains(sam.id));
      await Net.instance.shutdown();
      // Opened again: known before anything is sent.
      await Net.instance.start(AppState(), carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
      await pumpEventQueue(times: 20);
      expect(Net.instance.board!.used[sam.id]!.sentBy, 'hub');
      var drawn = 0;
      Net.instance.routesUsed.addListener(() => drawn++);
      // Signing out: nothing of it here or where it is kept.
      await Net.instance.forgetRoutesUsed();
      expect([Net.instance.board!.used, store.kept[RoutesKept.name], drawn], [isEmpty, '', 1]);
      await Net.instance.send(Net.instance.byId(sam.id)!, Envelope(kind: 'text', ack: false), only: {'hub'});
      Net.instance.setAway(true);
      await Net.instance.shutdown();
      expect(store.kept[RoutesKept.name], '', reason: 'and nothing is kept after, until the next account\'s routes are set up');
    });

    test('with nowhere to keep it (a browser), the routes work as before and keep nothing', () async {
      Net.routesStore = () => null;
      await Net.instance.start(AppState(), carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
      await Net.instance.send(Net.instance.byId(sam.id)!, Envelope(kind: 'text', ack: false), only: {'hub'});
      expect(Net.instance.board!.used[sam.id]!.sentBy, 'hub');
      Net.instance.setAway(true);
      await Net.instance.forgetRoutesUsed();
      expect(Net.instance.board!.used, isEmpty);
    });
  });

  group('Settings › Routes › Which route each conversation is on', () {
    test('what the lines say', () {
      final at = now.millisecondsSinceEpoch;
      expect(routeUseWords(RouteUse(sentBy: 'hub', sentAt: ago(const Duration(minutes: 3)), cameBy: 'lan', cameAt: ago(const Duration(days: 3))), now: at), 'Last sent by Relay server, 3 min ago; last came by Local network, 3 days ago.');
      expect(routeUseWords(RouteUse(cameBy: 'p2p', cameAt: now), now: at), 'Nothing sent lately; last came by Direct, just now.');
      expect(routeUseWords(RouteUse(sentBy: 'sms', sentAt: now), now: at), 'Last sent by SMS, just now; nothing has come lately.');
      expect(routeLastOf(RouteUse(sentBy: 'hub', sentAt: ago(const Duration(minutes: 3)), cameBy: 'lan', cameAt: ago(const Duration(minutes: 1)))), 'lan');
      expect(routeLastOf(RouteUse(sentBy: 'hub', sentAt: ago(const Duration(minutes: 1)), cameBy: 'lan', cameAt: ago(const Duration(minutes: 3)))), 'hub');
      final hub = RouteUse(sentBy: 'hub', sentAt: now), lan = RouteUse(cameBy: 'lan', cameAt: now);
      expect(groupRouteWords([('Maya', hub), ('Sam', lan)]), 'Maya by Relay server, Sam by Local network.');
      expect(groupRouteWords([('Maya', hub), ('Sam', null)]), 'Maya by Relay server; nothing lately to or from 1 other.');
      expect(groupRouteWords([('Maya', null), ('Sam', lan), ('Nell', null)]), 'Sam by Local network; nothing lately to or from 2 others.');
    });

    testWidgets('a person\'s conversation and a group\'s, the one used last first; a group nobody of which was reached is not listed, nor one this phone left', (tester) async {
      tester.view.physicalSize = const Size(412, 1600) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final state = AppState();
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      GroupMember member(NetKeys k, String name) => GroupMember(id: k.id, key: base64Encode(k.public), address: '@${name.toLowerCase()}', name: name);
      final mine = GroupMember(id: me.id, key: base64Encode(me.public), me: true);
      final groups = [
        Group(id: 'g1', name: 'Weekend', v: 1, thread: 1, members: [mine, member(sam, 'Sam'), member(nell, 'Nell'), member(zed, 'Zed')]),
        Group(id: 'g2', name: 'Nobody reached', v: 1, thread: 2, members: [mine, member(zed, 'Zed')]),
        Group(id: 'g3', name: 'Left', v: 1, thread: 3, members: [mine, member(sam, 'Sam')], gone: true),
      ];
      final used = {
        sam.id: RouteUse(sentBy: 'hub', sentAt: ago(const Duration(minutes: 30)), cameBy: 'hub', cameAt: ago(const Duration(minutes: 20))),
        nell.id: RouteUse(cameBy: 'lan', cameAt: ago(const Duration(minutes: 1))),
      };
      await tester.pumpWidget(AppScope(
        state: state,
        child: WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
          home: Builder(builder: (context) => ListView(children: [routesUsedSection(context, used, nameOf: (id) => id == sam.id ? 'Sam' : 'Nell', groups: groups, now: now.millisecondsSinceEpoch)])),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('WHICH ROUTE EACH CONVERSATION IS ON'), findsOneWidget);
      expect(_words(tester, 'used-${sam.id}'), ['Sam', 'Last sent by Relay server, 30 min ago; last came by Relay server, 20 min ago.']);
      expect(_words(tester, 'used-${nell.id}'), ['Nell', 'Nothing sent lately; last came by Local network, 1 min ago.']);
      expect(_words(tester, 'used-group-g1'), ['Weekend', 'Sam by Relay server, Nell by Local network; nothing lately to or from 1 other.']);
      expect(find.byKey(const ValueKey('used-group-g2')), findsNothing);
      expect(find.byKey(const ValueKey('used-group-g3')), findsNothing);
      // The newest first: Nell's and the group she is in (a minute ago), then Sam's.
      double y(String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;
      expect(y('used-${nell.id}'), lessThan(y('used-${sam.id}')));
      expect(y('used-group-g1'), lessThan(y('used-${sam.id}')));
      expect(find.textContaining('Circles and spaces always go by the relay server they were made on, and texts by the phone\'s carrier. Kept on this device only, out of any backup, for a week, and deleted when you sign out.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
