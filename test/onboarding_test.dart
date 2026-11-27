import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/glacier.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/onboarding/narration.dart';
import 'package:ghost_messaging/onboarding/onboarding.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:pointycastle/digests/sha256.dart';

/// The first-run walkthrough (lib/onboarding; Matt, 2026-11-15: "Look at how we do onboarding on Ghost KBD and Ghost
/// Markdown with the optional voice guide through the elevenlabs key and the vibrant colors and iconography for each
/// step, mimick this on the setup of Ghost Messaging"): its voice, its way out, and the words each voice was made from.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final played = <String>[];
  var status = <String, Object>{'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};

  setUp(() {
    played.clear();
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'status' ? status : null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost/guide'), (call) async {
      played.add(call.method == 'play' ? (call.arguments as Map)['asset'] as String : 'stop');
      return true;
    });
  });

  Future<AppState> open(WidgetTester tester, {VoidCallback? onDone}) async {
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    final app = AppState();
    await tester.pumpWidget(AppScope(
      state: app,
      child: WidgetsApp(
        color: const Color(0xFF4F5BD5),
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(app, 'mobile'), child: child!),
        home: Onboarding(onDone: onDone),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return app;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the texts page says its words, and switched off the voice stays off', (tester) async {
    final app = await open(tester);
    expect(played, ['assets/onboarding/texts.mp3']);
    played.clear();
    await tester.tap(find.byKey(const ValueKey('guide-voice')));
    await settle(tester);
    expect(played, ['stop']);
    expect(app.flag('guide_voice'), isFalse, reason: 'kept, as Ghost.md keeps its own');
    expect(find.text('Voice off'), findsOneWidget);
  });

  // Matt, 2026-11-20: "rework the onboarding flow to be very simple and just ask for a username and password"; "Yes,
  // replace it": the texts step alone, then the username and password (lib/main.dart).
  testWidgets('the walkthrough is the texts step alone', (tester) async {
    await open(tester);
    expect(guidePages.map((p) => p.$1), ['texts']);
    expect(find.text('Start with your texts'), findsOneWidget);
    expect(find.text('Everyone, in one place'), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('before Uplink can send texts there is no Skip and Continue waits', (tester) async {
    status = {'isDefault': false, 'contacts': false, 'notifications': false, 'phone': true};
    addTearDown(() => status = {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true});
    var done = 0;
    await open(tester, onDone: () => done++);
    expect(find.byKey(const ValueKey('guide-skip')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('guide-next')));
    await settle(tester);
    expect(done, 0);
    expect(find.text('Start with your texts'), findsOneWidget);
  });

  // Matt, 2026-11-20: "rework the onboarding on mobile so that SMS is not required and you can 'skip this step'".
  testWidgets('texts can be skipped: Skip this step finishes, and the account is asked for next', (tester) async {
    status = {'isDefault': false, 'contacts': false, 'notifications': false, 'phone': true};
    addTearDown(() => status = {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true});
    var done = 0;
    final app = await open(tester, onDone: () => done++);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('guide-skip-texts')), 120, scrollable: find.descendant(of: find.byType(PageView), matching: find.byType(Scrollable)).last);
    await tester.tap(find.byKey(const ValueKey('guide-skip-texts')));
    await settle(tester);
    expect(app.flag(textsSkippedKey, fallback: false), isTrue);
    expect(done, 1);
    expect(app.flag(accountDueKey, fallback: false), isTrue, reason: 'a new install is asked for a username and password next');
  });

  testWidgets('Skip finishes it, says so, and stops the voice', (tester) async {
    var done = 0;
    final app = await open(tester, onDone: () => done++);
    await tester.tap(find.byKey(const ValueKey('guide-skip')));
    await settle(tester);
    expect(done, 1);
    expect(app.flag('onboarded', fallback: false), isTrue);
    expect(played.last, 'stop');
  });

  test('every page has its voice, made from the words it shows now', () {
    final manifest = jsonDecode(File('assets/onboarding/narration.json').readAsStringSync()) as Map<String, dynamic>;
    final files = (manifest['files'] as Map).cast<String, dynamic>();
    for (final (id, _, _) in guidePages) {
      expect(narration[id], isNotNull, reason: '$id has words');
      expect(File('assets/onboarding/$id.mp3').existsSync(), isTrue, reason: '$id has a voice (python3 tool/onboarding_voice.py)');
      final digest = SHA256Digest().process(utf8.encode(narration[id]!)).map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, 16);
      expect(files[id]?['words'], digest, reason: '$id\'s words changed since its voice was made: python3 tool/onboarding_voice.py');
    }
    final bytes = Directory('assets/onboarding').listSync().whereType<File>().fold<int>(0, (n, f) => n + f.lengthSync());
    expect(bytes, lessThan(2 << 20), reason: 'the voices stay small');
  });

  test('the words are read by the tool as the app has them', () {
    // The tool reads one line a page: 'id': '...', with \' for an apostrophe.
    final source = File('lib/onboarding/narration.dart').readAsStringSync();
    final found = {
      for (final m in RegExp(r"^\s*'(\w+)':\s*'((?:[^'\\]|\\.)*)',\s*$", multiLine: true).allMatches(source)) m.group(1)!: m.group(2)!.replaceAll(r"\'", "'"),
    };
    expect(found, narration);
  });

  test('SmsStatus.usable: the default, or beside Google Messages', () {
    expect(SmsStatus.from(const {'isDefault': false, 'contacts': true, 'notifications': true, 'phone': true, 'sms': true, 'bridge': true}).usable, isTrue);
    expect(SmsStatus.from(const {'isDefault': false, 'contacts': true, 'notifications': true, 'phone': true}).usable, isFalse);
  });
}
