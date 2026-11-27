/// Plugins in development (Matt, 2026-11-20: "please add a developer setting for users to be able to manually upload
/// plugins for development testing"): Settings › Developer's card for loading a plugin you're making (from a file, by
/// pasting it, from a link that Reload fetches again), a row for each with its switch, and its own screen, where its
/// problems, what it threw lately, Try it, its settings, Reload and Remove are all in one place.
///
/// A pack loaded here isn't reviewed by anyone: switching it on the first time, or after a reload that lets it do
/// more, asks first (lib/ui/market/market_flows.dart switchOnDev), it runs only while developer mode is on, and the
/// conversations list says while one is (lib/ui/conversations.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/market_files.dart';
import '../../plugins/pack/pack.dart';
import '../../plugins/plugin.dart';
import '../../plugins/registry.dart';
import '../../plugins/settings.dart' show pluginOwnSettings;
import '../../sms.dart';
import '../circles/new_circle.dart' show askCircleWords;
import '../common.dart';
import '../plugins_page/plugin_art.dart';
import '../plugins_page/plugins_page.dart' show marketOnIphone, pluginsHere;
import '../shell.dart';
import 'market_flows.dart';
import 'market_forms.dart' show issueLines;
import 'try_pack.dart';
import '../../l10n/words.dart';

/// How a dev pack came, in the row's words.
String _fromWords(DevSource s) => switch (s.kind) {
      'file' => 'from a file',
      'paste' => 'pasted',
      'link' => 'from a link',
      _ => 'from the API',
    };

/// The running copy of [packId] in [registry], where there is one.
GhostPlugin? _plugin(String packId, PluginRegistry registry) => registry.plugins.where((p) => p.id == registryIdOf(packId) && p.source == PluginSource.dev).firstOrNull;

/// How a dev pack stands, in a word or two, with how many problems it has and how many warnings apart: a warning
/// doesn't stop it loading, and the docs' own Parcels, whose link button always has one, read "1 problem" for a file
/// that loads cleanly (review, 2026-11-20).
String devPackState(DevPack d, PluginRegistry registry, PluginStore store) {
  final (problems, warnings) = devPackCounts(d);
  final plugin = _plugin(d.id, registry);
  final state = switch (d) {
    _ when d.pack == null && d.plugin == null && plugin == null => null,
    _ when d.problem == 'paused' => 'paused',
    _ when d.needsConsent => 'needs your OK',
    _ when plugin != null && registry.isOn(plugin, store) => 'running',
    _ => 'off',
  };
  return [?state, if (problems > 0) '$problems ${problems == 1 ? 'problem' : 'problems'}', if (warnings > 0) '$warnings ${warnings == 1 ? 'warning' : 'warnings'}'].join(' · ');
}

/// A dev pack's problems (its newest copy's errors, and what it threw or was refused while running) and its warnings.
(int, int) devPackCounts(DevPack d) => (d.issues.where((i) => i.isError).length + d.errors.length, d.issues.where((i) => !i.isError).length);

