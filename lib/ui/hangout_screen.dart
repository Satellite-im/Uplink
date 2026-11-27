import '../circles/circles.dart' show Circles, CirclePerm, CircleSystemNote, CircleWelcome, slowModeLabel, slowModeLeft;
import 'package:flutter/foundation.dart' show listEquals;
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback, HardwareKeyboard, KeyDownEvent, KeyEvent, LogicalKeyboardKey, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../sms.dart' show Sms;
import '../art/app_icon.dart';
import 'chat_rail.dart';
import 'chat_rows.dart';
import 'notion_card.dart';
import 'link_cards.dart';
import '../notion/notion.dart' show NotionLink;
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../kit/semantic_colors.dart';
import '../voice/channels.dart';
import '../voice/hangout.dart';
import '../voice/mention_alerts.dart';
import '../voice/roles.dart';
import '../voice/open_space.dart';
import '../voice/voice.dart';
import '../voice/voice_changer.dart';
import 'call_float.dart' show CallPageMark;
import 'common.dart';
import 'connecting_banner.dart';
import 'emoji_picker.dart';
import 'emoji_suggestions.dart';
import 'plugin_note_card.dart';
import 'profile_card.dart';
import 'report_sheet.dart' show reportSpaceMessage;
import '../app_state.dart';
import '../backgrounds.dart';
import '../sms.dart' show Person;
import 'circles/circle_face.dart' show SpaceKindBadge, TitleBarMark, spaceKindIcon;
import '../reactions.dart' show reactionChoices;
import 'reaction_stickers.dart' show ReactionPickRow, ReactionStickers;
import 'circles/circle_welcome.dart' show CircleSystemLine, CircleWelcomeCard, ReadOnlyAdminLine, ReadOnlyFoot;
import 'circles/new_circle.dart' show circleHueInk;
import 'circles/members_drawer.dart' show showMembersDrawer;
import 'drawer_head.dart';
import 'composer_box.dart';
import 'dialup/bevel.dart';
import 'dialup/parts.dart' show DialupPanel;
import 'dialup/retro_button.dart';
import 'message_line.dart';
import 'translated_card.dart';
import '../plugins/plugin.dart' show MessageFacts;
import 'poof.dart';
import 'nav_bar.dart';
import 'open_space_view.dart';
import 'ripple_avatar.dart';
import 'shell.dart';
import '../snooze.dart';
import 'window_title.dart';
import 'skeleton.dart';
import 'space_designs/space_design.dart';
import 'split_handle.dart';
import 'sms_space_ui.dart';
import 'recording_ui.dart' show RecordingBanner;
import 'space_designs/call_plugins.dart' show CallPlugins;
import '../voice/recorder.dart' show CallRecorder;
import 'space_invite.dart';
import 'snooze_ui.dart';
import 'space_thread.dart';
import 'export_ui.dart';
import 'flat_line.dart';
import 'voice_screen.dart';
import 'jump_to_latest.dart';
import 'space_chat_files.dart';
import 'sticker_picker.dart';
import 'voice.dart' show VoiceRecorder, micRefusedWords, voiceProblem;
import '../files/file_platform.dart';
import '../files/files_store.dart' show FilesStore;
import '../stickers.dart' show stickerName;
import '../mentions.dart';
import '../me/me.dart' show Me;
import '../me/pictures.dart';
import 'mention_field.dart';
import 'poll_card.dart';
import 'verified_badge.dart';
import 'paste_images.dart';
import 'thread.dart' show LinkedText;
import 'schedule_ui.dart';
import '../scheduled.dart' show ScheduleTarget;
import '../l10n/words.dart';

/// A hangout: its chat, who is in it, and its call (Matt, 2026-11-15: "add a chat to hangouts so the whole group can
/// send messages to the hangout as well as voice and video"; roles: "Implement a permissions system similar to
/// discord for hangouts ... make default roles such as admin, moderator, member").
///
/// Out of the call it is the chat, with who is here and a way into voice at its top. In the call, a toggle chooses the
/// people or the chat, with the call's dock over either. The shield opens its roles (RolesScreen).
class HangoutScreen extends StatefulWidget {
  const HangoutScreen({super.key, required this.channel, this.onClose, this.inSidebar = false});
  final VoiceChannel channel;

  /// Opened in the list's place, under the pill: the chat's composer and the call's dock leave it room (Matt,
  /// 2026-11-15: "When opening a hangout the left side should show the chat with some space below reserved for the
  /// navbar controls").
  final bool inSidebar;

  /// Leaves the page where it is not a pushed route (the Voice tab showing it): back to the list.
  final VoidCallback? onClose;

  @override
  State<HangoutScreen> createState() => _HangoutScreenState();
}

/// A space's chat before its room can be opened (the relay server not reached yet): its messages in bones, and a line
/// over them saying what is being reached, an arc turning beside it (Matt, 2026-11-24: "show better loading states
/// with skeletal loaders and a connecting banner so it doesn't just seem like the app is frozen"). It was a title and
/// a sentence in the middle of an empty page, which looked the same whether the app was at work or stuck.
class _NoRoomYet extends StatelessWidget {
  const _NoRoomYet({required this.name, this.bottom = 0});
  final String name;

  /// The room kept clear at the foot (the composer's, the pill's).
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Stack(children: [
      Positioned.fill(child: SkeletonChat(label: 'Connecting to $name', faces: true, bottom: bottom)),
      PositionedDirectional(
        start: t.space(4),
        end: t.space(4),
        top: t.space(3),
        child: Center(heightFactor: 1, child: ConnectingPill(key: const ValueKey('space-connecting'), title: 'Connecting to $name…', detail: 'Reaching the relay server')),
      ),
    ]);
  }
}

class _HangoutScreenState extends State<HangoutScreen> {
  HangoutRoom? _room;
  String _tab = 'people';

  @override
  void initState() {
    super.initState();
    unawaited(Voice.instance.hold(widget.channel).then((r) {
      if (mounted) setState(() => _room = r);
    }));
  }

  @override
  void dispose() {
    unawaited(Voice.instance.release(widget.channel));
    super.dispose();
  }

  /// Joins the space's call (with the camera on for [video]), then shows it where this window shows a call.
  Future<void> _join({bool video = false}) async {
    try {
      await Voice.instance.join(widget.channel, video: video);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t join: ${e is StateError ? e.message : e}', tone: GlacierToastTone.danger);
      return;
    }
    if (!mounted) return;
    // Left while it was connecting (Leave is there from the first moment): there is no call to show.
    if (Voice.instance.session?.channel.room != widget.channel.room) return;
    // Where no shell draws the call: it opens as its page (lib/ui/space_designs).
    if (openSpaceCall(context)) return;
    // An open space stays where it was opened, its floor in this page with the call's controls over its foot: the
    // list beside it (a circle's spaces) is left as it is (Matt, 2026-11-23: "don't transform the server sidebar when
    // we enter to show the lists").
    if (widget.channel.kind == SpaceKind.open) return;
    // Beside the list a circle's space stays where it is, this page turning into the call over its chat (SpaceSplit),
    // the circle's list beside it as it was (Matt, 2026-11-23). A space of one's own goes to the Voice page, which
    // draws this same page for the call.
    if (AppShell.wideOf(context) && widget.channel.circle == null) AppShell.maybeOf(context)?.go('voice');
  }

  /// The call or the chat, on a phone: the people in the call, or the space's messages.
  Widget _callOrChat(Tokens t) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)),
        child: GlacierSegmentedControl(
          fullWidth: true,
          size: GlacierSegmentedSize.md,
          ariaLabel: 'People or chat',
          value: _tab,
          onValueChange: (x) => setState(() => _tab = x),
          options: [
            GlacierSegmentedOption(value: 'people', label: Semantics(label: 'People', child: AppIcon(Lucide.users, size: 18, wash: false))),
            GlacierSegmentedOption(value: 'chat', label: Semantics(label: 'Chat', child: AppIcon(LucideMore.messageCircle, size: 18, wash: false))),
          ],
        ),
      );

  /// The space's header, as a conversation's is (lib/ui/thread.dart): its kind's mark where a face goes, its name, and
  /// under it its description (Matt, 2026-11-17: "make the text header for spaces show the icon and the name and an
  /// area for a description of the channel so the header space taken up matches the space taken up on other areas like
  /// dms and telegram chats"). It sits in GhostPage's own bar, so it is the same height as theirs. Pressed, it opens the
  /// description for the owner and admins, and does nothing for anyone else.
  GhostPage _page(HangoutRoom? room, {required Widget body, List<Widget> actions = const []}) {
    final t = context.tokens;
    final c = widget.channel;
    final line = spaceHeaderLine(c, room);
    final edit = room != null && room.canManage ? () => editSpaceAbout(context, room) : null;
    final live = c.hasVoice && Voice.instance.inChannel(c).isNotEmpty;
    return GhostPage(
      title: c.name,
      actions: actions,
      // Dial-Up draws its own title bar and leaves titleWidget out: the line and the mark go there instead.
      subtitle: line,
      onTitle: edit,
      titleLeading: TitleBarMark(icon: spaceKindIcon(c.kind), child: SpaceKindBadge(kind: c.kind, size: 18, live: live)),
      titleWidget: GlacierPressable(
        onPressed: edit,
        builder: (context, state) => Row(children: [
          SpaceKindBadge(kind: c.kind, size: t.lenOf('2.1rem'), live: live),
          SizedBox(width: t.space(2)),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold')),
              Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            ]),
          ),
        ]),
      ),
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    final room = _room ?? v.hangoutFor(widget.channel);
    // The window is named for the space while it is open, where no circle of its names it first
    // (lib/ui/window_title.dart).
    // In this space's call the page is the call's: nothing floats over it while it is on the screen (GMFB-64).
    return WindowTitle(name: widget.channel.name, child: ListenableBuilder(
      listenable: v,
      builder: (context, page) => CallPageMark(on: v.session?.channel.room == widget.channel.room && !widget.inSidebar, child: page!),
      child: ListenableBuilder(
      // The recorder too: Record call's icon in the header goes to Stop as it starts.
      listenable: Listenable.merge([v, ?room, CallRecorder.instance, OpenSpaces.instance]),
      builder: (context, _) {
        final s = v.session?.channel.room == widget.channel.room ? v.session : null;
        // In the call on a narrow phone: the call's page is the page (space_design.dart).
        // An open space is its own page, the floor (lib/ui/open_space_view.dart): the call's page is not drawn in its
        // place (inlineSpaceCall asks OpenSpaces.isCall).
        final open = OpenSpaces.isCall(s);
        final callPage = inlineSpaceCall(context, s);
        if (callPage != null) return callPage;
        final pad = MediaQuery.paddingOf(context).bottom;
        final wide = AppShell.wideOf(context);
        // Under the pill in the list's place: what stands at the foot (the composer, the dock) stands above it.
        final pill = widget.inSidebar ? AppShell.pillRoom(context) : 0.0;
        final dockAt = pad + (widget.inSidebar ? pill : NavPill.inset(t));
        // A circle's space beside the circle's list (a wide window): the list's own Invite stands just beside it, so the
        // space's page leaves its own out rather than show two of the same button side by side.
        final besideCircle = wide && widget.channel.circle != null;
        final actions = [
          // Members: in a circle's space where the shield for its settings was (Matt, 2026-11-20: "remove the shield icon for
          // the quick space settings, instead show a members icon there and list the memebers in a given space within the
          // circle"), the circle's settings having the space's own; outside a circle beside the shield as before.
          if (room != null && widget.channel.circle == null) _membersButton(context, room),
          if ((room == null || room.can(Perm.invite)) && _circleInvites(widget.channel) && !besideCircle) IconTap(icon: Lucide.userPlus, label: 'Invite people', onPressed: () => showSpaceInvite(context, widget.channel)),
          // An SMS space: who is in it by text (lib/ui/sms_space_ui.dart).
          if (smsSpaceOf(widget.channel) != null) IconTap(icon: Lucide.smartphone, label: 'People by text', onPressed: () => push(context, (_) => TextedPeopleScreen(space: widget.channel))),
          // The plugins' own (Slots.spaceHeader): Record call's record and stop while in its call, Live captions'.
          for (final x in CallPlugins.header(widget.channel))
            IconTap(icon: x.icon, label: x.label, color: x.danger ? RecordingBanner.red : null, onPressed: () => x.run(context)),
          if (room != null && widget.channel.circle != null) _membersButton(context, room),
          if (room != null && widget.channel.circle == null) IconTap(icon: Lucide.shieldCheck, label: 'Space settings', onPressed: () => push(context, (_) => RolesScreen(room: room, settings: true))),
        ];
        if (room?.putOut != null) {
          return _page(
            room,
            body: Padding(padding: EdgeInsets.all(t.space(4)), child: SettingsCallout(child: Text(room!.putOut!))),
          );
        }
        // In a call on a phone the chat is a tab: while it is shown the call's controls are not, and the composer stands at
        // the foot as every conversation's does (Matt, 2026-11-15: "when we switch to chat please don't show the call
        // controls just make it appear like the bottom of all the compose windows look").
        final bottom = pill + (s != null && (wide || _tab != 'chat') ? NavPill.clearance(t) : 0);
        // Before the relay is reached there is no room yet: say so, rather than a bare title over nothing.
        Widget chatOver(double bottom) => room == null
            ? _NoRoomYet(name: widget.channel.name, bottom: bottom)
            : room.waitingForKey
                // The circle's key changed and this device hasn't got the new one yet (GMFB-26): what is written waits.
                ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(1)),
                      child: Text('Waiting for the circle\'s new key. What you write goes once it arrives.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                    ),
                    Expanded(child: HangoutChat(room: room, bottom: bottom)),
                  ])
                : HangoutChat(room: room, bottom: bottom);
        final chat = chatOver(bottom);
        // A texting or Files space has no call: no Join, no one "in voice", just its chat (SpaceKind). So has every
        // space in a browser, which has no calls yet (Sms.callsHere).
        if (s == null && (!widget.channel.hasVoice || !Sms.callsHere)) {
          return _page(room, actions: actions, body: chat);
        }
        if (s == null) {
          // Out of the call: who is here, a way in, and the chat.
          final here = room?.present.values.toList() ?? const <HangoutPerson>[];
          final inVoice = v.inChannel(widget.channel);
          // Dial-Up: on the window's silver, and who is in voice, as "People Here" under it lists them by name.
          final dialup = isDialup(context);
          final row = Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)),
            child: Row(children: [
              // Who is connected: their faces, then their names.
              for (final id in inVoice.take(4))
                Padding(padding: EdgeInsetsDirectional.only(end: t.space(1)), child: RippleAvatar(name: v.nameOf(id), level: 0, size: 30)),
              if (inVoice.isNotEmpty) SizedBox(width: t.space(1)),
              Expanded(
                child: Text(
                  inVoice.isEmpty ? (here.isEmpty || dialup ? 'Nobody in voice' : '${here.length} here · nobody in voice') : '${inVoice.length} connected · ${inVoice.map(v.nameOf).join(', ')}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
                ),
              ),
              SizedBox(width: t.space(2)),
              _JoinButton(onPressed: () => _join(), busy: v.joining?.room == widget.channel.room),
            ]),
          );
          // On a phone, with people talking in it: the call first, who is in it and Join, and the chat a tap away
          // (Matt, 2026-11-17: open "as a normal chat window when there are no people online and chatting", and
          // "switch between the call and chat UI"). Nobody in it: the chat, as any conversation opens.
          if (!wide && !dialup && inVoice.isNotEmpty) {
            return _page(
              room,
              actions: actions,
              body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _callOrChat(t),
                Expanded(
                  child: _tab == 'chat'
                      ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [row, Expanded(child: chat)])
                      : _WhoIsTalking(ids: inVoice, nameOf: (id) => (room?.present[id]?.name ?? '').isNotEmpty ? room!.present[id]!.name : v.nameOf(id), onJoin: () => _join(), busy: v.joining?.room == widget.channel.room),
                ),
              ]),
            );
          }
          return _page(
            room,
            actions: actions,
            body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              dialup ? ColoredBox(color: DialupColors.of(t).chrome, child: row) : row,
              Expanded(child: chat),
            ]),
          );
        }
        // In the call beside the list (a computer, a wide phone): this page, in the pane, is the call on top and the
        // space's chat under it, the list beside it left as it is (Matt, 2026-11-23: "a 66% top view with the third
        // screenshot content at the top and the chat and compose bar at the bottom leaving the sidebar unchanged so
        // you can still quickly navigate the circle"). The call's page draws the call: its own header, its people and
        // its buttons, with no Chat panel of its own.
        if (wide && !open) {
          return ColoredBox(
            color: t.color('glacier-bg'),
            child: SpaceSplit(
              call: SpaceCallPage(key: ValueKey('split-call-${s.channel.room}'), inline: true, chatBelow: true),
              chat: chatOver(pill),
            ),
          );
        }
        // An open space's here too is its floor, as on a phone: this page is the pane beside a circle's list.
        if (wide) {
          return _page(
            room,
            actions: actions,
            body: Stack(children: [
              // The call's buttons at the floor's left foot and the chat's box at its right, on one line (Matt,
              // 2026-11-23: "left justify the call controls and right justify the compose input").
              OpenSpaceFloor(session: s, bottomInset: dockAt + NavPill.clearance(t), sayBeside: dockAt),
              PositionedDirectional(start: t.space(3), bottom: dockAt, child: CallDock(session: s)),
            ]),
          );
        }
        // In an open space's call on a phone (any other space's is the call's page, above): its floor or its chat, and
        // the dock over the floor's foot.
        return _page(
          room,
          actions: actions,
          body: Stack(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _callOrChat(t),
              Expanded(child: _tab == 'chat' ? chat : OpenSpaceFloor(session: s, bottomInset: dockAt + NavPill.clearance(t))),
            ]),
            if (_tab != 'chat') PositionedDirectional(start: 0, end: 0, bottom: dockAt, child: Center(child: CallDock(session: s))),
          ]),
        );
      },
    )));
  }
}

