/// What the Marketplace asks before it acts (Matt, 2026-11-20: "I would like users to be able to develop and submit their
/// own plugins to our plugin marketplace and I'd like to be able to verify them for the store through a review
/// process"): adding a listing after a sheet that says, from its checked package alone, what it reads and adds;
/// switching on a plugin in development after the same sheet, which says nobody reviewed it; removing a store pack;
/// updating one, asking again where the new version can do more; reporting one; and the Updates page.
library;

import 'dart:async';
import '../../platform_info.dart';

import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextCapitalization, TextInputType;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../market/listing_plugin.dart';
import '../../market/market_api.dart';
import '../../market/market_models.dart';
import '../../market/market_state.dart';
import '../../me/me.dart';
import '../../net/net.dart';
import '../../plugins/pack/pack.dart';
import '../../plugins/plugin.dart';
import '../../plugins/registry.dart';
import '../../sms.dart';
import '../../voice/channels.dart' show Voice;
import '../common.dart';
import '../plugins_page/market_parts.dart' show MarketButton, MarketButtonLook;
import '../plugins_page/plugin_art.dart';
import '../plugins_page/plugins_page.dart' show pluginsHere;
import 'market_forms.dart' show MarketLengthLimit;
import '../../plugins/plugin_sync.dart';
import '../../l10n/words.dart';

/// A computer on its own, with no phone's texts: a plugin from another developer has nothing here to sort.
bool get marketNoTexts => Sms.standalone && !PlatformInfo.isAndroid && !PlatformInfo.isIOS;

/// The words a page says where a pack can't sort here.
const String marketNoTextsWords = 'This plugin sorts texts, which this computer doesn\'t have.';

/// Why the listing [l] can't be added on this device, or null where it can.
String? listingWhyNot(ListingPlugin l) {
  if (marketNoTexts) return marketNoTextsWords;
  if (l.needsNewerApp) return 'Needs a newer Uplink';
  return null;
}

/// The consent sheet's head (D.5), all of it made from the checked [pack]: its tile, who made it, that it was reviewed
/// (or, [dev], that nobody did), each line of what it reads as on its page, what it adds, and where it works.
class MarketConsent extends StatelessWidget {
  const MarketConsent({super.key, required this.pack, required this.plugin, this.dev = false});

  final PluginPack pack;

  /// What its tile is drawn from (its picture and colour are its pack's).
  final GhostPlugin plugin;
  final bool dev;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = t.color('app-ink');
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-3'));
    final body = pageText(t, t.fontSize('md'), height: 1.4, color: ink);
    Widget line(LucideIcon icon, String label, {String? hint, Key? key}) => Padding(
          key: key,
          padding: EdgeInsets.only(top: t.space(2)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: EdgeInsets.only(top: t.lenOf('0.15rem')), child: AppIcon(icon, size: 16, strokeWidth: 2.2, color: t.color('app-ink-2'), wash: false)),
            SizedBox(width: t.space(2)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: body),
                if (hint != null) Text(hint, style: quiet),
              ]),
            ),
          ]),
        );
    final adds = packAdds(pack);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          PluginTile(plugin: plugin, size: t.lenOf('2.6rem')),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pack.name, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink)),
              if (pack.developer != null) Text('By @${pack.developer}', style: quiet),
            ]),
          ),
        ]),
        SizedBox(height: t.space(2)),
        if (dev)
          line(Lucide.flaskConical, 'Not reviewed by anyone: switch this on only if you made it.', key: const ValueKey('market-consent-dev'))
        else
          line(LucideMore.badgeCheck, 'Reviewed by Uplink'),
        for (final r in packReaches(pack)) line(r.icon, r.label, hint: r.hint),
        if (adds.isNotEmpty) ...[
          Padding(padding: EdgeInsets.only(top: t.space(3)), child: Text('It adds:', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
          for (final a in adds) line(Lucide.check, a),
        ],
        Padding(padding: EdgeInsets.only(top: t.space(3)), child: Text('It works on this ${pluginsHere()} alone. Remove it at any time from its page in the Marketplace.', style: quiet)),
      ]),
    );
  }
}

/// Adds the listing [l] once its sheet is agreed to. A new version by another developer than the copy on this device
/// first removes that copy and its choices (D.5). Toasts how it went: its first tab named, or why not.
Future<void> addListing(BuildContext context, ListingPlugin l, {MarketState? market}) async {
  final m = market ?? MarketState.instance;
  final why = listingWhyNot(l);
  if (why != null) return toast(context, why, tone: GlacierToastTone.danger);
  await showChoices(context, title: 'Add ${l.name}?', header: MarketConsent(key: const ValueKey('market-consent'), pack: l.pack, plugin: l), choices: [
    Choice('Add ${l.name}', Lucide.plus, () => unawaited(_add(context, l, m))),
    Choice('Not now', Lucide.x, () {}),
  ]);
}

