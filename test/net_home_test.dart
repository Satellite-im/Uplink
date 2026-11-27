import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/home_record.dart';
import 'package:ghost_messaging/net/homes.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/presence.dart';
import 'package:ghost_messaging/ui/add_friend_drawer.dart';
import 'package:ghost_messaging/ui/add_me.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:ghost_messaging/ui/profile_card.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsModel;
import 'package:ghost_messaging/voice/friend_calls.dart';
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/hub.dart';
import 'package:glacier/glacier.dart';

/// The app's own routes (lib/net/net.dart) keeping this account's home record (docs/OPEN_NETWORK.md, section 4): made
/// the first time the relay is reached, given to it at every sign-in, and made anew with the next count when the app
/// moves to another relay. Against real relays on this machine, over real WebSockets, with only the phone stood in
/// for (its key and its signing). And the words on the screens that say what relays now do.

/// A relay's hub with federation, listening on this machine.
class _Relay {
  _Relay._(this.server, this.fed, this.hub);
  final HttpServer server;
  final Federation fed;
  final Hub hub;
  String get url => 'ws://127.0.0.1:${server.port}/hub';

  static Future<_Relay> start({FedMode mode = FedMode.open, bool federation = true}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fed = Federation(config: FedConfig(mode: mode, publicHub: 'ws://127.0.0.1:${server.port}/hub'));
    final hub = Hub(federation: federation ? fed : null);
    server.listen(hub.accept);
    return _Relay._(server, fed, hub);
  }

  Future<void> stop() async {
    hub.stop();
    await server.close(force: true);
  }
}

/// Friends as the phone keeps them, over the app's own routes ([Net.instance]) for where anyone lives.
class _Friends implements BuddiesPort, BuddiesAcross {
  _Friends(this.list);
  String list;
  @override
  Homes? get homes => Net.instance.homes;
  @override
  Listenable get homesChanged => Net.instance;
  @override
  bool passedOn(String id) => false;
  @override
  String? refusedWhy(String id) => null;
  @override
  String recall(String key) => '';
  @override
  void remember(String key, String value) {}
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => '';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NetKeys keys;
  final relays = <_Relay>[];

  Future<_Relay> relay({FedMode mode = FedMode.open, bool federation = true}) async {
    final r = await _Relay.start(mode: mode, federation: federation);
    relays.add(r);
    return r;
  }