/// A hangout's call beside the list on a wide screen: its chat, and once anyone turns on video, the videos in the top
/// half and the chat in the bottom (Matt, 2026-11-15: "when a video starts split the right side 50/50 showing the
/// videos above the chat"). The people and the dock are in the list's place (HangoutScreen).
class HangoutStage extends StatefulWidget {
  const HangoutStage({super.key, required this.channel});
  final VoiceChannel channel;

  @override
  State<HangoutStage> createState() => _HangoutStageState();
}

class _HangoutStageState extends State<HangoutStage> {
  HangoutRoom? _room;

  @override
  void initState() {
    super.initState();
    unawaited(Voice.instance.hold(widget.channel).then((r) {
      if (mounted) setState(() => _room = r);
    }));
  }

  @override
  void dispose() {
    unawaited(Voice.instance.release(widget.channel));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    final room = _room ?? v.hangoutFor(widget.channel);
    final media = v.media;
    return ListenableBuilder(
      listenable: Listenable.merge([v, ?room, ?media?.remote, ?media?.localVideo, ?media?.localScreen, ?v.session, OpenSpaces.instance]),
      builder: (context, _) {
        final s = v.session?.channel.room == widget.channel.room ? v.session : null;
        final chat = room == null ? const SizedBox.shrink() : HangoutChat(room: room);
        final videos = s != null && CallVideos.any(s);
        // In an open space's call: its floor over the chat, as the videos are (lib/ui/open_space_view.dart).
        final open = OpenSpaces.isCall(s);
        return GhostPage(
          title: 'Chat',
          back: false,
          actions: [
            // Members: in a circle's space where the shield for its settings was (Matt, 2026-11-20: "remove the shield icon for
          // the quick space settings, instead show a members icon there and list the memebers in a given space within the
          // circle"), the circle's settings having the space's own; outside a circle beside the shield as before.
          if (room != null && widget.channel.circle == null) _membersButton(context, room),
            if ((room == null || room.can(Perm.invite)) && _circleInvites(widget.channel)) IconTap(icon: Lucide.userPlus, label: 'Invite people', onPressed: () => showSpaceInvite(context, widget.channel)),
            // An SMS space: who is in it by text (lib/ui/sms_space_ui.dart).
            if (smsSpaceOf(widget.channel) != null) IconTap(icon: Lucide.smartphone, label: 'People by text', onPressed: () => push(context, (_) => TextedPeopleScreen(space: widget.channel))),
            if (room != null && widget.channel.circle != null) _membersButton(context, room),
            if (room != null && widget.channel.circle == null) IconTap(icon: Lucide.shieldCheck, label: 'Space settings', onPressed: () => push(context, (_) => RolesScreen(room: room, settings: true))),
          ],
          body: open
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // The list beside it is the circle's own, untouched (Matt, 2026-11-23: "don't take over the sidebar
                  // leave it the standard sidebar for the circle"), so the call's buttons stand on the floor here too.
                  Expanded(
                    flex: 3,
                    child: Stack(children: [
                      Positioned.fill(child: OpenSpaceFloor(session: s!, bottomInset: t.space(3) + NavPill.clearance(t), sayBeside: t.space(3))),
                      PositionedDirectional(start: t.space(3), bottom: t.space(3), child: CallDock(session: s)),
                    ]),
                  ),
                  if (videos) ...[
                    Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
                    SizedBox(height: 200, child: Padding(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(2)), child: CallVideos(session: s))),
                  ],
                  Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
                  Expanded(flex: 2, child: chat),
                ])
              : videos
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(child: Padding(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)), child: CallVideos(session: s))),
                  Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
                  Expanded(child: chat),
                ])
              : chat,
        );
      },
    );
  }
}

/// A space's call in a computer's pane, beside the list: the call on top, two thirds of the pane, and the space's chat
/// under it with its composer (Matt, 2026-11-23: "a 66% top view with the third screenshot content at the top and the
/// chat and compose bar at the bottom"). The line between them is dragged up or down, and where it was left is kept
/// with the device's choices; a double click puts it back at two thirds. However short the window, the chat keeps room
/// for its composer and a few lines.
class SpaceSplit extends StatefulWidget {
  const SpaceSplit({super.key, required this.call, required this.chat});
  final Widget call, chat;

  /// The call's share of the pane, as dragged, under this name in the device's choices.
  static const pref = 'space_split_call';

  /// Whether the chat under the call is shown, under this name in the device's choices: on unless it was put away with
  /// the Chat button beside Leave (Matt, 2026-11-24: "add a button next to the leave button for hiding and showing the
  /// chat"). Put away, the call has the whole pane, and stays so for every space until the button brings it back.
  static const chatPref = 'space_split_chat';
  ///
  /// The button is Share screen now (Matt, 2026-11-25: "replace the who hide chat button with a share screen
  /// button"), so nothing puts the chat away any more and it is always shown: a device that had it put away gets it
  /// back, and the choice it kept is no longer read.
  static bool chatShown(AppState? app) => true;

  /// Two thirds, as Matt asked.
  static const share = 0.66;

  /// The least the chat keeps (its composer and a few lines) and the least the call does, where the pane has room.
  static const chatLeast = 200.0;
  static const callLeast = 240.0;

  /// The call's height in a pane [high] tall, at [share] of it: no more than leaves the chat [chatLeast], and no less
  /// than [callLeast] (or, in a pane too short for both, a third of it).
  static double callHeight(double high, double share) {
    final most = math.max(high - chatLeast, high / 3);
    final least = math.min(callLeast, most);
    return (high * share).clamp(least, most);
  }

  @override
  State<SpaceSplit> createState() => _SpaceSplitState();
}

class _SpaceSplitState extends State<SpaceSplit> {
  /// The call's share as being dragged; null for what is kept (or two thirds).
  double? _share;

  double _kept(AppState? app) => (double.tryParse(app?.choice(SpaceSplit.pref, '') ?? '') ?? SpaceSplit.share).clamp(0.2, 0.9);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.maybeOf(context);
    final shown = SpaceSplit.chatShown(app);
    return LayoutBuilder(builder: (context, box) {
      final high = box.maxHeight;
      // With the chat put away the call has the whole pane, and there is no line to drag. The call stays the same
      // first child either way, so nothing of it is made again as the chat goes and comes.
      final top = shown ? SpaceSplit.callHeight(high, _share ?? _kept(app)) : high;
      final grip = SplitHandle.widthOf(context);
      return Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(key: const ValueKey('space-split-call'), height: top, child: widget.call),
          if (shown) Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
          if (shown) Expanded(key: const ValueKey('space-split-chat'), child: widget.chat),
        ]),
        if (shown) PositionedDirectional(
          key: const ValueKey('space-split-handle'),
          start: 0,
          end: 0,
          top: top - grip / 2,
          height: grip,
          child: SplitHandle(
            vertical: true,
            label: 'Resize the call and the chat',
            onDrag: (dy) => setState(() => _share = SpaceSplit.callHeight(high, (_share ?? top / high) + dy / high) / high),
            onDone: () {
              final now = _share;
              if (now != null) app?.set(SpaceSplit.pref, now.toStringAsFixed(3));
            },
            onReset: () {
              setState(() => _share = null);
              app?.set(SpaceSplit.pref, '');
            },
          ),
        ),
      ]);
    });
  }
}

/// Who is in a space's call, seen from outside it on a phone: each face and name. Tapping them joins the call (Matt,
/// 2026-11-17: "remove the join voice and video chat button ... just make tapping on the list of people join the call
/// automatically").
class _WhoIsTalking extends StatelessWidget {
  const _WhoIsTalking({required this.ids, required this.nameOf, required this.onJoin, this.busy = false});
  final List<String> ids;

  /// What each goes by: the name they gave the space's room, or the call's.
  final String Function(String id) nameOf;
  final VoidCallback onJoin;

  /// The call is being come into (Voice.joining): it says so, and takes no second press.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final face = t.lenOf('3rem');
    return GlacierPressable(
      onPressed: busy ? null : onJoin,
      semanticLabel: busy ? 'Joining the call' : 'Join the call with ${ids.length} in it',
      builder: (context, state) => ListView(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), MediaQuery.paddingOf(context).bottom + NavPill.clearance(t) + t.space(4)),
      children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: t.online)),
          SizedBox(width: t.space(2)),
          Text(ids.length == 1 ? '1 in voice' : '${ids.length} in voice', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.online)),
        ]),
        SizedBox(height: t.space(3)),
        for (final id in ids)
          Padding(
            padding: EdgeInsets.only(bottom: t.space(2)),
            child: Row(children: [
              RippleAvatar(name: nameOf(id), level: 0, size: face),
              SizedBox(width: t.space(3)),
              Expanded(child: Text(nameOf(id), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink')))),
            ]),
          ),
        SizedBox(height: t.space(1)),
        if (busy)
          Row(children: [
            const SizedBox.square(dimension: 16, child: GhostSpinner(size: 14)),
            SizedBox(width: t.space(2)),
            Text('Joining…', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-2'))),
          ])
        else
          Text('Tap to join', style: pageText(t, t.fontSize('sm'), color: t.color(state.pressed ? 'app-ink-2' : 'app-ink-3'))),
      ],
      ),
    );
  }
}

/// Join voice: a pill filled with ink, the headphones and the words.
class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.onPressed, this.busy = false});
  final VoidCallback onPressed;

  /// The call is being come into (Voice.joining): the button says so and takes no second press. It shows where the
  /// call itself is not on the screen yet, while another call is being left first.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final label = busy ? 'Joining…' : 'Join voice';
    // Dial-Up's is a raised silver button like the rest of its window's (lib/ui/dialup/retro_button.dart).
    if (isDialup(context)) return RetroButton(onPressed: busy ? () {} : onPressed, icon: LucideMore.headphones, label: label);
    final (fill, words) = strongFill(t);
    return GlacierPressable(
      onPressed: busy ? null : onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
        decoration: BoxDecoration(color: fill.withValues(alpha: state.pressed || busy ? 0.85 : 1), borderRadius: BorderRadius.circular(t.radius('full'))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy) const SizedBox.square(dimension: 16, child: GhostSpinner(size: 14)) else AppIcon(LucideMore.headphones, size: 16, wash: false, color: words),
          SizedBox(width: t.space(2)),
          Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: words)),
        ]),
      ),
    );
  }
}

/// A hangout's chat: its messages, newest at the foot, and the composer, which says why where this device may not
/// write. A message held down offers to delete it where this device may.
class HangoutChat extends StatefulWidget {
  const HangoutChat({super.key, required this.room, this.bottom = 0, this.uploads, this.circles});
  final HangoutRoom room;

  /// Room left under the composer (the call's dock).
  final double bottom;

  /// What sends the chat's files up (the app's FilesStore), and the circles whose roles say who may (the app's): a
  /// test's own in a test.
  final ChatUploads? uploads;
  final Circles? circles;

  @override
  State<HangoutChat> createState() => _HangoutChatState();
}

class _HangoutChatState extends State<HangoutChat> {
  /// The words being written, and who the "@Name"s in them mean (lib/ui/mention_field.dart).
  final _text = MentionController();
  late final _focus = FocusNode(onKeyEvent: _mentionKeys);

  /// The emoji a ":jo" being written finds, over the box, and a whole ":joy:" put in as 😂 (lib/ui/emoji_suggestions.dart;
  /// GMFB-22, Matt, Mac 0.12.6: "typing :joy: or something should expand the emoji to the joy emoji and auto suggest
  /// with a popup").
  late final EmojiShortcodeSuggester _shortcodes;

  /// The "@…" being written and the people it finds, while the list over the composer is open; which of them is
  /// chosen for Enter; and the query Escape closed it on, which keeps it closed until the query changes.
  MentionQuery? _query;
  List<MentionPerson> _found = const [];
  int _chosen = 0;
  MentionQuery? _closedOn;

  /// Where this space's chat was left, and its list's controller, which starts there (lib/ui/jump_to_latest.dart; Matt,
  /// 2026-11-17: "remember the scroll position when switching between chats"). The page can stay as the room changes
  /// (didUpdateWidget): the arrow then keeps the old room's spot and puts the list at the new one's, and a list made
  /// afresh for the new room (after its "No messages yet") starts at the new room's spot, since the controller asks
  /// which room it is each time a list takes it up.
  String get _spot => 'space:${widget.room.channel.room}';
  late final ScrollController _scroll = ScrollMemory.controllerFor(() => _spot);

  /// What others wrote, newest first, for the arrow to count while the person reads back.
  Iterable<Object> _incoming(HangoutRoom room) => room.timeline.reversed.where((m) => m.from != room.me).map((m) => m.id);
  bool _typing = false;

  /// Messages going in a puff, deleted once it has gone off (lib/ui/poof.dart).
  final Set<String> _poofing = {};

  /// Who came into the room and who left while it was open here, for Dial-Up's Host lines ("Riley has entered the
  /// room."): kept by this page alone, as the era's transcripts were, so they start empty each time it is opened.
  final List<({int at, String id, bool came})> _comings = [];

  /// Who was here at the room's last change (null until it is joined), and the names they gave, kept for saying who left.
  Set<String>? _here;
  final Map<String, String> _names = {};

  /// Dial-Up's "People Here" opened out under its strip, on a phone.
  bool _peopleOpen = false;

  /// The thread open beside the chat in a wide window (GMFB-36): the message it hangs from, or null.
  HangoutMessage? _threadRoot;

  /// The message a snooze's reminder asked to be shown, and the key its row is built under while it is looked for.
  String? _shownId;
  final _shownKey = GlobalKey();

  /// This chat's key among snoozes (lib/snooze.dart): a space's chat in Messages is snoozed under the same.
  String get _snoozeKey => Snoozed.space(widget.room.channel.room);

  /// Whether a thread opens beside the chat: in a wide window, the list and the pane side by side (AppShell.wideAt),
  /// or one as wide where there is no shell (the web's own frame, a test). On a phone it opens as its page.
  bool get _threadsBeside {
    if (AppShell.maybeOf(context) != null) return AppShell.wideOf(context);
    return MediaQuery.sizeOf(context).width >= AppShell.wideAt;
  }

  /// Opens [m]'s thread: beside the chat in a wide window, as its page on a phone.
  void _openThread(HangoutMessage m) {
    if (_threadsBeside) {
      setState(() => _threadRoot = m);
    } else {
      openThread(context, widget.room, m);
    }
  }

