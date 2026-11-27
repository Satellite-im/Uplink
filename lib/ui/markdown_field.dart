import 'package:flutter/widgets.dart';

import '../links.dart';
import '../message_format.dart';
import '../mentions.dart';

/// The composer's words drawn as they will be when sent, as they are typed (GMFB-35, lib/message_format.dart): the
/// "**" of **bold** and the "> " of a quote fainter than the words, and the words between markers bold, italic,
/// struck through or code (Matt, 2026-11-25: "the text should be bold and italic inside the symbols and the code
/// block should show the code block too"). The words are the words: nothing is put in or taken out, the markers stay
/// in sight, and they go as written. A list's "- " and "1. " are drawn as typed: they are already what they will be.
///
/// MentionController (lib/ui/mention_field.dart) is one, with its mentions drawn in theirs.
class MarkdownController extends TextEditingController {
  MarkdownController({super.text});

  /// Whether the markers are dimmed now: not where the words go somewhere that shows them as written (a text). Always
  /// where null.
  bool Function()? dims;

  /// The mentions drawn in [mentionLook] among the words; none here.
  List<Mention> get drawnMentions => const [];
  TextStyle? get mentionLook => null;

  /// [before] and [after] put round the selection (Bold, Italic, Code and the rest in the selection's menu), the selection kept on
  /// the same words; at a cursor, the two with the cursor between them.
  void wrapSelection(String before, [String? after]) {
    final close = after ?? before;
    final s = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final words = text.substring(s.start, s.end);
    value = TextEditingValue(
      text: text.replaceRange(s.start, s.end, '$before$words$close'),
      selection: s.isCollapsed ? TextSelection.collapsed(offset: s.start + before.length) : TextSelection(baseOffset: s.start + before.length, extentOffset: s.start + before.length + words.length),
    );
  }

  /// "> " put before each line the selection touches, or the line the cursor is on (Quote, GMFB-35); taken off again
  /// where every one of them has it already. The selection stays on the same words.
  void quoteSelection() {
    final s = selection.isValid ? selection : TextSelection.collapsed(offset: text.length);
    final from = s.start == 0 ? 0 : text.lastIndexOf('\n', s.start - 1) + 1;
    final lines = text.substring(from, s.end).split('\n');
    final off = lines.every((l) => l.startsWith('> '));
    // Where each of those lines starts: a place in the words moves by two for every line that starts at or before it
    // (taken off: by as much of the "> " as stood before it).
    final starts = <int>[];
    var at = from;
    for (final l in lines) {
      starts.add(at);
      at += l.length + 1;
    }
    int moved(int p) {
      var q = p;
      for (final ls in starts) {
        if (ls <= p) q += off ? -(p - ls).clamp(0, 2) : 2;
      }
      return q;
    }

    value = TextEditingValue(
      text: text.replaceRange(from, s.end, [for (final l in lines) off ? l.substring(2) : '> $l'].join('\n')),
      selection: s.isCollapsed ? TextSelection.collapsed(offset: moved(s.start)) : TextSelection(baseOffset: moved(s.start), extentOffset: moved(s.end)),
    );
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final words = text;
    final look = mentionLook;
    final mentions = look == null ? const <Mention>[] : Mention.checked(drawnMentions, words);
    final dim = dims?.call() ?? true;
    final format = dim ? MessageFormat.parse(words, keep: [for (final m in mentions) (m.start, m.end)], links: [for (final l in MessageLink.find(words)) (l.start, l.end)]) : null;
    final runs = format?.runs ?? const <FormatRun>[];
    if ((format?.isPlain ?? true) && mentions.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final ink = style?.color ?? const Color(0xFF000000);
    final faint = TextStyle(color: ink.withValues(alpha: 0.4));
    // The word being composed on a phone's keyboard keeps its underline.
    final composing = withComposing && value.isComposingRangeValid ? value.composing : null;
    // The words are cut at every edge of a marker, a mention and the composing range; each piece between two cuts
    // then takes one style.
    final cuts = <int>{
      0,
      words.length,
      for (final r in runs) ...[r.start, r.end],
      for (final m in mentions) ...[m.start, m.end],
      if (composing != null) ...[composing.start, composing.end],
    }.where((c) => c >= 0 && c <= words.length).toList()
      ..sort();
    final spans = <InlineSpan>[];
    var ri = 0, mi = 0;
    for (var c = 0; c + 1 < cuts.length; c++) {
      final a = cuts[c], b = cuts[c + 1];
      if (b <= a) continue;
      while (ri < runs.length && runs[ri].end <= a) {
        ri++;
      }
      while (mi < mentions.length && mentions[mi].end <= a) {
        mi++;
      }
      TextStyle? s;
      if (ri < runs.length && runs[ri].start <= a) s = _look(runs[ri], faint, ink);
      if (mi < mentions.length && mentions[mi].start <= a) s = look;
      if (composing != null && a >= composing.start && b <= composing.end) {
        s = (s ?? const TextStyle()).merge(const TextStyle(decoration: TextDecoration.underline));
      }
      spans.add(TextSpan(text: words.substring(a, b), style: s));
    }
    return TextSpan(style: style, children: spans);
  }

  /// How a run is drawn in the field: a marker faint, and the words between markers as they will be drawn when sent
  /// (bold, italic, struck through, code in the code's letters on its ground), at the size of the rest so the lines
  /// and the cursor stay where they are. A spoiler's words are on a ground, not hidden: they are being written.
  static TextStyle? _look(FormatRun r, TextStyle faint, Color ink) {
    if (r.marker || r.bar) return faint;
    if (r.flags & (Fmt.bold | Fmt.italic | Fmt.strike | Fmt.code | Fmt.spoiler) == 0) return null;
    return TextStyle(
      fontWeight: r.has(Fmt.bold) ? FontWeight.w700 : null,
      fontStyle: r.has(Fmt.italic) ? FontStyle.italic : null,
      decoration: r.has(Fmt.strike) ? TextDecoration.lineThrough : null,
      fontFamily: r.has(Fmt.code) ? 'JetBrains Mono Variable' : null,
      backgroundColor: r.has(Fmt.code) ? ink.withValues(alpha: 0.1) : r.has(Fmt.spoiler) ? ink.withValues(alpha: 0.18) : null,
    );
  }
}
