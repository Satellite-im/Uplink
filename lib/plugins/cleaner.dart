/// Cleaner: deletes whole conversations by what the list sorted them as, in bulk, showing how far it has got as it
/// goes (Matt, 2026-11-14: "add a "Cleaner" plugin that allows us to bulk delete messages by category and shows
/// deletion progress in real time").
///
/// A button in the list's header opens a sheet of the list's groups: Codes, Spam, each kind of text, and Personal &
/// other, each with how many conversations it has. Nothing is ticked to begin with. Ticked ones are deleted after a
/// second press that says it cannot be undone, one conversation at a time, with a bar and a count that move as each
/// goes, and a Stop that leaves the rest. Archived conversations are never in it. Deleting is Android's: the
/// conversations go from the phone for every app.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'plugin.dart';
import '../kit/semantic_colors.dart';

class CleanerPlugin extends GhostPlugin {
  const CleanerPlugin();

  @override
  String get id => 'cleaner';

  @override
  String get name => 'Cleaner';

  @override
  String get description => 'Delete conversations in bulk by kind: spam, codes, sales, deliveries and the rest.';

  @override
  LucideIcon get icon => LucideMore.brushCleaning;

  // Its card and page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page
  // with a marketplace like look how ghostmd has").
  @override
  PluginShelf get shelf => PluginShelf.organise;

  // Its tags in the Marketplace, so a search by tag finds it beside the plugins from other developers (Matt, 2026-11-20:
  // "plugin tags").
  @override
  List<String> get labels => const ['sorting'];

  @override
  String get tagline => 'Delete conversations in bulk, by kind.';

  @override
  List<String> get adds => const ['A brush in the list\'s header: tick the kinds to delete'];

  @override
  List<PluginReach> get reaches => const [PluginReach(Lucide.trash2, 'Deletes whole conversations from the phone', 'Only the kinds you tick, after you say yes. It can\'t be undone.')];

  @override
  bool get onByDefault => true;

  @override
  List<SlotFill> get slots => [
        Slots.listHeader.fill((place, prefs) {
          // Only while there is something to clean: a kind besides personal texts (Matt, 2026-11-19, of hiding the brush
          // when there's nothing to clean: "Yes, hide it"). Personal conversations alone are not cleaned in bulk.
          if (place.section != null || !place.groups.any((g) => g.id != ListGroup.othersId) || !Sms.can('deleteThreads')) return const [];
          return [
            PluginAction(
              label: 'Clean up',
              icon: LucideMore.brushCleaning,
              // Matt, 2026-11-14: "I wan the cleanup brush to be more subdued".
              quiet: true,
              run: (host) => host.present((context) => CleanerSheet(groups: place.groups, delete: host.deleteThread, reload: host.reload)),
            ),
          ];
        }),
      ];

  @override
  PluginSettingsPage? get settingsPage => PluginSettingsPage(hue: 'mint', intro: 'Delete conversations in bulk, by kind.', summary: (prefs) => 'From the list\'s header');

  @override
  List<PluginSetting> get settings => const [
        PluginSetting.note(label: 'Where it is', hint: 'The brush in the list\'s header. Tick the kinds to delete, press Delete, and say yes.', icon: LucideMore.brushCleaning),
        PluginSetting.note(label: 'What it deletes', hint: 'Whole conversations, from the phone, for every app. It can\'t be undone. Archived conversations are left alone.', icon: Lucide.trash2),
      ];
}

/// Where the sheet stands: choosing, asked to be sure, deleting, or done.
enum CleanerStep { choose, confirm, deleting, done }

/// The Cleaner's sheet. [delete] deletes one conversation; [reload] reads the list again as it goes and at the end.
class CleanerSheet extends StatefulWidget {
  const CleanerSheet({super.key, required this.groups, required this.delete, required this.reload});
  final List<ListGroup> groups;
  final Future<void> Function(int thread) delete;
  final Future<void> Function() reload;

  @override
  State<CleanerSheet> createState() => CleanerSheetState();
}

class CleanerSheetState extends State<CleanerSheet> {
  final Set<String> _ticked = {};
  CleanerStep step = CleanerStep.choose;
  int done = 0, failed = 0, total = 0;
  bool _stop = false;
  String? _now;

  List<int> get _threads => [
        for (final g in widget.groups)
          if (_ticked.contains(g.id)) ...g.threads,
      ];

  static String _count(int n) => n == 1 ? '1 conversation' : '$n conversations';

  /// Deletes the ticked groups' conversations one at a time, each once though two groups hold it, counting what went
  /// and what failed; stops where the person says so or the sheet closes.
  Future<void> _run() async {
    final threads = _threads.toSet().toList();
    final label = {for (final g in widget.groups) for (final t in g.threads) t: g.label};
    setState(() {
      step = CleanerStep.deleting;
      total = threads.length;
      done = 0;
      failed = 0;
      _stop = false;
    });
    for (final t in threads) {
      if (_stop || !mounted) break;
      setState(() => _now = label[t]);
      try {
        await widget.delete(t);
        done++;
      } catch (_) {
        failed++;
      }
      // The list behind catches up every so often, so what is gone goes from it as the bar moves.
      if ((done + failed) % 10 == 0) await widget.reload();
      if (mounted) setState(() {});
    }
    await widget.reload();
    if (mounted) setState(() => step = CleanerStep.done);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final n = _threads.toSet().length;
    final red = t.danger;
    Text words(String s, {String size = 'sm', String weight = 'regular', Color? color, int lines = 4}) =>
        Text(s, maxLines: lines, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize(size), weight: weight, color: color ?? t.color('app-ink'), height: 1.35));

