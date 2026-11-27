/// Plugins the Marketplace draws that the registry never holds (Matt, 2026-11-20: "I would like users to be able to
/// develop and submit their own plugins to our plugin marketplace"): a listing, an approved plugin not on this device
/// whose package the app has fetched and checked, and a store pack on this device that doesn't run (withdrawn, or no
/// longer checking out, or unreadable). Each is a [GhostPlugin] only so the shelves, the cards and a plugin's page draw
/// it as they draw any other; neither is ever put in the registry, switched on or asked about texts.
library;

import 'dart:typed_data';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../plugins/pack/pack.dart';
import '../plugins/plugin.dart';
import 'market_models.dart';
import 'market_state.dart';

/// An approved plugin from the catalog, drawn from its checked package [pack] alone: nothing the catalog says of it
/// reaches a card, its page or the consent sheet (SPEC H.1 6).
class ListingPlugin extends GhostPlugin {
  ListingPlugin(this.entry, this.pack, this.market, {bool needsNewerApp = false}) : _newer = needsNewerApp;

  final CatalogEntry entry;
  final PluginPack pack;
  final MarketState market;
  final bool _newer;

  @override
  String get id => registryIdOf(pack.id);
  @override
  String get name => pack.name;
  @override
  String get description => pack.description;
  @override
  String get tagline => pack.tagline;
  @override
  String get hue => pack.hue;
  @override
  PluginShelf get shelf => PluginShelf.values.asNameMap()[pack.shelf] ?? PluginShelf.tools;
  @override
  List<String> get labels => pack.labels;
  @override
  String? get developer => pack.developer;
  @override
  String? get version => pack.version;
  @override
  LucideIcon get icon => Lucide.all[pack.symbol] ?? Lucide.puzzle;
  @override
  Uint8List? get iconPng => pack.icon;

  /// Made once: the cards and the page ask for them on every build.
  @override
  late final List<PluginReach> reaches = packReaches(pack);
  @override
  late final List<String> adds = packAdds(pack);
  @override
  PluginSource get source => PluginSource.reviewed;
  @override
  bool get onByDefault => false;

  /// Its minApp is newer than this app: shown, and Add says it needs a newer Uplink.
  bool get needsNewerApp => _newer;
}

/// A store pack on this device that doesn't run ([InstalledPack.running] false), for its card on Added and its page:
/// what it is from its pack where that parses, else from the listing.json kept beside it, and why it doesn't run.
class StuckPackPlugin extends GhostPlugin {
  StuckPackPlugin(this.installed);

  final InstalledPack installed;

  PluginPack? get _pack => installed.pack;
  String? _kept(String key) => installed.listing[key] is String ? installed.listing[key] as String : null;

  @override
  String get id => registryIdOf(installed.id);
  @override
  String get name => _pack?.name ?? _kept('name') ?? installed.id;
  @override
  String get tagline => _pack?.tagline ?? _kept('tagline') ?? '';
  @override
  String get description => _pack?.description ?? tagline;
  @override
  String get hue => _pack?.hue ?? _kept('hue') ?? 'slate';
  @override
  PluginShelf get shelf => PluginShelf.values.asNameMap()[_pack?.shelf] ?? PluginShelf.tools;
  @override
  LucideIcon get icon => Lucide.all[_pack?.symbol ?? _kept('symbol')] ?? Lucide.puzzle;
  @override
  Uint8List? get iconPng => _pack?.icon;
  @override
  List<String> get labels => _pack?.labels ?? const [];
  @override
  String? get developer => installed.developer;
  @override
  String? get version => installed.version;
  @override
  late final List<PluginReach> reaches = _pack == null ? const [] : packReaches(_pack!);
  @override
  late final List<String> adds = _pack == null ? const [] : packAdds(_pack!);
  @override
  PluginSource get source => PluginSource.reviewed;
  @override
  bool get onByDefault => false;

  /// Why it doesn't run: revoked, bad_approval, untrusted_key, invalid, needs_newer_app, io, id_taken or too_many_packs.
  String? get problem => installed.problem;
}

/// The pack behind [plugin], where it is one: a listing's or a stuck pack's own, a running pack's, or what this device
/// holds for its id (a store pack's or a dev pack's). Null for a built-in.
PluginPack? packOf(GhostPlugin plugin, {InstalledPlugins? installed}) {
  if (plugin is ListingPlugin) return plugin.pack;
  if (plugin is StuckPackPlugin) return plugin.installed.pack;
  if (plugin is PackPlugin) return plugin.pack;
  if (plugin.source == PluginSource.builtIn) return null;
  final id = packIdOf(plugin.id);
  if (id == null) return null;
  final here = installed ?? InstalledPlugins.instance;
  return plugin.source == PluginSource.dev ? (here.devOf(id)?.plugin?.pack ?? here.devOf(id)?.pack) : here.storeOf(id)?.pack;
}
