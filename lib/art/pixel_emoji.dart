import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

/// Emoji in square pixels, for a look that is drawn in them (`--app-emoji: pixel`, Runestone; Matt, 2026-11-27: "also
/// add a shader to pixelate emoji").
///
/// An emoji is a smooth picture from the emoji set the person chose, among letters that are sixteen pixels to the
/// em. It is drawn once, small, onto the same grid (sixteen of its pixels to the em), and that small picture is then
/// drawn at its place with every pixel kept square: the letters' own pixel size, so the two sit on one grid. Done by
/// drawing it twice rather than by a program run on the graphics chip, so it is the same on every phone, computer
/// and in a browser, and in the tests that draw the screens; the small pictures are kept, so an emoji is made once.
///
/// It reaches what is read (a message's words, its reactions, a conversation's last line, a button's words), through
/// [pixelEmojiSpans]. Not what is being typed: a field's words are the keyboard's to edit.

/// Whether emoji are drawn in pixels under [t].
bool pixelEmojiOn(Tokens t) => t.raw('app-emoji')?.trim() == 'pixel';

/// A code point that is an emoji's or part of one (its joiners, selectors, tones and flags' letters).
bool _emojiRune(int r) =>
    r >= 0x1F000 ||
    (r >= 0x2600 && r <= 0x27BF) ||
    (r >= 0x2B00 && r <= 0x2BFF) ||
    (r >= 0x2300 && r <= 0x23FF) ||
    r == 0x200D ||
    r == 0xFE0F ||
    r == 0x20E3 ||
    (r >= 0xE0020 && r <= 0xE007F) ||
    r == 0x203C ||
    r == 0x2049;

/// Whether one written character (a grapheme, as someone counts them) is an emoji: every code point of it emoji-like,
/// and one of them a picture (a lone joiner or selector is not).
bool _isEmoji(String grapheme) {
  var picture = false;
  for (final r in grapheme.runes) {
    if (!_emojiRune(r)) return false;
    if (r != 0x200D && r != 0xFE0F && r != 0x20E3) picture = true;
  }
  return picture;
}

/// [spans] with each run of emoji in their words drawn in pixels ([PixelEmoji]) and the rest as they were. [base] is
/// the style the spans stand in, for the emoji's size where a span names none.
List<InlineSpan> pixelEmojiSpans(List<InlineSpan> spans, TextStyle base) => [for (final s in spans) ..._split(s, base)];

List<InlineSpan> _split(InlineSpan span, TextStyle base) {
  if (span is! TextSpan) return [span];
  final style = base.merge(span.style);
  final children = span.children == null ? null : [for (final c in span.children!) ..._split(c, style)];
  final text = span.text;
  if (text == null || text.isEmpty || !text.runes.any((r) => r >= 0x203C)) {
    return [children == null ? span : TextSpan(text: text, style: span.style, children: children, recognizer: span.recognizer, mouseCursor: span.mouseCursor, semanticsLabel: span.semanticsLabel)];
  }
  // The words in runs: emoji together, the rest together, in order.
  final out = <InlineSpan>[];
  final run = StringBuffer();
  var emoji = false;
  void end() {
    if (run.isEmpty) return;
    final words = run.toString();
    run.clear();
    out.add(emoji
        ? WidgetSpan(alignment: PlaceholderAlignment.middle, child: PixelEmoji(words, style: style))
        : TextSpan(text: words, style: span.style, recognizer: span.recognizer, mouseCursor: span.mouseCursor, semanticsLabel: span.semanticsLabel));
  }

  for (final g in text.characters) {
    final is_ = _isEmoji(g);
    if (is_ != emoji) end();
    emoji = is_;
    run.write(g);
  }
  end();
  return [...out, ...?children];
}

/// [emoji] (one or several, side by side) drawn in pixels at [style]'s size: as large on the line as the words would
/// draw it, on a grid of sixteen pixels to the em.
class PixelEmoji extends StatelessWidget {
  const PixelEmoji(this.emoji, {super.key, required this.style});
  final String emoji;
  final TextStyle style;

  /// How many of its pixels an em is: the letters' own sixteen.
  static const cells = 16;

  @override
  Widget build(BuildContext context) {
    final size = style.fontSize ?? 16;
    // Its own colours, with nothing of the words' under or over it (the look's shadow would be a second emoji).
    final plain = TextStyle(
      fontSize: size,
      height: style.height,
      fontFamily: style.fontFamily,
      fontFamilyFallback: style.fontFamilyFallback,
      leadingDistribution: style.leadingDistribution,
      color: const Color(0xFF000000),
    );
    final painter = TextPainter(text: TextSpan(text: emoji, style: plain), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout();
    final box = painter.size;
    final scaled = MediaQuery.textScalerOf(context).scale(size);
    final image = _small('$emoji\u0001${plain.fontFamily}\u0001${plain.fontFamilyFallback?.join(',')}\u0001${box.width / scaled}\u0001${box.height / scaled}', painter, scaled / cells);
    painter.dispose();
    return Semantics(
      label: emoji,
      child: ExcludeSemantics(child: CustomPaint(size: box, painter: _SmallPainter(image))),
    );
  }

  /// The small pictures made, the oldest let go past [_most]: one for each emoji, face and shape of its line.
  static final LinkedHashMap<String, ui.Image> _made = LinkedHashMap();
  static const _most = 400;

  /// [painter]'s emoji drawn with each [cell] logical pixels of it as one pixel of the picture.
  static ui.Image _small(String key, TextPainter painter, double cell) {
    final had = _made.remove(key);
    if (had != null) return _made[key] = had;
    final w = (painter.width / cell).ceil().clamp(1, 512), h = (painter.height / cell).ceil().clamp(1, 512);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(1 / cell);
    painter.paint(canvas, Offset.zero);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(w, h);
    picture.dispose();
    _made[key] = image;
    // Let go, not disposed: one still on a page that has not been drawn again since is still drawn from.
    while (_made.length > _most) {
      _made.remove(_made.keys.first);
    }
    return image;
  }

  /// Lets every small picture go: for a test that counts them, and when the emoji set changes.
  @visibleForTesting
  static void forget() {
    for (final image in _made.values) {
      image.dispose();
    }
    _made.clear();
  }

  @visibleForTesting
  static int get made => _made.length;
}

/// The small picture over the whole of its box, each of its pixels square.
class _SmallPainter extends CustomPainter {
  const _SmallPainter(this.image);
  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawImageRect(image, Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()), Offset.zero & size, Paint()..filterQuality = FilterQuality.none);

  @override
  bool shouldRepaint(_SmallPainter old) => old.image != image;
}
