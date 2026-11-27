import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../split_handle.dart';
import '../window_chrome.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_type.dart';
import '../../voice/roles.dart';
import '../connecting_banner.dart';
import '../hangout_screen.dart' show roleInk;
import '../ripple_avatar.dart';
import '../skeleton.dart';
import '../tile_grid.dart';
import '../voice_screen.dart' show TileTool, TileTools, ownVideoTools;
import 'space_design.dart';

/// A space's call, laid out as Telegram's group voice chat (the one way a space's call is drawn: space_design.dart):
/// headed by the space's name and how many are in voice, video tiles two across above a list of people, and at the foot
/// one big microphone button with two round buttons either side of it. Drawn in Uplink's own look, light or dark as the app is (Matt,
/// 2026-11-16: "Change the telegram one to be our colors without the gradients and our voice effects make the chat
/// window 33% of the screen"): flat paper and ink, hairlines, and the app's wobbly green ripples (RippleAvatar) round
/// whoever talks and round the microphone while you are live. No gradients anywhere. Made the app's own in its words
/// too (Matt, 2026-11-16: "make it ours and less like telegram"): talking, listening, muted; Mic on and Muted; the
/// app's RoleTag; no sheet grabber; corners and gaps from the app's tokens.
///
/// On a phone the chat opens as a second sheet over the voice chat; on a computer it is docked beside it, a third of
/// the window wide, open from the start.
class TelegramCall extends StatefulWidget {
  const TelegramCall({super.key, required this.call});
  final SpaceCall call;

  @override
  State<TelegramCall> createState() => _TelegramCallState();
}

/// The app's talking green and its red (as lib/ui/voice_screen.dart and lib/ui/ripple_avatar.dart use them).
Color _green(Tokens t) => t.colorOf('#2fb35a');
Color _red(Tokens t) => t.colorOf('#dd3a30');

class _TelegramCallState extends State<TelegramCall> {
  /// The chat beside or over the call; null until pressed, when a computer shows it and a phone does not.
  bool? _chat;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final call = widget.call;
    final media = MediaQuery.of(context);
    return SizedBox.expand(
      child: ColoredBox(
        color: t.color('glacier-bg'),
        child: LayoutBuilder(builder: (context, box) {
          // The top of a computer's pane, its chat under it (SpaceSplit): the computer's panel, without a chat of its own,
          // however short the part it is given.
          if (call.chatBelow) return _computer(context, call, box, media, false, () {});
          final wide = box.maxWidth >= 760 && box.maxHeight >= 480;
          final chat = _chat ?? wide;
          void toggleChat() => setState(() => _chat = !chat);
          if (wide) return _computer(context, call, box, media, chat, toggleChat);
          return _phone(context, call, media, chat, toggleChat);
        }),
      ),
    );
  }

  /// The voice chat as a sheet with rounded top corners; open, the chat is a second sheet over it, behind a dimmed
  /// layer that closes it when tapped.
  Widget _phone(BuildContext context, SpaceCall call, MediaQueryData media, bool chat, VoidCallback toggleChat) {
    final t = context.tokens;
    final pad = media.padding;
    final top = BorderRadius.vertical(top: Radius.circular(t.radius('xl')));
    // Typing, the message bar stands just above the keyboard (Matt, 2026-11-16: "the chatbar doesn't move up when in
    // the chat section of a space"). The chat adds the screen's own foot to what it is given, so the keyboard's height
    // less that foot puts the bar on the keyboard; without a keyboard, room for the foot as before.
    final keyboard = media.viewInsets.bottom;
    final chatBottom = keyboard > 0 ? math.max(1.0, keyboard - pad.bottom) : pad.bottom;
    return ColoredBox(
      color: t.color('app-paper-2'),
      child: Stack(children: [
        Positioned.fill(
          top: pad.top + t.space(2),
          child: Container(
            decoration: BoxDecoration(color: t.color('glacier-bg'), borderRadius: top, border: Border(top: BorderSide(color: t.color('app-rule')))),
            child: _VoicePanel(call: call, chatOpen: chat, onChat: toggleChat, bottom: pad.bottom),
          ),
        ),
        if (chat) ...[
          Positioned.fill(
            child: GestureDetector(onTap: toggleChat, child: const ColoredBox(color: Color(0x66000000))),
          ),
          Positioned.fill(
            top: pad.top + t.space(2) + 58 + t.space(1),
            child: ClipRRect(
              borderRadius: top,
              child: _ChatPanel(call: call, onClose: toggleChat, bottom: chatBottom),
            ),
          ),
        ],
      ]),
    );
  }

  /// The voice chat and, open, the chat docked to its right: the chat a third of the window, the voice chat the rest.
  Widget _computer(BuildContext context, SpaceCall call, BoxConstraints box, MediaQueryData media, bool chat, VoidCallback toggleChat) {
    final t = context.tokens;
    // A third of the window, or as dragged (lib/ui/split_handle.dart): from 280 to what leaves the voice chat 380.
    _chatWidth ??= PaneWidth.of(AppState.of(context), 'call_chat');
    double fit(double w) => w.clamp(280.0, (box.maxWidth - 380).clamp(280.0, double.infinity));
    final side = chat ? fit(_chatWidth ?? box.maxWidth / 3) : 0.0;
    final voice = box.maxWidth - side;
    final grip = SplitHandle.widthOf(context);
    return Stack(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        key: const ValueKey('tg-voice-panel'),
        width: voice,
        child: Padding(
          padding: EdgeInsets.only(top: media.padding.top),
          child: _VoicePanel(call: call, chatOpen: chat, onChat: toggleChat, bottom: media.padding.bottom, compact: true, maxWidth: 620),
        ),
      ),
      if (chat)
        Container(
          key: const ValueKey('tg-chat-panel'),
          width: side,
          padding: EdgeInsets.only(top: media.padding.top),
          decoration: BoxDecoration(
            color: t.color('glacier-bg'),
            border: Border(left: BorderSide(color: t.color('app-rule'))),
          ),
          child: _ChatPanel(call: call, onClose: toggleChat, bottom: media.padding.bottom),
        ),
      ]),
      if (chat)
        PositionedDirectional(
          key: const ValueKey('tg-chat-split'),
          start: voice - grip / 2,
          top: 0,
          bottom: 0,
          width: grip,
          child: SplitHandle(
            label: 'Resize the chat',
            onDrag: (dx) => setState(() => _chatWidth = fit(fit(_chatWidth ?? side) - dx)),
            onDone: () => PaneWidth.keep(AppState.of(context), 'call_chat', _chatWidth),
            onReset: () {
              setState(() => _chatWidth = null);
              PaneWidth.keep(AppState.of(context), 'call_chat', null);
            },
          ),
        ),
    ]);
  }

  /// The chat's width as dragged, kept between calls (PaneWidth 'call_chat'); null for a third of the window.
  double? _chatWidth;
}

