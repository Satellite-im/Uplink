import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_kit.dart' show SettingRow;
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_files.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/ui/market/my_submissions.dart';
import 'package:ghost_messaging/ui/market/submit_screen.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsWhere;
import 'package:ghost_messaging/ui/settings_panes.dart' show settingsSectionsOn;
import 'package:glacier/glacier.dart' show GlacierSwitch;

import 'support/list_harness.dart';
import 'support/market_fakes.dart';

/// Marketplace › Submit a plugin (lib/ui/market/submit_screen.dart; Matt, 2026-11-20: "Add a submission area with a form
/// to accept an icon, description, plugin tags, etc"): what stops it before anything (no identity of this device's own,
/// no username, another server, a blocked account), a plugin pasted filling the form and tried, each of the form's
/// rules, the Marketplace's check, the draft kept across leaving and loading again, what each platform offers for
/// pictures, the screenshots a new version keeps, a plugin in development used as it is, and exactly what is sent and
/// how it is signed. The runtime's checks and the device's packs are the real ones (lib/plugins/pack); the relay is
/// test/support/market_fakes.dart's, in memory.
Finder _key(String k) => find.byKey(ValueKey(k));

const _tall = Size(412, 5200);

void main() {
  late Directory dir;
  InstalledPlugins? installed;
  late FakeRelay relay;
  late MarketState market;
  late MarketApi api;
  late AppState state;
  String? clipboard;
  final copied = <String>[];
  final oldInstalled = InstalledPlugins.instance, oldMarket = MarketState.instance, oldRegistry = PluginRegistry.instance;

  setUp(() {
    ListPhone(const []).install();
    clipboard = null;
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      if (call.method == 'Clipboard.setData') copied.add(((call.arguments as Map)['text'] as String?) ?? '');
      return null;
    });
    dir = Directory.systemTemp.createTempSync('market-submit-');
    PluginRegistry.instance = PluginRegistry(shippedPlugins);
    installed = null;
    relay = FakeRelay();
    api = MarketApi(hubUrl: 'https://relay.test', signer: devSigner, transport: relay.call);
    // It reads InstalledPlugins.instance as it goes: each test puts its own in place.
    market = MarketState(api: () => api, cache: Directory('${dir.path}/market'), appVersion: '0.10.1');
    MarketState.instance = market;
    state = AppState();
    SubmitPluginScreen.debugPlatform = 'android';
  });
  tearDown(() {
    SubmitPluginScreen.debugPlatform = null;
    InstalledPlugins.instance = oldInstalled;
    MarketState.instance = oldMarket;
    PluginRegistry.instance = oldRegistry;
    dir.deleteSync(recursive: true);
  });

  Future<void> named(WidgetTester tester, String? username) async {
    final store = MemoryMeStore();
    if (username != null) store.set('me_username', username);
    await tester.runAsync(() => Me.instance.start(store, ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
  }

  /// This device's packs, read for the app the form draws from: made inside the test, whose zone its work runs in, the
  /// first time the test asks.
  Future<InstalledPlugins> ready() async => installed ??= InstalledPlugins.instance = await installedFor(state, Directory('${dir.path}/plugins'));

  Future<String?> icon(Uint8List bytes) async => base64Encode(bytes);
  Future<Uint8List?> shot(Uint8List bytes) async => bytes;

  Future<void> form(WidgetTester tester, {MarketApi? with_, String? hub, PluginPack? start, String? startVersion, String? startFor, Future<Uint8List?> Function()? pick}) async {
    await ready();
    // A form of its own each time: its state (the api it signs with) is made once.
    await tester.pumpWidget(const SizedBox());
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, SubmitPluginScreen(api: with_ ?? api, market: market, iconOf: icon, shotOf: shot, pickPicture: pick ?? () async => billsIcon, pastePicture: () async => billsIcon, hub: hub, start: start, startVersion: startVersion, startFor: startFor), state, size: _tall);
  }

  Future<void> paste(WidgetTester tester, Uint8List file) async {
    clipboard = utf8.decode(file);
    await tester.tap(_key('market-submit-paste'));
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String key, String words) async {
    await tester.enterText(find.descendant(of: _key(key), matching: find.byType(EditableText)), words);
    await settle(tester);
  }

  Future<void> agree(WidgetTester tester) async {
    await tester.tap(find.descendant(of: _key('market-submit-agree'), matching: find.text('I made this plugin, and it follows the Marketplace guidelines')));
    await settle(tester);
  }

  bool agreed(WidgetTester tester) => tester.widget<GlacierSwitch>(find.descendant(of: _key('market-submit-agree'), matching: find.byType(GlacierSwitch))).checked ?? false;

  bool sendable(WidgetTester tester) {
    final row = tester.widget<SettingRow>(_key('market-submit-send'));
    return row.onPress != null && !row.disabled;
  }

  testWidgets('before anything: no identity, no username, a blocked account, another server', (tester) async {
    await named(tester, 'maya');
    // A computer that follows its phone has no identity of its own.
    await form(tester, with_: MarketApi(hubUrl: 'https://relay.test', transport: relay.call));
    expect(_key('market-submit-who'), findsOneWidget);
    expect(find.textContaining('Submitting needs your Uplink identity on this'), findsOneWidget);
    expect(_key('market-submit-me'), findsOneWidget);
    expect(_key('market-submit-paste'), findsNothing);
    // No username.
    await named(tester, null);
    await form(tester);
    expect(find.text('Claim a username in Settings › Me first: your plugin is listed under it.'), findsOneWidget);
    expect(_key('market-submit-me'), findsOneWidget);
    // Blocked, as route 9 says.
    await named(tester, 'maya');
    relay.store.blocked = true;
    await form(tester);
    expect(_key('market-submit-blocked'), findsOneWidget);
    expect(find.text('This account can\'t submit plugins.'), findsOneWidget);
    relay.store.blocked = false;
    market.mine = null;
    // Another server: the form is there, Send isn't.
    await form(tester, hub: 'wss://relay.example.org/hub');
    expect(find.text('Plugins are reviewed on Uplink\'s own server, and this app uses relay.example.org. Switch back in Settings › Routes to submit.'), findsOneWidget, reason: 'the section has been called Routes since 2026-11-19');
    // The place it names is the one Settings has, where the relay server is changed: on the phone.
    expect([for (final s in settingsSectionsOn(SettingsWhere.phone)) if (s.id == 'network') s.label], ['Routes']);
    await paste(tester, packFile(billsJson()));
    await agree(tester);
    expect(_key('market-submit-loaded'), findsOneWidget);
    expect(sendable(tester), isFalse);
    expect(relay.store.checks, 0, reason: 'nothing is asked of a server it won\'t be sent to');
  });

  testWidgets('a pasted plugin fills the form, is checked with the Marketplace, and can be tried', (tester) async {
    await named(tester, 'Maya');
    await form(tester);
    expect(_key('market-submit-file'), findsOneWidget, reason: 'Android chooses files');
    await paste(tester, packFile(billsJson()));
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.text('mybills · 1.0.0 · 2 tag rules, 1 tab, 1 kind, 1 button')), findsOneWidget);
    expect(find.text('The Marketplace can take it.'), findsOneWidget);
    expect(relay.store.checks, 1);
    final checked = relay.asked.where((r) => r.method == 'POST' && r.url.path == '/market/submissions').single;
    expect((jsonDecode(utf8.decode(checked.body)) as Map).keys.toSet(), {'package', 'check'});
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-name'), matching: find.byType(EditableText))).controller.text, 'Bills');
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-version'), matching: find.byType(EditableText))).controller.text, '1.0.0');
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-support'), matching: find.byType(EditableText))).controller.text, 'https://example.com/plugins/bills');
    for (final l in ['bills', 'money', 'sorting']) {
      expect(find.descendant(of: _key('market-submit-label-$l'), matching: find.text(packLabels[l]!)), findsOneWidget);
    }
    expect(find.text('Organise'), findsOneWidget);
    expect(find.text('As @maya'), findsOneWidget, reason: 'listed under the tidied username');
    // Nothing in the way but the agreement.
    expect(_key('market-submit-problems'), findsNothing);
    expect(sendable(tester), isFalse);
    await agree(tester);
    expect(tester.widget<GlacierSwitch>(find.descendant(of: _key('market-submit-agree'), matching: find.byType(GlacierSwitch))).checked, isTrue);
    expect(sendable(tester), isTrue);
    // Try it, on the samples' bill.
    await type(tester, 'market-submit-try-text', packSamples.first.text);
    await tester.tap(_key('market-submit-try'));
    await settle(tester);
    final result = find.descendant(of: _key('market-submit-try-result'), matching: find.byType(Text));
    final said = [for (final e in result.evaluate()) (e.widget as Text).data ?? ''];
    expect(said, contains('Tags: bill=\$45.20'));
    expect(said, contains('It goes to Bills'));
    expect(said.any((l) => l.contains('Copy the amount')), isTrue);
  });

  testWidgets('Use one in development: a plugin loaded in Settings › Developer fills the form as it is', (tester) async {
    await named(tester, 'maya');
    state.setFlag('dev_mode', true);
    await addDev(await ready(), billsPack(id: 'mybills', name: 'My bills'));
    await form(tester);
    await tester.tap(_key('market-submit-dev'));
    await settle(tester);
    expect(find.text('1.0.0 · mybills'), findsOneWidget, reason: 'each one in development, with its version and id');
    await tester.tap(find.text('My bills'));
    await settle(tester);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.text('mybills · 1.0.0 · 2 tag rules, 1 tab, 1 kind, 1 button')), findsOneWidget);
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-name'), matching: find.byType(EditableText))).controller.text, 'My bills');
    expect(relay.store.checks, 1, reason: 'asked of the Marketplace as any plugin loaded is');
  });

  testWidgets('the form\'s rules: a reserved name, tags, the help link, a version above the one listed and what\'s new for it', (tester) async {
    await named(tester, 'maya');
    // Listed already at 1.0.0, by this developer.
    relay.store.put(packFile(billsJson(), (j) => j['developer'] = 'maya'), status: 'approved');
    await tester.runAsync(market.readMine);
    await form(tester);
    await paste(tester, packFile(billsJson()));
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-version'), matching: find.byType(EditableText))).controller.text, '1.0.1', reason: 'a version above the one listed');
    expect(find.text('Higher than 1.0.0, the version listed.'), findsOneWidget);
    await agree(tester);
    // What's new is needed for a plugin that is listed.
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.text('What\'s new: say what\'s new in this version.')), findsOneWidget);
    expect(sendable(tester), isFalse);
    await type(tester, 'market-submit-whatsnew', 'Receipts are a kind of their own.');
    expect(_key('market-submit-problems'), findsNothing);
    expect(sendable(tester), isTrue);
    await type(tester, 'market-submit-version', '1.0.0');
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.text('Version: higher than 1.0.0, the version listed.')), findsOneWidget);
    await type(tester, 'market-submit-version', '1.1.0');
    // A name that passes for the app's own.
    await type(tester, 'market-submit-name', 'Codes');
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.textContaining('Name: ')), findsOneWidget);
    expect(sendable(tester), isFalse);
    await type(tester, 'market-submit-name', 'Bills, mine');
    // Tags: one to four.
    for (final l in ['bills', 'money', 'sorting']) {
      await tester.tap(_key('market-submit-label-$l'));
      await settle(tester);
    }
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.textContaining('Tags: ')), findsOneWidget);
    for (final l in ['bills', 'money', 'sorting', 'work']) {
      await tester.tap(_key('market-submit-label-$l'));
      await settle(tester);
    }
    await tester.tap(_key('market-submit-label-travel'));
    await settle(tester);
    expect(find.text('Up to 4 tags.'), findsOneWidget);
    // The help link: https or an email address.
    await type(tester, 'market-submit-support', 'http://example.com/help');
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.textContaining('Help link or email: ')), findsOneWidget);
    await type(tester, 'market-submit-support', 'maya@example.com');
    expect(_key('market-submit-problems'), findsNothing);
    expect(sendable(tester), isTrue);
  });

  testWidgets('the Marketplace\'s refusal shows under The plugin before anything else is filled in', (tester) async {
    await named(tester, 'maya');
    relay.store.checkRefusal = (status: 409, body: {'ok': false, 'error': 'id_taken', 'message': 'Another developer has a plugin with that id. Give yours another id in its file.'});
    await form(tester);
    await paste(tester, packFile(billsJson()));
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.text('Another developer has a plugin with that id. Give yours another id in its file.')), findsOneWidget);
    await agree(tester);
    expect(sendable(tester), isFalse);
    // A version changed is asked again.
    relay.store.checkRefusal = null;
    await type(tester, 'market-submit-version', '1.0.1');
    expect(relay.store.checks, 2);
    expect(find.text('The Marketplace can take it.'), findsOneWidget);
    expect(sendable(tester), isTrue);
  });

  testWidgets('a Marketplace too busy or broken to check holds nothing back; whatever it said, it can be asked again', (tester) async {
    // "Too much at once. Try again in a minute." was kept as the Marketplace's refusal: Send stayed off, and nothing on
    // the form asked again (review, 2026-11-20).
    await named(tester, 'maya');
    for (final (status, error, words) in [(503, 'busy', 'Too much at once. Try again in a minute.'), (500, 'broken', 'Something went wrong here. Try again later.'), (502, 'bad_gateway', 'Bad gateway')]) {
      market.submitting = null;
      relay.store.checkRefusal = (status: status, body: {'ok': false, 'error': error, 'message': words});
      await form(tester);
      await paste(tester, packFile(billsJson()));
      if (!agreed(tester)) await agree(tester);
      expect(find.text(words), findsNothing, reason: '$error: not the plugin\'s problem');
      expect(find.text('Couldn\'t ask the Marketplace whether it can take it just now. It\'s asked again when you send it.'), findsOneWidget, reason: error);
      expect(sendable(tester), isTrue, reason: '$error: Send is checked in full anyway');
      relay.store.checkRefusal = null;
      final asked = relay.store.checks;
      await tester.tap(_key('market-submit-check-again'));
      await settle(tester);
      expect(relay.store.checks, asked + 1);
      expect(find.text('The Marketplace can take it.'), findsOneWidget, reason: error);
      expect(_key('market-submit-check-again'), findsNothing);
    }
    // rate_limited may be the day's submissions, which the check says: it holds Send back, and can be asked again.
    market.submitting = null;
    relay.store.checkRefusal = (status: 429, body: {'ok': false, 'error': 'rate_limited', 'message': 'That\'s a lot at once. Try again later.'});
    await form(tester);
    await paste(tester, packFile(billsJson()));
    if (!agreed(tester)) await agree(tester);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.text('That\'s a lot at once. Try again later.')), findsOneWidget);
    expect(sendable(tester), isFalse);
    relay.store.checkRefusal = null;
    await tester.tap(_key('market-submit-check-again'));
    await settle(tester);
    expect(find.text('The Marketplace can take it.'), findsOneWidget);
    expect(sendable(tester), isTrue);
  });

  testWidgets('checks are asked one at a time, the newest only: two at once, the Marketplace refused the second for the first', (tester) async {
    // "1.0.1" then "1.0.10" in Version sent two checks at once; for a large plugin the relay answers the second
    // rate_limited (one large body at a time from one key), and that was the answer kept (review, 2026-11-20).
    await named(tester, 'maya');
    var inFlight = 0, mostAtOnce = 0;
    Completer<void>? gate = Completer<void>();
    Future<({int status, Map<String, String> headers, Uint8List body})> transport(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) async {
      final check = method == 'POST' && url.path.endsWith('/market/submissions') && (jsonDecode(utf8.decode(body)) as Map)['check'] == true;
      if (check) {
        inFlight++;
        if (inFlight > mostAtOnce) mostAtOnce = inFlight;
        final held = gate;
        if (held != null) await held.future;
        inFlight--;
      }
      return relay.call(method, url, headers, body, most: most);
    }

    await form(tester, with_: MarketApi(hubUrl: 'https://relay.test', signer: devSigner, transport: transport));
    await paste(tester, packFile(billsJson()));
    await type(tester, 'market-submit-version', '1.0.1');
    await type(tester, 'market-submit-version', '1.0.10');
    expect(mostAtOnce, 1);
    gate.complete();
    gate = null;
    await settle(tester);
    expect(mostAtOnce, 1, reason: 'never two at once');
    expect(relay.store.checks, 2, reason: 'the first, which was under way, then the newest; the one between them was never sent');
    expect(find.text('The Marketplace can take it.'), findsOneWidget);
  });

  testWidgets('"sent already" is asked again once the plugin changes, so the change asked for can be sent', (tester) async {
    // Where changes were asked for the form starts as the copy sent, which the Marketplace calls sent already; the
    // check was asked again only for a new version, so Send stayed off however the plugin was changed (review,
    // 2026-11-20).
    await named(tester, 'maya');
    relay.store.checkRefusal = (status: 409, body: {'ok': false, 'error': 'duplicate', 'message': 'That exact plugin was sent already.'});
    await form(tester);
    await paste(tester, packFile(billsJson()));
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.text('That exact plugin was sent already.')), findsOneWidget);
    await agree(tester);
    expect(sendable(tester), isFalse);
    // The change asked for, made: the same version, other bytes.
    relay.store.checkRefusal = null;
    await type(tester, 'market-submit-description', 'Bills in a tab, the amount on the row. It never reads your contacts\' texts.');
    expect(relay.store.checks, 2);
    expect(find.text('That exact plugin was sent already.'), findsNothing);
    expect(find.text('The Marketplace can take it.'), findsOneWidget);
    expect(sendable(tester), isTrue);
    // Typed on, nothing more is asked: the answer holds until the bytes or the version change something it said.
    await type(tester, 'market-submit-description', 'Bills in a tab, the amount on the row.');
    expect(relay.store.checks, 2);
  });

  testWidgets('a plugin with no icon: the form says so, and its icon, category and colour are what is sent', (tester) async {
    await named(tester, 'maya');
    final picture = brokenPng();
    await form(tester, pick: () async => picture);
    // The docs' smallest plugin has no icon: one is needed to submit.
    await paste(tester, packFile(billsJson(), (j) => j.remove('icon')));
    expect(find.text('Icon: is needed.'), findsWidgets, reason: 'under How it\'s listed, and among what stops Send');
    await agree(tester);
    expect(sendable(tester), isFalse);
    await tester.tap(find.descendant(of: _key('market-submit-icon'), matching: find.text('Choose a picture')));
    await settle(tester);
    expect(find.text('Icon: is needed.'), findsNothing);
    await tester.tap(_key('market-submit-shelf'));
    await settle(tester);
    await tester.tap(find.text('Tools').last);
    await settle(tester);
    await tester.tap(_key('market-submit-hue'));
    await settle(tester);
    await tester.tap(find.text('Mint').last);
    await settle(tester);
    expect(sendable(tester), isTrue);
    await tester.tap(_key('market-submit-send'));
    await settle(tester);
    final sent = relay.asked.where((r) => r.method == 'POST' && r.url.path == '/market/submissions' && !(jsonDecode(utf8.decode(r.body)) as Map).containsKey('check')).single;
    final pack = (jsonDecode(utf8.decode(base64Decode((jsonDecode(utf8.decode(sent.body)) as Map)['package'] as String))) as Map).cast<String, Object?>();
    expect([pack['icon'], pack['shelf'], pack['hue']], [base64Encode(picture), 'tools', 'mint'], reason: 'the form\'s, not the file\'s');
  });

  testWidgets('the real picture code: an icon and a screenshot made again as plain PNGs, whatever the encoder writes', (tester) async {
    // Every form test passes stand-ins for these (D.8), so the code that makes a chosen picture an icon or a screenshot,
    // and cleanPng inside it that keeps the engine's own chunks out, ran in no test (review, 2026-11-20).
    List<String> chunks(Uint8List png) => pngInfo(png)!.chunks;
    Uint8List chunk(String type, List<int> data) => Uint8List.fromList([...(ByteData(4)..setUint32(0, data.length)).buffer.asUint8List(), ...ascii.encode(type), ...data, 0, 0, 0, 0]);
    await tester.runAsync(() async {
      Future<Uint8List> encoded(int w, int h, {bool noisy = false}) async {
        final pixels = Uint8List(w * h * 4);
        var seed = 7;
        for (var i = 0; i < pixels.length; i++) {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          pixels[i] = noisy ? seed >> 16 : (i % 4 == 3 ? 255 : (i % 4) * 90);
        }
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, done.complete);
        final image = await done.future;
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        return data!.buffer.asUint8List();
      }

      final icon = await pluginIconOf(await encoded(1200, 800));
      expect(icon, isNotNull);
      final png = base64Decode(icon!);
      expect(pngProblem(png, min: PackLimits.iconMin, max: PackLimits.iconMax, square: true), isNull);
      expect([pngInfo(png)!.width, pngInfo(png)!.height], [256, 256], reason: 'cut square, at its largest');
      expect(chunks(png).toSet().difference({'IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'}), isEmpty, reason: 'nothing but its pixels');
      final noisy = base64Decode((await pluginIconOf(await encoded(512, 512, noisy: true)))!);
      expect(pngInfo(noisy)!.width, lessThan(256), reason: 'a picture that doesn\'t compress steps down until it fits');
      expect(noisy.length, lessThanOrEqualTo(PackLimits.iconBytes));
      final big = await encoded(3000, 3000);
      final shot = await shrinkScreenshot(big);
      expect(shot, isNotNull);
      expect([pngInfo(shot!)!.width, pngInfo(shot)!.height], [2400, 2400]);
      expect(shot.length, lessThanOrEqualTo(PackLimits.shotBytes));
      expect(pngProblem(shot, min: PackLimits.shotMin, max: PackLimits.shotMax), isNull);
      expect(shot, isNot(big), reason: 'always made again, never the bytes passed through');
      // cleanPng keeps the five chunks a picture needs, whatever else an encoder or a camera wrote.
      final plain = await encoded(80, 80);
      final at = 8 + 25; // after the signature and IHDR
      final extra = Uint8List.fromList([...plain.sublist(0, at), ...chunk('sBIT', [8, 8, 8, 8]), ...chunk('tEXt', ascii.encode('Software\u0000camera')), ...chunk('iCCP', [0x61, 0, 0, 1, 2]), ...plain.sublist(at)]);
      expect(pngProblem(extra, min: 64, max: 2400), isNotNull);
      final cleaned = cleanPng(extra);
      expect(chunks(cleaned).where((c) => c != 'IDAT').toList(), ['IHDR', 'IEND']);
      expect(pngProblem(cleaned, min: 64, max: 2400), isNull);
    });
  });

  testWidgets('the draft: kept leaving and coming back; a corrected copy keeps what was changed; another plugin asks', (tester) async {
    await named(tester, 'maya');
    await form(tester);
    await paste(tester, packFile(billsJson()));
    await type(tester, 'market-submit-name', 'Bills, mine');
    await type(tester, 'market-submit-notes', 'Try it on s01.');
    await agree(tester);
    // Away (Settings › Me, a conversation) and back.
    await tester.pumpWidget(const SizedBox());
    await form(tester);
    expect(_key('market-submit-loaded'), findsOneWidget, reason: 'the plugin it held');
    String text(String key) => tester.widget<EditableText>(find.descendant(of: _key(key), matching: find.byType(EditableText))).controller.text;
    expect(text('market-submit-name'), 'Bills, mine');
    expect(text('market-submit-notes'), 'Try it on s01.');
    expect(tester.widget<GlacierSwitch>(find.descendant(of: _key('market-submit-agree'), matching: find.byType(GlacierSwitch))).checked, isTrue);
    // A corrected copy: what was changed here stays, the rest is the file's.
    await paste(tester, packFile(billsJson(), (j) {
      j['tagline'] = 'Bills in a tab of their own';
      j['name'] = 'Bills again';
    }));
    expect(text('market-submit-name'), 'Bills, mine');
    expect(text('market-submit-tagline'), 'Bills in a tab of their own');
    // Another plugin asks first; kept, nothing changes.
    await paste(tester, packFile(billsJson(id: 'otherbills')));
    expect(find.text('Start again with otherbills'), findsOneWidget);
    await tester.tap(find.text('Keep mybills'));
    await settle(tester);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.textContaining('mybills · 1.0.0')), findsOneWidget);
    await paste(tester, packFile(billsJson(id: 'otherbills')));
    await tester.tap(find.text('Start again with otherbills'));
    await settle(tester);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.textContaining('otherbills · 1.0.0')), findsOneWidget);
    expect(text('market-submit-name'), 'Bills');
    // And mybills' draft is still there for it.
    expect(market.draftOf('mybills')?.name, 'Bills, mine');
  });

  testWidgets('the draft on disk: the plugin switched away from, and the form as the app goes to the background', (tester) async {
    // The sheet says what was filled in for the first plugin is kept, and it was, in memory alone: the disk had it as
    // it was loaded, so after a restart what was typed for it was gone (review, 2026-11-20).
    await named(tester, 'maya');
    await form(tester);
    await paste(tester, packFile(billsJson()));
    await type(tester, 'market-submit-description', 'Bills in a tab, typed for mybills.');
    await type(tester, 'market-submit-notes', 'Notes for mybills.');
    await paste(tester, packFile(billsJson(id: 'otherbills')));
    await tester.tap(find.text('Start again with otherbills'));
    await settle(tester);
    // The writes asked for so far, waited for as they go on (each a real file's, so the real event loop and the test's
    // own microtasks are let run in turn, however busy the machine), never for a fixed time; then a Marketplace of a
    // new start reads the drafts the disk has.
    Future<MarketState> restarted() async {
      var written = false;
      unawaited(market.draftsWritten.then((_) => written = true));
      final watch = Stopwatch()..start();
      while (!written && watch.elapsed < const Duration(seconds: 60)) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(written, isTrue);
      final again = MarketState(api: () => api, cache: Directory('${dir.path}/market'), appVersion: '0.10.1');
      await tester.runAsync(again.loadDrafts);
      return again;
    }

    var again = await restarted();
    expect([again.draftOf('mybills')?.description, again.draftOf('mybills')?.notes], ['Bills in a tab, typed for mybills.', 'Notes for mybills.']);
    // Typed for otherbills, then the app goes to the background (Choose a picture's picker, a call): written then.
    await type(tester, 'market-submit-description', 'Typed for otherbills.');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    again = await restarted();
    expect(again.draftOf('otherbills')?.description, 'Typed for otherbills.');
  });

  testWidgets('pictures: a computer pastes them, Windows has no picture panel, a phone chooses', (tester) async {
    await named(tester, 'maya');
    for (final (platform, choose, paste_) in [('macos', true, true), ('windows', false, true), ('android', true, false)]) {
      SubmitPluginScreen.debugPlatform = platform;
      market.submitting = null;
      await form(tester);
      await paste(tester, packFile(billsJson()));
      expect(find.descendant(of: _key('market-submit-icon'), matching: find.text('Choose a picture')), choose ? findsOneWidget : findsNothing, reason: platform);
      expect(_key('market-submit-shot-add'), choose ? findsOneWidget : findsNothing, reason: platform);
      expect(_key('market-submit-icon-paste'), paste_ ? findsOneWidget : findsNothing, reason: platform);
      expect(_key('market-submit-shot-paste'), paste_ ? findsOneWidget : findsNothing, reason: platform);
      expect(_key('market-submit-file'), platform == 'windows' ? findsNothing : findsOneWidget, reason: platform);
    }
  });

  testWidgets('what is sent: the package canonical with the form\'s fields, the screenshots\' hashes, signed over C.2\'s words', (tester) async {
    await named(tester, 'Maya');
    await form(tester);
    await paste(tester, packFile(billsJson()));
    await type(tester, 'market-submit-name', 'Bills, mine');
    await type(tester, 'market-submit-description', 'Bills in a tab, the amount on the row.');
    await tester.tap(_key('market-submit-label-work'));
    await settle(tester);
    await tester.tap(_key('market-submit-shot-add'));
    await settle(tester);
    expect(_key('market-submit-shot-0'), findsOneWidget);
    await tester.tap(_key('market-submit-list'));
    await settle(tester);
    await type(tester, 'market-submit-notes', 'Made up texts only.');
    await agree(tester);
    await tester.tap(_key('market-submit-send'));
    await settle(tester);
    final sent = relay.asked.where((r) => r.method == 'POST' && r.url.path == '/market/submissions' && !(jsonDecode(utf8.decode(r.body)) as Map).containsKey('check')).single;
    final body = (jsonDecode(utf8.decode(sent.body)) as Map).cast<String, Object?>();
    final package = base64Decode(body['package'] as String);
    expect(canonicalBytes(jsonDecode(utf8.decode(package))), package, reason: 'canonical');
    final pack = (jsonDecode(utf8.decode(package)) as Map).cast<String, Object?>();
    expect(pack['name'], 'Bills, mine');
    expect(pack['description'], 'Bills in a tab, the amount on the row.');
    expect(pack['labels'], ['bills', 'money', 'sorting', 'work']);
    expect(pack['developer'], 'maya', reason: 'the username tidied');
    expect(pack['shots'], [sha256Hex(billsIcon)]);
    expect(pack.containsKey('whatsNew'), isFalse, reason: 'left out when empty');
    expect(body['shots'], [{'mime': 'image/png', 'data': base64Encode(billsIcon)}]);
    expect(body['notes'], 'Made up texts only.');
    expect(body['list'], 'later');
    expect(body['agree'], true);
    expect(parsePack(package, appVersion: '0.10.1', submission: true).errors, isEmpty);
    // Signed over the method, the path as asked, the time and the body's hash, the body's hash and length said too.
    final h = sent.headers;
    expect(h['x-ghost-body-sha256'], sha256Hex(sent.body));
    expect(h['x-ghost-body-length'], '${sent.body.length}');
    expect(base64Decode(h['x-ghost-key']!), devSigner.publicKey);
    final words = 'ghost-market v1\nPOST\n/market/submissions\n${h['x-ghost-time']}\n${h['x-ghost-body-sha256']}';
    expect(NetCrypto.verify(base64Decode(h['x-ghost-key']!), utf8.encode(words), base64Decode(h['x-ghost-sig']!)), isTrue);
    // Done: My submissions, the new one marked; the draft gone.
    expect(find.text('Sent for review'), findsOneWidget);
    final sid = relay.store.submissions.keys.single;
    expect(find.byWidgetPredicate((w) => w is MySubmissionsScreen && w.highlight == sid), findsOneWidget);
    expect(_key('market-mine-marked'), findsOneWidget);
    expect(market.draftOf('mybills'), isNull);
    expect(market.submitting, isNull);
  });

  testWidgets('notes the Marketplace would refuse are said under their name and hold Send back; line ends are made one kind', (tester) async {
    // The relay holds the notes to a plugin's own rule for words and answered an emoji made of several with
    // "Something in that isn't right." alone, naming no field; a description pasted from Windows held \r, which the
    // format refuses unseen (review, 2026-11-20).
    await named(tester, 'maya');
    await form(tester);
    await paste(tester, packFile(billsJson()));
    await agree(tester);
    expect(sendable(tester), isTrue);
    await type(tester, 'market-submit-notes', 'Tested on my Pixel 👩\u200D💻');
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.textContaining('Notes: Emoji made of several')), findsOneWidget);
    expect(sendable(tester), isFalse);
    await type(tester, 'market-submit-notes', 'Tested on my Pixel.\r\nThanks!');
    expect(_key('market-submit-problems'), findsNothing);
    await type(tester, 'market-submit-description', 'Bills in a tab.\r\nThe amount on the row.');
    expect(_key('market-submit-problems'), findsNothing, reason: 'its line ends are made one kind before it is checked');
    expect(sendable(tester), isTrue);
    await tester.tap(_key('market-submit-send'));
    await settle(tester);
    final sent = relay.asked.where((r) => r.method == 'POST' && r.url.path == '/market/submissions' && !(jsonDecode(utf8.decode(r.body)) as Map).containsKey('check')).single;
    final body = (jsonDecode(utf8.decode(sent.body)) as Map).cast<String, Object?>();
    expect(body['notes'], 'Tested on my Pixel.\nThanks!');
    expect((jsonDecode(utf8.decode(base64Decode(body['package'] as String))) as Map)['description'], 'Bills in a tab.\nThe amount on the row.');
  });

  testWidgets('a plugin its developer took off the Marketplace: the form says a new version stays off, and its switch can\'t say otherwise', (tester) async {
    // The relay approves its next version unlisted whatever its list says (C.6): the switch promised "It goes in the
    // Marketplace as soon as it's approved" (review, 2026-11-20).
    await named(tester, 'maya');
    relay.store.put(packFile(billsJson()), status: 'approved');
    relay.store.plugins['mybills']!
      ..['listing'] = 'unlisted'
      ..['by'] = 'owner';
    await form(tester);
    await paste(tester, packFile(billsJson(), (j) => j['version'] = '1.1.0'));
    expect(find.descendant(of: _key('market-submit-listing'), matching: find.text('You took it off the Marketplace: approved, it stays off until you list it again in My submissions.')), findsOneWidget);
    final list = tester.widget<GlacierSwitch>(_key('market-submit-list'));
    expect([list.checked, list.disabled], [false, true]);
  });

  testWidgets('"Submit it" on a plugin in development whose copy doesn\'t load says so, never starting with another plugin', (tester) async {
    // The form fell back to the plugin it held last, and the developer who pressed Submit on Bills got Parcels (review,
    // 2026-11-20).
    await named(tester, 'maya');
    state.setFlag('dev_mode', true);
    final here = await ready();
    await addDev(here, billsPack(id: 'myparcels', name: 'Parcels mine'));
    await form(tester, start: here.devOf('myparcels')!.pack);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.textContaining('myparcels')), findsOneWidget);
    expect((await here.loadDev(packFile(billsJson(), (j) => j['hue'] = 'chartreuse'), const DevSource('paste'))).code, 'invalid');
    await form(tester, start: here.devOf('mybills')?.pack, startFor: 'mybills');
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.text('It couldn\'t be loaded:')), findsOneWidget);
    expect(find.descendant(of: _key('market-submit-loaded'), matching: find.textContaining('bad_hue at hue')), findsOneWidget);
    expect(find.textContaining('myparcels'), findsNothing, reason: 'not the plugin the form held before');
  });

  testWidgets('a picture of the samples: the rows of the sample texts it sorts, drawn off the screen, a plain PNG', (tester) async {
    await named(tester, 'maya');
    await form(tester);
    await paste(tester, packFile(billsJson()));
    await tester.tap(_key('market-submit-shot-samples'));
    // The rows are drawn and painted on a frame, then read back as a picture on the engine's own time: a turn of the
    // real event loop and a frame at a time, never a fixed wait, with a deadline far past what a busy machine needs.
    final watch = Stopwatch()..start();
    while (_key('market-submit-shot-0').evaluate().isEmpty && watch.elapsed < const Duration(seconds: 60)) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(_key('market-submit-shot-0'), findsOneWidget);
    final image = tester.widget<Image>(find.descendant(of: _key('market-submit-shot-0'), matching: find.byType(Image)));
    final bytes = ((image.image as ResizeImage).imageProvider as MemoryImage).bytes;
    expect(pngProblem(bytes, min: PackLimits.shotMin, max: PackLimits.shotMax), isNull, reason: 'a screenshot the Marketplace takes');
    expect(cleanPng(bytes), bytes, reason: 'nothing but its pixels');
    expect(pngInfo(bytes)!.width, 800, reason: '400 points across at twice the pixels');
  });

  testWidgets('an invalid package as the Marketplace says lists its issues', (tester) async {
    await named(tester, 'maya');
    relay.store.submitRefusal = (status: 400, body: {'ok': false, 'error': 'invalid_package', 'message': 'The plugin has problems.', 'issues': [{'code': 'bad_icon', 'path': 'icon', 'message': 'icon: has a chunk the store doesn\'t take.'}]});
    await form(tester);
    await paste(tester, packFile(billsJson()));
    await agree(tester);
    await tester.tap(_key('market-submit-send'));
    await settle(tester);
    expect(find.descendant(of: _key('market-submit-problems'), matching: find.text('Icon: has a chunk the store doesn\'t take.')), findsOneWidget);
    expect(find.text('The plugin has problems.'), findsWidgets);
  });

  testWidgets('a new version keeps the screenshots it had, fetched as thumbnails', (tester) async {
    await named(tester, 'maya');
    final shotA = billsIcon, shotB = Uint8List.fromList([...billsIcon, 0]);
    final file = packFile(billsJson(), (j) {
      j['developer'] = 'maya';
      j['shots'] = [sha256Hex(shotA), sha256Hex(shotB)];
    });
    final sid = relay.store.put(file, status: 'approved', shots: [shotA, shotB]);
    await tester.runAsync(market.readMine);
    final pack = parsePack(file, appVersion: '0.10.1').pack!;
    final from = market.mine!.submissions.single;
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, SubmitPluginScreen(api: api, market: market, iconOf: icon, shotOf: shot, start: pack, startVersion: resubmitVersion(from), from: from), state, size: _tall);
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-version'), matching: find.byType(EditableText))).controller.text, '1.0.1');
    expect(_key('market-submit-shot-0'), findsOneWidget);
    expect(_key('market-submit-shot-1'), findsOneWidget);
    expect(find.text('Kept'), findsNWidgets(2));
    expect(relay.paths.where((p) => p.contains('/market/submissions/$sid/shots/')), hasLength(2), reason: 'their thumbnails, by route 12');
    await type(tester, 'market-submit-whatsnew', 'Faster.');
    await agree(tester);
    await tester.tap(_key('market-submit-send'));
    await settle(tester);
    final sent = relay.asked.where((r) => r.method == 'POST' && r.url.path == '/market/submissions' && !(jsonDecode(utf8.decode(r.body)) as Map).containsKey('check')).single;
    expect((jsonDecode(utf8.decode(sent.body)) as Map)['shots'], [{'keep': sha256Hex(shotA)}, {'keep': sha256Hex(shotB)}]);
  });
}
