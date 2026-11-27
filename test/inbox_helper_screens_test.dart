import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/glacier.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/account_helper.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/ui/inbox_signin_helper.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:ghost_messaging/ui/me.dart' show NetworkMark;
import 'package:ghost_messaging/ui/settings.dart';

import 'support/space_call_harness.dart';

/// Signing in to Messenger, Instagram and LinkedIn (lib/ui/inbox_signin_helper.dart) and their place in Settings, drawn
/// to test/shots/helper-* with --update-goldens.
class _Helper implements HelperLink {
  final asked = <Map<String, Object?>>[];
  final _out = StreamController<Map<String, Object?>>.broadcast();
  Object? Function(Map<String, Object?> r) answer = (_) => null;

  @override
  Stream<Map<String, Object?>> get heard => _out.stream;

  @override
  void say(Map<String, Object?> line) {
    asked.add(line);
    Map<String, Object?> reply;
    try {
      reply = {'id': line['id'], 'ok': true, 'result': line['op'] == 'status' ? {'linked': false} : answer(line)};
    } on StateError catch (e) {
      reply = {'id': line['id'], 'ok': false, 'error': e.message};
    }
    scheduleMicrotask(() => _out.add(reply));
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ghost-helper-ui'));
  tearDown(() {
    Inbox.instance = null;
    dir.deleteSync(recursive: true);
  });

  testWidgets('the warning is agreed to first; then the steps; a bad paste is said, a good one signs in', (tester) async {
    final h = await SpaceHarness.load(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    for (final dark in [false, true]) {
      final helper = _Helper();
      final n = AccountHelper(instagramService, link: () async => helper, folder: '${dir.path}/$dark');
      await tester.runAsync(() => n.start(AppState()));
      final opened = <String>[];
      await h.shoot(tester, HelperSignInScreen(network: n, onOpenPrivate: (url) async {
        opened.add(url);
        return true;
      }), 'helper-warning', dark: dark);
      // Nothing but the warning until it is agreed to.
      expect(find.textContaining('Instagram doesn\'t support or allow other apps'), findsOneWidget);
      expect(find.byKey(const ValueKey('helper-pasted')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('helper-agree')));
      await h.again(tester, 'helper-steps', dark: dark);
      expect(find.text('Sign in to Instagram in a private window'), findsOneWidget);
      // The extension's card comes first now: the paste box is further down the list.
      await tester.scrollUntilVisible(find.byKey(const ValueKey('helper-pasted')), 200, scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const ValueKey('helper-pasted')), findsOneWidget);
      expect(helper.asked.where((r) => r['op'] == 'sign_in'), isEmpty);

      // Something pasted that is not the request.
      await tester.enterText(find.byType(EditableText), 'sessionid=only');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('helper-sign-in')));
      await h.again(tester, 'helper-missing', dark: dark);
      expect(find.textContaining('missing csrftoken, ds_user_id'), findsOneWidget);
      expect(helper.asked.where((r) => r['op'] == 'sign_in'), isEmpty);

      // The request itself.
      helper.answer = (r) => r['op'] == 'sign_in' ? {'me': '42', 'name': 'Matt', 'handle': 'matt'} : (r['op'] == 'chats' ? const [] : null);
      await tester.enterText(find.byType(EditableText), "curl 'https://www.instagram.com/' -H 'cookie: sessionid=s; csrftoken=c; ds_user_id=42'");
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('helper-sign-in')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(n.state, InboxState.ready);
      expect(n.account, '@matt');
      await tester.pump(const Duration(seconds: 7));
      n.dispose();
    }
  });

  testWidgets('each has its mark, its page of Settings with the warning, and "Not in this build" without its helper', (tester) async {
    final h = await SpaceHarness.load(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    final helper = _Helper();
    final signedOut = AccountHelper(messengerService, link: () async => helper, folder: '${dir.path}/m');
    final none = AccountHelper(linkedInService, link: () async => null, folder: '${dir.path}/l');
    final insta = AccountHelper(instagramService, link: () async => null, folder: '${dir.path}/i');
    Inbox.instance = Inbox.of([signedOut, insta, none]);
    final store = AppState();
    await tester.runAsync(() async {
      for (final n in Inbox.instance.networks) {
        n.listStore = store;
        await n.start(store);
      }
    });
    addInboxSettings();
    addTearDown(() => SettingsSources.remove(inboxSettingsSections));
    for (final dark in [false, true]) {
      await h.shoot(tester, const SettingsSectionScreen('connections'), 'helper-connections', dark: dark);
      expect(find.text('Messenger'), findsOneWidget);
      expect(find.text('Instagram'), findsOneWidget);
      expect(find.text('LinkedIn'), findsOneWidget);
      // Their own logos, not a letter.
      for (final w in tester.widgetList<NetworkMark>(find.byType(NetworkMark))) {
        expect(find.descendant(of: find.byWidget(w), matching: find.byType(CustomPaint)), findsWidgets, reason: '${w.network.name} has a mark');
      }
      store.set('inbox_on_messenger', 'off'); // the shared store carries a switch between the two runs; start each off
      await h.shoot(tester, const SettingsSectionScreen('inbox-messenger'), 'helper-settings', dark: dark);
      // A plugin is off until switched on; then its warning and sign-in show (Matt, 2026-11-20: "Setup all these other
      // services as plugins ... off by default").
      expect(find.text('Use Messenger'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('plugin-switch')), matching: find.byType(GlacierSwitch)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Messenger doesn\'t support or allow other apps'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      await h.shoot(tester, const SettingsSectionScreen('inbox-linkedin'), 'helper-not-in-build', dark: dark);
      expect(find.text('Not in this build'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
    }
  });

  testWidgets('a sign-in the extension synced is offered first: one press signs Discord in with its token', (tester) async {
    final h = await SpaceHarness.load(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    final helper = _Helper();
    final n = AccountHelper(discordService, link: () async => helper, folder: '${dir.path}/discord');
    await tester.runAsync(() => n.start(AppState()));
    await h.shoot(tester, HelperSignInScreen(network: n, synced: () async => (cookies: {'token': 'synced-token'}, at: 1)), 'helper-synced');
    await tester.tap(find.byKey(const ValueKey('helper-agree')));
    await tester.pumpAndSettle();
    expect(find.text('Use the sign-in from your browser'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('helper-synced-sign-in')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    final asked = helper.asked.lastWhere((r) => r['op'] == 'sign_in');
    expect((asked['cookies'] as Map)['token'], 'synced-token');
    await tester.pump(const Duration(seconds: 7)); // the "Signed in" toast goes
  });
}
