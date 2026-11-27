import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../friends/buddies.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../voice/call_sound.dart';
import '../voice/channels.dart';
import '../voice/leveler.dart';
import '../voice/open_space.dart' show OpenSpaces;
import '../voice/voice.dart';
import '../sms.dart';
import 'common.dart';
import 'call_float.dart';
import 'call_mini.dart' show MiniWords, toggleCallMini;
import '../desktop/mini_window.dart' show CallMini;
import 'connecting_banner.dart';
import 'skeleton.dart';
import '../voice/rtc.dart';
import 'shell.dart';
import 'nav_bar.dart';
import 'ripple_avatar.dart';
import 'circles/new_circle.dart' show SpaceKindCards;
import 'hangout_screen.dart';
import 'space_groups_ui.dart';
import 'space_designs/space_design.dart';
import 'space_invite.dart';
import 'screen_share.dart';
import 'tile_grid.dart';
import '../kit/semantic_colors.dart';
import '../backgrounds.dart' show strongFill;
import '../l10n/words.dart';

/// Voice channels (Matt, 2026-11-14: "always open voice channels that you can jump in and out at any time and you can
/// see who's connected and also toggle video on and off"): each channel with who is in it, a press to hop in, and,
/// while in one, everyone in it (their picture where their video is on) and the buttons for the microphone, the
/// sound, the camera and leaving.
class VoiceScreen extends StatelessWidget {
  const VoiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final v = Voice.instance;
    return ListenableBuilder(
      listenable: v,
      builder: (context, _) {
        final s = v.session;
        // In a call this page is the call's: nothing floats over it while it is on the screen (GMFB-64).
        return CallPageMark(on: s != null, child: _page(context, v, s));
      },
    );
  }

  Widget _page(BuildContext context, Voice v, VoiceSession? s) {
    final t = context.tokens;
    // In a call, the page is the call and nothing else: who is in it, and its buttons in the dock (Matt,
    // 2026-11-15: "I want the call screen to be super simple too just a list of chatters and the call controls").
    // A hangout's call is its page: the people or the chat, its roles (lib/ui/hangout_screen.dart).
    // On a narrow phone a space's call is its own page (space_design.dart).
    final design = inlineSpaceCall(context, s);
    if (design != null) return design;
    // A space's call beside the list is the space's own page: the call over its chat (HangoutScreen's SpaceSplit). An
    // open space's floor is still drawn over its chat here (HangoutStage).
    if (s != null && s.channel.hangout && AppShell.wideOf(context) && OpenSpaces.isCall(s)) return HangoutStage(key: ValueKey('stage-${s.channel.room}'), channel: s.channel);
    if (s != null && s.channel.hangout) return HangoutScreen(key: ValueKey('hangout-${s.channel.room}'), channel: s.channel);
    // A hangout pressed in the list: its chat where a conversation would be, who is in it and Join at its top.
    final seen = v.viewing;
    if (s == null && seen != null && v.channels.any((c) => c.seed == seen.seed)) return HangoutScreen(key: ValueKey('hangout-${seen.room}'), channel: seen);
    if (s != null) {
      return GhostPage(
        title: s.channel.name,
        actions: [
          // A hangout's, not a group's: a group's channel is its members' alone.
          if (s.channel.group == null) IconTap(icon: Lucide.userPlus, label: 'Invite people', onPressed: () => showSpaceInvite(context, s.channel)),
        ],
        // A screen someone shares, or whoever was pinned, large over the call, as in a space's call (GMFB-27): here it
        // was only ever a tile among the others.
        body: StagedCall(
          session: s,
          child: Stack(children: [
            ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), 120 + MediaQuery.paddingOf(context).bottom),
              children: [CallPanel(session: s)],
            ),
            PositionedDirectional(start: 0, end: 0, bottom: MediaQuery.paddingOf(context).bottom + NavPill.inset(t), child: Center(child: CallDock(session: s))),
          ]),
        ),
      );
    }
    return GhostPage(
      title: 'Spaces',
      actions: [IconTap(icon: Lucide.plus, label: 'New space', onPressed: () => push(context, (_) => const NewChannelScreen()))],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          if (v.channels.isEmpty)
            SettingsCallout(child: const Tr('Every group of friends has a space. Make one of your own with + and share it with friends you added by username.'))
          else
            // A circle's spaces are listed in their circle, not here.
            PaneSection(title: 'Spaces', children: [for (final c in v.channels) if (c.circle == null) _ChannelRow(channel: c)]),
        ],
      ),
    );
  }
}

/// A space in the list: its name, who is in it now, and Join (with how many) or Connected. A group's channel has no
/// options button; any other has one.
class _ChannelRow extends StatelessWidget implements PaneRow {
  const _ChannelRow({required this.channel});
  final VoiceChannel channel;

  @override
  Widget build(BuildContext context) {
    final v = Voice.instance;
    final here = v.session?.channel.room == channel.room;
    // In it: who the call has; otherwise who the hub says is there.
    final inIt = here ? v.session!.members.keys.toList() : v.inChannel(channel);
    final who = inIt.isEmpty ? (here ? 'Just you' : 'Nobody here') : inIt.map(v.nameOf).join(', ');
    return SettingRow(
      icon: AppIcon(channel.group != null ? Lucide.users : LucideMore.headphones, size: 18),
      label: channel.name,
      hint: Text(here ? 'You and ${inIt.isEmpty ? 'nobody else yet' : who}' : who, maxLines: 1, overflow: TextOverflow.ellipsis),
      value: Text(here ? 'Connected' : (inIt.isEmpty ? 'Join' : 'Join · ${inIt.length}')),
      // A hangout opens its page (its chat, and a way into voice); a group's channel is joined at once.
      onPress: here
          ? null
          : channel.hangout
              ? () => push(context, (_) => HangoutScreen(channel: channel))
              : () async {
                  try {
                    await v.join(channel);
                  } catch (e) {
                    if (context.mounted) toast(context, 'Couldn\'t join: $e', tone: GlacierToastTone.danger);
                  }
                },
      control: channel.group != null
          ? null
          : IconTap(
              icon: Lucide.ellipsis,
              label: 'Space options',
              onPressed: () => showHangoutMenu(context, channel),
            ),
    );
  }
}

/// Puts [c]'s link on the clipboard: anyone with it can join from a browser (site/join).
void copyInvite(BuildContext context, VoiceChannel c) {
  Clipboard.setData(ClipboardData(text: c.link));
  toast(context, 'Invite link copied. Anyone with it can join ${c.name} from a browser.');
}

/// The channel you're in (Matt, 2026-11-15: "make the voice chats a list of participants don't show the squares
/// unless someone turns on video"): a picture for each who has video on, then everyone as a list, each face rippling
/// while they talk.
class CallPanel extends StatelessWidget {
  const CallPanel({super.key, required this.session, this.videos = true});
  final VoiceSession session;

  /// With the pictures of whoever has video on above the people; off where they are shown elsewhere (CallVideos,
  /// the pane beside a hangout's people on a wide screen).
  final bool videos;

