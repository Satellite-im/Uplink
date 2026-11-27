/// Reports of plugins (Matt, 2026-11-20: "I'd like to be able to verify them for the store through a review process"):
/// what people reported, why, in their words, who (where they chose to say), when, and marking each one dealt with.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/market_api.dart';
import '../../market/market_models.dart';
import '../../market/market_state.dart';
import '../admin_page.dart' show AdminSignIn;
import '../common.dart';
import '../skeleton.dart';
import '../plugins_page/market_parts.dart' show MarketButton, MarketButtonLook;
import 'market_forms.dart';

/// Who sent a report, as the reviewer reads it.
String reporterWords(ReportView r) => r.username == null ? 'No username' : '@${r.username} (${r.verified ? 'verified' : 'not verified'})';

/// The reviewer's list of reports, each with a way to mark it done.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, this.api, this.ask});

  /// The Marketplace: MarketState.instance.api where null, which is Uplink's own (MarketApi.live) in the app.
  final MarketApi? api;

  /// For a test: the relay's answers to the admin sign-in, in place of Me.admin.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late final MarketApi _api = widget.api ?? MarketState.instance.api;
  List<ReportView>? _reports;
  MarketError? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final got = await _api.reports();
      if (!mounted) return;
      setState(() {
        _reports = got;
        _error = null;
      });
    } on MarketError catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Marks [r] dealt with; where the relay wants a fresh admin sign-in, signs in over this page and tries again.
  Future<void> _done(ReportView r) async {
    setState(() => _busy.add(r.rid));
    try {
      await _api.resolveReport(r.rid);
      if (!mounted) return;
      setState(() => _reports = [for (final x in _reports ?? const <ReportView>[]) x.rid == r.rid ? ReportView(rid: x.rid, plugin: x.plugin, version: x.version, reason: x.reason, text: x.text, username: x.username, verified: x.verified, at: x.at, done: true, doneAt: DateTime.now().millisecondsSinceEpoch) : x]);
      toast(context, 'Marked done');
    } on MarketError catch (e) {
      if (!mounted) return;
      if (e.code == 'not_admin') {
        // Signed in here, on a page over this one whose fields the keyboard leaves in sight, and marked done again: as
        // the review screens do, never a way out of the Marketplace to Settings › Admin (D.10; review, 2026-11-20).
        await pushAdminSignIn(context, words: 'The Marketplace wants a fresh admin sign-in for that.', key: const ValueKey('market-reports-signin-sheet'), ask: widget.ask, signedIn: () {
          if (mounted) unawaited(_done(r));
        });
      } else {
        toast(context, e.message, tone: GlacierToastTone.danger);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(r.rid));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final reports = _reports;
    final error = _error;
    Widget row(ReportView r) => SettingRow(
          key: ValueKey('market-report-${r.rid}'),
          icon: AppIcon(r.done ? Lucide.circleCheck : Lucide.flag, size: 18),
          label: '${r.plugin} ${r.version} · ${r.reasonWords}',
          hint: Text([if (r.text.isNotEmpty) r.text, '${reporterWords(r)} · ${marketDate(r.at)}'].join('\n')),
          control: r.done
              ? Text('Done', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))
              : MarketButton(key: ValueKey('market-report-done-${r.rid}'), label: _busy.contains(r.rid) ? 'Marking…' : 'Mark done', look: MarketButtonLook.ring, onPress: _busy.contains(r.rid) ? null : () => unawaited(_done(r))),
        );
    final open = [for (final r in reports ?? const <ReportView>[]) if (!r.done) r];
    final done = [for (final r in reports ?? const <ReportView>[]) if (r.done) r];
    return GhostPage(
      key: const ValueKey('market-reports'),
      title: 'Reports',
      actions: [IconTap(icon: Lucide.refreshCw, label: 'Refresh', onPressed: () => unawaited(_read()))],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          // Signed out (the relay restarted with a deploy, or 8 hours went by): signed in again here, as the queue is,
          // whether the reports were read yet or a Refresh found it so.
          if (error?.code == 'not_admin')
            KeyedSubtree(key: const ValueKey('market-reports-signin'), child: AdminSignIn(ask: widget.ask, onDone: _read))
          else if (reports == null && error?.code == 'unreachable')
            MarketUnreachable(onRetry: () => unawaited(_read()))
          else if (reports == null && error != null)
            MarketBlock(words: error.message)
          else if (reports == null)
            const SkeletonPeople(label: 'Loading', most: 4, shrink: true),
          if (reports != null) ...[
            PaneSection(title: 'Open', children: [
              if (open.isEmpty) SettingRow(key: const ValueKey('market-reports-none'), icon: const AppIcon(Lucide.circleCheck, size: 18), label: 'No reports to read.'),
              for (final r in open) row(r),
            ]),
            if (done.isNotEmpty) ...[
              SizedBox(height: t.space(5)),
              PaneSection(title: 'Done', children: [for (final r in done) row(r)]),
            ],
          ],
        ],
      ),
    );
  }
}
