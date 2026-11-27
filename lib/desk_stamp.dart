/// A short mark of what a phone would answer its paired computer with, so that a computer asking for the same list
/// again and again is answered in a word while nothing has changed.
///
/// A paired computer asked the phone for every space and circle it has every eight seconds, and for its friends every
/// twenty, for as long as its app was open, and was sent the whole of each every time: a circle alone is up to 60 KB
/// with its picture. Sealed, sent and read again all day, with the phone in a pocket (Matt, 2026-11-24, with
/// Android's battery page saying "High CPU usage" under the app; docs/performance-audit.md, "A paired computer").
/// Now the computer says the mark it was last given (`have`), and a phone whose answer still has that mark says
/// `same` in its place. A phone or a computer from before knows nothing of marks and goes on as it did: the one
/// ignores `have` and answers in full, the other never sends it.
///
/// The mark is FNV-1a over everything in the answer, in the order it is written: a millisecond or two for a few
/// hundred kilobytes, and nothing like sending them. It is only ever compared with one this same device made.
library;

/// The mark of [answer]: eight hex digits.
String deskStamp(Object? answer) {
  var h = 0x811c9dc5;
  void byte(int b) => h = ((h ^ (b & 0xff)) * 0x01000193) & 0xffffffff;
  void walk(Object? o) {
    if (o is Map) {
      byte(0x7b);
      for (final e in o.entries) {
        walk('${e.key}');
        walk(e.value);
      }
      byte(0x7d);
    } else if (o is Iterable) {
      byte(0x5b);
      for (final x in o) {
        walk(x);
      }
      byte(0x5d);
    } else {
      final s = o is String ? o : '$o';
      for (var i = 0; i < s.length; i++) {
        final c = s.codeUnitAt(i);
        byte(c);
        if (c > 0xff) byte(c >> 8);
      }
      // Where one string ends and the next begins: "ab","c" is not "a","bc".
      byte(o is String ? 0x22 : 0x2c);
    }
  }

  walk(answer);
  return h.toRadixString(16).padLeft(8, '0');
}

/// [answer] as the phone gives it to a computer that said it [has] an answer by that mark already: the word `same`
/// where it still is the same, else the whole of it. Either way with the mark, for the computer to say next time.
Map<String, Object?> stampedFor(Object? has, Map<String, Object?> answer) {
  final stamp = deskStamp(answer);
  return has == stamp ? {'same': 1, 'stamp': stamp} : {...answer, 'stamp': stamp};
}