  /// The size of each video's tile where [count] have video on, in [width]: one alone across it all, more two to four
  /// across as the width allows, each 4:3. On a computer's wide pane (GMFB-58, @kevin, Windows 0.12.17: "The video call
  /// window is far too vertically slim for regular use") never more across than there are videos (two stood three
  /// across, small, beside a gap), and one alone no taller than 70% of the window ([screenHeight]) so it is all in
  /// view. A phone's come out as before.
  @visibleForTesting
  static Size videoTile({required double width, required int count, required double gap, required double screenHeight}) {
    final across = count == 1 ? 1 : math.min(count, (width / 240).floor().clamp(2, 4));
    final w = (width - gap * (across - 1)) / across;
    // Held to 70% of the window, it keeps 4:3 by narrowing (Matt, 2026-11-23: "make them like 4:3"), centred.
    final h = math.min(w / tileAspect, screenHeight * 0.7);
    return Size(h < w / tileAspect ? h * tileAspect : w, h);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    final media = v.media;
    final levels = media?.levels ?? session.media.levels;
    // The levels are listened to by each face alone (GMFB-6): the whole panel, video tiles and all, rebuilt at every
    // reading while anyone spoke.
    return ListenableBuilder(
      listenable: Listenable.merge([session, ?media?.remote, ?media?.localVideo, ?media?.localScreen, ?v.hangoutFor(session.channel), VideoShapes.changes]),
      builder: (context, _) {
        // A shared screen in the camera's place (GMFB-27), this device's own included.
        // A hangout's: each person's role beside their name, where it is not the one everyone starts with.
        final room = v.hangoutFor(session.channel);
        // Which mute it is (GMFB-49, Kevin: "muting should be split in communities"): `all` a moderator's, for
        // everyone, read from the roster and the room and not from what their app says of itself; `mine` this
        // device's own of them (Mute for me). Either way they are not heard here, so they are drawn muted.
        final people = <({String id, String name, bool guest, bool muted, bool all, bool mine, MediaStream? video, bool me, bool screen})>[
          (id: 'me', name: 'You', guest: false, muted: session.muted || session.deafened, all: room?.mutedForAll(room.me) ?? false, mine: false, video: media?.localScreen.value ?? media?.localVideo.value, me: true, screen: media?.localScreen.value != null),
          for (final m in session.members.values)
            (id: m.id, name: v.nameOf(m.id), guest: m.guest, muted: m.muted || v.silenced(m.id) || (room != null && !room.heard(m.id)), all: room?.mutedForAll(m.id) ?? false, mine: v.silenced(m.id), video: m.video ? media?.remote.value[m.id] : null, me: false, screen: m.screen),
        ];
        final withVideo = [for (final p in people) if (p.video != null) p];
        // Coming into the call: those the relay server says are in it, as bones under one's own row until each is
        // really there (CallWaitBuilder.coming).
        final coming = identical(v.session, session) ? CallWaitBuilder.coming(v) : 0;
        final face = Sms.computer ? 52.0 : 40.0;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // What the call is still waiting for (lib/ui/connecting_banner.dart); nothing once it is through.
          ConnectingBanner(wide: true, padding: EdgeInsets.fromLTRB(t.space(3), 0, t.space(1), t.space(2))),
          if (videos && withVideo.isNotEmpty) ...[
            LayoutBuilder(builder: (context, box) {
              final size = videoTile(width: box.maxWidth, count: withVideo.length, gap: t.space(2), screenHeight: MediaQuery.sizeOf(context).height);
              final w = size.width;
              // On a phone a camera's tile is the shape of its picture, so all of it shows (GMFB-71): as wide as its
              // place where that is no taller than 60% of the screen, else that tall and narrower.
              Size fit(MediaStream? stream, bool screen) {
                final shape = Sms.computer || screen ? null : VideoShapes.of(stream?.id);
                return shape == null ? Size(w, size.height) : wholeTile(width: w, shape: shape, most: MediaQuery.sizeOf(context).height * 0.6);
              }

              return Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: t.space(2), runSpacing: t.space(2), children: [
                for (final p in withVideo) SizedBox(key: ValueKey('video-${p.id}'), width: fit(p.video, p.screen).width, height: fit(p.video, p.screen).height, child: _Tile(onPressed: () => showPerson(context, session, p.id, p.name), whole: !Sms.computer, name: p.guest ? '${p.name} (guest)' : p.name, muted: p.muted, mark: mutedMark(all: p.all, mine: p.mine), stream: p.video, mirror: p.me && !p.screen && !session.backCamera, screen: p.screen, tools: p.me && !p.screen ? sessionVideoTools(context, session) : const [])),
              ]);
            }),
            SizedBox(height: t.space(3)),
          ],
          // The people as plain rows, not in a card (Matt, 2026-11-15: "Make the lists of people not in a card"), with
          // room above and below for the first and last face's rings.
          Padding(
              padding: EdgeInsets.symmetric(vertical: t.space(2)),
              child: Column(children: [
                for (final p in people)
                  // Press and hold (or press with the other button) for what can be done about them here.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => showPerson(context, session, p.id, p.name),
                    onSecondaryTap: () => showPerson(context, session, p.id, p.name),
                    child: Padding(
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(2), t.space(2)),
                    child: Row(children: [
                      // A little larger on a computer (Matt, 2026-11-15: "make the voice chat avatars a little larger on desktop").
                      LinkBadge(
                        id: p.id,
                        size: Sms.computer ? 52 : 40,
                        child: ValueListenableBuilder<Map<String, double>>(
                          valueListenable: levels,
                          builder: (context, loud, _) => RippleAvatar(name: p.me ? (session.name.isEmpty ? 'You' : session.name) : p.name, level: loud[p.id] ?? 0, muted: p.muted, size: Sms.computer ? 52 : 40),
                        ),
                      ),
                      SizedBox(width: t.space(3)),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: p.name,
                              // Their role's colour, as Discord draws names (Matt, 2026-11-17).
                              style: room == null ? null : TextStyle(color: roleInk(t, room.roster.roleOf(p.me ? room.me : p.id))),
                            ),
                            if (p.guest) TextSpan(text: '  guest', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                            if (p.muted && (p.all || p.mine)) TextSpan(text: p.all ? '  muted for everyone' : '  muted for you', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                          ]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink')),
                        ),
                          // How this device's connection to them stands, where it isn't simply through (GMFB-4).
                          LinkWords(id: p.id),
                        ]),
                      ),
                      if (p.video != null) Padding(padding: EdgeInsetsDirectional.only(end: t.space(2)), child: AppIcon(Lucide.video, size: 16, color: t.color('app-ink-3'))),
                      if (p.muted) Padding(padding: EdgeInsetsDirectional.only(end: t.space(3)), child: AppIcon(mutedMark(all: p.all, mine: p.mine), size: 16, wash: false, color: t.danger)),
                    ]),
                  )),
                if (coming > 0)
                  Skeleton(
                    key: const ValueKey('call-coming'),
                    label: coming == 1 ? '1 person in the call' : '$coming people in the call',
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(start: t.space(4), end: t.space(2)),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < coming; i++) SkeletonPeople.row(t, i, face: face, second: false)]),
                    ),
                  ),
              ])),
        ]);
      },
    );
  }
}

/// The pictures of whoever in [session] has video on, in the space given (Matt, 2026-11-15: "when a video starts split
/// the right side 50/50 showing the videos above the chat"): each 4:3 and as large as fits (Matt, 2026-11-23), the
/// grid centred. Nothing where nobody has video on ([any]).
class CallVideos extends StatelessWidget {
  const CallVideos({super.key, required this.session});
  final VoiceSession session;

