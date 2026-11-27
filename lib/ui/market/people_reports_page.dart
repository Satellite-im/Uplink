/// Reports of people and messages, as the reviewer reads them (GMFB-40, from the Uplink gap review: "Report a user or
/// message"): the relay hands over envelopes it can't read (relay/lib/market.dart route 24); this device opens each with
/// its own identity's key, which must be a review key the reports were sealed to (lib/plugins/pack/review_keys.dart),
/// and checks the reporter's signature. Each is marked done on the relay (route 25).
///
/// Settings › Admin › Reports of people, and the review queue's row of the same name.
library;

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/market_api.dart';
import '../../market/market_models.dart';
import '../../market/market_state.dart';
import '../../net/crypto.dart';
import '../../safety/abuse_report.dart';
import '../../sms.dart';
import '../admin_page.dart' show AdminSignIn;
import '../common.dart';
import '../skeleton.dart';
import '../plugins_page/market_parts.dart' show MarketButton, MarketButtonLook;
import 'market_forms.dart';
import '../../l10n/words.dart';

/// One row: as the relay keeps it, and as it opened here (null where it isn't sealed to this device's key, or was
/// changed on the way).
class PeopleReport {
  const PeopleReport(this.row, this.opened);
  final SealedReportRow row;
  final OpenedReport? opened;
}

/// This device's identity's key pair: what reports are opened with. The app's asks the phone, or this computer where it
/// is the same you; a test gives its own.
typedef ReviewerKeys = Future<NetKeys> Function();

/// The app's own [ReviewerKeys].
Future<NetKeys> reviewerKeysLive() async => NetKeys.fromScalar(await Sms.instance.identityExport());

/// [rows] opened with [keys].
List<PeopleReport> openAll(List<SealedReportRow> rows, NetKeys keys) => [for (final r in rows) PeopleReport(r, openReport(r.sealed, keys))];

/// The list: reports still open, then those marked done. Asks for the admin sign-in where the relay wants one.
class PeopleReportsScreen extends StatefulWidget {
  const PeopleReportsScreen({super.key, this.api, this.ask, this.keys});

  /// The Marketplace: MarketState.instance.api where null.
  final MarketApi? api;

  /// For a test: the relay's answers to the admin sign-in, in place of Me.admin.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask;

  final ReviewerKeys? keys;

  @override
  State<PeopleReportsScreen> createState() => _PeopleReportsScreenState();
}

class _PeopleReportsScreenState extends State<PeopleReportsScreen> {
  late final MarketApi _api = widget.api ?? MarketState.instance.api;
  List<PeopleReport>? _reports;
  MarketError? _error;
  String? _keyError;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  /// Reads the sealed rows from the relay and opens each with this device's key. A key that can't be read is said
  /// apart from the relay's own errors: nothing can be opened without it.
  Future<void> _read() async {
    try {
      final rows = await _api.sealedReports();
      NetKeys keys;
      try {
        keys = await (widget.keys ?? reviewerKeysLive)();
      } catch (e) {
        if (mounted) setState(() => _keyError = 'This device\'s key couldn\'t be read, so no report can be opened here: $e');
        return;
      }
      if (!mounted) return;
      setState(() {
        _reports = openAll(rows, keys);
        _error = null;
        _keyError = null;
      });
    } on MarketError catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Marks [r] done on the relay and in the list here. Where the relay wants a fresh admin sign-in, asks for it and
  /// tries again once signed in.
  Future<void> _done(PeopleReport r) async {
    setState(() => _busy.add(r.row.rid));
    try {
      await _api.resolveSealedReport(r.row.rid);
      if (!mounted) return;
      final x = r.row;
      setState(() => _reports = [
            for (final y in _reports ?? const <PeopleReport>[])
              y.row.rid == x.rid ? PeopleReport(SealedReportRow(rid: x.rid, sealed: x.sealed, at: x.at, done: true, doneAt: DateTime.now().millisecondsSinceEpoch), y.opened) : y,
          ]);
      toast(context, 'Marked done');
    } on MarketError catch (e) {
      if (!mounted) return;
      if (e.code == 'not_admin') {
        await pushAdminSignIn(context, words: 'The Marketplace wants a fresh admin sign-in for that.', key: const ValueKey('people-reports-signin-sheet'), ask: widget.ask, signedIn: () {
          if (mounted) unawaited(_done(r));
        });
      } else {
        toast(context, e.message, tone: GlacierToastTone.danger);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(r.row.rid));
    }
  }

  /// One report's row: who and why, with Mark done. One that didn't open here says so and can't be read further.
  Widget _row(PeopleReport r) {
    final t = context.tokens;
    final o = r.opened;
    final busy = _busy.contains(r.row.rid);
    final control = r.row.done
        ? Text('Done', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))
        : MarketButton(key: ValueKey('people-report-done-${r.row.rid}'), label: busy ? 'Marking…' : 'Mark done', look: MarketButtonLook.ring, onPress: busy ? null : () => unawaited(_done(r)));
    if (o == null) {
      return SettingRow(
        key: ValueKey('people-report-${r.row.rid}'),
        icon: AppIcon(Lucide.lock, size: 18, color: t.color('app-ink-3')),
        label: 'Can\'t be opened on this device',
        hint: Text('Sealed to another review key, or changed on the way · ${marketDate(r.row.at)}'),
        control: control,
      );
    }
    final rep = o.report;
    final who = rep.subjectUsername.isNotEmpty ? '@${rep.subjectUsername}' : (rep.subjectName.isNotEmpty ? rep.subjectName : 'someone');
    return SettingRow(
      key: ValueKey('people-report-${r.row.rid}'),
      icon: AppIcon(r.row.done ? Lucide.circleCheck : Lucide.flag, size: 18, color: r.row.done ? null : t.danger),
      label: '$who · ${rep.reason.label}',
      hint: Text([if (rep.note.isNotEmpty) rep.note, '${rep.isMessage ? 'A message' : 'The person'} · ${_whereOf(rep)} · ${marketDate(r.row.at)}'].join('\n'), maxLines: 3, overflow: TextOverflow.ellipsis),
      control: control,
      onPress: () => unawaited(push<void>(context, (_) => PeopleReportScreen(report: r))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final reports = _reports;
    final error = _error;
    final open = [for (final r in reports ?? const <PeopleReport>[]) if (!r.row.done) r];
    final done = [for (final r in reports ?? const <PeopleReport>[]) if (r.row.done) r];
    return GhostPage(
      key: const ValueKey('people-reports'),
      title: 'Reports of people',
      actions: [IconTap(icon: Lucide.refreshCw, label: 'Refresh', onPressed: () => unawaited(_read()))],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          if (error?.code == 'not_admin')
            KeyedSubtree(key: const ValueKey('people-reports-signin'), child: AdminSignIn(ask: widget.ask, onDone: _read))
          else if (_keyError != null)
            MarketBlock(words: _keyError!)
          else if (reports == null && error?.code == 'unreachable')
            MarketUnreachable(onRetry: () => unawaited(_read()))
          else if (reports == null && error != null)
            MarketBlock(words: error.message)
          else if (reports == null)
            const SkeletonPeople(label: 'Loading', most: 4, shrink: true),
          if (reports != null) ...[
            PaneSection(
              title: 'Open',
              description: const Tr('Opened here with this device\'s review key: the relay keeps them sealed and never sees what they say.'),
              children: [
                if (open.isEmpty) const SettingRow(key: ValueKey('people-reports-none'), icon: AppIcon(Lucide.circleCheck, size: 18), label: 'No reports to read.'),
                for (final r in open) _row(r),
              ],
            ),
            if (done.isNotEmpty) ...[
              SizedBox(height: t.space(5)),
              PaneSection(title: 'Done', children: [for (final r in done) _row(r)]),
            ],
          ],
        ],
      ),
    );
  }
}

