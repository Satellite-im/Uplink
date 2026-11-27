import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import '../voice/discord.dart';
import '../voice/space_groups.dart';
import '../voice/voice.dart';
import 'common.dart';
import 'ripple_avatar.dart';
import 'shell.dart';
import 'space_designs/space_design.dart';
import '../voice/channels.dart';
import '../l10n/words.dart';

/// The Spaces tab's groups (Matt, 2026-11-16: "add grouping options to spaces so we can group all of a servers spaces
/// under one group and show members that are in a space proxied from discord"): spaces in no group first, then each
/// group the person made under its heading, then each linked Discord server as a group of its voice channels with who
/// is in each (lib/voice/space_groups.dart, lib/voice/discord.dart).

/// A group's heading in the Spaces tab: one the person made, or a Discord server.
@immutable
class SpaceGroupHeading {
  const SpaceGroupHeading({required this.id, required this.name, required this.count, this.discord, this.live = 0});
  final String id;
  final String name;

  /// How many spaces are in it, and how many people are in them now (a Discord server's).
  final int count;
  final int live;
  final DiscordLink? discord;
}

/// What the Spaces tab lists, in order: [VoiceChannel]s, [SpaceGroupHeading]s and [DiscordChannel]s.
List<Object> spaceRows(List<VoiceChannel> voices) {
  final groups = SpaceGroups.instance;
  final discord = DiscordServers.instance;
  final known = {for (final g in groups.groups) g.id};
  final out = <Object>[for (final c in voices) if (!known.contains(groups.groupOf(c.seed))) c];
  for (final g in groups.groups) {
    final inIt = [for (final c in voices) if (groups.groupOf(c.seed) == g.id) c];
    out.add(SpaceGroupHeading(id: g.id, name: g.name, count: inIt.length));
    if (!groups.folded(g.id)) out.addAll(inIt);
  }
  for (final l in discord.links) {
    final state = discord.stateOf(l);
    out.add(SpaceGroupHeading(id: l.group, name: l.name, count: state.channels.length, discord: l, live: state.channels.fold(0, (n, c) => n + c.members.length)));
    if (!groups.folded(l.group)) out.addAll(state.channels);
  }
  return out;
}

/// A group's heading: its name and count, a chevron that folds it, and its menu.
class SpaceGroupRow extends StatelessWidget {
  const SpaceGroupRow({super.key, required this.heading});
  final SpaceGroupHeading heading;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final groups = SpaceGroups.instance;
    final folded = groups.folded(heading.id);
    final d = heading.discord;
    final problem = d == null ? null : DiscordServers.instance.stateOf(d).problem;
    return GlacierPressable(
      onPressed: () => groups.fold(heading.id, !folded),
      semanticLabel: '${heading.name}, ${heading.count} ${heading.count == 1 ? 'space' : 'spaces'}, ${folded ? 'folded' : 'open'}',
      builder: (context, state) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(4), t.space(2), t.space(1)),
        child: Row(children: [
          AnimatedRotation(turns: folded ? -0.25 : 0, duration: const Duration(milliseconds: 160), child: AppIcon(Lucide.chevronDown, size: 16, color: t.color('app-ink-3'))),
          SizedBox(width: t.space(2)),
          if (d != null) ...[AppIcon(LucideMore.headphones, size: 15, color: t.color('app-ink-2')), SizedBox(width: t.space(1))],
          Flexible(
            child: Text(
              heading.name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-2'), tracking: 0.6),
            ),
          ),
          SizedBox(width: t.space(2)),
          Text(
            d != null ? (problem == 'not linked' ? 'Unlinked' : problem == 'gone' ? 'Bot removed' : 'Discord${heading.live > 0 ? ' · ${heading.live} in voice' : ''}') : '${heading.count}',
            style: pageText(t, t.fontSize('xs'), color: problem != null ? t.colorOf('#dd3a30') : (heading.live > 0 ? t.colorOf('#2fb35a') : t.color('app-ink-3'))),
          ),
          const Spacer(),
          IconTap(icon: Lucide.ellipsis, label: '${heading.name} options', size: 18, onPressed: () => d != null ? _discordMenu(context, d) : _groupMenu(context, heading)),
        ]),
      ),
    );
  }
}

/// The menu of a group the person made: rename it, or delete it.
void _groupMenu(BuildContext context, SpaceGroupHeading heading) {
  showChoices(context, title: heading.name, choices: [
    Choice('Rename group', Lucide.pencil, () => askGroupName(context, title: 'Rename group', initial: heading.name, then: (name) => SpaceGroups.instance.rename(heading.id, name))),
    Choice('Delete group', Lucide.trash2, () => SpaceGroups.instance.delete(heading.id), danger: true),
  ]);
}

