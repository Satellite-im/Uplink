export 'call_plugins.dart' show SpaceExtra;
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_type.dart';
import '../../sms.dart';
import '../../voice/call_sound.dart';
import '../../voice/call_wait.dart';
import '../../voice/channels.dart';
import '../../voice/hangout.dart';
import '../../voice/open_space.dart';
import '../../voice/recorder.dart';
import '../../voice/roles.dart';
import '../../voice/spotify.dart';
import '../../voice/voice.dart';
import '../call_float.dart' show CallPageMark, CallPictures, FloatWords, popOutCall;
import '../common.dart';
import '../connecting_banner.dart';
import '../flat_line.dart' show pictureOfSpace;
import '../hangout_screen.dart';
import '../recording_ui.dart';
import '../ripple_avatar.dart';
import '../settings.dart';
import '../shell.dart';
import '../screen_share.dart';
import '../space_invite.dart';
import '../spotify_panel.dart';
import '../tile_grid.dart';
import '../../voice/rtc.dart' show RtcMedia;
import '../voice_screen.dart';
import 'call_plugins.dart';
import 'telegram.dart';

/// A space's call: one page ([SpaceCallPage], drawn by lib/ui/space_designs/telegram.dart) from one account of the
/// call ([SpaceCall]): who is in it and how loud each is, their video, the chat, and the call's buttons. On a narrow
/// phone the page is the call ([inlineSpaceCall]); beside a list it is the top of the space's own page, its chat under
/// it (HangoutScreen's SpaceSplit); pushed over a page that has no shell under it ([openSpaceCall]), Minimise puts it
/// away to the call banner.
///
/// It was one of seven ways a space's call could look, chosen in Settings › Developer (Matt, 2026-11-16: "give me 6
/// alternate designs for the calling chat and video screens for spaces", and of this one "deploy this as the default
/// version"). The others are gone (Matt, 2026-11-24: "remove the other video call layouts from the codebase we only
/// use the default one now"): five modelled on other call apps, and the app's earlier layout for a space's call. What
/// that earlier layout drew is still what draws the calls that are not a space's (a group's, a friend's:
/// lib/ui/voice_screen.dart) and the buttons on an open space's floor.

/// Someone in the call as its page draws them.
@immutable
class SpacePerson {
  const SpacePerson({
    required this.id,
    required this.name,
    this.me = false,
    this.muted = false,
    this.mutedForAll = false,
    this.mutedForMe = false,
    this.guest = false,
    this.video = false,
    this.screen = false,
    this.stream,
    this.shape,
    this.back = false,
    this.role,
    this.owner = false,
    this.username,
    this.tag,
    this.cover,
    this.doing,
  });

  /// `me` for this device, else their id on the hub (the key [SpaceCall.levels] uses).
  final String id;
  final String name;
  final bool me;

  /// Not heard here, for any reason: they muted themselves, or one of the two below.
  final bool muted;

  /// Why, where it isn't their own doing (GMFB-49, Kevin: "muting should be split in communities"): a moderator muted
  /// them for everyone (they can't unmute themselves), or this device alone stopped hearing them (Mute for me). Each
  /// has its own mark on their tile ([SpaceWords.mutedIcon]).
  final bool mutedForAll, mutedForMe;
  final bool guest;

  /// Video turned on; [stream] is its picture once it arrives (null until then, and always in a test).
  final bool video;
  final MediaStream? stream;

  /// The picture's own shape, width over height, once a frame of it has come (GMFB-71; [VideoShapes]): a phone draws
  /// the tile that shape, so the whole picture shows. Null until then.
  final double? shape;

  /// What [stream] shows is their shared screen (GMFB-27): drawn whole, never cropped or mirrored.
  final bool screen;

  /// This device's camera is the one on its back (GMFB-57): its own picture is not mirrored then, as a front
  /// camera's is.
  final bool back;

  /// Their role in the space, where it has roles (null for a group's channel).
  final Role? role;
  final bool owner;
  final String? username;

  /// Where they are from when not from Uplink: 'Discord' for someone in the Discord voice channel a space is
  /// bridged to. Shown beside their name; they can't be acted on from here.
  final String? tag;

  /// Not a person but the music played to the call (lib/voice/spotify.dart), listed among them as the Discord bridge's
  /// people are: what it is doing ("Playing Cut To The Feeling"), and its song's cover where it has one.
  final String? cover, doing;
  bool get music => doing != null;

  /// What to call them on a tile: "You" for this device.
  String get shown => me ? 'You' : name;

  /// The role's name to show beside them, where it is worth showing (not the one everyone starts with).
  String? roleLabel(Roster? roster) {
    if (owner) return 'Owner';
    if (role == null || roster == null || role!.id == roster.newcomer) return null;
    return role!.name;
  }
}