/// Adds the listing once agreed to, over any store copy of the same pack already here, and says where its tab is.
Future<void> _add(BuildContext context, ListingPlugin l, MarketState m) async {
  if (m.installed.storeOf(l.pack.id) != null) {
    final gone = await m.installed.removeStore(l.pack.id, forget: true);
    if (!gone.ok) {
      if (context.mounted) toast(context, gone.message, tone: GlacierToastTone.danger);
      return;
    }
  }
  final out = await m.install(l);
  if (!context.mounted) return;
  if (!out.ok) return toast(context, out.message, tone: GlacierToastTone.danger);
  final tab = l.pack.rules.sections.where((s) => s.kind == 'tab').firstOrNull;
  toast(context, tab == null ? '${l.name} added' : '${l.name} added. Its ${tab.label} tab is in Messages.', tone: GlacierToastTone.success);
}

/// Switches the plugin in development [plugin] on: at once where its lines have been agreed to, else after the consent
/// sheet that says nobody reviewed it (a first switch-on, or a reload whose lines grew).
Future<void> switchOnDev(BuildContext context, GhostPlugin plugin, PluginRegistry registry, PluginStore store) async {
  final id = packIdOf(plugin.id);
  if (id == null) return;
  final here = InstalledPlugins.instance;
  if (here.mayTurnOnDev(id)) return registry.setOn(plugin, store, true);
  final pack = packOf(plugin) ?? here.devOf(id)?.pack;
  if (pack == null) return;
  await showChoices(context, title: 'Switch on ${plugin.name}?', header: MarketConsent(key: const ValueKey('market-consent'), pack: pack, plugin: plugin, dev: true), choices: [
    Choice('Switch it on', Lucide.check, () async {
      final out = await here.agreeDev(id);
      if (!out.ok && context.mounted) toast(context, out.message, tone: GlacierToastTone.danger);
    }),
    Choice('Not now', Lucide.x, () {}),
  ]);
}

/// Removes the store pack [plugin] once that is agreed to: its files go, its choices stay.
Future<void> removeStorePack(BuildContext context, GhostPlugin plugin) async {
  final id = packIdOf(plugin.id);
  if (id == null) return;
  final t = context.tokens;
  await showChoices(context, title: 'Remove ${plugin.name}?', header: Padding(
    padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
    child: Text('It\'s deleted from this ${pluginsHere()}. Your choices for it are kept if you add it again.', key: const ValueKey('market-remove-confirm'), style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
  ), choices: [
    Choice('Remove ${plugin.name}', Lucide.trash2, () async {
      final out = await InstalledPlugins.instance.removeStore(id);
      // Off on the account's other devices (GMFB-9): switched off there, not deleted (lib/plugins/plugin_sync.dart).
      if (out.ok) PluginSync.instance.switched(plugin.id, false);
      if (!context.mounted) return;
      toast(context, out.ok ? '${plugin.name} removed' : out.message, tone: out.ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
    }, danger: true),
    Choice('Keep it', Lucide.x, () {}),
  ]);
}

/// What [now] can do that [before] couldn't: the lines of its privacy card and of what it adds, compared as text, that
/// the copy on this device hasn't (everything, where that copy can't be read). The lines are the runtime's own, as a
/// pack in development's consent keeps them (DevPack.consentLines), so the two never disagree on what is new; both
/// read as on [here] (this device where null; the review screen asks for a phone's, where a pack does the most).
({List<PluginReach> reaches, List<String> adds}) packGrew(PluginPack now, PluginPack? before, {String? here}) {
  String line(PluginReach r) => r.hint == null ? r.label : '${r.label}: ${r.hint}';
  final had = before == null ? const <String>{} : DevPack.consentLines(before, here: here).toSet();
  return (reaches: [for (final r in packReaches(now, here: here)) if (!had.contains(line(r))) r], adds: [for (final a in packAdds(now, here: here)) if (!had.contains(a)) a]);
}

/// Updates the store pack of [l]'s id to [l], keeping its switch as it is; first a sheet of only what the new version
/// can do that the copy here can't, where there is any (a new host, a new tab, a new permission).
Future<void> updateStorePack(BuildContext context, ListingPlugin l, {MarketState? market}) async {
  final m = market ?? MarketState.instance;
  final grew = packGrew(l.pack, m.installed.storeOf(l.pack.id)?.pack);
  if (grew.reaches.isEmpty && grew.adds.isEmpty) return _update(context, l, m);
  final t = context.tokens;
  final ink = pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink'));
  final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-3'));
  await showChoices(context, title: 'Update ${l.name}?', header: Padding(
    key: const ValueKey('market-update-grew'),
    padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('It can now:', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
      for (final r in grew.reaches) Padding(padding: EdgeInsets.only(top: t.space(2)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(r.label, style: ink), if (r.hint != null) Text(r.hint!, style: quiet)])),
      for (final a in grew.adds) Padding(padding: EdgeInsets.only(top: t.space(2)), child: Text(a, style: ink)),
    ]),
  ), choices: [
    Choice('Update ${l.name}', Lucide.download, () => unawaited(_update(context, l, m))),
    Choice('Not now', Lucide.x, () {}),
  ]);
}

