/// A plugin's own page on the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated
/// plugins page with a marketplace like look how ghostmd has"), after Ghost.md's PluginDetail: its colour across the
/// head with its icon, name and line; Add or Remove; what it does and what it adds; what it reads, keeps or sends;
/// and, once it is added, its own settings, the cards its section in Settings has always had.
///
/// A plugin from another developer (Matt, 2026-11-20: "I would like users to be able to develop and submit their own
/// plugins to our plugin marketplace and I'd like to be able to verify them for the store through a review process")
/// has more: who made it and whether it was reviewed, said in every look, so an unreviewed pack's page never looks like
/// a reviewed one's; its tags; its screenshots and what's new; Update, Reload or Report; and, where it was withdrawn or
/// doesn't run, why, with Remove. What it reads and what it adds are made from its package alone.
///
/// Removing a plugin keeps its choices, as the registry always has: added again, it is as it was.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../plugins/pack/pack.dart' show PluginPack, packLabels, pngInfo, sha256Hex;
import '../../plugins/plugin.dart';
import '../common.dart';
import '../dialup/bevel.dart';
import '../dialup/title_bar.dart';
import '../translated_card.dart' show TranslatePreview;
import 'market_parts.dart';
import 'plugin_art.dart';
import '../../l10n/words.dart';

/// A picture of a plugin at work, for its page, where it has one: Translate's text with the words as they came dimmed
/// in the card and the translation in the bubble (Matt, 2026-11-17: "show the original text dimmed in a card with the
/// translated text for the actual message bubble"), as Market's pages show what a plugin does.
Widget? pluginPreview(GhostPlugin plugin) => switch (plugin.id) {
      'translate' => const TranslatePreview(),
      _ => null,
    };

/// Which kind of plugin from another developer a page is for.
enum PackKind {
  /// An approved plugin not on this device: Add, after its consent sheet.
  listing,

  /// Installed from the Marketplace and running: Add or Remove, Update where one waits.
  store,

  /// Installed from the Marketplace and not running (withdrawn, no longer checks out, unreadable): Remove alone.
  stuck,

  /// Loaded in Settings › Developer, unreviewed: its switch, Reload, its problems.
  dev,
}

/// What a pack's page has beyond a built-in's: where it comes from, what can be done with it here, and what its
/// package says of it. Everything shown of the pack is from [pack], never from what a listing said.
class PackPage {
  const PackPage({required this.kind, this.pack, this.onAdd, this.whyNot, this.adding = false, this.updateTo, this.onUpdate, this.onReload, this.problems = 0, this.warnings = 0, this.onProblems, this.onReport, this.stuck, this.paused = false, this.onUnpause, this.nohere = false, this.takenFrom, this.shotOf, this.onLabel, this.onSupport});

  final PackKind kind;

  /// Its package, parsed; null for a stuck pack that couldn't be read.
  final PluginPack? pack;

  /// A listing's Add (its install flow); null with [whyNot] where this device can't take it.
  final VoidCallback? onAdd;
  final String? whyNot;

  /// A listing on its way: "Adding…".
  final bool adding;

  /// The version an update waiting would bring, and what does it.
  final String? updateTo;
  final VoidCallback? onUpdate;

  /// A dev pack's Reload, where its source can be read again.
  final VoidCallback? onReload;

  /// How many problems a dev pack has, and warnings apart (a warning doesn't stop it loading), and the way to them (its
  /// own screen, beside or over this page).
  final int problems;
  final int warnings;
  final VoidCallback? onProblems;

  final VoidCallback? onReport;

  /// Why a stuck pack doesn't run, in words for its box (D.4).
  final String? stuck;

  /// It was slowing the app down; [onUnpause] turns it back on.
  final bool paused;
  final VoidCallback? onUnpause;

  /// This computer has no texts for it to sort (a computer on its own).
  final bool nohere;

  /// A listing now by another developer than the copy on this device: that copy's developer, or '' where nothing here
  /// can tell who made that copy (one that no longer parses, installed before its developer was kept).
  final String? takenFrom;

  /// A screenshot's checked bytes by its SHA-256 (route 6), or null where it can't be had or isn't the one named.
  final Future<Uint8List?> Function(String sha256)? shotOf;

  /// A tag pressed on its head: Discover searches for it.
  final ValueChanged<String>? onLabel;

