/// A circle, in the list's place with a way back at its top (AppShell.openCircle; the pattern the server preview had,
/// Matt, 2026-11-17: "it should takeover the normal sidebar when i enter a server with a back button at the top"):
/// its list of spaces (circle_list.dart), and a space opened in the pane, beside it in a wide window and over it on a
/// phone, as a conversation is.
library;

import 'dart:async';

import 'circle_settings.dart' show openCircleSettingsFull;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../circles/sms_space.dart' show smsTexterOf;
import '../../files/files_store.dart';
import '../../plugins/spotify.dart' show SpotifyPlugin;
import '../../voice/spotify.dart' show SpotifyMusic;
import '../../voice/channels.dart';
import '../../sms.dart' show Conversation, Person, Sms;
import '../../voice/hangout.dart' show HangoutMessage;
import '../../voice/voice.dart';
import '../../kit/settings_kit.dart' show SettingsCallout;
import '../common.dart';
import '../window_title.dart';
import '../conversations.dart' show ConversationRow;
import '../dialup/bevel.dart';
import '../dialup/parts.dart' show DialupFace;
import '../files_space/files_screen.dart';
import '../hangout_screen.dart';
import '../shell.dart';
import 'arrange_spaces.dart';
import 'circle_face.dart';
import 'circle_invite.dart';
import 'circle_list.dart';
import 'circle_view.dart';
import 'members_drawer.dart' show showCircleMembers;
import 'new_circle.dart';
import '../../l10n/words.dart';

export 'circle_invite.dart' show showCircleInvite;

/// The seed of the circle space open in the pane, while one is: the row the circle's list marks.
final openCircleSpaceSeed = ValueNotifier<String?>(null);

/// What a circle's space opens as: a voice space its chat with a way into its call, a texting space only its chat (no
/// Join: HangoutScreen leaves it out for a space with no voice), and a Files space its files page. The files page is
/// lib/ui/files_space/ (FilesSpaceScreen), its chat a press away at its top.
/// In a browser whose build has no Files spaces (Sms.filesHere), a Files space says so in its page's place
/// ([FilesNotHere]).
Widget circleSpacePage(VoiceChannel c, {Key? key}) => c.kind == SpaceKind.files ? (!Sms.filesHere ? FilesNotHere(key: key, channel: c) : FilesSpaceScreen(key: key, channel: c)) : HangoutScreen(key: key, channel: c);

/// A Files space, in a browser: where it can be opened, in its page's place.
class FilesNotHere extends StatelessWidget {
  const FilesNotHere({super.key, required this.channel});
  final VoiceChannel channel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: channel.name,
      body: Padding(
        padding: EdgeInsets.all(t.space(4)),
        child: Align(alignment: Alignment.topCenter, child: SettingsCallout(child: const Tr('Files spaces aren\'t in the browser yet. This one opens in Uplink on a phone or a computer.'))),
      ),
    );
  }
}

/// Opens [c], a space of a circle, in the pane: beside the circle's list in a wide window, over it on a phone.
void openCircleSpace(BuildContext context, VoiceChannel c) {
  final shell = AppShell.maybeOf(context);
  openCircleSpaceSeed.value = c.seed;
  Voice.instance.markRead(c);
  if (shell == null) {
    push<void>(context, (_) => circleSpacePage(c));
    return;
  }
  shell.show(circleSpacePage(c, key: ValueKey('circle-space-page-${c.seed}')), showing: 'circle');
}

/// A space pressed in the circle's list. Beside the pane (a computer, an unfolded Fold) a voice space's call is come
/// into at once and shown, where it took a second press on Join voice in its page (GMFB-72: "join a voice chat when
/// clicking on a space in the sidebar"). On a phone it opens as before: its page there is the chat, or who is talking
/// with Join under them, and a press on a row of a list is too easy to make by chance to start the microphone.
///
/// It comes in as Join voice does, leaving any other call first (Voice.join), and only where Join would: not into a
/// call this device is in or coming into already, a space its role may not talk in or it was put out of (the page
/// says so, and its chat is still to read), an SMS space (it is pressed to text) or an open space, whose floor is
/// walked onto with its own Join. The space's menu still has Open, which opens it without the call.
void pressCircleSpace(BuildContext context, CircleSpaceView s, {required bool wide}) {
  final c = s.channel;
  openCircleSpace(context, c);
  final voice = Voice.instance;
  if (!wide || AppShell.maybeOf(context) == null) return;
  if (c.kind != SpaceKind.voice || !Sms.callsHere || smsTexterOf(s.space) != null) return;
  if (voice.session?.channel.room == c.room || voice.joining?.room == c.room) return;
  if (!Circles.instance.allows(c, CirclePerm.voice) || voice.heldHangout(c)?.putOut != null) return;
  unawaited(() async {
    try {
      await joinPressedSpace(c);
    } catch (e) {
      // As Join voice says it (HangoutScreen).
      if (context.mounted) toast(context, 'Couldn\'t join: ${e is StateError ? e.message : e}', tone: GlacierToastTone.danger);
    }
  }());
}