/// A linked Discord server's menu: open it in Discord, ask again who is in its channels, or take it out of the app.
void _discordMenu(BuildContext context, DiscordLink link) {
  showChoices(context, title: link.name, choices: [
    Choice('Open in Discord', Lucide.externalLink, () => Sms.instance.openLink('https://discord.com/channels/${link.guildId}')),
    Choice('Refresh', Lucide.refreshCw, () => DiscordServers.instance.refresh()),
    Choice('Remove from Uplink', Lucide.trash2, () => DiscordServers.instance.remove(link), danger: true),
  ]);
}

/// Asks for a group's name, then gives it to [then].
void askGroupName(BuildContext context, {required String title, String initial = '', required void Function(String name) then}) {
  push(context, (_) => _GroupNamePage(title: title, initial: initial, then: then));
}

/// The page [askGroupName] opens: one field for the name.
class _GroupNamePage extends StatefulWidget {
  const _GroupNamePage({required this.title, required this.initial, required this.then});
  final String title;
  final String initial;
  final void Function(String name) then;

  @override
  State<_GroupNamePage> createState() => _GroupNamePageState();
}

class _GroupNamePageState extends State<_GroupNamePage> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done() {
    if (_name.text.trim().isEmpty) return;
    widget.then(_name.text.trim());
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: widget.title,
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8)),
        children: [
          PaneSection(title: 'Name', children: [
            SettingRowBox(
              child: GlacierInput(controller: _name, placeholder: 'Group name'.t, ariaLabel: 'Group name', autoFocus: true, autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md, onSubmitted: (_) => _done()),
            ),
          ]),
          SizedBox(height: t.space(4)),
          PaneSection(title: '', children: [SettingRow(icon: AppIcon(Lucide.check, size: 18), label: 'Save', onPress: _done)]),
        ],
      ),
    );
  }
}

/// Moves [c] into one of the groups, a new one, or out of any.
void pickSpaceGroup(BuildContext context, VoiceChannel c) {
  final groups = SpaceGroups.instance;
  final now = groups.groupOf(c.seed);
  showChoices(context, title: 'Move ${c.name} to', choices: [
    for (final g in groups.groups) Choice('${g.id == now ? '✓  ' : ''}${g.name}', Lucide.folder, () => groups.move(c.seed, g.id)),
    Choice('New group…', Lucide.folderPlus, () => askGroupName(context, title: 'New group', then: (name) => groups.move(c.seed, groups.make(name)))),
    if (now != null) Choice('No group', Lucide.x, () => groups.move(c.seed, null)),
  ]);
}