  /// Shows message [id], a snooze's reminder pressed: a reply in a thread opens its thread; any other is scrolled to.
  void _showMessage(String id) {
    final room = widget.room;
    final m = room.messages.where((x) => x.id == id).firstOrNull;
    if (m == null) {
      toast(context, 'That message isn\'t here any more');
      return;
    }
    final root = m.thread == null ? null : room.messages.where((x) => x.id == m.thread).firstOrNull;
    if (root != null) return _openThread(root);
    setState(() => _shownId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final found = await scrollToShown(_scroll, _shownKey);
      if (!found && mounted) toast(context, 'That message is too far back to find');
    });
  }

  /// What is shown here is read: its unread mark in the list goes (Voice.markRead), and a mention in it is not
  /// notified while it is on the screen.
  void _read() {
    MentionAlerts.showing = widget.room.channel.seed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Voice.instance.markRead(widget.room.channel);
    });
  }

  /// The room changed: what shows is read, the names people gave are kept, and who came and who left since the last
  /// change are noted (the newest 200). [first] is the call made as the page takes the room up.
  void _roomChanged({bool first = false}) {
    _read();
    final room = widget.room;
    for (final p in room.present.values) {
      if (p.name.isNotEmpty) _names[p.id] = p.name;
    }
    if (!room.opened) {
      _here = null;
      return;
    }
    // Who "People Here" lists but you: in a space with a call, who is in the call (_inCall).
    final now = _callSpace(room) ? _inCall(room) : {for (final id in room.present.keys) if (id != room.me) id};
    final was = _here;
    if (was == null) {
      // Who is here on joining is what "People Here" says; only later changes are comings and goings. Opened with
      // nobody listed yet, the list joining brings is still on its way (HangoutRoom.open): the next change is it.
      if (!(first && now.isEmpty)) _here = now;
      return;
    }
    _here = now;
    final at = DateTime.now().millisecondsSinceEpoch;
    for (final id in now.difference(was)) {
      _comings.add((at: at, id: id, came: true));
    }
    for (final id in was.difference(now)) {
      _comings.add((at: at, id: id, came: false));
    }
    if (_comings.length > 200) _comings.removeRange(0, _comings.length - 200);
  }

  /// The call's people changed: in a space with a call they are who "People Here" lists, and who comes and goes.
  void _voiceChanged() {
    if (mounted && _callSpace(widget.room)) _roomChanged();
  }

  /// Whether [room] is a space with a call, where "People Here" is the call's people: not a texting or Files space,
  /// and not in a browser, which has no calls yet (Sms.callsHere).
  static bool _callSpace(HangoutRoom room) => room.channel.hasVoice && Sms.callsHere;

  /// Who but you is in [room]'s call: who the call says is, and whoever says so themselves here before the call's word
  /// of them comes.
  static Set<String> _inCall(HangoutRoom room) {
    final v = Voice.instance;
    return <String>{...v.inChannel(room.channel), for (final p in room.present.values) if (p.inVoice) p.id}..removeAll({room.me, v.me, 'me'});
  }

  /// A person's name for a coming or a going: as they say it now, else as they last said it here, else as Voice
  /// knows them.
  String _nameOf(String id) {
    final said = widget.room.present[id]?.name ?? '';
    return said.isNotEmpty ? said : (_names[id] ?? Voice.instance.nameOf(id));
  }

  @override
  void didUpdateWidget(HangoutChat old) {
    super.didUpdateWidget(old);
    if (old.room != widget.room) {
      old.room.removeListener(_roomChanged);
      _comings.clear();
      _here = null;
      _threadRoot = null;
      _shownId = null;
      widget.room.addListener(_roomChanged);
      _roomChanged(first: true);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.room.addListener(_roomChanged);
    Voice.instance.addListener(_voiceChanged);
    _roomChanged(first: true);
    // Opened from a snoozed message's notification (lib/main.dart): that message, once the chat is drawn.
    final show = Snoozed.instance.takeShow(_snoozeKey);
    if (show != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _showMessage(show) : null);
    _shortcodes = EmojiShortcodeSuggester(_text, app: () => mounted ? AppState.maybeOf(context) : null);
    // The composer lays itself out by whether there are words (lib/ui/composer_box.dart).
    _text.addListener(() {
      final typing = _text.text.isNotEmpty;
      if (typing != _typing && mounted) setState(() => _typing = typing);
      _findMentions();
    });
  }

  @override
  void dispose() {
    if (MentionAlerts.showing == widget.room.channel.seed) MentionAlerts.showing = null;
    widget.room.removeListener(_roomChanged);
    Voice.instance.removeListener(_voiceChanged);
    _slowTimer?.cancel();
    _shortcodes.dispose();
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Files chosen to go with the next message, and a voice message being recorded: its most seconds (Matt,
  /// 2026-11-18: "I also want full support for uploading attachements gifs stickers etc like we support in other chats").
  final List<({String path, bool owned})> _picked = [];
  int? _recording;

  ChatUploads get _uploads => widget.uploads ?? FilesStore.instance;
  bool get _mayAttach => spaceMayAttach(widget.room, circles: widget.circles);

  /// The message whose words are in the box to be changed, or null (Matt, 2026-11-20: "I'd like to be able to edit
  /// messages sent in circles from any computer or phone connected to the account that sent it").
  HangoutMessage? _editing;

  /// The message the next one answers, shown over the box (GMFB-13), or null.
  SpaceReply? _replying;

  /// Makes the next message an answer to [m], in place of any edit under way, and puts the cursor in the box.
  void _startReply(HangoutMessage m) {
    if (!widget.room.mayWrite) return;
    setState(() {
      _replying = SpaceReply.of(m);
      _editing = null;
    });
    _focus.requestFocus();
  }

  void _stopReplying() => setState(() => _replying = null);

  void _startEdit(HangoutMessage m) {
    if (!widget.room.canEdit(m)) return;
    setState(() {
      _editing = m;
      _replying = null;
      _picked.clear();
    });
    _text.load(m.text, m.mentions);
    _focus.requestFocus();
  }

  void _stopEditing() {
    setState(() => _editing = null);
    _text.clear();
  }

  /// Send: saves the message being edited, else sends the files picked with the words, else the words alone. Nothing
  /// goes while slow mode's wait is still running; the box is cleared only once the room has taken it.
  void _send() {
    final room = widget.room;
    final editing = _editing;
    if (editing != null) {
      // Saved; unchanged words just stop the editing.
      room.edit(editing, _text.text, mentions: _text.mentions);
      _stopEditing();
      return;
    }
    if (_slowLeft > Duration.zero) return;
    if (_picked.isNotEmpty) {
      if (!_mayAttach) {
        toast(context, 'Your role here can\'t send files.', tone: GlacierToastTone.danger);
        return;
      }
      if (room.sendFiles(List.of(_picked), _uploads, text: _text.text, mentions: _text.mentions, reply: _replying) != null) {
        setState(() {
          _picked.clear();
          _replying = null;
        });
        _text.clear();
      }
      return;
    }
    if (room.send(_text.text, mentions: _text.mentions, reply: _replying)) {
      _text.clear();
      if (_replying != null) setState(() => _replying = null);
    }
  }

  // --- mentions (Matt, 2026-11-19: "Add mentions support to spaces and circles with the @user prefix") ------------

  /// Who can be mentioned here: everyone the space knows (its members list's people), whoever has written in it, and
  /// in a circle its members; not you, not the banned.
  List<MentionPerson> _mentionable() {
    final room = widget.room;
    final last = <String, int>{};
    for (final m in room.messages) {
      last[m.from] = m.at;
    }
    final ids = <String>{...spacePeopleByRole(room).values.expand((l) => l), ...last.keys, ...spaceCircleMembers(room)}
      ..remove(room.me)
      ..removeWhere((id) => id.isEmpty || room.roster.banned.contains(id));
    // One person's phone and computer are two installs here: offered once, as the one here now (else the one that
    // wrote last). Your own other install is not offered at all.
    final people = <MentionPerson>[];
    final byUser = <String, int>{};
    for (final id in ids) {
      final user = room.present[id]?.username ?? room.usernames[id];
      if (user != null && user.isNotEmpty && user == room.username) continue;
      final p = MentionPerson(id: id, name: spaceNameOf(room, id), username: user, here: room.present.containsKey(id), last: last[id] ?? 0, role: room.roster.roleOf(id));
      final had = user == null || user.isEmpty ? null : byUser[user];
      if (had == null) {
        if (user != null && user.isNotEmpty) byUser[user] = people.length;
        people.add(p);
      } else if ((p.here && !people[had].here) || (p.here == people[had].here && p.last > people[had].last)) {
        people[had] = p;
      }
    }
    return people;
  }

  /// The list over the composer, as the words and the cursor are now.
  void _findMentions() {
    final q = _text.query;
    final found = q == null || q == _closedOn ? const <MentionPerson>[] : matchMentions(q.text, _mentionable());
    if (q != _closedOn) _closedOn = null;
    if (q == _query && listEquals(found.map((p) => p.id).toList(), _found.map((p) => p.id).toList())) return;
    if (!mounted) return;
    setState(() {
      _query = found.isEmpty ? null : q;
      _found = found;
      if (_chosen >= found.length || q?.start != _query?.start) _chosen = 0;
    });
  }

  /// Someone chosen from the list over the composer: their mention takes the place of the "@…" being written.
  void _pickMention(MentionPerson p) {
    final q = _query;
    if (q == null) return;
    _text.pick(q, p);
    _focus.requestFocus();
  }

  /// The app's own emoji picker (lib/ui/emoji_picker.dart; Matt, 2026-11-19: "roll an in house emoji picker"): each
  /// emoji picked goes in where the cursor is, and the box has the typing again once it is put away. Before it, the
  /// computer's own panel, which opened on nothing where the box had no focus yet.
  Future<void> _emoji() async {
    await showEmojiPicker(context, onPick: (e) => insertEmoji(_text, e));
    if (mounted) _focus.requestFocus();
  }

  /// The box's keys: Escape out of editing, the mention list's own keys while it is open, and Enter otherwise.
  KeyEventResult _mentionKeys(FocusNode node, KeyEvent e) {
    // Escape stops editing a message, its words given back.
    if (_editing != null && _query == null && !_shortcodes.open && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      _stopEditing();
      return KeyEventResult.handled;
    }
    // The emoji list over the box has the keys while it is open: Enter there picks, it does not send.
    if (_query == null) return _shortcodes.key(e) ?? _enterKey(e);
    return mentionKey(
          e,
          count: _found.length,
          chosen: _chosen,
          choose: (i) => setState(() => _chosen = i),
          pick: () => _pickMention(_found[_chosen]),
          close: () {
            _closedOn = _text.query;
            setState(() {
              _query = null;
              _found = const [];
            });
          },
        ) ??
        _enterKey(e);
  }

  /// Enter sends on a keyboard where Settings › Messages › Enter sends is on, Shift+Enter starting a new line (Matt,
  /// 2026-11-19: "Pressing enter isn't sending messages on desktop in circles"). Taken here rather than left to the
  /// platform's text input, which turned Enter into a new line in a space's box on a computer. Not while a word is
  /// still being composed (an input method's Enter chooses it).
  KeyEventResult _enterKey(KeyEvent e) {
    if (e is! KeyDownEvent || (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.numpadEnter)) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed || !AppState.of(context).enterSends || _text.value.composing.isValid) return KeyEventResult.ignored;
    _send();
    return KeyEventResult.handled;
  }

  /// A mention pressed in a message: who it is, with a way to mention them back and the space's members.
  /// Their profile card (Matt, 2026-11-19: "when clicking on a @mention anywhere ... show this profile popup with actions
  /// available for the user in context of where it's placed"): here, mention them back and the space's members too.
  void _mentionPressed(Mention m) => _openPerson(m.id);

  /// [id]'s profile card, from their mention, their face or their name in a message (Matt, 2026-11-19: "Clicking on a
  /// users profile picture or name should open the profile drawer as well"): here, mention them back and the space's
  /// members too.
  void _openPerson(String id) {
    final room = widget.room;
    showProfile(
      context,
      ProfileSubject.ghost(
        id: id,
        name: spaceNameOf(room, id),
        room: room,
        onMention: id == room.me || !room.mayWrite
            ? null
            : () {
                _text.mention(MentionPerson(id: id, name: spaceNameOf(room, id)));
                _focus.requestFocus();
              },
      ),
      more: [Choice('Members', Lucide.users, () => showSpaceMembers(context, room))],
    );
  }

  // --- slow mode (Matt, 2026-11-19: "add ... slow mode"; lib/circles/slow_mode.dart) ----------------------------------

  /// This space's wait between this person's messages, in seconds; 0 where there is none for them.
  int get _slowSeconds => (widget.circles ?? Circles.instance).slowModeFor(widget.room.channel);

  /// How long until this person may write here again: none where slow mode is off or they wrote long enough ago.
  Duration get _slowLeft {
    final secs = _slowSeconds;
    if (secs == 0) return Duration.zero;
    final room = widget.room;
    final last = room.messages.lastWhere((m) => m.from == room.me, orElse: () => const HangoutMessage(id: '', from: '', name: '', text: '', at: 0)).at;
    final left = last + secs * 1000 - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  /// Redraws the countdown each second while there is one.
  Timer? _slowTimer;
  void _tickSlowMode() {
    _slowTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() {});
      if (_slowLeft <= Duration.zero) {
        timer.cancel();
        _slowTimer = null;
      }
    });
  }

  /// The +: files and pictures where they may go, and a poll (Matt, 2026-11-19: "add Polls as a default feature")
  /// where this device may write; a choice between them where both may. Null where neither.
  VoidCallback? _plusAction(bool files, {bool polls = true}) {
    polls = polls && widget.room.mayWrite && _picked.isEmpty;
    if (!files && !polls) return null;
    if (!polls) return _attach;
    return () => showChoices(context, choices: [
          if (files) Choice('Photos and files', Lucide.imagePlus, () => unawaited(_attach())),
          Choice('Poll', LucideMore.chartColumn, () => push(context, (_) => NewPollScreen(room: widget.room))),
        ]);
  }

  /// The +'s files: any files, pictures, videos and GIFs among them, chosen with the device's own picker (a phone's
  /// copied into the app's folder first, as a Files space's are). They wait over the box to go with the next message,
  /// up to the most one takes ([HangoutMessage.mostFiles]).
  Future<void> _attach() async {
    if (!FilePlatform.canPick) {
      toast(context, 'Files can\'t be chosen on this device yet.');
      return;
    }
    try {
      final picked = await FilePlatform.pick();
      if (!mounted || picked.isEmpty) return;
      setState(() => _picked.addAll(picked.take(HangoutMessage.mostFiles - _picked.length)));
      if (picked.length + _picked.length > HangoutMessage.mostFiles) toast(context, 'Up to ${HangoutMessage.mostFiles} files go with one message.');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t add that: $e', tone: GlacierToastTone.danger);
    }
  }

  /// The stickers' sheet; the one tapped is sent straight away, by its name: every app carries the stickers, so nothing
  /// goes up, and it is sealed as any message here is.
  Future<void> _sticker() async {
    if (_slowLeft > Duration.zero) return;
    final asset = await pickSticker(context);
    if (asset == null || !mounted) return;
    HapticFeedback.lightImpact();
    if (!widget.room.sendWith(sticker: stickerName(asset))) toast(context, 'Couldn\'t send the sticker.', tone: GlacierToastTone.danger);
  }

  /// The microphone, on the phone (android/.../Voice.kt, as a Telegram chat records) or a computer's own
  /// (lib/desktop/desk_voice.dart, GMFB-32): recorded, then sent up as a file and its message, as any other file here.
  Future<void> _record() async {
    try {
      final limit = await Sms.instance.startVoice(file: true);
      if (!mounted) {
        if (limit != null) Sms.instance.cancelVoice().catchError((_) {});
        return;
      }
      if (limit == null) {
        toast(context, micRefusedWords(), tone: GlacierToastTone.danger);
        return;
      }
      HapticFeedback.lightImpact();
      setState(() => _recording = limit);
    } catch (e) {
      if (mounted) toast(context, voiceProblem(e), tone: GlacierToastTone.danger);
    }
  }

  /// Stops the recording and sends it as a voice message.
  Future<void> _sendVoice() async {
    setState(() => _recording = null);
    try {
      // In another voice, where Voice changer is on (lib/voice/voice_changer.dart): never as it was, should that fail.
      final changing = VoiceChanger.instance.active;
      if (changing && mounted) toast(context, 'Changing your voice…');
      final path = await VoiceChanger.instance.forSending(await Sms.instance.finishVoice());
      if (widget.room.sendFiles([(path: path, owned: true)], _uploads, voice: true) == null && mounted) toast(context, 'Couldn\'t send the voice message.', tone: GlacierToastTone.danger);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send the voice message: ${voiceProblem(e)}', tone: GlacierToastTone.danger);
    }
  }

  void _discardVoice() {
    Sms.instance.cancelVoice().catchError((_) {});
    setState(() => _recording = null);
  }

  /// A message with files on its way, at the right as your own are ([SpaceOutgoing]); in a circle's channel on the left
  /// under the messages' column, as everyone's are there ([_Message.flat]).
  Widget _outgoing(HangoutRoom room, OutgoingMessage o, Color mineBg, Color mineInk) {
    final t = context.tokens;
    final flat = room.channel.circle != null;
    return Padding(
      key: ValueKey('going-${o.id}'),
      padding: EdgeInsetsDirectional.only(top: t.space(2), start: flat ? FlatLine.wordsLeft(t) : 0),
      child: Align(
        alignment: flat ? AlignmentDirectional.centerStart : AlignmentDirectional.centerEnd,
        child: SpaceOutgoing(
          message: o,
          maxWidth: MediaQuery.sizeOf(context).width * 0.72,
          ground: flat ? theirBubble(t, onBackground: false) : mineBg,
          ink: flat ? t.color('app-ink') : mineInk,
          rim: flat ? theirRim(t) : bubbleNeedsRim(mineBg, t.color('glacier-bg')) ? Border.all(color: t.color('app-ink-4'), width: 1) : null,
          onRetry: () => room.retry(o, _uploads),
          onDiscard: () => room.discard(o, _uploads),
        ),
      ),
    );
  }

  /// Pressed and held under Dial-Up: what a bubble's press offers ([_Message]), copy, or delete at once with a puff.
  void _menu(HangoutMessage m) {
    HapticFeedback.mediumImpact();
    showChoices(context, choices: [
      if (widget.room.mayWrite) Choice('Reply', LucideMore.reply, () => _startReply(m)),
      if (m.thread == null) Choice('Reply in thread', Lucide.messageSquare, () => _openThread(m)),
      if (widget.room.canEdit(m)) Choice('Edit', Lucide.penLine, () => _startEdit(m)),
      if (m.text.isNotEmpty) Choice('Copy', Lucide.copy, () => Clipboard.setData(ClipboardData(text: m.text))),
      // Snooze one message (GMFB-36): back pinned at the top of this chat at its time.
      snoozeMessageChoice(context, chat: _snoozeKey, id: m.id, title: widget.room.channel.name, words: m.text.isEmpty ? m.what : m.text),
      ...translateChoices(context, spaceFacts(m, mine: m.from == widget.room.me)),
      // Report (GMFB-40): someone else's message.
      if (m.from != widget.room.me) Choice('Report', Lucide.flag, () => reportSpaceMessage(context, widget.room, m)),
      if (widget.room.canDelete(m)) Choice('Delete for everyone', Lucide.trash2, () => setState(() => _poofing.add(m.id)), danger: true),
    ]);
  }

  /// Who "People Here" lists: you first, then the others. In a space with a call it is who is in the call, and nobody
  /// who only has the space open (Matt, 2026-11-27: "the 'people here' reports people not in voice chat actively": it
  /// said 3 under a header that said "2 in voice"); in a texting or Files space, which has no call, and in a browser,
  /// which has none yet, it is who has the space open.
  List<({String id, String name, bool voice, bool me})> _people(HangoutRoom room) {
    final v = Voice.instance;
    final inVoice = v.inChannel(room.channel);
    final meIn = v.session?.channel.room == room.channel.room;
    if (_callSpace(room)) {
      return [
        if (meIn) (id: room.me, name: 'You', voice: true, me: true),
        for (final id in _inCall(room)) (id: id, name: _nameOf(id), voice: true, me: false),
      ];
    }
    return [
      (id: room.me, name: 'You', voice: meIn, me: true),
      for (final p in room.present.values)
        if (p.id != room.me) (id: p.id, name: _nameOf(p.id), voice: p.inVoice || inVoice.contains(p.id), me: false),
    ];
  }

  /// The space as Dial-Up's chat room (Matt, 2026-11-16: "base one of them heavily on the old AOL chatrooms"): one
  /// transcript of "Name: words" lines with Host saying who came and went, and "People Here" with who is in it. On a
  /// wide window the people stand beside the transcript, one name to a row, a speaker by each one in voice, filled
  /// while they talk; on a phone they are a strip over it that opens out.
  Widget _chatRoom(HangoutRoom room) {
    final c = DialupColors.of(context.tokens);
    final people = _people(room);
    final entries = <({int at, HangoutMessage? m, ({int at, String id, bool came})? e})>[
      for (final m in room.timeline) (at: m.at, m: m, e: null),
      for (final e in _comings) (at: e.at, m: null, e: e),
    ]..sort((a, b) => a.at.compareTo(b.at));
    final list = entries.reversed.toList();
    final going = room.outgoing.reversed.toList();
    bool sameDay(int a, int b) {
      final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
      return x.year == y.year && x.month == y.month && x.day == y.day;
    }

    final transcript = JumpToLatest(
      controller: _scroll,
      chat: _spot,
      incoming: _incoming(room),
      inset: const EdgeInsets.only(right: 14, bottom: 12),
      child: Transcript(
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: going.length + list.length + 1,
        itemBuilder: (context, at) {
          // The well's own colours (a look may write its chat on another ground than its pages': `.parchment`).
          final c = DialupColors.of(context.tokens);
          // Messages with files on their way, at the foot (the era drew none: the same as the other looks').
          if (at < going.length) {
            final o = going[at];
            return Padding(
              key: ValueKey('going-${o.id}'),
              padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 4),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: SpaceOutgoing(message: o, maxWidth: 280, ground: c.paper, ink: c.ink, rim: Border.all(color: c.shadow), onRetry: () => room.retry(o, _uploads), onDiscard: () => room.discard(o, _uploads)),
              ),
            );
          }
          final i = at - going.length;
          // The oldest end: where the room starts, and that what is said in it is sealed (each space's own key).
          if (i == list.length) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              HostLine('*** You are in "${room.channel.name}". ***'),
              const HostLine('Messages here are sealed end to end.'),
            ]);
          }
          final x = list[i];
          final older = i + 1 < list.length ? list[i + 1] : null;
          final newer = i > 0 ? list[i - 1] : null;
          final newDay = older == null || !sameDay(older.at, x.at);
          final Widget line;
          final e = x.e, m = x.m;
          if (e != null) {
            line = HostLine('${lineName(_nameOf(e.id))} has ${e.came ? 'entered' : 'left'} the room.');
          } else {
            final mine = m!.from == room.me;
            final name = mine ? 'You' : (m.name.isEmpty ? Voice.instance.nameOf(m.from) : m.name);
            final lastOfRun = newer == null || newer.m == null || newer.m!.from != m.from || !sameDay(newer.at, m.at);
            line = Poof(
              key: ValueKey('poof-${m.id}'),
              gone: _poofing.contains(m.id),
              side: AxisDirection.left,
              onDone: () {
                _poofing.remove(m.id);
                room.delete(m);
              },
              child: ShownWords(
                key: ValueKey(m.id),
                facts: spaceFacts(m, mine: mine),
                builder: (_, shown) => MessageLine(
                name: name,
                // Each person keeps one of the room's six colours, by their id, and yours is your own.
                nameColor: mine ? c.nameMine : c.nameFor(m.from),
                mine: mine,
                // A poll's question is on its card, and a plugin's note is its card (lib/ui/plugin_note_card.dart).
                body: m.poll != null || pluginCardOf(m, mine: mine) != null ? '' : (shown?.bubble ?? m.text),
                // A translation's words are not the words the mentions are counted in.
                mentions: shown == null ? m.mentions : const [],
                mentionStyle: mentionStyle(context.tokens, on: c.ink),
                onMention: _mentionPressed,
                // Their name opens their profile card.
                onNameTap: () => _openPerson(m.from),
                original: shown == null ? null : OriginalLine(view: shown),
                // What went with it under the words, square, as the era's lines carry pictures (Matt, 2026-11-18).
                media: [
                  if (pluginCardOf(m, mine: mine) case final pc?) PluginChatCardView(card: pc.card, plugin: pc.plugin, maxWidth: 320, ground: c.paper, ink: c.ink),
                  if (m.poll != null) PollCard(room: room, message: m, maxWidth: 320),
                  if (m.sticker != null) SpaceSticker(name: m.sticker!, side: 120),
                  if (m.files.isNotEmpty) SpaceChatFiles(channel: room.channel, message: m, maxWidth: 280, ground: c.paper, ink: c.ink, rim: Border.all(color: c.shadow)),
                ],
                status: lastOfRun || m.edited != null ? [if (lastOfRun) clock(DateTime.fromMillisecondsSinceEpoch(m.at)), if (m.edited != null) 'edited'].join(' · ') : null,
                onLongPress: (_) => _menu(m),
              )),
            );
          }
          if (!newDay) return line;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [HostLine.day(DateTime.fromMillisecondsSinceEpoch(x.at)), line]);
        },
      ),
    ));
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth >= 560) {
        return ColoredBox(
          color: c.chrome,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: transcript),
            SizedBox(width: 200, child: Padding(padding: const EdgeInsetsDirectional.fromSTEB(0, 4, 6, 4), child: _DialupPeople(people: people, panel: true))),
          ]),
        );
      }
      return ColoredBox(
        color: c.chrome,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _DialupPeopleStrip(people: people, open: _peopleOpen, onToggle: () => setState(() => _peopleOpen = !_peopleOpen)),
          if (_peopleOpen) Padding(padding: const EdgeInsetsDirectional.fromSTEB(6, 0, 6, 2), child: SizedBox(height: math.min(people.length, 4) * 44.0 + 8, child: _DialupPeople(people: people))),
          Expanded(child: transcript),
        ]),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final room = widget.room;
    return ListenableBuilder(
      // And the circle's, whose roles colour the names.
      listenable: Listenable.merge([room, Circles.instance]),
      builder: (context, _) {
        final circles = widget.circles ?? Circles.instance;
        final circle = circles.circleOf(room.channel);
        // A circle's welcome space starts with its welcome, and its system space has the circle's comings and goings
        // among its messages (Matt, 2026-11-20; lib/circles/welcome.dart): newest first, as the list runs.
        final welcome = circle != null && circle.manifest.welcomeSpace == room.channel.seed;
        final system = circle != null && circle.manifest.systemSpace == room.channel.seed;
        // A thread's replies are in its page, not here (GMFB-36).
        final threads = room.threads;
        final list = <Object>[
          ...room.timeline,
          if (system) ...circles.systemNotesIn(circle),
        ];
        if (system) list.sort((a, b) => _atOf(a).compareTo(_atOf(b)));
        final rows = [...list.reversed, if (welcome) _welcomeRow];
        // Messages with files on their way, newest at the foot, under everything sent.
        final going = room.outgoing.reversed.toList();
        // The space's own roles, and in a circle its roles too (lib/circles: CirclePerm.write; spaceMayWrite).
        final mayWrite = spaceMayWrite(room, circles: widget.circles);
        final readOnly = circles.isReadOnly(room.channel);
        final (mineBg, mineInk) = myBubble(t, AppState.of(context));
        final chat = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Messages back from a snooze, pinned at the top until shown (GMFB-36).
          SnoozedReminders(chat: _snoozeKey, onShow: _showMessage),
          Expanded(
            // Dial-Up writes the space as a chat room: its transcript, and who is here beside it or over it.
            child: isDialup(context)
                ? _chatRoom(room)
                : rows.isEmpty && going.isEmpty && !room.reached
                // Not in its room on the relay server yet: its messages in bones, not "No messages yet", which is
                // not known until the room has answered (lib/ui/skeleton.dart).
                ? const SkeletonChat(label: 'Loading messages…', faces: true)
                : rows.isEmpty && going.isEmpty
                ? Center(child: Text('No messages yet', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))))
                // The down arrow over the list's foot, back to the newest message (Matt, 2026-11-17: "add a down arrow
                // that pops up when we enter a chat and we're not scrolled to the bottom or after we scroll up a certain
                // amount").
                : JumpToLatest(
                  controller: _scroll,
                  chat: _spot,
                  incoming: _incoming(room),
                  // Left of the map's gutter, level with the bubbles' edge: at the list's own edge it stood over the
                  // map's foot and took the presses meant for its lowest lines.
                  inset: EdgeInsets.only(right: ChatRail.gutter, bottom: t.space(3)),
                  // The chat's map in the gutter at its right (lib/ui/chat_rail.dart).
                  child: ChatRail(
                    controller: _scroll,
                    chat: _spot,
                    marks: [
                      for (final row in rows)
                        if (row is HangoutMessage)
                          RailMark(at: row.at, who: row.from == room.me ? 'me' : row.from, mine: row.from == room.me, name: row.from == room.me ? 'You' : (row.name.isEmpty ? Voice.instance.nameOf(row.from) : row.name), text: row.text)
                        else if (row is CircleSystemNote)
                          RailMark(at: row.at, who: '', mine: false, quiet: true),
                    ],
                    face: (who, name, mine, size) => SpaceFace(room: room, id: mine ? room.me : who, name: name, size: size),
                    lead: going.length,
                    // The list that can go straight to a row (lib/ui/chat_rows.dart).
                    child: ChatListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), ChatRail.gutter, t.space(2)),
                    chat: _spot,
                    // A message by its id, a note by what it says of whom and when, one still going up by itself.
                    idOf: (i) {
                      if (i < going.length) return going[i];
                      final row = rows[i - going.length];
                      return row is HangoutMessage ? row.id : (row is CircleSystemNote ? (row.kind, row.id, row.at) : row);
                    },
                    itemCount: going.length + rows.length,
                    itemBuilder: (context, i) {
                      if (i < going.length) return _outgoing(room, going[i], mineBg, mineInk);
                      i -= going.length;
                      final row = rows[i];
                      if (identical(row, _welcomeRow)) return CircleWelcomeCard(circle: circle!, name: room.name);
                      final before = i == rows.length - 1 || rows[i + 1] is! HangoutMessage ? null : rows[i + 1] as HangoutMessage;
                      final after = i == 0 || rows[i - 1] is! HangoutMessage ? null : rows[i - 1] as HangoutMessage;
                      if (row is CircleSystemNote) {
                        final at = DateTime.fromMillisecondsSinceEpoch(row.at);
                        final prev = i == rows.length - 1 ? null : rows[i + 1];
                        final newDay = prev == null || !_sameDay(_atOf(prev), row.at);
                        final line = CircleSystemLine(note: row);
                        if (!newDay) return line;
                        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          DayTurn(dayHeading(at)),
                          line,
                        ]);
                      }
                      final m = row as HangoutMessage;
                      // Laid out as a conversation of texts is (Matt, 2026-11-16: "update the chat inside spaces to match
                      // the look and layout of the normal chats"): a run from one person is one stack of bubbles, the
                      // name over its first, the face and the time by its last, and a day's heading where the day turns.
                      // The list runs newest first: [i + 1] is the message before, [i - 1] the one after.
                      final at = DateTime.fromMillisecondsSinceEpoch(m.at);
                      bool sameDay(HangoutMessage? o) {
                        if (o == null) return false;
                        final d = DateTime.fromMillisecondsSinceEpoch(o.at);
                        return d.year == at.year && d.month == at.month && d.day == at.day;
                      }
                      // A system line just before starts the day too where the day turned there.
                      final prev = i == rows.length - 1 ? null : rows[i + 1];
                      final newDay = prev == null || prev is HangoutMessage ? !sameDay(before) : !_sameDay(_atOf(prev), m.at);
                      // In a circle's channel a pause of five minutes starts a new run, its name and time shown again,
                      // as Slack and Discord do (lib/ui/flat_line.dart).
                      final flat = room.channel.circle != null;
                      bool apart(HangoutMessage a, HangoutMessage b) => flat && FlatLine.apart(DateTime.fromMillisecondsSinceEpoch(a.at), DateTime.fromMillisecondsSinceEpoch(b.at));
                      // A system line beside it (lib/circles/welcome.dart) ends the run as a day's turn does.
                      final first = newDay || before == null || before.from != m.from || apart(m, before);
                      final last = after == null || !sameDay(after) || after.from != m.from || apart(after, m);
                      final message = Poof(
                        key: ValueKey('poof-${m.id}'),
                        gone: _poofing.contains(m.id),
                        side: AxisDirection.left,
                        onDone: () {
                          _poofing.remove(m.id);
                          room.delete(m);
                        },
                        child: _Message(key: ValueKey(m.id), room: room, message: m, first: first, last: last, mineBg: mineBg, mineInk: mineInk, flat: flat, onDelete: () => setState(() => _poofing.add(m.id)), onEdit: () => _startEdit(m), onReply: () => _startReply(m), onThread: () => _openThread(m), onMention: _mentionPressed, onPerson: _openPerson),
                      );
                      // Its thread's line under it, where it has one (GMFB-36): on the left under the words.
                      final thread = threads[m.id];
                      final shown = thread == null
                          ? message
                          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              message,
                              ThreadLine(count: thread.count, last: thread.last, indent: t.lenOf('1.75rem') + t.space(2) + t.space(3), onOpen: () => _openThread(m)),
                            ]);
                      // A snooze's reminder asked for it: its row is found under this key (scrollToShown).
                      final found = m.id == _shownId ? KeyedSubtree(key: _shownKey, child: shown) : shown;
                      if (!newDay) return found;
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        DayTurn(dayHeading(at)),
                        found,
                      ]);
                    },
                  ),
                  ),
                ),
          ),
          _DialupFoot(
            child: Padding(
              // Laid out as every other conversation's foot is (Matt, 2026-11-15: "Use the same compose input on spaces
              // that we use for the rest of the app ... just make it appear like the bottom of all the compose windows look").
              // The screen's foot always, as a conversation of texts leaves it, and the call's dock on top where there is one.
              // Over the keyboard while it is up, as a conversation's foot is in GhostPage's footer (Matt, 2026-11-18: "when
              // typing in a space the chat and chatbar don't slide up above the keyboard"): the list above, being the rest
              // of the column, shrinks to make room and keeps its newest messages in view.
              padding: composerFootPadding(t, bottom: MediaQuery.viewInsetsOf(context).bottom > 0 ? MediaQuery.viewInsetsOf(context).bottom : widget.bottom + MediaQuery.paddingOf(context).bottom),
              child: mayWrite
                  ? Builder(builder: (context) {
                      if (_recording != null) return VoiceRecorder(limit: _recording!, onDiscard: _discardVoice, onSend: _sendVoice, note: VoiceChanger.instance.note, carrier: false);
                      // The same buttons in the same places as every other conversation (lib/ui/composer_box.dart): files,
                      // stickers and, on the phone itself, voice messages, as in other chats (Matt, 2026-11-18). Files
                      // only where the circle's roles let this person share them (spaceMayAttach).
                      final attach = _mayAttach;
                      // Slow mode: how long until this person may write again here (Matt, 2026-11-19).
                      final slow = _slowSeconds;
                      final left = _slowLeft;
                      final waiting = left > Duration.zero;
                      if (waiting) _tickSlowMode();
                      final ScheduleTarget schedule = (kind: 'space', target: room.channel.seed, who: room.channel.name);
                      final buttons = composerButtons(
                        t,
                        hasSomething: _text.text.isNotEmpty || _picked.isNotEmpty,
                        onAttach: _editing != null ? null : _plusAction(attach && FilePlatform.canPick && _picked.length < HangoutMessage.mostFiles, polls: !waiting),
                        onSticker: _picked.isEmpty && !waiting && _editing == null ? _sticker : null,
                        onRecord: attach && Sms.canRecordVoice && _picked.isEmpty && !waiting && _editing == null ? _record : null,
                        // An edit is saved whenever, slow mode or not: it is no new message.
                        onSend: _editing != null
                            ? (_text.text.trim().isEmpty && _editing!.files.isEmpty ? null : _send)
                            : (_text.text.trim().isEmpty && _picked.isEmpty) || waiting
                                ? null
                                : _send,
                        emoji: Sms.remote,
                        onEmoji: _emoji,
                        // Send later (lib/ui/schedule_ui.dart): words alone; mentions go as plain words then.
                        onSendMenu: _editing != null
                            ? null
                            : () {
                                if (_picked.isNotEmpty) {
                                  toast(context, 'Files can\'t be scheduled yet. Send them now, or schedule the words alone.');
                                  return;
                                }
                                openSendMenu(context, to: room.mayWrite ? schedule : null, text: _text.text, onScheduled: _text.clear);
                              },
                        // Saving an edit: a tick, as a text being edited has (lib/ui/thread.dart).
                        send: _editing == null
                            ? null
                            : IconTap(
                                key: const ValueKey('composer-send'),
                                icon: Lucide.check,
                                label: 'Save edit',
                                filled: true,
                                size: 16,
                                box: t.lenOf('2.25rem'),
                                onPressed: _text.text.trim().isEmpty && _editing!.files.isEmpty ? null : _send,
                              ),
                      );
                      _text.style = mentionStyle(t);
                      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // Who an "@…" being written finds, over the box (Matt, 2026-11-19: "Add mentions support to spaces
                        // and circles with the @user prefix").
                        if (_query != null && _found.isNotEmpty)
                          MentionSuggestions(people: _found, chosen: _chosen, onPick: _pickMention, inkOf: (p) => spaceNameInk(t, widget.room, p.id)),
                        EmojiSuggestions(suggester: _shortcodes),
                        if (_editing != null) _EditingBar(words: _editing!.text, onClose: _stopEditing),
                        if (_replying != null && _editing == null) _ReplyBar(reply: _replying!, me: widget.room.me, onClose: _stopReplying),
                        if (slow > 0 && _editing == null) _SlowModeLine(seconds: slow, left: left),
                        if (readOnly && _editing == null) const ReadOnlyAdminLine(),
                        if (_picked.isNotEmpty) SpacePickedStrip(files: _picked, onRemove: (p) => setState(() => _picked.remove(p))),
                        if (_editing == null) ScheduledStrip(to: schedule),
                        ComposerBox(
                          typing: _typing,
                          plus: buttons.plus,
                          ends: buttons.ends,
                          below: buttons.below,
                          // A picture pasted on a computer goes with the message (lib/ui/paste_images.dart).
                          field: PasteImages(
                            focusNode: _focus,
                            enabled: attach && _editing == null && _picked.length < HangoutMessage.mostFiles,
                            onImage: (path) => setState(() => _picked.add((path: path, owned: false))),
                            child: ComposerField(controller: _text, focusNode: _focus, hint: 'Message ${room.channel.name}', onSubmitted: _send, enterSends: AppState.of(context).enterSends),
                          ),
                        ),
                      ]);
                    })
                  : readOnly
                      ? ReadOnlyFoot(space: room.channel, system: system)
                      : Text('Your role can\'t send messages here.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            ),
          ),
        ]);
        // A thread open beside the chat (GMFB-36): its panel at the right, or in the chat's place where the chat is
        // too narrow for both, with its cross back. Not on a phone, where threads open as their page.
        final root = _threadRoot;
        if (root == null || !_threadsBeside) return chat;
        return LayoutBuilder(builder: (context, box) {
          final panel = SpaceThreadPanel(key: const ValueKey('thread-panel'), room: room, root: root, onClose: () => setState(() => _threadRoot = null));
          if (box.maxWidth < SpaceThreadPanel.besideAt) return panel;
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: chat),
            Container(width: t.len('glacier-hairline'), color: t.color('app-rule')),
            SizedBox(width: SpaceThreadPanel.widthIn(box.maxWidth), child: panel),
          ]);
        });
      },
    );
  }
}