/// The voice chat itself: header, the people, the buttons. Holds the header's menu.
class _VoicePanel extends StatefulWidget {
  const _VoicePanel({required this.call, required this.chatOpen, required this.onChat, required this.bottom, this.compact = false, this.maxWidth});
  final SpaceCall call;
  final bool chatOpen;
  final VoidCallback onChat;
  final double bottom;

  /// Rows a little tighter, as on a computer.
  final bool compact;

  /// The people and the buttons no wider than this, centred (a computer's wide panel); the header spans it all.
  final double? maxWidth;

  @override
  State<_VoicePanel> createState() => _VoicePanelState();
}

class _VoicePanelState extends State<_VoicePanel> {
  bool _menu = false;

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    Widget narrow(Widget child) => widget.maxWidth == null ? child : Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: widget.maxWidth!), child: child));
    return Stack(children: [
      Column(children: [
        _Header(call: call, onMenu: () => setState(() => _menu = !_menu), menuOpen: _menu),
        // The people keep to the middle; with video on, the videos take the panel's whole width (GMFB-58), so the
        // people narrow themselves (_People).
        Expanded(child: _People(call: call, compact: widget.compact, maxWidth: widget.maxWidth)),
        narrow(_Controls(call: call, chatOpen: widget.chatOpen, onChat: widget.onChat, bottom: widget.bottom)),
      ]),
      if (_menu) ...[
        Positioned.fill(child: GestureDetector(onTap: () => setState(() => _menu = false), child: const ColoredBox(color: Color(0x00000000)))),
        PositionedDirectional(
          top: 58,
          end: context.tokens.space(3),
          child: _Menu(call: call, close: () => setState(() => _menu = false)),
        ),
      ],
    ]);
  }
}

/// The space's name and how many are in voice ("Just you" alone); Minimise on the left, the menu on the right.
class _Header extends StatelessWidget {
  const _Header({required this.call, required this.onMenu, required this.menuOpen});
  final SpaceCall call;
  final VoidCallback onMenu;
  final bool menuOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = call.count;
    final name = call.channel.name.isEmpty ? 'Space' : call.channel.name;
    // On the Mac this page covers the window, so its header is the top bar: dragged to move the window, and clear of
    // the three buttons at its left (lib/ui/window_chrome.dart).
    return WindowDragArea(
      child: SizedBox(
      height: 58,
      child: Row(children: [
        // In a pane (SpaceSplit) it is not at the window's left, so the lights are not beside it.
        SizedBox(width: (MacChrome.enabled && !call.chatBelow ? MacChrome.lightsRoom - t.space(3) : 0) + t.space(3)),
        // A back arrow, as every page's way back is (Matt, 2026-11-17: "make the down chevron a back arrow as well"): it still
        // puts the call away to its banner. In a pane the call is the space's own page, with nothing to put it away to:
        // the room is kept, so the name stays in the middle.
        if (call.onMinimize == null && call.chatBelow) const SizedBox(width: 38) else _IconButton(icon: Lucide.arrowLeft, label: 'Back', onPressed: call.onMinimize),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
            const SizedBox(height: 1),
            // On a stage, how many listen, said to everyone in it (GMFB-29); hands raised, to whoever manages it.
            Text(call.wait?.title ?? (call.listening != null ? SpaceCall.stageLine(call.listening!, hands: call.hands) : (n <= 1 ? 'Just you' : '$n in voice')), key: call.wait == null && call.listening != null ? const ValueKey('tg-stage-line') : null, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            // Bridged to Discord: its sound and chat pass through the bridge, so say what that costs.
            if (call.bridged) Text('Bridged to Discord · not end-to-end encrypted', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
          ]),
        ),
        _IconButton(icon: Lucide.ellipsisVertical, label: _menuLabel, onPressed: onMenu, on: menuOpen),
        SizedBox(width: t.space(3)),
      ]),
      ),
    );
  }
}

