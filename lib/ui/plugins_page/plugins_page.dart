/// The Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated plugins page with a
/// marketplace like look how ghostmd has"): Ghost.md's Market (its lib/market/market_screen.dart) for Uplink's
/// plugins. A band in colour with the plugins' tiles on it, a search, a chip for each shelf, a few
/// featured plugins, and then every plugin on a card: those added, and those to discover. A plugin's own page says
/// what it does, what it reads and keeps, has Add or Remove, and once it is added its settings.
///
/// It is the Marketplace's Discover, Added and In development since plugins left Settings (lib/ui/market/; Matt,
/// 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail with a marketplace
/// icon"), a screen of its own: on a phone a plugin's page opens over it, and with room (a Fold open, a computer's
/// window) it stands beside the shelves, whose cards go two to four across. Beside the app's own plugins it lists
/// those from other developers: the store packs on this device (those that don't run too, with why), the plugins in
/// development while developer mode is on, and the listings the Marketplace has checked (lib/market/market_state.dart).
/// Adding a built-in is the registry's switch; adding a listing asks first (lib/ui/market/market_flows.dart).
library;

import '../split_handle.dart';
import 'dart:async';
import '../../platform_info.dart';
import 'dart:math' as math;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart' show AppIcon, LucideIcon;
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/listing_plugin.dart';
import '../../market/market_state.dart';
import '../../plugins/pack/pack.dart' show DevPack, InstalledPack, InstalledPlugins, packAddressIssue, packIdOf, packLabels;
import '../../inbox/inbox.dart' show InboxState;
import '../../plugins/networks.dart';
import '../../plugins/plugin.dart';
import '../../plugins/registry.dart';
import '../../sms.dart';
import '../common.dart';
import '../dialup/bevel.dart';
import '../inbox_ui.dart' show turnOffNetwork;
import '../market/dev_plugins.dart' show DevPluginScreen, devPackCounts;
import '../market/market_flows.dart';
import '../settings.dart' show SettingsSeek, settingsMatch;
import '../shell.dart' show AppShell;
import 'market_parts.dart';
import 'plugin_cards.dart';
import 'plugin_detail.dart';
import 'plugin_sync_row.dart';
import 'plugins_band.dart';

/// The plugins featured at the head of the page, in this order, those the app has.
const List<String> featuredPlugins = ['translate', 'codes', 'spam'];

/// From this wide, a plugin's page stands beside the shelves rather than over them.
const double pluginsWide = 720;

/// Where the plugins run, in a word.
String pluginsHere() => Sms.remote ? (PlatformInfo.isIOS ? 'iPhone' : 'computer') : 'phone';

/// What plugins are, in a line: the band's.
String pluginsLine() => 'Extras for your messages, built in or from other developers, each on this ${pluginsHere()} alone.';

/// What a shelf chip stands for: every plugin (null), those added, or one shelf.
const String _added = 'added';

/// The chip for the plugins meant for circles.
const String _circles = 'circles';

/// The chips for plugins from other developers (store packs and listings) and for those in development.
const String _store = 'store';
const String _dev = 'dev';

/// No plugins from other developers at all here: an iPhone (SPEC G.5), where InstalledPlugins never allows store packs.
bool get marketOnIphone => !InstalledPlugins.instance.storeAllowed;