/// How a pressed space's call is come into: Voice.join, or a test's own in its place.
@visibleForTesting
Future<void> Function(VoiceChannel c) joinPressedSpace = _joinPressed;
Future<void> _joinPressed(VoiceChannel c) => Voice.instance.join(c);

/// Puts [joinPressedSpace] back after a test.
@visibleForTesting
void resetJoinPressedSpace() => joinPressedSpace = _joinPressed;

/// Opens [c]'s settings over the whole window, with their own sidebar (lib/ui/circles/circle_settings.dart).
void openCircleSettings(BuildContext context, Circle c) => openCircleSettingsFull(context, c.seed);

/// Opens a new space for [c] (under [section], where asked for under one) in the pane, as its settings open.
void openCircleNewSpace(BuildContext context, Circle c, {String? section}) {
  final shell = AppShell.maybeOf(context);
  if (shell == null) {
    push<void>(context, (_) => NewCircleSpaceScreen(circle: c, section: section));
    return;
  }
  shell.show(NewCircleSpaceScreen(key: ValueKey('circle-new-${c.seed}-${section ?? ''}'), circle: c, section: section), showing: 'circle-new');
}

/// A circle's own page: its list of spaces, drawn again whenever the circle, a call, the space open or a Files
/// space's list changes; a line saying so where the circle was left meanwhile.
class CircleScreen extends StatelessWidget {
  const CircleScreen({super.key, required this.seed, this.onBack});

  /// The circle's seed: it is read from Circles each time it changes.
  final String seed;

  /// Back to the conversations; the list's own navigator's pop where not given.
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final circles = Circles.instance;
    final voice = Voice.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([circles, voice, openCircleSpaceSeed, FilesStore.instance, _musicShown]),
      builder: (context, _) {
        final c = circles.bySeed(seed);
        final back = onBack ?? () => Navigator.of(context).maybePop();
        if (c == null) {
          // Left meanwhile (here, or on the phone or computer).
          return GhostPage(title: 'Circle', onBack: back, body: const Center(child: Tr('You left this circle.')));
        }
        // The window is named for the circle while its list is open (lib/ui/window_title.dart).
        return WindowTitle(name: c.name, circle: true, child: CircleList(view: circleView(context, c, onBack: back)));
      },
    );
  }
}

/// What plays in the call this device is in, changing only as the song does: the music itself says where it is every
/// few seconds, and the list is not drawn again for that.
final _musicShown = _MusicShown();

class _MusicShown extends ChangeNotifier {
  _MusicShown() {
    SpotifyMusic.instance.addListener(_look);
  }
  ({String song, String? cover})? now;
  void _look() {
    final song = SpotifyMusic.instance.state?.now?.song;
    final next = song == null ? null : (song: song.shown, cover: song.coverUrl);
    if (next == now) return;
    now = next;
    notifyListeners();
  }
}

/// The music in [channel]'s call: as the call says it where this device is in it ([here]), else as its DJ greeted the
/// space. None where the circle has Spotify off.
({String song, String? cover})? _musicIn(VoiceChannel channel, {required bool here}) {
  if (Circles.instance.pluginOnIn(channel, SpotifyPlugin.pluginId) != true) return null;
  if (here) return _musicShown.now;
  final song = Voice.instance.heldHangout(channel)?.musicInCall;
  return song == null ? null : (song: song, cover: null);
}