/// The header menu's words for a screen reader: what it holds.
final _menuLabel = 'More: ${[SpaceWords.invite, SpaceWords.devices, SpaceWords.settings, SpaceWords.leave].join(', ').toLowerCase()}';

/// A round icon in a header, its words for a screen reader.
class _IconButton extends StatelessWidget {
  const _IconButton({required this.icon, required this.label, required this.onPressed, this.on = false});
  final LucideIcon icon;
  final String label;
  final VoidCallback? onPressed;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: GlacierPressable(
        onPressed: onPressed,
        semanticLabel: label,
        builder: (context, state) => Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(shape: BoxShape.circle, color: t.color(on || state.hovered || state.pressed ? 'app-paper-3' : 'app-paper-2')),
          alignment: Alignment.center,
          child: AppIcon(icon, size: 20, wash: false, color: t.color('app-ink')),
        ),
      ),
    );
  }
}

/// The header's menu: invite, devices, the space's settings, leave.
class _Menu extends StatelessWidget {
  const _Menu({required this.call, required this.close});
  final SpaceCall call;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    void Function()? run(void Function(BuildContext)? action) => action == null
        ? null
        : () {
            close();
            action(context);
          };
    return Container(
      width: 270,
      padding: EdgeInsets.symmetric(vertical: t.space(1)),
      decoration: BoxDecoration(
        color: t.color('app-paper'),
        borderRadius: BorderRadius.circular(t.radius('lg')),
        border: Border.all(color: t.color('app-rule')),
        boxShadow: t.shadowOf('0 8px 28px rgba(0,0,0,0.22)'),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _MenuRow(icon: Lucide.userPlus, label: SpaceWords.invite, hint: 'Friends, a text or the link', onPressed: run(call.onInvite)),
        _MenuRow(icon: LucideMore.headphones, label: SpaceWords.devices, hint: 'Microphone, camera and speaker', onPressed: run(call.onDevices)),
        // The other camera (GMFB-57) was here; it is over one's own video now, and in what a press on it opens
        // (GMFB-70, Matt: "Move the flip video setting to show up as a button hovered over the video when available
        // and add it to the menu that pops up when tapping on a video").
        _MenuRow(icon: Lucide.settings, label: SpaceWords.settings, hint: 'Roles and permissions', onPressed: run(call.onSettings)),
        // What the plugins that are on in this call offer (Slots.callControls).
        for (final x in call.extras) _MenuRow(icon: x.icon, label: x.label, hint: x.hint ?? (x.builtIn ? 'A screen or a window, to everyone here' : 'A plugin'), danger: x.danger, onPressed: run(x.run)),
        Container(height: 1, margin: EdgeInsets.symmetric(vertical: t.space(1)), color: t.color('app-rule')),
        _MenuRow(
          icon: LucideMore.phoneOff,
          label: SpaceWords.leave,
          hint: 'Leave voice',
          danger: true,
          onPressed: call.onLeave == null
              ? null
              : () {
                  close();
                  call.onLeave!();
                },
        ),
      ]),
    );
  }
}