/// Settings › Developer's Plugins in development, from the app's choices and the packs on this device alone (a search
/// builds the page with no app round it), of plain rows so Settings' search finds each. Nothing at all in an App Store
/// build, which has no plugins in development (SPEC G.5).
List<Widget> devPluginsPane(BuildContext context, AppState app, {PluginRegistry? registry}) {
  final here = InstalledPlugins.instance;
  if (!here.devAllowed) return const [];
  final r = registry ?? PluginRegistry.instance;
  final store = AppStore(app);
  final shell = AppShell.maybeOf(context);
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  return [
    PaneSection(
      key: const ValueKey('dev-plugins'),
      title: 'Plugins in development',
      description: Text('Load a plugin you\'re making to try it on this ${pluginsHere()}. It isn\'t reviewed, and runs only while Developer mode is on.'),
      children: [
        if (canPickPluginFile)
          SettingRow(key: const ValueKey('dev-plugin-file'), icon: icon(Lucide.folderOpen), label: 'Load a plugin from a file', hint: const Tr('A .ghostplugin file.'), onPress: () => unawaited(_fromFile(context))),
        SettingRow(key: const ValueKey('dev-plugin-paste'), icon: icon(Lucide.clipboardPaste), label: 'Paste a plugin', hint: const Tr('Its words, copied from anywhere.'), onPress: () => unawaited(_pasted(context))),
        SettingRow(
          key: const ValueKey('dev-plugin-link'),
          icon: icon(Lucide.link),
          label: 'Load a plugin from a link',
          hint: const Tr('https, or http://127.0.0.1 with adb reverse. Reload fetches it again.'),
          onPress: () => askCircleWords(context, title: 'Load a plugin from a link', hint: 'Its address: https, or http://127.0.0.1 with adb reverse.', then: (words) {
            final url = Uri.tryParse(words.trim());
            if (words.trim().isEmpty) return;
            if (url == null || !url.hasScheme) return toast(context, 'That isn\'t an address.', tone: GlacierToastTone.danger);
            unawaited(loadDevPlugin(context, () => here.loadDevFromLink(url)));
          }),
        ),
        for (final d in here.dev)
          Builder(builder: (context) {
            final plugin = _plugin(d.id, r);
            final name = d.pack?.name ?? d.plugin?.name ?? d.id;
            return SettingRow(
              key: ValueKey('dev-plugin-${d.id}'),
              icon: plugin == null ? icon(Lucide.flaskConical) : PluginTile(plugin: plugin, size: context.tokens.lenOf('1.85rem')),
              label: name,
              hint: Text([d.pack?.version ?? d.plugin?.version ?? 'Doesn\'t load', _fromWords(d.source), devPackState(d, r, store)].where((s) => s.isNotEmpty).join(' · ')),
              control: GlacierSwitch(
                key: ValueKey('dev-plugin-switch-${d.id}'),
                checked: plugin != null && r.isOn(plugin, store),
                disabled: plugin == null,
                onCheckedChange: plugin == null ? null : (on) => on ? unawaited(switchOnDev(context, plugin, r, store)) : r.setOn(plugin, store, false),
                ariaLabel: name,
              ),
              onPress: () => unawaited(push<void>(context, (_) => DevPluginScreen(packId: d.id))),
            );
          }),
        if (!marketOnIphone && shell != null) SettingRow(key: const ValueKey('dev-plugin-submit'), icon: icon(Lucide.send), label: 'Submit a plugin to the Marketplace', onPress: () => shell.marketplace(section: 'submit')),
        SettingRow(key: const ValueKey('dev-plugin-docs'), icon: icon(Lucide.bookOpen), label: 'How to build and test one', onPress: () => openDocs('plugin-testing')),
      ],
    ),
  ];
}

/// Loads a plugin in development from a file the person picks.
Future<void> _fromFile(BuildContext context) async {
  final PickedPlugin? picked;
  try {
    picked = await pickPluginFile();
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t open that file: $e', tone: GlacierToastTone.danger);
    return;
  }
  if (picked == null || !context.mounted) return;
  await loadDevPlugin(context, () => InstalledPlugins.instance.loadDev(picked!.bytes, DevSource('file', path: picked.path, name: picked.name)));
}

/// Loads a plugin in development from the words on the clipboard.
Future<void> _pasted(BuildContext context) async {
  final data = await Clipboard.getData('text/plain');
  final text = data?.text?.trim() ?? '';
  if (!context.mounted) return;
  if (text.isEmpty) return toast(context, 'Copy the plugin\'s words first, then paste them here.');
  await loadDevPlugin(context, () => InstalledPlugins.instance.loadDev(utf8.encode(text), const DevSource('paste')));
}

/// A .ghostplugin shared in from another app on Android with developer mode on (lib/ui/files_space/share_in.dart):
/// loaded in development, not put in a Files space. [read] gives its bytes (the copy Android's share hands over).
Future<void> loadSharedPlugin(BuildContext context, String source, String name, {Future<Uint8List?> Function(String source)? read}) async {
  Uint8List? bytes;
  try {
    bytes = await (read ?? _readShared)(source);
  } catch (_) {}
  if (!context.mounted) return;
  if (bytes == null) return toast(context, 'Couldn\'t read $name.', tone: GlacierToastTone.danger);
  await loadDevPlugin(context, () => InstalledPlugins.instance.loadDev(bytes!, DevSource('file', name: name)));
}

Future<Uint8List?> _readShared(String source) async {
  final copy = await Sms.instance.cacheCopy(source);
  final file = File(copy);
  try {
    final out = BytesBuilder(copy: false);
    await for (final piece in file.openRead(0, PackLimits.packageBytes + 1)) {
      out.add(piece);
    }
    return out.takeBytes();
  } finally {
    if (copy != source) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }
}

