/// The Marketplace (Matt, 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail
/// with a marketplace icon", and "I would like users to be able to develop and submit their own plugins to our plugin
/// marketplace and I'd like to be able to verify them for the store through a review process"): a list of its sections
/// in Settings' shape, opened by its ring and standing in the list's place, the page of the section chosen in the pane,
/// beside it in a wide window and over it on a phone, as Settings' are.
///
/// Discover, Added and Updates; under "Make your own", Submit a plugin, My submissions, In development (in developer
/// mode) and the way to the docs; under "Admin", the Review queue. On a phone it has the band and a search over its
/// sections and every plugin; beside its page those are Discover's, and the list is its rows alone.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/listing_plugin.dart';
import '../../market/market_state.dart';
import '../../me/me.dart';
import '../../plugins/pack/pack.dart' show InstalledPlugins;
import '../../plugins/registry.dart';
import '../../plugins/settings.dart' show marketPluginsScreen;
import '../admin_page.dart' show adminOfferedFor;
import '../common.dart';
import '../nav_bar.dart';
import '../nav_style.dart';
import '../plugins_page/plugins_page.dart';
import '../settings.dart';
import '../shell.dart';
import 'market_flows.dart';
import 'my_submissions.dart';
import 'review_queue.dart';
import 'submit_screen.dart';
import '../../l10n/words.dart';

/// One of the Marketplace's sections: its row, and the heading it stands under ('' for none).
class MarketSection {
  const MarketSection(this.id, this.label, this.icon, this.hue, {this.group = ''});
  final String id;
  final String label;
  final LucideIcon icon;
  final String hue;
  final String group;
}

/// Every section, in the list's order (SPEC D.2). Which are offered now is [marketOffered]'s.
const List<MarketSection> marketSections = [
  MarketSection('discover', 'Discover', Lucide.compass, 'indigo'),
  MarketSection('added', 'Added', Lucide.checkCheck, 'green'),
  MarketSection('updates', 'Updates', Lucide.download, 'mint'),
  MarketSection('submit', 'Submit a plugin', Lucide.send, 'blue', group: _make),
  MarketSection('mine', 'My submissions', Lucide.listChecks, 'purple', group: _make),
  MarketSection('dev', 'In development', Lucide.flaskConical, 'graphite', group: _make),
  MarketSection('review', 'Review queue', Lucide.shieldCheck, 'coral', group: _admin),
];

// The headings sections are grouped under in the list.
const String _make = 'Make your own';
const String _admin = 'Admin';

/// Whether the section [id] is offered now, as the app's choices and this device stand ([current]: the section whose
/// page is in the pane, which an emptied Updates page stays for). On an iPhone nothing of Make your own is (SPEC G.5).
bool marketOffered(String id, AppState app, {String? current}) => switch (id) {
      'discover' || 'added' => true,
      'updates' => MarketState.instance.updates.isNotEmpty || current == 'updates',
      'submit' || 'mine' => !marketOnIphone,
      'dev' => app.flag('dev_mode', fallback: false) && InstalledPlugins.instance.devAllowed && !marketOnIphone,
      'review' => adminOfferedFor(app) && MarketState.instance.api.signer != null,
      _ => false,
    };

/// The sections offered now, in order.
List<MarketSection> marketSectionsNow(AppState app, {String? current}) => [for (final s in marketSections) if (marketOffered(s.id, app, current: current)) s];

/// A section's second line, and whether it is something to act on (My submissions' changes asked for).
({String text, bool danger}) marketSummary(String id, AppState app) {
  final m = MarketState.instance;
  final store = AppStore(app);
  final registry = PluginRegistry.instance;
  switch (id) {
    case 'discover':
      final n = marketPlugins(registry, m).length;
      return (text: '$n ${n == 1 ? 'plugin' : 'plugins'}', danger: false);
    case 'added':
      // What its page lists: every plugin added here, those for circles too, and those from other developers that are
      // here but don't run (review, 2026-11-20: the row said "1 added" over a page that said "Nothing added yet.").
      final n = registry.plugins.where((p) => registry.isOn(p, store)).length;
      final stuck = marketOnIphone ? 0 : InstalledPlugins.instance.store.where((p) => !p.running).length;
      return (text: n == 0 && stuck == 0 ? 'None yet' : [if (n > 0) '$n added', if (stuck > 0) '$stuck not running'].join(' · '), danger: false);
    case 'updates':
      final n = m.updates.length;
      return (text: n == 0 ? 'Everything\'s up to date' : '$n waiting', danger: false);
    case 'submit':
      return (text: 'Send one you made for review', danger: false);
    case 'mine':
      final subs = m.mine?.submissions ?? const [];
      final changes = subs.where((s) => s.status == 'changes_requested').length;
      final waiting = subs.where((s) => s.status == 'submitted' || s.status == 'in_review').length;
      if (changes > 0) return (text: '$changes ${changes == 1 ? 'needs' : 'need'} changes${waiting > 0 ? ' · $waiting waiting for review' : ''}', danger: true);
      if (waiting > 0) return (text: '$waiting waiting for review', danger: false);
      return (text: 'None yet', danger: false);
    case 'dev':
      // As its page lists them: those that run, and those whose copy doesn't (review, 2026-11-20: the row said
      // "1 loaded" over a page that said "Nothing loaded yet.").
      final dev = InstalledPlugins.instance.dev;
      final off = dev.where((d) => !d.running).length;
      return (text: [if (dev.length > off || off == 0) '${dev.length - off} loaded', if (off > 0) '$off not loading'].join(' · '), danger: false);
    case 'review':
      final n = m.reviewWaiting;
      return (text: n == null ? 'What waits for review' : '$n waiting', danger: false);
  }
  return (text: '', danger: false);
}

