/// The review queue (Matt, 2026-11-20: "I'd like to be able to verify them for the store through a review process"): what
/// waits for review, what is being reviewed, what waits on its developer's changes and what was decided lately, each
/// with who sent it and what to look at first (a new plugin or an update, sent again after a note, what it can now do
/// that its listed version can't, an unverified or blocked developer), and the reports.
///
/// In Settings › Admin and in Marketplace › Review queue alike. Where the relay has signed the admin out it signs in
/// right here, never by a link that takes the Marketplace away.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../market/market_api.dart';
import '../../market/market_models.dart';
import '../../market/market_state.dart';
import '../../me/me.dart' show MeError;
import '../admin_page.dart' show AdminSignIn;
import '../common.dart';
import '../skeleton.dart';
import '../plugins_page/plugin_art.dart';
import 'market_forms.dart';
import 'people_reports_page.dart';
import 'reports_page.dart';
import 'review_item.dart';

/// The second line of a queue's row: new or an update (from the version listed), then what to look at first.
String reviewRowHint(ReviewRow r, {String? current}) => [
      r.isUpdate ? (current == null ? 'Update' : 'Update from $current') : 'New plugin',
      if (r.again) 'sent again after changes',
      if (r.newPermissions.isNotEmpty) 'can now: ${r.newPermissions.join(', ')}',
      if (!r.verified) 'developer not verified',
      if (r.blocked) 'developer blocked',
    ].join(' · ');

/// The queue's page: its submissions in groups by where they stand, each opening its review, and the reports.
class ReviewQueueScreen extends StatefulWidget {
  const ReviewQueueScreen({super.key, this.api, this.ask});

  /// The Marketplace: MarketState.instance.api where null, which is Uplink's own (MarketApi.live) in the app.
  final MarketApi? api;

  /// For a test: the relay's answers to the admin sign-in, in place of Me.admin.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask;

  @override
  State<ReviewQueueScreen> createState() => _ReviewQueueScreenState();
}

class _ReviewQueueScreenState extends State<ReviewQueueScreen> {
  late final MarketApi _api = widget.api ?? MarketState.instance.api;
  ReviewQueue? _queue;
  bool _loading = true;
  MarketError? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  /// Route 14: the queue, or why not. The Marketplace's own row hears how many wait.
  Future<MarketError?> _read() async {
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    MarketError? error;
    ReviewQueue? got;
    try {
      got = await _api.reviewQueue();
      MarketState.instance.reviewQueueRead(got.waiting);
    } on MarketError catch (e) {
      error = e;
    } catch (_) {
      error = const MarketError('unreachable', marketUnreachableWords);
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _error = error;
        if (got != null) _queue = got;
      });
    }
    return error;
  }

  /// Signed in on the sign-in drawn here: the queue read again, and said under the fields if the relay still wants one.
  Future<void> _signedIn() async {
    final still = await _read();
    if (still?.code == 'not_admin') throw MeError(still!.message);
  }

  String? _currentOf(ReviewQueue q, String plugin) =>
      [...q.recent, ...q.open].where((r) => r.plugin == plugin && r.status == 'approved' && r.view.listing != null && r.view.revokedAt == null).firstOrNull?.version ?? MarketState.instance.catalog?.plugins.where((e) => e.id == plugin).firstOrNull?.version;

  Future<void> _open(ReviewRow r) async {
    await push<void>(context, (_) => ReviewItemScreen(r.sid, api: _api, ask: widget.ask));
    if (mounted) unawaited(_read());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = SizedBox(height: t.space(5));
    final q = _queue;
    final error = _error;
    final children = <Widget>[];
    if (error?.code == 'no_identity') {
      children.add(MarketBlock(key: const ValueKey('market-review-who'), words: error!.message, icon: Lucide.keyRound));
    } else if (error?.code == 'not_admin') {
      children.add(KeyedSubtree(key: const ValueKey('market-review-signin'), child: AdminSignIn(ask: widget.ask, onDone: _signedIn)));
    } else if (error?.code == 'unreachable' && q == null) {
      children.add(MarketUnreachable(onRetry: () => unawaited(_read())));
    } else if (error != null && q == null) {
      children.add(MarketBlock(words: error.message));
    } else if (q == null) {
      children.add(const SkeletonPeople(label: 'Loading', most: 4, shrink: true));
    } else {
      Widget row(ReviewRow r, {bool decided = false}) => SettingRow(
            key: ValueKey('market-review-${r.sid}'),
            icon: PluginTile(plugin: MarketFace.of(r.view), size: t.lenOf('1.85rem')),
            label: '${r.name.ifEmpty(r.plugin)} ${r.version} · @${r.developer ?? '?'}',
            hint: Text(decided ? '${submissionStatusWords(r.view)} · ${reviewRowHint(r, current: _currentOf(q, r.plugin))}' : reviewRowHint(r, current: _currentOf(q, r.plugin))),
            value: Text(marketDate(decided ? r.view.updatedAt : r.view.submittedAt)),
            onPress: () => unawaited(_open(r)),
          );
      final groups = [
        ('Waiting', [for (final r in q.open) if (r.status == 'submitted') r]),
        ('In review', [for (final r in q.open) if (r.status == 'in_review') r]),
        ('Changes asked for', [for (final r in q.open) if (r.status == 'changes_requested') r]),
      ];
      if (q.open.isEmpty) {
        children.addAll([PaneSection(children: [SettingRow(key: const ValueKey('market-review-empty'), icon: const AppIcon(Lucide.circleCheck, size: 18), label: 'Nothing waits for review.')]), gap]);
      }
      for (final (title, rows) in groups) {
        if (rows.isEmpty) continue;
        children.addAll([PaneSection(title: title, children: [for (final r in rows) row(r)]), gap]);
      }
      children.addAll([
        PaneSection(children: [
          SettingRow(key: const ValueKey('market-review-reports'), icon: const AppIcon(Lucide.flag, size: 18), label: 'Reports · ${q.reports} open', onPress: () => unawaited(push<void>(context, (_) => ReportsScreen(api: _api, ask: widget.ask)))),
          // Reports of people and messages (GMFB-40), sealed to this device's key.
          SettingRow(key: const ValueKey('market-review-people-reports'), icon: const AppIcon(Lucide.userRound, size: 18), label: 'Reports of people · ${q.abuse} open', onPress: () => unawaited(push<void>(context, (_) => PeopleReportsScreen(api: _api, ask: widget.ask)))),
        ]),
        gap,
      ]);
      if (q.recent.isNotEmpty) children.add(PaneSection(title: 'Decided lately', children: [for (final r in q.recent) row(r, decided: true)]));
      if (error != null) children.insertAll(0, [PaneSection(children: [SettingRow(icon: const AppIcon(Lucide.globe, size: 18), label: error.message)]), gap]);
    }
    return GhostPage(
      key: const ValueKey('market-review'),
      title: 'Review queue',
      actions: [IconTap(key: const ValueKey('market-review-refresh'), icon: Lucide.refreshCw, label: 'Refresh', onPressed: _loading ? null : () => unawaited(_read()))],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: children,
      ),
    );
  }
}