  setUp(() {
    // Real sockets to the relays above: the test binding answers every HTTP request 400 otherwise.
    HttpOverrides.global = null;
    keys = NetKeys.generate();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      switch (call.method) {
        case 'netIdentity':
          return {'id': keys.id, 'key': base64Encode(keys.public)};
        case 'netSign':
          return NetCrypto.sign(keys, ((call.arguments as Map)['message'] as List).cast<int>());
        case 'netPeers':
          return const <Object>[];
        case 'netSmsDrain':
          return const <Object>[];
      }
      return null;
    });
  });
  tearDown(() async {
    await Net.instance.shutdown();
    for (final r in relays) {
      await r.stop();
    }
    relays.clear();
  });

  /// The app's routes started on [at], signed in.
  Future<AppState> startOn(_Relay at) async {
    final app = AppState()..set('net_hub', at.url);
    await Net.instance.start(app);
    await Net.instance.want('test', true);
    await _until(() => Net.instance.hub!.state.value == CarrierState.up, 'never signed in: ${Net.instance.hub!.problem}');
    return app;
  }

  test('the record is made the first time the relay is reached, kept with the app\'s choices, and given at every sign-in', () async {
    final one = await relay();
    final app = await startOn(one);
    final homes = Net.instance.homes!;
    await _until(() => homes.mine != null && one.fed.homes.isOwn(keys.id), 'the relay was never given it');
    // Its count is never below the seconds since 1970: a device restored, or another of the account's, makes a newer
    // one than any before without knowing them.
    final first = homes.mine!.n;
    expect([homes.mine!.a, homes.mine!.h, first], [keys.id, [one.url], greaterThanOrEqualTo(DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60)]);
    expect([app.choice('net_home_n', ''), HomeRecord.check(jsonDecode(app.choice('net_home', '')), forId: keys.id)!.n], ['$first', first]);
    expect(one.fed.homes.of(keys.id)!.toJson(), homes.mine!.toJson());
    expect([Net.instance.hub!.relay!.id, Net.instance.hub!.relay!.fed, homes.relayTalks], [one.fed.id, true, true]);
    // The app is closed and opened again: the record it kept is given again as it signs in, and no new one is made.
    await Net.instance.shutdown();
    await Net.instance.start(app);
    await Net.instance.want('test', true);
    await _until(() => Net.instance.hub!.state.value == CarrierState.up, 'never signed in again');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect([Net.instance.homes!.mine!.n, app.choice('net_home_n', ''), one.fed.homes.of(keys.id)!.n], [first, '$first', first]);
    expect(Net.instance.homes!.mine!.toJson(), jsonDecode(app.choice('net_home', '')), reason: 'the very record kept, not another');
  });

  test('moving to another relay: the next count, given to the relay left before it is left, and to the new one', () async {
    final one = await relay(), two = await relay();
    final app = await startOn(one);
    await _until(() => one.fed.homes.isOwn(keys.id), 'the first relay was never given the first record');
    final first = Net.instance.homes!.mine!.n;
    final moved = await Net.instance.useRelay(two.url);
    expect(moved.problem, isNull);
    await _until(() => Net.instance.hub!.state.value == CarrierState.up && two.fed.homes.isOwn(keys.id), 'the new relay was never given it');
    final mine = Net.instance.homes!.mine!;
    expect([mine.n, mine.h, app.choice('net_home_n', '')], [greaterThan(first), [two.url], '${mine.n}']);
    expect(one.fed.homes.of(keys.id)!.toJson(), mine.toJson(), reason: 'the relay left holds the new record: it knows where they live now');
    expect(two.fed.homes.of(keys.id)!.toJson(), mine.toJson());
    // And back: the next count again.
    await Net.instance.useRelay(one.url);
    await _until(() => Net.instance.hub!.state.value == CarrierState.up && (one.fed.homes.of(keys.id)?.n ?? 0) > mine.n, 'never moved back');
    final back = Net.instance.homes!.mine!;
    expect([back.n, back.h, two.fed.homes.of(keys.id)!.n], [greaterThan(mine.n), [one.url], back.n]);
  });

  test('a relay from before, and one that doesn\'t talk to others: the record is made all the same, and the app knows which it is on', () async {
    final old = await relay(federation: false);
    await startOn(old);
    await _until(() => Net.instance.homes!.mine != null, 'no record was made');
    expect([Net.instance.homes!.mine!.h, Net.instance.hub!.relay, Net.instance.homes!.relayTalks], [[old.url], isNull, false]);
    await Net.instance.shutdown();
    keys = NetKeys.generate();
    // Off, a relay says nothing of itself and keeps nothing: the app copes as with one from before.
    final island = await relay(mode: FedMode.off);
    await startOn(island);
    await _until(() => Net.instance.homes!.mine != null, 'no record was made');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect([Net.instance.hub!.relay, Net.instance.homes!.relayTalks, island.fed.homes.own], [isNull, false, 0]);
  });

  test('who is here is not shown for a friend on another relay, though this relay saw them once; for a friend on it, it is', () async {
    final one = await relay();
    await startOn(one);
    // Maya and Anna each signed in to this relay once and went: it knows when it last saw them.
    final maya = KeysSigner(NetKeys.generate()), anna = KeysSigner(NetKeys.generate());
    for (final who in [maya, anna]) {
      final route = HubCarrier(url: one.url, signer: who);
      await route.start();
      await _until(() => route.state.value == CarrierState.up, 'never signed in');
      await route.stop();
    }
    await _until(() => one.hub.seenOf(maya.id) != null && one.hub.seenOf(anna.id) != null, 'the relay never saw them go');
    // Maya has since moved to another relay, as her record says; Anna lives on this one.
    final moved = (await HomeRecord.make(maya, addresses: ['wss://b.example/hub'], count: 2)).toJson();
    final here = (await HomeRecord.make(anna, addresses: [one.url], count: 1)).toJson();
    Buddies.instance = Buddies(_Friends(jsonEncode([
      Buddy(username: 'maya@b.example', id: maya.id, key: base64Encode(maya.publicKey), home: moved).toJson(),
      Buddy(username: 'anna', id: anna.id, key: base64Encode(anna.publicKey), home: here).toJson(),
    ])));
    addTearDown(() {
      Buddies.instance.dispose();
      Buddies.instance = null;
    });
    await Buddies.instance.start();
    expect([for (final b in Buddies.instance.friends) Buddies.instance.elsewhere(b)], [true, false]);
    // Asked of the relay for both, as an app from before would: it says when it last saw each.
    Net.instance.watchToo([maya.id, anna.id]);
    await _until(() => Net.instance.presenceOfId(maya.id) != null && Net.instance.presenceOfId(anna.id) != null, 'the relay never said when it saw them');
    expect(Presence.of('@anna')?.lastSeen, isNotNull, reason: 'a friend on this relay: last seen, as ever');
    expect(Presence.of('@maya@b.example'), isNull, reason: 'a friend on another relay: nothing is shown, not even what this relay once saw');
  });

  group('the words on the screens', () {
    test('Settings › Routes says what crosses relays now, and what still doesn\'t', () {
      expect(relayLimitsWords, startsWith('Relays can pass messages to each other.'));
      expect(relayLimitsWords, contains('@name@their.relay'));
      expect(relayLimitsWords, contains('where both relays allow it'));
      for (final still in ['usernames', 'your account backup', 'circles', 'spaces', 'calls', 'who is online', 'invite words']) {
        expect(relayLimitsWords, contains(still), reason: 'still each relay\'s own: $still');
      }
      expect(relayLimitsWords, isNot(contains('don\'t connect to each other')));
      expect(relayLimitsWords, isNot(contains('can\'t reach you')));
    });

    test('whether the relay in use passes messages on, by what it said of itself', () {
      final key = base64Encode(keys.public);
      expect(relayTalksWords(HubRelay(id: keys.id, key: key, fed: true)), ('Passes messages to other relays', 'A friend on another relay, added as @name@their.relay, is reached through this one.'));
      expect(relayTalksWords(HubRelay(id: keys.id, key: key)).$1, 'Doesn\'t pass messages to other relays');
      expect(relayTalksWords(HubRelay(id: keys.id, key: key)).$2, contains('hasn\'t switched that on'));
      expect(relayTalksWords(null), ('Doesn\'t pass messages to other relays', 'It has that switched off, or is from before relays talked to each other. You reach only people who use it.'), reason: 'a relay with it off says nothing of itself, as one from before');
    });

    test('the add-friend screen, an add-me link on a relay of one\'s own, a friend\'s card and a call say what is true', () {
      expect(addFriendWords('matt'), 'Type their username. For someone on another relay, add the relay after it: @name@their.relay. You\'re @matt.');
      expect(addUnreachedWords('maya@relay.example'), 'Found @maya@relay.example, but your relay doesn\'t pass messages to theirs yet. The request is kept, and sent again by itself for two weeks.');
      expect(addUnreachedWords('maya@relay.example', 'their relay would not take it'), 'Found @maya@relay.example, but their relay would not take it. The request is kept, and sent again by itself for two weeks.');
      final link = addMeElsewhereWords('wss://relay.example.com/hub', 'maya');
      expect(link, 'You use your own relay, relay.example.com. @maya is looked up there, so this may be someone other than the person who shared the link, or nobody. If they are on another relay, add them as @maya@their.relay in Add a friend instead.');
      expect(friendRelayWords('relay.example'), 'On relay.example, another relay than yours. What you write to each other goes through your relay to theirs, where both pass messages on.');
      expect(friendRelayWords('relay.example', talks: false), 'On relay.example, another relay than yours, and yours doesn\'t pass messages to other relays: what you write doesn\'t reach them from here.');
      expect(callElsewhereWords('Maya', 'relay.example'), 'Calls don\'t reach another relay yet. Maya is on relay.example, and your relay doesn\'t pass messages to theirs.', reason: 'no routes are up here: the relay in use is not known to talk');
      expect(movingWords('wss://gogho.st/hub'), contains('Friends who stay on gogho.st reach you there only where it and the new relay pass messages to each other'));
    });

    testWidgets('Settings › Routes shows that the relay in use passes messages to other relays, once the app has signed in to it', (tester) async {
      tester.view.physicalSize = const Size(412, 3000) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final one = (await tester.runAsync(relay))!;
      final island = (await tester.runAsync(() => relay(mode: FedMode.off)))!;
      final state = (await tester.runAsync(() => startOn(one)))!;
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final model = SettingsModel(state);
      addTearDown(model.dispose);
      Widget pane() => AppScope(
            state: state,
            child: WidgetsApp(
              color: const Color(0xFF000000),
              pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
              builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
              home: ListenableBuilder(listenable: Net.instance, builder: (context, _) => ListView(children: networkPane(context, model))),
            ),
          );
      await tester.pumpWidget(pane());
      await tester.pump(const Duration(milliseconds: 50));
      String talks() => (tester.widget(find.descendant(of: find.byKey(const ValueKey('relay-talks')), matching: find.byType(Text)).first) as Text).data!;
      expect(talks(), 'Passes messages to other relays');
      expect(find.text(relayLimitsWords), findsOneWidget);
      // Moved to a relay whose keeper hasn't switched it on.
      await tester.runAsync(() async {
        await Net.instance.useRelay(island.url);
        await _until(() => Net.instance.hub!.state.value == CarrierState.up, 'never signed in to the second relay');
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(talks(), 'Doesn\'t pass messages to other relays');
      // A record of where this account lives that couldn't be made is said, not swallowed (found in the review of
      // relays that talk, 2026-11-23).
      expect(find.byKey(const ValueKey('relay-home-problem')), findsNothing);
      Net.instance.homes!.problem = 'Where this account lives could not be signed: no key';
      await tester.pumpWidget(pane());
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.descendant(of: find.byKey(const ValueKey('relay-home-problem')), matching: find.text('Where this account lives could not be signed: no key')), findsOneWidget);
      Net.instance.homes!.problem = null;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