/// Everything the page needs to draw a space's call, and do what its buttons say. Made from the call there is
/// ([SpaceCall.live]); a test makes one of its own ([SpaceCall.new]) with no WebRTC underneath.
class SpaceCall {
  SpaceCall({
    required this.channel,
    required this.people,
    required this.levels,
    required this.changes,
    this.room,
    this.muted = false,
    this.deafened = false,
    this.video = false,
    this.micLocked = false,
    this.micLockedWhy,
    this.micLockedByRole = false,
    this.videoLocked = false,
    this.screen = false,
    this.onScreen,
    this.onFlip,
    this.onCamera,
    this.since,
    this.wait,
    this.coming = 0,
    this.onMute,
    this.onDeafen,
    this.onVideo,
    this.onLeave,
    this.onMinimize,
    this.onPerson,
    this.onSettings,
    this.onInvite,
    this.onDevices,
    this.chatBuilder,
    this.bridged = false,
    this.extras = const [],
    this.chatBelow = false,
    this.chatShown = true,
    this.onChatBelow,
    this.listening,
    this.hands = 0,
  });

  /// A stage's items in the call's menu (GMFB-29, from the Uplink gap review: "A stage/stream mode: some people speak,
  /// many listen, with a listener count"): Raise hand for a listener, and, for whoever manages the space, making it a
  /// stage or ending one, with how many are listening.
  static List<SpaceExtra> stageExtras(VoiceSession s, HangoutRoom? room) {
    if (room == null || !s.channel.hasVoice) return const [];
    final (:listening, :hands) = stageCount(s, room);
    return [
      if (room.stage && s.locked)
        SpaceExtra(label: s.hand ? 'Lower your hand' : 'Raise your hand', icon: LucideMore.hand, builtIn: true, run: (_) => s.raiseHand(!s.hand)),
      if (room.canManage)
        SpaceExtra(
          label: room.stage ? 'End the stage · $listening listening${hands > 0 ? ' · $hands ✋' : ''}' : 'Make it a stage',
          icon: Lucide.megaphone,
          builtIn: true,
          run: (context) async {
            final ok = await room.setStage(!room.stage);
            if (context.mounted) {
              toast(context, !ok ? 'The stage couldn\'t be changed' : (room.stage ? 'It\'s a stage: newcomers listen until you bring them up to speak' : 'Everyone can speak again'));
            }
          },
        ),
    ];
  }

  /// How many in [s] listen on [room]'s stage, this device among them, and how many of them have a hand raised.
  static ({int listening, int hands}) stageCount(VoiceSession s, HangoutRoom room) => (
        listening: [if (room.listens(room.me)) room.me, for (final id in s.members.keys) if (room.listens(id)) id].length,
        hands: (s.hand ? 1 : 0) + s.members.values.where((m) => m.hand).length,
      );

  /// What a stage says of itself to everyone in it (GMFB-29: "some people speak, many listen, with a listener count"):
  /// "Stage · 12 listening", and to whoever manages it how many hands are raised. Until now only the manager was told
  /// the count, in a menu's row.
  static String stageLine(int listening, {int hands = 0}) =>
      'Stage · $listening listening${hands > 0 ? ' · $hands ${hands == 1 ? 'hand' : 'hands'} raised' : ''}';

  /// Whether this device may invite people into [channel]'s call: never a group's (its members' alone, and it has no
  /// [room]), and in a space with roles only where this device's role may invite.
  static bool mayInvite(VoiceChannel channel, HangoutRoom? room) => channel.group == null && (room == null || room.can(Perm.invite));

  /// The music played to the call, as one of those in it; null while nothing plays.
  static SpacePerson? musicPerson() {
    final m = SpotifyMusic.instance;
    final now = m.state?.now;
    if (now == null) return null;
    return SpacePerson(id: 'music', name: 'Spotify', tag: 'Music', cover: now.song.coverUrl, doing: m.state!.playing ? 'playing ${now.song.shown}' : 'paused');
  }

