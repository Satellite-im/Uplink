import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_seen.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/perf/app_usage.dart';
import 'package:ghost_messaging/perf/cpu_reading.dart';
import 'package:ghost_messaging/plugins/performance.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/performance_row.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:glacier/glacier.dart';

/// A device that says what the test tells it to.
class _Source implements CpuSource {
  Duration spent = Duration.zero;
  Map<String, Duration>? byThread;
  int held = 200 * 1048576;
  bool silent = false;

  @override
  Duration? used() => silent ? null : spent;
  @override
  Map<String, Duration>? threads() => byThread == null ? null : Map.of(byThread!);
  @override
  int? memory() => held;
}

// Matt, 2026-11-24: "add a performance plugin that adds a small row to the top of the screen just below the titlebar
// that shows app usage, spikes and a log we can copy".
void main() {
  late _Source device;
  late DateTime clock;
  late AppUsage usage;

  /// Time passes, the device spends [cpu] of it on the app, and a reading is taken.
  void pass(Duration time, {Duration cpu = Duration.zero, bool gap = false}) {
    clock = clock.add(time);
    device.spent += cpu;
    usage.sample(gap: gap);
  }

  setUp(() {
    AppSeen.set(true);
    device = _Source();
    clock = DateTime(2026, 11, 24, 10, 0, 0);
    usage = AppUsage(source: device, now: () => clock);
  });
  tearDown(() {
    usage.stop();
    AppSeen.set(true);
  });

  group('what the app is using', () {
    test('a reading says how much of a core the app used since the one before', () {
      usage.start();
      pass(AppUsage.every, cpu: const Duration(milliseconds: 100));
      expect(usage.last!.cpu, closeTo(5, 0.01), reason: '100 ms of the processor in 2 s is 5% of a core');
      expect(usage.last!.memory, 200 * 1048576);
      pass(AppUsage.every, cpu: const Duration(seconds: 3));
      expect(usage.last!.cpu, closeTo(150, 0.01), reason: 'more than one core at once is more than 100%');
      expect(AppUsage.cpuWords(4.6), '5%');
      expect(AppUsage.cpuWords(0.44), '0.4%');
      expect(AppUsage.cpuWords(null), '–');
    });

    test('a busy stretch is one spike, said as it begins and again as it ends', () {
      usage.start();
      pass(AppUsage.every, cpu: const Duration(milliseconds: 40));
      expect(usage.spikes, 0);
      for (var i = 0; i < 3; i++) {
        pass(AppUsage.every, cpu: const Duration(milliseconds: 1600));
      }
      expect(usage.spikes, 1, reason: 'three busy readings in a row are one spike');
      expect(usage.log.where((l) => l.contains('Spike: The processor at 80% of a core')), hasLength(1));
      pass(AppUsage.every, cpu: const Duration(milliseconds: 60));
      expect(usage.log.last, contains('Back to 3%, after 6 s at 80% on average.'));
      expect(usage.spikes, 1);
    });

    test('a reading that comes late while the app is in sight is the app held up, and a spike', () {
      usage.start();
      pass(AppUsage.every);
      expect(usage.spikes, 0);
      pass(AppUsage.every + const Duration(milliseconds: 1400));
      expect(usage.spikes, 1);
      expect(usage.log.last, contains('held up for 1400 ms'));
      // A lid shut for an hour is not the app held up for an hour.
      pass(const Duration(hours: 1));
      expect(usage.spikes, 1);
      expect(usage.log.last, contains('the device slept'));
      // Put away, a phone holds timers back itself: late there says nothing, nor does the reading on coming back.
      AppSeen.set(false);
      pass(AppUsage.awayEvery + const Duration(seconds: 30));
      AppSeen.set(true);
      pass(AppUsage.every);
      expect(usage.spikes, 1);
      expect(usage.log.any((l) => l.endsWith('Put away.')), isTrue);
      expect(usage.log.any((l) => l.endsWith('Brought back.')), isTrue);
    });

    test('once a minute the log says what the minute came to, with the busiest threads where the device names them', () {
      device.byThread = {'AudioRecordJava': Duration.zero, 'network_thread': Duration.zero, 'idle': Duration.zero};
      usage.start();
      for (var i = 0; i < 30; i++) {
        device.byThread!['AudioRecordJava'] = device.byThread!['AudioRecordJava']! + const Duration(milliseconds: 60);
        device.byThread!['network_thread'] = device.byThread!['network_thread']! + const Duration(milliseconds: 20);
        pass(AppUsage.every, cpu: const Duration(milliseconds: 80));
      }
      final line = usage.log.last;
      expect(line, contains('1 min 0 s: processor 4% of a core on average, 4% at most'));
      expect(line, contains('memory 200 MB'));
      expect(line, contains('threads: AudioRecordJava 3%, network_thread 1%'));
      expect(line, isNot(contains('idle')), reason: 'a thread that did nothing is not listed');
    });

    test('where the device does not say, there is no figure and nothing breaks', () {
      device.silent = true;
      usage.start();
      pass(AppUsage.every);
      expect(usage.last!.cpu, isNull);
      expect(usage.log.first, contains('does not say how much of the processor'));
    });

    test('the log to copy says what it is of, and holds only its newest lines', () {
      usage.about = 'Uplink 0.0.0 on test';
      usage.start();
      for (var i = 0; i < AppUsage.logMost + 40; i++) {
        pass(AppUsage.every + const Duration(seconds: 1));
      }
      expect(usage.log, hasLength(AppUsage.logMost));
      final text = usage.text().split('\n');
      expect(text.first, 'Uplink 0.0.0 on test: performance log');
      expect(text[1], startsWith('Began 2026-11-24 10:00:00; '));
      expect(text.last, usage.log.last);
      usage.clear();
      expect(usage.log, isEmpty);
      expect(usage.spikes, 0);
    });

    test('a thread\'s line from the system is read whatever its name holds', () {
      final t = threadTime('4242 (pool-10 (x) thread) S 1 2 3 4 5 6 7 8 9 10 250 50 0 0 20 0 1 0')!;
      expect(t.name, 'pool-10 (x) thread');
      expect(t.used, const Duration(milliseconds: 3000));
      expect(threadTime('nonsense'), isNull);
    });
  });

  group('the row under the title bar', () {
    late TokenSheet sheet;
    setUpAll(() async {
      sheet = await loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css']);
      installSettingsStyles(sheet);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    });

    /// The app's frame as its own root builds it: the row over the navigator, inside the toasts.
    Future<AppState> draw(WidgetTester tester, {required bool on}) async {
      tester.view.physicalSize = const Size(900, 600) * 2.0;
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final nav = GlobalKey<NavigatorState>();
      final state = AppState();
      if (on) state.set(PluginRegistry.switchKey(const PerformancePlugin()), 'on');
      await tester.pumpWidget(AppScope(
        state: state,
        child: WidgetsApp(
          color: const Color(0xFF4F5BD5),
          navigatorKey: nav,
          debugShowCheckedModeBanner: false,
          pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (context, child) => ListenableBuilder(
            listenable: state,
            builder: (context, _) => GlacierTheme(
              sheet: sheet,
              attrs: ghostAttrs(state, 'desktop'),
              typography: ghostTypography('noto'),
              child: InkOverrides(child: GlacierToastProvider(child: PerformanceUnder(navigator: nav, usage: usage, child: child!))),
            ),
          ),
          home: const Center(child: Text('the app')),
        ),
      ));
      await tester.pump();
      return state;
    }

    testWidgets('is not there while the plugin is off, and nothing is read', (tester) async {
      await draw(tester, on: false);
      expect(find.byKey(const ValueKey('perf-row')), findsNothing);
      expect(find.text('the app'), findsOneWidget);
      expect(usage.running, isFalse);
    });

    testWidgets('is at the top with the app under it while the plugin is on; switched off it goes, and the reading stops', (tester) async {
      final state = await draw(tester, on: true);
      expect(usage.running, isTrue);
      final row = tester.getRect(find.byKey(const ValueKey('perf-row')));
      expect(row.top, 0);
      expect(row.height, PerformanceRow.heightOf());
      expect(row.left, 0);
      expect(row.width, 900, reason: 'the whole width of the window, flush under the title bar');
      // Square: the bar itself has no rounded edges, and nothing clips it round.
      final bar = find.byKey(const ValueKey('perf-row'));
      expect((tester.widget<Container>(bar).decoration! as BoxDecoration).borderRadius, isNull);
      expect((tester.widget<Container>(bar).decoration! as BoxDecoration).shape, BoxShape.rectangle);
      // Its buttons are the app's own round icon buttons, inside the bar.
      expect(find.descendant(of: bar, matching: find.byType(IconTap)), findsNWidgets(2));
      for (final name in ['Log', 'Copy']) {
        final at = tester.getRect(find.byKey(ValueKey('perf-$name')));
        expect(at.top, greaterThanOrEqualTo(row.top), reason: '$name inside the bar');
        expect(at.bottom, lessThanOrEqualTo(row.bottom), reason: '$name inside the bar');
      }
      expect(find.descendant(of: bar, matching: find.byType(ClipRRect)), findsNothing);
      expect(tester.getRect(find.text('the app')).top, greaterThanOrEqualTo(row.bottom), reason: 'the app is under the row, not behind it');
      pass(AppUsage.every, cpu: const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('CPU 5%'), findsOneWidget);
      expect(find.text('200 MB'), findsOneWidget);
      expect(find.text('0 spikes'), findsOneWidget);
      pass(AppUsage.every, cpu: const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('CPU 100%'), findsOneWidget);
      expect(find.text('1 spike'), findsOneWidget);
      state.set(PluginRegistry.switchKey(const PerformancePlugin()), 'off');
      await tester.pump();
      expect(find.byKey(const ValueKey('perf-row')), findsNothing);
      expect(usage.running, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Copy puts the log on the clipboard, and Log opens it as a page', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await draw(tester, on: true);
      pass(AppUsage.every, cpu: const Duration(seconds: 2));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('perf-Copy')));
      await tester.pump();
      expect(copied, contains('performance log'));
      expect(copied, contains('Spike: The processor at 100% of a core.'));
      await tester.tap(find.byKey(const ValueKey('perf-Log')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Performance log'), findsOneWidget);
      expect(find.textContaining('Spike: The processor at 100% of a core.'), findsOneWidget);
      expect(find.byKey(const ValueKey('perf-row')), findsOneWidget, reason: 'the row stays over the log\'s page');
      expect(tester.takeException(), isNull);
      // Let the toast go.
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
