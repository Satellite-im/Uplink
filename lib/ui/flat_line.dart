/// A message as a channel's line: everyone on the left, yourself too, a run's first message with the face, the name and
/// the time over it, the words on the page with no bubble (Matt, 2026-11-18: "Id like the chats in circles to be more
/// like discord or slack and keep the bubbles for dms and small groups").
///
/// A circle's text space draws its chat so (lib/ui/hangout_screen.dart), and so does every group on another network
/// (lib/ui/inbox_ui.dart; Matt, 2026-11-25: "For channels on slack and other groups please use the same chat UI without
/// the bubbles we use with text channels on circles"): the one widget, [FlatLine], for both, so they cannot come to look
/// apart. What is said in it (words, files, a poll, a sticker) is the chat's own to draw, as its `body`.
///
/// Dial-Up draws neither: it writes every chat as a transcript (lib/ui/message_line.dart).
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../kit/picture_decode.dart';
import '../kit/settings_type.dart';
import 'common.dart' show clock;
import 'cosmetics_ui.dart' show NameEffectText;
import 'dialup/bevel.dart' show isBevelChrome;
import 'dialup/parts.dart' show DialupFace;
import 'plugin_note_card.dart' show NoteWords;
import 'reaction_stickers.dart' show ReactionChips;
import '../l10n/words.dart';

/// One message as a channel's line: the face in a gutter by a run's first message, the name and the time beside it, and
/// what was said under them on the page.
class FlatLine extends StatelessWidget {
  const FlatLine({
    super.key,
    required this.name,
    required this.at,
    required this.first,
    required this.face,
    required this.body,
    this.nameInk,
    this.nameEffect = '',
    this.badge,
    this.mentionsMe = false,
    this.onMenu,
    this.onPerson,
    this.reactions = const [],
    this.reactionsKey,
    this.onReact,
    this.onAddReaction,
    this.foot,
  });

  /// Who wrote it: "You" for yourself.
  final String name;
  final DateTime at;

  /// The first of a run from one person: the face, the name and the time are drawn with it alone.
  final bool first;

  /// Their face at the size the line has for it.
  final Widget Function(double size) face;

  /// What was said, in at most the width it is given.
  final Widget Function(BuildContext context, double maxWidth) body;

  /// The name's colour (a role's in a circle); the page's own ink where null.
  final Color? nameInk;

  /// The name effect its sender wears (lib/me/cosmetics.dart), drawn in the name's letters; none where empty.
  final String nameEffect;

  /// A mark after the name, at a size that stands on the name's line.
  final Widget Function(double size)? badge;

  /// Someone else's message that mentions you: on a wash of the accent with a bar of it at its edge, as Slack and Discord
  /// mark one.
  final bool mentionsMe;

  /// Pressed and held, or pressed with a mouse's other button.
  final VoidCallback? onMenu;

  /// Their face or name pressed: their profile card.
  final VoidCallback? onPerson;

  /// Its reactions as pills under it, as Discord and Slack show them: pressed, yours goes on or off ([onReact]), and the
  /// plus at their end puts another on ([onAddReaction]).
  final List<({String emoji, int count, bool mine})> reactions;
  final Key? reactionsKey;
  final ValueChanged<String>? onReact;
  final VoidCallback? onAddReaction;

  /// Under all of it: how its sending went, where that is to be said.
  final Widget? foot;

  /// A pause this long starts a new run, its name and time shown again, as Slack and Discord do.
  static const pause = Duration(minutes: 5);

  /// Whether two messages are too far apart in time to be of one run.
  static bool apart(DateTime a, DateTime b) => a.difference(b).abs() > pause;

  static double faceSize(Tokens t) => t.lenOf('2.25rem');

  /// Where the words start, from the line's left edge.
  static double wordsLeft(Tokens t) => faceSize(t) + t.space(4);

