/// A thread in a space's chat (GMFB-36, from the Uplink gap review: forums and threads were promised in Uplink #1434):
/// replies to one message kept off the chat, in a page of their own on a phone and in a panel beside the chat in a
/// wide window, with a line under the message saying how many and who wrote last.
///
/// A reply in a thread is a message like any other, with `th` naming the message it hangs from (lib/voice/hangout.dart)
/// and that message quoted, so a build from before shows it in the chat as a reply.
library;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../snooze.dart';
import '../voice/channels.dart';
import '../voice/hangout.dart';
import 'common.dart';
import 'composer_box.dart';
import 'mention_field.dart' show mentionStyle;
import 'plugin_note_card.dart';
import 'ripple_avatar.dart';
import 'snooze_ui.dart';
import 'thread.dart' show LinkedText;

/// Opens [root]'s thread in [room].
Future<void> openThread(BuildContext context, HangoutRoom room, HangoutMessage root) => push(context, (_) => SpaceThreadScreen(room: room, root: root));

/// "3 replies · Sam, 2m": under a message whose thread has any, pressed to open it.
class ThreadLine extends StatelessWidget {
  const ThreadLine({super.key, required this.count, required this.last, required this.onOpen, this.indent = 0});
  final int count;
  final HangoutMessage last;
  final VoidCallback onOpen;

  /// Where it starts, to line up with the message's words.
  final double indent;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final who = last.name.isEmpty ? Voice.instance.nameOf(last.from) : last.name;
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, top: t.space(1), bottom: t.space(1)),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: GlacierPressable(
          onPressed: onOpen,
          semanticLabel: 'Open the thread, ${count == 1 ? '1 reply' : '$count replies'}',
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1)),
            decoration: BoxDecoration(
              color: t.color(state.pressed || state.hovered ? 'app-paper-3' : 'app-paper-2'),
              borderRadius: BorderRadius.circular(t.radius('md')),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              AppIcon(Lucide.messageSquare, size: 14, color: t.color('app-accent')),
              SizedBox(width: t.space(1)),
              Text(count == 1 ? '1 reply' : '$count replies', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-accent'))),
              SizedBox(width: t.space(2)),
              Flexible(child: Text('$who · ${ago(DateTime.fromMillisecondsSinceEpoch(last.at))}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// How long ago [d] was, shortly: "now", "5m", "3h", "2d", or the day.
String ago(DateTime d, [DateTime? now]) {
  final n = now ?? DateTime.now();
  final s = n.difference(d);
  if (s.inMinutes < 1) return 'now';
  if (s.inHours < 1) return '${s.inMinutes}m';
  if (s.inDays < 1) return '${s.inHours}h';
  if (s.inDays < 7) return '${s.inDays}d';
  return dayHeading(d, n);
}

/// A thread's page, on a phone: the message it hangs from, its replies, and a box to reply in ([SpaceThreadView]).
class SpaceThreadScreen extends StatelessWidget {
  const SpaceThreadScreen({super.key, required this.room, required this.root});
  final HangoutRoom room;
  final HangoutMessage root;

  @override
  Widget build(BuildContext context) => GhostPage(title: 'Thread', subtitle: room.channel.name, body: SpaceThreadView(room: room, root: root));
}

/// A thread beside its chat, in a wide window (GMFB-36: "threads show as a side panel with a reply count on the
/// message"): a head with its name and a cross that closes it, over what its page has ([SpaceThreadView]).
class SpaceThreadPanel extends StatelessWidget {
  const SpaceThreadPanel({super.key, required this.room, required this.root, required this.onClose});
  final HangoutRoom room;
  final HangoutMessage root;
  final VoidCallback onClose;

  /// How wide a chat must be for the panel to stand beside it; in a narrower one (the pane of a folding phone
  /// opened out) it takes the chat's place, with the same cross back to it.
  static const besideAt = 600.0;

  /// How wide it is beside a chat [width] wide.
  static double widthIn(double width) => (width * 0.4).clamp(300.0, 420.0);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(1), t.space(2)),
          child: Row(children: [
            AppIcon(Lucide.messageSquare, size: 16, color: t.color('app-ink-3')),
            SizedBox(width: t.space(2)),
            Text('Thread', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
            SizedBox(width: t.space(2)),
            Expanded(child: Text(room.channel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
            IconTap(key: const ValueKey('thread-panel-close'), icon: Lucide.x, label: 'Close the thread', onPressed: onClose),
          ]),
        ),
        Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
        Expanded(child: SpaceThreadView(key: ValueKey('thread-${root.id}'), room: room, root: root)),
      ]),
    );
  }
}

/// What a thread shows, on its page or in its panel: the message it hangs from, its replies, and a box to reply in.
class SpaceThreadView extends StatefulWidget {
  const SpaceThreadView({super.key, required this.room, required this.root});
  final HangoutRoom room;
  final HangoutMessage root;

  @override
  State<SpaceThreadView> createState() => _SpaceThreadViewState();
}

class _SpaceThreadViewState extends State<SpaceThreadView> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _typing = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() {
      final typing = _text.text.trim().isNotEmpty;
      if (typing != _typing) setState(() => _typing = typing);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Sends the box's words as a reply in this thread. The box is emptied only where the room took them.
  void _send() {
    if (widget.room.send(_text.text, thread: widget.root.id)) _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final room = widget.room;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        // The message as it is now (edited since), or as it was opened where it has gone.
        final root = room.messages.where((m) => m.id == widget.root.id).firstOrNull ?? widget.root;
        final replies = room.threadOf(root.id);
        final pad = MediaQuery.paddingOf(context);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(3)),
              children: [
                _ThreadMessage(room: room, message: root, big: true),
                Padding(
                  padding: EdgeInsets.symmetric(vertical: t.space(3)),
                  child: Row(children: [
                    Text(replies.isEmpty ? 'No replies yet' : (replies.length == 1 ? '1 reply' : '${replies.length} replies'),
                        style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'))),
                    SizedBox(width: t.space(2)),
                    Expanded(child: Container(height: t.len('glacier-hairline'), color: t.color('app-rule'))),
                  ]),
                ),
                for (final m in replies) _ThreadMessage(key: ValueKey(m.id), room: room, message: m),
              ],
            ),
          ),
          if (room.mayWrite)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(1), t.space(3), pad.bottom + t.space(3)),
              child: ComposerBox(
                typing: _typing,
                field: ComposerField(controller: _text, focusNode: _focus, hint: 'Reply in thread', onSubmitted: _send, enterSends: true),
                below: [
                  GlacierPressable(
                    onPressed: _send,
                    semanticLabel: 'Send',
                    builder: (context, state) => AppIcon(Lucide.send, size: 22, color: t.color('app-accent')),
                  ),
                ],
              ),
            ),
        ]);
      },
    );
  }
}

