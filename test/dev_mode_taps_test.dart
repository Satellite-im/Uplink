import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/settings_panes.dart';
import 'package:glacier/glacier.dart';

/// Twelve taps on Settings › About › Version turn developer mode on, which shows Settings › Developer (Matt,
/// 2026-11-20: "make it enabled by tapping the version number 12 times").
void main() {
  testWidgets('twelve quick taps on Version turn developer mode on; slow ones start again', (tester) async {
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final state = AppState();
    late BuildContext context;
    await tester.pumpWidget(AppScope(
      state: state,
      child: WidgetsApp(
        color: const Color(0xFF000000),
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (c, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: GlacierToastProvider(child: child!)),
        home: Builder(builder: (c) {
          context = c;
          return const SizedBox();
        }),
      ),
    ));
    bool on() => state.flag('dev_mode', fallback: false);
    bool listed() => settingsSectionsOn(SettingsWhere.phone).any((s) => s.id == 'developer' && (s.when?.call(SettingsModel(state)) ?? true));
    expect(listed(), isFalse, reason: 'Developer is hidden until developer mode is on');

    var at = DateTime(2026, 11, 20, 12);
    // Eleven taps, then a pause: the count starts again.
    for (var i = 0; i < 11; i++) {
      versionTapped(context, state, now: at = at.add(const Duration(milliseconds: 300)));
    }
    versionTapped(context, state, now: at = at.add(const Duration(seconds: 3)));
    expect(on(), isFalse);
    for (var i = 0; i < 10; i++) {
      versionTapped(context, state, now: at = at.add(const Duration(milliseconds: 300)));
    }
    expect(on(), isFalse, reason: 'eleven since the pause');
    await tester.pump();
    expect(find.text('One more tap to turn on developer mode.'), findsWidgets);
    versionTapped(context, state, now: at = at.add(const Duration(milliseconds: 300)));
    expect(on(), isTrue);
    expect(listed(), isTrue, reason: 'Developer shows once developer mode is on');
    await tester.pump(const Duration(seconds: 10));
  });
}