/// One of a Discord server's voice channels, as a space in its group: its name, who is in it (with their state, as
/// Discord's own sidebar shows them), and a press that joins it through the bridge (Matt, 2026-11-16: "I want the bot
/// to connect and act as my voice"). Its menu still opens it in Discord.
class DiscordChannelRow extends StatelessWidget {
  const DiscordChannelRow({super.key, required this.channel});
  final DiscordChannel channel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final green = t.colorOf('#2fb35a');
    final live = channel.members.isNotEmpty;
    void menu() => showChoices(context, title: channel.name, choices: [
          Choice('Join here', LucideMore.headphones, () => joinDiscordChannel(context, channel)),
          Choice('Open in Discord', Lucide.externalLink, () => Sms.instance.openLink(channel.link)),
          Choice('Copy link', Lucide.copy, () {
            Clipboard.setData(ClipboardData(text: channel.link));
            toast(context, 'Copied');
          }),
        ]);
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPress: menu,
      onSecondaryTap: menu,
      child: GlacierPressable(
        onPressed: () => joinDiscordChannel(context, channel),
        semanticLabel: '${channel.name}, Discord ${channel.stage ? 'stage' : 'voice channel'}, ${live ? '${channel.members.length} in it' : 'nobody in it'}. Joins through the bridge.',
        builder: (context, state) => Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
          child: Container(
            decoration: BoxDecoration(color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'), borderRadius: BorderRadius.circular(t.lenOf('1rem'))),
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3) - 2, t.space(3), t.space(3) - 2),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                AppIcon(channel.stage ? LucideMore.audioLines : Lucide.volume2, size: 18, color: live ? green : t.color('app-ink-2')),
                SizedBox(width: t.space(2)),
                Expanded(child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: live ? 'bold' : 'semibold', color: t.color('app-ink')))),
                if (channel.bridged) ...[_Badge(words: 'GHOST', color: t.color('app-ink')), SizedBox(width: t.space(2))],
                if (live) Text('${channel.members.length} in voice', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: green)),
              ]),
              // Who is in it, as Discord's sidebar lists them: face, name, and what they have on or off.
              for (final m in channel.members)
                Padding(
                  padding: EdgeInsetsDirectional.only(start: t.space(6), top: t.space(2)),
                  child: Row(children: [
                    RippleAvatar(name: m.name, level: 0, size: 24),
                    SizedBox(width: t.space(2)),
                    Expanded(child: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')))),
                    if (m.bot) _Badge(words: 'BOT', color: t.color('app-ink-3')),
                    if (m.streaming) _Badge(words: 'LIVE', color: t.colorOf('#dd3a30')),
                    if (m.video) Padding(padding: EdgeInsetsDirectional.only(start: t.space(1)), child: AppIcon(Lucide.video, size: 14, color: t.color('app-ink-3'))),
                    if (m.deafened)
                      Padding(padding: EdgeInsetsDirectional.only(start: t.space(1)), child: AppIcon(LucideMore.headphoneOff, size: 14, color: t.colorOf('#dd3a30')))
                    else if (m.muted)
                      Padding(padding: EdgeInsetsDirectional.only(start: t.space(1)), child: AppIcon(LucideMore.micOff, size: 14, color: t.colorOf('#dd3a30'))),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A tiny filled tag in a Discord channel's row: GHOST on a bridged channel, BOT and LIVE beside a member.
class _Badge extends StatelessWidget {
  const _Badge({required this.words, required this.color});
  final String words;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      margin: EdgeInsetsDirectional.only(start: t.space(1)),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
      child: Text(words, style: pageText(t, 9, weight: 'bold', color: const Color(0xFFFFFFFF))),
    );
  }
}

/// Links a Discord server: add the bot to it, type /ghost link there, enter the code here.
class AddDiscordScreen extends StatefulWidget {
  const AddDiscordScreen({super.key});

  @override
  State<AddDiscordScreen> createState() => _AddDiscordScreenState();
}

class _AddDiscordScreenState extends State<AddDiscordScreen> {
  final _code = TextEditingController();
  String? _invite, _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    DiscordServers.instance.inviteUrl().then((url) {
      if (mounted) setState(() => _invite = url);
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  /// Claims the server with the code typed; a refusal is shown under the field in the service's words.
  Future<void> _link() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final name = await DiscordServers.instance.claim(_code.text);
      if (!mounted) return;
      toast(context, '$name is in your spaces');
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = SizedBox(height: t.space(5));
    return GhostPage(
      title: 'Add a Discord server',
      actions: [docsButton('discord')],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          SettingsCallout(child: const Tr('Your server\'s voice channels show up in Messages as a group of spaces, with who is in each right now. Press one to join it from here: Uplink\'s bot carries the sound and the chat both ways.')),
          gap,
          PaneSection(
            title: '1. Add the bot',
            description: const Tr('Someone who can manage the server adds Uplink\'s bot. It only sees channel names and who is in voice.'),
            children: [
              SettingRow(
                icon: AppIcon(Lucide.userPlus, size: 18),
                label: 'Add the bot to your server',
                hint: const Tr('Opens Discord. Skip this if the bot is already there.'),
                onPress: () => Sms.instance.openLink(_invite ?? DiscordServers.knownInvite),
              ),
            ],
          ),
          gap,
          PaneSection(
            title: '2. Get a code',
            description: const Tr('In any channel of the server, type /ghost link. The bot answers with a code only you see. It works once, for 10 minutes.'),
            children: const [],
          ),
          gap,
          PaneSection(title: '3. Enter it', children: [
            SettingRowBox(
              child: GlacierInput(controller: _code, placeholder: 'ABC123'.t, ariaLabel: 'Code', autoCapitalize: TextCapitalization.characters, size: GlacierFieldSize.md, onSubmitted: (_) => _link()),
            ),
            SettingRow(icon: AppIcon(Lucide.link, size: 18), label: _busy ? 'Linking…' : 'Link the server', disabled: _busy, onPress: _busy ? null : _link),
          ]),
          if (_problem != null) ...[SizedBox(height: t.space(3)), SettingsCallout(child: Text(_problem!))],
        ],
      ),
    );
  }
}

/// Joins [channel] through the bridge: the bot goes into the Discord voice channel and a space for it, this device
/// joins the space, and the call opens as any space's does.
Future<void> joinDiscordChannel(BuildContext context, DiscordChannel channel) async {
  toast(context, 'Joining ${channel.name}…');
  try {
    final space = await DiscordServers.instance.joinVoice(channel);
    await Voice.instance.join(space);
    if (!context.mounted) return;
    if (!openSpaceCall(context)) AppShell.maybeOf(context)?.go('voice');
  } catch (e) {
    if (context.mounted) toast(context, e is DiscordProblem ? e.words : 'Couldn\'t join: $e', tone: GlacierToastTone.danger);
  }
}
