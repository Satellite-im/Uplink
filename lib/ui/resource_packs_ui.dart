import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../custom_theme.dart';
import '../kit/settings_kit.dart';
import '../l10n/words.dart';
import '../packs/resource_pack.dart';
import 'common.dart';

/// Textures: what the look in use is drawn with, under every look in Settings › Appearance (Matt, 2026-11-27: "I think
/// we should add texture packs to all themes, but remove the phosphor entirely and remove the dark dial uptheme, also
/// remove lamplight and mist and make them texture packs for the Ghost theme").
///
/// A look's packs are of two kinds (lib/looks.dart): sets of rules that are part of the app, which were looks of
/// their own before (Mist and Lamplight, Uplink's), and a resource pack's pictures, fetched to the device (Runestone's:
/// lib/packs/resource_pack.dart; Matt, 2026-11-27: "see how we can get the dark vanilla texture pack", then "let's
/// try the duckscape theme instead and bring in the pixelated looks", and, of the look in flat stone on his phone, "I
/// see the runestone theme but I wanted it to use the duckscape look"). The section lists the look's own first, then
/// each pack, the one in use ticked; a look nobody has made a pack for yet says so.

/// Settings › Appearance's section for the look in use, whichever it is.
PaneSection texturesSection(BuildContext context, AppState app) {
  final t = context.tokens;
  final look = app.look, family = look.family;
  final packs = ResourcePacks.instance;
  // A look drawn with a resource pack's pictures, on a device that can fetch one (not a browser).
  final pictures = family.pictures && ResourcePacks.here;
  final chosen = pictures ? ResourcePacks.chosen(app) : '';
  // The packs kept on this device, and the one drawn with where it is not among them (one read from elsewhere).
  final used = pictures ? packs.usedBy(app)?.entry : null;
  final onDisk = pictures ? packs.installed() : const <PackEntry>[];
  final kept = [...onDisk, if (used != null && !onDisk.any((e) => e.id == used.id)) used];
  Widget? tick(bool on) => on ? AppIcon(Lucide.check, size: 18, color: t.color('app-ink')) : null;

  // The pack chosen where it is not on this device: Runestone's usual one before it has been fetched, on its way, or
  // not fetched for want of a connection. Named from the app until the hub has been asked.
  SettingRow away(String id) {
    final wanted = chosen == id;
    final name = id == ResourcePacks.usual ? ResourcePacks.usualName : id;
    final fetching = packs.fetching == id, failed = wanted && packs.failed == id;
    return SettingRow(
      key: ValueKey('pack-$id'),
      icon: AppIcon(Lucide.image, size: 18),
      label: name,
      hint: fetching
          ? const Tr('Fetching it from the packs\' hub')
          : failed
              ? const Tr('It couldn\'t be fetched. Check the connection and try again.')
              : (id == ResourcePacks.usual ? const Tr('The pack Runestone comes with') : const Tr('Not on this device')),
      value: Text(fetching ? 'Fetching'.t : (failed ? 'Try again'.t : 'Get'.t)),
      disabled: packs.fetching != null,
      onPress: () => wanted ? packs.fetch(app, id) : packs.use(app, id),
    );
  }

  return PaneSection(
    title: 'Textures',
    footer: pictures
        ? const Tr('Runestone draws its windows, buttons and chat parchment from a resource pack: pixel art that players of the game it is modelled on have made for it. It comes with Duckscape, fetched to this device from the packs\' own hub on GitHub the first time the look is used; choose another, or plain stone, here. A pack is its artist\'s own work and is not part of this app.')
        : family.packs.isNotEmpty
            ? Text('What {look} is drawn with. Each pack brings its own colours, and is light or dark by itself.'.tf({'look': family.label}))
            : Text((family.pictures ? 'Packs for {look} are fetched by the app on a phone or a computer, not in a browser.' : 'Nobody has made a pack for {look} yet.').tf({'look': family.label})),
    children: [
      // The look's own, with no pack: for Runestone, plain stone.
      SettingRow(
        key: const ValueKey('pack-none'),
        icon: AppIcon(family.pictures ? Lucide.square : family.icon, size: 18),
        label: family.pictures ? 'Plain stone' : family.label,
        hint: family.pictures ? const Tr('No pack: flat colours') : const Tr('The look as it comes, with no pack'),
        value: tick(look == family && chosen.isEmpty),
        onPress: () {
          if (look != family) CustomTheme.chooseLook(app, family);
          if (pictures) packs.use(app, '');
        },
      ),
      // Its packs that are part of the app: each a look's whole set of colours, chosen here.
      for (final pack in family.packs)
        SettingRow(
          key: ValueKey('pack-${pack.name}'),
          icon: AppIcon(pack.icon, size: 18),
          label: pack.label,
          hint: Text(pack.description.t),
          value: tick(look == pack),
          onPress: () => CustomTheme.chooseLook(app, pack),
        ),
      // A resource pack's pictures: the ones kept on this device, the usual one where it is not among them, and the
      // hub to fetch another from.
      if (pictures) ...[
        for (final e in kept)
          SettingRow(
            key: ValueKey('pack-${e.id}'),
            icon: AppIcon(Lucide.image, size: 18),
            label: ResourcePacks.nameOf(e),
            hint: Text(e.author.isEmpty ? 'A resource pack'.t : '${'By'.t} ${e.author}'),
            value: tick(chosen == e.id),
            onPress: () => chosen == e.id ? _packMenu(context, app, e) : packs.use(app, e.id),
          ),
        if (!kept.any((e) => e.id == ResourcePacks.usual)) away(ResourcePacks.usual),
        if (chosen.isNotEmpty && chosen != ResourcePacks.usual && !kept.any((e) => e.id == chosen)) away(chosen),
        SettingRow(
          key: const ValueKey('pack-get'),
          icon: AppIcon(Lucide.download, size: 18),
          label: 'Get a resource pack',
          hint: const Tr('Choose one from the hub to fetch'),
          onPress: () => push<void>(context, (_) => ResourcePackHubScreen(app: app)),
        ),
      ],
    ],
  );
}

