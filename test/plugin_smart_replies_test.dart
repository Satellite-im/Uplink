import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/local_ai.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/plugins/conversation.dart' show PluginThread;
import 'package:ghost_messaging/plugins/replies.dart';
import 'package:glacier/glacier.dart';

/// Smarter replies and Summarize, by the device's own small model (lib/local_ai.dart, lib/plugins/replies.dart; Matt,
/// 2026-11-26: "add more intelligent auto replies using a very lightweight local AI that summarizes text and whatnot").
void main() {
  AiLine them(String text, [String who = 'Ana']) => (mine: false, who: who, text: text, at: 1);
  AiLine me(String text) => (mine: true, who: '', text: text, at: 1);

  tearDown(() {
    LocalAi.debugCalls = null;
    LocalAi.instance.debugReset();
  });

  test('what a lot that came in at once is', () {
    expect(catchUpOf([me('hey'), them('a'), them('b'), them('c')]), isNull, reason: 'three short texts read quickly');
    final four = catchUpOf([them('old'), me('hey'), them('one'), them('two'), them('three'), them('four', 'Bo')])!;
    expect(four.message, isFalse);
    expect(four.count, 4);
    expect(four.text, 'Ana: one\nAna: two\nAna: three\nBo: four', reason: 'since the person wrote, oldest first');
    final long = catchUpOf([me('so?'), them('x' * catchUpLong)])!;
    expect(long.message, isTrue);
    expect(long.text, 'x' * catchUpLong);
    expect(catchUpOf([them('a long one ${'y' * catchUpLong}'), me('ok')]), isNull, reason: 'the person has answered');
  });

  test('the model is asked once for the same texts, and not at all after the person\'s own', () async {
    var asked = 0;
    LocalAi.debugCalls = (method, args) async {
      asked++;
      expect(method, 'replies');
      final lines = args['messages'] as List;
      expect((lines.last as Map)['text'], 'dinner at 7?');
      return ['Yes, 7 works', 'Can we do 8?', 'Where?'];
    };
    final talk = [me('free tonight?'), them('dinner at 7?')];
    expect(await LocalAi.instance.replies(talk), ['Yes, 7 works', 'Can we do 8?', 'Where?']);
    expect(await LocalAi.instance.replies(talk), hasLength(3));
    expect(asked, 1);
    expect(await LocalAi.instance.replies([them('dinner at 7?'), me('sure')]), isNull);
    expect(asked, 1);
  });

  test('a device with no model answers nothing, and the words\' own replies stay', () async {
    LocalAi.debugCalls = (method, args) async => method == 'status' ? 'unavailable' : null;
    expect(await LocalAi.instance.replies([them('hi')]), isNull);
    expect(await LocalAi.instance.summarize('Ana: hi'), isNull);
    expect(await LocalAi.instance.status(), 'unavailable');
  });

  group('over the composer', () {
    Future<List<String>> pump(WidgetTester tester, Widget chips) async {
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      installSettingsStyles(sheet);
      final state = AppState();
      final written = <String>[];
      await tester.pumpWidget(AppScope(
        state: state,
        child: WidgetsApp(
          color: const Color(0xFF000000),
          pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
          home: PluginThread(write: written.add, child: Align(alignment: Alignment.bottomCenter, child: chips)),
        ),
      ));
      return written;
    }

    testWidgets('the words\' replies first, then the model\'s in their place', (tester) async {
      LocalAi.debugCalls = (method, args) async => method == 'replies' ? ['Yes, 7 works', 'Can we do 8?'] : 'unavailable';
      final written = await pump(tester, SmartReplyChips(rules: repliesFor('dinner at 7?'), recent: [them('dinner at 7?')]));
      await tester.pumpAndSettle();
      expect(find.text('Yes, 7 works'), findsOneWidget);
      expect(find.text('Sounds good!'), findsNothing);
      await tester.tap(find.text('Can we do 8?'));
      expect(written, ['Can we do 8?']);
    });

    testWidgets('with no model the words\' replies stay, and no Summarize', (tester) async {
      LocalAi.debugCalls = (method, args) async => method == 'status' ? 'unavailable' : null;
      final talk = [for (var i = 0; i < 5; i++) them('text $i')];
      await pump(tester, SmartReplyChips(rules: repliesFor('ok cool'), recent: talk, catchUp: catchUpOf(talk)));
      await tester.pumpAndSettle();
      expect(find.text('Sounds good'), findsOneWidget);
      expect(find.textContaining('Summarize'), findsNothing);
    });

    testWidgets('Summarize when a lot came in, and its sentence over the replies', (tester) async {
      String? asked;
      LocalAi.debugCalls = (method, args) async {
        if (method == 'status') return 'available';
        if (method == 'summarize') {
          asked = args['text'] as String;
          return 'Ana is running late and asks you to order for her.';
        }
        return null;
      };
      final talk = [me('here'), them('sorry'), them('train stuck'), them('20 min'), them('order for me?')];
      await pump(tester, SmartReplyChips(rules: repliesFor('order for me?'), recent: talk, catchUp: catchUpOf(talk)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Summarize 4 messages'));
      await tester.pumpAndSettle();
      expect(asked, 'Ana: sorry\nAna: train stuck\nAna: 20 min\nAna: order for me?');
      expect(find.text('Ana is running late and asks you to order for her.'), findsOneWidget);
      expect(find.textContaining('Summarize'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Close the summary'));
      await tester.pumpAndSettle();
      expect(find.text('Ana is running late and asks you to order for her.'), findsNothing);
    });
  });
}
