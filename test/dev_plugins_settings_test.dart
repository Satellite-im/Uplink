import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/codes.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/files_space/share_in.dart';
import 'package:ghost_messaging/ui/market/dev_plugins.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:glacier/glacier.dart' show GlacierSwitch;

import 'support/list_harness.dart';
import 'support/market_fakes.dart';

/// Settings › Developer › Plugins in development (lib/ui/market/dev_plugins.dart; Matt, 2026-11-20: "please add a
/// developer setting for users to be able to manually upload plugins for development testing"): there in developer
/// mode and never in an App Store build; pasting a plugin adds its row, and its first switch-on asks first; words that
/// aren't a plugin say what is wrong and add nothing; a pack's own screen reloads, lists what it was refused, tries a
/// text and removes it; the list says while one is on; and a shared .ghostplugin loads. Every pack is loaded, checked,
/// tried and run by the runtime itself (lib/plugins/pack).
Finder _key(String k) => find.byKey(ValueKey(k));

/// A host for a pack's button that does nothing: the gated host refuses before it would ask.
class _Host implements PluginHost {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// An HTTP client whose every GET answers 200 with [serve]'s bytes at that moment: a link a developer's own server
/// would serve, changed between loads.
class _Served implements HttpClient {
  _Served(this.serve);
  final List<int> Function() serve;
  final asked = <Uri>[];

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    asked.add(url);
    return _Request(serve());
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.bytes);
  final List<int> bytes;

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => _Response(bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes);
  final List<int> bytes;

  @override
  int get statusCode => 200;

