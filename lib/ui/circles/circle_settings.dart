/// A circle's settings over the whole window, with a sidebar of its own (Matt, 2026-11-17: "there are no server settings
/// we should be able to manage roles users etc and other basic circle settings with a full screen sidebar and main page
/// settings"), shaped like a Discord server's settings since 2026-11-18 (Matt: "The roles and settings in circles can
/// be cleaned up a lot to be closer to discord server settings please overhaul them and make it easier to use with tri
/// toggles for permissions and permission hierarchy"):
///
/// - **Circle:** Overview (who owns it, how many people and spaces, its name, picture, colour and icon) and Roles (in
///   their order, highest first, dragged by a handle or moved from a row's menu, with everyone last; each opened in an
///   editor of three tabs: Display, Permissions and Members).
/// - **People:** Members (searched, each with their roles as coloured chips, given and taken away) and Invites.
/// - **Spaces:** each space's name, kind and heading, and its Permissions: for everyone and each role, Deny, As the
///   circle says or Allow (lib/ui/circles/perm_toggle.dart), as Discord's channel overrides.
/// - At the foot, Leave circle, and Delete circle for its owner.
///
/// Beside one another on a wide window, where a role, a space or a person opens in the section's own pane; on a phone
/// the sidebar is the first page and each section, and each thing in one, opens over it. Whoever may not change
/// something reads what it is, with a word on why.
library;

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../circles/invite_word.dart';
import '../../invites/invite_relay.dart' show InviteRelayError;
import '../../desktop/ui/qr.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../plugins/plugin.dart' show PluginScope;
import '../../plugins/soundboard.dart' show SoundboardPlugin;
import '../../voice/soundboard.dart' show circleSounds, boardCircleMost;
import '../../plugins/notion.dart';
import '../notion_settings.dart';
import '../soundboard_screen.dart';
import '../../plugins/registry.dart' show PluginRegistry;
import '../../plugins/record_call.dart' show RecordCallPlugin;
import '../../sms.dart' show Sms;
import '../../files/files_model.dart' show SpaceFile;
import '../files_space/files_screen.dart' show askFileWords;
import '../../voice/channels.dart';
import '../../voice/voice.dart' show SpaceKind;
import '../common.dart';
import '../dialup/bevel.dart';
import '../shell.dart';
import 'arrange_spaces.dart';
import 'circle_face.dart';
import 'circle_invite.dart';
import 'circle_picture.dart';
import 'circle_welcome.dart';
import 'new_circle.dart';
import 'perm_toggle.dart';
import '../../l10n/words.dart';

/// The sections of a circle's settings, in the sidebar's order, each under its heading ([group]).
enum CircleSettingsSection {
  overview('Overview', Lucide.layoutGrid, 'blue', 'Circle'),
  roles('Roles', Lucide.shieldCheck, 'indigo', 'Circle'),
  plugins('Plugins', Lucide.puzzle, 'rose', 'Circle'),
  members('Members', Lucide.users, 'green', 'People'),
  invite('Invites', Lucide.link, 'purple', 'People'),
  welcome('Welcome', Lucide.doorOpen, 'mint', 'People'),
  spaces('Spaces', Lucide.listTree, 'amber', 'Spaces');

  const CircleSettingsSection(this.label, this.icon, this.hue, this.group);
  final String label;
  final LucideIcon icon;
  final String hue;
  final String group;
}

/// How wide a window must be for the sidebar and a section side by side.
const double circleSettingsWideAt = 720;

/// Opens [c]'s settings over the whole window (above the list and the pane, as a page of its own), on [section].
void openCircleSettingsFull(BuildContext context, String seed, {CircleSettingsSection section = CircleSettingsSection.overview, bool qr = false}) {
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    settings: const RouteSettings(name: 'circle-settings'),
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (context, _, _) => CircleSettingsPage(seed: seed, section: section, qr: qr),
    transitionsBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
  ));
}

/// Something opened from a section: a role (or everyone, CircleManifest.everyoneId), a space, a person.
typedef _Open = ({String kind, String id});

/// The settings of the circle with [seed], opened on [section]; [qr] opens Invites with the QR code showing.
class CircleSettingsPage extends StatefulWidget {
  const CircleSettingsPage({super.key, required this.seed, this.section = CircleSettingsSection.overview, this.qr = false});
  final String seed;
  final CircleSettingsSection section;
  final bool qr;

  @override
  State<CircleSettingsPage> createState() => _CircleSettingsPageState();
}

class _CircleSettingsPageState extends State<CircleSettingsPage> {
  late CircleSettingsSection _section = widget.section;
  late bool _qr = widget.qr;

  /// What is open in the section's pane on a wide window; null for the section itself.
  _Open? _open;

  @override
  Widget build(BuildContext context) {
    final circles = Circles.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([circles, Voice.instance]),
      builder: (context, _) {
        final c = circles.bySeed(widget.seed);
        if (c == null) return GhostPage(title: 'Circle', body: const Center(child: Tr('You left this circle.')));
        return LayoutBuilder(builder: (context, box) {
          if (box.maxWidth < circleSettingsWideAt) {
            // A phone: the sidebar is the page; a section opens over it with its way back.
            return GhostPage(
              title: 'Circle settings',
              body: _Sidebar(circle: c, chosen: null, onChoose: (s) => push<void>(context, (_) => _SectionPage(seed: c.seed, section: s))),
            );
          }
          final t = context.tokens;
          final open = _open;
          final shown = open == null ? null : _openTitle(c, open);
          return ColoredBox(
            color: t.color('glacier-bg'),
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                key: const ValueKey('circle-settings-sidebar'),
                width: 260,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: t.color('app-paper'), border: Border(right: BorderSide(color: t.color('app-rule')))),
                  child: GhostPage(
                    title: 'Circle settings',
                    body: _Sidebar(circle: c, chosen: _section, onChoose: (s) => setState(() {
                      _section = s;
                      _open = null;
                    })),
                  ),
                ),
              ),
              Expanded(
                child: open != null && shown != null
                    ? GhostPage(
                        key: ValueKey('circle-settings-open-${open.kind}-${open.id}'),
                        title: shown,
                        onBack: () => setState(() => _open = null),
                        actions: [_close(context)],
                        body: _OpenBody(circle: c, open: open, onGone: () => setState(() => _open = null)),
                      )
                    : GhostPage(
                        key: ValueKey('circle-settings-${_section.name}'),
                        title: _section.label,
                        back: false,
                        actions: [_close(context)],
                        body: _SectionBody(circle: c, section: _section, qr: _qr, onQr: () => setState(() => _qr = !_qr), onOpen: (o) => setState(() => _open = o)),
                      ),
              ),
            ]),
          );
        });
      },
    );
  }

  Widget _close(BuildContext context) => IconTap(key: const ValueKey('circle-settings-close'), icon: Lucide.x, label: 'Close settings', onPressed: () => Navigator.of(context).maybePop());
}

/// The title of what [o] opens; null where it is gone (a role deleted, a space taken out).
String? _openTitle(Circle c, _Open o) => switch (o.kind) {
      'role' => o.id == CircleManifest.everyoneId ? '@everyone' : c.manifest.roles.where((r) => r.id == o.id).firstOrNull?.name,
      'space' => c.space(o.id)?.name,
      _ => circlePeople(c).where((p) => p.id == o.id).firstOrNull?.name,
    };

/// The sidebar: the circle at its head (its face, name and how many spaces and people), then each section under its
/// heading, then leaving it (and, for its owner, deleting it) at the foot.
class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.circle, required this.chosen, required this.onChoose});
  final Circle circle;
  final CircleSettingsSection? chosen;
  final ValueChanged<CircleSettingsSection> onChoose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = circle;
    final people = circlePeople(c);
    final owner = _isOwner(c);
    final caps = t.lenOf('0.72rem');
    Widget heading(String words) => Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(4), t.space(3), t.space(1)),
          child: Semantics(header: true, label: words, child: ExcludeSemantics(child: Text(isBevelChrome(t) ? words : words.toUpperCase(), style: pageText(t, caps, weight: 'semibold', color: t.color('app-ink-3'), tracking: t.len('app-tracking-caps', em: caps))))),
        );
    String? last;
    return ListView(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(8)),
      children: [
        Row(children: [
          CircleFace.of(c, size: 44, selected: c.picture == null),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'bold')),
              Text('${_count(c.spaces.length, 'space')} · ${_count(people.length, 'person', 'people')}', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            ]),
          ),
        ]),
        SizedBox(height: t.space(1)),
        for (final s in CircleSettingsSection.values) ...[
          if (s.group != last) heading(last = s.group),
          GlacierScope(
            attrs: {'hue': s.hue},
            child: _SidebarRow(key: ValueKey('circle-settings-tab-${s.name}'), icon: s.icon, label: s.label, chosen: chosen == s, onPressed: () => onChoose(s)),
          ),
        ],
        Padding(padding: EdgeInsets.symmetric(vertical: t.space(3)), child: Container(height: t.len('glacier-hairline'), color: t.color('app-rule'))),
        _SidebarRow(key: const ValueKey('circle-leave'), icon: Lucide.logOut, label: 'Leave circle', danger: true, chosen: false, onPressed: () => _leave(context, c)),
        if (owner) _SidebarRow(key: const ValueKey('circle-delete'), icon: Lucide.trash2, label: 'Delete circle', danger: true, chosen: false, onPressed: () => _delete(context, c)),
      ],
    );
  }
}