/// Where what was reported happened, in the reviewer's words.
String _whereOf(AbuseReport r) => switch (r.place) {
      'space' => r.placeName.isEmpty ? 'a space' : 'space ${r.placeName}',
      'chat' => r.placeName.isEmpty ? 'a chat' : 'chat ${r.placeName}',
      _ => 'their profile',
    };

/// A date and the time of day, in this device's time, from milliseconds since 1970.
String _time(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${marketDate(ms)} ${two(d.hour)}:${two(d.minute)}';
}

/// One report, whole: who and why, the note, where, the messages that came with it, and who sent it.
class PeopleReportScreen extends StatelessWidget {
  const PeopleReportScreen({super.key, required this.report});
  final PeopleReport report;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final o = report.opened!;
    final r = o.report;
    final gap = SizedBox(height: t.space(5));
    void copy(String words) {
      unawaited(Clipboard.setData(ClipboardData(text: words)));
      toast(context, 'Copied');
    }

    return GhostPage(
      key: ValueKey('people-report-page-${report.row.rid}'),
      title: r.isMessage ? 'Reported message' : 'Reported person',
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          PaneSection(title: 'Who', children: [
            SettingRow(icon: const AppIcon(Lucide.userRound, size: 18), label: r.subjectUsername.isNotEmpty ? '@${r.subjectUsername}' : (r.subjectName.isEmpty ? 'Unknown' : r.subjectName), hint: Text([if (r.subjectName.isNotEmpty) r.subjectName, if (r.subjectId.isNotEmpty) 'Uplink id ${r.subjectId}'].join(' · ')), onPress: r.subjectId.isEmpty ? null : () => copy(r.subjectId)),
            SettingRow(icon: const AppIcon(Lucide.flag, size: 18), label: r.reason.label, hint: Text(r.note.isEmpty ? 'No note' : r.note)),
            SettingRow(icon: const AppIcon(Lucide.messageSquare, size: 18), label: _whereOf(r), hint: Text('Reported ${_time(r.at)}')),
          ]),
          if (r.messages.isNotEmpty) ...[
            gap,
            PaneSection(
              title: 'What came with it',
              description: const Tr('Handed over by the reporter: the message reported is flagged, the rest were said round it.'),
              children: [
                for (final m in r.messages)
                  SettingRow(
                    icon: AppIcon(m.reported ? Lucide.flag : Lucide.messageSquare, size: 16, color: m.reported ? t.danger : t.color('app-ink-3')),
                    label: '${m.mine ? '${m.name} (the reporter)' : m.name} · ${_time(m.at)}',
                    hint: Text(m.text.isEmpty ? '(no words)' : m.text),
                    onPress: () => copy(m.text),
                  ),
              ],
            ),
          ],
          gap,
          PaneSection(title: 'Sent by', children: [
            SettingRow(
              icon: AppIcon(o.verified ? Lucide.circleCheck : Lucide.circle, size: 18),
              label: r.reporterUsername.isNotEmpty ? '@${r.reporterUsername}' : 'No username',
              hint: Text('Uplink id ${o.reporterId} · ${o.verified ? 'their signature checks out' : 'their signature does NOT check out'}${r.platform.isEmpty ? '' : ' · ${r.platform} ${r.version}'}'),
              onPress: () => copy(o.reporterId),
            ),
          ]),
        ],
      ),
    );
  }
}