/// A line of the menu: an icon, a name and a quieter hint under it.
class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, required this.hint, required this.onPressed, this.danger = false});
  final LucideIcon icon;
  final String label, hint;
  final VoidCallback? onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = danger ? _red(t) : t.color('app-ink');
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: GlacierPressable(
        onPressed: onPressed,
        semanticLabel: label,
        builder: (context, state) => Container(
          color: state.hovered || state.pressed ? t.color('app-paper-2') : null,
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
          child: Row(children: [
            AppIcon(icon, size: 20, wash: false, color: danger ? _red(t) : t.color('app-ink-2')),
            SizedBox(width: t.space(4)),
            Expanded(
              child: ExcludeSemantics(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink)),
                Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              ])),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Video tiles two across, "Invite to space", then everyone in a list.
class _People extends StatelessWidget {
  const _People({required this.call, this.compact = false, this.maxWidth});
  final SpaceCall call;
  final bool compact;

  /// The list of people no wider than this, centred (a computer's wide panel). The videos are not held to it.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final videos = call.withVideo;
    final alone = call.others.isEmpty;
    final roster = call.room?.roster;
    // A face of 38 whose ripples reach 1.85 times its radius (about 35 px) needs rows of about 70 for its rings to
    // stay inside its own row: 16 above and below (14 where the panel is docked and short).
    final rowPad = compact ? 14.0 : 16.0;
    // On a computer with video on, the videos get the room (GMFB-58, @kevin, Windows 0.12.17: "The video call window
    // is far too vertically slim for regular use"): they were held to the list's 620 across and one alone to 200 high,
    // a strip in a window of any size, and shrank further for the list. There they now span the panel and take most
    // of its height, and the list scrolls under them. A phone is as it was.
    final roomy = compact && maxWidth != null && videos.isNotEmpty;
    Widget narrow(Widget child) => maxWidth == null ? child : Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth!), child: child));
    final people = LayoutBuilder(builder: (context, box) {
      // On a phone the video gives way to the list: its tiles shrink (to no less than 84 a row) so everyone in the
      // call fits under them where the panel is short.
      // The invite row, the rows, and the list's padding and gap under the video (the app's spacing, which grows a
      // little on a wide window).
      final line = call.wait == null ? 0.0 : ConnectingBanner.height + t.space(2);
      final list = line + 48 + (call.people.length + call.coming) * (_faceSize + rowPad * 2 + 1) + t.space(1) + t.space(3) * 2 + 2;
      final room = box.maxHeight - list;
      return ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), t.space(3)),
        children: [
          // What the call is still waiting for, above its people: "Connecting… Starting the microphone" with an arc
          // turning, from the press on Join until someone can be heard, then "Connected" for a moment
          // (lib/ui/connecting_banner.dart). Nothing, and no room kept, once it is through.
          Padding(
            padding: EdgeInsets.symmetric(horizontal: roomy ? math.max(0.0, (box.maxWidth - maxWidth!) / 2) : 0),
            child: ConnectingBanner(wide: true, padding: EdgeInsets.only(bottom: t.space(2))),
          ),
          if (videos.isNotEmpty) ...[
            // Roomy: four fifths of the panel's height, or all the list leaves where that is more.
            _VideoGrid(call: call, people: videos, room: roomy ? math.max(room, box.maxHeight * 0.8) : room, roomy: roomy, most: box.maxHeight * 0.6),
            SizedBox(height: t.space(3)),
          ],
          Container(
            // Roomy, the list keeps the width it had (the panel's 620 less the padding either side).
            margin: EdgeInsets.symmetric(horizontal: roomy ? math.max(0.0, (box.maxWidth - maxWidth!) / 2) : 0),
            decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('xl')), border: Border.all(color: t.color('app-rule'))),
            // Not clipped: a speaker's outermost ring may lean a pixel or two past the card rather than be cut flat.
            // The rows round their own hover at the card's corners instead.
            child: Column(children: [
              _InviteRow(onPressed: call.onInvite == null ? null : () => call.onInvite!(context)),
              for (final p in call.people) ...[
                Container(height: 1, margin: const EdgeInsetsDirectional.only(start: _textStart), color: t.color('app-rule')),
                _PersonRow(call: call, person: p, role: p.roleLabel(roster), pad: rowPad, last: identical(p, call.people.last)),
              ],
              // Those in the call who are not here yet, while it is being come into: in bones (SpaceCall.coming).
              if (call.coming > 0)
                Skeleton(
                  key: const ValueKey('tg-coming'),
                  label: call.coming == 1 ? '1 person in the call' : '${call.coming} people in the call',
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < call.coming; i++) ...[
                      Container(height: 1, margin: const EdgeInsetsDirectional.only(start: _textStart), color: t.color('app-rule')),
                      Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(_rowLeft, rowPad - t.space(2), 14, rowPad - t.space(2)),
                        child: SkeletonPeople.row(t, i, face: _faceSize, second: false),
                      ),
                    ],
                  ]),
                ),
            ]),
          ),
          if (alone) ...(call.chatBelow ? _waitingFit(t, room) : [
            SizedBox(height: t.space(10)),
            Column(children: [
              // You, large, your voice moving the ripples round you while you wait.
              SpaceFace(key: const ValueKey('tg-alone-me'), call: call, person: call.me, size: 88),
              SizedBox(height: t.space(10)),
              onceThrough(call, Text('Waiting for others to join', key: const ValueKey('tg-waiting'), textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink')))),
              SizedBox(height: t.space(1)),
              onceThrough(call, Text('Invite people, and they\'ll show up here as they join.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
            ]),
          ]),
        ],
      );
    });
    return roomy ? people : narrow(people);
  }

  /// Waiting alone, in the split's top part (SpaceSplit): as much of the waiting block as fits in [room], the height
  /// the list leaves above the buttons, so that nothing is cut and nothing scrolls. In turn: the large face with both
  /// lines; a smaller face; the line alone without the face; without the line under it; nothing.
  List<Widget> _waitingFit(Tokens t, double room) {
    final title = onceThrough(call, Text('Waiting for others to join', key: const ValueKey('tg-waiting'), textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))));
    final sub = onceThrough(call, Text('Invite people, and they\'ll show up here as they join.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))));
    // The lines' heights as drawn (a line is about 1.5 times its size), with a little to spare.
    final titleH = t.fontSize('md') * 1.6, subH = t.fontSize('sm') * 1.6;
    final lines = titleH + t.space(1) + subH;
    // The ripples reach 1.85 times the face's radius: the gaps round a face leave them room.
    for (final (face, gap) in [(88.0, t.space(10)), (56.0, t.space(6)), (40.0, t.space(5))]) {
      if (room >= gap * 2 + face + lines) {
        return [
          SizedBox(height: gap),
          Column(children: [SpaceFace(key: const ValueKey('tg-alone-me'), call: call, person: call.me, size: face), SizedBox(height: gap), title, SizedBox(height: t.space(1)), sub]),
        ];
      }
    }
    if (room >= t.space(4) + lines) return [SizedBox(height: t.space(4)), Column(children: [title, SizedBox(height: t.space(1)), sub])];
    if (room >= t.space(3) + titleH) return [SizedBox(height: t.space(3)), title];
    return const [];
  }
}