  /// Whether anyone in [session] has video on now, this device included.
  static bool any(VoiceSession session) {
    final media = Voice.instance.media;
    if (media?.localVideo.value != null || media?.localScreen.value != null) return true;
    return session.members.values.any((m) => m.video && media?.remote.value[m.id] != null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    final media = v.media;
    return ListenableBuilder(
      listenable: Listenable.merge([session, CallPin.who, ?media?.remote, ?media?.localVideo, ?media?.localScreen]),
      builder: (context, _) {
        final mine = media?.localScreen.value ?? media?.localVideo.value;
        final all = <({String id, String name, MediaStream stream, bool muted, bool me, bool screen})>[
          if (mine != null) (id: 'me', name: 'You', stream: mine, muted: session.muted || session.deafened, me: true, screen: media?.localScreen.value != null),
          for (final m in session.members.values)
            if (m.video && media?.remote.value[m.id] != null) (id: m.id, name: m.guest ? '${v.nameOf(m.id)} (guest)' : v.nameOf(m.id), stream: media!.remote.value[m.id]!, muted: m.muted, me: false, screen: m.screen),
        ];
        if (all.isEmpty) return const SizedBox.shrink();
        // Whoever this device pinned takes the space (CallPin; a press on a picture has Pin), else someone else's
        // shared screen; the rest in a strip under it (GMFB-27).
        final pin = CallPin.inCall(session);
        final shared = [for (final x in all) if (x.id == pin) x].firstOrNull ?? [for (final x in all) if (x.screen && !x.me) x].firstOrNull;
        final tiles = shared == null ? all : [for (final x in all) if (!identical(x, shared)) x];
        Widget tile(({String id, String name, MediaStream stream, bool muted, bool me, bool screen}) x) =>
            _Tile(onPressed: () => showPerson(context, session, x.id, x.me ? 'You' : v.nameOf(x.id)), name: x.screen ? '${x.name}\'s screen' : x.name, muted: x.muted, stream: x.stream, mirror: x.me && !x.screen && !session.backCamera, screen: x.screen, tools: x.me && !x.screen ? sessionVideoTools(context, session) : const []);
        if (shared != null) {
          return Column(children: [
            Expanded(flex: 3, child: tile(shared)),
            if (tiles.isNotEmpty) ...[
              SizedBox(height: t.space(2)),
              Expanded(child: TileGrid(count: tiles.length < 4 ? tiles.length : 4, gap: t.space(2), tile: (i) => tile(tiles[i]))),
            ],
          ]);
        }
        return TileGrid(count: tiles.length, gap: t.space(2), tile: (i) => tile(tiles[i]));
      },
    );
  }
}

/// The call's buttons: the microphone, the sound, the camera and leaving, in a dock like the app's pill.
class CallDock extends StatelessWidget {
  const CallDock({super.key, required this.session});
  final VoiceSession session;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final red = t.danger;
    // The size of the sidebar's dock (Matt, 2026-11-15: "the call controls are also too large they should match the
    // size of the sidebar control dock"): its rings, its frosted pill and the step between them (NavPill), and on a
    // computer the size that dock rests at (pillScrolledScale).
    final ring = t.len('app-ring');
    final gap = t.space(2);
    final radius = BorderRadius.circular(t.radius('full'));
    final mark = t.lenOf('1.15rem');
    Widget button(LucideIcon icon, String label, VoidCallback onPress, {bool on = false, bool danger = false}) => GlacierPressable(
          onPressed: onPress,
          semanticLabel: label,
          builder: (context, state) => Container(
            width: ring,
            height: ring,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: danger ? red.withValues(alpha: state.pressed ? 0.8 : 1) : (on ? t.color('app-ink') : t.color(state.pressed ? 'app-paper-3' : 'glacier-bg')),
              border: danger || on ? null : Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')),
            ),
            alignment: Alignment.center,
            child: AppIcon(icon, size: mark, wash: false, color: danger ? const Color(0xFFFFFFFF) : (on ? t.color('app-paper') : t.color('app-ink'))),
          ),
        );
    final media = Voice.instance.media;
    final dock = ListenableBuilder(
      // The pictures too: Pop out comes with the first and goes with the last.
      listenable: Listenable.merge([session, ?media?.remote, ?media?.localVideo, ?media?.localScreen]),
      builder: (context, _) => ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: EdgeInsets.all(gap + t.len('glacier-hairline')),
            foregroundDecoration: BoxDecoration(border: Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')), borderRadius: radius),
            decoration: BoxDecoration(color: t.colorOf('color-mix(in srgb, var(--glacier-bg) 82%, transparent)'), borderRadius: radius),
            child: Row(mainAxisSize: MainAxisSize.min, spacing: gap, children: [
              // Pills, each with a chevron that opens the devices to choose from (Matt, 2026-11-15: "on the microphone
              // icon and the deafen icon make them pill shaped with a little chevron facing up that opens a popover to
              // select input and output devices respectively").
              DevicePill(
                icon: session.muted ? LucideMore.micOff : Lucide.mic,
                label: session.muted ? 'Unmute' : 'Mute',
                on: session.muted,
                onPress: () => session.locked ? sayMicLocked(context, session) : session.setMuted(!session.muted),
                kind: 'audioinput',
              ),
              DevicePill(
                icon: session.deafened ? LucideMore.headphoneOff : LucideMore.headphones,
                label: session.deafened ? 'Hear again' : 'Deafen',
                on: session.deafened,
                onPress: () => session.setDeafened(!session.deafened),
                kind: 'audiooutput',
              ),
              // The camera's too, where there are cameras to choose between (GMFB-68): a computer or a browser.
              if (RtcMedia.choosesCamera)
                DevicePill(icon: session.video ? Lucide.video : LucideMore.videoOff, label: session.video ? 'Turn video off' : 'Turn video on', on: session.video, onPress: () => session.setVideo(!session.video), kind: 'videoinput')
              else
                button(session.video ? Lucide.video : LucideMore.videoOff, session.video ? 'Turn video off' : 'Turn video on', () => session.setVideo(!session.video), on: session.video),
              // The other camera, beside the camera's button, on a phone while video is on (GMFB-57).
              if (session.canFlipCamera) button(Lucide.refreshCw, 'Flip camera', () => unawaited(session.flipCamera())),
              if (session.canShareScreen) button(LucideMore.screenShare, screenShareLabel(session), () => unawaited(toggleScreenShare(context, session)), on: session.screen),
              // Away from the call with its picture floating over the app (GMFB-64), where there is a picture to float.
              if (CallPictures.anyIn(session)) button(LucideMore.pictureInPicture, FloatWords.popOut, () => popOutCall(context)),
              // The call in a small window above every other, for playing a game in a call (GMFB-41,
              // lib/ui/call_mini.dart): a Mac's and a PC's app.
              if (CallMini.here) button(LucideMore.minimize, MiniWords.enter, () => unawaited(toggleCallMini(context))),
              button(LucideMore.phoneOff, 'Leave', () => Voice.instance.leave(), danger: true),
            ]),
          ),
        ),
      ),
    );
    return Sms.computer ? Transform.scale(scale: pillScrolledScale, alignment: Alignment.bottomCenter, child: dock) : dock;
  }
}

/// Someone's video in a call: their picture with the name along the foot, and a red mic-off mark while muted.
class _Tile extends StatelessWidget {
  const _Tile({required this.name, required this.muted, this.mark = LucideMore.micOff, this.stream, this.mirror = false, this.screen = false, this.tools = const [], this.whole = false, this.onPressed});

  /// A press on the picture: what can be done about them ([showPerson]), Pin among it (GMFB-27).
  final VoidCallback? onPressed;

  /// The camera's picture drawn whole, where the tile has its shape (a phone, GMFB-71).
  final bool whole;

  /// Buttons over the picture ([TileTools]): this device's own camera's.
  final List<TileTool> tools;

  /// The mark while [muted] ([mutedMark]).
  final LucideIcon mark;
  final String name;
  final bool muted;
  final MediaStream? stream;
  final bool mirror;

  /// A shared screen: drawn whole on black.
  final bool screen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return TileTools(
      tools: tools,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: ClipRRect(
      borderRadius: BorderRadius.circular(t.radius('lg')),
      child: ColoredBox(
        color: screen ? const Color(0xFF000000) : t.color('app-paper-3'),
        child: Stack(fit: StackFit.expand, children: [
          // One renderer per stream (GMFB-5): when the tiles shift, as they do when someone turns video off, a renderer
          // never carries on drawing whoever stood in that place before.
          if (stream != null) StreamView(key: ObjectKey(stream), stream: stream!, mirror: mirror, contain: screen || whole),
          PositionedDirectional(
            start: t.space(2),
            bottom: t.space(2),
            end: t.space(2),
            child: Row(children: [
              Flexible(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF)))),
              if (muted) ...[SizedBox(width: t.space(1)), AppIcon(mark, size: 14, wash: false, color: t.danger)],
            ]),
          ),
        ]),
      ),
    )));
  }
}

/// A button over a video tile ([TileTools]).
typedef TileTool = ({LucideIcon icon, String label, VoidCallback onPressed});

/// What stands over this device's own camera picture (GMFB-70, Matt: "Move the flip video setting to show up as a
/// button hovered over the video when available"): Flip camera where there is one to flip ([onFlip], a phone), else
/// Change camera where cameras are chosen between ([onCamera], a computer; GMFB-68). Nothing where neither.
List<TileTool> ownVideoTools({VoidCallback? onFlip, VoidCallback? onCamera}) => [
      if (onFlip != null) (icon: Lucide.refreshCw, label: 'Flip camera', onPressed: onFlip) else if (onCamera != null) (icon: Lucide.refreshCw, label: 'Change camera', onPressed: onCamera),
    ];

/// The same for a call drawn from its session (CallPanel, CallVideos).
List<TileTool> sessionVideoTools(BuildContext context, VoiceSession session) => ownVideoTools(
      onFlip: session.canFlipCamera ? () => unawaited(session.flipCamera()) : null,
      onCamera: session.video && !session.screen && RtcMedia.choosesCamera ? () => unawaited(showCameraChoices(context)) : null,
    );

/// The cameras there are, to change to in the call as it goes (GMFB-68, Matt: "There is no way to switch or select a
/// video device in the app or actively during a call"): the system's own first, the one in use ticked, as Settings ›
/// Voice and video lists them.
Future<void> showCameraChoices(BuildContext context) async {
  final v = Voice.instance;
  final list = await RtcMedia.devices('videoinput');
  if (!context.mounted) return;
  final current = v.settings.camera;
  await showChoices(context, title: 'Camera', choices: [
    Choice(current.isEmpty ? '✓  The system\'s own' : 'The system\'s own', Lucide.laptop, () => unawaited(v.useCamera(''))),
    for (final d in list)
      if (d.deviceId != 'default')
        Choice('${d.deviceId == current ? '✓  ' : ''}${d.label.isEmpty ? 'A device' : d.label}', Lucide.video, () => unawaited(v.useCamera(d.deviceId, name: d.label))),
  ]);
}