/// The welcome card's place in a chat's list (circle_welcome.dart CircleWelcomeCard): at its top, the oldest end.
const Object _welcomeRow = Object();

/// When a row of a space's chat was said: a message's, or a system line's (lib/circles/welcome.dart).
int _atOf(Object row) => switch (row) {
      HangoutMessage m => m.at,
      CircleSystemNote n => n.at,
      _ => 0,
    };

/// Whether two times (milliseconds since the epoch) fall on one day by this device's clock: a new day gets a divider.
bool _sameDay(int a, int b) {
  final x = DateTime.fromMillisecondsSinceEpoch(a), y = DateTime.fromMillisecondsSinceEpoch(b);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// Over the box while a message's words are being changed: what is being edited, and the way to stop.
/// Over the box while answering a message (GMFB-13): who wrote it and its start, and a way to stop.
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.reply, required this.me, required this.onClose});
  final SpaceReply reply;
  final String me;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final who = reply.from == me ? 'yourself' : (reply.name.isEmpty ? Voice.instance.nameOf(reply.from) : reply.name);
    return Padding(
      key: const ValueKey('space-replying'),
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: Row(children: [
        AppIcon(LucideMore.reply, size: 16, color: t.color('app-accent')),
        SizedBox(width: t.space(2)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Replying to $who', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-accent'))),
            // Record call's line with its icon, not its emoji (GMFB-43).
            if (reply.text.isNotEmpty) NoteWords(reply.text, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
        IconTap(key: const ValueKey('space-replying-stop'), icon: Lucide.x, label: 'Stop replying', size: 18, onPressed: onClose),
      ]),
    );
  }
}

