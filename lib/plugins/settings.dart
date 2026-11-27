/// Settings › Plugins, which is the Marketplace since 2026-11-20 (lib/ui/market/; Matt: "Move plugins out of settings
/// into a marketplace button on the navigation rail with a marketplace icon"), each plugin's settings on its page there.
/// The section stays, unlisted, with its list of the kit's cards and rows ([pluginsPane]), every plugin with its switch,
/// and each plugin keeps its own section ([pluginPages]), so Settings' search still finds a plugin, and a plugin's
/// setting, by name, and a hit opens the Marketplace at it (lib/ui/settings.dart).
library;

import '../platform_info.dart';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../sms.dart';
import '../market/market_state.dart';
import '../ui/inbox_ui.dart' show networkPluginCard;
import '../ui/settings.dart';
import '../ui/plugins_page/plugins_page.dart';
import '../ui/plugins_page/plugin_sync_row.dart';
import 'networks.dart';
import 'plugin.dart';
import 'registry.dart';
import '../l10n/words.dart';

/// The plugins' sections of Settings: Plugins itself, there once the app has a plugin to switch, and after it a
/// section for each plugin that has one of its own ([GhostPlugin.settingsPage]), which Settings' list does not show
/// (the Plugins page leads to its settings) but a link or a search still opens.
List<SettingsSection> pluginsSettings() => PluginRegistry.instance.isEmpty ? const [] : [pluginsSection(), ...pluginPages()];

/// Settings › Plugins, for the app's own plugins or, in a test, for [registry]'s. No longer a row of Settings' list, a
/// band on it, a ring's menu entry, or the first section beside it: the Marketplace is all of those now (Matt,
/// 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail with a marketplace
/// icon"). Its [page] stays what Settings' search reads (every plugin's switch row by name, and the cards of those that
/// are on, packs included), and a hit there opens the Marketplace at that plugin.
SettingsSection pluginsSection([PluginRegistry? registry]) => SettingsSection(
      id: 'plugins',
      label: 'Marketplace',
      icon: const AppIcon(Lucide.store, size: 18),
      hue: 'rose',
      group: 'plugins',
      listed: false,
      summary: (m) {
        final r = registry ?? PluginRegistry.instance;
        final store = AppStore(m.app);
        final on = [for (final p in r.plugins) if (r.isOn(p, store)) p.name];
        return on.isEmpty ? 'None on' : on.join(' · ');
      },
      page: (context, m) => pluginsPane(context, m.app, registry ?? PluginRegistry.instance),
    );

/// The Plugins page for the app's own plugins or [registry]'s, each one's settings on its page once it is added: the
/// cards its own section in Settings has ([pluginPages]). The tests' shelves: the Marketplace's are [marketPluginsScreen].
Widget pluginsScreen([PluginRegistry? registry, String? open]) {
  final r = registry ?? PluginRegistry.instance;
  return PluginsPage(registry: r, open: open, settingsOf: (context, p) => _ownOf(context, p, r), summaryOf: (context, p) => _summaryOf(context, p, r));
}

/// The Marketplace's shelves (Discover, Added, In development): the app's plugins with those from other developers, the
/// checked listings among them, so a plugin's own settings still show on its page once it is added. [shelf] is the chip
/// chosen at first; [head] false is that shelf alone, with no band, search or chips; [lead] stands above it.
Widget marketPluginsScreen({String title = 'Discover', String? shelf, String? open, bool openListing = false, bool head = true, Widget? lead, String? search}) => PluginsPage(
      registry: PluginRegistry.instance,
      title: title,
      shelf: shelf,
      open: open,
      openListing: openListing,
      head: head,
      lead: lead,
      search: search,
      market: MarketState.instance,
      settingsOf: (context, p) => _ownOf(context, p, PluginRegistry.instance),
      summaryOf: (context, p) => _summaryOf(context, p, PluginRegistry.instance),
    );

/// [plugin]'s own settings as the kit's cards, as its page draws them once it is on: a dev pack's own screen too.
List<Widget> pluginOwnSettings(BuildContext context, GhostPlugin plugin, [PluginRegistry? registry]) => _ownOf(context, plugin, registry ?? PluginRegistry.instance);