/// [child], a video tile, with small round buttons at its top right: shown while the pointer is over the tile, and
/// always where there is no pointer to hover with (a phone), so they can be reached there too (GMFB-70).
class TileTools extends StatefulWidget {
  const TileTools({super.key, required this.tools, required this.child});
  final List<TileTool> tools;
  final Widget child;

  @override
  State<TileTools> createState() => _TileToolsState();
}

class _TileToolsState extends State<TileTools> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    if (widget.tools.isEmpty) return widget.child;
    final t = context.tokens;
    final shown = _over || !WidgetsBinding.instance.mouseTracker.mouseIsConnected;
    return MouseRegion(
      onEnter: (_) => setState(() => _over = true),
      onExit: (_) => setState(() => _over = false),
      child: Stack(fit: StackFit.expand, children: [
        widget.child,
        if (shown)
          PositionedDirectional(
            top: 8,
            end: 8,
            child: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
              for (final x in widget.tools)
                GlacierPressable(
                  onPressed: x.onPressed,
                  semanticLabel: x.label,
                  builder: (context, state) => Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: t.color(state.pressed ? 'app-paper-3' : 'glacier-bg').withValues(alpha: 0.9)),
                    alignment: Alignment.center,
                    child: AppIcon(x.icon, size: 16, wash: false, color: t.color('app-ink')),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

/// Who may draw each stream now, and how many renderers hold it (GMFB-64): a picture taken somewhere else ([StreamView]
/// with `claim`: the floating call and Android's picture in picture, lib/ui/call_float.dart) is drawn there alone. The
/// call's page under it, kept by its route while covered, lets go of its renderer for that stream and takes one again
/// when the picture comes back; the one taking it waits until every other has let go, so one stream is never on two
/// renderers at once, and a renderer only ever shows the one stream it was made for (GMFB-5).
abstract final class StreamClaims {
  /// Who has taken each stream, by its id: the last to take it is the one that draws it.
  static final Map<String, List<Object>> _takers = {};

  /// How many renderers hold each stream, and how many of those are still letting go of it.
  static final Map<String, int> _held = {}, _letting = {};

  /// Told when who may draw a stream changes: after the frame, so no picture is built again while one is.
  static final changes = _Told();
  static bool _saying = false;

  /// Who may draw [id]: null where nobody has taken it (every view of it may).
  static Object? takerOf(String id) => _takers[id]?.last;

  /// How many renderers hold [id] now, for a test.
  @visibleForTesting
  static int heldOf(String id) => _held[id] ?? 0;

  /// For a test: as the app starts, nothing taken or held (a test's last renderers are never let go of).
  @visibleForTesting
  static void reset() {
    _takers.clear();
    _held.clear();
    _letting.clear();
    _waiting.clear();
  }

  static void take(String id, Object who) {
    (_takers[id] ??= []).add(who);
    _say();
  }

  static void give(String id, Object who) {
    final l = _takers[id];
    if (l == null || !l.remove(who)) return;
    if (l.isEmpty) _takers.remove(id);
    _say();
  }

  static void _say() {
    if (_saying) return;
    _saying = true;
    final b = SchedulerBinding.instance;
    b.addPostFrameCallback((_) {
      _saying = false;
      changes.tell();
    });
    b.ensureVisualUpdate();
  }

  static final List<({String id, bool all, Completer<void> done})> _waiting = [];

  /// Done once [id] is free to take: no renderer still letting go of it, and, for [all] (a view that takes the
  /// picture), none holding it at all.
  static Future<void> free(String id, {bool all = false}) {
    if (_freeFor(id, all)) return Future.value();
    final w = (id: id, all: all, done: Completer<void>());
    _waiting.add(w);
    return w.done.future;
  }

  static bool _freeFor(String id, bool all) => (all ? _held[id] ?? 0 : _letting[id] ?? 0) == 0;

  static void _counted() {
    for (final w in [..._waiting]) {
      if (_freeFor(w.id, w.all)) {
        _waiting.remove(w);
        w.done.complete();
      }
    }
  }

  static void _hold(String id) => _held[id] = (_held[id] ?? 0) + 1;

  /// A renderer of [id] lets go of it, done when [done] is.
  static void _let(String id, Future<void> done) {
    _letting[id] = (_letting[id] ?? 0) + 1;
    unawaited(done.catchError((Object _) {}).whenComplete(() {
      _letting[id] = (_letting[id] ?? 1) - 1;
      _held[id] = (_held[id] ?? 1) - 1;
      if (_letting[id]! <= 0) _letting.remove(id);
      if (_held[id]! <= 0) _held.remove(id);
      _counted();
    }));
  }
}

/// [StreamClaims.changes]: a notifier that can be told from outside.
class _Told extends ChangeNotifier {
  void tell() => notifyListeners();
}

/// A picture from a call.
class StreamView extends StatefulWidget {
  const StreamView({super.key, required this.stream, this.mirror = false, this.contain = false, this.claim = false});
  final MediaStream stream;
  final bool mirror;

  /// Drawn whole inside its space rather than filling it: a shared screen (GMFB-27), whose edges matter.
  final bool contain;

  /// Takes the picture from wherever else it is drawn, for as long as this is shown ([StreamClaims]): the floating
  /// call and Android's picture in picture (GMFB-64), over a call's page that is still kept under them.
  final bool claim;

  @override
  State<StreamView> createState() => _StreamViewState();
}

class _StreamViewState extends State<StreamView> {
  RTCVideoRenderer? _renderer;
  bool _ready = false, _taking = false;
  late String _id = widget.stream.id;

  /// Whether this one may draw the stream now: nobody took it, or this did.
  bool get _mine {
    final who = StreamClaims.takerOf(_id);
    return who == null ? !widget.claim : identical(who, this);
  }

  @override
  void initState() {
    super.initState();
    if (widget.claim) StreamClaims.take(_id, this);
    StreamClaims.changes.addListener(_claimsChanged);
    unawaited(_take());
  }

  void _claimsChanged() {
    if (!mounted) return;
    if (_mine) {
      unawaited(_take());
    } else if (_renderer != null) {
      setState(_drop);
    }
  }

  /// A renderer for the stream, once nothing stands in the way: none still letting go of it, and, taking it from
  /// elsewhere, none holding it.
  Future<void> _take() async {
    if (_renderer != null || _taking) return;
    _taking = true;
    try {
      await StreamClaims.free(_id, all: widget.claim);
      if (!mounted || !_mine || _renderer != null) return;
      final r = RTCVideoRenderer();
      StreamClaims._hold(_id);
      _renderer = r;
      r.addListener(_shape);
      try {
        await r.initialize();
      } catch (_) {
        // No renderer to be had (a platform without one): nothing is drawn.
        if (identical(_renderer, r)) _drop();
        return;
      }
      if (!identical(_renderer, r)) return;
      if (!mounted || !_mine) {
        _drop();
        return;
      }
      r.srcObject = widget.stream;
      setState(() => _ready = true);
    } finally {
      _taking = false;
    }
  }

  /// Lets go of the renderer, if there is one.
  void _drop() {
    final r = _renderer;
    if (r == null) return;
    _renderer = null;
    _ready = false;
    r.removeListener(_shape);
    StreamClaims._let(_id, r.dispose());
  }

  /// The picture's own shape, said as its frames give it (GMFB-71): a phone's tile is drawn that shape.
  void _shape() {
    final v = _renderer?.value;
    if (v != null && v.width > 0 && v.height > 0) VideoShapes.say(widget.stream.id, v.aspectRatio);
  }

  @override
  void didUpdateWidget(StreamView old) {
    super.didUpdateWidget(old);
    if (identical(old.stream, widget.stream)) return;
    if (old.stream.id != widget.stream.id) {
      // Another stream altogether: the renderer is let go of, and one taken for this.
      if (old.claim) StreamClaims.give(_id, this);
      _drop();
      _id = widget.stream.id;
      if (widget.claim) StreamClaims.take(_id, this);
      unawaited(_take());
      return;
    }
    if (_ready) _renderer?.srcObject = widget.stream;
  }

  @override
  void dispose() {
    StreamClaims.changes.removeListener(_claimsChanged);
    _drop();
    if (widget.claim) StreamClaims.give(_id, this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _renderer;
    return _ready && r != null ? RTCVideoView(r, mirror: widget.mirror, objectFit: widget.contain ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover) : const SizedBox.shrink();
  }
}

/// A new channel: its name, and the friends it is shared with.
class NewChannelScreen extends StatefulWidget {
  const NewChannelScreen({super.key});

  @override
  State<NewChannelScreen> createState() => _NewChannelScreenState();
}

class _NewChannelScreenState extends State<NewChannelScreen> {
  final _name = TextEditingController();
  final Set<String> _with = {};

  // What it is for, as a circle's spaces are (lib/ui/circles/new_circle.dart): chat and voice, texting only, or files.
  SpaceKind _kind = SpaceKind.voice;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Makes the space, shares it with the friends ticked (saying who could not be reached), then opens it: its page
  /// for one without voice, the call itself for one with.
  Future<void> _make() async {
    final v = Voice.instance;
    final c = await v.make(_name.text, kind: _kind);
    final friends = [for (final f in Buddies.instance.friends) if (_with.contains(f.id)) f];
    final missed = friends.isEmpty ? const <Buddy>[] : await v.share(c, friends);
    if (!mounted) return;
    toast(context, friends.isEmpty ? '${c.name} made' : '${c.name} shared with ${friends.length - missed.length}${missed.isEmpty ? '' : '; couldn\'t reach ${missed.map((f) => f.shown).join(', ')}'}');
    // A texting or Files space has no call: its page opens, its chat ready. As any space does in a browser, which has
    // no calls yet (Sms.callsHere).
    if (!c.hasVoice || !Sms.callsHere) {
      final shell = AppShell.maybeOf(context);
      if (shell != null) {
        v.view(c);
        shell.go('voice');
      } else {
        unawaited(Navigator.of(context).pushReplacement(PageRouteBuilder<void>(pageBuilder: (context, _, _) => HangoutScreen(channel: c))));
      }
      return;
    }
    // A call, started: in it at once, its page in this one's place.
    try {
      await v.join(c);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t join: $e', tone: GlacierToastTone.danger);
    }
    if (!mounted) return;
    final shell = AppShell.maybeOf(context);
    if (shell != null) {
      shell.go('voice');
    } else {
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(pageBuilder: (context, _, _) => const VoiceScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final friends = Buddies.instance.roomFriends;
    return GhostPage(
      title: 'New space',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: StatefulBuilder(
          builder: (context, set) => ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            children: [
              PaneSection(title: 'Name', children: [
                SettingRowBox(child: GlacierInput(controller: _name, placeholder: 'Space name'.t, ariaLabel: 'Space name', autoFocus: true, autoCapitalize: TextCapitalization.words, size: GlacierFieldSize.md)),
              ]),
              SizedBox(height: t.space(6)),
              SpaceKindCards(value: _kind, onChanged: (k) => setState(() => _kind = k)),
              SizedBox(height: t.space(6)),
              PaneSection(
                title: 'Share with',
                description: Text(friends.isEmpty ? 'Add friends by username (Settings › Me › Friends) to share spaces with them.' : 'They can see who\'s in it and hop in any time.'),
                children: [
                  for (final f in friends)
                    SettingRow(
                      icon: AppIcon(Lucide.userRound, size: 18),
                      label: f.shown,
                      control: GlacierSwitch(checked: _with.contains(f.id), onCheckedChange: (on) => set(() => on ? _with.add(f.id) : _with.remove(f.id)), ariaLabel: f.shown),
                    ),
                ],
              ),
              SizedBox(height: t.space(6)),
              PaneSection(children: [
                _kind.hasVoice && Sms.callsHere
                    ? SettingRow(key: const ValueKey('new-space-make'), icon: AppIcon(LucideMore.phoneCall, size: 18), label: 'Start the call', onPress: _make)
                    : SettingRow(key: const ValueKey('new-space-make'), icon: AppIcon(Lucide.check, size: 18), label: 'Make the space', onPress: _make),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// A group calling, or a friend's invite into a space: shown over everything until joined or put away.
class RingCard extends StatelessWidget {
  const RingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    return ListenableBuilder(
      listenable: v,
      builder: (context, _) {
        final r = v.ringing;
        if (r == null) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), MediaQuery.paddingOf(context).top + t.space(2), t.space(3), 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: t.lenOf('30rem')),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(t.radius('xl')),
                child: ColoredBox(
                  color: t.color('app-ink'),
                  child: Padding(
                    padding: EdgeInsets.all(t.space(3)),
                    child: Row(children: [
                      AppIcon(r.invite ? Lucide.userPlus : (r.video ? Lucide.video : LucideMore.phoneCall), size: 22, wash: false, color: t.color('app-paper')),
                      SizedBox(width: t.space(3)),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(r.invite ? '${r.from} invited you to ${r.channel.name}' : (r.call != null ? r.from : r.channel.name), maxLines: r.invite ? 2 : 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'bold', color: t.color('app-paper'))),
                          // A waiting invite is not in the spaces until Join (Voice.offers): anyone who knows a number could leave one.
                          // A friend calling this device alone (GMFB-28): a phone's words.
                          Text(r.call != null ? (r.video ? 'Video call' : 'Voice call') : (r.offer ? 'Join to add it to your spaces' : (r.invite ? 'Now in your spaces' : '${r.from} is calling the group')), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-paper'))),
                        ]),
                      ),
                      IconTap(key: const ValueKey('ring-decline'), icon: Lucide.x, label: r.call != null ? 'Decline' : 'Not now', color: t.color('app-paper'), onPressed: v.dismissRing),
                      SizedBox(width: t.space(1)),
                      GlacierPressable(
                        onPressed: () async {
                          try {
                            await (r.offer ? v.acceptOffer(r) : v.join(r.channel, video: r.video));
                            // A friend's call answered: to the call (GMFB-28).
                            if (r.call != null && context.mounted) {
                              final shell = AppShell.maybeOf(context);
                              if (shell != null) {
                                shell.go('voice');
                              } else {
                                unawaited(push(context, (_) => const VoiceScreen()));
                              }
                            }
                          } catch (e) {
                            if (context.mounted) toast(context, 'Couldn\'t join: $e', tone: GlacierToastTone.danger);
                          }
                        },
                        semanticLabel: r.call != null ? 'Answer' : 'Join',
                        builder: (context, state) => Container(
                          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
                          decoration: BoxDecoration(color: t.online, borderRadius: BorderRadius.circular(t.radius('full'))),
                          key: const ValueKey('ring-answer'),
                          child: Text(r.call != null ? 'Answer' : 'Join', style: pageText(t, t.fontSize('sm'), weight: 'bold', color: const Color(0xFFFFFFFF))),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A voice channel among the conversations (Matt, 2026-11-15: "add voice chats to the list as well"): a card like a
/// conversation's, who is in it now (live, in green) or when it last had anyone, and a press to hop in.
class VoiceRow extends StatelessWidget {
  const VoiceRow({super.key, required this.channel, required this.onPress});
  final VoiceChannel channel;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    final face = t.lenOf('3rem');
    final green = t.online;
    final here = v.session?.channel.room == channel.room;
    final inIt = here ? ['me', ...v.session!.members.keys] : v.inChannel(channel);
    final live = inIt.isNotEmpty;
    final last = v.lastActive(channel);
    final who = here
        ? (inIt.length == 1 ? 'You\'re in · just you' : 'You\'re in · ${inIt.where((i) => i != 'me').map(v.nameOf).join(', ')}')
        : live
            ? inIt.map(v.nameOf).join(', ')
            : 'Nobody here · hop in any time';
    // Held, or pressed with the other button: a hangout's menu (Matt, 2026-11-15: "there also needs to be a context
    // menu to open settings for hangouts and manage permissions and such as well as delete the hangouts").
    void menu() {
      if (channel.hangout) {
        showHangoutMenu(context, channel, onOpen: onPress);
      } else {
        // A group's own space: it can still be put in one of the Spaces tab's groups.
        showChoices(context, title: channel.name, choices: [
          Choice('Open', LucideMore.headphones, onPress),
          Choice('Move to group…', Lucide.folder, () => pickSpaceGroup(context, channel)),
        ]);
      }
    }

    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      onLongPress: menu,
      onSecondaryTap: menu,
      child: GlacierPressable(
      onPressed: onPress,
      semanticLabel: '${channel.name}, space, ${live ? '${inIt.length} in it' : 'nobody in it'}',
      builder: (context, state) => Padding(
        padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
        child: Container(
          decoration: BoxDecoration(
            color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
            borderRadius: BorderRadius.circular(t.lenOf('1rem')),
            border: Border.all(color: here ? green : const Color(0x00000000), width: 2),
          ),
          padding: EdgeInsets.symmetric(horizontal: t.space(3) - 2, vertical: t.space(3) - 2),
          child: Row(children: [
            Container(
              width: face,
              height: face,
              decoration: BoxDecoration(shape: BoxShape.circle, color: live ? green.withValues(alpha: 0.16) : t.color('app-paper-3')),
              alignment: Alignment.center,
              child: AppIcon(channel.group != null ? Lucide.users : LucideMore.headphones, size: 20, wash: false, color: live ? green : t.color('app-ink-2')),
            ),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: live ? 'bold' : 'semibold', color: t.color('app-ink')))),
                  SizedBox(width: t.space(2)),
                  if (live)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: green)),
                      SizedBox(width: t.space(1)),
                      Text('Live', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: green)),
                    ])
                  else if (last != null)
                    Text(listWhen(last), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                ]),
                SizedBox(height: t.lenOf('0.15rem')),
                Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color(live ? 'app-ink-2' : 'app-ink-3'))),
              ]),
            ),
          ]),
        ),
      ),
    ),
    );
  }
}

/// The call you're in, as a banner in the sidebar just above the dock (Matt, 2026-11-15: "switch the active call to
/// be a banner again in the sidebar just above the navigation bar"): a beating green dot, the channel, how long and
/// who is talking, their faces rippling, and mute and leave. Pressed, it opens the call.
class CallBanner extends StatefulWidget {
  const CallBanner({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  State<CallBanner> createState() => _CallBannerState();
}

class _CallBannerState extends State<CallBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  Timer? _tick;

  /// The dot's beat and the call's clock run only while there is a call. The banner stays in the sidebar for the
  /// app's whole life, and a beat started at the first call and never stopped had the window drawn again at every
  /// refresh from then on, call or none (docs/performance-audit.md).
  void _sync() {
    final calling = Voice.instance.session != null;
    if (calling && !_beat.isAnimating) {
      _beat.repeat(reverse: true);
      // The time in the call, a second at a time.
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && Voice.instance.session != null) setState(() {});
      });
    } else if (!calling && (_beat.isAnimating || _tick != null)) {
      _beat.stop();
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void initState() {
    super.initState();
    Voice.instance.addListener(_sync);
    _sync();
  }

  @override
  void dispose() {
    Voice.instance.removeListener(_sync);
    _beat.dispose();
    _tick?.cancel();
    super.dispose();
  }

  /// The time in the call as a clock: 4:05, 1:02:09.
  static String _clock(Duration d) {
    final m = d.inMinutes, s = d.inSeconds % 60;
    return m >= 60 ? '${m ~/ 60}:${(m % 60).toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    return ListenableBuilder(
      // The call's floating picture stands in for the bar while it is up (GMFB-64, lib/ui/call_float.dart).
      listenable: Listenable.merge([v, CallFloat.instance]),
      builder: (context, _) {
        final s = v.session;
        if (s == null || CallFloat.instance.shown) return const SizedBox.shrink();
        final levels = v.media?.levels ?? s.media.levels;
        final red = t.danger;
        return ListenableBuilder(
          listenable: Listenable.merge([s, levels, ?v.media?.links, ?v.media?.micLive]),
          builder: (context, _) {
            final loud = levels.value;
            final talking = [
              if ((loud['me'] ?? 0) > RippleAvatar.talking && !s.muted) ('me', s.name.isEmpty ? 'You' : s.name),
              for (final m in s.members.values)
                if ((loud[m.id] ?? 0) > RippleAvatar.talking && !m.muted) (m.id, v.nameOf(m.id)),
            ];
            final people = s.members.length + 1;
            final radius = BorderRadius.circular(t.radius('full'));
            // Still connecting (lib/voice/call_wait.dart): amber, and what it is waiting for where the clock goes.
            final wait = CallWaitBuilder.now();
            final green = wait == null ? t.online : ConnectingBanner.amber(t);
            return GlacierPressable(
              onPressed: widget.onOpen,
              semanticLabel: wait != null ? '${s.channel.name}. ${wait.line}. Open the call.' : 'In ${s.channel.name}, $people connected${s.muted ? ', muted' : ''}. Open the call.',
              builder: (context, state) => ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1) + 2, t.space(1) + 2, t.space(1) + 2),
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(green.withValues(alpha: state.pressed ? 0.24 : 0.16), t.colorOf('color-mix(in srgb, var(--glacier-bg) 88%, transparent)')),
                      borderRadius: radius,
                      border: Border.all(color: green.withValues(alpha: 0.5), width: 1.5),
                    ),
                    child: Row(children: [
                      // Painted by itself: the beat does not have the banner, and the blur behind it, painted again.
                      RepaintBoundary(
                        child: FadeTransition(
                          opacity: Tween(begin: 0.35, end: 1.0).animate(_beat),
                          child: Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: green)),
                        ),
                      ),
                      SizedBox(width: t.space(2)),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(s.channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-ink'))),
                          Text(
                            wait != null
                                ? wait.line
                                : '${_clock(DateTime.now().difference(s.since ?? DateTime.now()))} · ${talking.isEmpty ? (people == 1 ? 'just you' : '$people here') : '${talking.map((x) => x.$2).join(', ')} talking'}',
                            key: wait != null ? const ValueKey('call-banner-connecting') : null,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: pageText(t, t.fontSize('xs'), color: wait != null ? green : (talking.isEmpty ? t.color('app-ink-3') : green)),
                          ),
                        ]),
                      ),
                      for (final (id, name) in talking.take(3))
                        Padding(padding: EdgeInsetsDirectional.only(start: t.space(1)), child: RippleAvatar(name: name, level: loud[id] ?? 0, size: 26)),
                      SizedBox(width: t.space(2)),
                      // The picture closed for this call: brought back over the app from here (GMFB-64).
                      if (CallFloat.instance.canPopOut) ...[
                        IconTap(key: const ValueKey('call-banner-pop-out'), icon: LucideMore.pictureInPicture, label: FloatWords.popOut, size: 18, onPressed: CallFloat.instance.reopen),
                        SizedBox(width: t.space(1)),
                      ],
                      IconTap(icon: s.muted ? LucideMore.micOff : Lucide.mic, label: s.muted ? 'Unmute' : 'Mute', size: 18, color: s.muted ? red : null, onPressed: () => s.locked ? sayMicLocked(context, s) : s.setMuted(!s.muted)),
                      SizedBox(width: t.space(1)),
                      GlacierPressable(
                        onPressed: () => v.leave(),
                        semanticLabel: 'Leave the call',
                        builder: (context, state) => Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: red.withValues(alpha: state.pressed ? 0.8 : 1)),
                          alignment: Alignment.center,
                          child: const AppIcon(LucideMore.phoneOff, size: 16, wash: false, color: Color(0xFFFFFFFF)),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The mark on someone who isn't heard (GMFB-49), so anyone can tell which mute it is: a lock where a moderator muted
/// them for everyone ([all]), a crossed speaker where only this device stopped hearing them ([mine]), the crossed
/// microphone where they muted themselves. A space's call page has the same (SpaceWords.mutedIcon).
LucideIcon mutedMark({required bool all, required bool mine}) => all ? Lucide.lock : (mine ? LucideMore.volumeX : LucideMore.micOff);

/// Why this device can't unmute, said when its mute button is pressed while locked (GMFB-49): until now the button
/// did nothing and said nothing.
void sayMicLocked(BuildContext context, VoiceSession session) =>
    toast(context, Voice.instance.hangoutFor(session.channel)?.micLockedWhy ?? 'You can\'t unmute in this space.');

/// What can be done about someone in the call, from this device (Matt, 2026-11-15: "add the ability to press and hold
/// on a user to habe options like muting changing volume levels for that user and more"): silence them here, how loud
/// they are here, add them as a friend where they have a username, copy their name. For yourself: mute and deafen.
void showPerson(BuildContext context, VoiceSession session, String id, String name) {
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => _PersonSheet(session: session, id: id, name: name),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The sheet [showPerson] slides up from the foot: a tap outside it closes it, and it follows the call as it changes.
class _PersonSheet extends StatelessWidget {
  const _PersonSheet({required this.session, required this.id, required this.name});
  final VoiceSession session;
  final String id;
  final String name;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final v = Voice.instance;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () {},
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: t.lenOf('30rem')),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(t.radius('xl')),
                child: ColoredBox(
                  color: t.color('app-paper-2'),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([v, session, CallPin.who]),
                    builder: (context, _) {
                      final me = id == 'me';
                      final m = session.members[id];
                      final gone = !me && m == null;
                      final friend = m?.username == null ? null : Buddies.instance.all.where((b) => b.username == m!.username).firstOrNull;
                      return Padding(
                        padding: EdgeInsets.all(t.space(4)),
                        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            RippleAvatar(name: name, level: 0, size: 44),
                            SizedBox(width: t.space(3)),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
                                Text(
                                  me ? 'You' : gone ? 'Left the call' : m!.guest ? 'Guest, from a link' : (m.username == null ? 'In the call' : '@${m.username}'),
                                  style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
                                ),
                              ]),
                            ),
                          ]),
                          SizedBox(height: t.space(3)),
                          // Their picture kept large on this device until unpinned (GMFB-27: "can pin it"), while
                          // their camera or screen is on. Nobody else is told.
                          if (CallPin.canPin(session, id) || CallPin.inCall(session) == id)
                            SettingRow(
                              key: const ValueKey('sheet-pin'),
                              icon: AppIcon(CallPin.inCall(session) == id ? Lucide.pinOff : Lucide.pin, size: 18),
                              label: CallPin.inCall(session) == id ? 'Unpin' : 'Pin',
                              hint: Text(CallPin.inCall(session) == id ? 'Back among the others.' : (me ? 'Keep your picture large. Only you see it that way.' : 'Keep their picture large. Only you see it that way.')),
                              onPress: () {
                                CallPin.toggle(session, id);
                                Navigator.of(context).pop();
                              },
                            ),
                          if (me) ...[
                            SettingRow(
                              label: 'Mute',
                              // Locked, the switch stays on: the line under it says why (GMFB-49).
                              hint: session.locked ? Text(v.hangoutFor(session.channel)?.micLockedWhy ?? 'You can\'t unmute in this space.') : null,
                              control: GlacierSwitch(checked: session.muted, onCheckedChange: session.setMuted, ariaLabel: 'Mute'),
                            ),
                            SettingRow(label: 'Deafen', hint: const Tr('Hear nobody, and say nothing.'), control: GlacierSwitch(checked: session.deafened, onCheckedChange: session.setDeafened, ariaLabel: 'Deafen')),
                            // The camera, in what a press on one's own video opens (GMFB-70, Matt: "add it to the menu
                            // that pops up when tapping on a video"): the other side of a phone, or another of a
                            // computer's (GMFB-68).
                            if (session.canFlipCamera)
                              SettingRow(key: const ValueKey('sheet-flip'), icon: AppIcon(Lucide.refreshCw, size: 18), label: 'Flip camera', hint: const Tr('Front or back'), onPress: () => unawaited(session.flipCamera()))
                            else if (session.video && !session.screen && RtcMedia.choosesCamera)
                              SettingRow(
                                key: const ValueKey('sheet-camera'),
                                icon: AppIcon(Lucide.video, size: 18),
                                label: 'Change camera',
                                onPress: () {
                                  final root = Navigator.of(context, rootNavigator: true);
                                  root.pop();
                                  unawaited(showCameraChoices(root.context));
                                },
                              ),
                          ] else if (!gone) ...[
                            SettingRow(
                              icon: AppIcon(LucideMore.volumeX, size: 18),
                              label: 'Mute for me',
                              hint: const Tr('Only you stop hearing them. They aren\'t told.'),
                              control: GlacierSwitch(checked: v.silenced(id), onCheckedChange: (on) => v.setSilenced(id, on), ariaLabel: 'Mute $name for me'),
                            ),
                            // Muted for everyone, for whoever can't change it (a moderator has the switch below).
                            if (v.hangoutFor(session.channel) case final room? when room.mutedForAll(id) && !room.canMuteForAll(id))
                              SettingRow(
                                key: const ValueKey('muted-for-everyone'),
                                icon: AppIcon(Lucide.lock, size: 18),
                                label: 'Muted for everyone',
                                hint: const Tr('A moderator muted them. Only a moderator can unmute them.'),
                              ),
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: t.space(2)),
                              child: Row(children: [
                                AppIcon(Lucide.volume2, size: 18, color: t.color('app-ink-2')),
                                SizedBox(width: t.space(3)),
                                Expanded(child: VolumeSlider(value: v.volumeOf(id).clamp(0.0, CallSound.most), max: CallSound.most, onChanged: (x) => v.setVolume(id, x), label: 'Volume for $name')),
                                SizedBox(width: t.space(3)),
                                SizedBox(width: 44, child: Text('${(v.volumeOf(id) * 100).round()}%', textAlign: TextAlign.end, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink')))),
                              ]),
                            ),
                            // What the auto leveler is doing to them, while it is on (lib/voice/leveler.dart).
                            ListenableBuilder(
                              listenable: AutoLeveler.instance,
                              builder: (context, _) {
                                final lv = AutoLeveler.instance;
                                if (!lv.active) return const SizedBox.shrink();
                                final db = lv.dbOf(id);
                                final words = db.abs() < 0.5 ? 'Auto leveler: as they are' : 'Auto leveler: ${db > 0 ? 'up' : 'down'} ${db.abs().toStringAsFixed(0)} dB';
                                return Padding(
                                  key: const ValueKey('leveler-line'),
                                  padding: EdgeInsetsDirectional.only(start: 18 + t.space(3), bottom: t.space(2)),
                                  child: Text(words, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                                );
                              },
                            ),
                            // On a stage, whoever manages it brings people up to speak and sends them back to listen
                            // (GMFB-29).
                            Builder(builder: (context) {
                              final room = v.hangoutFor(session.channel);
                              if (room == null || !room.stage || !room.canManage || !room.roster.outranks(room.me, id)) return const SizedBox.shrink();
                              final listening = room.listens(id);
                              return SettingRow(
                                key: const ValueKey('stage-speaker'),
                                icon: AppIcon(listening ? Lucide.megaphone : LucideMore.headphones, size: 18),
                                label: listening ? (m!.hand ? 'Bring up to speak (hand raised)' : 'Bring up to speak') : 'Move to the audience',
                                onPress: () async {
                                  final ok = await room.setSpeaker(id, listening);
                                  if (context.mounted && !ok) toast(context, 'That couldn\'t be changed');
                                },
                              );
                            }),
                            if (m!.username != null && friend?.state != 'yes')
                              SettingRow(
                                icon: AppIcon(Lucide.userPlus, size: 18),
                                label: friend?.state == 'asked' ? 'Friend request sent' : 'Add @${m.username} as a friend',
                                disabled: friend != null,
                                onPress: () async {
                                  try {
                                    await Buddies.instance.add(m.username!);
                                    if (context.mounted) toast(context, 'Asked @${m.username}');
                                  } catch (e) {
                                    if (context.mounted) toast(context, '$e', tone: GlacierToastTone.danger);
                                  }
                                },
                              ),
                            SettingRow(
                              icon: AppIcon(Lucide.copy, size: 18),
                              label: 'Copy name',
                              onPress: () {
                                Clipboard.setData(ClipboardData(text: m.username == null ? name : '@${m.username}'));
                                toast(context, 'Copied');
                              },
                            ),
                            // A hangout's: their role, and what this device's role may do about them.
                            if (v.hangoutFor(session.channel) case final room?) HangoutModeration(room: room, id: id, name: name),
                          ],
                          if (me)
                            if (v.hangoutFor(session.channel) case final room?)
                              SettingRow(icon: AppIcon(Lucide.shieldCheck, size: 18), label: 'Your role', value: RoleTag(role: room.roster.roleOf(room.me), owner: room.roster.isOwner(room.me))),
                        ]),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A volume from nothing to twice as loud, dragged or tapped along its track; 100% marked.
class VolumeSlider extends StatelessWidget {
  const VolumeSlider({super.key, required this.value, required this.onChanged, required this.label, this.max = 2.0});
  final double value;
  final ValueChanged<double> onChanged;
  final String label;
  final double max;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      label: label,
      value: '${(value * 100).round()}%',
      increasedValue: '${((value + 0.1).clamp(0, max) * 100).round()}%',
      decreasedValue: '${((value - 0.1).clamp(0, max) * 100).round()}%',
      onIncrease: () => onChanged((value + 0.1).clamp(0, max)),
      onDecrease: () => onChanged((value - 0.1).clamp(0, max)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        void at(double x) {
          var v = (x / w).clamp(0.0, 1.0) * max;
          // Held at 100% when near it.
          if ((v - 1).abs() < 0.04) v = 1;
          onChanged(v);
        }

        final frac = (value / max).clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => at(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
          child: SizedBox(
            height: 32,
            child: Stack(alignment: AlignmentDirectional.centerStart, children: [
              Container(height: 6, decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(3))),
              Container(width: w * frac, height: 6, decoration: BoxDecoration(color: t.color('app-accent'), borderRadius: BorderRadius.circular(3))),
              PositionedDirectional(start: w / 2 - 1, child: Container(width: 2, height: 12, color: t.color('app-ink-4'))),
              PositionedDirectional(
                start: (w * frac - 11).clamp(0.0, w - 22),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('app-paper'), border: Border.all(color: t.color('app-accent'), width: 2), boxShadow: t.shadowOf('0 1px 4px rgba(0,0,0,0.2)')),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }
}


/// A dock button as a pill: its toggle, and beside it a chevron facing up that opens the devices of [kind]
/// (`audioinput`: the microphones; `audiooutput`: the speakers and headsets) to choose from, the one in use ticked,
/// and a way to Settings › Voice and video.
class DevicePill extends StatefulWidget {
  const DevicePill({super.key, required this.icon, required this.label, required this.on, required this.onPress, required this.kind});
  final LucideIcon icon;
  final String label;
  final bool on;
  final VoidCallback onPress;
  final String kind;

  @override
  State<DevicePill> createState() => _DevicePillState();
}

class _DevicePillState extends State<DevicePill> {
  bool _open = false;
  List<MediaDeviceInfo> _devices = const [];

  Future<void> _load() async {
    final found = await RtcMedia.devices(widget.kind);
    if (mounted) setState(() => _devices = found);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    final input = widget.kind == 'audioinput';
    // The camera's (GMFB-68): the same pill, listing cameras.
    final camera = widget.kind == 'videoinput';
    final current = camera ? v.settings.camera : (input ? v.settings.input : v.settings.output);
    final ink = widget.on ? t.color('app-paper') : t.color('app-ink');
    final ground = widget.on ? t.color('app-ink') : t.color('glacier-bg');
    Widget row(String id, String name) => GlacierMenuItem(
          icon: AppIcon(camera ? Lucide.video : (input ? Lucide.mic : LucideMore.headphones), size: 16),
          shortcut: id == current ? AppIcon(Lucide.check, size: 16, color: t.color('app-ink')) : const SizedBox(width: 16),
          onSelect: () => camera ? v.useCamera(id, name: name) : (input ? v.useInput(id, name: name) : v.useOutput(id, name: name)),
          child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    final ring = t.len('app-ring');
    return Container(
      height: ring,
      decoration: BoxDecoration(
        color: ground,
        borderRadius: BorderRadius.circular(ring / 2),
        border: widget.on ? null : Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        GlacierPressable(
          onPressed: widget.onPress,
          semanticLabel: widget.label,
          builder: (context, state) => Container(
            width: ring - 6,
            height: ring,
            padding: const EdgeInsetsDirectional.only(start: 6),
            alignment: Alignment.center,
            child: AppIcon(widget.icon, size: t.lenOf('1.15rem'), wash: false, color: ink),
          ),
        ),
        GlacierMenu(
          open: _open,
          onOpenChange: (open) {
            setState(() => _open = open);
            if (open) _load();
          },
          placement: Placement.top,
          ariaLabel: camera ? 'Camera' : (input ? 'Microphone' : 'Speaker'),
          style: GlacierMenuStyle(minWidth: t.lenOf('15rem'), maxWidth: t.lenOf('20rem')),
          trigger: (context, trigger) => GlacierPressable(
            onPressed: trigger.toggle,
            semanticLabel: camera ? 'Choose a camera' : (input ? 'Choose a microphone' : 'Choose a speaker'),
            builder: (context, state) => Container(
              width: 24,
              height: ring,
              padding: const EdgeInsetsDirectional.only(end: 6),
              alignment: Alignment.center,
              child: AppIcon(Lucide.chevronUp, size: 14, strokeWidth: 2.4, wash: false, color: ink.withValues(alpha: 0.75)),
            ),
          ),
          children: [
            GlacierMenuLabel(child: Text(camera ? 'Camera' : (input ? 'Microphone' : 'Speaker or headset'))),
            row('', input ? 'The system\'s own' : 'The system\'s own'),
            // The Mac's "default" is the system's own, the row above.
            for (final d in _devices)
              if (d.deviceId != 'default') row(d.deviceId, d.label.isEmpty ? 'A device' : d.label),
            const GlacierMenuSeparator(),
            GlacierMenuItem(
              icon: const AppIcon(Lucide.settings, size: 16),
              onSelect: () {
                final shell = AppShell.maybeOf(context);
                if (shell != null) shell.settings('voice');
              },
              child: const Tr('Voice settings…'),
            ),
          ],
        ),
      ]),
    );
  }
}

/// A group of friends' call while anyone is in it and this device isn't, floating at the top of its conversation: who
/// is in it and Join (Matt, 2026-11-17: "each group should come with a space"; its chat is the group's texts, so the
/// call is joined from there). Nothing while the call is empty or this device is in it.
class SpaceLiveBar extends StatelessWidget {
  const SpaceLiveBar({super.key, required this.channel, required this.onJoin});
  final VoiceChannel channel;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Voice.instance,
      builder: (context, _) {
        final v = Voice.instance;
        final inIt = v.inChannel(channel);
        if (inIt.isEmpty || v.session?.channel.room == channel.room) return const SizedBox.shrink();
        final radius = BorderRadius.circular(t.radius('full'));
        final (fill, words) = strongFill(t);
        return Center(
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(1), t.space(1)),
                foregroundDecoration: BoxDecoration(border: Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')), borderRadius: radius),
                decoration: BoxDecoration(color: t.colorOf('color-mix(in srgb, var(--glacier-bg) 82%, transparent)'), borderRadius: radius),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: t.online)),
                  SizedBox(width: t.space(2)),
                  for (final id in inIt.take(3)) Padding(padding: EdgeInsetsDirectional.only(end: 2), child: RippleAvatar(name: v.nameOf(id), level: 0, size: 22)),
                  SizedBox(width: t.space(1)),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
                    child: Text(inIt.length == 1 ? '${v.nameOf(inIt.first)} in voice' : '${inIt.length} in voice', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
                  ),
                  SizedBox(width: t.space(2)),
                  GlacierPressable(
                    onPressed: onJoin,
                    semanticLabel: 'Join voice',
                    builder: (context, state) => Container(
                      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 2),
                      decoration: BoxDecoration(color: fill.withValues(alpha: state.pressed ? 0.85 : 1), borderRadius: radius),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        AppIcon(LucideMore.headphones, size: 14, wash: false, color: words),
                        SizedBox(width: t.space(1)),
                        Text('Join', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: words)),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}


/// How this device's connection to someone in a call stands, on their face (GMFB-4, @kevin: "show when users are
/// connected to the call so they and others know if they are having audio issues or if they are just not connected to
/// the call"): nothing while all is well; amber while connecting, reconnecting or slow; red where there is no way
/// through. Read aloud with the face.
class LinkBadge extends StatelessWidget {
  const LinkBadge({super.key, required this.id, required this.child, this.size = 40});

  /// Their id in the call (not `me`: this device has no connection to itself).
  final String id;
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final media = Voice.instance.media;
    if (media == null || id == 'me') return child;
    return ValueListenableBuilder<Map<String, PeerLink>>(
      valueListenable: media.links,
      builder: (context, links, _) {
        final link = links[id];
        final words = link?.words;
        if (link == null || words == null) return child;
        final t = context.tokens;
        final colour = link == PeerLink.failed ? t.danger : t.colorOf('#e08a1e');
        final dot = (size * 0.36).clamp(12.0, 20.0);
        return Semantics(
          label: words,
          child: Stack(clipBehavior: Clip.none, children: [
            child,
            PositionedDirectional(
              start: -2,
              bottom: -2,
              child: Container(
                key: ValueKey('link-$id-${link.name}'),
                width: dot,
                height: dot,
                decoration: BoxDecoration(color: colour, shape: BoxShape.circle, border: Border.all(color: t.color('app-paper'), width: 2)),
                alignment: Alignment.center,
                child: AppIcon(link == PeerLink.failed ? LucideMore.wifiOff : (link == PeerLink.poor ? Lucide.wifi : Lucide.loaderCircle), size: dot * 0.55, strokeWidth: 2.6, wash: false, color: const Color(0xFFFFFFFF)),
              ),
            ),
          ]),
        );
      },
    );
  }
}

/// What a person's row says of their connection, under their name; nothing while all is well (GMFB-4).
class LinkWords extends StatelessWidget {
  const LinkWords({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final media = Voice.instance.media;
    if (media == null || id == 'me') return const SizedBox.shrink();
    return ValueListenableBuilder<Map<String, PeerLink>>(
      valueListenable: media.links,
      builder: (context, links, _) {
        final link = links[id];
        final words = link?.words;
        if (link == null || words == null) return const SizedBox.shrink();
        final t = context.tokens;
        return Text(words, key: ValueKey('link-words-$id'), style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: link == PeerLink.failed ? t.danger : t.colorOf('#e08a1e')));
      },
    );
  }
}