  /// [child], pressed for the writer's profile card, with a hand over it on a computer.
  Widget _toPerson(Widget child) {
    final on = onPerson;
    if (on == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: on, child: Semantics(button: true, child: child)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = faceSize(t);
    final gutter = size + t.space(3);
    final maxWidth = math.min(MediaQuery.sizeOf(context).width - gutter - t.space(6), t.lenOf('34rem'));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onMenu,
      onSecondaryTap: onMenu,
      child: Container(
        decoration: mentionsMe ? BoxDecoration(color: t.color('app-accent').withValues(alpha: 0.10), border: Border(left: BorderSide(color: t.color('app-accent'), width: 3))) : null,
        // The gap above a run's first message is outside the wash, so a mention's is as tight above as below (Matt,
        // 2026-11-19: "the mention highlight has too much padding on the top").
        margin: EdgeInsets.only(top: first && mentionsMe ? t.space(2) : 0),
        padding: mentionsMe
            ? EdgeInsetsDirectional.fromSTEB(t.space(1), first ? t.space(1) : 2, t.space(1), first ? t.space(1) : 2)
            : EdgeInsetsDirectional.only(top: first ? t.space(3) : 2, start: t.space(1), end: t.space(1)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: gutter,
            child: first ? Align(alignment: AlignmentDirectional.topStart, child: _toPerson(face(size))) : null,
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (first)
                Padding(
                  padding: EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                    Flexible(child: _toPerson(NameEffectText(name, key: const ValueKey('flat-line-name'), id: nameEffect, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: nameInk ?? t.color('app-ink'))))),
                    if (badge != null) Baseline(baseline: 18, baselineType: TextBaseline.alphabetic, child: badge!(15)),
                    SizedBox(width: t.space(2)),
                    Text(clock(at), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                  ]),
                ),
              Align(alignment: AlignmentDirectional.centerStart, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: body(context, maxWidth))),
              if (reactions.isNotEmpty) ReactionChips(key: reactionsKey, kinds: reactions, onToggle: onReact, onAdd: onAddReaction),
              ?foot,
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A day's turn between a chat's messages: its name, small, across the middle.
class DayTurn extends StatelessWidget {
  const DayTurn(this.words, {super.key});
  final String words;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(top: t.space(4), bottom: t.space(1)),
      child: Text(words, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'))),
    );
  }
}

/// The message a message answers, quoted at its head: a bar in the accent, the writer ([who], nothing where not known),
/// and the start of their words.
class FlatQuote extends StatelessWidget {
  const FlatQuote({super.key, required this.who, required this.text, required this.ink});
  final String who;
  final String text;
  final Color ink;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), 2, t.space(2), 2),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: 0.07),
        border: Border(left: BorderSide(color: t.color('app-accent'), width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (who.isNotEmpty) Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-accent'))),
        // Record call's line with its icon, not its emoji (GMFB-43).
        if (text.isNotEmpty) NoteWords(text, maxLines: 2, style: pageText(t, t.fontSize('sm'), color: ink.withValues(alpha: 0.75))),
      ]),
    );
  }
}

/// "(edited)" after a message's words, small and faint, changed by its writer since (Matt, 2026-11-20: "I'd like to be
/// able to edit messages sent in circles"). [onTap], where what it said before can be shown, makes it a press.
InlineSpan editedMark(TextStyle style, Color ink, {Key? key, VoidCallback? onTap}) {
  final small = style.copyWith(fontSize: (style.fontSize ?? 14) * 0.78, color: ink.withValues(alpha: 0.55), fontWeight: FontWeight.w400);
  if (onTap == null) return TextSpan(text: '  (edited)', style: small);
  // The gap apart from the press, so a mark that goes to the next line starts at its edge.
  return TextSpan(style: small, children: [
    const TextSpan(text: '  '),
    WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(key: key, behavior: HitTestBehavior.opaque, onTap: onTap, child: Tr('(edited)', style: small)),
      ),
    ),
  ]);
}

/// A face [size] across from a profile picture as Uplink keeps one (base64; lib/me/pictures.dart), or null where [picture]
/// is none that can be read.
Widget? faceOfPicture(BuildContext context, String? picture, double size) {
  if (picture == null || picture.isEmpty) return null;
  // The same bytes each build, unpacked at the face's size (lib/kit/picture_decode.dart): one a message row.
  final bytes = pictureBytes(picture);
  if (bytes == null) return null;
  final image = Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: faceDecodeWidth(context, size));
  // Dial-Up's faces are square in a sunken ring, as Avatar draws them there.
  if (isBevelChrome(context.tokens)) return DialupFace(size: size, child: image);
  return ClipOval(child: SizedBox(width: size, height: size, child: image));
}

/// [picture] (as lib/ui/hangout_screen.dart's SpacePicture gives it) filling [size] square with no frame or shape of its own, or null where there
/// is none: for a face that frames it itself (RippleAvatar's child, VoiceFace's).
Widget? pictureOfSpace(BuildContext context, String? picture, double size) {
  if (picture == null || picture.isEmpty) return null;
  final bytes = pictureBytes(picture);
  if (bytes == null) return null;
  return Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: faceDecodeWidth(context, size));
}
