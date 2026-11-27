import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/pixel_emoji.dart';
import '../mentions.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../sms.dart' show Sms;
import 'common.dart' show dayHeading;
import 'dialup/bevel.dart';
import 'thread.dart' show LinkedText;

/// Messages as a chat room's transcript, for Dial-Up (lib/looks.dart; Matt, 2026-11-16: "base one of them heavily on
/// the old AOL chatrooms"): no bubbles and no faces, each message one run of words, a bold coloured "Name:" and then
/// what they said, wrapping back to the left edge under the name, all inside one white well sunk into the window.
///
/// The three conversations that draw bubbles (texts and Uplink in lib/ui/thread.dart, Telegram and Signal in
/// lib/ui/inbox_ui.dart, a space's chat in lib/ui/hangout_screen.dart) draw these instead while [drawsLines], so the
/// look is the same in all three; every other look keeps its bubbles exactly as they were.

/// Whether the conversation is drawn as transcript lines: asked of the tokens (`--app-chrome-style: bevel`), not of the
/// look's name, as the rest of Dial-Up's layout is (lib/ui/dialup/bevel.dart).
bool drawsLines(BuildContext context) => isDialup(context);

/// A screen name as a transcript shows it: past 16 letters it is cut with an ellipsis, so a long one never takes
/// half of a phone's line (the design's critique, 2026-11-16).
String lineName(String name) {
  final n = name.trim().characters;
  return n.length > 16 ? '${n.take(15)}…' : n.toString();
}

/// A transcript's words in logical pixels: 16, by Settings › Appearance › Text size, and a size smaller on a computer
/// as a bubble's are (lib/ui/thread.dart).
double lineSize(BuildContext context, [double px = 16]) => px * (AppState.maybeOf(context)?.textScale ?? 1) * (Sms.computer ? 0.88 : 1);

/// The white well a conversation's lines are written in, sunk into the window's silver. Over a chat background the
/// background shows round the well and never behind the words (the design: "they show behind the transcript well,
/// never behind text").
class Transcript extends StatelessWidget {
  const Transcript({super.key, required this.child, this.overBackground = false});
  final Widget child;
  final bool overBackground;

  @override
  Widget build(BuildContext context) {
    final c = DialupColors.of(context.tokens);
    // The well and all that is written in it are a scope of the tokens (`.parchment`, assets/css/app.css): a look
    // whose chat is written on another ground than its pages' (Runestone's grey parchment in its dark stone) says its
    // paper and inks again there. No rule of Dial-Up's asks for it, so its well is the page's white as it was.
    final well = Padding(padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 6, 4), child: GlacierScope(classes: const {'parchment'}, child: Sunken(child: child)));
    return overBackground ? well : ColoredBox(color: c.chrome, child: well);
  }
}

/// A line from the room's own speaker, Host: someone came or went, where the conversation starts, that it is sealed.
/// Italic and in the secondary ink, "Host:" in bold. [centred] draws it without the speaker, in the middle: a day's
/// turn ("*** Today ***").
class HostLine extends StatelessWidget {
  const HostLine(this.text, {super.key, this.centred = false, this.onLongPress});
  final String text;
  final bool centred;
  final VoidCallback? onLongPress;

  /// The day [d] falls on, as the transcript marks it.
  factory HostLine.day(DateTime d, {Key? key}) => HostLine('*** ${dayHeading(d)} ***', key: key, centred: true);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final style = pageText(t, lineSize(context, 15), color: c.inkSoft, height: 1.35).copyWith(fontStyle: FontStyle.italic);
    final line = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(8, centred ? 6 : 2, 8, centred ? 4 : 2),
      child: Text.rich(
        TextSpan(children: [
          if (!centred) TextSpan(text: 'Host: ', style: pageText(t, lineSize(context, 15), weight: 'bold', color: c.inkSoft, height: 1.35).copyWith(fontStyle: FontStyle.italic)),
          TextSpan(text: text),
        ]),
        style: style,
        textAlign: centred ? TextAlign.center : TextAlign.start,
      ),
    );
    return onLongPress == null ? line : GestureDetector(behavior: HitTestBehavior.opaque, onLongPress: onLongPress, child: line);
  }
}