/// The first row of the list of people, in the accent colour: "Invite to space".
class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = t.color('app-accent');
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: GlacierPressable(
        onPressed: onPressed,
        semanticLabel: _inviteWords,
        builder: (context, state) => Container(
          decoration: BoxDecoration(
            color: state.hovered || state.pressed ? t.color('app-paper-3') : null,
            borderRadius: BorderRadius.vertical(top: Radius.circular(t.radius('xl') - 1)),
          ),
          padding: const EdgeInsetsDirectional.fromSTEB(_rowLeft, 12, 14, 12),
          child: Row(children: [
            SizedBox(width: _faceSize, child: Center(child: AppIcon(Lucide.link, size: 22, wash: false, color: ink))),
            const SizedBox(width: _faceGap),
            Expanded(child: ExcludeSemantics(child: Text(_inviteWords, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink)))),
          ]),
        ),
      ),
    );
  }
}

const _inviteWords = 'Invite to space';

/// The list's face, its left inset and the gap to the name: the rings (to 1.85 × 19 ≈ 35 px from the face's middle)
/// end at 72, short of the name at [_textStart].
const double _faceSize = 38;
const double _rowLeft = 18;
const double _faceGap = 18;
const double _textStart = _rowLeft + _faceSize + _faceGap;

/// What someone is doing now, in the list's words and colour: green talking, red muted, quiet ink listening.
({String words, Color color, LucideIcon icon}) _status(Tokens t, SpaceCall call, SpacePerson p, Map<String, double> now) {
  // The music played to the call: what plays, or that it is paused.
  if (p.music) return (words: p.doing!, color: p.doing == 'paused' ? t.color('app-ink-3') : _green(t), icon: LucideMore.music);
  // Which mute it is (GMFB-49): a moderator's for everyone, this device's own of them, or theirs of themselves.
  if (p.muted && (p.mutedForAll || p.mutedForMe)) return (words: SpaceWords.mutedWords(p), color: _red(t), icon: SpaceWords.mutedIcon(p));
  if (p.muted) return (words: p.me && call.micLocked && !call.micLockedByRole ? 'muted by a moderator' : 'muted', color: _red(t), icon: LucideMore.micOff);
  if (call.isTalking(p, now)) return (words: 'talking', color: _green(t), icon: Lucide.mic);
  return (words: 'listening', color: t.color('app-ink-3'), icon: Lucide.mic);
}

/// One person in the list: the face with its talking rings, the name, and what they are doing now ([_status]).
/// Pressing or holding the row opens what can be done with them.
class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.call, required this.person, required this.role, this.pad = 16, this.last = false});
  final SpaceCall call;
  final SpacePerson person;

  /// The role worth showing beside them (SpacePerson.roleLabel), shown as the app's RoleTag; null for none.
  final String? role;
  final double pad;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = person;
    return GlacierPressable(
      onPressed: call.onPerson == null ? null : () => call.onPerson!(context, p),
      onLongPress: call.onPerson == null ? null : () => call.onPerson!(context, p),
      semanticLabel: p.shown,
      builder: (context, state) => ValueListenableBuilder<Map<String, double>>(
        valueListenable: call.levels,
        builder: (context, now, _) {
          final s = _status(t, call, p, now);
          final level = p.muted ? 0.0 : (now[p.id] ?? 0);
          return Container(
            decoration: BoxDecoration(
              color: state.hovered || state.pressed ? t.color('app-paper-3') : null,
              borderRadius: last ? BorderRadius.vertical(bottom: Radius.circular(t.radius('xl') - 1)) : null,
            ),
            padding: EdgeInsetsDirectional.fromSTEB(_rowLeft, pad, 14, pad),
            child: Row(children: [
              ExcludeSemantics(child: SpaceFace(key: ValueKey('tg-face-${p.id}'), call: call, person: p, size: _faceSize)),
              const SizedBox(width: _faceGap),
              Expanded(
                child: ExcludeSemantics(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    // Their role's colour, and the owner's crown, instead of a tag (Matt, 2026-11-17).
                    Flexible(child: Text(p.shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: (role != null ? roleInk(t, p.role ?? _ownerRole) : null) ?? t.color('app-ink')))),
                    // A guest as the app's call list shows one: the word, quiet, after the name.
                    if (p.guest) ...[SizedBox(width: t.space(2)), Text('guest', maxLines: 1, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))],
                    if (p.tag != null) ...[SizedBox(width: t.space(2)), Text(p.tag!, maxLines: 1, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))],
                  ]),
                  const SizedBox(height: 2),
                  Text(s.words, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: s.words == 'listening' ? 'regular' : 'semibold', color: s.color)),
                ])),
              ),
              const SizedBox(width: 8),
              if (p.video) Padding(padding: const EdgeInsetsDirectional.only(end: 10), child: AppIcon(Lucide.video, size: 18, wash: false, color: t.color('app-ink-3'))),
              _MicMark(icon: s.icon, color: s.color, level: level),
            ]),
          );
        },
      ),
    );
  }
}

/// RoleTag wants a role; an owner with none known reads as Owner all the same (RoleTag shows "Owner" for an owner).
final _ownerRole = Role.defaults.first;

/// The row's microphone, swelling a little with the voice.
class _MicMark extends StatelessWidget {
  const _MicMark({required this.icon, required this.color, required this.level});
  final LucideIcon icon;
  final Color color;
  final double level;