/// The page itself: the Marketplace's Discover as it stands, or Added or In development with [shelf] and no [head].
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, this.registry, this.open, this.openListing = false, this.settingsOf, this.summaryOf, this.title = 'Plugins', this.market, this.shelf, this.head = true, this.lead, this.search});

  /// The plugins: the app's own where not given.
  final PluginRegistry? registry;

  /// A plugin's id whose page is open from the start.
  final String? open;

  /// [open] is a listing's: a plugin's new version by another developer has the id of the copy on this device, and is
  /// a page of its own (D.5).
  final bool openListing;

  /// What the search holds from the start: a tag pressed on Added's or In development's page searches Discover.
  final String? search;

  /// A plugin's own settings, as cards, for its page once it is added.
  final List<Widget> Function(BuildContext context, GhostPlugin plugin)? settingsOf;

  /// What a plugin's settings come to, in a line, for its page once it is added.
  final String? Function(BuildContext context, GhostPlugin plugin)? summaryOf;

  /// The page's name on its bar: Discover, Added, In development in the Marketplace.
  final String title;

  /// The Marketplace: its checked listings are on the shelves, and what it says of the catalog under the chips. Null
  /// lists the device's own plugins alone (a test of the shelves).
  final MarketState? market;

  /// The chip chosen at first: null for All, 'added', 'circles', 'store', 'dev', or a shelf's name.
  final String? shelf;

  /// The band, the search and the chips. Without them (Added, In development) the page is that shelf alone.
  final bool head;

  /// Something above the shelves: In development's way to Settings › Developer.
  final Widget? lead;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  String _query = '';

  /// The chip chosen: null for All, [_added], [_circles], [_store], [_dev], or a [PluginShelf]'s name.
  String? _shelf;

  /// The plugin whose page stands beside the shelves, with room, and whether it is a listing's: a new version by
  /// another developer has the id of the copy on this device, so the id alone opened the copy's page (review,
  /// 2026-11-20).
  String? _open;
  bool _openListing = false;

  /// The setting a search found, to light on its plugin's page.
  String? _seek;
  final _finder = SettingsFinder();
  bool _sought = false;

  PluginRegistry get _registry => widget.registry ?? PluginRegistry.instance;

  @override
  void initState() {
    super.initState();
    _open = widget.open;
    _openListing = widget.openListing;
    _shelf = widget.shelf;
    _query = widget.search ?? '';
  }

  /// Asked for another shelf or another plugin's page in its place: as if made afresh with them.
  @override
  void didUpdateWidget(PluginsPage old) {
    super.didUpdateWidget(old);
    if (widget.shelf != old.shelf || widget.head != old.head) _shelf = widget.shelf;
    if (widget.open != old.open || widget.openListing != old.openListing) {
      _open = widget.open;
      _openListing = widget.openListing;
      _placed = false;
    }
    if (widget.search != old.search) _query = widget.search ?? '';
  }

  /// Every plugin the shelves have: the registry's (built-ins, the store packs that run, the dev packs while developer
  /// mode is on), then each store pack that doesn't run, then the checked listings for plugins not on this device (or
  /// a copy on it by another developer, which is offered as a new plugin).
  List<GhostPlugin> _every() => marketPlugins(_registry, widget.market);

  /// The plugin [id] among all three kinds, a listing only where asked for one or none else has the id.
  GhostPlugin? _find(String? id, {bool listing = false}) {
    if (id == null) return null;
    final all = _every().where((p) => p.id == id).toList();
    return (listing ? all.whereType<ListingPlugin>().firstOrNull : null) ?? all.where((p) => p is! ListingPlugin).firstOrNull ?? all.firstOrNull;
  }

  /// Listings and stuck packs are never asked of the registry: a leftover switch must not make a listing read as added.
  bool _isOn(GhostPlugin p, PluginStore store) => p is ListingPlugin || p is StuckPackPlugin ? false : _registry.isOn(p, store);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sought) return;
    _sought = true;
    // A search's hit for a plugin (its name, or a setting of its own) opens its page, the setting lit on it.
    final seek = SettingsSeek.of(context);
    if (seek == null) return;
    final folded = seek.toLowerCase();
    final every = _every();
    bool named(GhostPlugin p) => p.name.toLowerCase() == folded || (p.settingsPage?.label ?? '').toLowerCase() == folded;
    bool holds(GhostPlugin p) => _registry.settingsOf(p).any((s) => s.label.toLowerCase() == folded);
    // The plugin the link names, where the hit is one of its own: two plugins share labels ("Signal and Telegram",
    // "On this phone only"), and a hit in Spam filter's section opened Kinds of text's page, which comes first (review,
    // 2026-11-20). Only a hit with no plugin of its own (the unlisted plugins section's) is looked for across them all.
    final asked = _find(widget.open, listing: widget.openListing);
    final plugin = (asked != null && (named(asked) || holds(asked)) ? asked : null) ?? every.where(named).firstOrNull ?? every.where(holds).firstOrNull;
    if (plugin == null) return;
    // Opened as [PluginsPage.open] is: beside the shelves with room, over them on a phone (the first layout).
    _open = plugin.id;
    _openListing = plugin is ListingPlugin;
    if (plugin.name.toLowerCase() != folded) _seek = seek;
    if (_seek != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => WidgetsBinding.instance.addPostFrameCallback((_) => WidgetsBinding.instance.addPostFrameCallback((_) {
            final found = _finder.find(_seek!);
            if (found == null || !mounted) return;
            Scrollable.ensureVisible(found.context, alignment: 0.25, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
            found.light();
          })));
    }
  }

  bool _wide = false;

  /// The first layout has been: what was open from the start has been put where it goes.
  bool _placed = false;

  /// Adds [p]: a built-in or a store pack that is off is its switch; a listing asks first; a dev pack asks the first
  /// time, and whenever it can do something new since it was agreed to.
  void _add(GhostPlugin p) {
    final store = AppStore(AppState.of(context));
    if (p is ListingPlugin) return unawaited(addListing(context, p, market: widget.market));
    if (p.source == PluginSource.dev) return unawaited(switchOnDev(context, p, _registry, store));
    _registry.setOn(p, store, true);
  }

  /// Add on a card, or null where it can't be pressed: a stuck pack, or a listing this device can't take.
  VoidCallback? _addOf(GhostPlugin p) {
    if (p is StuckPackPlugin) return null;
    if (p is ListingPlugin && listingWhyNot(p) != null) return null;
    return () => _add(p);
  }

  /// [p]'s switch from its page: a store pack's Remove asks and deletes it, a dev pack's Remove only switches it off
  /// (deleting it is Settings › Developer's), a built-in's is its switch.
  void _switch(GhostPlugin p, bool on) {
    final store = AppStore(AppState.of(context));
    if (on) return _add(p);
    if (p is StuckPackPlugin || p.source == PluginSource.reviewed) return unawaited(removeStorePack(context, p));
    // A network signed in to is signed out by removing it: asked first, as Settings › Connections asks.
    final n = p is NetworkPlugin ? p.connection : null;
    if (n != null && (n.state == InboxState.ready || n.state == InboxState.signingIn)) return unawaited(turnOffNetwork(context, n));
    _registry.setOn(p, store, false);
  }

  /// A card pressed: with room its page stands beside the shelves (pressed again, it closes); otherwise it opens over
  /// them.
  void _openPlugin(GhostPlugin plugin) {
    final listing = plugin is ListingPlugin;
    if (_wide) {
      return setState(() {
        if (_open == plugin.id && _openListing == listing) {
          _open = null;
        } else {
          _open = plugin.id;
          _openListing = listing;
        }
      });
    }
    _push(plugin);
  }

  /// Its page over the shelves, looking the plugin up again on every build: a pack replaced by a new copy (an update,
  /// a reload) shows the new one, and the registry finds its settings. Once it is gone from this device and isn't
  /// listed either (removed while withdrawn, unlisted, or a plugin in development), the page goes: drawn as it was, its
  /// buttons acted on a plugin that was no longer there (review, 2026-11-20). One still listed comes back as its listing.
  void _push(GhostPlugin plugin) {
    final listing = plugin is ListingPlugin;
    push<void>(context, (context) => ListenableBuilder(
          listenable: Listenable.merge([_registry, InstalledPlugins.instance, ?widget.market]),
          builder: (context, _) {
            final now = _find(plugin.id, listing: listing);
            if (now == null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                final route = ModalRoute.of(context);
                if (route == null || !route.isActive) return;
                // Popped where it is on top, and taken out from under whatever is over it (its plugin's own screen).
                route.isCurrent ? Navigator.of(context).pop() : Navigator.of(context).removeRoute(route);
              });
              return PluginDetailPage(title: plugin.name, body: (context) => const SizedBox.shrink());
            }
            return PluginDetailPage(title: now.name, body: (context) => _detail(context, now, close: false));
          },
        ));
  }

  /// A tag pressed on a plugin's page: Discover searches for it, the page beside the shelves or over them put away.
  /// Added and In development have no search of their own, so the search is Discover's (D.4): in the Marketplace's
  /// pane where there is one, over this page where not. Set here, it left those pages showing another shelf under
  /// their own name (review, 2026-11-20).
  void _searchFor(String label, BuildContext from) {
    if (!_wide) Navigator.of(from).maybePop();
    if (!widget.head) {
      if (_wide) setState(() => _open = null);
      final shell = AppShell.maybeOf(context);
      if (shell != null) return shell.marketplace(section: 'discover', arg: label);
      unawaited(push<void>(context, (_) => PluginsPage(registry: widget.registry, title: 'Discover', market: widget.market, settingsOf: widget.settingsOf, summaryOf: widget.summaryOf, search: label)));
      return;
    }
    setState(() {
      _query = label;
      _shelf = null;
      _open = null;
    });
  }

  Widget _detail(BuildContext context, GhostPlugin plugin, {required bool close}) => pluginDetailOf(
        context,
        _registry,
        plugin,
        settingsOf: widget.settingsOf,
        summaryOf: widget.summaryOf,
        onClose: close ? () => setState(() => _open = null) : null,
        finder: _finder,
        seek: _seek,
        market: widget.market,
        onSwitch: (on) => _switch(plugin, on),
        onAdd: _addOf(plugin),
        onLabel: (label) => _searchFor(label, context),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([_registry, InstalledPlugins.instance, ?widget.market]),
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final t = context.tokens;
    final store = AppStore(AppState.of(context));
    return GhostPage(
      title: widget.title,
      body: LayoutBuilder(
        builder: (context, box) {
          _wide = box.maxWidth >= pluginsWide;
          // A plugin open from the start (or found by a search) on a phone: its page over the shelves, once they are
          // drawn. Decided here, where the width is known.
          if (!_wide && !_placed && _open != null) {
            final plugin = _find(_open, listing: _openListing);
            _open = null;
            if (plugin != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _push(plugin);
              });
            }
          }
          _placed = true;
          final open = _wide && _open != null ? _find(_open, listing: _openListing) : null;
          final foot = t.space(8) + MediaQuery.paddingOf(context).bottom;
          final shelves = ListView(
            key: const ValueKey('plugins-scroll'),
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), foot),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1180),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [if (widget.lead != null) widget.lead!, ..._page(context, t, store, wide: _wide, narrowed: open != null)]),
                ),
              ),
            ],
          );
          if (open == null) return shelves;
          final bevel = isBevelChrome(t);
          // As made, or as dragged (lib/ui/split_handle.dart): from 300 to what leaves the shelves 360.
          _paneWidth ??= PaneWidth.of(AppState.of(context), 'plugins');
          double fit(double w) => w.clamp(300.0, (box.maxWidth - 360).clamp(300.0, double.infinity));
          final paneW = fit(_paneWidth ?? math.min(440.0, box.maxWidth * 0.42));
          final grip = SplitHandle.widthOf(context);
          return Stack(children: [
            Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: shelves),
              Container(
                key: const ValueKey('plugins-pane'),
                width: paneW,
                decoration: BoxDecoration(
                  color: bevel ? DialupColors.of(t).chrome : t.color('app-paper'),
                  border: Border(left: BorderSide(color: bevel ? DialupColors.of(t).dark : t.color('app-rule'), width: t.len('glacier-hairline'))),
                ),
                child: ListView(
                  key: ValueKey('plugins-pane-${open.id}'),
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), foot),
                  children: [_detail(context, open, close: true)],
                ),
              ),
            ],
            ),
            PositionedDirectional(
              key: const ValueKey('plugins-split'),
              end: paneW - grip / 2,
              top: 0,
              bottom: 0,
              width: grip,
              child: SplitHandle(
                label: 'Resize the plugin\'s page',
                onDrag: (dx) => setState(() => _paneWidth = fit(fit(_paneWidth ?? paneW) - dx)),
                onDone: () => PaneWidth.keep(AppState.of(context), 'plugins', _paneWidth),
                onReset: () {
                  setState(() => _paneWidth = null);
                  PaneWidth.keep(AppState.of(context), 'plugins', null);
                },
              ),
            ),
          ]);
        },
      ),
    );
  }

  /// The plugin's page's width as dragged (PaneWidth 'plugins'); null for its width as made.
  double? _paneWidth;

  /// What the Marketplace says of plugins from other developers, in a line under the chips while All or From
  /// developers is chosen: why none show, or that some are still being checked. On an iPhone, that there are none.
  Widget? _catalogLine(Tokens t) {
    final m = widget.market;
    if (m == null || !widget.head || (_shelf != null && _shelf != _store)) return null;
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-2'));
    Widget line(String words, Key key, {Widget? then}) => Padding(
          key: key,
          padding: EdgeInsets.only(top: t.space(3)),
          child: Row(children: [Expanded(child: Text(words, style: quiet)), if (then != null) ...[SizedBox(width: t.space(2)), then]]),
        );
    if (marketOnIphone) return line('Plugins from other developers aren\'t on iPhone.', const ValueKey('market-ios'));
    final problem = m.problem;
    if (problem != null) {
      return switch (problem.code) {
        'unreachable' => line('Plugins from other developers couldn\'t be loaded.', const ValueKey('market-catalog-problem'), then: MarketButton(label: 'Try again', look: MarketButtonLook.ring, onPress: () => unawaited(m.refresh(force: true)))),
        'off' => line('The Marketplace isn\'t open just now.', const ValueKey('market-catalog-problem')),
        _ => line('This version of Uplink can\'t check plugins from other developers. Update it to see them.', const ValueKey('market-catalog-problem')),
      };
    }
    if (m.checking > 0) return line('Checking ${m.checking} ${m.checking == 1 ? 'plugin' : 'plugins'} from other developers…', const ValueKey('market-catalog-checking'));
    return null;
  }

  /// Everything on the shelves' side: the band, the search and the chips and what the chosen shelf holds; or, without
  /// [PluginsPage.head], the one shelf alone.
  List<Widget> _page(BuildContext context, Tokens t, PluginStore store, {required bool wide, required bool narrowed}) {
    final every = _every();
    final builtIn = _registry.plugins;
    final featured = [for (final id in featuredPlugins) ...builtIn.where((p) => p.id == id && p.source == PluginSource.builtIn)];
    final added = [for (final p in every) if (_isOn(p, store)) p];
    final stuck = [for (final p in every) if (p is StuckPackPlugin) p];
    final fromDevelopers = [for (final p in every) if (p.source == PluginSource.reviewed) p];
    final inDevelopment = [for (final p in every) if (p.source == PluginSource.dev) p];
    final shelves = [for (final s in PluginShelf.values) if (every.any((p) => p.shelf == s)) s];
    final shelf = _shelf;
    final query = _query.trim();
    final searching = query.isNotEmpty;
    final m = widget.market;
    // Meant for circles (a circle's owner or admins turn them on for everyone in it) or for this device alone: shown
    // apart (Matt, 2026-11-19: "Label plugins meant for circles in a separate section from the ones that are global").
    // A pack is never for circles (v1 is the device only).
    bool forCircles(GhostPlugin p) => p.scopes.contains(PluginScope.circle);
    final circled = [for (final p in builtIn) if (forCircles(p)) p];
    bool chosen(GhostPlugin p) => switch (shelf) {
          null => true,
          _added => _isOn(p, store) || p is StuckPackPlugin,
          _circles => forCircles(p),
          _store => p.source == PluginSource.reviewed,
          _dev => p.source == PluginSource.dev,
          final name => p.shelf.name == name,
        };
    final found = [for (final p in every) if (chosen(p) && (!searching || _matches(p, query))) p];
    final gap = t.space(6);

    Widget cards(List<GhostPlugin> plugins) {
      PluginCard card(GhostPlugin p) => PluginCard(
            plugin: p,
            added: _isOn(p, store),
            onAdd: _addOf(p),
            onOpen: () => _openPlugin(p),
            wide: wide,
            selected: _open == p.id && wide && (p is ListingPlugin) == _openListing,
            adding: p is ListingPlugin && (m?.adding(p.pack.id) ?? false),
          );
      if (!wide) {
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < plugins.length; i++) ...[if (i > 0) SizedBox(height: t.space(2)), card(plugins[i])],
        ]);
      }
      return MarketGrid(minWidth: t.lenOf(isBevelChrome(t) ? '20rem' : '14rem'), most: narrowed ? 2 : 4, children: [for (final p in plugins) card(p)]);
    }

    Widget shelfOf(String title, List<GhostPlugin> plugins, {String? meta, LucideIcon? icon, Key? key}) => Padding(
          key: key,
          padding: EdgeInsets.only(top: gap),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [MarketHeading(title: title, meta: meta, icon: icon), cards(plugins)]),
        );

    // A circle's plugins under their own heading, with a line saying who turns them on.
    Widget circleShelf(List<GhostPlugin> plugins) => Padding(
          key: const ValueKey('plugins-shelf-circles'),
          padding: EdgeInsets.only(top: gap),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MarketHeading(title: 'For circles', meta: '${plugins.length}', icon: Lucide.circleDot),
            Padding(
              padding: EdgeInsets.only(bottom: t.space(3)),
              child: Text(
                'A circle\'s owner or admins turn these on for everyone in it, in the circle\'s settings. Added here, one works for you in your own spaces and calls too.',
                style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4),
              ),
            ),
            cards(plugins),
          ]),
        );

    Widget nothing(String words, {bool every = true}) => Padding(
          key: const ValueKey('plugins-nothing'),
          padding: EdgeInsets.only(top: gap),
          child: Column(children: [
            Text(words, textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'))),
            if (every) ...[
              SizedBox(height: t.space(3)),
              MarketButton(
                label: 'Show every plugin',
                look: MarketButtonLook.ring,
                onPress: () => setState(() {
                  _query = '';
                  _shelf = null;
                }),
              ),
            ],
          ]),
        );

    // Added and In development, alone (the Marketplace's own rows): that shelf and nothing else, never "Show every
    // plugin", which is Discover's.
    if (!widget.head) {
      if (shelf == _dev) {
        // Those whose copy doesn't load (or can't run here) too, with their problems: the Marketplace's row counted
        // them while this page said nothing was loaded (review, 2026-11-20).
        final notLoading = [for (final d in InstalledPlugins.instance.dev) if (!d.running) d];
        if (inDevelopment.isEmpty && notLoading.isEmpty) return [nothing('Nothing loaded yet. Load one in Settings › Developer › Plugins in development.', every: false)];
        return [
          if (inDevelopment.isNotEmpty) shelfOf('In development', inDevelopment, meta: '${inDevelopment.length}', key: const ValueKey('plugins-shelf-dev')),
          if (notLoading.isNotEmpty)
            Padding(
              key: const ValueKey('plugins-shelf-dev-broken'),
              padding: EdgeInsets.only(top: gap),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                MarketHeading(title: 'Not loading', meta: '${notLoading.length}'),
                PaneSection(children: [
                  for (final d in notLoading)
                    SettingRow(
                      key: ValueKey('plugins-dev-broken-${d.id}'),
                      icon: const AppIcon(Lucide.flaskConical, size: 18),
                      label: d.pack?.name ?? d.plugin?.pack.name ?? d.id,
                      hint: Text(_notLoadingWords(d)),
                      onPress: () => unawaited(push<void>(context, (_) => DevPluginScreen(packId: d.id))),
                    ),
                ]),
              ]),
            ),
        ];
      }
      // Every plugin added here, those for circles too: on Discover they are a shelf of their own, which this page
      // hasn't, so they went missing here while its row counted them (review, 2026-11-20). Under their own heading, as
      // Matt asked (2026-11-19: "Label plugins meant for circles in a separate section from the ones that are global").
      final on = [for (final p in added) if (!forCircles(p)) p];
      final onCircles = [for (final p in added) if (forCircles(p)) p];
      // Under what is added, whether it is synced to the account's other devices (GMFB-9: lib/plugins/plugin_sync.dart).
      final sync = Padding(padding: EdgeInsets.only(top: gap), child: pluginSyncSection(context, AppState.of(context)));
      if (on.isEmpty && onCircles.isEmpty && stuck.isEmpty) return [nothing('Nothing added yet.', every: false), sync];
      return [
        if (on.isNotEmpty) shelfOf('Added', on, meta: '${on.length}', key: const ValueKey('plugins-shelf-added')),
        if (onCircles.isNotEmpty) shelfOf('For circles', onCircles, meta: '${onCircles.length}', icon: Lucide.circleDot, key: const ValueKey('plugins-shelf-added-circles')),
        if (stuck.isNotEmpty) shelfOf('Not running', stuck, meta: '${stuck.length}', key: const ValueKey('plugins-shelf-stuck')),
        sync,
      ];
    }

    final line = _catalogLine(t);
    final parts = <Widget>[
      PluginsBand(plugins: [...featured, ...every.where((p) => !featured.contains(p))], added: added.length, line: pluginsLine(), wide: wide),
      SizedBox(height: t.space(4)),
      GlacierSearchField(key: const ValueKey('plugins-search'), value: _query, placeholder: m == null ? 'Search plugins' : 'Search the Marketplace', size: GlacierFieldSize.md, onValueChange: (v) => setState(() => _query = v)),
      SizedBox(height: t.space(3)),
      _chips(t, [
        MarketChip(key: const ValueKey('plugins-chip-all'), label: 'All', chosen: shelf == null, onPress: () => setState(() => _shelf = null)),
        MarketChip(key: const ValueKey('plugins-chip-added'), label: 'Added', count: added.length, chosen: shelf == _added, onPress: () => setState(() => _shelf = _added)),
        if (circled.isNotEmpty) MarketChip(key: const ValueKey('plugins-chip-circles'), label: 'For circles', chosen: shelf == _circles, onPress: () => setState(() => _shelf = _circles)),
        if (fromDevelopers.isNotEmpty) MarketChip(key: const ValueKey('plugins-chip-store'), label: 'From developers', count: fromDevelopers.length, chosen: shelf == _store, onPress: () => setState(() => _shelf = _store)),
        if (inDevelopment.isNotEmpty) MarketChip(key: const ValueKey('plugins-chip-dev'), label: 'In development', count: inDevelopment.length, chosen: shelf == _dev, onPress: () => setState(() => _shelf = _dev)),
        for (final s in shelves) MarketChip(key: ValueKey('plugins-chip-${s.name}'), label: s.label, chosen: shelf == s.name, onPress: () => setState(() => _shelf = s.name)),
      ], wide: wide),
      ?line,
    ];

    if (found.isEmpty) {
      parts.add(nothing(searching ? 'Nothing called “$query”.' : (shelf == _added ? 'No plugin is added yet.' : 'No plugin here yet.')));
      return parts;
    }

    if (searching) {
      parts.add(shelfOf('Found', found, meta: '${found.length}', icon: Lucide.search, key: const ValueKey('plugins-shelf-found')));
      return parts;
    }

    if (shelf == null) {
      if (featured.isNotEmpty) {
        final featuredCards = [
          for (final p in featured) FeaturedPluginCard(plugin: p, added: _registry.isOn(p, store), onAdd: () => _add(p), onOpen: () => _openPlugin(p)),
        ];
        // Tall enough for a pitch of three or four lines under the name, whole.
        final height = t.lenOf(isBevelChrome(t) ? '13rem' : '14.5rem');
        parts.add(Padding(
          key: const ValueKey('plugins-featured'),
          padding: EdgeInsets.only(top: gap),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const MarketHeading(title: 'Featured', icon: Lucide.sparkles),
            // Across wherever the three fit, a plugin's page beside the shelves or not; else in a row that scrolls, so
            // the third is not left alone on a row of its own. On a phone the next card peeks past the edge; beside a
            // plugin's page the row fades out before the divider rather than being cut off flat against it.
            LayoutBuilder(builder: (context, box) {
              final least = t.lenOf(narrowed ? '12rem' : '14rem');
              final gap = t.space(3);
              if (wide && box.maxWidth >= featuredCards.length * least + (featuredCards.length - 1) * gap) {
                return MarketGrid(minWidth: least, most: featuredCards.length, children: [for (final c in featuredCards) SizedBox(height: height, child: c)]);
              }
              return MarketRow(width: math.min(t.lenOf('17rem'), box.maxWidth * 0.8), height: height, fade: wide, children: featuredCards);
            }),
          ]),
        ));
      }
      // What is on this device, packs among them, and those that don't run after them with why; then what isn't,
      // listings among them ("More to add" in the Marketplace, where Discover is the whole page's name).
      final mine = [for (final p in added) if (!forCircles(p)) p, ...stuck];
      final global = [for (final p in every) if (!forCircles(p)) p];
      final discover = [for (final p in global) if (!_isOn(p, store) && p is! StuckPackPlugin) p];
      if (mine.isNotEmpty) parts.add(shelfOf('Added', mine, meta: '${mine.length - stuck.length} of ${global.length}', key: const ValueKey('plugins-shelf-added')));
      if (discover.isNotEmpty) parts.add(shelfOf(m == null ? 'Discover' : 'More to add', discover, meta: '${discover.length}', key: const ValueKey('plugins-shelf-discover')));
      if (circled.isNotEmpty) parts.add(circleShelf(circled));
      return parts;
    }

    if (shelf == _circles) {
      parts.add(circleShelf(found));
      return parts;
    }
    // The two shelves of plugins from other developers are named here: they are no PluginShelf of the app's.
    final title = switch (shelf) {
      _added => 'Added',
      _store => 'From developers',
      _dev => 'In development',
      _ => PluginShelf.values.byName(shelf).label,
    };
    parts.add(shelfOf(title, found, meta: '${found.length}', key: ValueKey('plugins-shelf-$shelf')));
    return parts;
  }

  /// The shelves' chips: on a phone a row that scrolls sideways, as a market's filter does (wrapped, "Messages" was
  /// left alone on a second row); with room, wrapped, where they fit on one line.
  Widget _chips(Tokens t, List<Widget> chips, {required bool wide}) {
    final gap = t.space(2);
    if (wide) return Wrap(key: const ValueKey('plugins-chips'), spacing: gap, runSpacing: gap, children: chips);
    return SingleChildScrollView(
      key: const ValueKey('plugins-chips'),
      scrollDirection: Axis.horizontal,
      // Past the page's gutter as it scrolls, to the screen's edge.
      clipBehavior: Clip.none,
      child: Row(children: [for (var i = 0; i < chips.length; i++) ...[if (i > 0) SizedBox(width: gap), chips[i]]]),
    );
  }

  /// Why a plugin in development isn't running, in a few words for its row: its problems, or what holds it back.
  static String _notLoadingWords(DevPack d) {
    final errors = d.issues.where((i) => i.isError).length;
    if (d.pack == null) return errors == 0 ? 'Its copy doesn\'t load' : '$errors ${errors == 1 ? 'problem' : 'problems'}';
    return switch (d.problem) {
      'id_installed' => 'Its id is a plugin\'s from the Marketplace here',
      'too_many_packs' => 'As many plugins from other developers are here as may be',
      _ => 'It isn\'t running',
    };
  }

  /// Whether [plugin] answers the search: its name, its lines, its shelf, what it adds, who made it and its tags.
  bool _matches(GhostPlugin plugin, String query) => pluginMatches(plugin, query);
}