/// One message as a transcript line: "[name]: " in bold [nameColor], then [body], in one run of words, so a long one
/// wraps back to the left edge under the name. Your own ([mine]) have a 3px tick down their left edge in your name's
/// colour, since the side a bubble was on is gone and most people scan for it (the critique, 2026-11-16).
///
/// What went with it stands under the words, square: [media] (pictures, videos, voice messages, stickers), then
/// [under] (a link's card, what the plugins put there), then its reactions as a small raised chip. A time or a status
/// ([status]) follows the words in small type; a failed one says so in the danger colour on its own line, which a tap
/// on tries again ([onTapFailed]). Held down, it says where it is on the screen ([onLongPress]), as a bubble does.
class MessageLine extends StatefulWidget {
  const MessageLine({
    super.key,
    required this.name,
    required this.nameColor,
    this.mine = false,
    this.body = '',
    this.original,
    this.italic = false,
    this.concealed = false,
    this.onReveal,
    this.media = const [],
    this.under = const [],
    this.status,
    this.failed = false,
    this.onTapFailed,
    this.reactions = const [],
    this.onReactionsTap,
    this.edited,
    this.onEditedTap,
    this.highlighted = false,
    this.faded = false,
    this.onLongPress,
    this.mentions = const [],
    this.mentionStyle,
    this.onMention,
    this.onNameTap,
  });

  /// Who said it ("You" for your own), cut past 16 letters ([lineName]).
  final String name;
  final Color nameColor;
  final bool mine;
  final String body;

  /// Under the words, before what went with them: the words as they came where a plugin shows them otherwise, a dim
  /// italic line (lib/ui/translated_card.dart OriginalLine; Matt, 2026-11-17: "add a translate plugin which can
  /// automatically translate texts when detected from another language").
  final Widget? original;

  /// Drawn slanted: words standing in for ones that can't be shown (a sealed message this phone can't open).
  final bool italic;

  /// Invisible ink not yet tapped open: a row of grey blocks where the words are, until [onReveal].
  final bool concealed;
  final VoidCallback? onReveal;
  final List<Widget> media;
  final List<Widget> under;

  /// A time ("4:51 PM"), or what became of your message ("Delivered · 4:51 PM", "Sending…", why it didn't go).
  final String? status;
  final bool failed;
  final VoidCallback? onTapFailed;

  /// Each reaction's emoji, in the order they came.
  final List<String> reactions;
  final VoidCallback? onReactionsTap;

  /// "Edited", said after the words in brackets; a tap shows what it said first.
  final String? edited;
  final VoidCallback? onEditedTap;

  /// Being edited in the composer: ringed, as the era drew a focused row.
  final bool highlighted;

  /// Still going (a network's message being sent): drawn fainter.
  final bool faded;
  final ValueChanged<Rect>? onLongPress;

  /// Who [body] mentions, drawn and pressed as LinkedText draws them.
  final List<Mention> mentions;
  final TextStyle? mentionStyle;
  final ValueChanged<Mention>? onMention;

  /// The name pressed: whose profile card (lib/ui/profile_card.dart).
  final VoidCallback? onNameTap;

  @override
  State<MessageLine> createState() => _MessageLineState();
}

/// [words] in [style], their emoji in square pixels where the look draws them so (lib/art/pixel_emoji.dart).
Widget _words(Tokens t, String words, TextStyle style) => pixelEmojiOn(t) ? Text.rich(TextSpan(children: pixelEmojiSpans([TextSpan(text: words)], style)), style: style) : Text(words, style: style);

class _MessageLineState extends State<MessageLine> {
  final _editedTap = TapGestureRecognizer();
  final _nameTap = TapGestureRecognizer();

  @override
  void dispose() {
    _editedTap.dispose();
    _nameTap.dispose();
    super.dispose();
  }