    Widget button(String label, VoidCallback? onPress, {bool danger = false, bool quiet = false}) => GlacierPressable(
          onPressed: onPress,
          semanticLabel: label,
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(3)),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: onPress == null
                  ? t.color('app-paper-3')
                  : quiet
                      ? t.color(state.pressed ? 'app-paper-3' : 'app-paper')
                      : danger
                          ? red.withValues(alpha: state.pressed ? 0.85 : 1)
                          : t.color('app-accent'),
              borderRadius: BorderRadius.circular(t.radius('full')),
              border: quiet ? Border.all(color: t.color('app-rule')) : null,
            ),
            child: Text(label,
                style: pageText(t, t.fontSize('sm'),
                    weight: 'semibold',
                    color: onPress == null
                        ? t.color('app-ink-4')
                        : quiet
                            ? t.color('app-ink')
                            : danger
                                ? const Color(0xFFFFFFFF)
                                : t.color('app-on-accent'))),
          ),
        );

    final List<Widget> body = switch (step) {
      CleanerStep.choose => [
          words('Clean up', size: 'lg', weight: 'bold'),
          SizedBox(height: t.space(1)),
          words('Tick the kinds of conversation to delete. They go from this phone for every app.', color: t.color('app-ink-3')),
          SizedBox(height: t.space(3)),
          for (final g in widget.groups)
            GlacierPressable(
              onPressed: () => setState(() => _ticked.contains(g.id) ? _ticked.remove(g.id) : _ticked.add(g.id)),
              semanticLabel: '${g.label}, ${_count(g.threads.length)}, ${_ticked.contains(g.id) ? 'ticked' : 'not ticked'}',
              builder: (context, state) => Container(
                padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(3)),
                decoration: BoxDecoration(color: state.pressed ? t.color('app-paper-3') : null, borderRadius: BorderRadius.circular(t.radius('md'))),
                child: Row(children: [
                  AppIcon(g.icon, size: 18, color: t.color('app-ink')),
                  SizedBox(width: t.space(3)),
                  Expanded(child: words(g.label, lines: 1, weight: 'medium')),
                  words('${g.threads.length}', color: t.color('app-ink-3'), lines: 1),
                  SizedBox(width: t.space(3)),
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: _ticked.contains(g.id) ? t.color('app-accent') : null,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _ticked.contains(g.id) ? t.color('app-accent') : t.color('app-ink-4'), width: 1.5),
                    ),
                    alignment: Alignment.center,
                    child: _ticked.contains(g.id) ? AppIcon(Lucide.check, size: 14, strokeWidth: 3, color: t.color('app-on-accent'), wash: false) : null,
                  ),
                ]),
              ),
            ),
          SizedBox(height: t.space(3)),
          Row(children: [
            Expanded(child: button('Cancel', () => Navigator.of(context).pop(), quiet: true)),
            SizedBox(width: t.space(2)),
            Expanded(child: button(n == 0 ? 'Delete' : 'Delete ${_count(n)}', n == 0 ? null : () => setState(() => step = CleanerStep.confirm), danger: true)),
          ]),
        ],
      CleanerStep.confirm => [
          words('Delete ${_count(n)}?', size: 'lg', weight: 'bold'),
          SizedBox(height: t.space(1)),
          words(
              'Every message in ${n == 1 ? 'it' : 'them'} is deleted from this phone, for every app: ${[for (final g in widget.groups) if (_ticked.contains(g.id)) g.label].join(', ')}. This can\'t be undone.',
              color: t.color('app-ink-3'),
              lines: 8),
          SizedBox(height: t.space(4)),
          Row(children: [
            Expanded(child: button('Back', () => setState(() => step = CleanerStep.choose), quiet: true)),
            SizedBox(width: t.space(2)),
            Expanded(child: button('Delete', _run, danger: true)),
          ]),
        ],
      CleanerStep.deleting => [
          words('Deleting ${done + failed + (done + failed < total ? 1 : 0)} of $total', size: 'lg', weight: 'bold'),
          SizedBox(height: t.space(1)),
          words(_now ?? '', color: t.color('app-ink-3'), lines: 1),
          SizedBox(height: t.space(3)),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Container(
              height: 8,
              color: t.color('app-paper-3'),
              alignment: AlignmentDirectional.centerStart,
              // As far along as the deleting is, sliding as each one goes.
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 180),
                alignment: AlignmentDirectional.centerStart,
                heightFactor: 1,
                widthFactor: total == 0 ? 0 : ((done + failed) / total).clamp(0.0, 1.0),
                child: ColoredBox(color: red),
              ),
            ),
          ),
          SizedBox(height: t.space(2)),
          words('$done deleted${failed > 0 ? ' · $failed couldn\'t be' : ''}', color: t.color('app-ink-3'), lines: 1),
          SizedBox(height: t.space(4)),
          button(_stop ? 'Stopping…' : 'Stop', _stop ? null : () => setState(() => _stop = true), quiet: true),
        ],
      CleanerStep.done => [
          words(_stop && done < total ? 'Stopped' : 'Done', size: 'lg', weight: 'bold'),
          SizedBox(height: t.space(1)),
          words('${_count(done)} deleted${failed > 0 ? ', $failed couldn\'t be' : ''}${_stop && done + failed < total ? ', ${total - done - failed} left as they were' : ''}.', color: t.color('app-ink-3')),
          SizedBox(height: t.space(4)),
          button('Done', () => Navigator.of(context).pop()),
        ],
    };

    return PopScope(
      // Not closed by Android's back while it is deleting: Stop is the way to end it early.
      canPop: step != CleanerStep.deleting,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: t.lenOf('30rem'), maxHeight: MediaQuery.sizeOf(context).height - pad.top - pad.bottom - t.space(8)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.radius('xl')),
              child: ColoredBox(
                color: t.color('app-paper-2'),
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(t.space(4)),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: body),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
