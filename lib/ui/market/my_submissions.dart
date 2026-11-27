/// My submissions (Matt, 2026-11-20: "I would like users to be able to develop and submit their own plugins to our plugin
/// marketplace and I'd like to be able to verify them for the store through a review process", and "a listing process"):
/// each plugin a developer has sent, whether it is listed, taking it off the Marketplace and listing it again, and each
/// version sent with where its review stands, the reviewer's notes, what it can do, its screenshots, withdrawing it,
/// sending a new version and copying its package.
///
/// Read from route 9 each time it is opened; a developer hears of a decision without opening it too (MarketState's
/// toasts from mine.json).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
import '../../net/net.dart';
import '../../plugins/pack/pack.dart';
import '../common.dart';
import '../skeleton.dart';
import '../plugins_page/plugin_art.dart';
import '../settings_panes.dart' show appVersion;
import '../shell.dart';
import 'market_forms.dart';
import 'submit_screen.dart';
import '../../l10n/words.dart';

/// A plugin's place in the Marketplace, as its heading says it.
String listingWords(PluginState? p) => switch (p?.listing) {
      'listed' => 'Listed',
      'unlisted' => 'Approved, not listed',
      _ => 'Not listed',
    };

/// The version "Submit a new version" starts at, from [s]: one higher in its last part where it was approved, the same
/// where changes were asked for (or it wasn't taken), and in any case higher than [current], the version listed.
String resubmitVersion(SubmissionView s, {String? current}) {
  var v = s.status == 'approved' ? nextVersion(s.version) : s.version;
  if (current != null) {
    try {
      if (compareVersions(v, current) <= 0) v = nextVersion(current);
    } on FormatException {
      // Not versions: left as it is, for the form to say.
    }
  }
  return v;
}

/// Marketplace › My submissions: a section for each plugin sent, with its listing and a row for each version.
class MySubmissionsScreen extends StatefulWidget {
  const MySubmissionsScreen({super.key, this.api, this.highlight, this.market, this.hub});

  /// The Marketplace: MarketState.instance.api where null, which is Uplink's own (MarketApi.live) in the app.
  final MarketApi? api;

  /// A submission to mark and scroll to: the one just sent.
  final String? highlight;
  final MarketState? market;

  /// The server this app uses (Net.instance.hubUrl where null): a test's other server.
  final String? hub;

  @override
  State<MySubmissionsScreen> createState() => _MySubmissionsScreenState();
}

