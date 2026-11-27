/// Every emoji, for the app's own emoji picker (Matt, 2026-11-19: "roll an in house emoji picker we should be able to
/// pull the code out from other apps we've built"): Ghost Keyboard's emoji plugin's data and search
/// (ghost-kbd: android/.../Emoji.kt), ported. assets/emoji/emoji.tsv is emojibase-data's list (MIT,
/// assets/emoji/LICENSE-emojibase), a line each: the emoji, its group, the Emoji version it came in, its name, its CLDR
/// keywords, its five skin tones (where it has them) and its shortcodes.
///
/// Emoji newer than [newest] are left out, so nothing is drawn as an empty box by a font or a phone that doesn't have
/// them yet.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app_state.dart';

@immutable
class EmojiEntry {
  const EmojiEntry(this.emoji, this.group, this.version, this.label, this.tags, this.skins, this.codes);
  final String emoji;
  final int group;
  final double version;
  final String label;
  final List<String> tags;

  /// Its five skin tones, light to dark; empty where it has none.
  final List<String> skins;
  final List<String> codes;

  /// In skin tone [tone] (1 to 5), where it has tones; itself otherwise.
  String toned(int tone) => tone >= 1 && tone <= 5 && skins.length == 5 ? skins[tone - 1] : emoji;
}

class EmojiData {
  EmojiData._(this.all);

  /// The newest Emoji version shown.
  static const newest = 15.0;

  /// The groups in order (2, the parts skin tones are made of, is not picked from), each with the emoji its tab shows
  /// and its name.
  static const groups = [
    (0, '😀', 'Smileys'),
    (1, '👋', 'People'),
    (3, '🐻', 'Animals & nature'),
    (4, '🍔', 'Food & drink'),
    (5, '✈️', 'Travel & places'),
    (6, '⚽', 'Activities'),
    (7, '💡', 'Objects'),
    (8, '💟', 'Symbols'),
    (9, '🏳️', 'Flags'),
  ];

  final List<EmojiEntry> all;

  static EmojiData? _loaded;
  static Future<EmojiData>? _loading;

  /// The list, read once from the app's assets.
  static Future<EmojiData> load() {
    final had = _loaded;
    if (had != null) return SynchronousFuture(had);
    return _loading ??= rootBundle.loadString('assets/emoji/emoji.tsv').then((tsv) => _loaded = parse(tsv));
  }

  /// What is loaded already, where it is.
  static EmojiData? get loaded => _loaded;

  /// [tsv] read, newer than [newest] left out.
  static EmojiData parse(String tsv) {
    final out = <EmojiEntry>[];
    for (final line in tsv.split('\n')) {
      final f = line.split('\t');
      if (f.length < 7 || f[0].isEmpty) continue;
      final version = double.tryParse(f[2]) ?? 0;
      if (version > newest) continue;
      List<String> words(String s) => [for (final w in s.split(' ')) if (w.isNotEmpty) w];
      out.add(EmojiEntry(f[0], int.tryParse(f[1]) ?? 0, version, f[3], [for (final w in words(f[4])) w.replaceAll('_', ' ')], words(f[5]), words(f[6].trim())));
    }
    return EmojiData._(out);
  }

  /// The emoji in [group], in order.
  List<EmojiEntry> inGroup(int group) => [for (final e in all) if (e.group == group) e];

  /// Emoji for a search, best first: a shortcode or name that is the query, then ones that start with it, then
  /// keywords that do, then names that contain it. Every word of a query of several must match.
  List<EmojiEntry> search(String query, {int limit = 80}) {
    final q = query.trim().toLowerCase().replaceAll(RegExp(r'^:|:$'), '');
    if (q.isEmpty) return const [];
    final words = [for (final w in q.split(RegExp(r'\s+'))) if (w.isNotEmpty) w];
    final scored = <(EmojiEntry, int, int)>[];
    for (final (i, e) in all.indexed) {
      final label = e.label.toLowerCase();
      final parts = label.split(RegExp(r'[ :-]'));
      var total = 0;
      var ok = true;
      for (final w in words) {
        final s = e.codes.contains(w) || label == w
            ? 100
            : e.codes.any((c) => c.startsWith(w))
                ? 60
                : parts.any((p) => p.startsWith(w))
                    ? 50
                    : e.tags.any((t) => t.toLowerCase() == w)
                        ? 45
                        : e.tags.any((t) => t.toLowerCase().startsWith(w))
                            ? 30
                            : label.contains(w)
                                ? 15
                                : 0;
        if (s == 0) {
          ok = false;
          break;
        }
        total += s;
      }
      if (ok) scored.add((e, total, i));
    }
    scored.sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : a.$3.compareTo(b.$3));
    return [for (final s in scored.take(limit)) s.$1];
  }
}

/// The emoji this person picked lately, newest first, and their skin tone: kept with their choices.
class EmojiChoices {
  EmojiChoices(this.app);
  final AppState app;

  static const _recentKey = 'emoji_recent';
  static const _toneKey = 'emoji_tone';
  static const recentKept = 32;

  List<String> get recent => [for (final e in app.choice(_recentKey, '').split(' ')) if (e.isNotEmpty) e];

  void used(String emoji) => app.set(_recentKey, [emoji, ...recent.where((e) => e != emoji)].take(recentKept).join(' '));

  /// 0 for none (the yellow ones), 1 to 5 light to dark.
  int get tone => int.tryParse(app.choice(_toneKey, '0')) ?? 0;
  set tone(int t) => app.set(_toneKey, '${t.clamp(0, 5)}');
}