/// One plugin's page from the Plugins page on a screen of its own: its section of Settings ([pluginPages]).
Widget pluginScreen(GhostPlugin plugin, [PluginRegistry? registry]) {
  final r = registry ?? PluginRegistry.instance;
  return PluginScreen(registry: r, plugin: plugin, settingsOf: (context, p) => _ownOf(context, p, r), summaryOf: (context, p) => _summaryOf(context, p, r));
}

List<Widget> _ownOf(BuildContext context, GhostPlugin p, PluginRegistry r) {
  final n = p is NetworkPlugin ? p.connection : null;
  return [if (n != null) networkPluginCard(context, n), ..._own(context, p, r, AppStore(AppState.of(context)), title: null)];
}

String? _summaryOf(BuildContext context, GhostPlugin p, PluginRegistry r) => p.settingsPage?.summary?.call(r.prefsOf(p, AppStore(AppState.of(context))));

/// A section of Settings for each plugin that asks for one (Matt, 2026-11-14: "the plugins and all being able to
/// make their own setting sections"): its row is under Plugins, on or off, and its page is its own switch, at the top
/// (Matt, the same day: "Plugins should be able to be toggled on and off from the top of each plugin setting page"),
/// then its own settings while it is on.
List<SettingsSection> pluginPages([PluginRegistry? registry]) {
  final r = registry ?? PluginRegistry.instance;
  return [
    for (final p in r.plugins)
      if (p.settingsPage != null)
        SettingsSection(
          id: 'plugin-${p.id}',
          label: p.settingsPage!.label ?? p.name,
          icon: AppIcon(p.icon, size: 18),
          hue: p.settingsPage!.hue,
          group: 'plugins',
          // Not a row of Settings' list since the Plugins page (Matt, 2026-11-17): the plugin's page there leads to
          // these settings. Still opened by its id, and still read by Settings' search.
          listed: false,
          summary: (m) {
            final store = AppStore(m.app);
            if (!r.isOn(p, store)) return 'Off';
            return p.settingsPage!.summary?.call(r.prefsOf(p, store)) ?? p.description;
          },
          // Its page from the Plugins page (Matt, 2026-11-17: "redo how the plugins look with their own dedicated
          // plugins page with a marketplace like look how ghostmd has"); [page] stays what Settings' search reads.
          screen: (context, m) => pluginScreen(p, r),
          page: (context, m) {
            final store = AppStore(m.app);
            final on = r.isOn(p, store);
            return [
              PaneSection(
                description: p.settingsPage!.intro == null ? null : Text(p.settingsPage!.intro!),
                children: [
                  SettingRow(
                    icon: AppIcon(p.icon, size: 18),
                    label: p.name,
                    hint: Text(on ? p.description : 'Off. ${p.description}'),
                    control: GlacierSwitch(checked: on, onCheckedChange: (yes) => r.setOn(p, store, yes), ariaLabel: p.name),
                  ),
                ],
              ),
              if (on) ..._own(context, p, r, store, title: null),
            ];
          },
        ),
  ];
}

/// Every plugin in one card with its switch, then a card of its own settings for each that is on and has no page in
/// the Marketplace.
List<Widget> pluginsPane(BuildContext context, AppState app, PluginRegistry registry) {
  final store = AppStore(app);
  return [
    PaneSection(
      title: 'Plugins',
      description: Text('Extra things the app can do with your messages. Each one works on this ${Sms.remote ? (PlatformInfo.isIOS ? 'iPhone' : 'computer') : 'phone'} alone, and does nothing while it is off.'),
      footer: registry.plugins.any((p) => p.settingsPage != null) ? const Tr('Each plugin\'s settings are on its page in the Marketplace.') : null,
      children: [
        for (final p in registry.plugins)
          SettingRow(
            icon: AppIcon(p.icon, size: 18),
            label: p.name,
            hint: Text(p.description),
            control: GlacierSwitch(checked: registry.isOn(p, store), onCheckedChange: (on) => registry.setOn(p, store, on), ariaLabel: p.name),
          ),
      ],
    ),
    // A card here for each plugin that is on and keeps its settings on this page.
    for (final p in registry.plugins)
      if (registry.isOn(p, store) && p.settingsPage == null) ..._own(context, p, registry, store, title: p.name),
    // Which are on, synced across the Uplink account's devices (GMFB-9): the app's own plugins', not a test's registry.
    if (identical(registry, PluginRegistry.instance)) pluginSyncSection(context, app),
  ];
}