/// The message a message answers, quoted at its head (GMFB-13): a bar in the accent, the writer, and the start of their
/// words.
class SpaceQuote extends StatelessWidget {
  const SpaceQuote({super.key, required this.reply, required this.me, required this.ink});
  final SpaceReply reply;
  final String me;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final who = reply.from == me ? 'You' : (reply.name.isEmpty ? Voice.instance.nameOf(reply.from) : reply.name);
    return FlatQuote(key: ValueKey('space-quote-${reply.id}'), who: who, text: reply.text, ink: ink);
  }
}

class _EditingBar extends StatelessWidget {
  const _EditingBar({required this.words, required this.onClose});
  final String words;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      key: const ValueKey('space-editing'),
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: Row(children: [
        AppIcon(Lucide.penLine, size: 16, color: t.color('app-accent')),
        SizedBox(width: t.space(2)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Editing message', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-accent'))),
            if (words.isNotEmpty) Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
        IconTap(key: const ValueKey('space-editing-stop'), icon: Lucide.x, label: 'Stop editing', size: 18, onPressed: onClose),
      ]),
    );
  }
}

/// The chat's foot under Dial-Up: the silver panel every other conversation's composer stands in (GhostPage's), with
/// its light top edge, where the page's white showed through (the review of the looks, 2026-11-16). Elsewhere as it was.
class _DialupFoot extends StatelessWidget {
  const _DialupFoot({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isDialup(context)) return child;
    final c = DialupColors.of(context.tokens);
    return DialupPanel(
      child: DecoratedBox(decoration: BoxDecoration(color: c.chrome, border: Border(top: BorderSide(color: c.hi, width: Bevel.ringOf(context)))), child: child),
    );
  }
}

/// Someone in the room, for Dial-Up's "People Here": their name, whether they are in its call, and whether it is you.
typedef _Here = ({String id, String name, bool voice, bool me});