/// Every plugin the Marketplace has: [registry]'s (built-ins, the store packs that run, the dev packs while developer
/// mode is on), then each store pack that doesn't run, then [market]'s checked listings for plugins not on this device
/// (or for one whose copy here is by another developer, which is offered as a new plugin). None from other developers
/// on an iPhone.
List<GhostPlugin> marketPlugins(PluginRegistry registry, MarketState? market) {
  final here = InstalledPlugins.instance;
  return [
    ...registry.plugins,
    for (final p in here.store)
      if (!p.running) StuckPackPlugin(p),
    if (market != null && here.storeAllowed)
      for (final l in market.listings)
        if (here.devOf(l.pack.id) == null && (here.storeOf(l.pack.id) == null || identical(market.developerChanged(l.pack.id), l))) l,
  ];
}

/// Whether [plugin] answers [query]: its name, its lines, its shelf, what it adds, who made it and its tags by the
/// names they are shown by. The Marketplace's own search reads the same.
bool pluginMatches(GhostPlugin plugin, String query) => settingsMatch(query, [plugin.name, plugin.tagline, plugin.description, plugin.shelf.label, ...plugin.adds, plugin.settingsPage?.label ?? '', plugin.developer ?? '', for (final l in plugin.labels) packLabels[l] ?? l].join(' '));