/// The Marketplace's list of sections: its ring's page, in the list's place.
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> {
  String _query = '';

  @override
  void initState() {
    super.initState();
    // What is older than ten minutes is read again (nothing until the shell has started it: never under a test).
    unawaited(MarketState.instance.opened());
  }

  /// Opens a section: in the frame's pane where there is a frame, over this page where there is none.
  void _open(String id, {String? plugin, String? arg}) {
    final shell = AppShell.maybeOf(context);
    if (shell != null) return shell.marketplace(section: id, plugin: plugin, arg: arg);
    push<void>(context, (context) => MarketSectionScreen(id, plugin: plugin, arg: arg));
  }

  @override
  Widget build(BuildContext context) {
    final shell = AppShell.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([InstalledPlugins.instance, MarketState.instance, PluginRegistry.instance, Me.instance, ?shell?.marketSection]),
      builder: (context, _) => _build(context, shell),
    );
  }

  Widget _build(BuildContext context, AppShellState? shell) {
    final t = context.tokens;
    final app = AppState.of(context);
    // Beside its page: the frame's list and pane are side by side.
    final beside = shell != null && AppShell.wideOf(context);
    final chosen = beside ? shell.marketSection.value : null;
    final sections = marketSectionsNow(app, current: shell?.marketSection.value);
    // Beside the pane there is always a section in it: Discover, until another is pressed (unfolding the Fold, or
    // widening a window, never leaves the pane empty).
    if (beside && chosen == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && shell.marketOpen && shell.wide && shell.marketSection.value == null) shell.marketplace(section: 'discover');
      });
    }
    final query = beside ? '' : _query.trim();
    var index = 0;
    Widget row(MarketSection s) {
      final said = marketSummary(s.id, app);
      return SettingsReveal(
        shown: beside && s.id == chosen,
        foot: beside && !AppShell.railOf(context) ? NavPill.clearance(t) : 0,
        child: SettingsSectionRow(
          key: ValueKey('market-row-${s.id}'),
          label: s.label,
          icon: AppIcon(s.icon, size: 18),
          hue: s.hue,
          summary: said.text,
          summaryDanger: said.danger,
          index: index++,
          selected: beside && s.id == chosen,
          chevron: !beside,
          onPress: () => _open(s.id),
        ),
      );
    }

    Widget heading(String words) => Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(2), 0, t.space(2), t.space(2)),
          child: Semantics(header: true, child: Text(words.toUpperCase(), style: pageText(t, t.lenOf('0.72rem'), weight: 'semibold', color: t.color('app-ink-3'), tracking: t.len('app-tracking-caps', em: t.lenOf('0.72rem'))))),
        );

    final groups = <String, List<MarketSection>>{};
    for (final s in sections) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    // Make your own has its docs row after its sections, and is not there at all on an iPhone.
    if (!marketOnIphone) groups.putIfAbsent(_make, () => []);
    final list = <Widget>[
      if (!beside) ...[
        PluginsEntry(registry: PluginRegistry.instance, onOpen: () => _open('discover'), extra: [for (final p in marketPlugins(PluginRegistry.instance, MarketState.instance)) if (p is ListingPlugin || p is StuckPackPlugin) p]),
        SizedBox(height: t.space(4)),
      ],
      for (final g in groups.entries) ...[
        if (g.key.isNotEmpty) heading(g.key),
        SettingsGroup(rows: [
          for (final s in g.value) row(s),
          if (g.key == _make)
            SettingsSectionRow(key: const ValueKey('market-docs'), label: 'How to build a plugin', icon: const AppIcon(Lucide.bookOpen, size: 18), hue: 'amber', summary: 'Step by step, at gogho.st/docs', index: index++, chevron: !beside, onPress: () => openDocs('build-a-plugin')),
        ]),
        SizedBox(height: t.space(5)),
      ],
    ];

    List<Widget> found() {
      final rows = [for (final s in sections) if (settingsMatch(query, '${s.label} ${marketSummary(s.id, app).text}')) s];
      final plugins = [for (final p in marketPlugins(PluginRegistry.instance, MarketState.instance)) if (pluginMatches(p, query)) p];
      if (rows.isEmpty && plugins.isEmpty) {
        return [
          Padding(
            padding: EdgeInsets.all(t.space(4)),
            child: Text('Nothing called “$query”.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'))),
          ),
        ];
      }
      return [
        SettingsGroup(rows: [
          for (final s in rows) row(s),
          for (final p in plugins)
            SettingsSectionRow(
              key: ValueKey('market-hit-${p.id}'),
              label: p.name,
              icon: AppIcon(p.icon, size: 18),
              hue: p.hue,
              summary: [if (p.developer != null) 'By @${p.developer}', p.tagline].join(' · '),
              index: index++,
              // A listing says it is one: a new version by another developer has the id of the copy on this device.
              onPress: () => _open('discover', plugin: p.id, arg: p is ListingPlugin ? 'listing' : null),
            ),
        ]),
      ];
    }

    return GhostPage(
      title: 'Marketplace',
      // A back arrow always, as Settings has: on a phone it is the page's own, beside its page it takes the Marketplace
      // away, back to the conversations or the circle it was opened from.
      onBack: beside ? shell.closeMarketplace : null,
      bigTitle: beside ? true : null,
      actions: [docsButton('plugins')],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!beside)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(3)),
            child: GlacierSearchField(key: const ValueKey('market-search'), placeholder: 'Search the Marketplace'.t, size: GlacierFieldSize.md, onValueChange: (v) => setState(() => _query = v)),
          ),
        const HeaderEnd(),
        Expanded(
          child: ListView(
            key: const ValueKey('marketplace-list'),
            // As Settings' list: the pill behaves under the Marketplace as under Settings (lib/ui/shell.dart).
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), MediaQuery.paddingOf(context).bottom + (beside && !AppShell.railOf(context) ? NavPill.clearance(t) : (AppShell.maybeOf(context) != null && NavStyle.of(AppState.of(context)).unified ? AppShell.pillRoom(context) + t.space(4) : t.space(8)))),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: query.isEmpty ? list : found(),
          ),
        ),
      ]),
    );
  }
}