  @override
  bool get isRedirect => false;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) => Stream<List<int>>.value(bytes).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory dir;
  late InstalledPlugins installed;
  late AppState state;
  late ListPhone phone;
  String? clipboard;
  var made = 0;
  final oldInstalled = InstalledPlugins.instance, oldRegistry = PluginRegistry.instance;

  setUp(() {
    phone = ListPhone(const [])..install();
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      if (call.method == 'Clipboard.setData') phone.copied.add(((call.arguments as Map)['text'] as String?) ?? '');
      return null;
    });
    dir = Directory.systemTemp.createTempSync('dev-plugins-');
    PluginRegistry.instance = PluginRegistry(const [CodesPlugin()]);
    state = AppState()..setFlag('dev_mode', true);
  });
  tearDown(() {
    InstalledPlugins.instance = oldInstalled;
    PluginRegistry.instance = oldRegistry;
    dir.deleteSync(recursive: true);
  });

  /// This device's packs, read for the app the screens draw from: made inside the test, whose zone its work runs in.
  Future<void> ready({bool devAllowed = true, HttpClient Function()? http}) async {
    installed = await installedFor(state, Directory('${dir.path}/plugins-${made++}'), devAllowed: devAllowed, http: http);
    InstalledPlugins.instance = installed;
  }

  Future<void> developer(WidgetTester tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('developer'), state, size: const Size(412, 2400));
  }

  testWidgets('only in developer mode, and never in an App Store build', (tester) async {
    await ready();
    await developer(tester);
    expect(_key('dev-plugins'), findsOneWidget);
    for (final k in ['dev-plugin-paste', 'dev-plugin-link', 'dev-plugin-docs']) {
      expect(_key(k), findsOneWidget, reason: k);
    }
    expect(find.text('Shows Settings › API, Plugins in development below, and the Marketplace\'s In development.'), findsOneWidget);
    state.setFlag('dev_mode', false);
    await developer(tester);
    expect(_key('dev-plugins'), findsNothing, reason: 'Developer itself is hidden');
    state.setFlag('dev_mode', true);
    await ready(devAllowed: false);
    await developer(tester);
    expect(find.text('Developer mode'), findsOneWidget);
    expect(_key('dev-plugins'), findsNothing);
  });

  testWidgets('Paste adds its row with its switch; the first switch-on asks, and agreeing switches it on', (tester) async {
    await ready();
    clipboard = utf8.decode(packBytes(billsPack()));
    await developer(tester);
    await tester.tap(_key('dev-plugin-paste'));
    await settle(tester);
    expect(installed.devOf('bills')!.source.kind, 'paste');
    expect(find.text('Bills loaded. Switch it on to agree to what it can do now.'), findsOneWidget);
    expect(_key('dev-plugin-bills'), findsOneWidget);
    expect(find.descendant(of: _key('dev-plugin-bills'), matching: find.textContaining('1.0.0 · pasted · needs your OK')), findsOneWidget);
    // The toast gone (fake time), so it isn't over the sheet's last choice.
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    final toggle = _key('dev-plugin-switch-bills');
    expect(tester.widget<GlacierSwitch>(toggle).checked, isFalse);
    await tester.tap(toggle);
    await settle(tester);
    expect(_key('market-consent'), findsOneWidget);
    expect(_key('market-consent-dev'), findsOneWidget);
    expect(installed.devOf('bills')!.agreed, isNull, reason: 'nothing switched on before the sheet is answered');
    expect(state.flag('plugin_xbills', fallback: false), isFalse);
    await tester.ensureVisible(find.text('Switch it on'));
    await settle(tester);
    await tester.tap(find.text('Switch it on'));
    await settle(tester);
    expect(installed.devOf('bills')!.agreed, DevPack.consentLines(billsPack()));
    expect(state.flag('plugin_xbills', fallback: false), isTrue);
    expect(tester.widget<GlacierSwitch>(_key('dev-plugin-switch-bills')).checked, isTrue);
    // Agreed to, it switches off and on again without asking.
    await tester.tap(_key('dev-plugin-switch-bills'));
    await settle(tester);
    expect(state.flag('plugin_xbills', fallback: true), isFalse);
    await tester.tap(_key('dev-plugin-switch-bills'));
    await settle(tester);
    expect(_key('market-consent'), findsNothing);
    expect(state.flag('plugin_xbills', fallback: false), isTrue);
  });

  testWidgets('a plugin that loads with a warning is said to be loaded, its consent line and its warning with it', (tester) async {
    // A copy that loads has warnings at most, and every pack with a link button has one (opens_links): the docs' own
    // Parcels was told only "1 problem: see its row", never that it was loaded nor that it waited to be agreed to
    // (review, 2026-11-20).
    await ready();
    clipboard = File('test/fixtures/packs/parcels.ghostplugin').readAsStringSync();
    await developer(tester);
    await tester.tap(_key('dev-plugin-paste'));
    await settle(tester);
    expect(installed.devOf('parcels')!.issues.map((i) => i.code), ['opens_links']);
    expect(find.text('Parcels loaded. Switch it on to agree to what it can do now. One warning: see its row.'), findsOneWidget);
    expect(find.text('1 problem: see its row'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    // Agreed to, then pasted again: a sentence each, and its row counts a warning, not a problem ("Parcels loaded One
    // warning: see its row." over "1 problem" for a file that loads cleanly, review, 2026-11-20).
    await installed.agreeDev('parcels');
    await settle(tester);
    await tester.tap(_key('dev-plugin-paste'));
    await settle(tester);
    expect(find.text('Parcels loaded. One warning: see its row.'), findsOneWidget);
    expect(find.descendant(of: _key('dev-plugin-parcels'), matching: find.text('1.0.0 · pasted · running · 1 warning')), findsOneWidget);
    expect(devPackState(installed.devOf('parcels')!, PluginRegistry.instance, AppStore(state)), 'running · 1 warning');
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    // A copy that doesn't load, kept with its row, is still its problems.
    clipboard = utf8.decode(packFile(billsJson(id: 'mybills'), (j) => j['hue'] = 'chartreuse'));
    await tester.tap(_key('dev-plugin-paste'));
    await settle(tester);
    expect(find.text('1 problem: see its row'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
  });

  testWidgets('words that aren\'t a plugin say what is wrong, add no row, and copy', (tester) async {
    await ready();
    clipboard = 'not a plugin at all';
    await developer(tester);
    await tester.tap(_key('dev-plugin-paste'));
    await settle(tester);
    expect(_key('dev-plugin-problems'), findsOneWidget);
    expect(find.descendant(of: _key('dev-plugin-problems'), matching: find.textContaining('bad_json')), findsOneWidget);
    expect(installed.dev, isEmpty);
    expect(Directory('${installed.root.path}/dev').existsSync(), isFalse, reason: 'nothing written');
    await tester.ensureVisible(find.text('Copy the problems'));
    await settle(tester);
    await tester.tap(find.text('Copy the problems'));
    await settle(tester);
    expect(phone.copied.last, contains('bad_json'));
    expect(_key('dev-plugin-bills'), findsNothing);
  });

  testWidgets('its own screen: where it came from, what it was refused, Try it on s01 and the samples, Reload, Remove', (tester) async {
    // Its own server's copy: one that says where its page is in its description (a warning), then a newer one.
    var copy = billsPack(description: 'Bills in a tab of their own. More at https://example.com/plugins/bills.');
    final link = _Served(() => packBytes(copy));
    await ready(http: () => link);
    final loaded = await installed.loadDevFromLink(Uri.parse('https://example.com/bills.ghostplugin'));
    expect(loaded.ok, isTrue, reason: loaded.message);
    await installed.agreeDev('bills');
    // A move into another conversation, which no pack's button may make: refused by the gated host, and kept.
    GatedHost(_Host(), plugin: installed.devOf('bills')!.plugin!, thread: 1).move(2, null);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const DevPluginScreen(packId: 'bills'), state, size: const Size(412, 3000));
    expect(_key('dev-plugin-screen-bills'), findsOneWidget);
    expect(find.textContaining('from a link'), findsWidgets);
    expect(find.descendant(of: _key('dev-plugin-issues-bills'), matching: find.textContaining('warning description_link at description')), findsOneWidget);
    expect(find.descendant(of: _key('dev-plugin-errors-bills'), matching: find.textContaining('move refused for xbills')), findsOneWidget);
    // Try it, with the bill of the samples.
    await tester.enterText(find.descendant(of: _key('dev-plugin-try-text-bills'), matching: find.byType(EditableText)), packSamples.first.text);
    await tester.tap(_key('dev-plugin-try-bills'));
    await settle(tester);
    final result = _key('dev-plugin-try-result-bills');
    expect(find.descendant(of: result, matching: find.text(r'Tags: bill=$45.20')), findsOneWidget);
    expect(find.descendant(of: result, matching: find.text('It goes to Bills')), findsOneWidget);
    expect(find.descendant(of: result, matching: find.text('On its row: Copy the amount')), findsOneWidget);
    expect(find.descendant(of: result, matching: find.text(r'Its row: $45.20 · A bill')), findsOneWidget);
    expect(find.descendant(of: result, matching: find.text('In a message\'s menu: Copy the amount')), findsOneWidget);
    // Every sample, a line each.
    await tester.ensureVisible(find.text('Try the samples'));
    await settle(tester);
    await tester.tap(find.text('Try the samples'));
    await settle(tester);
    final samples = _key('dev-plugin-samples-bills');
    expect(find.descendant(of: samples, matching: find.textContaining(r's01 · Bills · bill=$45.20')), findsOneWidget);
    expect(find.descendant(of: samples, matching: find.textContaining('s04 · Receipts · paid=€12,50')), findsOneWidget);
    expect(find.descendant(of: samples, matching: find.textContaining('s12 · nothing')), findsOneWidget);
    // Its own settings, now it is on.
    expect(find.text('More words for bills'), findsOneWidget);
    // Reload fetches it again: the newer copy.
    copy = billsPack(version: '1.0.1');
    await tester.ensureVisible(_key('dev-plugin-reload-bills'));
    await settle(tester);
    await tester.tap(_key('dev-plugin-reload-bills'));
    await settle(tester);
    expect(link.asked, hasLength(2));
    expect(installed.devOf('bills')!.pack!.version, '1.0.1');
    expect(find.descendant(of: _key('dev-plugin-issues-bills'), matching: find.text('None: it checks out.')), findsOneWidget);
    expect(state.flag('plugin_xbills', fallback: false), isTrue, reason: 'it can do nothing new, so it stays on');
    // A copy that can do more (a page its button opens) is switched off until it is agreed to again.
    copy = billsPack(version: '1.0.2', link: 'https://example.com/plugins/bills/pay');
    await tester.tap(_key('dev-plugin-reload-bills'));
    await settle(tester);
    expect(installed.devOf('bills')!.needsConsent, isTrue);
    expect(state.flag('plugin_xbills', fallback: true), isFalse);
    expect(find.textContaining('needs your OK'), findsWidgets);
    // Remove takes it away.
    await tester.ensureVisible(_key('dev-plugin-remove-bills'));
    await settle(tester);
    await tester.tap(_key('dev-plugin-remove-bills'));
    await settle(tester);
    expect(installed.dev, isEmpty);
    expect(PluginRegistry.instance.plugins.any((p) => p.id == 'xbills'), isFalse);
  });

  testWidgets('a pasted copy can\'t be reloaded; one from a link can', (tester) async {
    await ready();
    await addDev(installed, billsPack());
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const DevPluginScreen(packId: 'bills'), state, size: const Size(412, 3000));
    expect(_key('dev-plugin-reload-bills'), findsNothing);
    expect(_key('dev-plugin-remove-bills'), findsOneWidget);
  });

  testWidgets('the list says while a plugin in development is on', (tester) async {
    await ready();
    await addDev(installed, billsPack());
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ConversationsScreen(), state);
    expect(_key('dev-plugins-on'), findsNothing, reason: 'loaded, not on');
    await installed.agreeDev('bills');
    await settle(tester);
    expect(_key('dev-plugins-on'), findsOneWidget);
    expect(find.text('A plugin in development is on · Settings › Developer'), findsOneWidget);
    // Developer mode off takes it out of the list's registry, and the line with it.
    state.setFlag('dev_mode', false);
    await settle(tester);
    expect(_key('dev-plugins-on'), findsNothing);
  });

  testWidgets('a .ghostplugin shared in loads in development, the rest are left for a Files space', (tester) async {
    await ready();
    final sheet = await loadSheet(tester);
    late BuildContext context;
    await pumpScreen(tester, sheet, Builder(builder: (c) {
      context = c;
      return const SizedBox.expand();
    }), state);
    final files = [const IncomingFile(source: 'content://share/bills.ghostplugin', name: 'bills.ghostplugin'), const IncomingFile(source: 'content://share/photo.jpg', name: 'photo.jpg')];
    final left = await FilesShareIn.takePlugins(context, files, read: (source) async => packBytes(billsPack()));
    await settle(tester);
    expect([for (final f in left) f.name], ['photo.jpg']);
    expect(installed.devOf('bills')!.source.kind, 'file');
    expect(installed.dev.single.source.name, 'bills.ghostplugin');
    expect(find.text('Bills loaded. Switch it on to agree to what it can do now.'), findsOneWidget);
    // With developer mode off it is a file like any other.
    state.setFlag('dev_mode', false);
    final again = await FilesShareIn.takePlugins(context, files, read: (source) async => packBytes(billsPack()));
    expect(again, hasLength(2));
  });
}