  @override
  Widget build(BuildContext context) => AnimatedScale(
        scale: 1 + (level > SpaceCall.talking ? math.min(level, 0.6) * 0.35 : 0),
        duration: const Duration(milliseconds: 120),
        child: AppIcon(icon, size: 22, wash: false, color: color),
      );
}

/// Everyone with video on: on a computer 4:3 tiles as large as fit ([roomy]); on a phone two across (one alone, or the
/// last of an odd number, across the whole width), each the shape of its own picture once that is known.
class _VideoGrid extends StatelessWidget {
  const _VideoGrid({required this.call, required this.people, required this.room, this.roomy = false, this.most = double.infinity});

  /// On a phone, the tallest a tile shaped as its picture may be (GMFB-71): an upright phone's picture across the
  /// whole width would be taller than the screen, so it is drawn narrower, whole, in the middle.
  final double most;
  final SpaceCall call;
  final List<SpacePerson> people;

  /// The height the list leaves for the grid; its rows shrink to fit it, to no less than 84 each.
  final double room;

  /// On a computer (GMFB-58): tiles shaped 4:3 (Matt, 2026-11-23) and as large as [room] and the width allow, as many across as makes
  /// them largest, no row under 240 high (the list scrolls instead); the grid in the middle.
  final bool roomy;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final gap = context.tokens.space(2);
      if (roomy) {
        final n = people.length;
        var w = 0.0, h = 0.0;
        // From everyone in one row to one a row: fewer across only where that makes the tiles clearly larger.
        for (var across = n; across >= 1; across--) {
          final rows = (n / across).ceil();
          // Whole pixels, so a row's tiles never add up to a hair more than the width and wrap.
          final cell = ((box.maxWidth - gap * (across - 1)) / across).floorToDouble();
          final high = math.min(cell / tileAspect, math.max(240.0, (room - gap * (rows - 1)) / rows));
          if (high > h * 1.15) {
            h = high;
            w = math.min(cell, high * tileAspect);
          }
        }
        return SizedBox(
          width: box.maxWidth,
          child: Wrap(alignment: WrapAlignment.center, spacing: gap, runSpacing: gap, children: [
            for (final p in people) SizedBox(width: w, height: h, child: _VideoTile(call: call, person: p)),
          ]),
        );
      }
      final half = (box.maxWidth - gap) / 2;
      final rows = (people.length + 1) ~/ 2;
      final fit = math.max(84.0, (room - gap * (rows - 1)) / rows);
      final pair = math.min(half * 0.82, fit);
      final wide = math.min(math.min(box.maxWidth * 9 / 16, 200.0), fit);
      // A phone's tile is the shape of the picture in it, so the whole of what the camera films shows (GMFB-71, Matt:
      // "Videos are still rectangular on mobile and don't show the whole camera resolution"): tiles were a fixed wide
      // strip (one alone 200 high across the screen) and an upright phone's 9:16 picture lost most of itself to fit.
      // Each keeps its place two across, as wide as that allows and no taller than [most]; the list scrolls under
      // them. Until a picture's shape is known (and for a face, with video not here yet) the tile is as it was.
      Widget cell(SpacePerson p, double across, double high) {
        final shape = p.screen ? null : p.shape;
        if (shape == null) return SizedBox(width: across, height: high, child: _VideoTile(call: call, person: p));
        final size = wholeTile(width: across, shape: shape, most: most);
        return SizedBox(width: across, child: Center(child: SizedBox(key: ValueKey('tg-whole-${p.id}'), width: size.width, height: size.height, child: _VideoTile(call: call, person: p, whole: true))));
      }

      return Wrap(spacing: gap, runSpacing: gap, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (var i = 0; i < people.length; i++)
          if (people.length.isOdd && i == people.length - 1) cell(people[i], box.maxWidth, wide) else cell(people[i], half, pair),
      ]);
    });
  }
}