  void _held(BuildContext at) {
    final box = at.findRenderObject();
    // Measured against the pane the conversation is in, as a bubble's is (lib/ui/thread.dart).
    final pane = Navigator.maybeOf(at)?.context.findRenderObject();
    if (box is RenderBox && box.hasSize) widget.onLongPress?.call(box.localToGlobal(Offset.zero, ancestor: pane) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final w = widget;
    final px = lineSize(context);
    // The words in the page's ink, or in your colour or theirs where the look has one each (DialupColors.wordsMine).
    final ink = w.mine ? c.wordsMine : c.wordsTheirs;
    final text = pageText(t, px, color: ink, height: 1.35);
    final nameStyle = pageText(t, px, weight: 'bold', color: w.nameColor, height: 1.35);
    final small = pageText(t, lineSize(context, 12), color: c.inkSoft, height: 1.35);
    _editedTap.onTap = w.onEditedTap;
    _nameTap.onTap = w.onNameTap;
    final after = <InlineSpan>[
      if (w.edited != null) TextSpan(text: ' (${w.edited!.toLowerCase()})', style: small, recognizer: w.onEditedTap == null ? null : _editedTap),
      // Held together, so a time never breaks between "5:43" and "PM".
      if (w.status != null && !w.failed) TextSpan(text: '  ${w.status!.replaceAll(' ', '\u00A0')}', style: small),
    ];
    final name = lineName(w.name);
    final Widget words;
    if (w.concealed) {
      // The era had no invisible ink: the words stand as blocks of the old shaded character until tapped.
      final n = math.min(math.max(w.body.characters.length, 3), 48);
      words = Text.rich(
        TextSpan(children: [TextSpan(text: '$name: ', style: nameStyle), TextSpan(text: '▒' * n, style: text.copyWith(color: c.disabled)), TextSpan(text: '  Tap to reveal', style: small)]),
        style: text,
        semanticsLabel: '$name: hidden message, tap to reveal',
      );
    } else if (w.body.isEmpty) {
      words = Text.rich(TextSpan(children: [TextSpan(text: '$name:', style: nameStyle), ...after]), style: text);
    } else {
      words = LinkedText(
        w.body,
        ink: ink,
        style: w.italic ? text.copyWith(fontStyle: FontStyle.italic) : text,
        before: [
          TextSpan(text: name, style: nameStyle.copyWith(fontStyle: FontStyle.normal), recognizer: w.onNameTap == null ? null : _nameTap, mouseCursor: w.onNameTap == null ? null : SystemMouseCursors.click),
          TextSpan(text: ': ', style: nameStyle.copyWith(fontStyle: FontStyle.normal)),
        ],
        after: after,
        mentions: w.mentions,
        mentionStyle: w.mentionStyle,
        onMention: w.onMention,
      );
    }
    final kinds = <String>[];
    for (final r in w.reactions) {
      if (!kinds.contains(r)) kinds.add(r);
    }
    final reactions = kinds.isEmpty
        ? null
        : GlacierPressable(
            onPressed: w.onReactionsTap,
            semanticLabel: '${w.reactions.length} reaction${w.reactions.length == 1 ? '' : 's'}: ${kinds.join(' ')}',
            builder: (context, state) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Bevel(
                style: state.pressed ? BevelStyle.pressed : BevelStyle.raised,
                rings: 1,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                child: _words(
                  t,
                  '${kinds.take(4).join(' ')}${w.reactions.length > kinds.length ? ' ${w.reactions.length}' : ''}',
                  pageText(t, lineSize(context, 14), color: c.onChrome, height: 1.25),
                ),
              ),
            ),
          );
    final maxMedia = math.min(MediaQuery.sizeOf(context).width * 0.7, 320.0);
    Widget line = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      words,
      ?w.original,
      for (final m in w.media) Padding(padding: const EdgeInsets.only(top: 4, bottom: 2), child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxMedia), child: m)),
      for (final u in w.under) Padding(padding: const EdgeInsets.only(top: 4), child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxMedia), child: u)),
      ?reactions,
      if (w.failed && w.status != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text('*** ${w.status} ***', style: small.copyWith(color: t.danger, fontSize: lineSize(context, 13))),
        ),
    ]);
    line = Container(
      width: double.infinity,
      // Yours: a tick down the left edge in your name's colour; everyone's words start on the same edge.
      decoration: BoxDecoration(
        // A failed line on a pale wash of the danger colour (the design: red words on #FFE0E0), lighter than the bubble's
        // failed ground so the red words keep their contrast on the white page.
        color: w.failed ? Color.lerp(c.paper, t.danger, 0.12) : null,
        border: w.mine ? Border(left: BorderSide(color: c.nameMine, width: 3)) : null,
      ),
      foregroundDecoration: w.highlighted ? BoxDecoration(border: Border.all(color: t.chosen)) : null,
      padding: EdgeInsetsDirectional.fromSTEB(w.mine ? 5 : 8, 2, 8, 2),
      child: line,
    );
    if (w.faded) line = Opacity(opacity: 0.6, child: line);
    return Builder(
      builder: (at) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: w.onLongPress == null ? null : () => _held(at),
        onSecondaryTap: w.onLongPress == null ? null : () => _held(at),
        onTap: w.concealed ? w.onReveal : (w.failed ? w.onTapFailed : null),
        child: line,
      ),
    );
  }
}