/// One message in a thread: the face, the name and when, and the words.
class _ThreadMessage extends StatelessWidget {
  const _ThreadMessage({super.key, required this.room, required this.message, this.big = false});
  final HangoutRoom room;
  final HangoutMessage message;

  /// The message the thread hangs from, its words a little larger.
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = message;
    final name = m.name.isEmpty ? Voice.instance.nameOf(m.from) : m.name;
    final at = DateTime.fromMillisecondsSinceEpoch(m.at);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _menu(context),
      onSecondaryTap: () => _menu(context),
      child: Padding(
        padding: EdgeInsets.only(bottom: t.space(3)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          RippleAvatar(name: name, level: 0, size: big ? 36 : 28),
          SizedBox(width: t.space(2)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(m.from == room.me ? 'You' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-ink')))),
                SizedBox(width: t.space(2)),
                Text('${dayHeading(at)} ${clock(at)}${m.edited != null ? ' · edited' : ''}', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              ]),
              SizedBox(height: t.space(1) / 2),
              // Formatted as in the space's chat (GMFB-35).
              // A plugin's note is its card here too, as in the chat (GMFB-43: Record call's start and stop showed
              // their emoji in a thread).
              if (pluginCardOf(m, mine: m.from == room.me) case final pc?)
                PluginChatCardView(card: pc.card, plugin: pc.plugin)
              else if (m.text.isEmpty)
                Text(m.what, style: pageText(t, t.fontSize(big ? 'md' : 'sm'), color: t.color('app-ink'), height: 1.4))
              else
                LinkedText(m.text, ink: t.color('app-ink'), style: pageText(t, t.fontSize(big ? 'md' : 'sm'), color: t.color('app-ink'), height: 1.4), mentions: m.mentions, mentionStyle: mentionStyle(t)),
            ]),
          ),
        ]),
      ),
    );
  }

  /// Press and hold, or a right click: copy the words; a reply, never the message the thread hangs from, can be
  /// deleted here by whoever may.
  void _menu(BuildContext context) {
    final m = message;
    showChoices(context, choices: [
      if (m.text.isNotEmpty) Choice('Copy', Lucide.copy, () => Clipboard.setData(ClipboardData(text: m.text))),
      // Snoozed as a message in the chat is (GMFB-36): its reminder, back in the chat, opens this thread.
      snoozeMessageChoice(context, chat: Snoozed.space(room.channel.room), id: m.id, title: room.channel.name, words: m.text.isEmpty ? m.what : m.text),
      if (m.thread != null && room.canDelete(m)) Choice('Delete for everyone', Lucide.trash2, () => room.delete(m), danger: true),
    ]);
  }
}
