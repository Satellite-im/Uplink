/// A Signal or Telegram group's drawer, risen from the foot of the screen by a long press on the chat's name (Matt,
/// 2026-11-16: "Add them to a drawer when pressing and holding on the group name add support for all supported
/// featues"): its name, picture and description, the disappearing-message timer, who is in it (each made admin or
/// removed), adding people, who may do what, the invite link, and leaving. Every change is made on the network itself
/// ([InboxNetwork.changeGroup]), where everyone in the group sees it; what the group's rules do not let this person
/// change is shown and not offered.
library;

import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../inbox/inbox.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart' show pageText;
import '../sms.dart';
import 'common.dart';
import 'skeleton.dart';
import '../l10n/words.dart';

/// Opens the drawer of the group [chatId] on [network].
Future<void> showGroupDrawer(BuildContext context, InboxNetwork network, String chatId) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: const Color(0x66000000),
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => GroupDrawer(network: network, chatId: chatId),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The words for a timer of [seconds].
String timerWords(int seconds) => disappearingTimers.where((t) => t.$1 == seconds).firstOrNull?.$2 ?? (seconds == 0 ? 'Off' : '$seconds seconds');

/// The drawer itself: the group as the network last gave it, read as it opens and again after each change.
class GroupDrawer extends StatefulWidget {
  const GroupDrawer({super.key, required this.network, required this.chatId});
  final InboxNetwork network;
  final String chatId;

  @override
  State<GroupDrawer> createState() => _GroupDrawerState();
}