/// Runs [load] and says how it went: loaded, and waiting to be agreed to where it is, with how many warnings it has;
/// a broken copy kept with how many problems it has, on its row; or, for words that aren't a plugin at all (no row,
/// nothing written), a sheet of what is wrong with them.
Future<void> loadDevPlugin(BuildContext context, Future<PackOutcome> Function() load) async {
  final here = InstalledPlugins.instance;
  // Each copy as it stood, to tell a copy kept with its problems (a good id) from words that made no row at all.
  final before = {for (final d in here.dev) d.id: d.loadedAt};
  PackOutcome out;
  try {
    out = await load();
  } catch (e) {
    out = PackOutcome.failed('failed', 'Couldn\'t load it: $e');
  }
  if (!context.mounted) return;
  final problems = out.issues.length;
  final words = '$problems ${problems == 1 ? 'problem' : 'problems'}: see its row';
  if (out.ok) {
    // A copy that loads has warnings at most (a link button always has opens_links): it is loaded, and the consent's
    // line is said whatever it warns of. "1 problem: see its row" was all the docs' own Parcels was told (review,
    // 2026-11-20).
    final name = out.plugin?.name ?? 'The plugin';
    final warnings = out.issues.where((i) => !i.isError).length;
    final loaded = out.needsConsent ? '$name loaded. Switch it on to agree to what it can do now.' : '$name loaded';
    // A sentence of its own after "Bills loaded", which has no full stop where no consent is asked ("Parcels loaded One
    // warning", review, 2026-11-20).
    toast(context, warnings == 0 ? loaded : '${out.needsConsent ? loaded : '$loaded.'} ${warnings == 1 ? 'One warning' : '$warnings warnings'}: see its row.', tone: GlacierToastTone.success);
    return;
  }
  final kept = here.dev.any((d) => before[d.id] == null || before[d.id] != d.loadedAt);
  if (out.code == 'invalid' && problems > 0) return kept ? toast(context, words) : showDevProblems(context, out.issues);
  toast(context, out.message, tone: GlacierToastTone.danger);
}

/// What is wrong with words that couldn't be loaded at all, each issue's code, where and what, to copy.
Future<void> showDevProblems(BuildContext context, List<PackIssue> issues) {
  final t = context.tokens;
  final mono = TextStyle(fontFamily: 'JetBrains Mono Variable', fontSize: t.fontSize('xs'), height: 1.45, color: t.color('app-ink-2'));
  String line(PackIssue i) => '${i.code}${i.path.isEmpty ? '' : ' at ${i.path}'}: ${i.message}';
  return showChoices(context, title: issues.length == 1 ? 'It couldn\'t be loaded' : 'It couldn\'t be loaded: ${issues.length} problems', header: Padding(
    key: const ValueKey('dev-plugin-problems'),
    padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final i in issues.take(40)) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text(line(i), style: mono))]),
  ), choices: [
    Choice('Copy the problems', Lucide.copy, () async {
      await Clipboard.setData(ClipboardData(text: issues.map(line).join('\n')));
      if (context.mounted) toast(context, 'Problems copied');
    }),
    Choice('Close', Lucide.x, () {}),
  ]);
}

/// A plugin in development's own screen: this copy, its problems, what it threw lately, Try it, its own settings once
/// it is on, and Reload, Open in the Marketplace, Submit it and Remove. It looks its pack up by id on every build, so a
/// reload shows the new copy.
class DevPluginScreen extends StatelessWidget {
  const DevPluginScreen({super.key, required this.packId, this.registry});

  final String packId;
  final PluginRegistry? registry;