/// [c] as its list draws it, as it stands now.
CircleView circleView(BuildContext context, Circle c, {required VoidCallback onBack}) {
  final circles = Circles.instance;
  final voice = Voice.instance;
  final wide = AppShell.wideOf(context);
  final showing = AppShell.maybeOf(context) == null || AppShell.showingOf(context) == 'circle';
  final spaces = [
    for (final s in c.spaces)
      () {
        final channel = c.channelOf(s);
        final here = voice.session?.channel.room == channel.room;
        final ids = !channel.hasVoice ? const <String>[] : (here ? ['me', ...voice.session!.members.keys] : voice.inChannel(channel));
        final last = voice.lastMessage(channel);
        final room = voice.hangoutFor(channel);
        final me = room?.me;
        String who(HangoutMessage m) => m.from == me ? 'You' : (m.name.isNotEmpty ? m.name : voice.nameOf(m.from));
        return CircleSpaceView(
          space: s,
          channel: channel,
          unread: voice.unreadIn(channel),
          mentions: voice.mentionsIn(channel),
          lastMessage: last == null ? null : '${who(last)}: ${last.summary}',
          lastAt: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last.at),
          inVoice: [for (final id in ids) id == 'me' ? 'You' : voice.nameOf(id)],
          people: [
            for (final id in ids)
              () {
                final shows = voice.pictureOf(channel, id);
                return CircleVoicePerson(id: id, name: id == 'me' ? 'You' : voice.nameOf(id), camera: shows.camera, screen: shows.screen);
              }(),
          ],
          here: here,
          // A stage with people in it: how many of them listen (GMFB-29). The space's roles say who, so it is known
          // from outside the call too.
          listening: room != null && room.stage && ids.isNotEmpty ? ids.where((id) => room.listens(id == 'me' ? room.me : id)).length : null,
          music: ids.isEmpty ? null : _musicIn(channel, here: here),
          files: s.kind == SpaceKind.files ? FilesStore.instance.heldCount(channel) : null,
        );
      }(),
  ];
  // As the circle's roles say (lib/circles: CirclePerm): its spaces, and inviting.
  final canEdit = circles.can(c, CirclePerm.spaces);
  return CircleView(
    circle: c,
    spaces: spaces,
    selected: wide && showing ? openCircleSpaceSeed.value : null,
    wide: wide,
    canEdit: canEdit,
    online: circles.onlineIn(c),
    onOpen: (s) => pressCircleSpace(context, s, wide: wide),
    onSpaceMenu: (s) => showCircleSpaceMenu(context, c, s),
    onNewSpace: ({String? section}) => canEdit ? openCircleNewSpace(context, c, section: section) : null,
    onSettings: () => openCircleSettings(context, c),
    onInvite: () => circles.can(c, CirclePerm.invite) ? showCircleInvite(context, c) : toast(context, 'Your role in ${c.name} can\'t invite people.'),
    onBack: onBack,
    onMenu: () => showCircleMenu(context, c),
  );
}

/// A circle's menu: mark as read, invite, new space, arranging, settings, leave.
void showCircleMenu(BuildContext context, Circle c) {
  final circles = Circles.instance;
  final canEdit = circles.can(c, CirclePerm.spaces);
  showChoices(context, title: c.name, choices: [
    // Its members here too, where the dock is the same on every page and has no Members of its own (NavStyle.unified).
    // Every space in it read at once, its unread mark gone from the list and the rail.
    Choice('Mark as read', Lucide.checkCheck, () => circles.markRead(c)),
    Choice('Members', Lucide.users, () => showCircleMembers(context, c)),
    if (circles.can(c, CirclePerm.invite)) Choice('Invite people', Lucide.userPlus, () => showCircleInvite(context, c)),
    if (canEdit) Choice('New space', Lucide.plus, () => openCircleNewSpace(context, c)),
    if (canEdit) Choice('Arrange spaces', Lucide.listTree, () => push<void>(context, (_) => ArrangeCircleSpacesScreen(seed: c.seed)), hint: 'Move, rename or delete them'),
    // Where a circle's settings are, the dock's cog being the app's (Matt, 2026-11-18: "to manage settings in a given
    // circle we shoould click the circle name and chevron in the top of the sidebar and replace "about this circle" with
    // "Circle Settings""). Someone who may change nothing still sees them, read only (circle_settings.dart).
    Choice('Circle settings', Lucide.settings, () => openCircleSettings(context, c)),
    Choice('Leave circle', Lucide.logOut, () => confirmLeaveCircle(context, c), danger: true),
  ]);
}

