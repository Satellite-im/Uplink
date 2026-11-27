import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/me/me.dart' show MemoryMeStore;
import 'package:ghost_messaging/desktop/platform.dart' show computerWord, desktopName;
import 'package:ghost_messaging/emoji_sets.dart';
import 'package:ghost_messaging/files/file_kinds.dart' show FileKind;
import 'package:ghost_messaging/files/files_model.dart' show SpaceFile;
import 'package:ghost_messaging/keys.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/platform_info.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/standalone/standalone.dart';
import 'package:ghost_messaging/standalone/store.dart' show StoreLost;
import 'package:ghost_messaging/standalone/welcome.dart' show welcomeNote;
import 'package:ghost_messaging/ui/account_screens.dart' show DevicesScreen, askSignOut;
import 'package:ghost_messaging/ui/circles/circle_face.dart' show spaceKindsOffered;
import 'package:ghost_messaging/ui/circles/circle_screen.dart' show FilesNotHere, circleSpacePage;
import 'package:ghost_messaging/ui/composer_box.dart' show composerButtons;
import 'package:ghost_messaging/ui/files_space/files_screen.dart' show FilesSpaceScreen;
import 'package:ghost_messaging/ui/hangout_screen.dart' show HangoutScreen;
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/settings_panes.dart';
import 'package:ghost_messaging/ui/settings_shortcuts.dart' show shortcutsSummary;
import 'package:ghost_messaging/ui/space_chat_files.dart' show SpaceChatFiles, SpaceFilesNotHere;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/hangout.dart' show HangoutMessage;
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/web/app.dart';
import 'package:ghost_messaging/web/browser.dart';
import 'package:ghost_messaging/web/settings.dart';
import 'package:ghost_messaging/web/store.dart';
import 'package:glacier/glacier.dart';