/// Someone whose camera is on, as a rounded tile: their picture (the face until it comes), edged green while they
/// talk.
class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.call, required this.person, this.whole = false});
  final SpaceCall call;
  final SpacePerson person;

  /// The tile is the picture's own shape: drawn whole (GMFB-71).
  final bool whole;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final p = person;
    // Over one's own camera's picture: the other camera (GMFB-70), or the choice of cameras (GMFB-68).
    final tools = p.me && p.video && !p.screen
        ? ownVideoTools(onFlip: call.onFlip, onCamera: call.onCamera == null ? null : () => call.onCamera!(context))
        : const <TileTool>[];
    return TileTools(
      tools: tools,
      child: GlacierPressable(
      onPressed: call.onPerson == null ? null : () => call.onPerson!(context, p),
      semanticLabel: '${p.shown}, video',
      builder: (context, state) => ValueListenableBuilder<Map<String, double>>(
        valueListenable: call.levels,
        builder: (context, now, _) {
          final talking = call.isTalking(p, now);
          final s = _status(t, call, p, now);
          // Rings round the whole tile, where there is a picture in it and so no face to ring.
          return VoiceRipples(
            level: p.video && p.stream != null ? now[p.id] ?? 0 : 0,
            muted: p.muted,
            color: _green(t),
            reach: 14,
            corner: t.radius('xl'),
            builder: (context, _) => Container(
            decoration: BoxDecoration(
              color: t.color('app-paper-2'),
              borderRadius: BorderRadius.circular(t.radius('xl')),
              border: Border.all(color: talking ? _green(t) : t.color('app-rule'), width: talking ? 2.5 : 1),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.radius('xl') - (talking ? 2.5 : 1)),
              child: Stack(fit: StackFit.expand, children: [
                SpaceVideo(
                  call: call,
                  person: p,
                  whole: whole,
                  // The face in the middle of the part above the name chip (the chip's top is 28 from the foot), sized
                  // so its ripples, which reach 1.85 times its radius, stay above the chip too.
                  fallback: LayoutBuilder(builder: (context, box) {
                    final above = math.max(0.0, box.maxHeight - 30);
                    return Stack(children: [
                      PositionedDirectional(
                        start: 0,
                        end: 0,
                        top: 0,
                        height: above,
                        child: Center(child: ExcludeSemantics(child: SpaceFace(key: ValueKey('tg-tile-${p.id}'), call: call, person: p, size: math.min(56.0, above / 1.85)))),
                      ),
                    ]);
                  }),
                ),
                // The name on a flat chip of the page's paper, readable over a picture too.
                PositionedDirectional(
                  start: 8,
                  bottom: 8,
                  end: 8,
                  child: Row(children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsetsDirectional.fromSTEB(7, 3, 9, 3),
                        decoration: BoxDecoration(color: t.color('glacier-bg').withValues(alpha: 0.9), borderRadius: BorderRadius.circular(t.radius('full'))),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          AppIcon(s.icon, size: 14, wash: false, color: s.words == 'listening' ? t.color('app-ink-2') : s.color),
                          const SizedBox(width: 4),
                          Flexible(child: ExcludeSemantics(child: Text(p.shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink'))))),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ));
        },
      ),
    ));
  }
}

/// The foot: Video and Deafen, the big microphone, Chat and Leave.
class _Controls extends StatelessWidget {
  const _Controls({required this.call, required this.chatOpen, required this.onChat, required this.bottom});
  final SpaceCall call;
  final bool chatOpen;
  final VoidCallback onChat;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    Widget side(Widget child) => Expanded(child: Center(child: child));
    final leave = _RoundButton(icon: Lucide.x, label: SpaceWords.leave, danger: true, onPressed: call.onLeave);
    // Under the call with the chat below it (SpaceSplit) the buttons are a group in the middle, each in a slot of the
    // same width, so the gaps between them are even.
    if (call.chatBelow) {
      Widget slot(String key, Widget child) => SizedBox(key: ValueKey('tg-slot-$key'), width: _slot, child: Center(child: child));
      return Container(
        key: const ValueKey('tg-controls'),
        padding: EdgeInsetsDirectional.fromSTEB(8, 8, 8, bottom + 14),
        // In a pane too narrow for the group, it shrinks rather than spill.
        child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          slot('video', _RoundButton(icon: SpaceWords.videoIcon(call), label: SpaceWords.video(call), on: call.video, onPressed: call.videoLocked ? null : call.onVideo)),
          slot('deafen', _RoundButton(icon: SpaceWords.deafenIcon(call), label: SpaceWords.deafen(call), on: call.deafened, onPressed: call.onDeafen)),
          slot('mic', _MicButton(call: call)),
          // Share screen beside Leave, where this device can share one (Matt, 2026-11-25: "replace the who hide chat
          // button with a share screen button"); it was Chat, which put the chat under the call away.
          if (call.onScreen != null) slot('screen', _RoundButton(icon: LucideMore.screenShare, label: call.screen ? 'Stop sharing' : 'Share screen', on: call.screen, onPressed: () => call.onScreen!(context))),
          slot('leave', leave),
        ]))),
      );
    }
    // No rule above the controls: it stopped short of the page's edges (Matt, 2026-11-17: "the border at the bottom for the
    // controls should span the full width of the page or remove the border completely").
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(8, 8, 8, bottom + 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        side(_RoundButton(
          icon: SpaceWords.videoIcon(call),
          label: SpaceWords.video(call),
          on: call.video,
          onPressed: call.videoLocked ? null : call.onVideo,
        )),
        side(_RoundButton(icon: SpaceWords.deafenIcon(call), label: SpaceWords.deafen(call), on: call.deafened, onPressed: call.onDeafen)),
        SizedBox(width: 104, child: _MicButton(call: call)),
        side(_RoundButton(icon: LucideMore.messageCircle, label: SpaceWords.chat, on: chatOpen, onPressed: onChat)),
        side(leave),
      ]),
    );
  }
}

/// The width of each button's slot in the split's group (SpaceSplit): the microphone's box and a little room.
const double _slot = 112;