class _MySubmissionsScreenState extends State<MySubmissionsScreen> {
  MarketState get _market => widget.market ?? MarketState.instance;
  late final MarketApi _api = widget.api ?? _market.api;
  MyMarket? _mine;
  bool _loading = true;
  bool _unreachable = false;
  String? _failed;
  final _marked = GlobalKey();
  bool _scrolled = false;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    if (_api.signer != null) unawaited(_read());
  }

  /// Reads what this developer has sent, and tells [MarketState] it was seen so its decisions aren't toasted again.
  Future<void> _read() async {
    setState(() {
      _loading = true;
      _unreachable = false;
      _failed = null;
    });
    try {
      final got = await _api.mine();
      unawaited(_market.seenMine(got));
      if (!mounted) return;
      setState(() {
        _mine = got;
        _loading = false;
      });
    } on MarketError catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unreachable = e.code == 'unreachable';
        _failed = e.code == 'unreachable' ? null : e.message;
      });
    }
  }

  /// Lists the plugin again, or takes it off the Marketplace once that is confirmed.
  Future<void> _setListed(PluginState p, bool listed) async {
    if (!listed) {
      var go = false;
      final t = context.tokens;
      await showChoices(context, title: 'Take ${_nameOf(p.id)} off the Marketplace?', header: Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
        child: Text('People who added it keep it. Nobody new can add it until you list it again.', style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
      ), choices: [
        Choice('Take it off the Marketplace', Lucide.eyeOff, () => go = true, danger: true),
        Choice('Keep it listed', Lucide.x, () {}),
      ]);
      if (!go || !mounted) return;
    }
    setState(() => _busy.add(p.id));
    try {
      final now = await _api.setListed(p.id, listed);
      if (!mounted) return;
      final mine = _mine;
      if (mine != null) {
        _mine = MyMarket(blocked: mine.blocked, submissions: mine.submissions, plugins: [for (final x in mine.plugins) x.id == p.id ? now : x]);
        unawaited(_market.seenMine(_mine!));
      }
      toast(context, listed ? '${_nameOf(p.id)} is listed again' : '${_nameOf(p.id)} was taken off the Marketplace', tone: GlacierToastTone.success);
      unawaited(_read());
    } on MarketError catch (e) {
      if (mounted) toast(context, e.message, tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
    }
  }

  String _nameOf(String plugin) => _mine?.submissions.where((s) => s.plugin == plugin).firstOrNull?.name.ifEmpty(plugin) ?? plugin;

  Future<void> _open(SubmissionView s) async {
    await push<void>(context, (_) => MySubmissionScreen(view: s, api: _api, market: widget.market, current: _mine?.plugins.where((p) => p.id == s.plugin).firstOrNull?.current));
    if (mounted) unawaited(_read());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final server = marketHubIsOther(widget.hub);
    final mine = _mine;
    final children = <Widget>[
      if (server) ...[
        PaneSection(children: [SettingRow(key: const ValueKey('market-mine-server'), icon: const AppIcon(Lucide.globe, size: 18), label: marketServerWords(widget.hub ?? Net.instance.hubUrl))]),
        SizedBox(height: t.space(5)),
      ],
    ];
    if (_api.signer == null) {
      children.add(marketWhoBlock(context, key: const ValueKey('market-mine-who'), rowKey: const ValueKey('market-mine-me')));
    } else if (mine == null && _loading) {
      children.add(const SkeletonPeople(label: 'Loading', most: 4, shrink: true));
    } else if (mine == null && _unreachable) {
      children.add(MarketUnreachable(onRetry: () => unawaited(_read())));
    } else if (mine == null) {
      children.add(MarketBlock(words: _failed ?? marketUnreachableWords));
    } else {
      children.addAll(_list(context, t, mine));
    }
    // The one just sent, marked: scrolled to once it is drawn.
    if (!_scrolled && mine != null && widget.highlight != null) {
      _scrolled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final c = _marked.currentContext;
        if (c != null && c.mounted) unawaited(Scrollable.ensureVisible(c, duration: const Duration(milliseconds: 250), alignment: 0.3));
      });
    }
    return GhostPage(
      key: const ValueKey('market-mine'),
      title: 'My submissions',
      actions: [
        if (_api.signer != null) IconTap(key: const ValueKey('market-mine-refresh'), icon: Lucide.refreshCw, label: 'Refresh', onPressed: _loading ? null : () => unawaited(_read())),
        docsButton('plugin-submit'),
      ],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: children,
      ),
    );
  }

  List<Widget> _list(BuildContext context, Tokens t, MyMarket mine) {
    final gap = SizedBox(height: t.space(5));
    if (mine.submissions.isEmpty) {
      return [
        if (mine.blocked) ...[const MarketBlock(key: ValueKey('market-mine-blocked'), words: 'This account can\'t submit plugins.', icon: Lucide.ban), gap],
        PaneSection(children: [
          SettingRow(key: const ValueKey('market-mine-none'), icon: const AppIcon(Lucide.send, size: 18), label: 'Nothing sent yet. Submit a plugin when you\'ve made one.', onPress: AppShell.maybeOf(context) == null ? null : () => AppShell.maybeOf(context)!.marketplace(section: 'submit')),
        ]),
      ];
    }
    // A plugin each, in the order of its newest submission.
    final order = <String>[];
    for (final s in mine.submissions) {
      if (!order.contains(s.plugin)) order.add(s.plugin);
    }
    return [
      if (mine.blocked) ...[const MarketBlock(key: ValueKey('market-mine-blocked'), words: 'This account can\'t submit plugins.', icon: Lucide.ban), gap],
      for (final id in order) ...[
        _plugin(context, t, id, mine.plugins.where((p) => p.id == id).firstOrNull, [for (final s in mine.submissions) if (s.plugin == id) s]),
        gap,
      ],
    ];
  }

  Widget _plugin(BuildContext context, Tokens t, String id, PluginState? p, List<SubmissionView> subs) {
    final name = subs.first.name.ifEmpty(id);
    final busy = _busy.contains(id);
    return PaneSection(
      key: ValueKey('market-mine-plugin-$id'),
      title: name,
      description: Text([listingWords(p), if ((p?.note ?? '').isNotEmpty) p!.note!].join(' · '), key: ValueKey('market-mine-listing-$id')),
      children: [
        if (p?.listing == 'listed')
          SettingRow(key: ValueKey('market-mine-unlist-$id'), icon: const AppIcon(Lucide.eyeOff, size: 18), label: busy ? 'Taking it off…' : 'Take it off the Marketplace', disabled: busy, onPress: () => unawaited(_setListed(p!, false)))
        else if (p?.listing == 'unlisted' && p?.by == 'owner')
          SettingRow(key: ValueKey('market-mine-relist-$id'), icon: const AppIcon(Lucide.store, size: 18), label: busy ? 'Listing it…' : 'List it again', disabled: busy, onPress: () => unawaited(_setListed(p!, true))),
        for (final s in subs) _row(t, s),
      ],
    );
  }

  Widget _row(Tokens t, SubmissionView s) {
    final row = SettingRow(
      key: ValueKey('market-mine-${s.sid}'),
      icon: PluginTile(plugin: MarketFace.of(s), size: t.lenOf('1.85rem')),
      label: '${s.name.ifEmpty(s.plugin)} ${s.version}',
      hint: Text(submissionStatusWords(s), key: ValueKey('market-mine-status-${s.sid}'), style: s.status == 'changes_requested' || s.revokedAt != null ? TextStyle(color: t.danger) : null),
      value: Text(marketDate(s.submittedAt)),
      onPress: () => unawaited(_open(s)),
    );
    if (s.sid != widget.highlight) return row;
    return _Marked(key: _marked, child: row);
  }
}