/// Dial-Up's "People Here: N" on a phone: a strip over the transcript with the count and the first names, which a press
/// opens out into the list ([_DialupPeople]) and closes again.
class _DialupPeopleStrip extends StatelessWidget {
  const _DialupPeopleStrip({required this.people, required this.open, required this.onToggle});
  final List<_Here> people;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    return GlacierPressable(
      onPressed: onToggle,
      semanticLabel: 'People Here: ${people.length}. ${open ? 'Hide' : 'Show'} who is here',
      builder: (context, state) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(children: [
            CustomPaint(size: const Size(10, 10), painter: _Triangle(color: c.onChrome, open: open)),
            const SizedBox(width: 8),
            Text('People Here: ${people.length}', style: pageText(t, lineSize(context, 15), weight: 'bold', color: c.onChrome)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                people.map((p) => p.name).join(', '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: pageText(t, lineSize(context, 14), color: c.inkSoft),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Dial-Up's list of who is in a space: one name to a 44px row in a white well, a speaker by each one in its voice,
/// filled while they talk (from the call's levels, as the faces ripple with them elsewhere). [panel] puts the count
/// over it, for the wide window where it stands beside the transcript.
class _DialupPeople extends StatelessWidget {
  const _DialupPeople({required this.people, this.panel = false});
  final List<_Here> people;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final v = Voice.instance;
    final levels = v.media?.levels ?? v.session?.media.levels;
    Widget rows(Map<String, double> loud) => Sunken(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              for (final p in people)
                Semantics(
                  label: '${p.name}${p.voice ? ', in voice' : ''}',
                  excludeSemantics: true,
                  child: SizedBox(
                    height: 44,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(children: [
                        SizedBox(
                          width: 18,
                          child: p.voice
                              ? VoiceRipples(
                                  level: loud[p.me ? 'me' : p.id] ?? 0,
                                  reach: 8,
                                  builder: (context, _) => CustomPaint(size: const Size(16, 14), painter: _Speaker(color: c.ink, talking: (loud[p.me ? 'me' : p.id] ?? 0) > RippleAvatar.talking)),
                                )
                              : null,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            lineName(p.name),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: pageText(t, lineSize(context), weight: p.me ? 'bold' : 'regular', color: p.me ? c.nameMine : c.ink),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        );
    final list = levels == null ? rows(const {}) : ValueListenableBuilder<Map<String, double>>(valueListenable: levels, builder: (context, loud, _) => rows(loud));
    if (!panel) return list;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 32,
        child: Align(alignment: AlignmentDirectional.centerStart, child: Text('People Here: ${people.length}', style: pageText(t, lineSize(context, 15), weight: 'bold', color: c.onChrome))),
      ),
      Expanded(child: list),
    ]);
  }
}

/// A face in a list of a space's people who is in its call: rippling as they talk where this device is in that call too,
/// with the ring that says they are in it.
class _LiveFace extends StatelessWidget {
  const _LiveFace({required this.channel, required this.id, required this.name, required this.size});
  final VoiceChannel channel;
  final String id;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = Voice.instance.session;
    if (s == null || s.channel.room != channel.room) return RippleAvatar(name: name, level: 0, size: size, ringed: true);
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: callLevels(s),
      builder: (context, loud, _) => RippleAvatar(name: name, level: loud[id] ?? 0, muted: id == 'me' ? s.muted : (s.members[id]?.muted ?? false), size: size, ringed: true),
    );
  }
}

/// A disclosure triangle drawn as a path: pointing right while closed, down while open.
class _Triangle extends CustomPainter {
  const _Triangle({required this.color, required this.open});
  final Color color;
  final bool open;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = open ? (Path()..moveTo(0, h * 0.2)..lineTo(w, h * 0.2)..lineTo(w / 2, h * 0.85)) : (Path()..moveTo(w * 0.2, 0)..lineTo(w * 0.85, h / 2)..lineTo(w * 0.2, h));
    canvas.drawPath(path..close(), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Triangle old) => old.color != color || old.open != open;
}

/// A loudspeaker drawn as a path, in the era's flat way: an outline while someone is in voice and quiet, filled with
/// its sound waves while they talk.
class _Speaker extends CustomPainter {
  const _Speaker({required this.color, required this.talking});
  final Color color;
  final bool talking;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = Path()
      ..moveTo(0, h * 0.35)
      ..lineTo(w * 0.22, h * 0.35)
      ..lineTo(w * 0.5, h * 0.08)
      ..lineTo(w * 0.5, h * 0.92)
      ..lineTo(w * 0.22, h * 0.65)
      ..lineTo(0, h * 0.65)
      ..close();
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(body, talking ? (Paint()..color = color) : stroke);
    if (talking) {
      canvas.drawArc(Rect.fromCenter(center: Offset(w * 0.5, h / 2), width: w * 0.5, height: h * 0.5), -0.9, 1.8, false, stroke);
      canvas.drawArc(Rect.fromCenter(center: Offset(w * 0.5, h / 2), width: w * 0.95, height: h * 0.95), -0.9, 1.8, false, stroke);
    }
  }

  @override
  bool shouldRepaint(_Speaker old) => old.color != color || old.talking != talking;
}


/// The facts a plugin that shows a message's words otherwise is asked by (the Translate plugin; Matt, 2026-11-17: "add
/// a translate plugin which can automatically translate texts when detected from another language"): none for your own.
MessageFacts? spaceFacts(HangoutMessage m, {required bool mine}) =>
    mine || m.text.trim().isEmpty ? null : MessageFacts(thread: -1, senders: [m.from], text: m.text, contact: false, outgoing: false, date: DateTime.fromMillisecondsSinceEpoch(m.at), id: 'space:${m.id}', network: 'space');

/// One message of a space's chat: a bubble, as in a conversation, or a channel's line ([flat]) in a circle.
class _Message extends StatelessWidget {
  const _Message({super.key, required this.room, required this.message, required this.first, required this.last, required this.mineBg, required this.mineInk, this.onDelete, this.onEdit, this.onReply, this.onThread, this.flat = false, this.onMention, this.onPerson});
  final HangoutRoom room;
  final HangoutMessage message;

  /// Drawn as Slack and Discord draw a channel (Matt, 2026-11-18: "Id like the chats in circles to be more like discord
  /// or slack and keep the bubbles for dms and small groups"): everyone on the left, yourself too, a run's first message
  /// with the face, the name and the time over it, the words on the page with no bubble.
  final bool flat;

  /// The first and the last of a run from one person on one day.
  final bool first, last;

  /// This person's own bubble colours (lib/backgrounds.dart myBubble), as in a conversation of texts.
  final Color mineBg, mineInk;

  /// Deletes it, with its puff.
  final VoidCallback? onDelete;

  /// Its words put in the box to change, where it is this person's (HangoutRoom.canEdit).
  final VoidCallback? onEdit;

  /// Answered: the next message quotes it (GMFB-13).
  final VoidCallback? onReply;

  /// Its thread opened: beside the chat in a wide window (GMFB-36). Its page where not given.
  final VoidCallback? onThread;

  /// A mention in it pressed.
  final ValueChanged<Mention>? onMention;

  /// Their face or name pressed: their profile card.
  final ValueChanged<String>? onPerson;

  /// [child], pressed for [message]'s writer's profile card, with a hand over it on a computer.
  Widget _toPerson(Widget child) {
    final on = onPerson;
    if (on == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => on(message.from), child: Semantics(button: true, child: child)),
    );
  }

  /// Someone else's message that mentions you: drawn so it stands out, as other chat apps draw one.
  bool get mentionsMe => message.from != room.me && room.mentionsMe(message);

  @override
  Widget build(BuildContext context) => ShownWords(facts: spaceFacts(message, mine: message.from == room.me), builder: _build);

  /// The message, saying [shown]'s words where a plugin shows them otherwise, with the words as they came over it.
  Widget _build(BuildContext context, ShownView? shown) {
    final t = context.tokens;
    final m = message;
    final mine = m.from == room.me;
    final name = m.name.isEmpty ? Voice.instance.nameOf(m.from) : m.name;
    final round = Radius.circular(lookCorner(t, '1.125rem', most: 1));
    final tight = Radius.circular(lookCorner(t, '0.375rem', most: 1));
    final faceSize = t.lenOf('1.75rem');
    final faceGap = mine ? 0.0 : faceSize + t.space(2);
    // Pressed and held: copy it, or delete it at once with a puff (Matt, 2026-11-15: "Don't ask for confirmation when
    // deleting a message and show a poof animation when one is deleted").
    // Reactions (Matt, 2026-11-20: "add reactions after done to spaces and circles"): the row over the menu, as in a
    // conversation of texts; in a read-only space too, where only posting is the admins'.
    final reacted = room.reactionsOn(m);
    void react(String emoji) {
      HapticFeedback.selectionClick();
      room.react(m, emoji);
    }

    void menu() {
      HapticFeedback.mediumImpact();
      final mineSet = {for (final r in reacted) if (r.mine) r.emoji};
      showChoices(context, header: room.mayReact ? ReactionPickRow(emojis: reactionChoices, mine: mineSet, onPick: (emoji) {
        Navigator.of(context, rootNavigator: true).pop();
        react(emoji);
      }) : null, choices: [
        if (room.mayWrite && onReply != null) Choice('Reply', LucideMore.reply, () => onReply!.call()),
        if (m.thread == null) Choice('Reply in thread', Lucide.messageSquare, () => onThread != null ? onThread!() : openThread(context, room, m)),
        if (room.canEdit(m) && onEdit != null) Choice('Edit', Lucide.penLine, () => onEdit!.call()),
        if (m.text.isNotEmpty) Choice('Copy', Lucide.copy, () => Clipboard.setData(ClipboardData(text: m.text))),
        // Snooze one message (GMFB-36): back pinned at the top of this chat at its time.
        snoozeMessageChoice(context, chat: Snoozed.space(room.channel.room), id: m.id, title: room.channel.name, words: m.text.isEmpty ? m.what : m.text),
        ...translateChoices(context, spaceFacts(m, mine: mine)),
        // Report (GMFB-40): someone else's message.
        if (!mine) Choice('Report', Lucide.flag, () => reportSpaceMessage(context, room, m)),
        if (room.canDelete(m)) Choice('Delete for everyone', Lucide.trash2, () => onDelete?.call(), danger: true),
      ]);
    }

    if (flat) return _flat(context, shown, menu, reacted, react);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.72;
    final bubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
        decoration: BoxDecoration(
          color: mentionsMe ? Color.alphaBlend(t.color('app-accent').withValues(alpha: 0.12), theirBubble(t, onBackground: false)) : (mine ? mineBg : theirBubble(t, onBackground: false)),
          border: mentionsMe ? Border.all(color: t.color('app-accent'), width: 1.5) : (!mine ? theirRim(t) : bubbleNeedsRim(mineBg, t.color('glacier-bg')) ? Border.all(color: t.color('app-ink-4'), width: 1) : null),
          borderRadius: BorderRadius.only(
            topLeft: !mine && !first ? tight : round,
            bottomLeft: !mine && !last ? tight : round,
            topRight: mine && !first ? tight : round,
            bottomRight: mine && !last ? tight : round,
          ),
        ),
        child: m.reply == null
            ? _words(t, shown, pageText(t, t.fontSize('md'), color: mine ? mineInk : t.color('app-ink'), height: 1.3), mine ? mineInk : t.color('app-ink'))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                SpaceQuote(reply: m.reply!, me: room.me, ink: mine ? mineInk : t.color('app-ink')),
                SizedBox(height: t.space(1)),
                _words(t, shown, pageText(t, t.fontSize('md'), color: mine ? mineInk : t.color('app-ink'), height: 1.3), mine ? mineInk : t.color('app-ink')),
              ]),
      ),
    );
    // A sticker on the page with no bubble; files over the words, the words' bubble only where there are any (Matt,
    // 2026-11-18: "I also want full support for uploading attachements gifs stickers etc like we support in other chats").
    final words = shown == null ? bubble : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [OriginalCard(view: shown, maxWidth: maxWidth), bubble]);
    final Widget body;
    final plugin = pluginCardOf(m, mine: mine);
    if (plugin != null) {
      // A plugin's note: its card, in place of the bubble (lib/ui/plugin_note_card.dart).
      body = PluginChatCardView(card: plugin.card, plugin: plugin.plugin, maxWidth: maxWidth);
    } else if (m.poll != null) {
      body = PollCard(room: room, message: m, maxWidth: maxWidth);
    } else if (m.sticker != null) {
      body = SpaceSticker(name: m.sticker!, side: math.min(t.lenOf('9.5rem'), maxWidth));
    } else if (m.files.isNotEmpty) {
      body = Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        SpaceChatFiles(
          channel: room.channel,
          message: m,
          mine: mine,
          maxWidth: maxWidth,
          ground: mine ? mineBg : theirBubble(t, onBackground: false),
          ink: mine ? mineInk : t.color('app-ink'),
          rim: !mine ? theirRim(t) : bubbleNeedsRim(mineBg, t.color('glacier-bg')) ? Border.all(color: t.color('app-ink-4'), width: 1) : null,
        ),
        if (m.text.isNotEmpty) ...[SizedBox(height: t.space(1)), words],
      ]);
    } else {
      // Notion links, opened out under the bubble where the circle has Notion (lib/ui/notion_card.dart).
      // And every other link's card, a GIF's or a picture's link as the picture (lib/ui/link_cards.dart).
      final notion = [...notionCardsUnder(context, room.channel, m.text, maxWidth: maxWidth), ...linkCardsUnder(context, m.text, skip: (url) => NotionLink.of(url) != null)];
      body = notion.isEmpty ? words : Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [words, ...notion]);
    }
    // Stuck on the bubble as stickers, as in a conversation of texts (lib/ui/reaction_stickers.dart).
    final stuck = reacted.isEmpty ? body : ReactionStickers(key: ValueKey('reactions-${m.id}'), bubble: body, seed: m.id, kinds: [for (final r in reacted) (emoji: r.emoji, count: r.count)], onTap: menu);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: menu,
      onSecondaryTap: menu,
      child: Padding(
        padding: EdgeInsets.only(top: first ? t.space(2) : 2),
        child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
          // The name over a run's first bubble in its role's colour (the app's primary colour where the role has none),
          // by their role's colour alone (Matt, 2026-11-18: "Remove the crown icon just use role colors").
          if (first && !mine)
            Padding(
              padding: EdgeInsetsDirectional.only(start: faceGap + t.space(3), bottom: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: _toPerson(Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: spaceNameInk(t, room, m.from) ?? t.color('app-accent'))))),
                VerifiedBadge(id: m.from, username: room.usernames[m.from], me: m.from == room.me, size: 12),
              ]),
            ),
          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            // Their face by the run's last bubble, as in a group of texts.
            if (!mine) ...[
              SizedBox(width: faceSize, child: last ? _toPerson(SpaceFace(room: room, id: m.from, name: name, size: faceSize)) : null),
              SizedBox(width: t.space(2)),
            ],
            // The words as they came, dimmed, in a card over a translated bubble.
            Flexible(child: stuck),
          ]),
          if (last)
            Padding(
              padding: EdgeInsetsDirectional.only(top: 2, start: faceGap + t.space(2), end: t.space(2)),
              child: Text(clock(DateTime.fromMillisecondsSinceEpoch(m.at)), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            ),
        ]),
      ),
    );
  }
}

extension on _Message {
  /// The words, with their links and mentions pressable; a translation's as they are (the mentions are counted in the
  /// words as they came).
  Widget _words(Tokens t, ShownView? shown, TextStyle style, Color ink) {
    // Record call's line that came with no card to draw (from a build before its notes): its icon where the emoji was
    // (GMFB-43). Such a line has no mentions to count again.
    final mark = shown == null && message.mentions.isEmpty ? recordingWordsOf(message.text) : null;
    return LinkedText(
        mark?.words ?? shown?.bubble ?? message.text,
        ink: ink,
        style: style,
        before: [if (mark != null) noteIconSpan(t, mark, style)],
        // Changed by its writer since (Matt, 2026-11-20: "I'd like to be able to edit messages sent in circles").
        after: [
          if (message.edited != null) editedMark(style, ink),
        ],
        mentions: shown == null ? message.mentions : const [],
        mentionStyle: mentionStyle(t, on: message.from == room.me && !flat ? ink : null),
        onMention: onMention,
      );
  }

  /// The message as a channel's line ([flat]): the face in a gutter by a run's first message, the name in its role's
  /// colour and the time beside it, and the words, files or sticker under them on the page (lib/ui/flat_line.dart).
  Widget _flat(BuildContext context, ShownView? shown, VoidCallback menu, List<ReactionTally> reacted, ValueChanged<String> react) {
    final t = context.tokens;
    final m = message;
    final mine = m.from == room.me;
    // Your own line is under the name the others read, in the name effect you wear, as theirs are in theirs (Matt,
    // 2026-11-25: "the "you" should say my username and show my selected text effect"). It said You.
    final own = room.name.isNotEmpty ? room.name : Me.instance.shownName;
    final name = mine ? (own.isEmpty ? 'You' : own) : (m.name.isEmpty ? Voice.instance.nameOf(m.from) : m.name);
    return FlatLine(
      name: name,
      nameEffect: mine ? Me.instance.cosmetics.name : (room.present[m.from]?.cosmetics.name ?? ''),
      at: DateTime.fromMillisecondsSinceEpoch(m.at),
      first: first,
      face: (size) => SpaceFace(room: room, id: m.from, name: name, size: size),
      nameInk: spaceNameInk(t, room, m.from),
      badge: (size) => VerifiedBadge(id: m.from, username: room.usernames[m.from], me: m.from == room.me, size: size),
      mentionsMe: mentionsMe,
      onMenu: menu,
      onPerson: onPerson == null ? null : () => onPerson!(m.from),
      reactions: [for (final r in reacted) (emoji: r.emoji, count: r.count, mine: r.mine)],
      reactionsKey: ValueKey('reactions-${m.id}'),
      onReact: room.mayReact ? react : null,
      onAddReaction: room.mayReact ? menu : null,
      body: (context, maxWidth) => _flatBody(context, shown, maxWidth),
    );
  }

  /// What a channel's line says: a plugin's card, a poll, a sticker, or the message it answers, its files, its words and
  /// the cards of their links.
  Widget _flatBody(BuildContext context, ShownView? shown, double maxWidth) {
    final t = context.tokens;
    final m = message;
    final ink = t.color('app-ink');
    final plugin = pluginCardOf(m, mine: m.from == room.me);
    if (plugin != null) return PluginChatCardView(card: plugin.card, plugin: plugin.plugin, maxWidth: math.min(maxWidth, t.lenOf('26rem')));
    if (m.poll != null) return PollCard(room: room, message: m, maxWidth: maxWidth);
    if (m.sticker != null) return SpaceSticker(name: m.sticker!, side: math.min(t.lenOf('8rem'), maxWidth));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (m.reply != null) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: SpaceQuote(reply: m.reply!, me: room.me, ink: ink)),
      if (m.files.isNotEmpty) ...[
        SpaceChatFiles(channel: room.channel, message: m, mine: false, maxWidth: maxWidth, ground: theirBubble(t, onBackground: false), ink: ink, rim: theirRim(t)),
        if (m.text.isNotEmpty) SizedBox(height: t.space(1)),
      ],
      if (shown != null) OriginalCard(view: shown, maxWidth: maxWidth),
      if (m.text.isNotEmpty) _words(t, shown, pageText(t, t.fontSize('md'), color: ink, height: 1.4), ink),
      // Notion links, opened out where the circle has Notion (lib/ui/notion_card.dart).
      ...notionCardsUnder(context, room.channel, m.text, maxWidth: math.min(maxWidth, t.lenOf('30rem'))),
      // Every other link's card, and a GIF's or a picture's link as the picture (lib/ui/link_cards.dart).
      ...linkCardsUnder(context, m.text, skip: (url) => NotionLink.of(url) != null),
    ]);
  }
}

/// A role's name in a small pill: the owner's says Owner.
/// The button in a space's header that opens its members in a drawer (Matt, 2026-11-17: "the member list should show
/// up as a drawer like the add user, it should include a button to switch to add user at the top"). It had put the
/// members in the chat's place, and the chat back.
Widget _membersButton(BuildContext context, HangoutRoom room) =>
    IconTap(key: const ValueKey('space-members'), icon: Lucide.users, label: 'Members', onPressed: () => showSpaceMembers(context, room));

/// [room]'s members in the drawer (lib/ui/circles/members_drawer.dart), with Add people at its top opening the space's
/// invite drawer; greyed for someone the space does not let invite, and left out for a group's space, which nobody is
/// invited into.
Future<void> showSpaceMembers(BuildContext context, HangoutRoom room) => showMembersDrawer(
      context,
      title: 'Members',
      subtitle: room.channel.name,
      list: (_) => SpaceMembers(room: room, shrinkWrap: true),
      onAddPeople: room.channel.group != null ? null : () => showSpaceInvite(context, room.channel),
      mayAdd: room.can(Perm.invite) && _circleInvites(room.channel),
    );