  /// The call [Voice] is in, as it stands now; null when there is none. [minimize] puts the page away.
  static SpaceCall? live({VoidCallback? minimize, bool chatBelow = false, bool chatShown = true, VoidCallback? onChatBelow}) {
    final v = Voice.instance;
    final s = v.session;
    if (s == null) return null;
    final media = v.media;
    final room = v.hangoutFor(s.channel);
    final roster = room?.roster;
    final meId = room?.me ?? v.me ?? 'me';
    Role? roleOf(String id) => roster?.roleOf(id);
    final people = <SpacePerson>[
      SpacePerson(
        id: 'me',
        name: s.name.isEmpty ? 'You' : s.name,
        me: true,
        muted: s.muted || s.deafened,
        mutedForAll: room?.mutedForAll(meId) ?? false,
        video: s.video || s.screen,
        screen: media?.localScreen.value != null,
        stream: media?.localScreen.value ?? media?.localVideo.value,
        shape: VideoShapes.of((media?.localScreen.value ?? media?.localVideo.value)?.id),
        back: s.backCamera,
        role: roleOf(meId),
        owner: roster?.isOwner(meId) ?? false,
      ),
      for (final m in s.members.values)
        // The bridge to Discord is a member, but not a person: the people it brings are below.
        if (m.id != s.bridgeId)
        SpacePerson(
          id: m.id,
          // A hand raised to speak on a stage, before the name, wherever the name is drawn (GMFB-29).
          name: m.hand ? '✋ ${v.nameOf(m.id)}' : v.nameOf(m.id),
          muted: m.muted || (room != null && !room.heard(m.id)) || v.silenced(m.id),
          mutedForAll: room?.mutedForAll(m.id) ?? false,
          mutedForMe: v.silenced(m.id),
          guest: m.guest,
          video: m.video,
          screen: m.screen,
          stream: m.video ? media?.remote.value[m.id] : null,
          shape: m.video ? VideoShapes.of(media?.remote.value[m.id]?.id) : null,
          role: roleOf(m.id),
          owner: roster?.isOwner(m.id) ?? false,
          username: m.username,
        ),
      // Everyone in the Discord voice channel the space is bridged to (VoiceSession.discordPeople).
      for (final d in s.discordPeople)
        if (!d.bot) SpacePerson(id: 'dc:${d.id}', name: d.name, muted: d.muted || d.deafened, tag: 'Discord'),
      ?musicPerson(),
    ];
    final stage = room != null && room.stage && s.channel.hasVoice ? stageCount(s, room) : null;
    return SpaceCall(
      channel: s.channel,
      people: people,
      levels: callLevels(s),
      // The ways through and the microphone too: what the call is waiting for follows them ([wait]).
      changes: Listenable.merge([v, s, ?room, ?media?.remote, ?media?.localVideo, ?media?.localScreen, ?media?.links, ?media?.micLive, CallRecorder.instance, SpotifyMusic.instance, VideoShapes.changes, CallPin.who]),
      bridged: s.channel.discord != null,
      chatBelow: chatBelow,
      chatShown: chatShown,
      onChatBelow: onChatBelow,
      listening: stage?.listening,
      // Hands are raised to whoever can bring people up to speak.
      hands: stage != null && room!.canManage ? stage.hands : 0,
      room: room,
      muted: s.muted,
      deafened: s.deafened,
      video: s.video,
      micLocked: s.locked,
      micLockedWhy: s.locked ? room?.micLockedWhy : null,
      micLockedByRole: s.locked && room != null && !room.mutedForAll(meId),
      videoLocked: s.videoLocked,
      screen: s.screen,
      onScreen: s.canShareScreen ? (context) => unawaited(toggleScreenShare(context, s)) : null,
      onFlip: s.canFlipCamera ? () => unawaited(s.flipCamera()) : null,
      onCamera: s.video && !s.screen && RtcMedia.choosesCamera ? (context) => unawaited(showCameraChoices(context)) : null,
      since: s.since,
      wait: CallWaitBuilder.now(v),
      coming: CallWaitBuilder.coming(v),
      onMute: () => s.setMuted(!s.muted),
      onDeafen: () => s.setDeafened(!s.deafened),
      onVideo: () => unawaited(s.setVideo(!s.video)),
      onLeave: () => unawaited(v.leave()),
      onMinimize: minimize,
      // Someone in Discord can't be muted or given a role from here: their press does nothing yet. The music's opens its
      // queue.
      onPerson: (context, p) {
        if (p.music) unawaited(push<void>(context, (_) => const SpotifyScreen()));
        if (p.tag == null) showPerson(context, s, p.id, p.name);
      },
      onSettings: room == null ? null : (context) => push(context, (_) => RolesScreen(room: room, settings: true)),
      onInvite: mayInvite(s.channel, room) ? (context) => showSpaceInvite(context, s.channel) : null,
      onDevices: (context) => push(context, (_) => const SettingsSectionScreen('voice')),
      chatBuilder: room == null ? null : ({double bottom = 0}) => HangoutChat(room: room, bottom: bottom),
      // Sharing the screen, first in the call's menu (GMFB-27), where this device can.
      extras: [
        if (s.canShareScreen) SpaceExtra(label: screenShareLabel(s), icon: LucideMore.screenShare, builtIn: true, run: (context) => unawaited(toggleScreenShare(context, s))),
        // Away from the call with its picture floating over the app (GMFB-64), where there is a picture to float.
        if (CallPictures.anyIn(s)) SpaceExtra(label: FloatWords.popOut, icon: LucideMore.pictureInPicture, builtIn: true, hint: 'Keep the picture over the app', run: popOutCall),
        ...stageExtras(s, room),
        ...CallPlugins.extras(),
        // In a browser, what its call leaves out, said where the call's choices are.
        if (Sms.browser)
          SpaceExtra(
            label: 'In a browser',
            icon: Lucide.info,
            builtIn: true,
            run: (context) => showChoices(context, title: 'In a browser', header: const Text(callsInBrowser), choices: [
              Choice('Voice and video settings', LucideMore.headphones, () => push(context, (_) => const SettingsSectionScreen('voice'))),
            ]),
          ),
      ],
    );
  }