/// One of the four round buttons round the microphone: a flat circle, its words under it. On, it is filled with the
/// ink; Leave is the app's red.
class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.onPressed, this.on = false, this.danger = false});
  final LucideIcon icon;
  final String label;
  final VoidCallback? onPressed;
  final bool on, danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Opacity(
      opacity: onPressed == null ? 0.4 : 1,
      child: GlacierPressable(
        onPressed: onPressed,
        semanticLabel: label,
        builder: (context, state) {
          final ground = danger ? _red(t) : (on ? t.color('app-accent') : t.color(state.hovered || state.pressed ? 'app-paper-3' : 'app-paper-2'));
          final mark = danger ? const Color(0xFFFFFFFF) : (on ? t.color('app-paper') : t.color('app-ink'));
          return Padding(
            // Level with the middle of the microphone button.
            padding: const EdgeInsets.only(top: (_MicButton.box - 50) / 2),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AnimatedScale(
                scale: state.pressed ? 0.94 : 1,
                duration: const Duration(milliseconds: 100),
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: ground, border: on || danger ? null : Border.all(color: t.color('app-rule'))),
                  alignment: Alignment.center,
                  child: AppIcon(icon, size: 22, wash: false, color: mark),
                ),
              ),
              const SizedBox(height: 6),
              ExcludeSemantics(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-2')))),
            ]),
          );
        },
      ),
    );
  }
}

/// The big microphone: a flat circle, green while you are live with the app's wobbly ripples going out from it as you
/// talk (RippleAvatar's rings, driven by levels['me']); quiet paper while muted; a lock when a moderator has muted
/// you; and what it means under it.
class _MicButton extends StatelessWidget {
  const _MicButton({required this.call});
  final SpaceCall call;

  /// Only a little bigger than the buttons beside it (50) (Matt, 2026-11-16: "make the mic on button only slightly
  /// bigger than the other icons").
  static const size = 60.0;

  /// The ripples are drawn round a hidden face of this size, so that the rings, which run from its edge out to 1.85
  /// times its radius (40 px), show as a band round the 60 px button and stay inside its 88 px box.
  static const ringFace = 43.0;

  /// The box the button and its rings stand in; the buttons beside it are centred on it ([_RoundButton]).
  static const box = 88.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final locked = call.micLocked;
    final live = !call.muted && !call.deafened && !locked;
    // Deafened, the button undeafens: hearing comes back first (and your voice with it, unless you muted too).
    final deaf = call.deafened && !locked;
    final green = _green(t);
    // A lock is a moderator's mute, or a role that may not speak (a stage's listener): each says which (GMFB-49).
    final title = locked ? (call.micLockedByRole ? 'Your role can\'t speak' : 'Muted by a moderator') : (deaf ? SpaceWords.deafen(call) : (live ? 'Mic on' : 'Muted'));
    final hint = locked ? 'You can listen' : (deaf ? (call.muted ? 'Tap to listen' : 'Tap to listen and speak') : (live ? 'Tap to mute' : 'Tap to unmute'));
    final icon = locked ? Lucide.lock : (deaf ? LucideMore.headphoneOff : (live ? Lucide.mic : LucideMore.micOff));
    return GlacierPressable(
      // Locked, a press says why and who can change it, where that is known.
      onPressed: locked ? (call.micLockedWhy == null ? null : () => GlacierToast.of(context).toast(message: Text(call.micLockedWhy!))) : (deaf ? call.onDeafen : call.onMute),
      semanticLabel: locked || deaf ? title : SpaceWords.mute(call),
      builder: (context, state) => Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: box,
          child: Center(
            child: Stack(alignment: Alignment.center, children: [
              // The app's ripples, the face under them hidden by the button.
              ExcludeSemantics(
                child: ValueListenableBuilder<Map<String, double>>(
                  valueListenable: call.levels,
                  builder: (context, now, _) => RippleAvatar(key: const ValueKey('tg-mic-ripples'), name: ' ', level: live ? (now['me'] ?? 0) : 0, muted: !live, size: ringFace, color: green),
                ),
              ),
              AnimatedScale(
                scale: state.pressed ? 0.95 : 1,
                duration: const Duration(milliseconds: 100),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: live ? green : t.color(locked ? 'app-paper-3' : 'app-paper-2'),
                    border: live ? null : Border.all(color: locked ? t.color('app-ink-4') : t.color('app-rule'), width: locked ? 1.5 : 1),
                  ),
                  alignment: Alignment.center,
                  child: AppIcon(icon, size: locked ? 22 : 26, wash: false, color: live ? const Color(0xFFFFFFFF) : t.color(locked ? 'app-ink-3' : 'app-ink')),
                ),
              ),
            ]),
          ),
        ),
        ExcludeSemantics(child: Text(title, maxLines: locked ? 2 : 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: live ? green : t.color('app-ink')))),
        ExcludeSemantics(child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')))),
      ]),
    );
  }
}

/// The space's chat as a sheet of its own (a phone) or a panel docked beside the voice chat (a computer), in the
/// app's own paper and ink as its bubbles and composer are.
class _ChatPanel extends StatelessWidget {
  const _ChatPanel({required this.call, required this.onClose, required this.bottom});
  final SpaceCall call;
  final VoidCallback onClose;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final name = call.channel.name.isEmpty ? 'Space' : call.channel.name;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Column(children: [
        Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.color('app-rule')))),
          child: Column(children: [
            SizedBox(
              height: 58,
              child: Row(children: [
                SizedBox(width: t.space(4)),
                AppIcon(LucideMore.messageCircle, size: 20, wash: false, color: t.color('app-ink')),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(SpaceWords.chat, maxLines: 1, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                  ]),
                ),
                _IconButton(icon: Lucide.x, label: 'Close chat', onPressed: onClose),
                SizedBox(width: t.space(3)),
              ]),
            ),
          ]),
        ),
        Expanded(child: call.chat(bottom: bottom)),
      ]),
    );
  }
}