/// Whether a circle's space lets this install invite people (its roles, then the space's own overrides: Deny, As the
/// circle says or Allow; Matt, 2026-11-18: "tri toggles for permissions"). Always outside a circle.
bool _circleInvites(VoiceChannel channel) => Circles.instance.allows(channel, CirclePerm.invite);

/// Everyone a space knows, for its member list and its settings: the owner, whoever is here now, whoever has been given
/// a role, and you; not the banned.
///
/// [withCircle]: in a circle's space, its circle's members too, whether or not they have been in the space yet (its
/// members list; Matt, 2026-11-20: "list the memebers in a given space within the circle").
Map<String, List<String>> spacePeopleByRole(HangoutRoom room, {bool withCircle = false}) {
  final r = room.roster;
  final people = <String>{r.ownerId, ...room.present.keys, ...r.assigned.keys, room.me, if (withCircle) ...spaceCircleMembers(room)}..remove('');
  final byRole = <String, List<String>>{};
  for (final id in people) {
    if (r.banned.contains(id)) continue;
    byRole.putIfAbsent(r.roleOf(id).id, () => []).add(id);
  }
  return byRole;
}

/// A space's members (Matt, 2026-11-17: "add a button to switch the chat to a member list"; now in a drawer,
/// showSpaceMembers), as a chat app's member list is: by role, highest first, each with their face, whether they are
/// here now or in voice, and their role. Pressing someone you outrank changes their role, where you may.
class SpaceMembers extends StatelessWidget {
  const SpaceMembers({super.key, required this.room, this.bottom = 0, this.shrinkWrap = false});
  final HangoutRoom room;

  /// What stands over the list's foot (the pill, the dock): room is left for it.
  final double bottom;

  /// As tall as its rows and no taller, for the drawer, which is as tall as what it holds.
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Listenable.merge([room, Voice.instance]),
      builder: (context, _) {
        final r = room.roster;
        final byRole = spacePeopleByRole(room, withCircle: true);
        final inVoice = Voice.instance.inChannel(room.channel).toSet();
        int order(String id) => inVoice.contains(id) ? 0 : (room.present.containsKey(id) ? 1 : 2);
        final total = byRole.values.fold<int>(0, (n, l) => n + l.length);
        final here = byRole.values.expand((l) => l).where((id) => order(id) < 2).length;
        int byOrder(String a, String b) {
          final o = order(a).compareTo(order(b));
          return o != 0 ? o : _nameOf(room, a).toLowerCase().compareTo(_nameOf(room, b).toLowerCase());
        }

        // The owner under an Owner heading of their own, as a circle's members list has it, so the heading and the
        // pill beside them say the same; then each role, highest first.
        final groups = <(String, Role, List<String>)>[
          if (r.ownerId.isNotEmpty && !r.banned.contains(r.ownerId) && byRole.values.any((l) => l.contains(r.ownerId))) ('Owner', r.roleOf(r.ownerId), [r.ownerId]),
          for (final role in r.ranked)
            if ([for (final id in byRole[role.id] ?? const <String>[]) if (!r.isOwner(id)) id] case final ids when ids.isNotEmpty) (role.name, role, ids..sort(byOrder)),
        ];
        // The count line and the headings on the drawer's gutter, where its head and Add people start.
        return ListView(
          shrinkWrap: shrinkWrap,
          padding: EdgeInsetsDirectional.fromSTEB(DrawerHead.gutter(t), t.space(3), DrawerHead.gutter(t), t.space(4) + bottom),
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: t.space(3)),
              child: Text('$total member${total == 1 ? '' : 's'} · $here here now', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            ),
            for (final (heading, role, ids) in groups) ...[
              DrawerHeading('$heading · ${ids.length}'),
              PaneSection(
                children: [
                  for (final id in ids)
                    SettingRow(
                      // Your face from your own name, as a circle's members list draws it.
                      icon: Opacity(
                        opacity: order(id) == 2 ? 0.5 : 1,
                        // Their picture where they have one; in the call, the ring that says so round their initials.
                        child: inVoice.contains(id)
                            ? _LiveFace(channel: room.channel, id: id == room.me ? 'me' : id, name: id == room.me ? youFaceName() : _nameOf(room, id), size: 30)
                            : SpaceFace(room: room, id: id, name: id == room.me ? youFaceName() : _nameOf(room, id), size: 30),
                      ),
                      label: id == room.me ? 'You' : _nameOf(room, id),
                      labelAfter: VerifiedBadge(id: id, username: room.usernames[id], me: id == room.me, size: 14),
                      // In voice, and what they show the call (GMFB-66).
                      hint: Text(inVoice.contains(id) ? switch (Voice.instance.pictureOf(room.channel, id == room.me ? 'me' : id)) { (camera: _, screen: true) => 'In voice · sharing a screen', (camera: true, screen: _) => 'In voice · camera on', _ => 'In voice' } : (room.present.containsKey(id) ? 'Here now' : 'Away')),
                      labelColor: roleInk(t, role),
                      // Their profile card (Matt, 2026-11-19: "Clicking on a users profile picture or name should open the profile
                      // drawer as well"), with Change role where this device may.
                      onPress: () => showProfile(context, ProfileSubject.ghost(id: id, name: _nameOf(room, id), room: room), more: [
                        if (room.canManage && r.outranks(room.me, id)) Choice('Change role', Lucide.shieldCheck, () => pickRole(context, room, id, _nameOf(room, id))),
                      ]),
                    ),
                ],
              ),
              SizedBox(height: t.space(5)),
            ],
          ],
        );
      },
    );
  }
}

/// Each part of a space's settings in a colour of its own, as Settings' sections are (Matt, 2026-11-17: "add colors to
/// the spaces settings"): the rows' icons sit on a wash of it.
Widget _hued(String hue, Widget section) => GlacierScope(attrs: {'hue': hue}, child: section);

/// A role in words, where a row asks which (Matt, 2026-11-17: "Don't show the badges for owner moderator etc, instead
/// assign role colors like discord does"): its name in its colour (the crown that marked the owner went on 2026-11-18:
/// "Remove the crown icon just use role colors for members and such").
class RoleTag extends StatelessWidget {
  const RoleTag({super.key, required this.role, this.owner = false});
  final Role role;
  final bool owner;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(role.name, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: roleInk(t, role) ?? t.color('app-ink-2'))),
    ]);
  }
}

/// The colour a role's people's names are drawn in; null where it is the text's own ([Role.shownColor]).
/// The colour [id]'s name is drawn in, in [room]'s chat (Matt, 2026-11-19: "users names are not updating in chat to
/// reflect their role status"): in a circle's space, their highest coloured role in the circle (CircleManifest.nameHueOf,
/// as the members list and Discord colour a name), the owner and admins in the admins' colour where no role colours
/// them; elsewhere, the space's own roles. The circle's roles had been ignored here: names kept the space's.
Color? spaceNameInk(Tokens t, HangoutRoom room, String id) {
  final c = Circles.instance.circleOf(room.channel);
  if (c == null) return roleInk(t, room.roster.roleOf(id));
  final m = c.manifest;
  final who = Circles.instance.sameAs(id);
  final hue = m.nameHueOf(who) ?? m.nameHueOf(id);
  if (hue != null) return circleHueInk(t, hue);
  if (m.ownerId == who || m.ownerId == id || m.granted(who) || m.granted(id)) return t.colorOf(Role.defaultColor(Role.admin)!);
  return null;
}

/// The colour a role's people's names are written in; null where the role has none and they are in the text's own.
Color? roleInk(Tokens t, Role role) {
  final c = role.shownColor;
  return c == null ? null : t.colorOf(c);
}


/// The line under a space's name in its header: its description, or else what kind of space it is, or how many are
/// here in a voice space with people in it.
String spaceHeaderLine(VoiceChannel c, HangoutRoom? room) {
  final about = room?.about;
  if (about != null) return about.replaceAll(RegExp(r'\s+'), ' ');
  final here = room?.present.length ?? 0;
  if (c.hasVoice && here > 0) return '$here here';
  return c.kind.label;
}

/// Opens the space's description to write, for the owner and admins (HangoutRoom.setAbout).
void editSpaceAbout(BuildContext context, HangoutRoom room) {
  if (!room.canManage) return;
  unawaited(push<void>(context, (_) => _AboutPage(room: room)));
}

/// The page a space's description is written on.
class _AboutPage extends StatefulWidget {
  const _AboutPage({required this.room});
  final HangoutRoom room;

  @override
  State<_AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<_AboutPage> {
  late final _words = TextEditingController(text: widget.room.about ?? '');

  @override
  void dispose() {
    _words.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ok = await widget.room.setAbout(_words.text);
    if (!mounted) return;
    if (!ok) {
      toast(context, 'Only the owner and admins can change the description.', tone: GlacierToastTone.danger);
      return;
    }
    unawaited(Navigator.of(context).maybePop());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: 'Description',
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        children: [
          PaneSection(
            description: const Tr('Shown under the space\'s name, to everyone in it. Leave it empty to show none.'),
            children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('about-words'),
                  controller: _words,
                  ariaLabel: 'Description',
                  placeholder: 'What this space is for'.t,
                  autoFocus: true,
                  autoCapitalize: TextCapitalization.sentences,
                  maxLength: SpaceAbout.most,
                  size: GlacierFieldSize.md,
                  onSubmitted: (_) => _save(),
                ),
              ),
            ],
          ),
          SizedBox(height: t.space(4)),
          PaneSection(children: [SettingRow(key: const ValueKey('about-save'), icon: AppIcon(Lucide.check, size: 18), label: 'Save', onPress: _save)]),
        ],
      ),
    );
  }
}

/// A hangout's roles: who has which, what each may do, and the role newcomers get. Anyone can read it; the owner and
/// admins change it.
class RolesScreen extends StatelessWidget {
  const RolesScreen({super.key, required this.room, this.settings = false});
  final HangoutRoom room;

  /// As the hangout's settings: its link, sharing it and deleting it around the roles.
  final bool settings;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final r = room.roster;
        final manage = room.canManage;
        final gap = SizedBox(height: t.space(6));
        // Everyone known: here now, or given a role.
        final byRole = spacePeopleByRole(room);
        final c = room.channel;
        return GhostPage(
          title: settings ? c.name : 'Roles and permissions',
          // As a Settings page: each row's icon on its section's colour.
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            children: [
              if (settings) ...[
                _hued('blue', PaneSection(title: 'Space', children: [
                  if (room.can(Perm.invite) && _circleInvites(c)) SettingRow(icon: AppIcon(Lucide.userPlus, size: 18), label: 'Invite people', hint: const Tr('Friends in the app, anyone by a text, or the link.'), onPress: () => showSpaceInvite(context, c)),
                  // Export (GMFB-36): the chat and its threads as a Markdown or JSON file, with its files if asked.
                  SettingRow(icon: AppIcon(Lucide.download, size: 18), label: 'Export chat', hint: const Tr('Every message here, threads too, as Markdown or JSON, with its files if you like.'), onPress: () => exportSpace(context, room)),
                  SettingRow(icon: AppIcon(Lucide.users, size: 18), label: 'Owner', value: Text(r.isOwner(room.me) ? 'You' : (r.hasOwner ? _nameOf(room, r.ownerId) : 'None'))),
                  // What the space is for, under its name in the header; the owner and admins write it (Matt, 2026-11-17).
                  SettingRow(
                    icon: AppIcon(Lucide.fileText, size: 18),
                    label: 'Description',
                    hint: Text(room.about ?? (manage ? 'None yet. Shown under the space\'s name.' : 'None'), maxLines: 2, overflow: TextOverflow.ellipsis),
                    onPress: manage ? () => editSpaceAbout(context, room) : null,
                  ),
                ])),
                gap,
              ],
              if (!r.hasOwner)
                SettingsCallout(child: const Tr('This space was made before roles, so it has no owner: everyone in it is a member, and no one can change that.'))
              else if (!manage)
                SettingsCallout(child: Text('You\'re ${r.isOwner(room.me) ? 'the owner' : 'a ${r.roleOf(room.me).name.toLowerCase()}'}. The owner and admins change roles.')),
              if (r.hasOwner) ...[
                _hued('green', PaneSection(
                  title: 'People',
                  description: const Tr('Press someone to change their role. Admins are made by the owner alone.'),
                  children: [
                    for (final role in r.ranked)
                      for (final id in byRole[role.id] ?? const <String>[])
                        SettingRow(
                          icon: AppIcon(Lucide.users, size: 18),
                          label: id == room.me ? 'You' : _nameOf(room, id),
                          labelColor: roleInk(t, role),
                              value: Text(role.name),
                          onPress: manage && r.outranks(room.me, id) ? () => pickRole(context, room, id, _nameOf(room, id)) : null,
                        ),
                  ],
                )),
                gap,
                _hued('purple', PaneSection(
                  title: 'Roles',
                  description: const Tr('Highest first. A role can act on the ones below it: mute, remove, delete their messages.'),
                  children: [
                    for (final role in r.ranked)
                      SettingRow(
                        icon: AppIcon(role.id == Role.admin ? Lucide.crown : Lucide.shieldCheck, size: 18),
                        label: role.name,
                        hint: Text(role.id == Role.admin ? 'Everything' : (role.perms.isEmpty ? 'Nothing' : role.perms.map((p) => p.label).join(', ')), maxLines: 2, overflow: TextOverflow.ellipsis),
                        value: Text(role.id == r.newcomer ? 'New people' : ''),
                        onPress: () => push(context, (_) => RoleScreen(room: room, roleId: role.id)),
                      ),
                    if (manage)
                      SettingRow(
                        icon: AppIcon(Lucide.plus, size: 18),
                        label: 'Add a role',
                        onPress: () async {
                          final id = 'r${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
                          final ok = await room.saveRole(Role(id: id, name: 'New role', rank: 15, perms: {...Role.defaults.last.perms}));
                          if (ok && context.mounted) unawaited(push(context, (_) => RoleScreen(room: room, roleId: id)));
                        },
                      ),
                  ],
                )),
                gap,
                _hued('mint', PaneSection(
                  title: 'New people',
                  children: [
                    SettingRow(
                      icon: AppIcon(Lucide.userPlus, size: 18),
                      label: 'Join as',
                      value: Text(r.roleById(r.newcomer)?.name ?? 'Member'),
                      onPress: manage
                          ? () => showChoices(context, title: 'New people join as', choices: [
                                for (final role in r.ranked)
                                  if (role.id != Role.admin) Choice('${role.id == r.newcomer ? '✓  ' : ''}${role.name}', Lucide.shieldCheck, () => room.setNewcomer(role.id)),
                              ])
                          : null,
                    ),
                  ],
                )),
                if (settings) ...[
                  gap,
                  _hued('red', PaneSection(title: '', children: [
                    SettingRow(icon: AppIcon(Lucide.trash2, size: 18), label: 'Delete space', hint: const Tr('From this phone and your computer.'), onPress: () => confirmDeleteHangout(context, c)),
                  ])),
                ],
                if (r.banned.isNotEmpty) ...[
                  gap,
                  _hued('coral', PaneSection(
                    title: 'Banned',
                    children: [
                      for (final id in r.banned)
                        SettingRow(
                          icon: AppIcon(Lucide.ban, size: 18),
                          label: _nameOf(room, id),
                          value: manage ? const Tr('Unban') : null,
                          onPress: manage ? () => room.ban(id, on: false) : null,
                        ),
                    ],
                  )),
                ],
              ],
            ],
          ),
          ),
        );
      },
    );
  }
}

/// The name [id] goes by in [room]: what they said here, what they last wrote under, a friend's or a group's name.
String spaceNameOf(HangoutRoom room, String id) => _nameOf(room, id);

/// The members a circle's space has through its circle (they need not have been in the space); none outside a circle.
Iterable<String> spaceCircleMembers(HangoutRoom room) {
  final circle = Circles.instance.circleOf(room.channel);
  if (circle == null) return const [];
  return {...Circles.instance.seenIn(circle).keys, ...Circles.instance.presentIn(circle)};
}