/// One section's page by its [id]: what the frame puts in its pane for a row of the Marketplace's list. [plugin] opens
/// Discover at that plugin's page, [seek] lights a setting on it, [arg] is the section's own (a dev pack's id for
/// Submit, a submission's for My submissions; for Discover, 'listing' where [plugin] names a listing's page, else the
/// words its search starts with: a tag pressed on Added's or In development's page). A section not offered now draws
/// nothing, and the page goes.
class MarketSectionScreen extends StatefulWidget {
  const MarketSectionScreen(this.id, {super.key, this.plugin, this.seek, this.arg});
  final String id;
  final String? plugin;
  final String? seek;
  final String? arg;

  @override
  State<MarketSectionScreen> createState() => _MarketSectionScreenState();
}

class _MarketSectionScreenState extends State<MarketSectionScreen> {
  @override
  Widget build(BuildContext context) {
    final shell = AppShell.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([InstalledPlugins.instance, MarketState.instance, Me.instance]),
      builder: (context, _) {
        final app = AppState.of(context);
        if (!marketOffered(widget.id, app, current: shell?.marketSection.value ?? widget.id)) {
          if (shell == null) return const MarketplaceScreen();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && shell.marketSection.value == widget.id) shell.marketGone();
          });
          return ColoredBox(color: context.tokens.color('glacier-bg'), child: const SizedBox.expand());
        }
        return switch (widget.id) {
          'discover' => SettingsSeek(seek: widget.seek, child: marketPluginsScreen(title: 'Discover', open: widget.plugin, openListing: widget.plugin != null && widget.arg == 'listing', search: widget.plugin == null ? widget.arg : null)),
          'added' => marketPluginsScreen(title: 'Added', shelf: 'added', head: false),
          'updates' => const MarketUpdatesPage(),
          'dev' => marketPluginsScreen(title: 'In development', shelf: 'dev', head: false, lead: _devManage(context, shell)),
          // A dev pack's "Submit it" names its pack: the form starts with it (SPEC D.8), or says what stops it where its
          // newest copy doesn't load, never another plugin the form held before.
          'submit' => SubmitPluginScreen(start: widget.arg == null ? null : InstalledPlugins.instance.devOf(widget.arg!)?.pack, startFor: widget.arg),
          // The submission just sent, marked (SPEC D.9).
          'mine' => MySubmissionsScreen(highlight: widget.arg),
          'review' => const ReviewQueueScreen(),
          _ => const MarketplaceScreen(),
        };
      },
    );
  }

  /// The row above In development's list that leads to Settings › Developer, where the packs are loaded.
  Widget _devManage(BuildContext context, AppShellState? shell) => Padding(
        padding: EdgeInsets.only(bottom: context.tokens.space(2)),
        child: PaneSection(children: [
          SettingRow(
            key: const ValueKey('market-dev-manage'),
            icon: const AppIcon(Lucide.terminal, size: 18),
            label: 'Load and manage them in Settings › Developer',
            onPress: shell == null ? null : () => shell.settings('developer', 'Plugins in development'),
          ),
        ]),
      );
}
