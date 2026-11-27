import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/relay_host/hosting.dart';
import 'package:ghost_messaging/relay_host/relay_host_io.dart';
import 'package:ghost_messaging/relay_host/relay_host_web.dart' as web;
import 'package:ghost_messaging/relay_host/words.dart';
import 'package:ghost_messaging/ui/account_screens.dart' show askSignOut;
import 'package:ghost_messaging/ui/network.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsModel;
import 'package:glacier/glacier.dart';

import 'support/host_support.dart';

/// Settings › Routes › Host a relay on this device (lib/ui/relay_host_section.dart; lib/relay_host): off unless switched
/// on, and said before it is (what the host sees, how long it runs, what the network sees and the firewall's question,
/// and that gogho.st won't take its link yet); while it runs, how it stands, this app on it, its addresses, its pass
/// phrase; and on the other side, the relay picker asking for a hosted relay's pass phrase and saying who sees what.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NetKeys keys;
  setUp(() {
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
  tearDown(() => Net.instance.shutdown());

  Future<void> open(WidgetTester tester, AppState state) async {
    tester.view.physicalSize = const Size(412, 1600) * 2.0;
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
        // Every row built, as a column that scrolls: what a test taps is brought into view first ([tap]).
        home: ListenableBuilder(listenable: Net.instance, builder: (context, _) => SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: networkPane(context, model)))),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Lets real work (sockets, the hub, keys made aside) go on, and draws, until [ok] or twenty seconds have gone.
  Future<void> until(WidgetTester tester, bool Function() ok, String what) async {
    for (var i = 0; i < 400 && !ok(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(ok(), isTrue, reason: what);
  }

  /// Taps what [finder] finds, brought into view first.
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    // (A field just typed into brings itself into view, scrolling a while; nothing is pressed while a list scrolls.)
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(finder);
  }

  /// Types [text] into what [finder] finds, brought into view first.
  Future<void> type(WidgetTester tester, Finder finder, String text) async {
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(finder, text);
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// The words of the Text with [key], or of the first Text inside what has it.
  String textOf(WidgetTester tester, Key key) {
    final w = tester.widget(find.byKey(key));
    return w is Text ? w.data! : (tester.widget(find.descendant(of: find.byKey(key), matching: find.byType(Text)).first) as Text).data!;
  }

  /// Everything stopped and the screen gone; and the clock of what was dialled from the screen moved past a
  /// WebSocket's own ping and the wait for its answer (25 seconds each), which a socket closed under the test's clock
  /// leaves behind.
  Future<void> done(WidgetTester tester) async {
    await tester.runAsync(() => Net.instance.shutdown());
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 30));
    }
  }

  testWidgets('off by default: the switch alone, nothing listening; a browser\'s build has none to show', (tester) async {
    final state = AppState();
    await open(tester, state);
    expect(Net.instance.relayHost, isA<RelayHost>(), reason: 'a computer (this one, running the test) can host');
    expect(web.makeRelayHost(), isNull);
    expect(find.byKey(const ValueKey('host-on')), findsOneWidget);
    expect(tester.widget<GlacierSwitch>(find.descendant(of: find.byKey(const ValueKey('host-on')), matching: find.byType(GlacierSwitch))).checked, isFalse);
    expect(find.text(hostOffHint), findsOneWidget);
    for (final key in ['host-limits', 'host-via', 'host-use', 'host-lan', 'host-direct', 'host-pass-set']) {
      expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
    }
    expect([Net.instance.relayHost!.state, state.choice(RelayHost.onKey, 'unset')], [HostState.off, 'unset'], reason: 'nothing is written until someone chooses');
    await done(tester);
  });

  testWidgets('switched on, it says first what the host sees, how long it runs, what the network sees, the firewall\'s question and that gogho.st won\'t take its link; then it runs', (tester) async {
    final state = AppState();
    await open(tester, state);
    final host = Net.instance.relayHost!;
    await tap(tester, find.descendant(of: find.byKey(const ValueKey('host-on')), matching: find.byType(GlacierSwitch)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final words = textOf(tester, const ValueKey('host-words'));
    for (final said in [hostSeesWords, hostRunsWords(phone: false), lanSeenWords, firewallWords('macos', 7787), 'gogho.st doesn\'t take links from relays hosted from an app yet']) {
      expect(words, contains(said));
    }
    expect(host.on, isFalse, reason: 'nothing changes until the person says so');
    await tap(tester, find.text('Host it'));
    await until(tester, () => host.state == HostState.up, 'it never started');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.choice(RelayHost.onKey, ''), 'on');
    expect(textOf(tester, const ValueKey('host-on')), hostLabel);
    expect(find.text(hostStateWords(host)), findsOneWidget);
    expect(find.text(hostLimitsWords), findsOneWidget);
    expect(find.byKey(const ValueKey('host-via')), findsOneWidget);
    expect(find.text(directNoneWords), findsOneWidget, reason: 'this build has no direct route');
    // Its address on this network (this machine alone, under a test), with its QR code and link.
    expect(host.lanUrls, [matches(RegExp(r'^ws://127\.0\.0\.1:\d+/hub$'))]);
    expect(find.text(host.lanUrls.single), findsOneWidget);
    expect(find.byKey(const ValueKey('host-lan-qr')), findsOneWidget);
    expect(find.text(noPassWords), findsOneWidget);
    await done(tester);
  });

  testWidgets('signing out, while it hosts one, says the relay on this device stops, and what of it stays', (tester) async {
    final state = AppState();
    await open(tester, state);
    final host = Net.instance.relayHost!;
    final words = signOutHostWords(everything: false);
    askSignOut(tester.element(find.byKey(const ValueKey('host-on'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(words), findsNothing, reason: 'not hosting: nothing of it said');
    Navigator.of(tester.element(find.byKey(const ValueKey('host-on'))), rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => host.setOn(true));
    askSignOut(tester.element(find.byKey(const ValueKey('host-on'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining(words), findsOneWidget);
    expect(words, 'It also stops the relay on this device and switches it off, and forgets its pass phrase: everyone on it sees their relay gone. Its folder (its key, where its people said they live) stays.');
    expect(signOutHostWords(everything: true), endsWith('stays, unless you delete everything here.'));
    Navigator.of(tester.element(find.byKey(const ValueKey('host-on'))), rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 300));
    await done(tester);
  });

  testWidgets('used for this app: offered once its public relay lets it stay, asked first, saying what it means for the account\'s other devices and its friends; then this app is on it, in memory', (tester) async {
    final state = AppState();
    final public = (await tester.runAsync(PublicRelay.start))!;
    Net.relayHostMaker = () => RelayHost(via: public.via, viaPlain: true, viaPorts: {public.port}, viaDial: public.viaDial, phone: false);
    addTearDown(() => Net.relayHostMaker = makeRelayHost);
    await open(tester, state);
    final host = Net.instance.relayHost!;
    await tester.runAsync(() => host.setOn(true));
    await until(tester, () => find.byKey(const ValueKey('host-use')).evaluate().isNotEmpty, 'the way to use it was never offered (${host.viaLink.kind})');
    await tap(tester, find.byKey(const ValueKey('host-use')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final words = textOf(tester, const ValueKey('host-words'));
    expect(words, contains(movingWords(Net.defaultHub)));
    expect(words, contains(moveHereWords('127.0.0.1')));
    await tap(tester, find.text('Use it'));
    await until(tester, () => Net.instance.hubUrl == host.ownUrl, 'this app never moved onto it');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.choice('net_hub', ''), host.ownUrl);
    expect(textOf(tester, const ValueKey('relay-in-use')), 'The relay on this device');
    expect(find.byKey(const ValueKey('host-in-use')), findsOneWidget);
    // (The toast that said so goes first: it is over the sheet's foot.)
    await tester.pump(const Duration(seconds: 6));
    // Switched off: it says this app goes back first, and what its folder keeps; then it does.
    await tap(tester, find.descendant(of: find.byKey(const ValueKey('host-on')), matching: find.byType(GlacierSwitch)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final off = textOf(tester, const ValueKey('host-words'));
    expect(off, contains('This app goes back to Uplink\'s relay (gogho.st) first.'));
    expect(off, contains(keptWords));
    await tap(tester, find.text('Stop hosting'));
    await until(tester, () => host.state == HostState.off && Net.instance.hubUrl == Net.defaultHub, 'it never stopped, or this app never went back');
    expect(state.choice(RelayHost.onKey, 'unset'), '');
    await done(tester);
  });

  testWidgets('a pass phrase set here is asked of everyone; and the relay picker asks for a hosted relay\'s, saying who sees what', (tester) async {
    final state = AppState();
    final public = (await tester.runAsync(PublicRelay.start))!;
    await open(tester, state);
    final host = Net.instance.relayHost!;
    await tester.runAsync(() => host.setOn(true));
    await until(tester, () => find.byKey(const ValueKey('host-pass-field')).evaluate().isNotEmpty, 'the pass phrase was never offered');
    await type(tester, find.byKey(const ValueKey('host-pass-field')), 'a long walk to the old mill');
    await tap(tester, find.byKey(const ValueKey('host-pass-set')));
    await until(tester, () => host.state == HostState.up && ((host as RelayHost).hub?.asksPass ?? false) && find.text(passWords).evaluate().isNotEmpty, 'the pass phrase was never set');
    expect(find.text(passWords), findsOneWidget);
    expect(find.byKey(const ValueKey('host-pass-clear')), findsOneWidget);
    // (The toast that said so goes first.)
    await tester.pump(const Duration(seconds: 6));

    // Someone else's relay, hosted from their app, on this network, asking a pass phrase.
    final theirs = makeHost(Kept(), lan: true, via: public.via, viaPlain: true, viaPorts: {public.port}, viaDial: public.viaDial);
    addTearDown(theirs.shutdown);
    await tester.runAsync(() async {
      await theirs.setOn(true);
      await theirs.setPass('their own phrase');
      await waitFor(() => theirs.viaLink.kind == ViaKind.stays, 'their relay was never let stay: ${theirs.viaLink.kind}');
    });
    final url = theirs.lanUrls.single;
    await type(tester, find.byKey(const ValueKey('relay-address')), url);
    await tap(tester, find.byKey(const ValueKey('relay-check-and-use')));
    await until(tester, () => find.byKey(const ValueKey('relay-words')).evaluate().isNotEmpty, '"Use this relay?" was never asked');
    await tester.pump(const Duration(milliseconds: 300));
    expect(textOf(tester, const ValueKey('relay-words')), contains(joinHostedWords));
    expect(find.byKey(const ValueKey('relay-pass')), findsOneWidget, reason: 'it asks for a pass phrase');
    // Without one, nothing changes, and it says why.
    await tap(tester, find.text('Use this relay'));
    await until(tester, () => find.byKey(const ValueKey('relay-problem')).evaluate().isNotEmpty, 'it never said a pass phrase is wanted');
    expect(textOf(tester, const ValueKey('relay-problem')), 'This relay asks for a pass phrase: whoever runs it can give it to you.');
    expect(Net.instance.hubUrl, Net.defaultHub);
    // With the wrong one it moves, the relay refuses it, and the phrase is asked for where the relay in use is shown.
    await tap(tester, find.byKey(const ValueKey('relay-check-and-use')));
    await until(tester, () => find.byKey(const ValueKey('relay-pass')).evaluate().isNotEmpty, '"Use this relay?" was never asked again');
    await tester.pump(const Duration(milliseconds: 300));
    await type(tester, find.byKey(const ValueKey('relay-pass')), 'not their phrase');
    await tap(tester, find.text('Use this relay'));
    await until(tester, () => Net.instance.hubUrl == url && Net.instance.hub?.url == url, 'it never moved');
    await tester.pump(const Duration(seconds: 6));
    await tester.runAsync(() => Net.instance.want('test', true));
    await until(tester, () => Net.instance.hub!.passRefused == 'wrong' && find.byKey(const ValueKey('relay-pass-field')).evaluate().isNotEmpty, 'the wrong phrase was never said to be wrong');
    expect(textOf(tester, const ValueKey('relay-pass-why')), 'The pass phrase given isn\'t this relay\'s.');
    await type(tester, find.byKey(const ValueKey('relay-pass-field')), 'their own phrase');
    await tap(tester, find.byKey(const ValueKey('relay-pass-try')));
    await until(tester, () => Net.instance.hub!.state.value == CarrierState.up, 'it never signed in with the right phrase');
    expect(find.byKey(const ValueKey('relay-pass-field')), findsNothing);
    // On it, what its keeper sees is said for as long as this app is there, and it is nobody's "own relay".
    await until(tester, () => find.byKey(const ValueKey('relay-hosted')).evaluate().isNotEmpty, 'what its keeper sees was never said');
    expect(find.text(joinHostedWords), findsOneWidget);
    expect(textOf(tester, const ValueKey('relay-in-use')), 'A relay in someone\'s app: 127.0.0.1:${Uri.parse(url).port}');
    await tester.runAsync(() => Net.instance.want('test', false));
    await done(tester);
  });

  testWidgets('not offered for this app until its public relay lets it stay, nor ever on a phone; a joiner isn\'t offered one that doesn\'t stay either (the second review, 2026-11-23)', (tester) async {
    final state = AppState();
    await open(tester, state);
    final host = Net.instance.relayHost!;
    // Under a test its public relay is never reached: refused.
    await tester.runAsync(() => host.setOn(true));
    await until(tester, () => find.byKey(const ValueKey('host-use-not')).evaluate().isNotEmpty, 'it never said why it can\'t be used yet');
    expect(find.byKey(const ValueKey('host-use')), findsNothing);
    expect(find.text(hostedNotLinkedWords), findsOneWidget);

    // Someone else's on this network, not let stay: said why, and no way to move there.
    final theirs = makeHost(Kept(), lan: true);
    addTearDown(theirs.shutdown);
    await tester.runAsync(() => theirs.setOn(true));
    await type(tester, find.byKey(const ValueKey('relay-address')), theirs.lanUrls.single);
    await tap(tester, find.byKey(const ValueKey('relay-check-and-use')));
    await until(tester, () => find.byKey(const ValueKey('relay-words')).evaluate().isNotEmpty, '"Use this relay?" was never asked');
    await tester.pump(const Duration(milliseconds: 300));
    final words = textOf(tester, const ValueKey('relay-words'));
    expect(words, contains(hostedNotLinkedWords));
    expect(words, contains(lanSeenWords), reason: 'on a network address, what the network sees is said to the joiner too');
    expect(find.text('Use this relay'), findsNothing);
    Navigator.of(tester.element(find.byKey(const ValueKey('relay-words'))), rootNavigator: true).pop();
    await tester.pump(const Duration(milliseconds: 300));
    await done(tester);
  });

  testWidgets('on a phone, never offered for this app, and said why', (tester) async {
    final state = AppState();
    final public = (await tester.runAsync(PublicRelay.start))!;
    Net.relayHostMaker = () => RelayHost(via: public.via, viaPlain: true, viaPorts: {public.port}, viaDial: public.viaDial, phone: true);
    addTearDown(() => Net.relayHostMaker = makeRelayHost);
    await open(tester, state);
    final host = Net.instance.relayHost!;
    await tester.runAsync(() => host.setOn(true));
    await until(tester, () => host.viaLink.kind == ViaKind.stays && find.byKey(const ValueKey('host-use-not')).evaluate().isNotEmpty, 'it never said why not on a phone');
    expect(find.text(phoneNotHereWords), findsOneWidget, reason: 'linked and let stay, still not on a phone');
    expect(find.byKey(const ValueKey('host-use')), findsNothing);
    await done(tester);
  });
}