/// A person's name in [room], from the nearest place that knows it: as they say it here now, as their last message
/// had it, as the space's circle saw them, as Voice knows them; else "Someone" with the start of their id.
String _nameOf(HangoutRoom room, String id) {
  final said = room.present[id]?.name;
  if (said != null && said.isNotEmpty) return said;
  for (final m in room.messages.reversed) {
    if (m.from == id && m.name.isNotEmpty) return m.name;
  }
  // Someone seen elsewhere in the space's circle, by the name they gave there.
  final circle = Circles.instance.circleOf(room.channel);
  final seen = circle == null ? '' : (Circles.instance.seenIn(circle)[id] ?? '');
  if (seen.isNotEmpty) return seen;
  final named = Voice.instance.nameOf(id);
  return named == 'Someone' ? 'Someone (${id.substring(0, 6)})' : named;
}

/// One role: its name, and a switch for each thing it may do. Admin may do everything; it can't be changed.
class RoleScreen extends StatefulWidget {
  const RoleScreen({super.key, required this.room, required this.roleId});
  final HangoutRoom room;
  final String roleId;

  @override
  State<RoleScreen> createState() => _RoleScreenState();
}

class _RoleScreenState extends State<RoleScreen> {
  late final _name = TextEditingController(text: widget.room.roster.roleById(widget.roleId)?.name ?? '');

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final room = widget.room;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final role = room.roster.roleById(widget.roleId);
        if (role == null) return const GhostPage(title: 'Role', body: SizedBox.shrink());
        final admin = role.id == Role.admin;
        final edit = room.canManage && !admin;
        final builtIn = Role.defaults.any((d) => d.id == role.id);
        return GhostPage(
          title: role.name,
          body: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            children: [
              if (admin) SettingsCallout(child: const Tr('Admins may do everything, and give out every role but admin. The owner makes admins.')),
              if (edit && !builtIn)
                PaneSection(title: 'Name', children: [
                  SettingRowBox(
                    child: GlacierInput(
                      controller: _name,
                      placeholder: 'Role name'.t,
                      ariaLabel: 'Role name',
                      autoCapitalize: TextCapitalization.words,
                      size: GlacierFieldSize.md,
                      onSubmitted: (x) {
                        if (x.trim().isNotEmpty) room.saveRole(role.copyWith(name: x.trim()));
                      },
                    ),
                  ),
                ]),
              if (edit && !builtIn)
                PaneSection(title: 'Place', description: const Tr('Above Member to act on members; below Moderator to be acted on by moderators.'), children: [
                  SettingRow(
                    icon: AppIcon(Lucide.shieldCheck, size: 18),
                    label: 'Ranks',
                    value: Text(role.rank > 20 ? 'Above Moderator' : role.rank > 10 ? 'Between Member and Moderator' : 'Below Member'),
                    onPress: () => showChoices(context, title: 'Where ${role.name} ranks', choices: [
                      Choice('Above Moderator', Lucide.arrowUp, () => room.saveRole(role.copyWith(rank: 25))),
                      Choice('Between Member and Moderator', Lucide.minus, () => room.saveRole(role.copyWith(rank: 15))),
                      Choice('Below Member', Lucide.arrowDown, () => room.saveRole(role.copyWith(rank: 5))),
                    ]),
                  ),
                ]),
              // The colour its people's names are drawn in, as a Discord role's (Matt, 2026-11-17: "assign role colors like
              // discord does"): any role's, the admins' too, by whoever manages the space.
              PaneSection(title: 'Colour', description: const Tr('Names of people with this role are drawn in it, in the chat and the member list.'), children: [
                SettingRowBox(child: _RoleColours(role: role, enabled: room.canManage, onPick: (c) => room.saveRole(c == null ? role.copyWith(noColor: true) : role.copyWith(color: c)))),
              ]),
              PaneSection(
                title: 'What ${role.name.toLowerCase()}s may do',
                children: [
                  // A Files space's permissions only in a Files space (Perm.files).
                  for (final p in Perm.values.where(Perm.of(room.channel.kind).contains))
                    SettingRow(
                      label: p.label,
                      hint: Text(p.hint),
                      disabled: !edit,
                      control: GlacierSwitch(
                        checked: admin || role.perms.contains(p),
                        disabled: !edit,
                        ariaLabel: p.label,
                        onCheckedChange: (on) => room.saveRole(role.copyWith(perms: on ? {...role.perms, p} : ({...role.perms}..remove(p)))),
                      ),
                    ),
                ],
              ),
              if (edit && !builtIn && role.id != room.roster.newcomer)
                PaneSection(title: '', children: [
                  SettingRow(
                    icon: AppIcon(Lucide.trash2, size: 18),
                    label: 'Delete ${role.name}',
                    hint: const Tr('Whoever has it goes back to the role new people get.'),
                    onPress: () async {
                      if (await room.deleteRole(role.id) && context.mounted) Navigator.of(context).maybePop();
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

/// A role's colour to choose: its own default (Admin red, Moderator blue, the text's own for the rest) and Discord's
/// role colours, the chosen one ringed.
class _RoleColours extends StatelessWidget {
  const _RoleColours({required this.role, required this.enabled, required this.onPick});
  final Role role;
  final bool enabled;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('2rem');
    Widget swatch(String? hex, String label) {
      final shown = hex ?? Role.defaultColor(role.id);
      final chosen = role.color == hex;
      return Semantics(
        button: true,
        selected: chosen,
        label: label,
        child: GestureDetector(
          onTap: enabled ? () => onPick(hex) : null,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: shown == null ? t.color('app-paper-3') : t.colorOf(shown),
              border: Border.all(color: chosen ? t.color('app-ink') : const Color(0x00000000), width: 2.5),
            ),
            alignment: Alignment.center,
            child: hex == null ? AppIcon(chosen ? Lucide.check : Lucide.minus, size: 14, wash: false, color: shown == null ? t.color('app-ink-2') : const Color(0xFFFFFFFF)) : (chosen ? const AppIcon(Lucide.check, size: 14, wash: false, color: Color(0xFFFFFFFF)) : null),
          ),
        ),
      );
    }

    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: t.space(1)),
        child: Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
          swatch(null, 'Default colour'),
          for (final c in Role.palette) swatch(c, 'Colour $c'),
        ]),
      ),
    );
  }
}

/// Chooses [id]'s role: the roles below this device's own (the owner can give admin).
void pickRole(BuildContext context, HangoutRoom room, String id, String name) {
  final r = room.roster;
  final mine = r.isOwner(room.me) ? 1000 : r.roleOf(room.me).rank;
  showChoices(context, title: '$name\'s role', choices: [
    for (final role in r.ranked)
      if (role.rank < mine || (role.id == Role.admin && r.isOwner(room.me)))
        Choice('${r.roleOf(id).id == role.id ? '✓  ' : ''}${role.name}', role.id == Role.admin ? Lucide.crown : Lucide.shieldCheck, () async {
          final ok = await room.setRole(id, role.id);
          if (!ok && context.mounted) toast(context, 'Couldn\'t change their role', tone: GlacierToastTone.danger);
        }),
  ]);
}

/// What can be done about [id] in the hangout from this device, by its role: their role, muting them for everyone,
/// removing them, banning them. In the call's press-and-hold sheet (voice_screen.dart).
class HangoutModeration extends StatelessWidget {
  const HangoutModeration({super.key, required this.room, required this.id, required this.name});
  final HangoutRoom room;
  final String id;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final r = room.roster;
        final above = r.outranks(room.me, id);
        final mutedAll = room.mutedForAll(id);
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SettingRow(
            icon: AppIcon(Lucide.shieldCheck, size: 18),
            label: 'Role',
            value: RoleTag(role: r.roleOf(id), owner: r.isOwner(id)),
            onPress: room.canManage && above ? () => pickRole(context, room, id, name) : null,
          ),
          if (above && room.can(Perm.muteOthers))
            SettingRow(
              icon: AppIcon(Lucide.lock, size: 18),
              label: 'Mute for everyone',
              // What sets it apart from Mute for me, above it in the sheet (GMFB-49).
              hint: const Tr('No one in the space hears them, and they can\'t unmute themselves.'),
              control: GlacierSwitch(checked: mutedAll, onCheckedChange: (on) => room.muteForAll(id, on), ariaLabel: 'Mute $name for everyone'),
            ),
          if (above && room.can(Perm.removeMembers))
            SettingRow(
              icon: AppIcon(Lucide.userMinus, size: 18),
              label: 'Remove from space',
              hint: const Tr('They can come back with the link.'),
              onPress: () {
                room.remove(id);
                Navigator.of(context).maybePop();
              },
            ),
          if (above && room.can(Perm.ban) && room.canManage)
            SettingRow(
              icon: AppIcon(Lucide.ban, size: 18),
              label: 'Ban',
              hint: const Tr('Kept out for good, even with the link.'),
              onPress: () => showChoices(context, title: 'Ban $name? They\'re removed now and can\'t come back.', choices: [
                Choice('Ban', Lucide.ban, () async {
                  await room.ban(id);
                  if (context.mounted) Navigator.of(context).maybePop();
                }, danger: true),
              ]),
            ),
        ]);
      },
    );
  }
}

/// A hangout's menu, held or pressed with the other button on its row (Matt, 2026-11-15: "there also needs to be a
/// context menu to open settings for hangouts and manage permissions and such as well as delete the hangouts"): open
/// it, its settings and roles, invite people into it (space_invite.dart), delete it.
void showHangoutMenu(BuildContext context, VoiceChannel channel, {VoidCallback? onOpen, List<Choice> more = const []}) {
  final v = Voice.instance;
  final room = v.hangoutFor(channel);
  showChoices(context, title: channel.name, choices: [
    if (onOpen != null) Choice('Open', LucideMore.messageCircle, onOpen),
    // Whatever the list it was pressed in has for it: Messages' Snooze (GMFB-36).
    ...more,
    Choice('Settings and permissions', Lucide.shieldCheck, () => push(context, (_) => HangoutSettingsScreen(channel: channel))),
    if (room != null) Choice('Export chat', Lucide.download, () => exportSpace(context, room)),
    if ((room == null || room.can(Perm.invite)) && _circleInvites(channel)) Choice('Invite people', Lucide.userPlus, () => showSpaceInvite(context, channel)),
    Choice('Delete space', Lucide.trash2, () => confirmDeleteHangout(context, channel), danger: true),
  ]);
}

/// Asks first, then leaves [channel]: its call if this phone is in it, and the space itself, off this phone and its
/// computer (Voice.forget), as a swipe on its row asks (Matt, 2026-11-17: "can be swiped to leave a space or delete /
/// archive"). Its link brings it back.
void confirmLeaveHangout(BuildContext context, VoiceChannel channel) {
  showChoices(context, title: 'Leave ${channel.name}? It goes from your list; its link brings you back.', choices: [
    Choice('Leave space', Lucide.logOut, () async {
      final v = Voice.instance;
      if (v.viewing?.seed == channel.seed) v.view(null);
      await v.forget(channel);
      if (context.mounted) toast(context, 'Left ${channel.name}');
    }, danger: true),
  ]);
}

/// Asks first, then takes [channel] off this phone and its computer (Voice.forget). Others keep their copy.
void confirmDeleteHangout(BuildContext context, VoiceChannel channel) {
  showChoices(context, title: 'Delete ${channel.name}? It goes from this phone and your computer; people who have the link keep it.', choices: [
    Choice('Delete space', Lucide.trash2, () async {
      final v = Voice.instance;
      if (v.viewing?.seed == channel.seed) v.view(null);
      await v.forget(channel);
      if (context.mounted) toast(context, 'Deleted ${channel.name}');
    }, danger: true),
  ]);
}

/// A hangout's settings: its link and sharing, its roles and permissions, deleting it. Holds the hangout's room open
/// while shown, so changes reach the others.
class HangoutSettingsScreen extends StatefulWidget {
  const HangoutSettingsScreen({super.key, required this.channel});
  final VoiceChannel channel;

  @override
  State<HangoutSettingsScreen> createState() => _HangoutSettingsScreenState();
}

class _HangoutSettingsScreenState extends State<HangoutSettingsScreen> {
  HangoutRoom? _room;

  @override
  void initState() {
    super.initState();
    _room = Voice.instance.hangoutFor(widget.channel);
    unawaited(Voice.instance.hold(widget.channel).then((r) {
      if (mounted) setState(() => _room = r);
    }));
  }

  @override
  void dispose() {
    unawaited(Voice.instance.release(widget.channel));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null) {
      return GhostPage(title: widget.channel.name, body: Padding(padding: EdgeInsets.all(context.tokens.space(4)), child: SettingsCallout(child: const Tr('The relay server isn\'t connected, so this space\'s settings can\'t be reached right now.'))));
    }
    return RolesScreen(room: room, settings: true);
  }
}

/// Someone's face in a space: their profile picture where they have one, else their initials on their colour as before
/// (Matt, 2026-11-19: "Profile pictures are not loading in circles spaces"). Yours from your profile; anyone else's
/// from the pictures kept here (lib/me/pictures.dart), asked of them once ([HangoutRoom.pictureOf]) where their
/// greeting says they have one this device hasn't got. It was their initials always: the picture was only ever
/// fetched for their profile card.
class SpaceFace extends StatelessWidget {
  const SpaceFace({super.key, required this.room, required this.id, required this.name, required this.size});
  final HangoutRoom room;
  final String id;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => SpacePicture(
        room: room,
        id: id,
        builder: (context, picture) => faceOfPicture(context, picture, size) ?? Avatar(people: [Person(address: 'space:$id', name: name)], size: size),
      );
}

/// Someone in a space's picture as it is kept on this device, given to [builder] (null where they have none, or none
/// has come yet) and again as it changes: what [SpaceFace] frames as a face, and a call's faces and the sidebar's draw
/// in their own shape ([pictureOfSpace]).
class SpacePicture extends StatefulWidget {
  const SpacePicture({super.key, required this.room, required this.id, required this.builder});
  final HangoutRoom room;
  final String id;
  final Widget Function(BuildContext context, String? picture) builder;

  @override
  State<SpacePicture> createState() => _SpacePictureState();
}

class _SpacePictureState extends State<SpacePicture> {
  /// Who has been asked for their picture, by room, so a chat full of their messages asks once.
  static final Map<String, Set<String>> _asked = {};

  @override
  void initState() {
    super.initState();
    ProfilePictures.instance.addListener(_changed);
    Me.instance.addListener(_changed);
  }

  @override
  void dispose() {
    ProfilePictures.instance.removeListener(_changed);
    Me.instance.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// Their picture as it is kept on this device (your own for you), or null; one they say they have that is not
  /// kept yet is asked of them, once for the room.
  String? _picture() {
    final room = widget.room, id = widget.id;
    if (id == room.me) return Me.instance.pictureSharp;
    final hash = room.present[id]?.pictureHash ?? '';
    // Here and saying they have none: none.
    if (room.present.containsKey(id) && hash.isEmpty) return null;
    final kept = ProfilePictures.instance.of(id, hash: hash.isEmpty ? null : hash);
    if (kept == null && hash.isNotEmpty && (_asked[room.channel.room] ??= {}).add(id)) {
      // The answer is kept (ProfilePictures), which redraws every face of theirs; no answer, and the next look asks again.
      unawaited(room.pictureOf(id).then((p) {
        if (p == null) _asked[room.channel.room]?.remove(id);
      }));
    }
    return kept;
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _picture());
}

/// Over a space's box where it has slow mode: how long each person waits, and while this one waits, how long is left
/// (Matt, 2026-11-19: "add ... slow mode").
class _SlowModeLine extends StatelessWidget {
  const _SlowModeLine({required this.seconds, required this.left});
  final int seconds;
  final Duration left;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final waiting = left > Duration.zero;
    return Padding(
      key: ValueKey(waiting ? 'slow-mode-wait' : 'slow-mode-on'),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), t.space(1)),
      child: Row(children: [
        AppIcon(Lucide.hourglass, size: 13, color: t.color('app-ink-3')),
        SizedBox(width: t.space(1) + 2),
        Expanded(
          child: Text(
            waiting ? 'Slow mode: you can write again in ${slowModeLeft(left)}' : 'Slow mode: one message every ${slowModeLabel(seconds)}',
            style: pageText(t, t.fontSize('xs'), weight: waiting ? 'semibold' : 'regular', color: t.color(waiting ? 'app-ink-2' : 'app-ink-3')),
          ),
        ),
      ]),
    );
  }
}