  final VoiceChannel channel;

  /// This device first, then everyone else in the call.
  final List<SpacePerson> people;

  /// How loud each is now, 0 to 1, by [SpacePerson.id] (`me` for this device): the ripples, the green rings, the
  /// waves. Changes several times a second; listen to it where the picture should move.
  final ValueListenable<Map<String, double>> levels;

  /// Anything else in the call changing (who is in it, mute, video, the chat): build the page again from
  /// [SpaceCall.live] when it fires (SpaceCallPage does).
  final Listenable changes;

  /// The space's chat and roles; null for a group's channel.
  final HangoutRoom? room;

  final bool muted, deafened, video;

  /// This device is sharing its screen (GMFB-27); [onScreen] starts or stops it, null where this device can't.
  final bool screen;
  final void Function(BuildContext context)? onScreen;

  /// Changes between the front and the back camera (GMFB-57, Kevin: "Add a button to flip camera on mobile
  /// versions"). Null where there is nothing to flip, and no button is drawn then: a computer, video off, or
  /// the screen shared in the camera's place.
  final VoidCallback? onFlip;

  /// Opens the choice of cameras (GMFB-68, Matt: "There is no way to switch or select a video device in the app or
  /// actively during a call"). Null where there is none to make: a phone (which has [onFlip]), video off, or the
  /// screen shared in the camera's place.
  final void Function(BuildContext context)? onCamera;

  /// This device may not unmute (muted for everyone, or its role may not speak), or turn video on.
  final bool micLocked, videoLocked;

  /// Why the microphone is locked, in a sentence for the mute button to say when pressed (GMFB-49); and whether it is
  /// this device's role that may not speak (a stage's listener), not a moderator's mute.
  final String? micLockedWhy;
  final bool micLockedByRole;

  /// When this device came into the call.
  final DateTime? since;

  /// What the call is still waiting for (lib/voice/call_wait.dart): "Connecting…" and what exactly; null once it is
  /// through. The page says it where it would say who is here, and holds back that nobody else is ([onceThrough]),
  /// so its own words never contradict the line above its people (ConnectingBanner), which has an arc turning.
  final CallWait? wait;

  /// How many are in the call, as the relay server says, and not here yet while it is being come into
  /// (CallWaitBuilder.coming): the list of people draws them as bones.
  final int coming;

  final VoidCallback? onMute, onDeafen, onVideo, onLeave, onMinimize;
  final void Function(BuildContext context, SpacePerson person)? onPerson;
  final void Function(BuildContext context)? onSettings, onInvite, onDevices;
  final Widget Function({double bottom})? chatBuilder;

  /// The space is bridged to a Discord voice channel: its sound and chat go through the bridge, so it is not
  /// end-to-end encrypted. The page says so.
  final bool bridged;

  /// What the plugins that are on in this call offer in its menu (Slots.callControls): Record, for one.
  final List<SpaceExtra> extras;

  /// The space's chat is shown under the call by the page round it (SpaceSplit, a computer's pane): the call leaves
  /// out its own Chat button and its chat panel (Matt, 2026-11-23: "the chat and compose bar at the bottom").
  final bool chatBelow;

  /// Under the call ([chatBelow]): whether that chat is shown now, and what puts it away and brings it back (Matt,
  /// 2026-11-24: "add a button next to the leave button for hiding and showing the chat"). The call's own Chat button
  /// does that there, in place of opening a panel of its own. Null: nothing to put away, and no button.
  final bool chatShown;
  final VoidCallback? onChatBelow;

  /// While the space is a stage (GMFB-29): how many in the call listen, shown to everyone under the space's name
  /// ([stageLine]); null where it is not a stage. [hands]: how many hands are raised, known here only to whoever
  /// manages the stage (0 for everyone else).
  final int? listening;
  final int hands;

  /// Whether the call draws its Chat button: always on its own page, and under the split where the chat there can be
  /// put away.
  bool get hasChatButton => !chatBelow || onChatBelow != null;

