import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/desk.dart' show defaultRelay;
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/relay_choice.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsModel;
import 'package:glacier/glacier.dart';

/// GMFB-25, "Self-hosting the relay, documented": another relay's address is tidied, asked whether an Uplink
/// relay answers there, and only then used; going back to ours is one step; and nothing changes for anyone who never
/// touches it.

/// A stand-in for a server at 127.0.0.1: a hub that greets as relay/lib/hub.dart does, one that accepts the WebSocket
/// and says nothing, or one that says something else.
Future<HttpServer> _server(String kind) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = 200
        ..write('Ghost Messaging relay\n');
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    if (kind == 'hub') ws.add(jsonEncode({'hello': '0123456789abcdef0123456789abcdef', 'peek': true, 'react': true}));
    if (kind == 'other') ws.add(jsonEncode({'welcome': 'to some other server'}));
    ws.listen((_) {}, onDone: () {});
  });
  return server;
}

String _hubAt(HttpServer s) => 'ws://127.0.0.1:${s.port}/hub';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Real sockets to the stand-ins above: the test binding answers every HTTP request 400 otherwise.
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      switch (call.method) {
        case 'netIdentity':
          return {'id': '0f' * 16, 'key': 'AlFcPW655Ja5BNP+yn9U/c0MwemXvzddylFa0KbDtANf'};
        case 'netPeers':
          return const <Object>[];
        case 'netSmsDrain':
          return const <Object>[];
      }
      return null;
    });
  });
  tearDown(() => Net.instance.shutdown());

  group('the defaults are as they were', () {
    test('ours is gogho.st, and an install that never chose stays on it', () async {
      expect(Net.defaultHub, 'wss://gogho.st/hub');
      expect(defaultRelay, 'wss://gogho.st/relay');
      final app = AppState();
      await Net.instance.start(app);
      expect(Net.instance.hubUrl, Net.defaultHub);
      expect(Net.instance.onDefaultHub, isTrue);
      expect(Net.instance.hub!.url, Net.defaultHub);
      expect(app.choice('net_hub', 'unset'), 'unset', reason: 'nothing is written until someone chooses');
      expect(relayInUseWords(Net.defaultHub), 'Uplink\'s relay (gogho.st)');
    });

    test('an address chosen before this change is still read as it was', () async {
      final app = AppState()..set('net_hub', ' wss://relay.example.com/hub ');
      await Net.instance.start(app);
      expect(Net.instance.hubUrl, 'wss://relay.example.com/hub');
      expect(Net.instance.onDefaultHub, isFalse);
    });
  });

  group('what a typed address becomes', () {
    test('tidied to a WebSocket address ending in /hub', () {
      expect(tidyRelayAddress(''), '');
      expect(tidyRelayAddress('   '), '');
      expect(tidyRelayAddress('relay.example.com'), 'wss://relay.example.com/hub');
      expect(tidyRelayAddress('Relay.Example.com/'), 'wss://relay.example.com/hub');
      expect(tidyRelayAddress('https://relay.example.com'), 'wss://relay.example.com/hub');
      expect(tidyRelayAddress('wss://relay.example.com/hub'), 'wss://relay.example.com/hub');
      expect(tidyRelayAddress('wss://relay.example.com/ghost/hub/'), 'wss://relay.example.com/ghost/hub');
      expect(tidyRelayAddress('wss://relay.example.com/ghost'), 'wss://relay.example.com/ghost/hub');
      expect(tidyRelayAddress('http://192.168.1.20:8787'), 'ws://192.168.1.20:8787/hub');
      expect(tidyRelayAddress('wss://relay.example.com:8443/hub?x=1#y'), 'wss://relay.example.com:8443/hub');
      expect(tidyRelayAddress('gogho.st'), Net.defaultHub);
    });

    test('refused where it cannot be an address', () {
      expect(tidyRelayAddress('ftp://relay.example.com'), isNull);
      expect(tidyRelayAddress('relay example com'), isNull);
      expect(tidyRelayAddress('wss://'), isNull);
      expect(tidyRelayAddress('wss://me:secret@relay.example.com/hub'), isNull);
    });

    test('the relay in use, named', () {
      expect(relayInUseWords('wss://relay.example.com/hub'), 'Your own relay: relay.example.com');
      expect(relayInUseWords('ws://127.0.0.1:8787/hub'), 'Your own relay: 127.0.0.1:8787');
      expect(relayInUseWords('wss://ghost-sms.com/hub'), 'Uplink\'s relay (ghost-sms.com)');
    });
  });

  group('asking whether a relay answers', () {
    test('an Uplink hub answers', () async {
      final s = await _server('hub');
      addTearDown(() => s.close(force: true));
      final r = await checkRelay(_hubAt(s), timeout: const Duration(seconds: 5));
      expect(r.ok, isTrue, reason: r.problem);
      expect(r.took, isNotNull);
    });

    test('a WebSocket server that says nothing, or something else, is not one', () async {
      final quiet = await _server('quiet'), other = await _server('other');
      addTearDown(() => quiet.close(force: true));
      addTearDown(() => other.close(force: true));
      final a = await checkRelay(_hubAt(quiet), timeout: const Duration(milliseconds: 600));
      expect(a.ok, isFalse);
      expect(a.problem, contains('not as an Uplink relay'));
      final b = await checkRelay(_hubAt(other), timeout: const Duration(seconds: 5));
      expect(b.ok, isFalse);
      expect(b.problem, contains('not as an Uplink relay'));
    });

    test('nobody there is not one', () async {
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = s.port;
      await s.close(force: true);
      final r = await checkRelay('ws://127.0.0.1:$port/hub', timeout: const Duration(seconds: 5));
      expect(r.ok, isFalse);
      expect(r.problem, startsWith('Couldn\'t connect'));
    });
  });

  group('switching', () {
    test('only once a relay answers, after the person says yes; back to ours in one step', () async {
      final app = AppState();
      await Net.instance.start(app);
      final net = Net.instance;
      final quiet = await _server('quiet'), hub = await _server('hub');
      addTearDown(() => quiet.close(force: true));
      addTearDown(() => hub.close(force: true));

      // Not an address: nothing changes.
      var r = await net.useRelay('ftp://nope');
      expect(r.problem, isNotNull);
      expect(net.hubUrl, Net.defaultHub);

      // Something there, but no relay: nothing changes, and nobody was asked.
      var asked = 0;
      r = await net.useRelay(_hubAt(quiet), timeout: const Duration(milliseconds: 600), confirm: (_) async {
        asked++;
        return true;
      });
      expect(r.problem, contains('not as an Uplink relay'));
      expect(asked, 0);
      expect(net.hubUrl, Net.defaultHub);
      expect(app.choice('net_hub', 'unset'), 'unset');

      // A relay answers, and the person says no: nothing changes.
      r = await net.useRelay(_hubAt(hub), confirm: (_) async => false);
      expect(r.problem, isNull);
      expect(r.declined, isTrue);
      expect(net.hubUrl, Net.defaultHub);

      // A relay answers, and the person says yes: the route is the new one.
      String? confirmed;
      r = await net.useRelay('http://127.0.0.1:${hub.port}', confirm: (url) async {
        confirmed = url;
        return true;
      });
      expect(r.problem, isNull);
      expect(r.declined, isFalse);
      expect(confirmed, _hubAt(hub), reason: 'the tidied address is what is asked about and used');
      expect(net.hubUrl, _hubAt(hub));
      expect(net.onDefaultHub, isFalse);
      expect(net.hub!.url, _hubAt(hub));
      expect(net.board!.carrier('hub'), same(net.hub), reason: 'the switchboard routes by the new one');
      expect(app.choice('net_hub', ''), _hubAt(hub));

      // Back to ours: no check, no question.
      r = await net.useRelay('', confirm: (_) async => fail('going back to ours asks nothing'));
      expect(r.problem, isNull);
      expect(net.hubUrl, Net.defaultHub);
      expect(net.hub!.url, Net.defaultHub);
      expect(app.choice('net_hub', 'unset'), '');
    });
  });

  group('Settings › Routes', () {
    Future<void> open(WidgetTester tester, AppState state) async {
      tester.view.physicalSize = const Size(412, 3000) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => Net.instance.start(state));
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final model = SettingsModel(state);
      addTearDown(model.dispose);
      await tester.pumpWidget(AppScope(
        state: state,
        child: WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
          home: ListenableBuilder(listenable: Net.instance, builder: (context, _) => ListView(children: networkPane(context, model))),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
    }

    String inUse(WidgetTester tester) => (tester.widget(find.descendant(of: find.byKey(const ValueKey('relay-in-use')), matching: find.byType(Text)).first) as Text).data!;

    testWidgets('shows ours in use, with no way "back" to it', (tester) async {
      await open(tester, AppState());
      expect(inUse(tester), 'Uplink\'s relay (gogho.st)');
      expect(find.byKey(const ValueKey('relay-use-default')), findsNothing);
      expect(find.text(relayLimitsWords), findsOneWidget, reason: 'what a relay of your own does not reach is said');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an address that cannot be one is refused where it was typed; nothing changes', (tester) async {
      final state = AppState();
      await open(tester, state);
      await tester.enterText(find.byType(EditableText), 'ftp://nope');
      await tester.tap(find.byKey(const ValueKey('relay-check-and-use')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('relay-problem')), findsOneWidget);
      expect(Net.instance.hubUrl, Net.defaultHub);
      expect(state.choice('net_hub', 'unset'), 'unset');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on another relay it is named, and one press goes back to ours', (tester) async {
      final state = AppState()..set('net_hub', 'wss://relay.example.com/hub');
      await open(tester, state);
      expect(inUse(tester), 'Your own relay: relay.example.com');
      await tester.tap(find.byKey(const ValueKey('relay-use-default')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      expect(Net.instance.hubUrl, Net.defaultHub);
      expect(inUse(tester), 'Uplink\'s relay (gogho.st)');
      expect(find.byKey(const ValueKey('relay-use-default')), findsNothing);
      expect(tester.widget<EditableText>(find.byType(EditableText)).controller.text, '', reason: 'the field follows: ours is shown as empty');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