class _GroupDrawerState extends State<GroupDrawer> {
  GroupDetails? _g;
  String? _problem;
  bool _busy = false;
  final _title = TextEditingController();
  final _about = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _about.dispose();
    super.dispose();
  }

  /// Asks the network for the group and fills the name and description fields from it; null from the network means
  /// it is not a group that can be changed from here.
  Future<void> _load() async {
    try {
      final g = await widget.network.groupDetails(widget.chatId);
      if (!mounted) return;
      setState(() {
        _g = g;
        _problem = g == null ? 'This isn\'t a group ${widget.network.name} lets Uplink change.' : null;
        if (g != null) {
          _title.text = g.title;
          _about.text = g.description;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _problem = _words(e));
    }
  }

  /// An error as words a person reads: without Dart's "Bad state: " and the like at its start.
  static String _words(Object e) => '$e'.replaceFirst(RegExp(r'^(Bad state|Exception|StateError): '), '');

  /// Makes [change] on the network, says [done] when it is made, and shows the group as it then is.
  Future<void> _change(GroupChange change, String done) async {
    if (_busy || change.isEmpty) return;
    setState(() => _busy = true);
    try {
      final g = await widget.network.changeGroup(widget.chatId, change);
      if (!mounted) return;
      if (change.leave || g == null) {
        Navigator.of(context).pop();
        toast(context, done);
        return;
      }
      setState(() {
        _g = g;
        _title.text = g.title;
        _about.text = g.description;
      });
      toast(context, done);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t change the group: ${_words(e)}', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // The name and the description are saved as typed, only where they changed; a name is never saved empty.
  void _saveTitle() {
    final g = _g;
    final typed = _title.text.trim();
    if (g == null || typed.isEmpty || typed == g.title) return;
    _change(GroupChange(title: typed), 'Named $typed');
  }

  void _saveAbout() {
    final g = _g;
    final typed = _about.text.trim();
    if (g == null || typed == g.description.trim()) return;
    _change(GroupChange(description: typed), typed.isEmpty ? 'Description removed' : 'Description saved');
  }

  /// The picture's menu: choose one from the device, or remove the one it has.
  Future<void> _photo() async {
    final g = _g!;
    await showChoices(context, title: 'The group\'s picture', choices: [
      Choice('Choose a picture', Lucide.image, () async {
        final picked = await Sms.instance.pickImages();
        if (picked.isEmpty || !mounted) return;
        try {
          final path = await Sms.instance.cacheCopy(picked.first);
          await _change(GroupChange(photo: path), 'Picture changed');
        } catch (e) {
          if (mounted) toast(context, 'Couldn\'t use that picture: ${_words(e)}', tone: GlacierToastTone.danger);
        }
      }),
      if (g.photo != null) Choice('Remove the picture', Lucide.trash2, () => _change(const GroupChange(photo: ''), 'Picture removed'), danger: true),
    ]);
  }

  /// The disappearing-message timer's choices, the one set now ticked.
  void _timer() {
    final g = _g!;
    showChoices(context, title: 'Messages sent after this disappear for everyone after', choices: [
      for (final (seconds, words) in disappearingTimers)
        Choice(words, seconds == g.timer ? Lucide.check : Lucide.clock, () => _change(GroupChange(timer: seconds), seconds == 0 ? 'Disappearing messages off' : 'Messages disappear after ${words.toLowerCase()}')),
    ]);
  }

  /// A member's menu: only what the network and the group's rules let this person do to them, and copying their
  /// number. Nothing opens where there is nothing to offer.
  void _person(GroupPerson p) {
    final g = _g!;
    final choices = [
      if (g.can(GroupFeature.admins) && g.canSetAdmins && !p.me && !p.owner)
        p.admin
            ? Choice('Remove as admin', Lucide.userMinus, () => _change(GroupChange(unadmin: [p.id]), '${p.name} is no longer an admin'))
            : Choice('Make admin', Lucide.crown, () => _change(GroupChange(admin: [p.id]), '${p.name} is an admin')),
      if (g.can(GroupFeature.removePeople) && g.canRemovePeople && !p.me && !p.owner)
        Choice('Remove from the group', Lucide.userX, () => _change(GroupChange(remove: [p.id]), '${p.name} removed'), danger: true),
      if (p.number != null) Choice('Copy ${p.number}', Lucide.copy, () => Clipboard.setData(ClipboardData(text: p.number!))),
    ];
    if (choices.isEmpty) return;
    showChoices(context, title: p.name, choices: choices);
  }

  /// Add people: the network's contacts who are neither in the group nor already asked into it.
  void _add() {
    final g = _g!;
    final inIt = {for (final p in [...g.people, ...g.pending]) p.id};
    final can = [for (final c in widget.network.contacts) if (!inIt.contains(c.id)) c];
    if (can.isEmpty) {
      toast(context, 'Everyone in your ${widget.network.name} contacts is in this group already');
      return;
    }
    showChoices(context, title: 'Add to ${g.title}', choices: [
      for (final c in can) Choice(c.name, Lucide.userPlus, () => _change(GroupChange(add: [c.id]), '${c.name} added'), hint: c.number),
    ]);
  }

  void _leave() {
    final g = _g!;
    showChoices(context, title: 'Leave ${g.title}? You won\'t get its messages, and someone in it would have to add you back.', choices: [
      Choice('Leave the group', Lucide.logOut, () => _change(const GroupChange(leave: true), 'You left ${g.title}'), danger: true),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final g = _g;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(2), pad.top + t.space(6), t.space(2), pad.bottom + t.space(2)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.lenOf('34rem')),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(t.radius('xl')),
            child: ColoredBox(
              color: t.color('glacier-bg'),
              child: Stack(children: [
                SingleChildScrollView(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(3), t.space(4)),
                  child: g == null
                      ? (_problem == null
                          // Its people in bones while the group is read (lib/ui/skeleton.dart).
                          ? const SkeletonPeople(label: 'Loading the group', most: 5, shrink: true)
                          : Padding(
                              padding: EdgeInsets.all(t.space(6)),
                              child: Center(child: Text(_problem!, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
                            ))
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: _sections(context, g)),
                ),
                if (_busy) PositionedDirectional(top: t.space(3), end: t.space(3), child: const GhostSpinner()),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// The drawer's content, top to bottom, for the group as it stands.
  List<Widget> _sections(BuildContext context, GroupDetails g) {
    final t = context.tokens;
    final edit = g.canEditInfo;
    Widget person(GroupPerson p, {String? note}) => SettingRow(
          icon: Avatar(people: [Person(address: '${widget.network.id}:${p.id}', name: p.name)], size: 32),
          label: p.me ? '${p.name} (you)' : p.name,
          hint: Text([if (p.owner) 'Owner' else if (p.admin) 'Admin', ?note, ?p.number].join(' · ').ifEmpty('Member')),
          onPress: g.canSetAdmins || g.canRemovePeople || p.number != null ? () => _person(p) : null,
        );
    final admins = [...g.people.where((p) => p.owner || p.admin), ...g.people.where((p) => !p.owner && !p.admin)];
    return [
      // The face and the name.
      Center(
        child: GlacierPressable(
          onPressed: edit && g.can(GroupFeature.photo) ? _photo : null,
          builder: (context, state) => Column(children: [
            Avatar(people: [Person(address: '${widget.network.id}:${widget.chatId}', name: g.title, photo: g.photo)], size: t.lenOf('5rem')),
            if (edit && g.can(GroupFeature.photo))
              Padding(padding: EdgeInsets.only(top: t.space(1)), child: Text('Change picture', style: pageText(t, t.fontSize('xs'), color: t.color('app-accent')))),
          ]),
        ),
      ),
      SizedBox(height: t.space(3)),
      PaneSection(
        title: 'Group',
        footer: edit ? null : Tr('Only admins can change this group\'s details.'),
        children: [
          if (g.can(GroupFeature.title))
            SettingRow(
              label: 'Name',
              layout: SettingRowLayout.stacked,
              control: edit
                  ? GlacierInput(controller: _title, ariaLabel: 'Group name', size: GlacierFieldSize.md, autoCapitalize: TextCapitalization.sentences, onSubmitted: (_) => _saveTitle(), onBlur: _saveTitle)
                  : Text(g.title, style: pageText(t, t.fontSize('md'))),
            ),
          if (g.can(GroupFeature.description))
            SettingRow(
              label: 'Description',
              layout: SettingRowLayout.stacked,
              control: edit
                  ? GlacierInput(controller: _about, placeholder: 'What the group is for'.t, ariaLabel: 'Group description', size: GlacierFieldSize.md, autoCapitalize: TextCapitalization.sentences, onSubmitted: (_) => _saveAbout(), onBlur: _saveAbout)
                  : Text(g.description.isEmpty ? 'None' : g.description, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            ),
          if (g.can(GroupFeature.timer))
            SettingRow(
              icon: const AppIcon(Lucide.clock, size: 18),
              label: 'Disappearing messages',
              value: Text(timerWords(g.timer)),
              onPress: edit ? _timer : null,
            ),
        ],
      ),
      PaneSection(
        title: '${g.people.length} ${g.people.length == 1 ? 'person' : 'people'}',
        children: [
          if (g.can(GroupFeature.addPeople) && g.canAddPeople) SettingRow(icon: const AppIcon(Lucide.userPlus, size: 18), label: 'Add people', onPress: _add),
          for (final p in admins) person(p),
        ],
      ),
      if (g.pending.isNotEmpty) PaneSection(title: 'Invited', children: [for (final p in g.pending) person(p, note: 'Invited')]),
      if (g.requesting.isNotEmpty) PaneSection(title: 'Asking to join', children: [for (final p in g.requesting) person(p, note: 'Asking to join')]),
      if (g.can(GroupFeature.announcementsOnly) || g.can(GroupFeature.editInfoRule) || g.can(GroupFeature.addPeopleRule))
        PaneSection(
          title: 'Who can',
          footer: g.canChangeRules ? null : const Tr('Only admins can change these.'),
          children: [
            if (g.can(GroupFeature.announcementsOnly))
              _rule('Only admins can send messages', g.announcementsOnly, g.canChangeRules, (on) => _change(GroupChange(announcementsOnly: on), on ? 'Only admins can send messages' : 'Everyone can send messages')),
            if (g.can(GroupFeature.editInfoRule))
              _rule('Only admins can edit the group', g.editInfoAdminsOnly, g.canChangeRules, (on) => _change(GroupChange(editInfoAdminsOnly: on), on ? 'Only admins can edit the group' : 'Everyone can edit the group')),
            if (g.can(GroupFeature.addPeopleRule))
              _rule('Only admins can add people', g.addPeopleAdminsOnly, g.canChangeRules, (on) => _change(GroupChange(addPeopleAdminsOnly: on), on ? 'Only admins can add people' : 'Everyone can add people')),
          ],
        ),
      PaneSection(children: [
        if (g.can(GroupFeature.inviteLink) && g.inviteLink != null)
          SettingRow(
            icon: const AppIcon(Lucide.link, size: 18),
            label: 'Copy invite link',
            hint: Text(g.inviteLink!, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPress: () {
              Clipboard.setData(ClipboardData(text: g.inviteLink!));
              toast(context, 'Invite link copied');
            },
          ),
        if (g.can(GroupFeature.leave)) SettingRow(icon: AppIcon(Lucide.logOut, size: 18, color: t.colorOf('#dd3a30')), label: 'Leave the group', onPress: _leave),
      ]),
    ];
  }

  /// One of the group's rules as a switch; shown and not changeable where this person may not set it ([can] false).
  Widget _rule(String label, bool on, bool can, ValueChanged<bool> set) => SettingRow(
        label: label,
        control: GlacierSwitch(checked: on, disabled: !can, onCheckedChange: can ? set : null, ariaLabel: label),
      );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