  /// The level at which someone counts as talking (RippleAvatar.talking).
  static const talking = RippleAvatar.talking;

  SpacePerson get me => people.first;
  List<SpacePerson> get others => [for (final p in people.skip(1)) if (!p.music) p];
  List<SpacePerson> get withVideo => [for (final p in people) if (p.video) p];

  /// How many people are in it: the music is not one.
  int get count => people.where((p) => !p.music).length;

  /// Who is loudest now, if anyone is talking (not muted): the "active speaker".
  SpacePerson? loudest(Map<String, double> now) {
    SpacePerson? best;
    var most = talking;
    for (final p in people) {
      final l = now[p.id] ?? 0;
      // The music is loud all the time and is nobody speaking.
      if (!p.music && !p.muted && l > most) {
        best = p;
        most = l;
      }
    }
    return best;
  }

  /// Whether [p] counts as talking at the levels [now]: not muted and louder than [talking].
  bool isTalking(SpacePerson p, Map<String, double> now) => !p.muted && (now[p.id] ?? 0) > talking;

  /// The chat, with [bottom] left clear under its composer; a line saying there is none for a group's channel.
  Widget chat({double bottom = 0}) => chatBuilder?.call(bottom: bottom) ?? const _NoChat();

  /// How long this device has been in the call, as a clock: 4:05, 1:02:09.
  String clock(DateTime now) {
    final d = now.difference(since ?? now);
    final m = d.inMinutes, s = d.inSeconds % 60;
    return m >= 60 ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// [child], which says that nobody else is in the call ("Waiting for others to join"), only once the call is through:
/// while it is still connecting ([SpaceCall.wait]) nobody knows who is in it, and the line over the page is the one
/// thing said. Its room is kept, so nothing moves when it comes.
Widget onceThrough(SpaceCall call, Widget child) => Visibility(visible: call.wait == null, maintainSize: true, maintainAnimation: true, maintainState: true, child: child);

/// What stands where the chat would in a group's channel, which has no chat of its own.
class _NoChat extends StatelessWidget {
  const _NoChat();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(child: Text('A group\'s chat is its conversation', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))));
  }
}

/// A face that ripples while they talk, from [SpaceCall.levels]: the app's RippleAvatar, kept moving on its own.
class SpaceFace extends StatelessWidget {
  const SpaceFace({super.key, required this.call, required this.person, this.size = 44, this.ringed = false});
  final SpaceCall call;
  final SpacePerson person;
  final double size;
  final bool ringed;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<String, double>>(
        valueListenable: call.levels,
        // With how this device's connection to them stands, where it isn't simply through (GMFB-4).
        builder: (context, now, _) => person.music
            ? RippleAvatar(name: person.name, level: now[person.id] ?? 0, size: size, ringed: ringed, child: SongCover(url: person.cover, size: size))
            : LinkBadge(
          id: person.id,
          size: size,
          child: _face(context, now),
        ),
      );

  /// Their picture where the space's own room knows it, as the sidebar shows it, and their initial where it does not.
  Widget _face(BuildContext context, Map<String, double> now) {
    Widget face(Widget? picture) => RippleAvatar(name: person.me ? (person.name.isEmpty ? 'You' : person.name) : person.name, level: person.muted ? 0 : (now[person.id] ?? 0), muted: person.muted, size: size, ringed: ringed, child: picture);
    final room = call.room;
    if (room == null) return face(null);
    return SpacePicture(room: room, id: person.me ? room.me : person.id, builder: (context, picture) => face(pictureOfSpace(context, picture, size)));
  }
}

/// Someone's picture where their video is on and has arrived; else [fallback] (or their face on a dark ground), so a
/// tile is never empty.
class SpaceVideo extends StatelessWidget {
  const SpaceVideo({super.key, required this.call, required this.person, this.fallback, this.faceSize = 64, this.whole = false});

  /// The camera's picture drawn whole, as a shared screen's always is, where the tile has its shape (GMFB-71).
  final bool whole;
  final SpaceCall call;
  final SpacePerson person;
  final Widget? fallback;
  final double faceSize;

  @override
  Widget build(BuildContext context) {
    final stream = person.stream;
    // One renderer per stream (GMFB-5; voice_screen.dart's _Tile says why).
    if (stream != null) {
      final view = StreamView(key: ObjectKey(stream), stream: stream, mirror: person.me && !person.screen && !person.back, contain: person.screen || whole);
      return person.screen ? ColoredBox(color: const Color(0xFF000000), child: view) : view;
    }
    return fallback ?? ColoredBox(color: const Color(0xFF1C1C1F), child: Center(child: SpaceFace(call: call, person: person, size: faceSize)));
  }
}

