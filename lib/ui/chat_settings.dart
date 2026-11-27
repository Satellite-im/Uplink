import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/ghost_icons.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../friends/friends.dart';
import '../friends/groups.dart';
import '../sms.dart';
import 'background_picker.dart';
import 'common.dart';
import 'encryption.dart';
import 'export_ui.dart';
import '../l10n/words.dart';

/// One conversation's own settings, from the cog at its top (Matt, 2026-11-13: "we should have chat backgrounds be on
/// a per chat setting, each chat should get it's own settings cog"): who is in it, its background and the colour of
/// your bubbles in it, its encryption, and whether it is muted or pinned.
class ChatSettingsScreen extends StatefulWidget {
  const ChatSettingsScreen({super.key, required this.thread, required this.people});
  final int thread;
  final List<Person> people;

  @override
  State<ChatSettingsScreen> createState() => _ChatSettingsScreenState();
}

class _ChatSettingsScreenState extends State<ChatSettingsScreen> {
  /// Whether this is an RCS group Google Messages knows, whose name is everyone's.
  bool _rcsGroup = false;

  Conversation? _conversation;
  E2eState _e2e = const E2eState();

  /// The Friend row was pressed: asks, accepts, or (asked first) takes a request back or stops being friends.
  Future<void> _friend(Person who) async {
    final friends = Friends.instance;
    switch (_e2e.friend) {
      case '':
        await friends.add(who.address);
        if (mounted) toast(context, 'Friend request sent to ${who.label}');
      case 'invited':
        await friends.accept(who.address);
        if (mounted) toast(context, 'You and ${who.label} are friends');
      default:
        final friend = _e2e.isFriend;
        showChoices(context, title: friend ? 'Stop being friends with ${who.label}? What you write to them goes as a text again.' : 'Take back the friend request to ${who.label}?', choices: [
          Choice(friend ? 'Remove friend' : 'Take back', Lucide.userRound, () async {
            await friends.remove(who.address);
            _load();
          }, danger: true),
        ]);
        return;
    }
    _load();
  }
  StreamSubscription<int>? _changes;

  /// The group of friends this conversation is, where it is one (lib/friends/groups.dart).
  Group? get _ghost => Groups.instance.ofThread(widget.thread);
  bool get _group => widget.people.length > 1 || _ghost != null;

  void _groupsChanged() {
    if (mounted) setState(() {});
  }

  /// A member's row was pressed, by an admin: make them one too (or no longer), or take them out.
  void _member(Group g, GroupMember m) {
    showChoices(context, title: m.label, choices: [
      Choice(m.admin ? 'Remove as admin' : 'Make admin', Lucide.shieldCheck, () => _try(() => Groups.instance.setAdmin(g.id, m.id, !m.admin))),
      Choice('Remove from group', Lucide.userMinus, () => _try(() => Groups.instance.remove(g.id, m.id)), danger: true),
    ]);
  }

  /// Add people: the friends who are not in it yet.
  void _addPeople(Group g) {
    final inIt = {for (final m in g.members) Friends.digits(m.shown)};
    final can = Friends.instance.friends.where((f) => !inIt.contains(Friends.digits(f.address))).toList();
    if (can.isEmpty) {
      toast(context, 'Every friend of yours is in it already');
      return;
    }
    showChoices(context, title: 'Add a friend to ${g.title}', choices: [
      for (final f in can) Choice(f.person?.label ?? f.address, Lucide.userPlus, () => _try(() => Groups.instance.add(g.id, f.address))),
    ]);
  }

  /// Leave group, asked first.
  void _leave(Group g) {
    showChoices(context, title: 'Leave ${g.title}? Its conversation stays on this phone, and you can be added again.', choices: [
      Choice('Leave group', Lucide.logOut, () => _try(() => Groups.instance.leave(g.id)), danger: true),
    ]);
  }