/// One row of the sidebar: a section, marked when it is the one showing, or Leave and Delete at the foot ([danger]).
class _SidebarRow extends StatelessWidget {
  const _SidebarRow({super.key, required this.icon, required this.label, required this.chosen, required this.onPressed, this.danger = false});
  final LucideIcon icon;
  final String label;
  final bool chosen;
  final bool danger;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      selected: chosen,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: bevel ? 0 : t.radius('md'),
        offset: -2,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2) + 2),
          decoration: BoxDecoration(
            color: chosen ? t.color('app-paper-3') : (state.hovered || state.pressed ? t.color('app-paper-2') : const Color(0x00000000)),
            borderRadius: BorderRadius.circular(bevel ? 0 : t.radius('md')),
          ),
          child: Row(children: [
            AppIcon(icon, size: 18, color: danger ? t.danger : t.color('app-ink-2')),
            SizedBox(width: t.space(3)),
            Expanded(child: Text(label, style: pageText(t, t.fontSize('sm'), weight: chosen ? 'semibold' : 'medium', color: danger ? t.danger : t.color('app-ink')))),
          ]),
        ),
      ),
    );
  }
}

/// A section as a page of its own: a phone's, over the sidebar.
class _SectionPage extends StatefulWidget {
  const _SectionPage({required this.seed, required this.section});
  final String seed;
  final CircleSettingsSection section;

  @override
  State<_SectionPage> createState() => _SectionPageState();
}

class _SectionPageState extends State<_SectionPage> {
  bool _qr = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Circles.instance, Voice.instance]),
      builder: (context, _) {
        final c = Circles.instance.bySeed(widget.seed);
        if (c == null) return GhostPage(title: widget.section.label, body: const Center(child: Tr('You left this circle.')));
        return GhostPage(
          title: widget.section.label,
          body: _SectionBody(circle: c, section: widget.section, qr: _qr, onQr: () => setState(() => _qr = !_qr), onOpen: (o) => push<void>(context, (_) => _OpenPage(seed: c.seed, open: o))),
        );
      },
    );
  }
}

/// A role, a space or a person as a page of its own: a phone's, over its section.
class _OpenPage extends StatelessWidget {
  const _OpenPage({required this.seed, required this.open});
  final String seed;
  final _Open open;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Circles.instance, Voice.instance]),
      builder: (context, _) {
        final c = Circles.instance.bySeed(seed);
        final title = c == null ? null : _openTitle(c, open);
        if (c == null || title == null) return GhostPage(title: 'Circle', body: const Center(child: Tr('This is gone.')));
        return GhostPage(title: title, body: _OpenBody(circle: c, open: open, onGone: () => Navigator.of(context).maybePop()));
      },
    );
  }
}

/// Whether this device's own key is the circle's owner's. Never true for a circle made without an owner's key.
bool _isOwner(Circle c) => c.manifest.ownerId.isNotEmpty && Circles.instance.signer?.id == c.manifest.ownerId;

/// A count in words: "1 space", "3 spaces"; [many] where the plural is not the word with an s.
String _count(int n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// A section's page: its rows, centred and no wider than a reading line, in its own hue.
class _Scroll extends StatelessWidget {
  const _Scroll({required this.hue, required this.children});
  final String hue;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierScope(
      attrs: {'hue': hue},
      child: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
          children: [Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 680), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)))],
        ),
      ),
    );
  }
}

/// One section's settings.
class _SectionBody extends StatelessWidget {
  const _SectionBody({required this.circle, required this.section, required this.qr, required this.onQr, required this.onOpen});
  final Circle circle;
  final CircleSettingsSection section;
  final bool qr;
  final VoidCallback onQr;
  final ValueChanged<_Open> onOpen;

  @override
  Widget build(BuildContext context) {
    final c = circle;
    return switch (section) {
      CircleSettingsSection.overview => _Scroll(hue: section.hue, children: _overview(context, c)),
      CircleSettingsSection.roles => _Scroll(hue: section.hue, children: [_RolesList(circle: c, onOpen: onOpen)]),
      CircleSettingsSection.plugins => _Scroll(hue: section.hue, children: _plugins(context, c)),
      CircleSettingsSection.members => _Members(circle: c, hue: section.hue, onOpen: onOpen),
      CircleSettingsSection.invite => _Scroll(hue: section.hue, children: _invites(context, c)),
      // Welcome messages, the welcome space and read-only spaces (Matt, 2026-11-20; circle_welcome.dart).
      CircleSettingsSection.welcome => _Scroll(hue: section.hue, children: circleWelcomeSection(context, c, onOpenSpace: (seed) => onOpen((kind: 'space', id: seed)))),
      CircleSettingsSection.spaces => _Scroll(hue: section.hue, children: _spaces(context, c)),
    };
  }