/// A plugin's page as the Plugins page and a plugin's own screen draw it: Add or Remove, and once it is added its
/// settings and what they come to. A plugin from another developer's page has its [PackPage] made here: where it came
/// from, Update, Reload, its problems, Report, and why a stuck one doesn't run.
Widget pluginDetailOf(
  BuildContext context,
  PluginRegistry registry,
  GhostPlugin plugin, {
  List<Widget> Function(BuildContext context, GhostPlugin plugin)? settingsOf,
  String? Function(BuildContext context, GhostPlugin plugin)? summaryOf,
  VoidCallback? onClose,
  SettingsFinder? finder,
  String? seek,
  MarketState? market,
  ValueChanged<bool>? onSwitch,
  VoidCallback? onAdd,
  ValueChanged<String>? onLabel,
}) {
  final store = AppStore(AppState.of(context));
  final listing = plugin is ListingPlugin;
  final stuck = plugin is StuckPackPlugin;
  final added = listing || stuck ? false : registry.isOn(plugin, store);
  final page = plugin.source == PluginSource.builtIn ? null : _packPage(context, registry, plugin, market: market, onAdd: onAdd, onLabel: onLabel);
  return PluginDetail(
    key: ValueKey('plugins-page-${plugin.id}'),
    plugin: plugin,
    added: added,
    here: pluginsHere(),
    onSwitch: onSwitch ?? (on) => registry.setOn(plugin, store, on),
    summary: added ? summaryOf?.call(context, plugin) : null,
    settings: added ? (settingsOf?.call(context, plugin) ?? const []) : const [],
    hasSettings: registry.settingsOf(plugin).isNotEmpty || plugin.settingsPage != null,
    onClose: onClose,
    finder: finder,
    seek: seek,
    pack: page,
  );
}