/// A space's menu in a circle: open, and for whoever may change the circle, rename, heading, kind, arrange and delete.
void showCircleSpaceMenu(BuildContext context, Circle c, CircleSpaceView s) {
  final circles = Circles.instance;
  final canEdit = circles.can(c, CirclePerm.spaces);
  showChoices(context, title: '${s.name} · ${spaceKindTitle(s.kind)}', choices: [
    Choice('Open', spaceKindIcon(s.kind), () => openCircleSpace(context, s.channel)),
    if (canEdit) ...[
      Choice('Rename', Lucide.pencil, () => askCircleWords(context, title: 'Rename ${s.name}', initial: s.name, then: (name) => circles.updateSpace(c, s.seed, name: name))),
      Choice('Heading', Lucide.listTree, () => askCircleWords(context, title: 'Heading for ${s.name}', initial: s.section ?? '', hint: 'Spaces with the same heading are listed together. Leave it empty for none.', then: (h) => circles.updateSpace(c, s.seed, section: h.isEmpty ? null : h, clearSection: h.isEmpty))),
      for (final k in spaceKindsOffered)
        if (k != s.kind) Choice('Make it ${spaceKindTitle(k).toLowerCase()}', spaceKindIcon(k), () => circles.updateSpace(c, s.seed, kind: k), hint: spaceKindBlurb(k)),
      Choice('Arrange spaces', Lucide.gripVertical, () => push<void>(context, (_) => ArrangeCircleSpacesScreen(seed: c.seed))),
      Choice('Delete space', Lucide.trash2, () => confirmRemoveCircleSpace(context, c, s.space), danger: true),
    ],
  ]);
}

/// Asks first, then leaves [c] on this device and its phone or computer.
void confirmLeaveCircle(BuildContext context, Circle c) {
  showChoices(context, title: 'Leave ${c.name}? It goes from your list; its link brings you back.', choices: [
    Choice('Leave circle', Lucide.logOut, () async {
      final shell = AppShell.maybeOf(context);
      await Circles.instance.leave(c);
      if (shell?.openCircleSeed == c.seed && context.mounted) Navigator.of(context).maybePop();
      if (context.mounted) toast(context, 'Left ${c.name}');
    }, danger: true),
  ]);
}

/// The Circles tab's row for [circle], drawn as a conversation's (ConversationRow), so it has the same card, the same
/// Dial-Up transcript line, its newest activity's time, an unread dot and who is talking: its face, its name, and
/// "3 spaces · Maya is talking" or its newest message.
class CircleRow extends StatelessWidget {
  const CircleRow({super.key, required this.circle, this.onPress, this.onLongPress, this.selected = false});
  final Circle circle;
  final VoidCallback? onPress;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final circles = Circles.instance;
    final voice = Voice.instance;
    final unread = circles.unread(circle);
    final inVoice = circles.inVoice(circle);
    final count = '${circle.spaces.length} ${circle.spaces.length == 1 ? 'space' : 'spaces'}';
    // The newest message in any of its spaces, and which space it was in.
    HangoutMessage? newest;
    VoiceChannel? where;
    for (final ch in circle.channels) {
      final m = voice.lastMessage(ch);
      if (m != null && (newest == null || m.at > newest.at)) (newest, where) = (m, ch);
    }
    String line;
    if (inVoice.isNotEmpty) {
      final names = inVoice.take(3).map(voice.nameOf).join(', ');
      line = '$count · ${inVoice.length == 1 ? talkingAlone(names) : '$names talking'}';
    } else if (newest != null) {
      final me = voice.hangoutFor(where!)?.me;
      final who = newest.from == me ? 'You' : (newest.name.isNotEmpty ? newest.name : voice.nameOf(newest.from));
      line = '${where.name} · $who: ${newest.summary}';
    } else {
      line = count;
    }
    final c = Conversation(
      id: -(circle.seed.hashCode & 0x3fffffff) - 1,
      date: newest == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(newest.at),
      people: [Person(address: 'circle:${circle.seed}', name: circle.name)],
      name: circle.name,
      snippet: line,
      unread: unread > 0,
      error: false,
      archived: false,
    );
    return ConversationRow(
      conversation: c,
      unreadCount: unread,
      mentioned: circles.mentions(circle) > 0,
      live: inVoice.isEmpty ? null : inVoice.length,
      timed: newest != null,
      selected: selected,
      face: (size) => CircleRowFace(circle: circle, size: size),
      onPress: onPress ?? () => AppShell.maybeOf(context)?.openCircle(circle),
      onLongPress: onLongPress ?? () => showCircleMenu(context, circle),
    );
  }
}

/// A circle's face in its row: round in its colour; in Dial-Up a small square frame as its people's faces have, its
/// icon (or picture) in the page's ink set into it.
class CircleRowFace extends StatelessWidget {
  const CircleRowFace({super.key, required this.circle, required this.size});
  final Circle circle;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (!isBevelChrome(t)) return CircleFace.of(circle, size: size);
    return DialupFace(size: size, child: circle.picture != null ? CircleFace.of(circle, size: size) : Center(child: AppIcon(circleIconOf(circle.icon), size: size * 0.66, color: t.color('app-ink'), wash: false)));
  }
}