/// The words the call's buttons say, wherever they are drawn: so "Mute" is "Mute" everywhere.
abstract final class SpaceWords {
  static String mute(SpaceCall c) => c.muted ? 'Unmute' : 'Mute';
  static String video(SpaceCall c) => c.video ? 'Stop video' : 'Video';
  static String deafen(SpaceCall c) => c.deafened ? 'Undeafen' : 'Deafen';
  static const leave = 'Leave', chat = 'Chat', invite = 'Invite', settings = 'Settings', devices = 'Devices', flip = 'Flip camera';

  /// The mark on someone who isn't heard, and its words (GMFB-49), so anyone can tell which mute it is: a lock where a
  /// moderator muted them for everyone, a crossed speaker where only this device stopped hearing them, the crossed
  /// microphone where they muted themselves.
  static LucideIcon mutedIcon(SpacePerson p) => p.mutedForAll ? Lucide.lock : (p.mutedForMe ? LucideMore.volumeX : LucideMore.micOff);
  static String mutedWords(SpacePerson p) => p.mutedForAll ? 'muted for everyone' : (p.mutedForMe ? 'muted for you' : 'muted');
  static LucideIcon videoIcon(SpaceCall c) => c.video ? Lucide.video : LucideMore.videoOff;
  static const LucideIcon flipIcon = Lucide.refreshCw;
  static LucideIcon deafenIcon(SpaceCall c) => c.deafened ? LucideMore.headphoneOff : LucideMore.headphones;
}

/// A space's call as a page: built again from the call as it changes, and closed when the call ends.
class SpaceCallPage extends StatefulWidget {
  const SpaceCallPage({super.key, this.inline = false, this.chatBelow = false, this.chatShown = true, this.onChatBelow});

  /// With [chatBelow]: whether the chat under the call is shown, and what shows and hides it ([SpaceCall.onChatBelow]).
  final bool chatShown;
  final VoidCallback? onChatBelow;

  /// Drawn as the top of a computer's pane with the space's chat under it (SpaceSplit): no Chat button or chat panel
  /// of its own, and nothing to put away to (the pane is the space's own page). Always [inline] too.
  final bool chatBelow;

  /// Drawn as the call page itself (a narrow phone's), not pushed over everything: when the call ends the page under
  /// it shows what is there then, and nothing is popped.
  final bool inline;

  @override
  State<SpaceCallPage> createState() => _SpaceCallPageState();
}

class _SpaceCallPageState extends State<SpaceCallPage> {
  VoiceChannel? _held;

  /// Whose shared screen was put away with Back to call (GMFB-27): theirs stays a line over the call, with View,
  /// until they share again or someone else does.
  String? _putAway;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final s = Voice.instance.session;
    if (s != null && s.channel.hangout) {
      _held = s.channel;
      unawaited(Voice.instance.hold(s.channel));
    }
    // The clock in a call's header, a second at a time.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    Voice.instance.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (Voice.instance.session == null) {
      if (!widget.inline && !widget.chatBelow) _close();
      return;
    }
    setState(() {});
  }

  /// Closes the page this call is drawn on, once: only while its own route is the one on top. Voice tells its
  /// listeners again and again as a call ends (the room let go, the relay saying who is left), and those came while
  /// this page was still sliding away; a Navigator's maybePop then reached the page under it, the shell, whose own
  /// back put away the circle's space and then the circle itself (Matt, 2026-11-17: "leaving a space call takes us
  /// out of the circle completely it should take us back to the circle not the whole main screen").
  void _close() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    Voice.instance.removeListener(_changed);
    final held = _held;
    if (held != null) unawaited(Voice.instance.release(held));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallPageMark(child: _build(context));

  /// The page, which is the call's: nothing floats over it while it is on the screen (GMFB-64).
  Widget _build(BuildContext context) {
    final minimize = widget.chatBelow ? null : _close;
    final call = SpaceCall.live(minimize: minimize, chatBelow: widget.chatBelow, chatShown: widget.chatShown, onChatBelow: widget.onChatBelow);
    if (call == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: call.changes,
      builder: (context, _) {
        final now = SpaceCall.live(minimize: minimize, chatBelow: widget.chatBelow, chatShown: widget.chatShown, onChatBelow: widget.onChatBelow) ?? call;
        final page = KeyedSubtree(key: const ValueKey('space-call'), child: TelegramCall(call: now));
        // What the plugins put over the call (Slots.callBanner): a line everyone must see.
        final session = Voice.instance.session;
        // Someone else's shared screen, large over the call until put away (GMFB-27); or whoever this device pinned
        // (CallPin), until unpinned.
        if (_putAway != null && (session == null || sharerIn(session) == null)) _putAway = null;
        final large = session == null ? null : stagedIn(session, putAway: _putAway);
        // Whether the screen someone shares is the one shown: else its line, with View, stays over the call.
        final staged = large != null && !large.pinned;
        // A recording is told to everyone, whatever plugins are on (lib/ui/recording_ui.dart).
        final banners = [
          if (session != null && RecordingBanner.shows(session)) const RecordingBanner(),
          if (session != null && ScreenShareBanner.shows(session, viewing: staged)) ScreenShareBanner(
              session: session,
              onView: () {
                CallPin.clear();
                setState(() => _putAway = null);
              },
            ),
          ...CallPlugins.banners(context),
        ];
        final stage = large == null || session == null
            ? null
            : Positioned.fill(
                child: ScreenStage(
                  name: large.name,
                  stream: large.stream,
                  screen: large.screen,
                  mirror: large.mirror,
                  pinned: large.pinned,
                  who: large.id == 'me' ? null : large.id,
                  onPin: () => CallPin.toggle(session, large.id),
                  onBack: () => leaveStage(session, large.id, pinned: large.pinned, putAway: (id) => setState(() => _putAway = id)),
                ),
              );
        if (banners.isEmpty && stage == null) return page;
        // Clipped to its own box in a pane, so the banners dragged about stay over the call, not over the chat below.
        final stack = Stack(children: [page, ?stage, if (banners.isNotEmpty) CallBanners(top: MediaQuery.paddingOf(context).top + 62, children: banners)]);
        return widget.chatBelow ? ClipRect(child: stack) : stack;
      },
    );
  }
}