/// A row marked as the one just sent.
class _Marked extends StatelessWidget implements PaneRow {
  const _Marked({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      selected: true,
      child: ColoredBox(key: const ValueKey('market-mine-marked'), color: t.color('app-accent').withValues(alpha: 0.12), child: child),
    );
  }
}

/// One submission's page: where its review stands, the notes on it, what its package can do, its screenshots, and
/// withdrawing it, sending a new version from it, and copying its package.
class MySubmissionScreen extends StatefulWidget {
  const MySubmissionScreen({super.key, required this.view, this.api, this.market, this.current});
  final SubmissionView view;
  final MarketApi? api;
  final MarketState? market;

  /// The plugin's version the Marketplace holds as current, where it has one: a new version starts above it.
  final String? current;

  @override
  State<MySubmissionScreen> createState() => _MySubmissionScreenState();
}

class _MySubmissionScreenState extends State<MySubmissionScreen> {
  late final MarketApi _api = widget.api ?? (widget.market ?? MarketState.instance).api;
  late SubmissionView _s = widget.view;
  Uint8List? _package;
  PluginPack? _pack;
  bool _packageFailed = false;
  final Map<int, Uint8List> _shots = {};
  bool _withdrawing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Reads the submission afresh, then its package and each screenshot; a screenshot is shown only where its bytes
  /// match the hash the submission names.
  Future<void> _load() async {
    try {
      final fresh = await _api.submission(_s.sid);
      if (mounted && fresh.sid == _s.sid) setState(() => _s = fresh);
    } catch (_) {}
    try {
      final bytes = await _api.submissionPackage(_s.sid);
      final parse = parsePack(bytes, appVersion: appVersion, checkMinApp: false);
      if (!mounted) return;
      setState(() {
        _package = bytes;
        _pack = parse.pack;
        _packageFailed = parse.pack == null;
      });
    } catch (_) {
      if (mounted) setState(() => _packageFailed = true);
    }
    for (final (n, sha) in _s.shots.indexed) {
      try {
        final bytes = await _api.submissionShot(_s.sid, n);
        if (!mounted) return;
        if (sha256Hex(bytes) == sha) setState(() => _shots[n] = bytes);
      } catch (_) {}
    }
  }

  Future<void> _withdraw() async {
    var go = false;
    final t = context.tokens;
    await showChoices(context, title: 'Withdraw ${_s.name.ifEmpty(_s.plugin)} ${_s.version}?', header: Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
      child: Text('It leaves the review queue. Send a new version whenever you\'re ready.', style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
    ), choices: [
      Choice('Withdraw', Lucide.undo2, () => go = true, danger: true),
      Choice('Keep it', Lucide.x, () {}),
    ]);
    if (!go || !mounted) return;
    setState(() => _withdrawing = true);
    try {
      final now = await _api.withdraw(_s.sid);
      if (!mounted) return;
      setState(() => _s = now.sid == _s.sid ? now : _s);
      toast(context, 'Withdrawn');
    } on MarketError catch (e) {
      if (mounted) toast(context, e.message, tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _withdrawing = false);
    }
  }