/// A plugin's own settings as cards: the rows it describes in words ([GhostPlugin.settings]), a new card at each of
/// its headings, then what it puts in the settings slot. No card where it has neither.
List<Widget> _own(BuildContext context, GhostPlugin plugin, PluginRegistry registry, PluginStore store, {required String? title, String? description}) {
  final prefs = registry.prefsOf(plugin, store);
  final cards = <PaneSection>[];
  var heading = title;
  Widget? intro = description == null ? null : Text(description);
  var rows = <Widget>[];
  void close() {
    if (rows.isNotEmpty) cards.add(PaneSection(title: heading, description: intro, children: rows));
    rows = <Widget>[];
  }

  for (final s in registry.settingsOf(plugin)) {
    if (s.heading) {
      close();
      heading = s.label.t;
      intro = s.hint == null ? null : Text(s.hint!.t);
      continue;
    }
    rows.addAll(_row(s, prefs));
  }
  rows.addAll(registry.widgets(Slots.settings, context, const SettingsPlace(), store, only: plugin));
  close();
  return cards;
}

/// The row, or rows, one setting is drawn as.
List<Widget> _row(PluginSetting s, PluginPrefs prefs) {
  final icon = s.icon == null ? null : AppIcon(s.icon!, size: 18);
  if (s.options.isNotEmpty) {
    final chosen = prefs.get(s.key!) ?? s.choice;
    return [
      if (s.hint != null || icon != null) SettingRow(icon: icon, label: s.label, hint: s.hint == null ? null : Text(s.hint!.t)),
      for (final o in s.options)
        SettingRow(
          label: o.label,
          hint: o.hint == null ? null : Text(o.hint!.t),
          control: Pick(checked: chosen == o.value, label: '${s.label}: ${o.label}', onPress: () => prefs.set(s.key!, o.value)),
        ),
    ];
  }
  if (s.words) {
    return [
      SettingRow(
        icon: icon,
        label: s.label,
        hint: s.hint == null ? null : Text(s.hint!.t),
        layout: SettingRowLayout.stacked,
        control: _WordsField(key: ValueKey('words-${s.key}'), prefs: prefs, keyName: s.key!, label: s.label, placeholder: s.placeholder),
      ),
    ];
  }
  return [
    SettingRow(
      icon: icon,
      label: s.label,
      hint: s.hint == null ? null : Text(s.hint!.t),
      control: s.key == null ? null : GlacierSwitch(checked: prefs.flag(s.key!, fallback: s.fallback), onCheckedChange: (on) => prefs.setFlag(s.key!, on), ariaLabel: s.label),
    ),
  ];
}

/// Words typed with commas between them, kept a line each when the field is left or Enter is pressed.
class _WordsField extends StatefulWidget {
  const _WordsField({super.key, required this.prefs, required this.keyName, required this.label, this.placeholder});
  final PluginPrefs prefs;
  final String keyName;
  final String label;
  final String? placeholder;

  @override
  State<_WordsField> createState() => _WordsFieldState();
}

class _WordsFieldState extends State<_WordsField> {
  late final _text = TextEditingController(text: wordsOf(widget.prefs, widget.keyName).join(', '));

  @override
  void dispose() {
    _save();
    _text.dispose();
    super.dispose();
  }

  /// Kept a line each, as [wordsOf] reads them; written only where they changed, and once more as the field goes.
  void _save() {
    final words = [for (final w in _text.text.split(RegExp(r'[\n,]'))) if (w.trim().isNotEmpty) w.trim()];
    final kept = words.join('\n');
    if (kept != (widget.prefs.get(widget.keyName) ?? '')) widget.prefs.set(widget.keyName, kept);
  }

  @override
  Widget build(BuildContext context) => GlacierInput(
        controller: _text,
        placeholder: (widget.placeholder ?? 'Words, with commas between them').t,
        ariaLabel: widget.label,
        autoCorrect: false,
        autoCapitalize: TextCapitalization.none,
        size: GlacierFieldSize.md,
        onSubmitted: (_) => _save(),
        onBlur: _save,
      );
}
