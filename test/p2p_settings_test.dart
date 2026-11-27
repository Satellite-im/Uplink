import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/p2p.dart';
import 'package:ghost_messaging/net/p2p/p2p_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsModel;
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';
import 'package:glacier/glacier.dart';

import 'support/direct_world.dart';
import 'support/fake_p2p.dart';

/// Settings › Routes and the direct route (lib/ui/network.dart): no Direct row at all in a build with no core; with
/// one, the route among the others with its switch, and under them what it knows, what it holds now, "Only through
/// link helpers", and a line where the relay has named no link helper.

const _helper = 'https://link.example';

/// Every piece of text drawn in the row keyed [key].
List<String> _words(WidgetTester tester, String key) => [for (final t in tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))) ?t.data];

Finder _switchIn(String key) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(GlacierSwitch));

/// Flips the switch in the row keyed [key] to [on], as a tap does (its own onCheckedChange), with what that sets off
/// let run outside the test's clock: what switching Direct on makes (its node's timers, its streams) is stopped again by
/// the test the same way.
Future<void> _flip(WidgetTester tester, String key, bool on) async {
  final change = tester.widget<GlacierSwitch>(_switchIn(key)).onCheckedChange!;
  await tester.runAsync(() async => change(on));
}

/// Lets what a press set off finish, however long the machine takes (two seconds at most), not for a length of time.
Future<void> _until(WidgetTester tester, bool Function() ok) async {
  for (var i = 0; i < 400 && !ok(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 50));
}

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('what the rows say', () {
    expect([directKnownWords(0), directKnownWords(1), directKnownWords(4)], ['No friend\'s device known yet', 'Knows 1 friend\'s device', 'Knows 4 friends\' devices']);
    const how = 'A device is known once it and this one have told each other they are here, which they do through the relay server.';
    expect([directKnownHint(0), directKnownHint(1), directKnownHint(3)], [how, 'And 1 other device of your own. $how', 'And 3 other devices of your own. $how']);
    expect([directLinkedWords(0), directLinkedWords(1), directLinkedWords(2)], ['Not linked to any now', 'Linked to 1 device now', 'Linked to 2 devices now']);
    expect(directLinkedHint(const []), 'A link is made when the relay server can\'t carry something, and let go when nothing has been said on it for a while.');
    expect(directLinkedHint(const [P2pPathKind.direct]), '1 straight.');
    expect(directLinkedHint(const [P2pPathKind.helper, P2pPathKind.direct, P2pPathKind.helper]), '1 straight, 2 through a link helper.');
    expect(directLinkedHint(const [P2pPathKind.helper]), '1 through a link helper.');
    expect(directLinkedHint(const [P2pPathKind.none]), 'Finding the way.');
    expect(directHelpersOnlyHint, 'Friends\' devices then see the link helper\'s address and not this device\'s. It is slower.');
    // What switching Direct on means, said before it is on (Matt's brief, 2026-11-23): a friend's device learns this
    // device's network address, only the account's own devices and friends are told, a link helper sees which devices
    // link and how much is sent, never who or what.
    expect(P2pCarrier.aboutWords, 'Straight between your devices and your friends\', for when the relay server can\'t carry something. Their devices learn this device\'s network address, and nobody else is told it. A link helper sees which devices link and how much they send, never who they are or what is said.');
    expect(directOffWords, 'Switched on, this device links straight with your own devices and your friends\' when the relay server can\'t carry something, and checks what the relay says against what they say. Only those devices are told where this one is, and they learn its network address.');
    expect(directHelperWords, 'A link helper is a server that helps two devices find each other and passes their sealed packets along where no straight path can be made. It sees which devices link and how much they send, never who they are or what is said.');
    // A relay that names no link helper: what that costs, and no helper made up in its place.
    expect([directNoHelperLabel, directNoHelperHint(helpersOnly: false), directNoHelperHint(helpersOnly: true)], [
      'The relay server names no link helper',
      'So only devices that can reach each other as they are link up, such as two on the same network: devices behind most home routers can\'t link.',
      'So nothing links while "Only through link helpers" is on.',
    ]);
  });

  test('the settings pages are told to draw again when what the direct route knows or holds changes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    final model = SettingsModel(AppState())..start();
    await pumpEventQueue();
    var drawn = 0;
    model.addListener(() => drawn++);
    Net.instance.direct.value++;
    expect(drawn, 1);
    // And when the route that last carried something to or from someone changes (Which route each conversation is on).
    Net.instance.routesUsed.value++;
    expect(drawn, 2);
    model.dispose();
    Net.instance.direct.value++;
    Net.instance.routesUsed.value++;
    expect(drawn, 2, reason: 'and no longer once the pages are gone');
  });

  group('Settings › Routes, as the app holds the routes', () {
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

    // GMFB-24: "Settings shows which route each conversation is using."
    testWidgets('which route each person is on: none listed before anything went or came; then the route that last carried something each way, and when', (tester) async {
      await open(tester, AppState());
      final key = NetCrypto.netKey(NetCrypto.conversationKey(me, sam.public)!);
      expect(find.text('WHICH ROUTE EACH CONVERSATION IS ON'), findsNothing);
      expect(find.byKey(ValueKey('used-${sam.id}')), findsNothing);
      await tester.runAsync(() async {
        await Net.instance.send(Net.instance.byId(sam.id)!, Envelope(kind: 'text', ack: false), only: {'hub'});
        final sms = Net.instance.board!.carrier('sms')! as PlainCarrier;
        sms.take(Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(key, Envelope(kind: 'text', ack: false).encode())));
        for (var i = 0; i < 400 && Net.instance.board!.used[sam.id]?.cameBy == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      final model = SettingsModel(AppState());
      addTearDown(model.dispose);
      await _pump(tester, AppState(), Listenable.merge([Net.instance, Net.instance.routesUsed]), (context) => networkPane(context, model));
      expect(find.text('WHICH ROUTE EACH CONVERSATION IS ON'), findsOneWidget);
      expect(_words(tester, 'used-${sam.id}'), ['@sam', 'Last sent by Relay server, just now; last came by SMS, just now.']);
      // What they send next by the relay is what is shown, as it comes.
      await tester.runAsync(() async {
        final hub = Net.instance.board!.carrier('hub')! as PlainCarrier;
        hub.take(Packet.wrap(from: sam.id, sealed: true, payload: NetCrypto.seal(key, Envelope(kind: 'text', ack: false).encode())));
        for (var i = 0; i < 400 && Net.instance.board!.used[sam.id]?.cameBy != 'hub'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(_words(tester, 'used-${sam.id}').last, 'Last sent by Relay server, just now; last came by Relay server, just now.');
      expect([routeName('hub'), routeName('p2p'), routeName('sms'), routeName('lan')], ['Relay server', 'Direct', 'SMS', 'Local network']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a build with no core shows no Direct row at all, and nothing of the direct route', (tester) async {
      await open(tester, AppState());
      expect(find.byKey(const ValueKey('route-hub')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-sms')), findsOneWidget);
      expect(find.byKey(const ValueKey('route-p2p')), findsNothing);
      for (final key in ['direct-known', 'direct-linked', 'direct-helpers-only', 'direct-no-helpers']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.text('Direct'), findsNothing);
      expect(find.text('DIRECT'), findsNothing);
      expect(find.textContaining('A direct route between devices, with no server, isn\'t in this build yet.'), findsOneWidget, reason: 'said to be missing here');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a core that could not be started: the other routes as ever, Direct switched on and not working, and a line that says why', (tester) async {
      Net.p2pNode = FakeP2pMesh.broken(StateError('libghost_p2p.so could not be loaded'));
      await open(tester, AppState()..set(Net.directName, 'on'));
      expect(find.byKey(const ValueKey('route-hub')), findsOneWidget);
      expect(_words(tester, 'route-p2p'), ['Direct', 'Not working on this device\n${P2pCarrier.aboutWords}']);
      expect(tester.widget<GlacierSwitch>(_switchIn('route-p2p')).checked, isTrue);
      expect(_words(tester, 'direct-problem'), ['Direct isn\'t working on this device', 'The direct route could not be started on this device (Bad state: libghost_p2p.so could not be loaded). The other routes work as before.']);
      for (final key in ['direct-known', 'direct-linked', 'direct-helpers-only']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      // Checking the relay says there is no direct route here, not that Direct is off.
      expect(find.textContaining('This device has no direct route'), findsOneWidget);
      expect(find.textContaining('Direct is off'), findsNothing);
      // Switched off: nothing is tried, and nothing said of it.
      await _flip(tester, 'route-p2p', false);
      await _until(tester, () => !Net.instance.directOn);
      expect([Net.instance.directProblem, find.byKey(const ValueKey('direct-problem')).evaluate().length], [null, 0]);
      expect(_words(tester, 'route-p2p').last, startsWith('Off\n'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with a core, Direct is among the routes after the relay\'s, switched off and saying what switching it on means; switched on, its route, its lines and its switch; off again, as before', (tester) async {
      final mesh = FakeP2pMesh();
      var made = 0;
      Net.p2pNode = () {
        made++;
        return mesh.node();
      };
      final state = AppState();
      await open(tester, state);
      List<String> routes() => [for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('route-')).evaluate()) (e.widget.key as ValueKey<String>).value];
      // Among the routes, after the relay's, switched off: its name and what switching it on means. Nothing of it made.
      expect(routes(), ['route-hub', 'route-p2p', 'route-sms']);
      expect(_words(tester, 'route-p2p'), ['Direct', 'Off\n${P2pCarrier.aboutWords}']);
      expect(tester.widget<GlacierSwitch>(_switchIn('route-p2p')).checked, isFalse);
      expect([made, Net.instance.p2p], [0, null]);
      expect(find.textContaining('a peer-to-peer one'), findsNothing);
      // (No local network route under a test: it would open ports on this machine. test/lan_net_test.dart has it.)
      expect(find.text('No local network route here: this build has none.'), findsOneWidget);
      // Its section says it too, before it is on, and offers "Only through link helpers" first.
      expect(find.text('DIRECT'), findsOneWidget);
      expect(find.text(directOffWords), findsOneWidget);
      expect(find.text(directHelperWords), findsOneWidget);
      expect(_words(tester, 'direct-helpers-only'), ['Only through link helpers', directHelpersOnlyHint]);
      for (final key in ['direct-known', 'direct-linked']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      // (A relay of the test's own, which names nothing: not said to name no link helper either.)
      expect(find.byKey(const ValueKey('direct-no-helpers')), findsNothing);

      // Switched on, without the app starting again: its route among the others, its lines and its switch under them.
      await _flip(tester, 'route-p2p', true);
      await _until(tester, () => Net.instance.p2p?.card != null);
      expect([made, state.choice(Net.directName, ''), state.choice('net_off', 'x')], [1, 'on', 'x']);
      expect(routes(), ['route-hub', 'route-p2p', 'route-sms']);
      expect(_words(tester, 'route-p2p'), ['Direct', 'Ready\n${P2pCarrier.aboutWords}']);
      expect(tester.widget<GlacierSwitch>(_switchIn('route-p2p')).checked, isTrue);
      expect(find.text(directOnWords), findsOneWidget);
      expect(_words(tester, 'direct-known'), ['No friend\'s device known yet', directKnownHint(0)]);
      expect(_words(tester, 'direct-linked'), ['Not linked to any now', directLinkedHint(const [])]);
      expect(_words(tester, 'direct-helpers-only'), ['Only through link helpers', directHelpersOnlyHint]);
      expect(_words(tester, 'direct-no-helpers'), [directNoHelperLabel, directNoHelperHint(helpersOnly: false)]);
      expect(tester.widget<GlacierSwitch>(_switchIn('direct-helpers-only')).checked, isFalse);

      // "Only through link helpers": kept as the person's choice, and said to mean nothing links for now.
      await tester.tap(_switchIn('direct-helpers-only'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(Net.instance.p2p!.helpersOnly, isTrue);
      expect(state.choice(P2p.helpersOnlyName, ''), 'on');
      expect(tester.widget<GlacierSwitch>(_switchIn('direct-helpers-only')).checked, isTrue);
      expect(_words(tester, 'direct-no-helpers').last, directNoHelperHint(helpersOnly: true));
      // The relay names a link helper: that line goes.
      Net.instance.p2p!.setHelpers(const [_helper]);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('direct-no-helpers')), findsNothing);

      // Switched off: the route and its lines go, the switch and the words before it is on come back.
      await _flip(tester, 'route-p2p', false);
      await _until(tester, () => Net.instance.p2p == null && Net.instance.board!.off.contains('p2p'));
      expect([state.choice(Net.directName, ''), state.choice('net_off', 'x'), Net.instance.board!.off], ['off', 'x', {'p2p'}]);
      expect(routes(), ['route-hub', 'route-p2p', 'route-sms']);
      expect(_words(tester, 'route-p2p'), ['Direct', 'Off\n${P2pCarrier.aboutWords}']);
      expect(tester.widget<GlacierSwitch>(_switchIn('route-p2p')).checked, isFalse);
      expect(find.text(directOffWords), findsOneWidget);
      expect(find.byKey(const ValueKey('direct-known')), findsNothing);
      expect(tester.widget<GlacierSwitch>(_switchIn('direct-helpers-only')).checked, isTrue, reason: 'the choice stays');
      // And on again: the same node.
      await _flip(tester, 'route-p2p', true);
      await _until(tester, () => Net.instance.p2p?.card != null);
      expect([made, _words(tester, 'route-p2p').last], [1, startsWith('Ready\n')]);
      // Everything that was started is stopped before the page goes.
      await tester.runAsync(() => Net.instance.shutdown());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    // Matt's brief: "Where the relay in use names no link helper (a self-hosted relay, or gogho.st today), say what that
    // costs (devices behind most home routers can't link) rather than inventing a default."
    testWidgets('before Direct is on: a relay that names no link helper is said with what it costs, and "Only through link helpers" can be chosen first and is what Direct then starts with', (tester) async {
      final relay = Relay(hub: Hub());
      final port = (await tester.runAsync(() => relay.start(port: 0)))!;
      addTearDown(() => tester.runAsync(relay.stop));
      final mesh = FakeP2pMesh();
      Net.p2pNode = mesh.node;
      final state = AppState()..set('net_hub', 'ws://127.0.0.1:$port/hub');
      await tester.runAsync(() async {
        await Net.instance.start(state);
        for (var i = 0; i < 400 && Net.instance.relayHelpers == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      expect(Net.instance.relayHelpers, isEmpty, reason: 'signed in, and named none');
      final model = SettingsModel(state);
      addTearDown(model.dispose);
      await _pump(tester, state, Listenable.merge([Net.instance, Net.instance.direct]), (context) => networkPane(context, model));
      expect(_words(tester, 'direct-no-helpers'), [directNoHelperLabel, directNoHelperHint(helpersOnly: false)]);
      // Chosen before Direct is on: kept with the choices, as the direct network keeps it.
      await tester.tap(_switchIn('direct-helpers-only'));
      await tester.pump(const Duration(milliseconds: 50));
      expect([state.choice(P2p.helpersOnlyName, ''), Net.instance.helpersOnly, Net.instance.p2p], ['on', true, null]);
      expect(tester.widget<GlacierSwitch>(_switchIn('direct-helpers-only')).checked, isTrue);
      expect(_words(tester, 'direct-no-helpers').last, directNoHelperHint(helpersOnly: true));
      // Switched on: it starts with it.
      await _flip(tester, 'route-p2p', true);
      await _until(tester, () => Net.instance.p2p?.loaded ?? false);
      expect(Net.instance.p2p!.helpersOnly, isTrue);
      await tester.runAsync(() => Net.instance.shutdown());
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('the Direct section, over devices that know and link with each other', () {
    testWidgets('says how many friends\' devices are known and how many of your own, how many are linked and how, and draws again as that changes', (tester) async {
      final w = World(helpers: [_helper]);
      final maya = w.account('maya');
      late Install a, b, mine;
      await tester.runAsync(() async {
        a = w.install(maya, computer: true);
        mine = w.install(maya, computer: true);
        b = w.install(w.account('sam'), computer: true, network: 'elsewhere');
        w.friends(a, b);
        w.friends(mine, b);
        for (final i in [a, mine, b]) {
          await i.start();
        }
      });
      addTearDown(() => tester.runAsync(w.stop));
      final state = AppState();
      await _pump(tester, state, a.p2p, (context) => [directSection(context, a.p2p)]);
      expect(_words(tester, 'direct-known'), ['Knows 1 friend\'s device', directKnownHint(1)]);
      expect(_words(tester, 'direct-linked'), ['Not linked to any now', directLinkedHint(const [])]);
      expect(find.byKey(const ValueKey('direct-no-helpers')), findsNothing, reason: 'the relay named one');
      expect(find.text('DIRECT'), findsOneWidget);

      // The relay goes, and a text is sent: a link to the friend's device on another network, through the helper, and
      // one to this account's own other device, straight.
      await tester.runAsync(() async {
        await w.relayGone();
        await a.text(b.account, 'by the helper');
        await a.board.send(a.mine, _mine(), only: const {'p2p'});
        await w.settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(_words(tester, 'direct-linked'), ['Linked to 2 devices now', '1 straight, 1 through a link helper.']);

      // "Only through link helpers": the node is started again with it, so the links go, and are made through the
      // helper when next used.
      await tester.tap(_switchIn('direct-helpers-only'));
      await tester.runAsync(w.settle);
      await tester.pump(const Duration(milliseconds: 50));
      expect([a.p2p.helpersOnly, a.node.config!.helpersOnly, a.plain.kept[P2p.helpersOnlyName]], [true, true, 'on']);
      expect(_words(tester, 'direct-linked').first, 'Not linked to any now');
      await tester.runAsync(() async {
        await a.board.send(a.mine, _mine(), only: const {'p2p'});
        await w.settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(_words(tester, 'direct-linked'), ['Linked to 1 device now', '1 through a link helper.']);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

Envelope _mine() => Envelope(kind: 'mine', body: const {'t': 'to my other device'});