  void _resubmit() {
    final pack = _pack;
    if (pack == null) return;
    unawaited(push<void>(context, (_) => SubmitPluginScreen(api: widget.api, market: widget.market, start: pack, startVersion: resubmitVersion(_s, current: widget.current), from: _s)));
  }

  Future<void> _copy() async {
    final bytes = _package;
    if (bytes == null) return;
    await Clipboard.setData(ClipboardData(text: utf8.decode(bytes, allowMalformed: true)));
    if (mounted) toast(context, 'Package copied');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = _s;
    final gap = SizedBox(height: t.space(5));
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-2'));
    final body = pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink'));
    final pack = _pack;
    return GhostPage(
      key: ValueKey('market-mine-item-${s.sid}'),
      title: '${s.name.ifEmpty(s.plugin)} ${s.version}',
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          PaneSection(children: [
            SettingRow(
              icon: PluginTile(plugin: pack == null ? MarketFace.of(s) : MarketFace.ofPack(pack), size: t.lenOf('1.85rem')),
              label: submissionStatusWords(s),
              hint: Text(['Sent ${marketDate(s.submittedAt)}', if (s.updatedAt > s.submittedAt) 'changed ${marketDate(s.updatedAt)}', s.list == 'later' ? 'listed when you choose' : 'listed once approved'].join(' · ')),
            ),
          ]),
          gap,
          PaneSection(
            key: const ValueKey('market-mine-notes'),
            title: 'Notes',
            children: [
              if (s.notes.isEmpty) SettingRowBox(child: Tr('No notes yet.', style: quiet)),
              for (final n in s.notes)
                SettingRowBox(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${n.by == 'reviewer' ? 'Reviewer' : 'You'} · ${marketDate(n.at)}', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-2'))),
                    SizedBox(height: t.space(1)),
                    Text(n.text, style: body),
                  ]),
                ),
            ],
          ),
          gap,
          PaneSection(title: 'What it can do', children: [
            if (pack != null)
              for (final r in packReaches(pack)) SettingRow(icon: AppIcon(r.icon, size: 18), label: r.label, hint: r.hint == null ? null : Text(r.hint!))
            else
              SettingRowBox(child: Text(_packageFailed ? 'Couldn\'t read its package.' : 'Reading its package…', style: quiet)),
          ]),
          if (s.shots.isNotEmpty) ...[
            gap,
            PaneSection(title: 'Screenshots', children: [
              SettingRowBox(
                child: SizedBox(
                  height: t.lenOf('12rem'),
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: s.shots.length,
                    separatorBuilder: (context, _) => SizedBox(width: t.space(2)),
                    itemBuilder: (context, n) {
                      final bytes = _shots[n];
                      final height = t.lenOf('12rem');
                      final info = bytes == null ? null : pngInfo(bytes);
                      final width = info == null || info.height == 0 ? height * 0.5 : height * info.width / info.height;
                      return ClipRRect(
                        key: ValueKey('market-mine-shot-$n'),
                        borderRadius: BorderRadius.circular(pluginCorner(t, t.radius('md'))),
                        child: Container(
                          width: width,
                          height: height,
                          color: t.color('app-paper-3'),
                          child: bytes == null ? null : Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true, cacheHeight: (height * MediaQuery.devicePixelRatioOf(context)).round(), errorBuilder: (context, _, _) => const SizedBox.shrink()),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ]),
          ],
          gap,
          PaneSection(children: [
            if (s.open) SettingRow(key: const ValueKey('market-mine-withdraw'), icon: const AppIcon(Lucide.undo2, size: 18), label: _withdrawing ? 'Withdrawing…' : 'Withdraw', labelColor: t.danger, hint: const Tr('Out of the review queue.'), disabled: _withdrawing, onPress: () => unawaited(_withdraw())),
            SettingRow(key: const ValueKey('market-mine-resubmit'), icon: const AppIcon(Lucide.send, size: 18), label: 'Submit a new version', hint: Text(pack == null ? (_packageFailed ? 'Its package couldn\'t be read.' : 'Reading its package…') : 'As ${resubmitVersion(s, current: widget.current)}, from this one, its screenshots kept.'), disabled: pack == null, onPress: pack == null ? null : _resubmit),
            SettingRow(key: const ValueKey('market-mine-copy'), icon: const AppIcon(Lucide.copy, size: 18), label: 'Copy the package', hint: const Tr('Its file as it was sent, to change and load again.'), disabled: _package == null, onPress: _package == null ? null : () => unawaited(_copy())),
          ]),
        ],
      ),
    );
  }
}