  List<Widget> _overview(BuildContext context, Circle c) {
    final t = context.tokens;
    final circles = Circles.instance;
    final edit = circles.can(c, CirclePerm.circle);
    final people = circlePeople(c);
    final owner = people.where((p) => p.owner).firstOrNull;
    final gap = SizedBox(height: t.space(6));
    // Who owns it and how big it is, in words (Matt, 2026-11-18: "make it easier to use").
    final who = owner == null ? 'No one can change it: it was made without an owner\'s key.' : (owner.me ? 'You own this circle.' : '${owner.name} owns this circle.');
    return [
      Center(child: CircleFace.of(c, size: 76, selected: c.picture == null)),
      SizedBox(height: t.space(2)),
      Text(c.name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xl'), weight: 'bold')),
      SizedBox(height: t.space(1)),
      Text(
        key: const ValueKey('circle-overview-summary'),
        '$who ${_count(people.length, 'person', 'people')} · ${_count(c.spaces.length, 'space')} · ${_count(c.manifest.roles.length, 'role')}',
        textAlign: TextAlign.center,
        style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
      ),
      SizedBox(height: t.space(5)),
      if (!edit) ...[SettingsCallout(child: Text('Your roles in ${c.name} don\'t let you change it. Whoever has Change the circle can.')), gap],
      if (edit) ...[
        PaneSection(title: 'Circle', children: [
          SettingRow(key: const ValueKey('circle-rename'), icon: AppIcon(Lucide.pencil, size: 18), label: 'Name', value: Text(c.name), onPress: () => askCircleWords(context, title: 'Rename circle', initial: c.name, then: (n) => circles.edit(c, name: n))),
          // Not in a browser, which can't choose a picture yet (Sms.browser).
          if (!Sms.browser) SettingRow(
            key: const ValueKey('circle-picture'),
            icon: AppIcon(Lucide.imagePlus, size: 18),
            label: c.picture == null ? 'Choose a picture' : 'Change the picture',
            hint: const Tr('Shown in the icon\'s place'),
            onPress: () async {
              final p = await pickCirclePicture(context);
              if (p != null) circles.edit(c, picture: p);
            },
          ),
          if (c.picture != null) SettingRow(icon: AppIcon(Lucide.trash2, size: 18), label: 'Use the icon instead', onPress: () => circles.edit(c, clearPicture: true)),
          // Behind the top of its sidebar, as a Discord server's banner (Matt, 2026-11-19).
          SettingRow(
            key: const ValueKey('circle-banner'),
            icon: AppIcon(Lucide.imagePlus, size: 18),
            label: c.banner == null ? 'Choose a banner' : 'Change the banner',
            hint: const Tr('A wide picture across the top of the circle\'s sidebar'),
            onPress: () async {
              await chooseCircleBanner(context, c);
            },
          ),
          if (c.banner != null) SettingRow(icon: AppIcon(Lucide.trash2, size: 18), label: 'Remove the banner', onPress: () => circles.edit(c, clearBanner: true)),
        ]),
        gap,
        PaneSection(title: 'Colour', children: [SettingRowBox(child: CircleHuePicker(value: c.hue, onChanged: (h) => circles.edit(c, hue: h)))]),
        gap,
        PaneSection(title: 'Icon', children: [SettingRowBox(child: CircleIconPicker(hue: c.hue, value: c.icon, onChanged: (i) => circles.edit(c, icon: i)))]),
      ],
    ];
  }

  /// The plugins a circle may hold, each turned on or off for everyone in it (Matt, 2026-11-19: "Some plugins should
  /// be serverside / cirlce side as well"): kept in the circle's signed manifest, so every member's app does it in this
  /// circle's spaces without adding it themselves.
  List<Widget> _plugins(BuildContext context, Circle c) {
    final circles = Circles.instance;
    final edit = circles.can(c, CirclePerm.circle);
    final list = PluginRegistry.instance.circlePlugins;
    return [
      if (!edit) ...[SettingsCallout(child: Text('Whoever has Change the circle turns plugins on or off for everyone in ${c.name}.')), SizedBox(height: context.tokens.space(4))],
      PaneSection(
        title: 'For everyone in the circle',
        description: const Tr('Turned on here, a plugin works in this circle\'s spaces for every member, without anyone adding it.'),
        children: [
          if (list.isEmpty) const SettingRowBox(child: Tr('No plugin works for a whole circle yet.')),
          for (final p in list)
            SettingRow(
              key: ValueKey('circle-plugin-${p.id}'),
              icon: AppIcon(p.icon, size: 18),
              label: p.name,
              hint: Text(p.scopes.contains(PluginScope.server) ? '${p.description} ${PluginScope.server.hint}.' : p.description),
              control: GlacierSwitch(
                checked: c.manifest.pluginOn(p.id) ?? false,
                disabled: !edit,
                ariaLabel: '${p.name} for everyone in ${c.name}',
                onCheckedChange: (v) async {
                  final ok = await circles.setPlugin(c, p.id, on: v);
                  if (!ok && context.mounted) toast(context, 'Couldn\'t change ${p.name} for the circle');
                },
              ),
            ),
        ],
      ),
      // Record call's save location (Matt, 2026-11-19: "allow for changing settings like save location (expect saving to
      // have at least one file space in a circle we'll save to a folder in a given space within the circle)").
      if (list.any((p) => p.id == 'recordcall')) ...[
        SizedBox(height: context.tokens.space(5)),
        _recordingsTo(context, c, edit),
      ],
      // Notion's token for the circle (Matt, 2026-11-25: "only requires the circle to have the plugin configured").
      if (list.any((p) => p.id == NotionPlugin.pluginId)) ...[
        SizedBox(height: context.tokens.space(5)),
        NotionCircleSection(circle: c, edit: edit),
      ],
      // Soundboard's own sounds for the circle (Matt, 2026-11-20: "build a soundboards plugin for circles").
      if (list.any((p) => p.id == SoundboardPlugin.pluginId)) ...[
        SizedBox(height: context.tokens.space(5)),
        PaneSection(
          title: 'Soundboard',
          description: Text(edit ? 'Sounds of ${c.name}\'s own, beside the app\'s, for everyone in a call here.' : 'Sounds of ${c.name}\'s own, beside the app\'s. Whoever has Change the circle adds them.'),
          children: [
            SettingRow(
              key: const ValueKey('circle-soundboard'),
              icon: AppIcon(Lucide.megaphone, size: 18),
              label: edit ? 'Its sounds' : 'Hear its sounds',
              value: Text('${circleSounds(c).length} of $boardCircleMost'),
              onPress: () => push(context, (_) => SoundboardScreen(circle: c)),
            ),
          ],
        ),
      ],
    ];
  }

  /// Where this circle's call recordings are saved: one of its Files spaces, and a folder in it.
  Widget _recordingsTo(BuildContext context, Circle c, bool edit) {
    final to = RecordCallPlugin.saveToIn(c);
    final files = [for (final s in c.spaces) if (s.kind == SpaceKind.files) s];
    Future<void> set({String? space, String? folder}) async {
      final now = RecordCallPlugin.saveToIn(c);
      final ok = await Circles.instance.setPlugin(c, 'recordcall',
          on: c.manifest.pluginOn('recordcall') ?? false, choices: {'space': space ?? now?.space.seed, 'folder': folder ?? now?.folder ?? RecordCallPlugin.defaultFolder});
      if (!ok && context.mounted) toast(context, 'Couldn\'t change where recordings are saved');
    }

    return PaneSection(
      title: 'Call recordings',
      description: Text(to == null
          ? 'Record call saves a recording made in this circle into one of its Files spaces. Add a Files space to save them there; until then they stay on the device that recorded.'
          : 'A call recorded in any of ${c.name}\'s spaces is saved here for the circle, as well as on the device that recorded it.'),
      children: [
        if (to != null) ...[
          SettingRow(
            key: const ValueKey('recordings-space'),
            icon: AppIcon(Lucide.folderOpen, size: 18),
            label: 'Files space',
            hint: Text(to.space.name),
            onPress: !edit || files.length < 2
                ? null
                : () => showChoices(context, title: 'Save recordings in', choices: [
                      for (final s in files) Choice(s.name, s.seed == to.space.seed ? Lucide.check : Lucide.folderOpen, () => set(space: s.seed)),
                    ]),
          ),
          SettingRow(
            key: const ValueKey('recordings-folder'),
            icon: AppIcon(Lucide.folder, size: 18),
            label: 'Folder',
            hint: Text(to.folder),
            onPress: !edit
                ? null
                : () => askFileWords(context, title: 'Folder for recordings', initial: to.folder, hint: 'In ${to.space.name}. Use / for a folder inside another.', then: (words) {
                      final folder = SpaceFile.cleanFolder(words.trim());
                      if (folder == null) {
                        toast(context, 'That can\'t be a folder\'s name');
                        return;
                      }
                      unawaited(set(folder: folder));
                    }),
          ),
        ],
      ],
    );
  }

  List<Widget> _invites(BuildContext context, Circle c) {
    final t = context.tokens;
    final circles = Circles.instance;
    final word = c.inviteWord;
    final mayChange = circles.can(c, CirclePerm.circle);
    return [
      // An invite word, as a Discord server's vanity invite, for every circle (Matt, 2026-11-19: "add the custom invite
      // code word as a default feature"; lib/circles/invite_word.dart).
      PaneSection(
        title: 'Invite word',
        description: Text(word == null
            ? 'A short link to the circle, like gogho.st/c/bookclub, in place of the long one. Anyone who knows the word can join.'
            : 'Anyone who opens gogho.st/c/$word, or types $word into Join a circle, can join.'),
        children: [
          if (word != null)
            SettingRow(
              key: const ValueKey('circle-word-copy'),
              icon: AppIcon(Lucide.link, size: 18),
              label: 'gogho.st/c/$word',
              value: const Tr('Copy'),
              onPress: () {
                Clipboard.setData(ClipboardData(text: inviteWordLink(word)));
                toast(context, 'Invite link copied');
              },
            ),
          if (mayChange) ...[
            SettingRow(
              key: const ValueKey('circle-word-choose'),
              icon: AppIcon(Lucide.pencil, size: 18),
              label: word == null ? 'Choose an invite word' : 'Change the word',
              hint: const Tr('3 to 32 letters, numbers or hyphens.'),
              onPress: () => askCircleWords(context, title: 'Invite word', initial: word ?? tidyInviteWord(c.name) ?? '', hint: 'gogho.st/c/…', then: (raw) => chooseCircleInviteWord(context, c, raw)),
            ),
            if (word != null)
              SettingRow(
                key: const ValueKey('circle-word-remove'),
                icon: AppIcon(Lucide.trash2, size: 18),
                label: 'Remove the word',
                hint: const Tr('The long link goes on working.'),
                onPress: () => chooseCircleInviteWord(context, c, null),
              ),
          ] else if (word == null)
            const SettingRow(label: 'No invite word yet', hint: Tr('Whoever may change the circle can choose one.')),
        ],
      ),
      PaneSection(
        title: 'Invite link',
        description: const Tr('Whoever has the link is in the circle, so share it with people you know.'),
        children: [
          if (circles.can(c, CirclePerm.invite)) SettingRow(key: const ValueKey('circle-settings-invite-people'), icon: AppIcon(Lucide.userPlus, size: 18), label: 'Invite people', hint: const Tr('Friends in the app, anyone by a text, or the link.'), onPress: () => showCircleInvite(context, c)),
          SettingRow(
            key: const ValueKey('circle-copy-link'),
            icon: AppIcon(Lucide.copy, size: 18),
            label: 'Copy invite link',
            onPress: () {
              Clipboard.setData(ClipboardData(text: c.link));
              toast(context, 'Invite link copied');
            },
          ),
          SettingRow(key: const ValueKey('circle-qr'), icon: AppIcon(Lucide.scanText, size: 18), label: qr ? 'Hide the QR code' : 'Show a QR code', onPress: onQr),
          if (qr)
            SettingRowBox(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(t.space(2)),
                  child: Semantics(label: 'The invite link to ${c.name}, as a QR code', child: ExcludeSemantics(child: QrView(data: c.link, size: 200, radius: isBevelChrome(t) ? 0 : 14))),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  List<Widget> _spaces(BuildContext context, Circle c) {
    final t = context.tokens;
    final circles = Circles.instance;
    final edit = circles.can(c, CirclePerm.spaces);
    final m = c.manifest;
    return [
      if (!edit) ...[SettingsCallout(child: Text('Your roles in ${c.name} don\'t let you change its spaces. Whoever has Manage spaces can.')), SizedBox(height: t.space(6))],
      PaneSection(
        title: _count(c.spaces.length, 'space'),
        description: Text(edit ? 'Press a space to rename it, change its kind or heading, or set what each role may do in it.' : 'The spaces in ${c.name}.'),
        children: [
          for (final s in c.spaces)
            SettingRow(
              key: ValueKey('circle-settings-space-${s.seed}'),
              icon: AppIcon(spaceKindIcon(s.kind), size: 18),
              label: s.name,
              hint: Text([
                spaceKindTitle(s.kind),
                if (s.section != null) s.section!,
                if (m.overrides[s.seed] case final per?) _count(per.length, 'role changed', 'roles changed'),
              ].join(' · ')),
              onPress: edit ? () => onOpen((kind: 'space', id: s.seed)) : null,
            ),
          if (edit) ...[
            SettingRow(key: const ValueKey('circle-settings-new-space'), icon: AppIcon(Lucide.plus, size: 18), label: 'New space', hint: const Tr('A chat, a voice chat, or a files space'), onPress: () => push<void>(context, (_) => NewCircleSpaceScreen(circle: c))),
            SettingRow(key: const ValueKey('circle-arrange'), icon: AppIcon(Lucide.chevronsUpDown, size: 18), label: 'Arrange spaces', hint: const Tr('Their order and headings'), onPress: () => push<void>(context, (_) => ArrangeCircleSpacesScreen(seed: c.seed))),
          ],
        ],
      ),
    ];
  }
}

// --- roles ----------------------------------------------------------------------------------------------------------

/// A role's colour as a dot: hollow where it gives names no colour.
class RoleDot extends StatelessWidget {
  const RoleDot({super.key, required this.hue, this.size = 12});
  final String hue;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final none = !circleHues.contains(hue);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: none ? null : t.hueSwatch(hue),
        border: none ? Border.all(color: t.color('app-ink-3'), width: 1.5) : null,
      ),
    );
  }
}

/// A role as a small chip: its dot and its name (a member's roles, a space's role picker).
class RoleChip extends StatelessWidget {
  const RoleChip({super.key, required this.name, required this.hue, this.chosen = false, this.marked = false, this.onPressed});
  final String name;
  final String hue;
  final bool chosen;

  /// A dot after the name: this role has something changed here (a space's overrides).
  final bool marked;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    Widget chip(PressState? s) => Container(
          padding: EdgeInsets.symmetric(horizontal: t.space(2) + 2, vertical: onPressed == null ? 3 : 6),
          decoration: BoxDecoration(
            color: chosen ? t.chosenWash : (s != null && s.hovered ? t.color('app-paper-3') : t.color('app-paper-3').withValues(alpha: 0.7)),
            borderRadius: BorderRadius.circular(bevel ? 0 : 999),
            border: Border.all(color: chosen ? t.chosen : t.color('glacier-border-subtle'), width: chosen ? 1.5 : t.len('glacier-hairline')),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            RoleDot(hue: hue, size: 9),
            SizedBox(width: t.space(1) + 2),
            Text(name, style: pageText(t, t.fontSize(onPressed == null ? 'xs' : 'sm'), weight: chosen ? 'semibold' : 'medium', color: t.color('app-ink'))),
            if (marked) ...[SizedBox(width: t.space(1) + 2), Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: t.warn))],
          ]),
        );
    if (onPressed == null) return chip(null);
    return GlacierPressable(onPressed: onPressed, semanticLabel: '$name${marked ? ', changed here' : ''}', selected: chosen, builder: (context, s) => GlacierFocusRing(visible: s.focused, radius: 999, child: chip(s)));
  }
}

