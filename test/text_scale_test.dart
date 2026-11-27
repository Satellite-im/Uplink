import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/settings_panes.dart';
import 'package:ghost_messaging/ui/text_scale.dart';
import 'package:ghost_messaging/ui/thread.dart';

import 'support/list_harness.dart';

/// The text size slider (GMFB-41, lib/ui/text_scale.dart): a number from 80 to 150 kept under `text_scale`, laid over
/// every word the app draws, with the four sizes there were before read as the percent they were.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null));

  group('the size kept', () {
    test('nothing chosen is 100%, and an old size is the percent it was', () {
      expect(AppState().textPercent, 100);
      for (final (old, percent) in [('small', 90), ('default', 100), ('large', 115), ('larger', 130)]) {
        expect((AppState()..set('text_size', old)).textPercent, percent, reason: old);
      }
    });

    test('a percent chosen is kept as a number and wins over the old size', () {
      final app = AppState()..set('text_size', 'larger');
      app.setTextPercent(105);
      expect(app.choice('text_scale', ''), '105');
      expect(app.textPercent, 105);
      // The old choice is left as it was: an older version on another device still reads it.
      expect(app.textSize, 'larger');
    });

    test('held to steps of five between 80 and 150', () {
      expect(AppState.textStep(60), 80);
      expect(AppState.textStep(400), 150);
      expect(AppState.textStep(112), 110);
      expect(AppState.textStep(113), 115);
      expect((AppState()..set('text_scale', '999')).textPercent, 150);
      expect((AppState()..set('text_scale', 'big')).textPercent, 100);
    });

    test('a message is not multiplied a second time', () {
      expect((AppState()..setTextPercent(150)).textScale, 1.0);
      expect((AppState()..set('text_size', 'large')).textScale, 1.0);
    });
  });

  group('over the app', () {
    Future<TextScaler> scalerWith(WidgetTester tester, AppState app, {TextScaler device = TextScaler.noScaling}) async {
      late TextScaler got;
      await tester.pumpWidget(AppScope(
        state: app,
        child: MediaQuery(
          data: MediaQueryData(textScaler: device),
          child: AppTextScale(child: Builder(builder: (context) {
            got = MediaQuery.textScalerOf(context);
            return const SizedBox.shrink();
          })),
        ),
      ));
      return got;
    }

    testWidgets('at 100% the device\'s own scaling is left exactly as it is', (tester) async {
      const device = TextScaler.linear(1.3);
      expect(await scalerWith(tester, AppState(), device: device), same(device));
    });

    testWidgets('a size chosen multiplies the device\'s own', (tester) async {
      final app = AppState()..setTextPercent(150);
      expect((await scalerWith(tester, app)).scale(10), 15);
      expect((await scalerWith(tester, app, device: const TextScaler.linear(1.2))).scale(10), closeTo(18, 0.001));
      expect((await scalerWith(tester, AppState()..set('text_size', 'small'))).scale(10), 9);
    });
  });

  group('Settings › Appearance › Text', () {
    testWidgets('the slider: a tap along the track chooses a percent, and the app is drawn at it', (tester) async {
      ListPhone([]).install();
      final sheet = await loadSheet(tester);
      final app = AppState();
      final model = SettingsModel(app);
      addTearDown(model.dispose);
      final section = settingsSections.firstWhere((s) => s.id == 'appearance');
      await pumpScreen(tester, sheet, ListenableBuilder(listenable: app, builder: (context, _) => AppTextScale(child: SectionPage(section: section, model: model))), app);
      final slider = find.byKey(const ValueKey('text-size'));
      await tester.scrollUntilVisible(slider, 200, scrollable: find.byType(Scrollable).first);
      await settle(tester);
      expect(find.text('100%'), findsOneWidget);
      final box = tester.getRect(slider);
      // The far right is 150%, the far left 80%, and the middle 115%.
      await tester.tapAt(Offset(box.right - 1, box.center.dy));
      await settle(tester);
      expect(app.textPercent, 150);
      expect(app.choice('text_scale', ''), '150');
      expect(find.text('150%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(slider);
      await settle(tester);
      final again = tester.getRect(slider);
      await tester.tapAt(Offset(again.left + 1, again.center.dy));
      await settle(tester);
      expect(app.textPercent, 80);
      await tester.ensureVisible(slider);
      await settle(tester);
      final mid = tester.getRect(slider);
      await tester.tapAt(mid.center);
      await settle(tester);
      expect(app.textPercent, 115);
      expect(tester.takeException(), isNull);
    });
  });

  // The dense screens at the top of the range on a phone: nothing may be drawn past its edge.
  group('at 150% on a phone nothing overflows', () {
    AppState large() => AppState()..setTextPercent(150);
    const small = Size(360, 720);

    testWidgets('the list of conversations', (tester) async {
      ListPhone([
        ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7 by the fountain where we met the last time', name: 'Maya Chen-Featherstonehaugh', minutes: 4, unread: true),
        ListPhone.conversation(2, '70001', 'Your ticket 4411 is ready', minutes: 9, unread: true, muted: true),
        ListPhone.conversation(3, '+15551230005', 'Call me when you land', name: 'Dad', minutes: 50),
        ListPhone.conversation(4, '+15551230006', 'I have ticket 77 for you', name: 'Priya Natarajan', minutes: 3000),
      ]).install();
      final sheet = await loadSheet(tester);
      // The words are drawn larger, not only said to be: a name's height at 100% and at 150%.
      await pumpScreen(tester, sheet, const AppTextScale(child: ConversationsScreen()), AppState(), size: small);
      final plain = tester.getSize(find.text('Dad')).height;
      await tester.pumpWidget(const SizedBox());
      await pumpScreen(tester, sheet, const AppTextScale(child: ConversationsScreen(key: ValueKey('large'))), large(), size: small);
      expect(tester.getSize(find.text('Dad')).height, closeTo(plain * 1.5, 1.5));
      expect(find.byType(ConversationRow), findsNWidgets(4));
      expect(MediaQuery.textScalerOf(tester.element(find.byType(ConversationRow).first)).scale(10), 15);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a conversation', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
        switch (call.method) {
          case 'status':
            return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
          case 'messages':
            return [
              for (var i = 0; i < 8; i++)
                {'id': 20 - i, 'kind': 'sms', 'address': '+15551230007', 'body': i.isEven ? 'A long line of words that has to wrap inside its bubble at this size, twice over at least' : 'ok', 'date': now - i * 60000, 'outgoing': i % 3 == 0, 'state': 'sent', 'read': true},
            ];
          case 'e2e':
            return {'address': (call.arguments as Map)['address'], 'state': 'none', 'verified': false, 'changed': false};
          case 'prefs':
            return <String, String>{};
          case 'ghostPeers':
          case 'netSmsAvailable':
            return false;
          default:
            return null;
        }
      });
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, const AppTextScale(child: ThreadScreen(thread: 7, people: [Person(address: '+15551230007', name: 'Person Seven Of A Long Name')])), large(), size: small);
      expect(find.textContaining('A long line of words'), findsWidgets);
      expect(tester.takeException(), isNull);
      await settle(tester);
    });

    testWidgets('Settings, its list and every page a phone has that opens with nothing asked', (tester) async {
      ListPhone([]).install();
      final sheet = await loadSheet(tester);
      final app = large();
      await pumpScreen(tester, sheet, const AppTextScale(child: SettingsScreen()), app, size: small);
      expect(tester.takeException(), isNull);
      final model = SettingsModel(app);
      addTearDown(model.dispose);
      for (final id in ['appearance', 'messages', 'notifications', 'effects', 'receipts']) {
        final section = settingsSections.firstWhere((s) => s.id == id);
        await pumpScreen(tester, sheet, AppTextScale(child: SectionPage(key: ValueKey(id), section: section, model: model)), app, size: small);
        final list = find.byType(Scrollable).first;
        for (var i = 0; i < 6; i++) {
          expect(tester.takeException(), isNull, reason: id);
          await tester.drag(list, const Offset(0, -500));
          await settle(tester);
        }
        expect(tester.takeException(), isNull, reason: id);
      }
    });
  });
}