/// What the page of a plugin from another developer has beyond the app's own: which kind it is (a listing, a store
/// pack, one that doesn't run, one in development) and what each of its buttons does.
PackPage _packPage(BuildContext context, PluginRegistry registry, GhostPlugin plugin, {MarketState? market, VoidCallback? onAdd, ValueChanged<String>? onLabel}) {
  final here = InstalledPlugins.instance;
  final m = market ?? MarketState.instance;
  final id = packIdOf(plugin.id);
  final pack = packOf(plugin);
  final kind = switch (plugin) {
    ListingPlugin() => PackKind.listing,
    StuckPackPlugin() => PackKind.stuck,
    _ when plugin.source == PluginSource.dev => PackKind.dev,
    _ => PackKind.store,
  };
  final installed = id == null ? null : here.storeOf(id);
  final dev = id == null ? null : here.devOf(id);
  final update = kind == PackKind.store || kind == PackKind.stuck ? m.updates.where((u) => u.installed.id == id).firstOrNull : null;
  final support = pack?.support;
  final (problems, warnings) = dev == null ? (0, 0) : devPackCounts(dev);
  return PackPage(
    kind: kind,
    pack: pack,
    onAdd: kind == PackKind.listing ? onAdd : null,
    // Under the buttons, why Add can't be pressed: not the nohere words again, which have their own box.
    whyNot: plugin is ListingPlugin && !marketNoTexts ? listingWhyNot(plugin) : null,
    adding: plugin is ListingPlugin && m.adding(plugin.pack.id),
    updateTo: update?.listing.version,
    onUpdate: update == null ? null : () => unawaited(updateStorePack(context, update.listing, market: m)),
    onReload: dev != null && dev.source.reloadable ? () => unawaited(_reload(context, dev.id)) : null,
    problems: problems,
    warnings: warnings,
    onProblems: dev == null ? null : () => unawaited(push<void>(context, (_) => DevPluginScreen(packId: dev.id))),
    onReport: kind == PackKind.listing || kind == PackKind.store ? () => unawaited(reportPlugin(context, plugin, market: m)) : null,
    stuck: plugin is StuckPackPlugin ? stuckWords(plugin.problem, why: installed?.revoked?.why, here: pluginsHere()) : null,
    // A plugin in development pauses as a store pack does, and its pause is kept across a reload of the same copy.
    paused: (kind == PackKind.store && installed?.problem == 'paused') || (kind == PackKind.dev && dev?.problem == 'paused'),
    onUnpause: id == null ? null : () => here.unpause(id),
    nohere: marketNoTexts,
    takenFrom: plugin is ListingPlugin ? _takenFrom(here.storeOf(plugin.pack.id), plugin) : null,
    shotOf: kind == PackKind.listing || kind == PackKind.store ? m.shotOf : null,
    onLabel: onLabel,
    onSupport: support == null ? null : () => unawaited(_help(context, support)),
  );
}