/// The Roles section: what roles are and how their order works, then the roles, highest first, each dragged by its
/// handle or moved from its menu, with everyone (@everyone) last; then the owner, and admins made by hand.
class _RolesList extends StatelessWidget {
  const _RolesList({required this.circle, required this.onOpen});
  final Circle circle;
  final ValueChanged<_Open> onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = circle;
    final circles = Circles.instance;
    final m = c.manifest;
    final me = circles.signer?.id ?? '';
    final manage = circles.can(c, CirclePerm.roles);
    final roles = m.roles;
    final people = circlePeople(c);
    final owner = people.where((p) => p.owner).firstOrNull;
    final admins = [for (final p in people) if (p.admin && m.rolesOf(p.id).isEmpty) p];
    final bevel = isBevelChrome(t);
    final gap = SizedBox(height: t.space(6));
    final top = m.rankOf(me);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsCallout(
        icon: AppIcon(Lucide.listOrdered, size: 18),
        child: Text(
          manage
              ? 'Roles are listed highest first. Someone\'s name takes the colour of their highest coloured role, and people can only manage the roles under their own highest. Drag a role by its handle to move it.'
              : 'Roles are listed highest first. Someone\'s name takes the colour of their highest coloured role.',
        ),
      ),
      gap,
      PaneSection(
        title: 'Roles · ${roles.length}',
        children: [
          if (manage && roles.length < circleRolesMax)
            SettingRow(
              key: const ValueKey('circle-role-new'),
              icon: AppIcon(Lucide.plus, size: 18),
              label: 'New role',
              hint: const Tr('Made at the bottom, over everyone'),
              onPress: () => askCircleWords(context, title: 'New role', then: (name) async {
                final r = CircleRole.make(name, hue: circleHues[roles.length % circleHues.length], perms: const {});
                final ok = await circles.saveRole(circles.bySeed(c.seed) ?? c, r);
                if (!context.mounted) return;
                if (!ok) return toast(context, 'Couldn\'t make the role', tone: GlacierToastTone.danger);
                onOpen((kind: 'role', id: r.id));
              }),
            ),
          if (roles.isNotEmpty)
            _RoleRows(
              child: ReorderableList(
                key: const ValueKey('circle-roles-list'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: roles.length,
                proxyDecorator: (child, _, _) => ColoredBox(color: bevel ? DialupColors.of(t).chrome : t.color('app-paper-3'), child: child),
                onReorderItem: (from, to) async {
                  if (to == from) return;
                  final ok = await circles.moveRole(circles.bySeed(c.seed) ?? c, roles[from].id, to);
                  if (!ok && context.mounted) toast(context, 'You can only move roles under your own highest role.', tone: GlacierToastTone.danger);
                },
                itemBuilder: (context, i) => _RoleRow(
                  key: ValueKey('circle-role-${roles[i].id}'),
                  circle: c,
                  role: roles[i],
                  index: i,
                  count: m.holdersOf(roles[i].id),
                  manage: manage && m.mayManageRole(me, roles[i].id),
                  // A role may go up as far as the one just under this install's own highest.
                  mayUp: i > 0 && (me == m.ownerId || i - 1 > top),
                  mayDown: i < roles.length - 1,
                  ruled: i > 0,
                  onOpen: () => onOpen((kind: 'role', id: roles[i].id)),
                ),
              ),
            ),
          SettingRow(
            key: const ValueKey('circle-role-everyone'),
            icon: AppIcon(Lucide.users, size: 18),
            label: '@everyone',
            hint: Text('Everyone in the circle, under every role: ${_perms(m.everyone)}'),
            onPress: () => onOpen((kind: 'role', id: CircleManifest.everyoneId)),
          ),
        ],
      ),
      gap,
      PaneSection(
        title: 'Owner',
        description: const Tr('Above every role: can do everything, give any role, make admins, and delete the circle.'),
        children: [
          SettingRow(
            key: const ValueKey('circle-role-owner'),
            icon: AppIcon(Lucide.shieldCheck, size: 18),
            label: owner == null ? 'No one' : (owner.me ? 'You' : owner.name),
            labelColor: owner == null ? null : circleRoleInk(t, owner),
          ),
        ],
      ),
      if (admins.isNotEmpty) ...[
        gap,
        PaneSection(
          title: 'Admins',
          description: const Tr('Made by the owner, with no role: just under the owner, they can do everything but delete the circle or make admins.'),
          children: [
            for (final p in admins)
              SettingRow(key: ValueKey('circle-role-admin-${p.id}'), icon: AppIcon(Lucide.shieldCheck, size: 18), label: p.me ? 'You' : p.name, labelColor: circleRoleInk(t, p), onPress: _isOwner(c) ? () => circlePersonMenu(context, c, p) : null),
          ],
        ),
      ],
    ]);
  }
}