/// The pack in use, pressed: stop using it, or take it off this device.
void _packMenu(BuildContext context, AppState app, PackEntry e) {
  final packs = ResourcePacks.instance;
  showChoices(context, title: ResourcePacks.nameOf(e), choices: [
    Choice('Use plain stone', Lucide.square, () => packs.use(app, '')),
    Choice('Remove from this device', Lucide.trash2, () => packs.remove(app, e.id)),
  ]);
}

/// The hub's packs, to fetch one from: each with who made it, a field to find one by name, and Get.
class ResourcePackHubScreen extends StatefulWidget {
  const ResourcePackHubScreen({super.key, required this.app, this.packs});
  final AppState app;

  /// The packs asked, [ResourcePacks.instance] where null.
  final ResourcePacks? packs;

  @override
  State<ResourcePackHubScreen> createState() => _ResourcePackHubScreenState();
}

class _ResourcePackHubScreenState extends State<ResourcePackHubScreen> {
  List<PackEntry>? _list;
  String? _problem;
  String _find = '';

  /// The pack being fetched, by its id.
  String? _getting;

  ResourcePacks get _packs => widget.packs ?? ResourcePacks.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _problem = null);
    try {
      final list = await _packs.hub();
      if (mounted) setState(() => _list = list);
    } catch (_) {
      if (mounted) setState(() => _problem = 'The list of packs couldn\'t be fetched. Check the connection and try again.'.t);
    }
  }

  Future<void> _get(PackEntry e) async {
    if (_getting != null) return;
    setState(() => _getting = e.id);
    try {
      await _packs.install(widget.app, e);
      if (!mounted) return;
      toast(context, '${ResourcePacks.nameOf(e)}: ${'in use'.t}');
      Navigator.of(context).maybePop();
    } catch (_) {
      if (mounted) toast(context, '${ResourcePacks.nameOf(e)}: ${'couldn\'t be fetched'.t}', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _getting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final find = _find.trim().toLowerCase();
    final shown = [
      for (final e in _list ?? const <PackEntry>[])
        if (find.isEmpty || e.name.toLowerCase().contains(find) || e.author.toLowerCase().contains(find) || e.tags.any((tag) => tag.toLowerCase().contains(find))) e,
    ];
    final have = {for (final e in _packs.installed()) e.id: e.commit};
    return GhostPage(
      title: 'Resource packs',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsets.fromLTRB(t.space(4), t.space(2), t.space(4), t.space(8)),
          children: [
            PaneSection(
              description: const Tr('Each pack is its artist\'s own work, made for the game Runestone is modelled on and kept in the packs\' hub on GitHub. Get fetches one to this device; nothing of it is sent anywhere.'),
              children: [
                SettingRowBox(
                  child: GlacierInput(
                    key: const ValueKey('pack-find'),
                    placeholder: 'Find a pack',
                    ariaLabel: 'Find a pack',
                    onChange: (v) => setState(() => _find = v),
                  ),
                ),
              ],
            ),
            SizedBox(height: t.space(5)),
            if (_problem != null)
              PaneSection(children: [
                SettingRow(icon: AppIcon(Lucide.wifiOff, size: 18), label: 'Not fetched', hint: Text(_problem!), value: Text('Try again'.t), onPress: _load),
              ])
            else if (_list == null)
              PaneSection(children: [SettingRow(icon: AppIcon(Lucide.loaderCircle, size: 18), label: 'Fetching the list', hint: const Tr('From the packs\' hub'))])
            else
              PaneSection(
                title: 'Packs',
                children: [
                  for (final e in shown)
                    SettingRow(
                      key: ValueKey('hub-${e.id}'),
                      icon: AppIcon(Lucide.image, size: 18),
                      label: ResourcePacks.nameOf(e),
                      hint: Text(e.author.isEmpty ? 'A resource pack'.t : '${'By'.t} ${e.author}'),
                      value: Text(_getting == e.id ? 'Fetching'.t : (have[e.id] == null ? 'Get'.t : (have[e.id] == e.commit ? 'Use'.t : 'Update'.t))),
                      disabled: _getting != null && _getting != e.id,
                      onPress: () => _get(e),
                    ),
                  if (shown.isEmpty) SettingRow(icon: AppIcon(Lucide.search, size: 18), label: 'No pack by that name'),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