/// Opens the space call's page over everything. False where there is nothing to open: not in a space's call, in an
/// open space's (its floor is its page: OpenSpaces.isCall), or where the app's shell draws the call itself.
bool openSpaceCall(BuildContext context) {
  final s = Voice.instance.session;
  if (s == null || !s.channel.hangout || OpenSpaces.isCall(s)) return false;
  // On a narrow phone the call's page is the page itself (inlineSpaceCall), so there is nothing to push over it; in a
  // wide window it is the top of the space's own page in the pane, its chat under it, the list beside it left as it
  // is (SpaceSplit; Matt, 2026-11-23: "leaving the sidebar unchanged so you can still quickly navigate the circle").
  if (AppShell.maybeOf(context) != null) return false;
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    settings: const RouteSettings(name: 'space-call'),
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, _, _) => const SpaceCallPage(),
    transitionsBuilder: (context, a, _, child) => FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
  ));
  return true;
}

/// A space's call drawn as the call page itself, where the window is narrow (a phone, a folded Fold): wherever the
/// call page is reached from (joining, the call banner, the Spaces tab) it is this (Matt, 2026-11-16: "I don't see the
/// new telegram like UI as the default in ghost calls ... i only see it when I open the phone to fullscreen not when
/// it's closed and skinny"). Null where something else draws the call: a call that is not a space's, an open space's
/// floor, and beside a list, where the space's own page holds it over its chat.
Widget? inlineSpaceCall(BuildContext context, VoiceSession? s) {
  if (s == null || !s.channel.hangout || OpenSpaces.isCall(s) || AppShell.wideOf(context)) return null;
  return SpaceCallPage(key: ValueKey('inline-call-${s.channel.room}'), inline: true);
}

/// How loud everyone in [s] is: the people in it, those in the Discord channel it is bridged to, and the music played to it.
ValueListenable<Map<String, double>> callLevels(VoiceSession s) {
  ValueListenable<Map<String, double>> all = Voice.instance.media?.levels ?? s.media.levels;
  if (s.discordPeople.isNotEmpty) all = MergedLevels(all, s.discordLevels);
  if (SpotifyMusic.instance.state?.now != null) all = MergedLevels(all, SpotifyMusic.instance.levels);
  return all;
}

/// Two sets of levels read as one: the call's own and the Discord people's (keys don't overlap).
class MergedLevels implements ValueListenable<Map<String, double>> {
  MergedLevels(this.a, this.b);
  final ValueListenable<Map<String, double>> a, b;

  @override
  bool operator ==(Object other) => other is MergedLevels && other.a == a && other.b == b;
  @override
  int get hashCode => Object.hash(a, b);

  @override
  Map<String, double> get value => {...a.value, ...b.value};

  @override
  void addListener(VoidCallback listener) {
    a.addListener(listener);
    b.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    a.removeListener(listener);
    b.removeListener(listener);
  }
}


/// The lines over a call (the recording's, the plugins'), where they can be moved and folded (GMFB-16, @kevin, Android
/// 0.11.5: "Audio recording banner covers ui elements in a way that makes them unusable and cannot be moved"): they
/// stood over the call's header, its menu and the first people with no way out of the way. Drag them up or down the
/// screen; the grip folds them to a small red chip at the side, which unfolds them again. Where they were left is
/// kept while the app runs.
class CallBanners extends StatefulWidget {
  const CallBanners({super.key, required this.top, required this.children});