  @override
  Widget build(BuildContext context) {
    final r = registry ?? PluginRegistry.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([InstalledPlugins.instance, r]),
      builder: (context, _) {
        final t = context.tokens;
        final app = AppState.of(context);
        final store = AppStore(app);
        final here = InstalledPlugins.instance;
        final d = here.devOf(packId);
        final shell = AppShell.maybeOf(context);
        final plugin = _plugin(packId, r);
        final pack = d?.pack ?? d?.plugin?.pack;
        final mono = TextStyle(fontFamily: 'JetBrains Mono Variable', fontSize: t.fontSize('xs'), height: 1.45, color: t.color('app-ink-2'));
        Widget icon(LucideIcon i) => AppIcon(i, size: 18);
        String when(DateTime at) => '${at.year}-${_two(at.month)}-${_two(at.day)} ${_two(at.hour)}:${_two(at.minute)}';
        return GhostPage(
          key: ValueKey('dev-plugin-screen-$packId'),
          title: pack?.name ?? packId,
          body: d == null
              ? Center(child: Padding(padding: EdgeInsets.all(t.space(6)), child: Text('It isn\'t loaded any more.', style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2')))))
              : ListView(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
                  children: [
                    PaneBody(children: [
                      PaneSection(title: 'This copy', children: [
                        SettingRow(icon: icon(Lucide.flaskConical), label: 'Where from', value: Text([_fromWords(d.source), ?d.source.name, ?d.source.url].join(' · '))),
                        SettingRow(icon: icon(Lucide.clock), label: 'Loaded', value: Text(when(d.loadedAt))),
                        SettingRow(icon: icon(Lucide.tag), label: 'Version', value: Text(pack?.version ?? 'Doesn\'t load')),
                        SettingRow(icon: icon(Lucide.hash), label: 'Id', value: Text(packId)),
                        SettingRow(icon: icon(Lucide.activity), label: 'Now', value: Text(devPackState(d, r, store).ifEmpty('Doesn\'t load'))),
                      ]),
                      PaneSection(key: ValueKey('dev-plugin-issues-$packId'), title: 'Problems', children: [
                        if (d.issues.isEmpty)
                          SettingRowBox(child: Tr('None: it checks out.', style: mono))
                        else
                          SettingRowBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            for (final line in issueLines(d.issues, (i) => '${i.isError ? '' : 'warning '}${i.code}${i.path.isEmpty ? '' : ' at ${i.path}'}: ${i.message}')) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text(line, style: mono)),
                          ])),
                      ]),
                      PaneSection(key: ValueKey('dev-plugin-errors-$packId'), title: 'Lately', footer: const Tr('What it threw, or was refused, while it ran: the newest first.'), children: [
                        if (d.errors.isEmpty)
                          SettingRowBox(child: Tr('Nothing has gone wrong yet.', style: mono))
                        else
                          SettingRowBox(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            for (final e in d.errors) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text('${when(e.at)} ${e.line}', style: mono)),
                          ])),
                      ]),
                    ]),
                    if (pack != null) ...[
                      SizedBox(height: t.space(4)),
                      KeyedSubtree(key: ValueKey('dev-plugin-try-$packId-section'), child: TryPackSection(pack, keyPrefix: 'dev-plugin-', keySuffix: '-$packId', store: store)),
                    ],
                    if (plugin != null && r.isOn(plugin, store)) ...[
                      SizedBox(height: t.space(4)),
                      GlacierScope(attrs: {'hue': plugin.hue}, child: PaneBody(children: pluginOwnSettings(context, plugin, r))),
                    ],
                    SizedBox(height: t.space(4)),
                    PaneSection(children: [
                      // Paused for slowing the app down, as a store pack is: the pause is kept for this copy across a
                      // reload of the same file and a restart, so it is turned back on here, or on its page (D.4).
                      if (d.problem == 'paused')
                        SettingRow(key: ValueKey('dev-plugin-unpause-$packId'), icon: icon(Lucide.play), label: 'Turn it back on', hint: const Tr('Paused: it was slowing the app down.'), onPress: () => here.unpause(packId)),
                      if (d.source.reloadable)
                        SettingRow(key: ValueKey('dev-plugin-reload-$packId'), icon: icon(Lucide.refreshCw), label: 'Reload', hint: Text(d.source.kind == 'link' ? 'Fetches it again from ${d.source.url}.' : 'Reads the file again.'), onPress: () => unawaited(loadDevPlugin(context, () => here.reloadDev(packId)))),
                      if (shell != null)
                        SettingRow(key: ValueKey('dev-plugin-open-$packId'), icon: icon(Lucide.store), label: 'Open in the Marketplace', onPress: () => shell.marketplace(plugin: registryIdOf(packId))),
                      // Its newest copy is what would be sent: one that doesn't load can't be, and the form opened on
                      // it held another plugin (review, 2026-11-20).
                      if (shell != null && !marketOnIphone)
                        SettingRow(key: ValueKey('dev-plugin-submit-$packId'), icon: icon(Lucide.send), label: 'Submit it to the Marketplace', hint: d.pack == null ? const Tr('Put its problems right first.') : null, disabled: d.pack == null, onPress: d.pack == null ? null : () => shell.marketplace(section: 'submit', arg: packId)),
                      SettingRow(
                        key: ValueKey('dev-plugin-remove-$packId'),
                        icon: icon(Lucide.trash2),
                        label: 'Remove',
                        labelColor: t.color('app-danger'),
                        hint: const Tr('Its copy goes from this device. Your choices for it are kept for when you load it again.'),
                        onPress: () async {
                          final out = await here.removeDev(packId);
                          if (!context.mounted) return;
                          toast(context, out.ok ? '${pack?.name ?? packId} removed' : out.message, tone: out.ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
                          if (out.ok) Navigator.of(context).maybePop();
                        },
                      ),
                    ]),
                  ],
                ),
        );
      },
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