/// Whose copy adding the listing [l] would take away: [had]'s developer where it is someone else's, '' where nothing
/// here can tell who made it (MarketState.developerChanged counts that as someone else's), null where [l] is that
/// copy's developer's own or there is no copy.
String? _takenFrom(InstalledPack? had, ListingPlugin l) => had == null || (had.developer != null && had.developer == l.pack.developer) ? null : had.developer ?? '';

/// Reads a plugin in development again from where it was loaded, and says whether it must be agreed to afresh.
Future<void> _reload(BuildContext context, String packId) async {
  final out = await InstalledPlugins.instance.reloadDev(packId);
  if (!context.mounted) return;
  toast(context, out.ok ? (out.needsConsent ? '${out.plugin!.name} reloaded. Switch it on to agree to what it can do now.' : '${out.plugin!.name} reloaded') : out.message, tone: out.ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
}

/// A pack's help: an https address opened in the browser, an email address copied (the app opens no mail of its own).
Future<void> _help(BuildContext context, String support) async {
  if (support.contains('@') && !support.contains('://')) {
    await Clipboard.setData(ClipboardData(text: support));
    if (context.mounted) toast(context, 'Address copied');
    return;
  }
  if (packAddressIssue(support) == null) await Sms.instance.openLink(support);
}

/// A plugin's own section of Settings (`plugin-<id>`, opened by a link or a search): its page from the Plugins page,
/// on a screen of its own. It was a plain list of rows with the plugin's switch on a card at its top, then a second
/// switch for translating as texts come, which read as two switches saying different things; now it is the same page
/// as on the shelves, its colour across the head and Add or Remove under it.
class PluginScreen extends StatefulWidget {
  const PluginScreen({super.key, required this.registry, required this.plugin, this.settingsOf, this.summaryOf});

  final PluginRegistry registry;
  final GhostPlugin plugin;
  final List<Widget> Function(BuildContext context, GhostPlugin plugin)? settingsOf;
  final String? Function(BuildContext context, GhostPlugin plugin)? summaryOf;

  @override
  State<PluginScreen> createState() => _PluginScreenState();
}

class _PluginScreenState extends State<PluginScreen> {
  final _finder = SettingsFinder();
  String? _seek;
  bool _sought = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sought) return;
    _sought = true;
    // A search's hit for one of its settings: lit on the page, as the Plugins page lights it.
    final seek = SettingsSeek.of(context);
    if (seek == null || seek.toLowerCase() == widget.plugin.name.toLowerCase()) return;
    _seek = seek;
    WidgetsBinding.instance.addPostFrameCallback((_) => WidgetsBinding.instance.addPostFrameCallback((_) {
          final found = _finder.find(seek);
          if (found == null || !mounted) return;
          Scrollable.ensureVisible(found.context, alignment: 0.25, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
          found.light();
        }));
  }

  @override
  Widget build(BuildContext context) => PluginDetailPage(
        title: widget.plugin.name,
        body: (context) => pluginDetailOf(context, widget.registry, widget.plugin, settingsOf: widget.settingsOf, summaryOf: widget.summaryOf, finder: _finder, seek: _seek),
      );
}