  /// Where they start, from the top of the screen.
  final double top;
  final List<Widget> children;

  /// Where they were moved to, and whether they are folded: for every call page while the app runs.
  @visibleForTesting
  static double? moved;
  @visibleForTesting
  static bool folded = false;

  @override
  State<CallBanners> createState() => _CallBannersState();
}

class _CallBannersState extends State<CallBanners> {
  /// Whether any of the lines draws anything. A plugin's line is listed while the plugin is on (the soundboard's, the
  /// voice changer's) and is empty until it has something to say, as the recording's is once it has stopped: with
  /// nothing drawn, neither the grip nor the folded chip shows (Matt, 2026-11-22: "the recording pill gets stuck on
  /// the screen even when not recording").
  bool _drawn = false;

  /// The lines' height after a layout. [_drawn] follows it a frame later: this is called during layout, where
  /// setState may not be.
  void _measured(double height) {
    final drawn = height > 0.5;
    if (drawn == _drawn) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _drawn != drawn) setState(() => _drawn = drawn);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final lines = _HeightOf(onHeight: _measured, child: Column(mainAxisSize: MainAxisSize.min, children: widget.children));
    return LayoutBuilder(builder: (context, box) {
      final pad = MediaQuery.paddingOf(context);
      final most = (box.maxHeight - pad.bottom - 72).clamp(pad.top, double.infinity);
      final top = (CallBanners.moved ?? widget.top).clamp(pad.top, most);
      void drag(DragUpdateDetails d) => setState(() => CallBanners.moved = (top + d.delta.dy).clamp(pad.top, most));
      if (!_drawn) return Offstage(child: lines);
      if (CallBanners.folded) {
        return Stack(children: [
          // Still laid out, unseen, so that the chip goes when the lines have nothing more to say. Positioned, as an
          // unpositioned child would size the stack to it (nothing) and leave the chip outside where it can be pressed.
          PositionedDirectional(start: 0, end: 0, top: top, child: Offstage(child: lines)),
          PositionedDirectional(
            end: t.space(3),
            top: top,
            child: GestureDetector(
              key: const ValueKey('call-banners-folded'),
              onVerticalDragUpdate: drag,
              child: GlacierPressable(
                onPressed: () => setState(() => CallBanners.folded = false),
                semanticLabel: 'Show the lines over this call',
                builder: (context, state) => Container(
                  padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                  decoration: BoxDecoration(color: RecordingBanner.red.withValues(alpha: state.pressed ? 0.8 : 1), borderRadius: BorderRadius.circular(999), boxShadow: t.shadowOf('0 4px 14px rgba(0,0,0,0.25)')),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const AppIcon(Lucide.circleDot, size: 14, strokeWidth: 2.4, color: Color(0xFFFFFFFF)),
                    SizedBox(width: t.space(1)),
                    const AppIcon(Lucide.chevronDown, size: 14, strokeWidth: 2.4, color: Color(0xFFFFFFFF)),
                  ]),
                ),
              ),
            ),
          ),
        ]);
      }
      return Stack(children: [
        PositionedDirectional(
          start: 0,
          end: 0,
          top: top,
          child: GestureDetector(
            key: const ValueKey('call-banners'),
            behavior: HitTestBehavior.deferToChild,
            onVerticalDragUpdate: drag,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              lines,
              // The grip: drag it (or any of the lines) to move them, press it to fold them away.
              GlacierPressable(
                onPressed: () => setState(() => CallBanners.folded = true),
                semanticLabel: 'Fold the lines over this call',
                builder: (context, state) => Container(
                  key: const ValueKey('call-banners-grip'),
                  padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(1)),
                  child: Container(width: 36, height: 5, decoration: BoxDecoration(color: RecordingBanner.red.withValues(alpha: state.pressed ? 1 : 0.7), borderRadius: BorderRadius.circular(3))),
                ),
              ),
            ]),
          ),
        ),
      ]);
    });
  }
}

/// Tells [onHeight] the height its child was laid out to, after each layout.
class _HeightOf extends SingleChildRenderObjectWidget {
  const _HeightOf({required this.onHeight, required super.child});
  final void Function(double height) onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeightOf(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightOf renderObject) => renderObject.onHeight = onHeight;
}

/// [_HeightOf]'s render object: lays its child out as it would be, then reports the height.
class _RenderHeightOf extends RenderProxyBox {
  _RenderHeightOf(this.onHeight);
  void Function(double height) onHeight;

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}