  /// Its help: an https address opened, an email address copied.
  final VoidCallback? onSupport;

  bool get reviewed => kind == PackKind.listing || kind == PackKind.store;
}

/// The words a stuck store pack's box says, by its problem (D.4): withdrawn, with the reviewer's own signed reason;
/// a review this build can't check; a pack this build can't run; or one this device couldn't load.
String stuckWords(String? problem, {String? why, required String here}) => switch (problem) {
      'revoked' => 'Withdrawn from the Marketplace${why == null || why.isEmpty ? '' : ': $why'}. It\'s off, and does nothing until you remove it.',
      'bad_approval' || 'untrusted_key' => 'This version of Uplink can\'t check its review, so it\'s off. An update may fix it.',
      'invalid' || 'needs_newer_app' => 'This version of Uplink can\'t run it. Update Uplink.',
      _ => 'It couldn\'t be loaded on this $here.',
    };

/// The page for [plugin]; [pluginDetailOf] (plugins_page.dart) makes it with the app's own answers.
class PluginDetail extends StatelessWidget {
  const PluginDetail({super.key, required this.plugin, required this.added, required this.onSwitch, required this.here, this.summary, this.settings = const [], this.hasSettings = false, this.onClose, this.finder, this.seek, this.pack});

  final GhostPlugin plugin;
  final bool added;

  /// Adds it, or removes it.
  final ValueChanged<bool> onSwitch;

  /// Where it runs, in a word: phone, computer, iPhone.
  final String here;

  /// What its settings come to as they stand, under the buttons once it is added.
  final String? summary;

  /// Its own settings' cards, drawn once it is added.
  final List<Widget> settings;

  /// It has settings of its own, to say so while it is not added.
  final bool hasSettings;

  /// Shuts the page, where it stands beside the shelves; null where the page's bar does.
  final VoidCallback? onClose;

  /// Finds a setting on it by name, for a search's hit ([seek]).
  final SettingsFinder? finder;
  final String? seek;

  /// What a plugin from another developer's page has more; null for a built-in.
  final PackPage? pack;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final c = PluginHues.of(t, plugin.hue);
    final gap = t.space(4);
    final ink = t.color('app-ink');
    final body = pageText(t, t.fontSize('md'), height: 1.45, color: ink);
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-3'));
    final p = pack;
    final pk = p?.pack;