/// Uplink in a web page (lib/web; Matt: "the full web client"), as far as it can be held without a browser:
/// what the page keeps and how, being the one tab, where its hub is, what it says in the app's place, and what the
/// screens leave out and call themselves there. The page itself in real browser engines is tool/web/e2e.mjs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    for (final c in ['ghost_desktop/system', 'ghost_messaging/sms']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
    }
  });

  group('what the page keeps', () {
    Future<StandaloneCalls> page(MemoryBrowserProfile profile) async {
      final c = StandaloneCalls.on(WebStandaloneStore(profile.store));
      await c.load();
      return c;
    }

    test('who it is stays who it is when the page is loaded again', () async {
      final profile = MemoryBrowserProfile();
      final first = await (await page(profile)).invokeMethod<Map>('netIdentity');
      final again = await (await page(profile)).invokeMethod<Map>('netIdentity');
      expect(again, first);
      expect(first!['id'], NetCrypto.idOf(base64Decode(first['key'] as String)));
      // Another browser is someone else.
      expect((await (await page(MemoryBrowserProfile())).invokeMethod<Map>('netIdentity'))!['id'], isNot(first['id']));
    });

    test('every record is sealed: the JSON, the key and every secret; nothing is kept plain', () async {
      final profile = MemoryBrowserProfile();
      final c = await page(profile);
      final scalar = NetCrypto.hex(((await c.invokeMethod<List>('identityExport'))!).cast<int>());
      await c.invokeMethod('secretKeep', {'name': 'account-words', 'value': 'twelve words nobody else has'});
      await c.invokeMethod('setPref', {'key': 'theme', 'value': 'dark'});
      // A circle's seed kept by the circles beside their list, and a message: in the JSON, which is sealed too.
      await c.invokeMethod('setPref', {'key': 'circles_joined_at', 'value': '{"${'5e' * 32}":1}'});
      await c.invokeMethod('netTextIn', {'address': '@sam', 'body': 'a canary nobody else wrote', 'at': 1000});
      await c.flushed();
      expect(profile.store.plain, isEmpty);
      expect(profile.store.sealed.keys, unorderedEquals([WebStandaloneStore.stateName, WebStandaloneStore.identityName, 'secret:account-words']));
      // Nothing is anywhere as it was given: not the key, not the secret, not the seed, not the message.
      for (final kept in profile.store.sealed.values) {
        for (final given in [scalar, 'twelve words nobody else has', '5e' * 32, 'a canary nobody else wrote', 'theme']) {
          expect(kept, isNot(contains(given)));
        }
      }
      expect(await c.invokeMethod('secretRead', {'name': 'account-words'}), 'twelve words nobody else has');
      // The choices are in the JSON, and there after a reload; a secret given as nothing is taken away.
      expect((jsonDecode((await profile.store.readSealed(WebStandaloneStore.stateName))!) as Map)['prefs'], containsPair('theme', 'dark'));
      expect((await (await page(profile)).invokeMethod<Map>('prefs'))!['theme'], 'dark');
      await c.invokeMethod('secretKeep', {'name': 'account-words', 'value': ''});
      expect(profile.store.sealed.keys, unorderedEquals([WebStandaloneStore.stateName, WebStandaloneStore.identityName]));
      expect(await c.invokeMethod('secretRead', {'name': 'account-words'}), isNull);
    });

    test('a JSON record a build from before kept plain is read, and sealed in its place', () async {
      final profile = MemoryBrowserProfile();
      final first = await (await page(profile)).invokeMethod<Map>('netIdentity');
      profile.store.sealed.remove(WebStandaloneStore.stateName);
      profile.store.plain[WebStandaloneStore.stateName] = jsonEncode({'prefs': {'theme': 'dark'}, 'buddies': '[]'});
      final again = await page(profile);
      expect((await again.invokeMethod<Map>('prefs'))!['theme'], 'dark');
      expect((await again.invokeMethod<Map>('netIdentity'))!['id'], first!['id']);
      expect(profile.store.plain, isEmpty);
      expect(profile.store.sealed.keys, contains(WebStandaloneStore.stateName));
    });

    test('a record that won\'t open is a store lost: never quietly someone new', () async {
      final profile = MemoryBrowserProfile();
      await (await page(profile)).invokeMethod<Map>('netIdentity');
      profile.store.sealed[WebStandaloneStore.identityName] = 'not what was sealed';
      await expectLater(page(profile), throwsA(isA<StoreLost>()));
      // The JSON the same.
      final other = MemoryBrowserProfile();
      await (await page(other)).invokeMethod<Map>('netIdentity');
      await (await page(other)).invokeMethod('setPref', {'key': 'acct_address', 'value': '0xabc'});
      other.store.sealed[WebStandaloneStore.stateName] = 'changed';
      await expectLater(page(other), throwsA(isA<StoreLost>()));
      // An identity gone from a store that has the rest: the same.
      final third = MemoryBrowserProfile();
      final c = await page(third);
      await c.invokeMethod('setPref', {'key': 'acct_address', 'value': '0xabc'});
      await c.flushed();
      third.store.sealed.remove(WebStandaloneStore.identityName);
      await expectLater(page(third), throwsA(isA<StoreLost>()));
      // And one found while the app runs is told.
      final fourth = MemoryBrowserProfile();
      final d = await page(fourth);
      String? lost;
      fourth.store.onLost = (name) => lost = name;
      await d.invokeMethod('secretKeep', {'name': 'fs_prekeys', 'value': 'kept'});
      fourth.store.sealed['secret:fs_prekeys'] = 'changed';
      await expectLater(d.invokeMethod('secretRead', {'name': 'fs_prekeys'}), throwsA(isA<StoreLost>()));
      expect(lost, 'secret:fs_prekeys');
    });

    test('wiped, nothing is kept and nothing more is written; the page is told why for the welcome', () async {
      final profile = MemoryBrowserProfile();
      final c = await page(profile);
      await c.invokeMethod('netTextIn', {'address': '@sam', 'body': 'before', 'at': 1000});
      await c.invokeMethod('secretKeep', {'name': 'circle_keys', 'value': 'keys'});
      await c.flushed();
      await c.invokeMethod('wipeHere', {'note': 'signed-out'});
      expect(profile.store.wipes, 1);
      expect(profile.store.sealed, isEmpty);
      expect(c.endNote, 'signed-out');
      // Whatever is asked after is let go: the routes may still be finishing.
      await c.invokeMethod('netTextIn', {'address': '@sam', 'body': 'after', 'at': 2000});
      await c.invokeMethod('secretKeep', {'name': 'circle_keys', 'value': 'again'});
      await c.invokeMethod('identityImport', {'scalar': NetKeys.generate().scalar});
      await c.flushed();
      expect(profile.store.sealed, isEmpty);
    });
    test('an account kept in a restored key is who the page is from then on', () async {
      final profile = MemoryBrowserProfile();
      final c = await page(profile);
      final other = NetKeys.generate();
      await c.invokeMethod('identityImport', {'scalar': other.scalar});
      final again = await (await page(profile)).invokeMethod<Map>('netIdentity');
      expect(again!['id'], other.id);
    });
  });

  group('one tab at a time', () {
    test('a second tab is refused while the first is the app, and has it once that one is gone', () async {
      final profile = MemoryBrowserProfile();
      final one = MemoryBrowser(profile: profile), two = MemoryBrowser(profile: profile);
      expect(await one.holdTab(onAsked: () async {}), isNotNull);
      expect(await two.holdTab(onAsked: () async {}), isNull);
      profile.tabGone();
      expect(await two.holdTab(onAsked: () async {}), isNotNull);
    });

    test('taking over asks the tab that is it to finish first, and then it is the other\'s', () async {
      final profile = MemoryBrowserProfile();
      final one = MemoryBrowser(profile: profile), two = MemoryBrowser(profile: profile);
      final order = <String>[];
      await one.holdTab(onAsked: () async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        order.add('the first finished writing');
      });
      await two.takeTab(onAsked: () async {});
      order.add('the second has it');
      expect(order, ['the first finished writing', 'the second has it']);
      expect(await one.holdTab(onAsked: () async {}), isNull);
    });
  });

  test('a tab letting go writes what it has, and nothing after', () async {
    final before = Sms.calls;
    final profile = MemoryBrowserProfile();
    final c = StandaloneCalls.on(WebStandaloneStore(profile.store));
    await c.load();
    Sms.calls = c;
    try {
      await c.invokeMethod('netTextIn', {'address': '@sam', 'body': 'heard before handing over', 'at': 1000});
      await letGo();
      expect(c.closed, isTrue);
      final kept = (await profile.store.readSealed(WebStandaloneStore.stateName))!;
      expect(kept, contains('heard before handing over'));
      // A message heard after (the routes were stopped first, so none should be) is never written over the other tab's.
      await c.invokeMethod('netTextIn', {'address': '@sam', 'body': 'heard after', 'at': 2000});
      await c.flushed();
      expect((await profile.store.readSealed(WebStandaloneStore.stateName))!, kept);
      expect(profile.store.closed, isTrue);
    } finally {
      Sms.calls = before;
    }
  });

  // The second review: a browser removed while its tab stayed open went on reading and writing until it was loaded
  // again. It asks every few minutes, whenever it is looked at again, and as the hub comes back (no more than every half
  // minute): Account.check, which deletes only on the account's signed removal.
  test('a page left open asks whether it is still the account\'s: when looked at again, and every few minutes', () async {
    final before = Account.instance;
    final relay = _HelloCount();
    final store = MemoryMeStore()..set('acct_address', '0x${'a' * 40}');
    Account.instance = Account(relay: relay, port: _NoPort(), store: store, profiles: _NoProfiles());
    addTearDown(() => Account.instance = before);
    var now = DateTime(2026, 11, 23, 12);
    final browser = MemoryBrowser();
    removalCheckEvery = const Duration(milliseconds: 40);
    addTearDown(() => removalCheckEvery = const Duration(minutes: 3));
    final stop = watchForRemoval(browser, now: () => now);
    addTearDown(stop);
    browser.becomeVisible();
    await Future<void>.delayed(Duration.zero);
    expect(relay.hellos, 1);
    // Brought back again at once: not asked again.
    browser.becomeVisible();
    await Future<void>.delayed(Duration.zero);
    expect(relay.hellos, 1);
    // Half a minute on: asked, by the clock alone too.
    now = now.add(const Duration(seconds: 31));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(relay.hellos, 2);
    now = now.add(const Duration(seconds: 31));
    browser.becomeVisible();
    await Future<void>.delayed(Duration.zero);
    expect(relay.hellos, 3);
  });

  test('the hub is beside the app: the page\'s own address, /hub where the page is /app/', () {
    expect(hubFor(Uri.parse('https://gogho.st/app/')), 'wss://gogho.st/hub');
    expect(hubFor(Uri.parse('https://gogho.st/app/index.html')), 'wss://gogho.st/hub');
    expect(hubFor(Uri.parse('https://gogho.st/app/#anything')), 'wss://gogho.st/hub');
    expect(hubFor(Uri.parse('https://gogho.st/app')), 'wss://gogho.st/hub');
    expect(hubFor(Uri.parse('http://127.0.0.1:8787/app/')), 'ws://127.0.0.1:8787/hub');
    expect(hubFor(Uri.parse('https://example.org:8443/ghost/app/')), 'wss://example.org:8443/ghost/hub');
    // Served from somewhere else: still its own address, never another.
    expect(hubFor(Uri.parse('https://example.org/')), 'wss://example.org/hub');
    // And nothing is changed where the app is no page: the relay it always had.
    expect(Net.homeHub, Net.defaultHub);
  });

  // app.gogho.st (tool/build-web.mjs --app): the hub is the one the build names, wherever the page is.
  test('a build that names its hub speaks to that one, wherever the page is', () {
    expect(hubFor(Uri.parse('https://app.gogho.st/'), built: 'wss://gogho.st/hub'), 'wss://gogho.st/hub');
    expect(hubFor(Uri.parse('https://app.gogho.st/app/'), built: 'wss://gogho.st/hub'), 'wss://gogho.st/hub');
    // This test's build names none.
    expect(builtHub, isEmpty);
    expect(hubFor(Uri.parse('https://app.gogho.st/')), 'wss://app.gogho.st/hub');
  });

  test('a browser is named by what it says it is, and never as one of the five platforms', () {
    expect(browserNameOf('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'), 'Browser · Chrome · Mac');
    expect(browserNameOf('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15'), 'Browser · Safari · Mac');
    expect(browserNameOf('Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0'), 'Browser · Firefox · Windows');
    expect(browserNameOf('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0'), 'Browser · Edge · Windows');
    expect(browserNameOf('Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36'), 'Browser · Chrome · Android');
    expect(browserNameOf('Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1'), 'Browser · Safari · iOS');
    expect(browserNameOf('Mozilla/5.0 (X11; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0'), 'Browser · Firefox · Linux');
    expect(browserNameOf('something else entirely'), 'Browser');
    expect(browserNameOf(''), 'Browser');
  });

  group('in the app\'s place', () {
    testWidgets('a browser that can\'t run it is told why, and nothing is started', (tester) async {
      await webMain(browser: MemoryBrowser(unfit: 'Uplink needs a secure address to run in a browser: one that starts with https.'));
      await tester.pump();
      expect(find.text('Uplink needs a secure address to run in a browser: one that starts with https.'), findsOneWidget);
      expect(find.byKey(const ValueKey('web-notice-action')), findsNothing);
      expect(Sms.browser, isFalse);
      expect(Sms.standalone, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a second tab says the app is open in another, and offers to have it here', (tester) async {
      final profile = MemoryBrowserProfile();
      await MemoryBrowser(profile: profile).holdTab(onAsked: () async {});
      await webMain(browser: MemoryBrowser(profile: profile));
      await tester.pump();
      expect(find.text('Uplink is open in another tab.'), findsOneWidget);
      expect(find.text('Use it here'), findsOneWidget);
      expect(tester.getSemantics(find.byKey(const ValueKey('web-notice-action')).first), isNotNull);
      // Nothing was started, and nothing of the other tab's was touched.
      expect(Sms.browser, isFalse);
      expect(profile.store.plain, isEmpty);
      expect(profile.store.sealed, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a browser that keeps nothing for the page is told so', (tester) async {
      final browser = MemoryBrowser()..noStore = true;
      await webMain(browser: browser);
      await tester.pump();
      expect(find.text('This browser won\'t keep anything for this page.'), findsOneWidget);
      expect(Sms.browser, isFalse);
      expect(browser.reloads, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a store that won\'t open is deleted, and the page starts again saying so', (tester) async {
      final profile = MemoryBrowserProfile();
      final c = StandaloneCalls.on(WebStandaloneStore(profile.store));
      await c.load();
      await c.invokeMethod('setPref', {'key': 'acct_address', 'value': '0xabc'});
      await c.flushed();
      profile.store.sealed[WebStandaloneStore.identityName] = 'sealed under another key';
      final browser = MemoryBrowser(profile: profile);
      await webMain(browser: browser);
      expect(profile.store.wipes, 1);
      expect(browser.reloadNotes, ['lost']);
      expect(Sms.browser, isFalse, reason: 'nothing was started');
      expect(tester.takeException(), isNull);
    });

    test('the note a page was loaded again with is said once, then gone from the address', () {
      final browser = MemoryBrowser(note: 'removed');
      expect(browser.takeNote(), 'removed');
      expect(browser.takeNote(), isNull);
      expect(MemoryBrowser(note: 'anything else').takeNote(), isNull);
      expect(welcomeNote('removed'), contains('removed from your account from another device'));
      expect(welcomeNote('signed-out'), contains('signed out'));
      expect(welcomeNote('lost'), contains('couldn\'t be opened'));
      expect(welcomeNote(''), isNull);
    });

    testWidgets('a store that can\'t be read just now is said so, and nothing is written over it', (tester) async {
      final profile = MemoryBrowserProfile();
      final c = StandaloneCalls.on(WebStandaloneStore(profile.store));
      await c.load();
      await c.invokeMethod('netTextIn', {'address': '@sam', 'body': 'kept', 'at': 1000});
      await c.flushed();
      final kept = {...profile.store.sealed};
      profile.store.failReads = true;
      final browser = MemoryBrowser(profile: profile);
      // Tried again a moment apart, on the real clock.
      await tester.runAsync(() => webMain(browser: browser));
      await tester.pump();
      expect(find.text('Uplink couldn\'t read what this browser keeps for it just now.'), findsOneWidget);
      expect(profile.store.sealed, kept);
      expect(profile.store.wipes, 0);
      expect(browser.reloads, 0);
      expect(Sms.browser, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a plain record from before that can\'t be sealed just now (the store full) is left as it was', (tester) async {
      final profile = MemoryBrowserProfile();
      profile.store.plain[WebStandaloneStore.stateName] = jsonEncode({'prefs': {'theme': 'dark'}, 'buddies': '[]'});
      profile.store.failWrites = true;
      await tester.runAsync(() => webMain(browser: MemoryBrowser(profile: profile)));
      await tester.pump();
      expect(find.text('Uplink couldn\'t read what this browser keeps for it just now.'), findsOneWidget);
      expect(profile.store.plain[WebStandaloneStore.stateName], contains('dark'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the button is pressed once while what it does runs', (tester) async {
      var runs = 0;
      await tester.pumpWidget(WebNotice(
        words: 'Uplink is open in another tab.',
        action: 'Use it here',
        onAction: () async {
          runs++;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
      ));
      await tester.tap(find.byKey(const ValueKey('web-notice-action')));
      await tester.pump();
      expect(find.text('Opening…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('web-notice-action')), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(runs, 1);
      expect(find.text('Use it here'), findsOneWidget);
    });
  });

  // What a browser can't do is absent from its screens, not broken in them, and it is called a browser. Each of these
  // asks the app's own questions (Sms.browser, Sms.callsHere), which are false and true on every phone and computer.
  group('in a browser', () {
    late SmsCalls before;
    setUp(() => before = Sms.calls);
    tearDown(() {
      Sms.browser = false;
      Sms.browserCalls = false;
      Sms.browserWide = false;
      Sms.browserName = 'Browser';
      Sms.standalone = false;
      Sms.calls = before;
      SettingsSources.remove(browserSettings);
    });

    /// As lib/web/app.dart leaves things once the page has started.
    void asAPage({bool wide = true}) {
      Sms.calls = StandaloneCalls.on(WebStandaloneStore(MemoryBrowserStore()));
      Sms.standalone = true;
      Sms.browser = true;
      Sms.browserWide = wide;
      Sms.browserName = 'Browser · Safari · Mac';
      SettingsSources.add(browserSettings);
    }

    test('nowhere else is anything a browser\'s', () {
      expect(Sms.browser, isFalse);
      expect(Sms.callsHere, isTrue);
      expect(computerWord, isNot('browser'));
      expect(spaceKindsOffered, SpaceKind.values);
      expect(offeredEmojiSets, emojiSets);
      expect(emojiFamilyOf('system'), isNull);
      expect(emojiSetInUse('system').id, 'system');
      expect(settingsSectionsOn(SettingsWhere.computer).map((s) => s.id), isNot(contains('browser-about')));
      expect(circleSpacePage(const VoiceChannel(seed: 'aa', name: 'Shelf', kind: SpaceKind.files)), isA<FilesSpaceScreen>());
    });

    test('it is called a browser: in Settings, and in the account\'s list of devices', () {
      asAPage();
      expect(computerWord, 'browser');
      expect(desktopName, 'a browser');
      expect(settingsGroupLabel('app'), 'This browser');
      expect(Account.instance.profiles.deviceName, 'Browser · Safari · Mac');
    });

    test('it reads at a computer\'s sizes in a wide window and a phone\'s in a narrow one', () {
      asAPage(wide: true);
      expect(Sms.computer, isTrue);
      // Narrow: a phone's, in a browser, where the device is none of the three kinds of computer. This test runs on one
      // of them, which is a computer whatever its window: only that much can be held here.
      asAPage(wide: false);
      expect(Sms.computer, PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux);
    });

    test('Settings has its own About, and none of what it has nothing to set for', () {
      asAPage();
      final model = SettingsModel(AppState());
      final shown = [for (final s in settingsSections) if (s.when?.call(model) ?? true) s.id];
      expect(shown, contains('browser-about'));
      // No calls, no sounds: nothing to set. And what is the phone's alone was never a computer's.
      expect(shown, isNot(contains('voice')));
      expect(shown, isNot(contains('sounds')));
      for (final phones in ['notifications', 'receipts', 'android', 'keyboard', 'computers', 'network', 'updates', 'about', 'api']) {
        expect(shown, isNot(contains(phones)), reason: phones);
      }
      // What it does have.
      expect(shown, containsAll(['me', 'appearance', 'emoji', 'messages', 'blocked']));
      final about = settingsSections.firstWhere((s) => s.id == 'browser-about');
      expect(about.summary!(model), 'Uplink in a browser $appVersion');
      // Keyboard shortcuts with no push to talk, and none of the calls' commands.
      expect(shortcutsSummary(model), 'Every command and its keys');
      // On a phone or a computer they are there as they were.
      Sms.browser = false;
      final elsewhere = [for (final s in settingsSectionsOn(SettingsWhere.computer)) if (s.when?.call(model) ?? true) s.id];
      expect(elsewhere, containsAll(['voice', 'sounds']));
      expect(shortcutsSummary(model), 'Push to talk off');
    });

    test('there are no calls: nothing joins one, and a space is offered without Files', () async {
      asAPage();
      expect(Sms.callsHere, isFalse);
      const lounge = VoiceChannel(seed: 'aa', name: 'Lounge');
      await expectLater(Voice.instance.join(lounge), throwsA(isA<StateError>().having((e) => e.message, 'what it says', 'Calls aren\'t in the browser yet.')));
      expect(spaceKindsOffered, [SpaceKind.voice, SpaceKind.text]);
      // A Files space made elsewhere says where it opens, in its page's place; the others are their chat.
      expect(circleSpacePage(const VoiceChannel(seed: 'aa', name: 'Shelf', kind: SpaceKind.files)), isA<FilesNotHere>());
      expect(circleSpacePage(lounge), isA<HangoutScreen>());
    });

    // GMFB-30, GMFB-51: a build with calls (every one but tool/build-web.mjs --no-calls) joins them through the page's own WebRTC.
    test('with calls in its build, a browser offers them: the spaces\' calls, their keys, Voice and video, and says what a call leaves out', () async {
      asAPage();
      expect(webCalls, isTrue, reason: 'on unless the build leaves them out (--no-calls)');
      expect(webFiles, isTrue, reason: 'on unless the build leaves them out (--no-files)');
      Sms.browserCalls = true;
      expect(Sms.callsHere, isTrue);
      // Into a call as anywhere else: here no relay is connected, which is what stops it, not the browser.
      const lounge = VoiceChannel(seed: 'aa', name: 'Lounge');
      await expectLater(Voice.instance.join(lounge), throwsA(isA<StateError>().having((e) => e.message, 'what it says', 'The relay server isn\'t connected.')));
      for (final c in KeyCommand.values) {
        expect(Keys.offered(c), c != KeyCommand.marketplace, reason: c.name);
      }
      final model = SettingsModel(AppState());
      final shown = [for (final s in settingsSections) if (s.when?.call(model) ?? true) s.id];
      expect(shown, contains('voice'));
      expect(shortcutsSummary(model), 'Push to talk off');
      expect(notInBrowserYet, isNot(startsWith('Calls')));
      expect(notInBrowserYet, contains('recording, the voice changer'));
      Sms.browserCalls = false;
      expect(notInBrowserYet, startsWith('Calls, '));
    });

    testWidgets('a Files space says it isn\'t in the browser yet', (tester) async {
      final sheet = await _sheet(tester);
      asAPage();
      await tester.pumpWidget(_Themed(sheet: sheet, child: const FilesNotHere(channel: VoiceChannel(seed: 'aa', name: 'Shelf', kind: SpaceKind.files))));
      expect(find.text('Files spaces aren\'t in the browser yet. This one opens in Uplink on a phone or a computer.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the composer has Send where the microphone is, since nothing is recorded there', (tester) async {
      final sheet = await _sheet(tester);
      Future<List<String>> keys({required bool something}) async {
        late List<String> found;
        await tester.pumpWidget(_Themed(
          sheet: sheet,
          child: Builder(builder: (context) {
            final b = composerButtons(context.tokens, hasSomething: something, onAttach: null, onSticker: () {}, onRecord: null, onSend: something ? () {} : null);
            found = [for (final w in [...b.ends, ...b.below]) if (w.key is ValueKey<String>) (w.key! as ValueKey<String>).value];
            return Row(children: [b.plus, ...b.ends]);
          }),
        ));
        return found;
      }

      expect(await keys(something: false), contains('composer-mic'));
      asAPage();
      expect(await keys(something: false), isNot(contains('composer-mic')));
      expect(await keys(something: false), contains('composer-send'));
      expect(await keys(something: true), contains('composer-send'));
      expect(tester.takeException(), isNull);
    });

    // Matt: "the full web client". What a browser hasn't got is in no list of commands, on no key and in no quick
    // switcher, however it is asked for; everywhere else every command is as it was.
    test('the Marketplace and the calls\' commands are on no key, and in no list, in a browser', () {
      for (final c in KeyCommand.values) {
        // The call's mini window is only a Mac's and a PC's app's (lib/desktop/mini_window.dart, test/call_mini_test.dart).
        if (c == KeyCommand.miniWindow) continue;
        expect(Keys.offered(c), isTrue, reason: '${c.name} elsewhere');
      }
      final keys = Keys.forTest();
      asAPage();
      for (final c in KeyCommand.values) {
        expect(Keys.offered(c), c.group != 'Calls' && c != KeyCommand.marketplace, reason: c.name);
      }
      // No key is the Marketplace's, nor push to talk's: the key alone is the key.
      expect(keys.commandFor(const KeyDownEvent(physicalKey: PhysicalKeyboardKey.backquote, logicalKey: LogicalKeyboardKey.backquote, timeStamp: Duration.zero), typing: false), isNull);
      Sms.browser = false;
      expect(keys.commandFor(const KeyDownEvent(physicalKey: PhysicalKeyboardKey.backquote, logicalKey: LogicalKeyboardKey.backquote, timeStamp: Duration.zero), typing: false), KeyCommand.pushToTalk);
    });

    testWidgets('a picture or a file posted in a space from a phone shows what it is, and opens nowhere here', (tester) async {
      final sheet = await _sheet(tester);
      asAPage();
      SpaceFile file(String name, {Uint8List? thumb}) => SpaceFile(id: NetCrypto.hex(NetCrypto.randomBytes(16)), name: name, size: 123456, mime: FileKind.mimeOf(name), sha: '', key: NetCrypto.randomBytes(32), prefix: NetCrypto.randomBytes(8), by: 'maya', byName: 'Maya', at: 0, thumb: thumb, width: 40, height: 30);
      final picture = file('beach.jpg', thumb: base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='));
      final message = HangoutMessage(id: 'm1', from: 'maya', name: 'Maya', text: 'from the beach', at: 0, files: [picture, file('notes.pdf'), file('clip.mp4')]);
      await tester.pumpWidget(_Themed(
        sheet: sheet,
        child: Center(child: SpaceChatFiles(channel: const VoiceChannel(seed: 'aa', name: 'General', kind: SpaceKind.text), message: message, maxWidth: 280, ground: const Color(0xFF222222), ink: const Color(0xFFFFFFFF))),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'nothing looked for on a disk the page hasn\'t got');
      expect(find.byType(SpaceFilesNotHere), findsOneWidget);
      expect(find.text('beach.jpg'), findsOneWidget);
      expect(find.text('notes.pdf'), findsOneWidget);
      expect(find.textContaining('opens on a phone or a computer'), findsNWidgets(3));
      // The small picture that came in the message is drawn; nothing else is fetched.
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('space-file-not-here-${picture.id}')));
      await tester.pump();
      expect(find.text(SpaceFilesNotHere.words), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    // What signing out does here is said plainly (lib/ui/account_screens.dart: askSignOut).
    testWidgets('signing out says what goes and what stays: everything in a browser, a choice on a device of its own', (tester) async {
      final sheet = await _sheet(tester);
      Future<List<String>> said() async {
        await tester.pumpWidget(_Themed(
          sheet: sheet,
          child: Builder(builder: (context) => GestureDetector(key: const ValueKey('ask'), behavior: HitTestBehavior.opaque, onTap: () => askSignOut(context), child: const SizedBox.expand())),
        ));
        await tester.tap(find.byKey(const ValueKey('ask')));
        await tester.pumpAndSettle();
        final words = [for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? ''];
        await tester.pumpWidget(const SizedBox());
        return words;
      }

      asAPage();
      var words = await said();
      expect(words.join('\n'), contains('Sign out of this browser? Everything of your account is deleted from it'));
      expect(words, contains('Sign out and delete'));
      expect(words, isNot(contains('Sign out')));
      // An iPhone or a computer of its own: what stays is said, and deleting it too is offered.
      Sms.browser = false;
      words = await said();
      expect(words.join('\n'), contains('Your conversations, your spaces and your choices stay on this device, unless you delete everything here too, which also signs out of your other networks here'));
      expect(words, containsAll(['Sign out', 'Sign out and delete everything here']));
      // A phone: its texts and conversations stay, as they always have.
      Sms.standalone = false;
      Sms.calls = before;
      words = await said();
      expect(words.join('\n'), contains('Your texts and conversations stay on this phone.'));
      expect(words, isNot(contains('Sign out and delete everything here')));
      expect(tester.takeException(), isNull);
    });

    test('a browser\'s place on the list says when it was last seen and signed in', () {
      final now = DateTime.utc(2026, 11, 23, 12);
      AccountDevice device(String p, {bool here = false}) => AccountDevice(id: 'a' * 32, name: 'Browser · Chrome · Mac', platform: p, since: '2026-11-03', seen: '2026-11-22', here: here);
      expect(DevicesScreen.hintOf(device('web'), now: now), 'A browser. Last seen yesterday, signed in 3 Nov 2026');
      expect(DevicesScreen.hintOf(device('android'), now: now), 'Last seen yesterday');
      expect(DevicesScreen.hintOf(device('web', here: true), now: now), 'This device');
      expect(DevicesScreen.dayOf('2026-11-23', now: now), 'today');
    });
  });
}

/// The app's own stylesheet, as its start loads it.
Future<TokenSheet> _sheet(WidgetTester tester) async {
  final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
  installSettingsStyles(sheet);
  return sheet;
}

/// A widget of the app's with the app round it: its choices, and the theme it reads its sizes and colours from.
class _Themed extends StatelessWidget {
  const _Themed({required this.sheet, required this.child});
  final TokenSheet sheet;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = AppState();
    return AppScope(
      state: state,
      child: WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (c, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'desktop'), child: GlacierToastProvider(child: child!)),
        home: child,
      ),
    );
  }
}

/// A relay that counts how often a device asks whether it is still listed, and says it is.
class _HelloCount implements AccountRelay {
  var hellos = 0;
  @override
  String get hubId => 'test';
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    if (what['dir'] == 'acct-hello') hellos++;
    return {'dir': what['dir'], 'known': true, 'account': true};
  }
}

class _NoPort implements AccountPort {
  @override
  dynamic noSuchMethod(Invocation i) => Future<Object?>.value();
}

class _NoProfiles implements AccountProfiles {
  @override
  dynamic noSuchMethod(Invocation i) => Future<Object?>.value();
}
