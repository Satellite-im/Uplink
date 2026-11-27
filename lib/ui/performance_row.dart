/// The Performance plugin's row (lib/plugins/performance.dart; Matt, 2026-11-24: "add a performance plugin that adds a
/// small row to the top of the screen just below the titlebar that shows app usage, spikes and a log we can copy"):
/// across the top of the window, under its title bar (under the status bar on a phone), with what the app is using
/// now, a little graph of the last three minutes, how many spikes there have been, Log and Copy.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../perf/app_usage.dart';
import '../plugins/performance.dart';
import '../plugins/registry.dart';
import '../sms.dart' show Sms;
import 'common.dart';
import 'dialup/bevel.dart' show isBevelChrome;
import 'settings_panes.dart' show appVersion;

/// [child] with the row over it while the Performance plugin is on, and [child] alone while it is off. The reading
/// itself ([AppUsage]) runs for exactly as long as the plugin is on.
class PerformanceUnder extends StatefulWidget {
  const PerformanceUnder({super.key, required this.child, required this.navigator, this.statusBar = false, this.usage});
  final Widget child;

  /// The app's navigator: the row stands above it, so the log's page is opened on it.
  final GlobalKey<NavigatorState> navigator;

  /// On a phone: the row goes under the status bar, and the pages below are told that bar is already cleared.
  final bool statusBar;

  /// For a test: the readings to show, in place of the app's own.
  final AppUsage? usage;

  @override
  State<PerformanceUnder> createState() => _PerformanceUnderState();
}

class _PerformanceUnderState extends State<PerformanceUnder> {
  bool _on = false;
  AppUsage get _usage => widget.usage ?? AppUsage.instance;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppState.maybeOf(context);
    final registry = PluginRegistry.instance;
    final plugin = registry.plugins.whereType<PerformancePlugin>().firstOrNull;
    final on = app != null && plugin != null && registry.isOn(plugin, AppStore(app));
    if (on == _on) return;
    _on = on;
    if (on) {
      _usage.about = 'Uplink $appVersion on ${defaultTargetPlatform.name}';
      _usage.start();
    } else {
      _usage.stop();
    }
  }

  @override
  void dispose() {
    if (_on) _usage.stop();
    super.dispose();
  }

  void _openLog() {
    final nav = widget.navigator.currentState;
    if (nav == null) return;
    unawaited(nav.push<void>(PageRouteBuilder<void>(settings: const RouteSettings(name: 'performance-log'), pageBuilder: (context, _, _) => PerformanceLogPage(usage: _usage))));
  }

  @override
  Widget build(BuildContext context) {
    if (!_on) return widget.child;
    final top = widget.statusBar ? MediaQuery.paddingOf(context).top : 0.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // The bar's own ground under the status bar too, so the clock and the battery over it are on the page's colour
      // as they are on every page (bare, that strip was the window's black).
      ColoredBox(color: context.tokens.color('glacier-bg'), child: Padding(padding: EdgeInsets.only(top: top), child: PerformanceRow(usage: _usage, onLog: _openLog))),
      Expanded(child: widget.statusBar ? MediaQuery.removePadding(context: context, removeTop: true, child: widget.child) : widget.child),
    ]);
  }
}

/// Copies [usage]'s log, and says so.
void copyPerformanceLog(BuildContext context, AppUsage usage) {
  unawaited(Clipboard.setData(ClipboardData(text: usage.text())));
  toast(context, 'Performance log copied');
}

/// The row itself: the processor, memory and frames now, the graph, the spikes, Log and Copy. A flat bar the whole
/// width of the window, straight under the title bar, with square corners and a hairline under it (Matt, 2026-11-24:
/// "the performance bar should be under the titlebar without rounded edges"). Its two buttons are the app's own
/// round icon buttons.
class PerformanceRow extends StatelessWidget {
  const PerformanceRow({super.key, required this.usage, required this.onLog});
  final AppUsage usage;
  final VoidCallback onLog;