    Widget section(String title, List<Widget> children, {Key? key}) => Padding(
          key: key,
          padding: EdgeInsets.only(top: gap * 1.5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(header: true, child: Text(title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
              SizedBox(height: t.space(1)),
              ...children,
            ],
          ),
        );

    Widget point(LucideIcon icon, String label, {String? hint}) => Padding(
          padding: EdgeInsets.only(top: t.space(2)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: t.lenOf('1.9rem'),
                height: t.lenOf('1.9rem'),
                decoration: BoxDecoration(color: bevel ? null : c.wash, borderRadius: BorderRadius.circular(pluginCorner(t, t.lenOf('0.55rem')))),
                alignment: Alignment.center,
                child: AppIcon(icon, size: 15, strokeWidth: 2.2, color: bevel ? ink : c.accent, wash: false),
              ),
              SizedBox(width: t.space(3)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(padding: EdgeInsets.only(top: t.lenOf('0.2rem')), child: Text(label, style: pageText(t, t.fontSize('md'), weight: hint == null ? 'regular' : 'medium', height: 1.35, color: ink))),
                    if (hint != null) Padding(padding: EdgeInsets.only(top: t.lenOf('0.15rem')), child: Text(hint, style: quiet)),
                  ],
                ),
              ),
            ],
          ),
        );

    // A box under the head, for what stands in the way: withdrawn, paused, nowhere to run, another developer's now.
    Widget notice(String words, {required Key key, LucideIcon icon = Lucide.circleAlert, Widget? then}) => Padding(
          key: key,
          padding: EdgeInsets.only(top: gap),
          child: MarketCard(
            padding: EdgeInsets.all(t.space(3)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AppIcon(icon, size: 18, strokeWidth: 2.2, color: bevel ? ink : c.accent, wash: false),
                SizedBox(width: t.space(2)),
                Expanded(child: Text(words, style: body)),
              ]),
              if (then != null) ...[SizedBox(height: t.space(2)), then],
            ]),
          ),
        );

    final stuck = p?.kind == PackKind.stuck;
    final status = stuck ? ((p!.stuck?.startsWith('Withdrawn') ?? false) ? 'Withdrawn' : 'Not working') : (added ? 'Added' : 'Not added');
    final listing = p?.kind == PackKind.listing;
    final buttons = <Widget>[
      // Dial-Up's head has no tags: whether it is added stands by its button, not on the title bar.
      if (bevel && added && !listing && !stuck) MarketAdded(key: const ValueKey('plugins-detail-status'), name: plugin.name),
      if (listing)
        p!.adding
            ? MarketButton(key: ValueKey('plugins-adding-${plugin.id}'), label: 'Adding…', look: MarketButtonLook.filled, color: c.start, onColor: c.on, large: true, onPress: null)
            : MarketButton(
                key: ValueKey('plugins-add-${plugin.id}'),
                label: 'Add to Uplink',
                semantics: 'Add ${plugin.name}',
                icon: Lucide.plus,
                look: MarketButtonLook.filled,
                color: c.start,
                onColor: c.on,
                large: true,
                onPress: p.onAdd,
              )
      else if (stuck)
        MarketButton(key: ValueKey('plugins-remove-${plugin.id}'), label: 'Remove', semantics: 'Remove ${plugin.name}', icon: Lucide.minus, look: MarketButtonLook.ring, color: c.start, onColor: c.on, large: true, onPress: () => onSwitch(false))
      else
        MarketButton(
          key: ValueKey(added ? 'plugins-remove-${plugin.id}' : 'plugins-add-${plugin.id}'),
          label: added ? 'Remove' : 'Add to Uplink',
          semantics: '${added ? 'Remove' : 'Add'} ${plugin.name}',
          icon: added ? Lucide.minus : Lucide.plus,
          look: added ? MarketButtonLook.ring : MarketButtonLook.filled,
          color: c.start,
          onColor: c.on,
          large: true,
          onPress: p?.nohere == true && !added ? null : () => onSwitch(!added),
        ),
      if (p?.onUpdate != null && p?.updateTo != null) MarketButton(key: ValueKey('plugins-update-${plugin.id}'), label: 'Update to ${p!.updateTo}', icon: Lucide.download, look: MarketButtonLook.ring, large: true, onPress: p.onUpdate),
      if (p?.onReload != null) MarketButton(key: ValueKey('plugins-reload-${plugin.id}'), label: 'Reload', icon: Lucide.refreshCw, look: MarketButtonLook.ring, large: true, onPress: p!.onReload),
      if (p != null && (p.problems > 0 || p.warnings > 0)) MarketButton(key: ValueKey('plugins-problems-${plugin.id}'), label: [if (p.problems > 0) '${p.problems} ${p.problems == 1 ? 'problem' : 'problems'}', if (p.warnings > 0) '${p.warnings} ${p.warnings == 1 ? 'warning' : 'warnings'}'].join(', '), icon: p.problems > 0 ? Lucide.triangleAlert : Lucide.info, look: MarketButtonLook.ring, large: true, onPress: p.onProblems),
    ];
    final hint = switch (p?.kind) {
      null => added ? 'Added. Removed, it does nothing until it is added again, and keeps your choices for it.' : 'Built in: adding it is a switch, and removing it keeps your choices for it.',
      PackKind.listing => 'From the Marketplace: reviewed before it was listed. Adding it asks first, and it works on this $here alone.',
      PackKind.store || PackKind.stuck => 'From the Marketplace. Removing it deletes it from this $here; your choices for it are kept.',
      PackKind.dev => 'Loaded in Developer mode: not reviewed. It runs only while Developer mode is on.',
    };
    final preview = p == null || p.kind == PackKind.dev ? pluginPreview(plugin) : null;
    final shots = p != null && p.reviewed && pk != null && pk.shots.isNotEmpty && p.shotOf != null ? pk.shots : const <String>[];
    final whatsNew = pk?.whatsNew;
    final hasSection = (pk?.rules.sections.isNotEmpty ?? false);
    return Column(
      key: ValueKey('plugins-detail-${plugin.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bevel ? _window(t, status) : _hero(t, c, status),
        if (stuck && p!.stuck != null) notice(p.stuck!, key: const ValueKey('plugins-detail-withdrawn')),
        if (p != null && p.paused)
          notice('Paused: it was slowing the app down.', key: const ValueKey('plugins-detail-paused'), icon: Lucide.pause, then: MarketButton(key: ValueKey('market-unpause-${plugin.id}'), label: 'Turn it back on', look: MarketButtonLook.ring, onPress: p.onUnpause)),
        if (p != null && p.nohere) notice('This plugin sorts texts, which this computer doesn\'t have.', key: const ValueKey('plugins-detail-nohere'), icon: Lucide.info),
        if (p?.takenFrom != null) notice(p!.takenFrom!.isEmpty ? 'This is now by @${plugin.developer}. Adding it removes your copy of it here, and your choices for it.' : 'This is now by @${plugin.developer}. Adding it removes your copy by @${p.takenFrom}, and your choices for it.', key: const ValueKey('market-developer-changed'), icon: Lucide.info),
        SizedBox(height: gap),
        Wrap(spacing: t.space(2), runSpacing: t.space(2), crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
        if (p?.whyNot != null) Padding(padding: EdgeInsets.only(top: t.space(2)), child: Text(p!.whyNot!, key: const ValueKey('plugins-detail-whynot'), style: quiet)),
        SizedBox(height: t.space(2)),
        Text(hint, key: const ValueKey('plugins-detail-hint'), style: quiet),
        section('What it does', [Text(plugin.description, style: body)]),
        if (preview != null)
          section('How it looks', [
            SizedBox(height: t.space(1)),
            MarketCard(key: const ValueKey('plugins-detail-preview'), padding: EdgeInsets.all(t.space(3)), child: preview),
          ])
        else if (shots.isNotEmpty)
          section('How it looks', [SizedBox(height: t.space(1)), _Shots(key: const ValueKey('plugins-detail-shots'), shots: shots, shotOf: p!.shotOf!)]),
        if (whatsNew != null && whatsNew.isNotEmpty) section('What\'s new in ${pk!.version}', [Text(whatsNew, style: body)], key: const ValueKey('plugins-detail-whatsnew')),
        if (plugin.adds.isNotEmpty) section('What it adds', [for (final add in plugin.adds) point(Lucide.check, add)]),
        if (p != null && hasSection) Padding(padding: EdgeInsets.only(top: t.space(3)), child: Tr('Built-in plugins sort first: a text Codes, Spam filter or a kind of Kinds of text takes stays theirs.', key: const ValueKey('plugins-detail-first'), style: quiet)),
        section('What it reads and keeps', [
          for (final r in plugin.reaches) point(r.icon, r.label, hint: r.hint),
          // A pack's card is its package's lines and nothing else: they say where it runs and that it reaches nothing.
          if (p == null) point(Lucide.shieldCheck, 'Runs on this $here', hint: plugin.reaches.isEmpty ? 'It works on what is on the screen, here, and sends nothing anywhere.' : 'Nothing else leaves it, and nothing is kept past the app being closed unless it says so above.'),
        ], key: const ValueKey('plugins-detail-privacy')),
        if (added && settings.isNotEmpty && !stuck)
          Padding(
            key: const ValueKey('plugins-detail-settings'),
            padding: EdgeInsets.only(top: gap * 1.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(header: true, child: Text('Its settings', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
                // What they come to now, named as such: under Remove with no word before it, "Balanced · muted" read
                // as nothing in particular.
                if (summary != null) Padding(padding: EdgeInsets.only(top: t.space(1)), child: Text('Set to: $summary', key: const ValueKey('plugins-detail-summary'), style: quiet)),
                SizedBox(height: t.space(2)),
                GlacierScope(
                  attrs: {'hue': plugin.hue},
                  child: SettingsPaneScope(
                    finder: finder ?? SettingsFinder(),
                    whole: seek != null,
                    seeking: seek,
                    child: PaneBody(children: settings),
                  ),
                ),
              ],
            ),
          )
        else if (listing && pk != null && pk.settings.any((s) => s.type != 'heading'))
          // Not on this device yet: what it will let you set, by name.
          section('Its settings', [for (final s in pk.settings) if (s.type != 'heading') point(Lucide.slidersHorizontal, s.label)], key: const ValueKey('plugins-detail-settings-names'))
        else if (!added && hasSettings && !stuck)
          section('Its settings', [Tr('Once it is added, its settings are here.', style: quiet)]),
        if (pk?.support != null)
          section('Help from the developer', [
            Padding(
              padding: EdgeInsets.only(top: t.space(1)),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: MarketButton(label: pk!.support!, icon: pk.support!.contains('@') && !pk.support!.contains('://') ? Lucide.copy : Lucide.link, look: MarketButtonLook.ring, onPress: p?.onSupport),
              ),
            ),
          ], key: const ValueKey('plugins-detail-support')),
        if (p?.onReport != null)
          Padding(
            padding: EdgeInsets.only(top: gap * 1.5),
            child: Align(alignment: AlignmentDirectional.centerStart, child: MarketButton(key: ValueKey('plugins-report-${plugin.id}'), label: 'Report this plugin', icon: Lucide.flag, look: MarketButtonLook.ring, onPress: p!.onReport)),
          ),
        Padding(
          padding: EdgeInsets.only(top: gap * 1.5),
          child: Text(
            p == null
                ? '${plugin.shelf.label} · built in · on this $here alone'
                : [plugin.shelf.label, if (plugin.version != null) 'version ${plugin.version}', if (plugin.developer != null) 'by @${plugin.developer}', 'on this $here alone'].join(' · '),
            style: quiet,
          ),
        ),
      ],
    );
  }

  /// Where a plugin from another developer comes from, under its tagline: built in; by its developer and reviewed;
  /// or by its developer, in development and not reviewed.
  Widget _source(Tokens t, Color color) {
    final p = pack;
    final style = pageText(t, t.fontSize('sm'), weight: 'medium', height: 1.35, color: color);
    final dev = plugin.developer;
    final words = switch (p?.kind) {
      null => 'Built in',
      PackKind.dev => [if (dev != null) 'By @$dev', 'In development · not reviewed'].join(' · '),
      _ when p!.reviewed => [if (dev != null) 'By @$dev', 'Reviewed by Uplink'].join('\n'),
      _ => dev == null ? 'From the Marketplace' : 'By @$dev',
    };
    return Text(words, key: const ValueKey('plugins-detail-source'), style: style);
  }

  /// Its tags, each a press that searches Discover for it.
  List<Widget> _labels(Tokens t, {Color? ground, Color? ink, Color? ring}) => [
        for (final l in plugin.labels)
          GlacierPressable(
            key: ValueKey('plugins-detail-label-$l'),
            onPressed: pack?.onLabel == null ? null : () => pack!.onLabel!(packLabels[l] ?? l),
            semanticLabel: 'Find plugins for ${packLabels[l] ?? l}',
            builder: (context, state) => MarketTag(label: packLabels[l] ?? l, ground: ground, ink: ink, ring: ring),
          ),
      ];

  /// The head: the plugin's colour, its icon large and faint as its picture, and its name and line on it.
  Widget _hero(Tokens t, PluginHues c, String status) {
    final radius = pluginCorner(t, t.radius('lg') * 1.5);
    final p = pack;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: c.gradient),
        child: Stack(
          children: [
            Positioned.fill(child: hueGlow(c, radius: radius)),
            // Faint, low and mostly past the end, beyond the words' width: it ran under the line in every look.
            PositionedDirectional(end: -t.space(16), bottom: -t.space(12), child: AppIcon(plugin.icon, size: t.lenOf('12rem'), strokeWidth: 1.4, color: c.faint, wash: false)),
            Padding(
              padding: EdgeInsets.all(t.space(5)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GlassChip(plugin: plugin, size: t.lenOf('3.6rem')),
                      const Spacer(),
                      if (onClose != null)
                        GlacierPressable(
                          key: const ValueKey('plugins-detail-close'),
                          onPressed: onClose,
                          semanticLabel: 'Close ${plugin.name}',
                          builder: (context, state) => GlacierFocusRing(
                            visible: state.focused,
                            child: Container(
                              width: t.space(8),
                              height: t.space(8),
                              decoration: BoxDecoration(color: c.tag, borderRadius: BorderRadius.circular(pluginCorner(t, t.space(4)))),
                              alignment: Alignment.center,
                              child: AppIcon(Lucide.x, size: 16, strokeWidth: 2.4, color: c.on, wash: false),
                            ),
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: t.space(4)),
                  Semantics(header: true, child: Text(plugin.name, style: pageText(t, t.fontSize('2xl'), weight: 'bold', color: c.on))),
                  SizedBox(height: t.space(1)),
                  FractionallySizedBox(
                    widthFactor: 0.68,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(plugin.tagline, style: pageText(t, t.fontSize('md'), height: 1.35, color: c.on.withValues(alpha: 0.92))),
                  ),
                  SizedBox(height: t.space(2)),
                  _source(t, c.on.withValues(alpha: 0.92)),
                  SizedBox(height: t.space(3)),
                  Wrap(
                    spacing: t.space(2),
                    runSpacing: t.space(2),
                    children: [
                      if (p?.kind != PackKind.listing) MarketTag(key: const ValueKey('plugins-detail-status'), label: status, ground: c.tag, ink: c.on, ring: c.tagRing),
                      if (p != null && p.reviewed) _ReviewedTag(key: const ValueKey('plugins-detail-reviewed'), ground: c.tag, ink: c.on, ring: c.tagRing),
                      if (p?.kind == PackKind.dev) MarketTag(key: const ValueKey('plugins-detail-dev'), label: 'In development · not reviewed', ground: c.tag, ink: c.on, ring: c.tagRing),
                      MarketTag(label: plugin.shelf.label, ground: c.tag, ink: c.on, ring: c.tagRing),
                      // A pack's tags, which search for it; a built-in's are only for search.
                      if (p != null) ..._labels(t, ground: c.tag, ink: c.on, ring: c.tagRing),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Dial-Up's head: a window titled for the plugin's shelf (its X where the page stands beside the shelves), and on
  /// the silver its tile, its name and its line. The page's own bar names the plugin on a phone, so the window's title
  /// bar saying it again read as the title twice. Its head has no tags, so a plugin from another developer says where
  /// it comes from in lines: its source and tags under the line, the Reviewed mark by the name, and a bevelled label
  /// for one in development.
  Widget _window(Tokens t, String status) {
    final c = DialupColors.of(t);
    final p = pack;
    return Bevel(
      padding: const EdgeInsets.all(2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TitleBar(title: '${plugin.shelf.label} plugin', onClose: onClose, closeLabel: 'Close ${plugin.name}', leading: AppIcon(plugin.icon, size: 16, strokeWidth: 2.2, color: c.titlebarInk, wash: false)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PluginTile(plugin: plugin, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(child: Semantics(header: true, child: Text(plugin.name, style: pageText(t, 17, weight: 'bold', color: c.onChrome)))),
                      if (p != null && p.reviewed) ...[const SizedBox(width: 6), _ReviewedTag(key: const ValueKey('plugins-detail-reviewed'), ink: c.onChrome)],
                    ]),
                    const SizedBox(height: 2),
                    Text(plugin.tagline, style: pageText(t, 15, height: 1.35, color: c.onChrome)),
                    const SizedBox(height: 4),
                    _source(t, c.onChrome),
                    if (p != null) ...[
                      if (plugin.labels.isNotEmpty) ...[const SizedBox(height: 4), Wrap(spacing: 6, runSpacing: 4, children: _labels(t))],
                      if (p.kind == PackKind.dev) ...[
                        const SizedBox(height: 6),
                        Bevel(key: const ValueKey('plugins-detail-dev'), style: BevelStyle.sunken, padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: Tr('In development · not reviewed', style: pageText(t, 13, weight: 'bold', color: c.onChrome))),
                      ],
                      if (p.kind == PackKind.stuck) ...[const SizedBox(height: 4), Text(status, key: const ValueKey('plugins-detail-status'), style: pageText(t, 13, weight: 'bold', color: c.onChrome))],
                    ],
                  ]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Reviewed", with its mark: a store pack's and a listing's, never "Verified", which would read as checking who the
/// developer is (SPEC 0.4).
class _ReviewedTag extends StatelessWidget {
  const _ReviewedTag({super.key, this.ground, this.ink, this.ring});
  final Color? ground, ink, ring;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final colour = ink ?? t.color('app-ink-2');
    return Container(
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.12rem')),
      decoration: BoxDecoration(
        color: ground ?? (isBevelChrome(t) ? null : t.color('app-paper-3')),
        borderRadius: BorderRadius.circular(t.radius('full')),
        border: ring == null ? null : Border.all(color: ring!, width: t.len('glacier-hairline')),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        AppIcon(LucideMore.badgeCheck, size: 13, strokeWidth: 2.2, color: colour, wash: false),
        SizedBox(width: t.lenOf('0.2rem')),
        Text('Reviewed', maxLines: 1, style: pageText(t, t.fontSize('xs'), weight: 'medium', color: colour)),
      ]),
    );
  }
}

/// A pack's screenshots in a sideways strip: each fetched and shown only where its bytes are the one its checked
/// package names (by SHA-256), decoded at the size it is drawn.
class _Shots extends StatefulWidget {
  const _Shots({super.key, required this.shots, required this.shotOf});
  final List<String> shots;
  final Future<Uint8List?> Function(String sha256) shotOf;

  @override
  State<_Shots> createState() => _ShotsState();
}

class _ShotsState extends State<_Shots> {
  final Map<String, Uint8List> _got = {};

  /// Each hash asked for, and whether its answer came (a picture or not).
  final Map<String, bool> _asked = {};

  @override
  void initState() {
    super.initState();
    widget.shots.forEach(_fetch);
  }

  /// A new version on the same page (Update, from the page): its pictures are fetched, and the old ones' let go. The
  /// strip was made once and kept the old version's fetches, so "How it looks" stood empty under its heading until the
  /// page was opened again (review, 2026-11-20).
  @override
  void didUpdateWidget(_Shots old) {
    super.didUpdateWidget(old);
    if (listEquals(old.shots, widget.shots)) return;
    final now = widget.shots.toSet();
    _got.removeWhere((sha, _) => !now.contains(sha));
    _asked.removeWhere((sha, _) => !now.contains(sha));
    widget.shots.forEach(_fetch);
  }

  /// Asks for the picture named [sha] once, and keeps it only where its bytes hash to that name.
  void _fetch(String sha) {
    if (_asked.containsKey(sha)) return;
    _asked[sha] = false;
    void done() {
      if (mounted && _asked.containsKey(sha)) setState(() => _asked[sha] = true);
    }

    widget.shotOf(sha).then((bytes) {
      if (mounted && bytes != null && sha256Hex(bytes) == sha && widget.shots.contains(sha)) _got[sha] = bytes;
      done();
    }).catchError((Object _) => done());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final shown = [for (final sha in widget.shots) if (_got[sha] != null) (sha, _got[sha]!)];
    final height = t.lenOf('16rem');
    if (shown.isEmpty) {
      // Every one asked for came back with nothing to show (offline, or the store no longer serves them): said, not a
      // blank under the heading.
      final answered = widget.shots.isNotEmpty && widget.shots.every((sha) => _asked[sha] == true);
      if (!answered) return SizedBox(height: t.space(1));
      return Text('Its pictures couldn\'t be loaded.', key: const ValueKey('plugins-detail-shots-none'), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')));
    }
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: shown.length,
        separatorBuilder: (context, _) => SizedBox(width: t.space(2)),
        itemBuilder: (context, i) {
          // As wide as its own proportions say, read from its header: the strip doesn't jump as each one decodes.
          final info = pngInfo(shown[i].$2);
          final width = info == null || info.height == 0 ? height * 0.5 : height * info.width / info.height;
          return ClipRRect(
            key: ValueKey('plugins-detail-shot-${shown[i].$1}'),
            borderRadius: BorderRadius.circular(pluginCorner(t, t.radius('md'))),
            child: Image.memory(shown[i].$2, width: width, height: height, fit: BoxFit.contain, filterQuality: FilterQuality.medium, gaplessPlayback: true, cacheHeight: (height * MediaQuery.devicePixelRatioOf(context)).round(), errorBuilder: (context, _, _) => SizedBox(width: width, height: height)),
          );
        },
      ),
    );
  }
}

/// A plugin's page on a phone: the page over the shelves, with its name on the bar and the way back.
class PluginDetailPage extends StatelessWidget {
  const PluginDetailPage({super.key, required this.title, required this.body});

  final String title;

  /// The page's body, built afresh as the person's choices change (it is under the app's own scope, not the shelves').
  final Widget Function(BuildContext context) body;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: title,
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [Builder(builder: body)],
      ),
    );
  }
}