/// Permissions as a line of words, in the order CirclePerm lists them; "nothing" for none.
String _perms(Set<CirclePerm> ps) => ps.isEmpty ? 'nothing' : [for (final p in CirclePerm.values) if (ps.contains(p)) p.label.toLowerCase()].join(', ');

/// The roles' list as one row of their card, so the card's hairlines fall between it and its neighbours.
class _RoleRows extends StatelessWidget implements PaneRow {
  const _RoleRows({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// One role in the list: a handle to drag it by, its colour, its name, how many have it, and a menu (Edit, Move up,
/// Move down, Delete) for the keyboard and a screen reader as much as the hand.
class _RoleRow extends StatelessWidget {
  const _RoleRow({super.key, required this.circle, required this.role, required this.index, required this.count, required this.manage, required this.mayUp, required this.mayDown, required this.ruled, required this.onOpen});
  final Circle circle;
  final CircleRole role;
  final int index;
  final int count;
  final bool manage, mayUp, mayDown, ruled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circles = Circles.instance;
    final c = circle;
    Future<void> move(int to) async {
      final ok = await circles.moveRole(circles.bySeed(c.seed) ?? c, role.id, to);
      if (!ok && context.mounted) toast(context, 'You can only move roles under your own highest role.', tone: GlacierToastTone.danger);
    }

    void menu() => showChoices(context, title: role.name, choices: [
          Choice(manage ? 'Edit role' : 'See role', Lucide.pencil, onOpen),
          if (manage && mayUp) Choice('Move up', Lucide.arrowUp, () => move(index - 1)),
          if (manage && mayDown) Choice('Move down', Lucide.arrowDown, () => move(index + 1)),
          if (manage) Choice('Delete role', Lucide.trash2, () => _confirmDeleteRole(context, c, role), danger: true),
        ]);

    final name = Text(role.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: circleHues.contains(role.hue) ? circleHueInk(t, role.hue) : null));
    return DecoratedBox(
      decoration: BoxDecoration(border: ruled ? Border(top: BorderSide(color: t.color('app-rule'), width: t.len('glacier-hairline'))) : null),
      child: GlacierPressable(
        onPressed: onOpen,
        semanticLabel: '${role.name}, ${_count(count, 'person', 'people')}${manage ? '' : ', above your own role'}',
        builder: (context, s) => GlacierFocusRing(
          visible: s.focused,
          radius: t.radius('sm'),
          offset: -3,
          child: Container(
            color: s.pressed ? t.color('app-paper-3') : const Color(0x00000000),
            padding: EdgeInsetsDirectional.fromSTEB(manage ? t.space(1) : t.space(3), t.space(2), t.space(1), t.space(2)),
            child: Row(children: [
              if (manage)
                ReorderableDragStartListener(
                  index: index,
                  child: Semantics(
                    label: 'Drag ${role.name} to move it',
                    child: Padding(padding: EdgeInsets.all(t.space(2)), child: AppIcon(Lucide.gripVertical, size: 18, color: t.color('app-ink-3'))),
                  ),
                )
              else
                Padding(padding: EdgeInsetsDirectional.only(end: t.space(2)), child: AppIcon(Lucide.lock, size: 14, color: t.color('app-ink-4'))),
              RoleDot(hue: role.hue, size: 14),
              SizedBox(width: t.space(3)),
              Expanded(child: name),
              SizedBox(width: t.space(2)),
              AppIcon(Lucide.userRound, size: 14, color: t.color('app-ink-3')),
              SizedBox(width: 3),
              Text('$count', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              IconTap(key: ValueKey('circle-role-menu-${role.id}'), icon: Lucide.ellipsis, label: 'More for ${role.name}', size: 18, onPressed: menu),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Asks before deleting role [r], deletes it from the circle as it stands now, and runs [then] once it is gone.
void _confirmDeleteRole(BuildContext context, Circle c, CircleRole r, {VoidCallback? then}) {
  showChoices(context, title: 'Delete ${r.name}? Whoever has it loses what it gave, and every space forgets what it said of it.', choices: [
    Choice('Delete role', Lucide.trash2, () async {
      final circles = Circles.instance;
      final ok = await circles.deleteRole(circles.bySeed(c.seed) ?? c, r.id);
      if (!context.mounted) return;
      if (!ok) return toast(context, 'Couldn\'t delete ${r.name}', tone: GlacierToastTone.danger);
      then?.call();
    }, danger: true),
  ]);
}

// --- what a section opens -------------------------------------------------------------------------------------------

/// The page of what a section opened: a role's editor, a space's permissions, or a person's roles.
class _OpenBody extends StatelessWidget {
  const _OpenBody({required this.circle, required this.open, required this.onGone});
  final Circle circle;
  final _Open open;

  /// Called when what is open is no longer there to show: a role or space deleted from its own page.
  final VoidCallback onGone;

  @override
  Widget build(BuildContext context) => switch (open.kind) {
        'role' => CircleRoleEditor(key: ValueKey('role-editor-${open.id}'), circle: circle, roleId: open.id, onGone: onGone),
        'space' => _SpacePermissions(key: ValueKey('space-perms-${open.id}'), circle: circle, spaceSeed: open.id, onGone: onGone),
        _ => _PersonRoles(circle: circle, personId: open.id),
      };
}

/// The tabs of a role's editor, as Discord's.
enum _RoleTab { display, permissions, members }

/// A role's editor, as Discord's (Matt, 2026-11-18: "closer to discord server settings"): Display (its name and
/// colour), Permissions (grouped, each a switch with its words) and Members (who has it). Everyone's (@everyone) has
/// Permissions alone. Read only where the role is at or above this install's own highest; a permission that would let
/// its people sign the circle's manifest is the owner's alone to give, and says so.
class CircleRoleEditor extends StatefulWidget {
  const CircleRoleEditor({super.key, required this.circle, required this.roleId, this.onGone});
  final Circle circle;
  final String roleId;
  final VoidCallback? onGone;

  @override
  State<CircleRoleEditor> createState() => _CircleRoleEditorState();
}

class _CircleRoleEditorState extends State<CircleRoleEditor> {
  _RoleTab _tab = _RoleTab.display;

  bool get _everyone => widget.roleId == CircleManifest.everyoneId;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circles = Circles.instance;
    final c = widget.circle;
    final m = c.manifest;
    final r = _everyone ? null : m.roles.where((x) => x.id == widget.roleId).firstOrNull;
    if (!_everyone && r == null) return const Center(child: Tr('This role is gone.'));
    final owner = _isOwner(c);
    final manage = _everyone ? circles.can(c, CirclePerm.roles) : circles.mayManageRole(c, r!.id) && circles.can(c, CirclePerm.roles);
    final tab = _everyone ? _RoleTab.permissions : _tab;
    final gap = SizedBox(height: t.space(6));

    Future<void> save(CircleRole next) async {
      final ok = await circles.saveRole(circles.bySeed(c.seed) ?? c, next);
      if (!ok && context.mounted) toast(context, 'Couldn\'t change the role', tone: GlacierToastTone.danger);
    }

    Future<void> setPerms(Set<CirclePerm> perms) async {
      final ok = _everyone ? await circles.setEveryone(circles.bySeed(c.seed) ?? c, perms) : await circles.saveRole(circles.bySeed(c.seed) ?? c, r!.copyWith(perms: perms));
      if (!ok && context.mounted) toast(context, 'Couldn\'t change what it lets people do', tone: GlacierToastTone.danger);
    }

    final perms = _everyone ? m.everyone : r!.perms;
    final why = !manage ? (circles.can(c, CirclePerm.roles) ? 'This role is at or above your own highest role, so you can\'t change it.' : 'Your roles don\'t let you manage roles.') : null;

    final head = Row(children: [
      if (r != null) ...[RoleDot(hue: r.hue, size: 18), SizedBox(width: t.space(3))] else ...[AppIcon(Lucide.users, size: 18, color: t.color('app-ink-2')), SizedBox(width: t.space(3))],
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r?.name ?? '@everyone', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: r != null && circleHues.contains(r.hue) ? circleHueInk(t, r.hue) : null)),
          Text(r == null ? 'Everyone in the circle, under every role' : '${_count(m.holdersOf(r.id), 'person', 'people')} · ${_rankWords(m, r.id)}', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
        ]),
      ),
    ]);

    final List<Widget> body = switch (tab) {
      _RoleTab.display => [
          PaneSection(title: 'Name', children: [
            SettingRow(key: const ValueKey('role-rename'), icon: AppIcon(Lucide.pencil, size: 18), label: 'Name', value: Text(r!.name), disabledReason: why, onPress: () => askCircleWords(context, title: 'Rename role', initial: r.name, then: (n) => save(r.copyWith(name: n)))),
          ]),
          gap,
          PaneSection(
            title: 'Colour',
            description: const Tr('Names are drawn in the colour of their highest role that has one.'),
            children: [
              SettingRow(
                key: const ValueKey('role-no-colour'),
                label: 'No colour',
                hint: const Tr('Names keep the text\'s own colour'),
                disabledReason: why,
                control: GlacierSwitch(checked: r.hue == circleRoleNoHue, disabled: !manage, ariaLabel: 'No colour', onCheckedChange: (on) => save(r.copyWith(hue: on ? circleRoleNoHue : 'blue'))),
              ),
              SettingRowBox(child: IgnorePointer(ignoring: !manage, child: Opacity(opacity: manage ? 1 : 0.5, child: CircleHuePicker(value: r.hue, onChanged: (h) => save(r.copyWith(hue: h)))))),
            ],
          ),
          if (manage) ...[
            gap,
            PaneSection(children: [
              SettingRow(key: const ValueKey('role-delete'), icon: AppIcon(Lucide.trash2, size: 18), label: 'Delete role', onPress: () => _confirmDeleteRole(context, c, r, then: widget.onGone)),
            ]),
          ],
        ],
      _RoleTab.permissions => [
          if (_everyone) ...[SettingsCallout(child: const Tr('What everyone in the circle may do, whatever their roles. A space can change this for itself, in its Permissions.')), gap],
          for (final (group, list) in CirclePerm.groups) ...[
            PaneSection(
              title: group,
              children: [
                for (final p in list)
                  () {
                    // Why this one can't be switched here, in a few words; null where it can.
                    final String? off = why ??
                        (p.signs && _everyone
                            ? 'Never everyone\'s: give it with a role.'
                            : (p.signs && !owner && !perms.contains(p) ? 'Only the owner can give this: it lets people change the circle for everyone.' : null));
                    return SettingRow(
                      key: ValueKey('role-perm-${p.wire}'),
                      label: p.label,
                      hint: Text(p.blurb),
                      disabledReason: off,
                      control: GlacierSwitch(
                        checked: perms.contains(p),
                        disabled: off != null,
                        ariaLabel: p.label,
                        onCheckedChange: (on) => setPerms(on ? {...perms, p} : ({...perms}..remove(p))),
                      ),
                    );
                  }(),
              ],
            ),
            SizedBox(height: t.space(4)),
          ],
          if (manage)
            PaneSection(children: [
              SettingRow(
                key: const ValueKey('role-clear-perms'),
                icon: AppIcon(Lucide.eraser, size: 18),
                label: 'Clear permissions',
                hint: Text(_everyone ? 'Everyone may do nothing but read' : 'The role gives nothing more than everyone has'),
                // Signing ones only the owner may take away too, as only they give them.
                onPress: perms.isEmpty ? null : () => setPerms(owner ? {} : {for (final p in perms) if (p.signs) p}),
              ),
            ]),
        ],
      _RoleTab.members => () {
          final people = [for (final p in circlePeople(c)) if (!p.owner) p];
          return [
            PaneSection(
              title: 'Who has it · ${m.holdersOf(r!.id)}',
              description: Text(manage ? 'Switch someone on to give them ${r.name}, off to take it away.' : 'The people with ${r.name}.'),
              children: [
                for (final p in people)
                  SettingRow(
                    key: ValueKey('role-holder-${p.id}'),
                    label: p.name,
                    labelColor: circleRoleInk(t, p),
                    disabledReason: why ?? (r.signs && !owner ? 'Only the owner gives a role that changes the circle.' : null),
                    control: GlacierSwitch(
                      checked: m.roleAssignments[p.id]?.contains(r.id) ?? false,
                      disabled: why != null || (r.signs && !owner),
                      ariaLabel: '${p.name} has ${r.name}',
                      onCheckedChange: (on) async {
                        final now = circles.bySeed(c.seed) ?? c;
                        final mine = [...?now.manifest.roleAssignments[p.id]];
                        on ? mine.add(r.id) : mine.remove(r.id);
                        final ok = await circles.setRolesOf(now, p.id, mine);
                        if (!ok && context.mounted) toast(context, 'Couldn\'t change ${p.name}\'s roles', tone: GlacierToastTone.danger);
                      },
                    ),
                  ),
                if (people.isEmpty) SettingRow(label: 'No one else is in the circle yet', disabled: true),
              ],
            ),
          ];
        }(),
    };

    return _Scroll(hue: 'indigo', children: [
      head,
      SizedBox(height: t.space(4)),
      if (!_everyone) ...[
        GlacierSegmentedControl(
          key: const ValueKey('role-tabs'),
          fullWidth: true,
          ariaLabel: 'Role settings',
          value: tab.name,
          onValueChange: (v) => setState(() => _tab = _RoleTab.values.byName(v)),
          options: const [
            GlacierSegmentedOption(value: 'display', label: Tr('Display')),
            GlacierSegmentedOption(value: 'permissions', label: Tr('Permissions')),
            GlacierSegmentedOption(value: 'members', label: Tr('Members')),
          ],
        ),
        SizedBox(height: t.space(5)),
      ],
      if (why != null) ...[SettingsCallout(icon: AppIcon(Lucide.lock, size: 18), child: Text(why)), gap],
      ...body,
    ]);
  }
}

/// Where [roleId] stands in words: "Highest role", "Role 2 of 4".
String _rankWords(CircleManifest m, String roleId) {
  final at = m.roles.indexWhere((r) => r.id == roleId);
  if (at == 0) return 'Highest role';
  return 'Role ${at + 1} of ${m.roles.length}';
}

// --- a space's permissions ------------------------------------------------------------------------------------------

/// A space: its name, kind and heading, and its Permissions, as Discord's channel overrides (Matt, 2026-11-18: "tri
/// toggles for permissions"): pick everyone or a role, then for each permission a space of its kind has, Deny, As the
/// circle says, or Allow. A role at or above this install's own highest is shown, not changed.
class _SpacePermissions extends StatefulWidget {
  const _SpacePermissions({super.key, required this.circle, required this.spaceSeed, required this.onGone});
  final Circle circle;
  final String spaceSeed;
  final VoidCallback onGone;

  @override
  State<_SpacePermissions> createState() => _SpacePermissionsState();
}

class _SpacePermissionsState extends State<_SpacePermissions> {
  String _role = CircleManifest.everyoneId;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circles = Circles.instance;
    final c = widget.circle;
    final m = c.manifest;
    final s = c.space(widget.spaceSeed);
    if (s == null) return const Center(child: Tr('This space is gone.'));
    final edit = circles.can(c, CirclePerm.spaces);
    final roles = m.roles;
    if (_role != CircleManifest.everyoneId && !roles.any((r) => r.id == _role)) _role = CircleManifest.everyoneId;
    final everyone = _role == CircleManifest.everyoneId;
    final role = everyone ? null : roles.firstWhere((r) => r.id == _role);
    final o = m.overrideOf(s.seed, _role);
    final mayChange = edit && (everyone || circles.mayManageRole(c, _role));
    final why = !edit ? 'Your roles don\'t let you manage spaces.' : (!mayChange ? '${role!.name} is at or above your own highest role.' : null);
    final per = m.overrides[s.seed] ?? const {};
    final gap = SizedBox(height: t.space(6));

    // What the circle alone gives, before this space says anything: everyone's for @everyone, and with the role's too.
    final circleGives = everyone ? m.everyone : {...m.everyone, ...role!.perms};

    return _Scroll(hue: 'amber', children: [
      PaneSection(title: 'Space', children: [
        SettingRow(key: const ValueKey('space-rename'), icon: AppIcon(Lucide.pencil, size: 18), label: 'Name', value: Text(s.name), onPress: edit ? () => askCircleWords(context, title: 'Rename ${s.name}', initial: s.name, then: (n) => circles.updateSpace(circles.bySeed(c.seed) ?? c, s.seed, name: n)) : null),
        SettingRow(
          key: const ValueKey('space-kind'),
          icon: AppIcon(spaceKindIcon(s.kind), size: 18),
          label: 'Kind',
          value: Text(spaceKindTitle(s.kind)),
          onPress: edit
              ? () => showChoices(context, title: 'What kind of space is ${s.name}?', choices: [
                    for (final k in spaceKindsOffered)
                      if (k != s.kind) Choice('Make it ${spaceKindTitle(k).toLowerCase()}', spaceKindIcon(k), () => circles.updateSpace(circles.bySeed(c.seed) ?? c, s.seed, kind: k), hint: spaceKindBlurb(k)),
                  ])
              : null,
        ),
        SettingRow(
          key: const ValueKey('space-heading'),
          icon: AppIcon(Lucide.listTree, size: 18),
          label: 'Heading',
          value: Text(s.section ?? 'None'),
          onPress: edit ? () => askCircleWords(context, title: 'Heading for ${s.name}', initial: s.section ?? '', hint: 'Spaces with the same heading are listed together. Leave it empty for none.', then: (h) => circles.updateSpace(circles.bySeed(c.seed) ?? c, s.seed, section: h.isEmpty ? null : h, clearSection: h.isEmpty)) : null,
        ),
        // Each person may write once in so long (Matt, 2026-11-19: "add ... slow mode"); not those who manage spaces.
        SettingRow(
          key: const ValueKey('space-slow'),
          icon: AppIcon(Lucide.hourglass, size: 18),
          label: 'Slow mode',
          hint: const Tr('How long each person waits between messages here. Those who manage spaces don\'t wait.'),
          value: Text(slowModeLabel(slowModeOf(s))),
          onPress: edit
              ? () => showChoices(context, title: 'Slow mode in ${s.name}', choices: [
                    for (final secs in slowModeChoices)
                      Choice(secs == 0 ? 'Off' : 'One message every ${slowModeLabel(secs)}', secs == slowModeOf(s) ? Lucide.check : Lucide.hourglass, () => circles.setSlowMode(circles.bySeed(c.seed) ?? c, s.seed, secs)),
                  ])
              : null,
        ),
        // Only the owner and admins write here (Matt, 2026-11-20: "read only channels for system messages and admin /
        // moderation announcements"); the relay holds everyone else to it too (lib/circles/welcome.dart).
        if (s.kind != SpaceKind.files)
          SettingRow(
            key: const ValueKey('space-read-only'),
            icon: AppIcon(Lucide.lock, size: 18),
            label: 'Read-only',
            hint: Text(m.systemSpace == s.seed ? 'The circle\'s system messages are written here. Only the owner and admins can post.' : 'Only the owner and admins can post here: announcements, rules. Everyone else reads.'),
            control: GlacierSwitch(
              checked: readOnlyOf(s),
              disabled: !edit,
              ariaLabel: 'Read-only',
              onCheckedChange: (on) async {
                final ok = await circles.setReadOnly(circles.bySeed(c.seed) ?? c, s.seed, on);
                if (!ok && context.mounted) toast(context, 'Couldn\'t change ${s.name}', tone: GlacierToastTone.danger);
              },
            ),
          ),
      ]),
      gap,
      PaneSection(
        title: 'Permissions',
        description: const Tr('What each role may do in this space: the cross takes a permission away here, the slash leaves it as the circle says, and the tick gives it. A role\'s word outweighs everyone\'s.'),
        children: [
          SettingRowBox(
            child: Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
              RoleChip(key: const ValueKey('space-perm-role-@'), name: '@everyone', hue: circleRoleNoHue, chosen: everyone, marked: per.containsKey(CircleManifest.everyoneId), onPressed: () => setState(() => _role = CircleManifest.everyoneId)),
              for (final r in roles) RoleChip(key: ValueKey('space-perm-role-${r.id}'), name: r.name, hue: r.hue, chosen: r.id == _role, marked: per.containsKey(r.id), onPressed: () => setState(() => _role = r.id)),
            ]),
          ),
          for (final p in CirclePerm.inSpace(s.kind))
            SettingRow(
              key: ValueKey('space-perm-${p.wire}'),
              label: p.label,
              hint: Text('${p.blurb}. The circle ${circleGives.contains(p) ? 'allows' : 'doesn\'t allow'} it${everyone ? '' : ' for ${role!.name}'}.'),
              control: PermTriToggle(
                key: ValueKey('space-perm-toggle-${p.wire}'),
                value: o.of(p),
                label: '${p.label} for ${role?.name ?? 'everyone'}',
                disabled: !mayChange,
                onChanged: (v) async {
                  final ok = await circles.setOverride(circles.bySeed(c.seed) ?? c, s.seed, _role, p, v);
                  if (!ok && context.mounted) toast(context, 'Couldn\'t change ${p.label.toLowerCase()} here', tone: GlacierToastTone.danger);
                },
              ),
            ),
          if (mayChange)
            SettingRow(
              key: const ValueKey('space-perm-clear'),
              icon: AppIcon(Lucide.eraser, size: 18),
              label: 'Clear',
              hint: Text('Everything back to as the circle says for ${role?.name ?? 'everyone'}'),
              onPress: o.isEmpty ? null : () => circles.clearOverrides(circles.bySeed(c.seed) ?? c, s.seed, _role),
            ),
        ],
      ),
      if (why != null) ...[SizedBox(height: t.space(2)), SettingsFootnote(child: Text(why))],
      if (edit) ...[
        gap,
        PaneSection(children: [
          SettingRow(key: const ValueKey('space-delete'), icon: AppIcon(Lucide.trash2, size: 18), label: 'Delete space', onPress: () => confirmRemoveCircleSpace(context, c, s)),
        ]),
      ],
    ]);
  }
}

// --- members --------------------------------------------------------------------------------------------------------

/// The Members section: everyone the circle knows of, searched by name, each with their roles as coloured chips, and
/// each pressed to give or take away roles (for whoever may manage roles).
class _Members extends StatefulWidget {
  const _Members({required this.circle, required this.hue, required this.onOpen});
  final Circle circle;
  final String hue;
  final ValueChanged<_Open> onOpen;

  @override
  State<_Members> createState() => _MembersState();
}

class _MembersState extends State<_Members> {
  String _find = '';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = widget.circle;
    final circles = Circles.instance;
    final m = c.manifest;
    final all = circlePeople(c);
    final q = _find.trim().toLowerCase();
    final people = q.isEmpty ? all : [for (final p in all) if (p.name.toLowerCase().contains(q) || m.rolesOf(p.id).any((r) => r.name.toLowerCase().contains(q))) p];
    final manage = circles.can(c, CirclePerm.roles) || _isOwner(c);
    return _Scroll(hue: widget.hue, children: [
      GlacierSearchField(key: const ValueKey('circle-members-search'), placeholder: 'Search members or roles'.t, value: _find, onValueChange: (v) => setState(() => _find = v)),
      SizedBox(height: t.space(4)),
      PaneSection(
        title: q.isEmpty ? _count(all.length, 'person', 'people') : '${people.length} of ${all.length}',
        description: Text(manage ? 'Press someone to give them roles or take roles away.' : 'Who is in ${c.name}, and their roles.'),
        children: [
          if (circles.can(c, CirclePerm.invite) && q.isEmpty) SettingRow(key: const ValueKey('circle-settings-invite'), icon: AppIcon(Lucide.userPlus, size: 18), label: 'Invite people', hint: const Tr('Friends in the app, anyone by a text, or the link.'), onPress: () => showCircleInvite(context, c)),
          for (final p in people)
            SettingRow(
              key: ValueKey('circle-person-${p.id}'),
              icon: AppIcon(p.owner || p.admin ? Lucide.shieldCheck : Lucide.userRound, size: 18),
              label: p.name,
              labelColor: circleRoleInk(t, p),
              hint: m.rolesOf(p.id).isEmpty
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Wrap(spacing: t.space(1) + 2, runSpacing: t.space(1), children: [
                        for (final r in m.rolesOf(p.id)) RoleChip(key: ValueKey('member-role-${p.id}-${r.id}'), name: r.name, hue: r.hue),
                      ]),
                    ),
              value: CircleRoleTag(person: p),
              onPress: !p.owner && manage ? () => widget.onOpen((kind: 'person', id: p.id)) : null,
            ),
          if (people.isEmpty) SettingRow(label: 'No one matches "$_find"', disabled: true),
        ],
      ),
      // Banned (CircleManifest.removed), each let back with Unban by whoever may change the circle.
      if (m.removed.isNotEmpty && q.isEmpty) ...[
        SizedBox(height: t.space(6)),
        PaneSection(
          key: const ValueKey('circle-banned'),
          title: 'Banned',
          description: const Tr('Kept out of the circle, and not heard in it. Unbanned, they can come back if invited again.'),
          children: [
            for (final id in m.removed)
              SettingRow(
                key: ValueKey('circle-banned-$id'),
                icon: AppIcon(Lucide.ban, size: 18),
                label: Voice.instance.nameOf(id).isEmpty ? 'Someone (${id.substring(0, id.length < 8 ? id.length : 8)})' : Voice.instance.nameOf(id),
                value: circles.canEdit(c) ? const Tr('Unban') : null,
                onPress: circles.canEdit(c)
                    ? () async {
                        final ok = await circles.removeMember(circles.bySeed(c.seed) ?? c, id, back: true);
                        if (context.mounted) toast(context, ok ? 'Unbanned' : 'Couldn\'t unban them', tone: ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
                      }
                    : null,
              ),
          ],
        ),
      ],
    ]);
  }
}

/// Someone's roles in a circle, each switched on or off; one at or above this install's own highest is shown, not
/// changed. For the owner, making them an admin by hand too, where they have no role.
class _PersonRoles extends StatelessWidget {
  const _PersonRoles({required this.circle, required this.personId});
  final Circle circle;
  final String personId;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circles = Circles.instance;
    final c = circle;
    final person = circlePeople(c).where((p) => p.id == personId).firstOrNull;
    if (person == null) return const Center(child: Tr('They are no longer listed.'));
    final owner = _isOwner(c);
    final mine = c.manifest.roleAssignments[person.id] ?? const [];
    return _Scroll(hue: 'green', children: [
      PaneSection(
        title: 'Roles',
        description: Text('What ${person.name} may do: what everyone may, and what these give.'),
        children: [
          for (final r in c.manifest.roles)
            () {
              final off = !circles.mayManageRole(c, r.id) ? 'At or above your own highest role' : (r.signs && !owner ? 'Only the owner gives a role that changes the circle' : null);
              return SettingRow(
                key: ValueKey('person-role-${r.id}'),
                icon: RoleDot(hue: r.hue, size: 14),
                label: r.name,
                hint: Text(r.perms.isEmpty ? 'Nothing more than everyone' : _perms(r.perms)),
                disabledReason: off,
                control: GlacierSwitch(
                  checked: mine.contains(r.id),
                  disabled: off != null,
                  ariaLabel: '${person.name} has ${r.name}',
                  onCheckedChange: (on) async {
                    final now = circles.bySeed(c.seed) ?? c;
                    final next = [...?now.manifest.roleAssignments[person.id]];
                    on ? next.add(r.id) : next.remove(r.id);
                    final ok = await circles.setRolesOf(now, person.id, next);
                    if (!ok && context.mounted) toast(context, 'Couldn\'t change ${person.name}\'s roles', tone: GlacierToastTone.danger);
                  },
                ),
              );
            }(),
          if (c.manifest.roles.isEmpty) SettingRow(label: 'No roles yet: make them in Roles', disabled: true),
        ],
      ),
      if (owner && mine.isEmpty) ...[
        SizedBox(height: t.space(6)),
        PaneSection(
          title: 'Admin',
          description: const Tr('An admin with no role can do everything but delete the circle or make admins.'),
          children: [
            SettingRow(
              key: const ValueKey('person-admin'),
              label: 'Admin',
              control: GlacierSwitch(
                checked: person.admin,
                ariaLabel: '${person.name} is an admin',
                onCheckedChange: (on) async {
                  final ok = await circles.grantAdmin(circles.bySeed(c.seed) ?? c, person.id, on: on);
                  if (!ok && context.mounted) toast(context, 'Couldn\'t change ${person.name}\'s role', tone: GlacierToastTone.danger);
                },
              ),
            ),
          ],
        ),
      ],
      // Kick or ban (Matt, 2026-11-20: "I can't seem to kick users or ban them from circles").
      if (c.manifest.mayRemove(circles.signer?.id ?? '', person.id)) ...[
        SizedBox(height: t.space(6)),
        PaneSection(
          title: 'Kick or ban',
          description: Text('A kick puts ${person.name} out now; they can come back if invited again. A ban keeps them out, and nobody here hears them.'),
          children: [
            for (final ch in circleKickBanChoices(context, c, person, (ok, done) {
              if (context.mounted) toast(context, ok ? done : 'Couldn\'t change that for ${person.name}', tone: ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
            }))
              SettingRow(key: ValueKey('person-${ch.label.startsWith('Kick') ? 'kick' : 'ban'}'), icon: AppIcon(ch.icon, size: 18, color: context.tokens.danger), label: ch.label, labelColor: context.tokens.danger, hint: ch.hint == null ? null : Text(ch.hint!), onPress: ch.onPress),
          ],
        ),
      ],
    ]);
  }
}

// --- leaving --------------------------------------------------------------------------------------------------------

/// Leave circle, asked first: it goes from this device's list only.
void _leave(BuildContext context, Circle c) {
  showChoices(context, title: 'Leave ${c.name}? It goes from your list; its link brings you back.', choices: [
    Choice('Leave circle', Lucide.logOut, () => _gone(context, c, () => Circles.instance.leave(c), 'Left ${c.name}'), danger: true),
  ]);
}

/// Delete circle, asked first: every space is taken out for everyone in it, then it is left here.
void _delete(BuildContext context, Circle c) {
  showChoices(context, title: 'Delete ${c.name}? Every space goes from it for everyone in it, and it goes from your list. This can\'t be undone.', choices: [
    Choice('Delete circle', Lucide.trash2, () => _gone(context, c, () async {
          // A manifest has no "closed" mark: one with no spaces is said to everyone, then the circle is left here.
          for (final s in c.spaces) {
            final now = Circles.instance.bySeed(c.seed);
            if (now == null) break;
            await Circles.instance.removeSpace(now, s.seed);
          }
          final now = Circles.instance.bySeed(c.seed);
          if (now != null) await Circles.instance.leave(now);
        }, '${c.name} deleted'), danger: true),
  ]);
}

/// Does [away], then puts the settings and the circle away, saying [words].
Future<void> _gone(BuildContext context, Circle c, Future<void> Function() away, String words) async {
  final nav = Navigator.of(context, rootNavigator: true);
  final shell = AppShell.maybeOf(context);
  final open = shell?.openCircleSeed == c.seed;
  await away();
  if (context.mounted) toast(context, words);
  nav.popUntil((r) => r.settings.name != 'circle-settings' || r.isFirst);
  if (open) shell?.go('messages');
}

/// Sets [c]'s invite word to [raw] (tidied), or removes it where null, saying how it went.
Future<void> chooseCircleInviteWord(BuildContext context, Circle c, String? raw) async {
  String? word;
  if (raw != null) {
    final problem = inviteWordProblem(raw);
    if (problem != null) return toast(context, problem, tone: GlacierToastTone.danger);
    word = tidyInviteWord(raw)!;
    if (word == c.inviteWord) return;
  }
  try {
    await Circles.instance.setInviteWord(c, word);
    if (context.mounted) toast(context, word == null ? 'Invite word removed' : 'gogho.st/c/$word is ${c.name}\'s now');
  } catch (e) {
    if (context.mounted) toast(context, e is InviteRelayError ? e.message : (e is StateError ? e.message : 'Couldn\'t set the word: $e'), tone: GlacierToastTone.danger);
  }
}
