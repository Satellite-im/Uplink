import 'dart:convert';
import 'dart:io';

/// A circle's invite word (Matt, 2026-11-19: "add the custom invite code word as a default feature"): gogho.st/c/bookclub
/// in place of a long link, as a Discord server's vanity invite is, for every circle and for nothing.
///
/// - **Kept by a hash of the word**, never the word: the app and the site's /c/ page send `h`, a SHA-256 of the word
///   (lib/circles/invite_word.dart in the app). This server never sees the word in a request or in its file.
/// - **Holding the circle's link sealed** (`b`) with a key made from the word by a slow derivation (PBKDF2), so the
///   file says nothing to whoever reads it without guessing words. A word is meant to be shared: anyone who knows it
///   can join, as anyone with the link can.
/// - **Claimed by the install that set it** ([owner], by its hub id): only it may change or drop it. A word another
///   install holds is refused as taken. One install holds at most [maxForOne]; it sets at most [anHour] an hour. A
///   word not set again for [life] is let go (the app sets its words again as it starts).
///
/// What it says, over the hub: `{"dir": "word-set", "h", "b"}` (answered `{"dir": "word-set", "h", "ok": true}`),
/// `{"dir": "word-drop", "h"}` (`{"dir": "word-drop", "h", "ok": true}`) and `{"dir": "word", "h"}` (`{"dir": "word",
/// "h", "b"}`, `b` null for no such word). Over HTTP, `GET /word/<h>` answers `{"b": …}` or 404, for the site's page.
/// A refusal is `{"dir": "err", "about", "err"}`. An app from before this never says any of it.
class InviteWords {
  InviteWords({this.dataDir, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Directory? dataDir;
  final DateTime Function() _now;

  /// The `dir` messages this answers (the hub sends them here).
  static const dirs = {'word-set', 'word-drop', 'word'};

  /// [maxForOne]: words one install may hold. [anHour]: times one install may set a word in an hour. [maxBlob]: the
  /// most characters in a sealed link. [maxAll]: words kept in all. [life]: how long a word lasts unless set again.
  static const maxForOne = 10;
  static const anHour = 20;
  static const maxBlob = 1024;
  static const maxAll = 200000;
  static const life = Duration(days: 365);

  /// By the word's hash: who holds it, the sealed link, and when it was last set.
  final Map<String, ({String owner, String blob, int at})> _words = {};
  // When each install set a word in the last hour, in memory only: what [anHour] counts.
  final Map<String, List<DateTime>> _sets = {};
  bool _dirty = false;

  int get count => _words.length;

  static final _hash = RegExp(r'^[0-9a-f]{64}$');

  File? get _file => dataDir == null ? null : File('${dataDir!.path}/invite_words.json');

  /// Reads invite_words.json (`{v, words: {<hash>: {o: owner, b: sealed link, t: ms}}}`) as the hub starts.
  void load() {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map;
      for (final e in (j['words'] as Map).entries) {
        final v = e.value as Map;
        _words[e.key as String] = (owner: v['o'] as String, blob: v['b'] as String, at: (v['t'] as num).toInt());
      }
    } catch (_) {}
  }

  /// Writes the file where something changed: after each word set or dropped, and as the hub stops.
  void save() {
    final f = _file;
    if (f == null || !_dirty) return;
    _dirty = false;
    f.parent.createSync(recursive: true);
    final tmp = File('${f.path}.tmp')
      ..writeAsStringSync(jsonEncode({
        'v': 1,
        'words': {for (final e in _words.entries) e.key: {'o': e.value.owner, 'b': e.value.blob, 't': e.value.at}},
      }));
    tmp.renameSync(f.path);
  }

  /// Lets go of words not set again for [life]; the hub calls it every ten minutes.
  void sweep() {
    final cut = _now().subtract(life).millisecondsSinceEpoch;
    final before = _words.length;
    _words.removeWhere((_, v) => v.at < cut);
    if (_words.length != before) _dirty = true;
    save();
  }

  /// The sealed link for [hash], or null.
  String? blobOf(String hash) => _words[hash]?.blob;

  /// Who holds [hash], or null.
  String? owner(String hash) => _words[hash]?.owner;

  /// A message from the install [id] over the hub, answered through [tell].
  void said(String id, Map said, void Function(Map<String, Object?>) tell) {
    final dir = said['dir'];
    final h = said['h'];
    void refuse(String why) => tell({'dir': 'err', 'about': dir, 'err': why});
    if (h is! String || !_hash.hasMatch(h)) return refuse('That isn\'t a word\'s hash.');
    switch (dir) {
      case 'word':
        tell({'dir': 'word', 'h': h, 'b': _words[h]?.blob});
      case 'word-drop':
        final had = _words[h];
        if (had != null && had.owner != id) return refuse('That word is someone else\'s.');
        if (had != null) {
          _words.remove(h);
          _dirty = true;
          save();
        }
        tell({'dir': 'word-drop', 'h': h, 'ok': true});
      case 'word-set':
        final b = said['b'];
        if (b is! String || b.isEmpty || b.length > maxBlob) return refuse('That invite doesn\'t fit.');
        final had = _words[h];
        if (had != null && had.owner != id) return refuse('That word is taken. Try another.');
        final now = _now();
        final mine = _sets[id] ??= [];
        mine.removeWhere((t) => now.difference(t) > const Duration(hours: 1));
        if (mine.length >= anHour) return refuse('Too many words set in the last hour. Try again later.');
        if (had == null) {
          if (_words.values.where((v) => v.owner == id).length >= maxForOne) return refuse('You hold $maxForOne words already. Drop one first.');
          if (_words.length >= maxAll) return refuse('This server holds all the words it can.');
        }
        mine.add(now);
        _words[h] = (owner: id, blob: b, at: now.millisecondsSinceEpoch);
        _dirty = true;
        save();
        tell({'dir': 'word-set', 'h': h, 'ok': true});
    }
  }

  /// `GET /word/<hash>`, for the site's /c/ page.
  Future<void> handle(HttpRequest r, String hash) async {
    final b = r.method == 'GET' && _hash.hasMatch(hash) ? _words[hash]?.blob : null;
    r.response
      ..statusCode = b == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..headers.set('cache-control', 'no-store')
      ..write(jsonEncode({'b': b}));
    await r.response.close();
  }
}