  /// Makes a change to the group of friends, and says why in a toast where it is refused.
  Future<void> _try(Future<void> Function() change) async {
    try {
      await change();
    } catch (e) {
      if (mounted) toast(context, e is StateError ? e.message : 'Couldn\'t change the group', tone: GlacierToastTone.danger);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
    _changes = Sms.instance.changes.stream.listen((_) => _load());
    Groups.instance.addListener(_groupsChanged);
  }

  @override
  void dispose() {
    Groups.instance.removeListener(_groupsChanged);
    _changes?.cancel();
    super.dispose();
  }

  /// Reads the conversation again, whether it is an RCS group, and (one person only) where encryption and friendship
  /// stand with them. Run at the start and whenever the phone says something changed.
  Future<void> _load() async {
    try {
      // This one alone: the whole list is a long read on a phone with thousands.
      final c = await Sms.instance.conversation(widget.thread);
      if (mounted) setState(() => _conversation = c);
    } catch (_) {}
    // An RCS group's name is everyone's (Matt, 2026-11-18: "there is no rcs group chat name that is set for other users").
    if (_group) {
      final rcs = await Sms.instance.isRcsGroup(widget.thread);
      if (mounted && rcs != _rcsGroup) setState(() => _rcsGroup = rcs);
    }
    if (_group || widget.people.isEmpty) return;
    try {
      final e = await Sms.instance.e2e(widget.people.first.address);
      if (mounted) setState(() => _e2e = e);
    } catch (_) {}
  }

  /// Sets one of the conversation's switches (muted, pinned and the like) on the phone, then reads it back.
  Future<void> _flag(String name, bool on) async {
    await Sms.instance.threadFlag(name, widget.thread, on);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final thread = widget.thread;
    final people = widget.people;
    final c = _conversation;
    final own = ChatBackground.own(app, thread);
    final ghost = _ghost;
    final title = ghost != null ? ghost.title : (people.isEmpty ? (c?.name ?? 'Conversation') : (c?.name ?? Conversation.peopleTitle(people)));
    return GlacierScope(
      attrs: const {'hue': 'indigo'},
      child: Builder(builder: (context) {
        final t = context.tokens;
        return SettingsPaneScope(
          finder: SettingsFinder(),
          child: GhostPage(
            title: 'Conversation settings',
            body: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              children: [
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Avatar(people: people, size: t.lenOf('4.5rem')),
                  SizedBox(height: t.space(3)),
                  Text(title, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xl'), weight: 'bold', color: t.color('app-ink'))),
                  if (_e2e.on) ...[
                    SizedBox(height: t.space(1)),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIcon(Lucide.lock, size: 12, strokeWidth: 2.4, wash: false, color: t.color('app-ink-3')),
                      const SizedBox(width: 4),
                      Text(_e2e.isFriend ? (_e2e.verified ? 'Friend · verified' : 'Friend · encrypted') : (_e2e.verified ? 'Encrypted · verified' : 'Encrypted'), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                    ]),
                  ],
                ]),
                SizedBox(height: t.space(5)),
                // A group can be given a name (Matt, 2026-11-14: "expand on the ability to create, name and manage
                // groups like telegram"). It is this phone's own: a group text has nowhere to carry one. On a
                // computer it is asked of the phone, where the phone can (Sms.can).
                // A group of friends has a name every member sees, which its admins give it; its members, with who
                // is an admin; and, for an admin, adding a friend, making another admin and taking someone out
                // (Matt: "create, name and manage groups like telegram"). Anyone can leave.
                if (ghost != null) ...[
                  if (ghost.amAdmin) ...[
                    PaneSection(title: 'Group name', footer: const Tr('Everyone in the group sees this name.'), children: [
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                        child: _GroupName(
                          key: ValueKey('shared-${ghost.name}'),
                          thread: thread,
                          name: ghost.name.isEmpty ? null : ghost.name,
                          people: people,
                          onSaved: _load,
                          save: (typed) => Groups.instance.rename(ghost.id, typed),
                        ),
                      ),
                    ]),
                    SizedBox(height: t.space(5)),
                  ],
                  PaneSection(
                    title: '${ghost.members.length} ${ghost.members.length == 1 ? 'member' : 'members'}',
                    footer: Text(ghost.gone ? 'You are no longer in this group.' : 'What is written here goes to each member over the internet, encrypted, never as a text.'),
                    children: [
                      for (final m in ghost.members)
                        SettingRow(
                          icon: AppIcon(m.admin ? Lucide.shieldCheck : Lucide.userRound, size: 18),
                          // As this phone knows them (GroupMember.shown), never the address the group's admin wrote.
                          label: m.label,
                          value: m.admin ? const Tr('Admin') : null,
                          hint: m.name != null && !m.me && !m.standIn ? Text(m.shown) : null,
                          onPress: ghost.amAdmin && !m.me ? () => _member(ghost, m) : null,
                        ),
                      if (ghost.amAdmin) SettingRow(icon: const AppIcon(Lucide.userPlus, size: 18), label: 'Add people', onPress: () => _addPeople(ghost)),
                      if (!ghost.gone) SettingRow(icon: const AppIcon(Lucide.logOut, size: 18), label: 'Leave group', onPress: () => _leave(ghost)),
                    ],
                  ),
                  SizedBox(height: t.space(5)),
                ],
                if (ghost == null && _group && Sms.can('threadName')) ...[
                  PaneSection(
                      title: 'Group name',
                      // An RCS group's name goes to everyone through Google Messages; a picture-message (MMS) group has no
                      // name of its own to share, so it is this phone's alone.
                      footer: Text(_rcsGroup ? 'Everyone in the group sees this name: it is renamed through Google Messages.' : 'Only you see this name. Picture-message (MMS) groups have no shared name, so the others see the group as they always have.'),
                      children: [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                      child: _GroupName(key: ValueKey('name-${c?.name}'), thread: thread, name: c?.name, people: people, onSaved: _load),
                    ),
                  ]),
                  SizedBox(height: t.space(5)),
                ],
                if (ghost == null) PaneSection(title: _group ? '${people.length} people' : 'Person', children: [
                  for (final p in people)
                    SettingRow(
                      icon: AppIcon(Sms.remote ? Lucide.copy : Lucide.phone, size: 18),
                      label: p.label,
                      hint: p.name != null && p.name!.isNotEmpty ? Text(p.address) : null,
                      // The phone calls; a computer copies the number.
                      onPress: Sms.remote
                          ? () async {
                              await Clipboard.setData(ClipboardData(text: p.address));
                              if (context.mounted) toast(context, 'Number copied');
                            }
                          : () => const MethodChannel('ghost_messaging/sms').invokeMethod('dial', {'address': p.address}),
                    ),
                ]),
                SizedBox(height: t.space(5)),
                PaneSection(
                  title: 'Look',
                  footer: Text(Sms.remote
                      ? 'For this conversation alone, on this computer. The phone keeps what it wears there.'
                      : 'For this conversation alone. Every other conversation keeps what it wears.'),
                  children: [
                    SettingRow(
                      icon: const AppIcon(Lucide.image, size: 18),
                      label: 'Chat background',
                      value: Text(own == null ? 'Same as every chat' : own.label),
                      onPress: () => push<void>(context, (_) => BackgroundPicker(thread: thread, who: _group ? null : (people.isEmpty ? null : people.first.label), people: people)),
                    ),
                    SettingRow(
                      icon: const AppIcon(Lucide.palette, size: 18),
                      label: 'Your bubbles here',
                      layout: SettingRowLayout.stacked,
                      control: BubbleSwatches(chosen: app.choice('bubble_$thread', ''), same: true, onPick: (id) => app.set('bubble_$thread', id)),
                    ),
                    SettingRowBox(child: BackgroundPreview(background: ChatBackground.of(app, thread), thread: thread)),
                  ],
                ),
                if (!_group && people.isNotEmpty) ...[
                  SizedBox(height: t.space(5)),
                  PaneSection(title: 'Privacy', children: [
                    SettingRow(
                      icon: AppIcon(_e2e.on ? (_e2e.verified ? Lucide.shieldCheck : Lucide.lock) : Lucide.keyRound, size: 18),
                      label: 'Encryption',
                      hint: Text(switch (_e2e.state) {
                        'on' when _e2e.plainWarning => 'On, but ${people.first.label}\'s last ${_e2e.plain == 1 ? 'text' : '${_e2e.plain} texts'} came without it. They may not be able to read what you send.${Sms.can('e2eOff') ? '' : ' It is turned off from the phone.'}',
                        'on' when !Sms.can('e2eOff') => _e2e.verified ? 'On, and the safety number is verified. It is turned off from the phone.' : 'On. It is turned off, and its safety number compared, from the phone.',
                        'on' => _e2e.verified ? 'On, and the safety number is verified.' : 'On. Compare the safety number to be sure nobody is in the middle.',
                        'pending' => _e2e.changed ? '${people.first.label} sent a NEW key. Review it before accepting.' : '${people.first.label} sent their key and waits for your yes.',
                        'offered' => 'Your key was sent. It starts when ${people.first.label} accepts.',
                        _ when !Sms.can('e2eOffer') => 'Off. It is turned on from the phone.',
                        _ => _e2e.hasGhost ? '${people.first.label} has Uplink too: your texts can go sealed so only your two phones read them.' : 'Off. It needs ${people.first.label} to have Uplink too.',
                      }),
                      // Keys are made, sent and agreed to by the phone that holds them: a computer asks it to (Sms.can), or shows
                      // where it stands where its phone's app is from before it could.
                      onPress: Sms.can('e2eOffer') ? () => showEncryptionChoices(context, people.first, _e2e, _load) : null,
                    ),
                    // Friends (lib/friends/friends.dart): offered where both have the app and a relay server
                    // answers; where the two already stand somewhere it is always said. Asked and answered on the
                    // phone, which holds the keys and the routes.
                    if (!Sms.paired && (_e2e.friend.isNotEmpty || (Friends.instance.available && (_e2e.on || _e2e.offerable))))
                      SettingRow(
                        icon: AppIcon(_e2e.isFriend ? Lucide.userCheck : Lucide.userPlus, size: 18),
                        label: switch (_e2e.friend) { 'yes' => 'Friends', 'invited' => 'Accept friend request', 'want' || 'asked' => 'Friend request sent', _ => 'Add friend' },
                        hint: Text(switch (_e2e.friend) {
                          'yes' => 'What you write to ${people.first.label} goes over the internet, encrypted, and as a text only where it can\'t. Tap to stop being friends.',
                          'invited' => '${people.first.label} asked. Friends chat over the internet, encrypted, not by text.',
                          'want' || 'asked' => 'Waiting for ${people.first.label} to accept. Tap to take it back.',
                          _ => '${people.first.label} has Uplink too. Friends chat over the internet, encrypted, not by text.',
                        }),
                        onPress: () => _friend(people.first),
                      ),
                  ]),
                ],
                SizedBox(height: t.space(5)),
                PaneSection(title: 'This conversation', children: [
                  SettingRow(
                    icon: const AppIcon(GhostIcons.bellOff, size: 18),
                    label: 'Mute notifications',
                    hint: Text(Sms.remote ? 'On the phone: messages still arrive, quietly.' : 'Messages still arrive, quietly.'),
                    control: GlacierSwitch(checked: c?.muted ?? false, onCheckedChange: (on) => _flag('muted', on), ariaLabel: 'Mute notifications'),
                  ),
                  SettingRow(
                    icon: const AppIcon(Lucide.pin, size: 18),
                    label: 'Pin to top',
                    control: GlacierSwitch(checked: c?.pinned ?? false, onCheckedChange: (on) => _flag('pinned', on), ariaLabel: 'Pin to top'),
                  ),
                  SettingRow(
                    icon: AppIcon((c?.archived ?? false) ? Lucide.archiveRestore : Lucide.archive, size: 18),
                    label: (c?.archived ?? false) ? 'Move back to Messages' : 'Archive',
                    onPress: () async {
                      final to = !(c?.archived ?? false);
                      await Sms.instance.archive(thread, to);
                      await _load();
                      if (context.mounted) toast(context, to ? 'Archived' : 'Moved back to Messages');
                    },
                  ),
                  // Export (GMFB-36): the whole conversation as a Markdown or JSON file, with its files if asked.
                  SettingRow(
                    icon: const AppIcon(Lucide.download, size: 18),
                    label: 'Export conversation',
                    hint: const Tr('Every message as Markdown or JSON, with its pictures and files if you like.'),
                    onPress: () => exportTexts(context, thread, c?.title ?? widget.people.map((p) => p.label).join(', '), widget.people),
                  ),
                ]),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// A group's name, typed: kept as the field is left or Enter is pressed; emptied, the group goes by its people's
/// names again.
class _GroupName extends StatefulWidget {
  const _GroupName({super.key, required this.thread, required this.name, required this.people, required this.onSaved, this.save});

  /// How the name is kept, where it is not this phone's own name for the conversation: a group of friends'.
  final Future<void> Function(String name)? save;
  final int thread;
  final String? name;
  final List<Person> people;
  final VoidCallback onSaved;

  @override
  State<_GroupName> createState() => _GroupNameState();
}

class _GroupNameState extends State<_GroupName> {
  late final _text = TextEditingController(text: widget.name ?? '');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final typed = _text.text.trim();
    if (typed == (widget.name ?? '')) return;
    try {
      final own = widget.save;
      await (own != null ? own(typed) : Sms.instance.setThreadName(widget.thread, typed));
      if (mounted) toast(context, typed.isEmpty ? 'Name removed' : 'Named $typed');
      widget.onSaved();
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t save the name', tone: GlacierToastTone.danger);
    }
  }

  @override
  Widget build(BuildContext context) => GlacierInput(
        controller: _text,
        placeholder: Conversation.peopleTitle(widget.people),
        ariaLabel: 'Group name',
        size: GlacierFieldSize.md,
        onSubmitted: (_) => _save(),
        onBlur: _save,
      );
}