  /// How tall the bar is: slim on a computer, a little more on a phone so its two buttons can be pressed.
  static const double height = 26;
  static const double touchHeight = 34;
  static double heightOf() => Sms.computer ? height : touchHeight;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: usage,
      builder: (context, _) {
        final high = heightOf();
        final now = usage.last;
        final cpu = now?.cpu;
        final busy = cpu != null && cpu >= AppUsage.spikeAt;
        final quiet = t.color('app-ink-2');
        TextStyle words({Color? color, bool bold = false}) =>
            pageText(t, t.fontSize('xs'), weight: bold ? 'semibold' : 'regular', color: color ?? quiet, mono: true).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
        // Frames a second over the last reading: none while nothing on the screen changes, which is how it should be.
        final seconds = (now == null || now.seen ? AppUsage.every : AppUsage.awayEvery).inSeconds;
        final fps = now == null ? null : (now.frames / seconds).round();
        final memory = now?.memory;
        Widget gap() => SizedBox(width: t.space(3));
        // The app's own round icon buttons, as a page's header has (Matt, 2026-11-24: "the buttons on the performance
        // bar should fit the same standard button shapes we use in the app"), at the bar's size: IconTap, which is
        // Dial-Up's tool button under that look (drawn at its full size there and fitted to the bar).
        final box = high - 6;
        Widget press(String name, LucideIcon icon, String says, VoidCallback onPressed) => SizedBox.square(
              key: ValueKey('perf-$name'),
              dimension: box,
              child: FittedBox(child: IconTap(icon: icon, label: says, onPressed: onPressed, size: isBevelChrome(t) ? 24 : box * 0.6, box: box)),
            );
        return Semantics(
          container: true,
          label: 'Performance',
          child: Container(
            key: const ValueKey('perf-row'),
            height: high,
            padding: EdgeInsets.symmetric(horizontal: t.space(3)),
            decoration: BoxDecoration(color: t.color('glacier-bg'), border: Border(bottom: BorderSide(color: t.color('app-rule'), width: t.len('glacier-hairline')))),
            child: Row(children: [
              AppIcon(Lucide.gauge, size: 13, color: busy ? t.danger : quiet, wash: false),
              SizedBox(width: t.space(2)),
              Text('CPU ${AppUsage.cpuWords(cpu)}', key: const ValueKey('perf-cpu'), style: words(color: busy ? t.danger : t.color('app-ink'), bold: true)),
              if (memory != null) ...[gap(), Text('${(memory / 1048576).round()} MB', style: words())],
              if (fps != null) ...[gap(), Text('$fps fps', style: words())],
              gap(),
              Text('${usage.spikes} ${usage.spikes == 1 ? 'spike' : 'spikes'}', key: const ValueKey('perf-spikes'), style: words(color: usage.spikes > 0 ? t.danger : quiet, bold: usage.spikes > 0)),
              gap(),
              // The processor over the readings kept (three minutes of them), to the top of the row at a whole core.
              Expanded(child: SizedBox(height: high - 10, child: CustomPaint(painter: _Graph([for (final s in usage.history) s.cpu ?? 0], line: t.color('app-accent'), busy: t.danger)))),
              gap(),
              press('Log', Lucide.scrollText, 'Open the performance log', onLog),
              SizedBox(width: t.space(1)),
              press('Copy', Lucide.copy, 'Copy the performance log', () => copyPerformanceLog(context, usage)),
            ]),
          ),
        );
      },
    );
  }
}

/// The readings as bars from the left, newest at the right: a whole core fills the height, and a reading at a spike
/// is drawn in the warning colour.
class _Graph extends CustomPainter {
  _Graph(this.readings, {required this.line, required this.busy});
  final List<double> readings;
  final Color line, busy;

  @override
  void paint(Canvas canvas, Size size) {
    if (readings.isEmpty) return;
    final each = math.min(4.0, size.width / AppUsage.historyMost);
    final from = size.width - readings.length * each;
    for (var i = 0; i < readings.length; i++) {
      final share = (readings[i] / 100).clamp(0.0, 1.0);
      final high = math.max(1.0, share * size.height);
      canvas.drawRect(Rect.fromLTWH(from + i * each, size.height - high, math.max(1.0, each - 1), high), Paint()..color = readings[i] >= AppUsage.spikeAt ? busy : line.withValues(alpha: 0.7));
    }
  }

  @override
  bool shouldRepaint(_Graph old) => !listEquals(old.readings, readings) || old.line != line || old.busy != busy;
}

/// The log as a page: every line, newest at the foot, with Copy and Clear in its header.
class PerformanceLogPage extends StatelessWidget {
  const PerformanceLogPage({super.key, required this.usage});
  final AppUsage usage;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: 'Performance log',
      actions: [
        IconTap(icon: Lucide.copy, label: 'Copy the log', onPressed: () => copyPerformanceLog(context, usage)),
        IconTap(icon: Lucide.x, label: 'Clear the log', onPressed: usage.clear),
      ],
      body: ListenableBuilder(
        listenable: usage,
        builder: (context, _) {
          final lines = usage.log;
          if (lines.isEmpty) {
            return Center(child: Padding(padding: EdgeInsets.all(t.space(6)), child: Text('Nothing yet. A line is written for each spike, and one a minute.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')))));
          }
          // The newest at the foot, and the foot in sight: the list is drawn from its end.
          return ListView.builder(
            key: const ValueKey('perf-log'),
            reverse: true,
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(6) + MediaQuery.paddingOf(context).bottom),
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final line = lines[lines.length - 1 - i];
              final spike = line.contains('Spike:');
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(line, style: pageText(t, t.fontSize('xs'), color: spike ? t.danger : t.color('app-ink'), mono: true, height: 1.35)),
              );
            },
          );
        },
      ),
    );
  }
}