Future<void> _update(BuildContext context, ListingPlugin l, MarketState m) async {
  final out = await m.update(l);
  if (!context.mounted) return;
  toast(context, out.ok ? '${l.name} is up to date: ${l.version}' : out.message, tone: out.ok ? GlacierToastTone.success : GlacierToastTone.danger);
}

/// Reports [plugin]: why, then a few words more (never the person's texts) and whether to send their username, then
/// route 7, signed with the person's own key.
Future<void> reportPlugin(BuildContext context, GhostPlugin plugin, {MarketState? market}) {
  final t = context.tokens;
  return showChoices(context, title: 'Report ${plugin.name}', header: Padding(
    padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
    child: Text('What\'s wrong with it? Every report is read.', key: const ValueKey('market-report'), style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
  ), choices: [
    for (final r in ReportReason.values) Choice(r.label, Lucide.flag, () => unawaited(push<void>(context, (_) => _ReportPage(plugin: plugin, reason: r, market: market)))),
  ]);
}

/// A report's second step: a few words more, whether to send the username with it, and Send.
class _ReportPage extends StatefulWidget {
  const _ReportPage({required this.plugin, required this.reason, this.market});
  final GhostPlugin plugin;
  final ReportReason reason;
  final MarketState? market;

  @override
  State<_ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<_ReportPage> {
  final _words = TextEditingController();
  final _focus = FocusNode();
  bool _name = false;
  bool _sending = false;

  @override
  void dispose() {
    _words.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final m = widget.market ?? MarketState.instance;
    final id = packIdOf(widget.plugin.id);
    final username = Me.instance.username;
    if (id == null) return;
    // Said here, and nothing sent: the relay holds a report's words to a plugin's own rule and answers a slip with
    // "Something in that isn't right." alone, so a report with an emoji made of several couldn't be sent at all, nor
    // said why (review, 2026-11-20).
    final words = marketWords(_words.text);
    final problem = marketWordsProblem(words, MarketMost.report);
    if (problem != null) return toast(context, 'Your words: $problem', tone: GlacierToastTone.danger);
    setState(() => _sending = true);
    try {
      await m.api.report(
        PluginReport(plugin: id, version: widget.plugin.version ?? '', reason: widget.reason, text: words, username: _name && username != null ? tidyHandle(username) : null),
        signer: Net.instance.hub?.signer ?? Voice.instance.signer,
      );
      if (!mounted) return;
      toast(context, 'Thanks: it will be looked at.', tone: GlacierToastTone.success);
      Navigator.of(context).maybePop();
    } on MarketError catch (e) {
      if (mounted) toast(context, e.message, tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink'));
    final username = Me.instance.username;
    return GhostPage(
      title: 'Report ${widget.plugin.name}',
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          PaneSection(title: 'Say more', description: Text(widget.reason.label), children: [
            SettingRowBox(
              child: GestureDetector(
                key: const ValueKey('market-report-words'),
                onTap: _focus.requestFocus,
                child: Container(
                  constraints: BoxConstraints(minHeight: t.lenOf('7rem')),
                  padding: EdgeInsets.all(t.space(3)),
                  decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('md'))),
                  child: Stack(children: [
                    ListenableBuilder(listenable: _words, builder: (context, _) => _words.text.isEmpty ? IgnorePointer(child: Tr('Don\'t paste your texts here.', style: ink.copyWith(color: t.color('app-ink-3')))) : const SizedBox.shrink()),
                    Semantics(
                      label: 'Say more',
                      textField: true,
                      child: EditableText(
                        controller: _words,
                        focusNode: _focus,
                        style: ink,
                        cursorColor: t.color('app-ink'),
                        backgroundCursorColor: t.color('app-ink-3'),
                        selectionColor: t.textSelection,
                        minLines: 4,
                        maxLines: 10,
                        keyboardType: TextInputType.multiline,
                        textCapitalization: TextCapitalization.sentences,
                        inputFormatters: [LengthLimitingTextInputFormatter(MarketMost.report), MarketLengthLimit(MarketMost.report)],
                        readOnly: _sending,
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
          SizedBox(height: t.space(4)),
          PaneSection(children: [
            if (username != null)
              SettingRow(
                key: const ValueKey('market-report-name'),
                icon: const AppIcon(Lucide.atSign, size: 18),
                label: 'Send my username with it',
                hint: Text('@${tidyHandle(username)}, so the reviewer can ask you about it.'),
                control: GlacierSwitch(checked: _name, onCheckedChange: (on) => setState(() => _name = on), ariaLabel: 'Send my username with it'),
              ),
            SettingRow(key: const ValueKey('market-report-send'), icon: const AppIcon(Lucide.send, size: 18), label: _sending ? 'Sending…' : 'Send the report', onPress: _sending ? null : _send),
          ]),
        ],
      ),
    );
  }
}

/// Marketplace › Updates: each waiting update, from the version here to the new one with what's new, and Update;
/// Update all for those that can do nothing new. Stays, saying so, once the last is done.
class MarketUpdatesPage extends StatefulWidget {
  const MarketUpdatesPage({super.key, this.market});
  final MarketState? market;

  @override
  State<MarketUpdatesPage> createState() => _MarketUpdatesPageState();
}

class _MarketUpdatesPageState extends State<MarketUpdatesPage> {
  /// Update all is running: its row says so and can't be pressed again.
  bool _all = false;

  /// Updates each of [quiet] in turn and says how it went: how many were updated, and what stopped the first that
  /// wasn't. "2 updated" was said whatever happened, a disk that refused the write or a version this app can't run
  /// among it (review, 2026-11-20).
  Future<void> _updateAll(MarketState m, List<({InstalledPack installed, ListingPlugin listing})> quiet) async {
    if (_all) return;
    setState(() => _all = true);
    final failed = <(ListingPlugin, PackOutcome)>[];
    var ok = 0;
    try {
      for (final u in quiet) {
        final out = await m.update(u.listing);
        out.ok ? ok++ : failed.add((u.listing, out));
      }
    } finally {
      if (mounted) setState(() => _all = false);
    }
    if (!mounted) return;
    if (failed.isEmpty) return toast(context, '$ok updated', tone: GlacierToastTone.success);
    final (first, why) = failed.first;
    toast(context, [if (ok > 0) '$ok updated.', '${first.name}: ${why.message}', if (failed.length > 1) '${failed.length - 1} more couldn\'t be updated.'].join(' '), tone: GlacierToastTone.danger);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.market ?? MarketState.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([m, InstalledPlugins.instance]),
      builder: (context, _) {
        final t = context.tokens;
        final ups = m.updates;
        final quiet = [for (final u in ups) if (() { final g = packGrew(u.listing.pack, u.installed.pack); return g.reaches.isEmpty && g.adds.isEmpty; }()) u];
        return GhostPage(
          key: const ValueKey('market-updates'),
          title: 'Updates',
          body: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            children: [
              if (ups.isEmpty)
                Padding(
                  padding: EdgeInsets.all(t.space(4)),
                  child: Text('Everything\'s up to date.', key: const ValueKey('market-updates-none'), textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'))),
                )
              else ...[
                PaneSection(children: [
                  for (final u in ups)
                    SettingRow(
                      key: ValueKey('market-update-${u.installed.id}'),
                      icon: PluginTile(plugin: u.listing, size: t.lenOf('1.85rem')),
                      label: u.listing.name,
                      hint: Text([
                        '${u.installed.version} → ${u.listing.version}',
                        if ((u.listing.pack.whatsNew ?? '').isNotEmpty) u.listing.pack.whatsNew!,
                      ].join('\n')),
                      control: MarketButton(label: m.adding(u.installed.id) ? 'Updating…' : 'Update', look: MarketButtonLook.ring, onPress: m.adding(u.installed.id) || _all ? null : () => updateStorePack(context, u.listing, market: m)),
                    ),
                ]),
                if (ups.length > 1 && quiet.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: t.space(4)),
                    child: PaneSection(children: [
                      SettingRow(
                        key: const ValueKey('market-update-all'),
                        icon: const AppIcon(Lucide.download, size: 18),
                        label: _all ? 'Updating…' : 'Update all',
                        hint: Text(quiet.length == ups.length ? 'All ${ups.length}.' : '${quiet.length} of ${ups.length}: the others can do something new, so each asks first.'),
                        disabled: _all,
                        onPress: _all ? null : () => unawaited(_updateAll(m, quiet)),
                      ),
                    ]),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