/// The Marketplace's band, where Settings' list had its way to the Plugins page: the band, short, with a few of the
/// plugins' tiles on it and how many are added. Ringed in the ink while its page stands beside the list.
class PluginsEntry extends StatelessWidget {
  const PluginsEntry({super.key, required this.registry, required this.onOpen, this.selected = false, this.extra = const []});

  final PluginRegistry registry;
  final VoidCallback onOpen;
  final bool selected;

  /// Plugins from other developers counted and drawn after the registry's: the stuck packs and the listings.
  final List<GhostPlugin> extra;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final store = AppStore(AppState.of(context));
    final all = [...registry.plugins, ...extra];
    final featured = [for (final id in featuredPlugins) ...all.where((p) => p.id == id && p.source == PluginSource.builtIn)];
    final added = registry.plugins.where((p) => registry.isOn(p, store)).length;
    final radius = isBevelChrome(t) ? 0.0 : t.radius('lg') * 1.2;
    return GlacierPressable(
      key: const ValueKey('plugins-entry'),
      onPressed: onOpen,
      semanticLabel: 'Marketplace, $added of ${all.length} added',
      selected: selected,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: radius,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 140),
          scale: state.pressed && !isBevelChrome(t) ? 0.985 : 1,
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), border: selected ? Border.all(color: t.color('app-ink'), width: 2) : null),
            child: ExcludeSemantics(child: PluginsBand(plugins: [...featured, ...all.where((p) => !featured.contains(p))], added: added, line: pluginsLine(), wide: false, compact: true)),
          ),
        ),
      ),
    );
  }
}
