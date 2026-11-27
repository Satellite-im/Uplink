/// Notion, as a circle's chats show it (Matt, 2026-11-25: "add a notion integration to ghost messaging through a plugin
/// that allows sharing notion boards and stuff with auto expansions in circles and only requires the circle to have
/// the plugin configured"). A link to a Notion page or database written in a space of a circle that has Notion set up
/// is drawn under its message as what it links to: a page's title, what it says first and what its database says of
/// it (status, who, when); a database as a board, its rows under the columns of its status.
///
/// What is read is read from Notion's own API (api.notion.com) by each member's device, with the circle's integration
/// token, which the circle keeps for its members (lib/circles). So one person sets it up and nobody else signs in to
/// anything, and Notion gives the token only what its integration was shared: a page nobody shared with it reads as
/// "not shared with this circle's Notion", never as its contents.
///
/// This file is the reading and the shaping, with nothing of the app in it: what sends a request is given
/// ([NotionSend]), so it is tried without a network.
library;

import 'dart:async';
import 'dart:convert';

/// Sends one request and answers with its status and body.
typedef NotionSend = Future<({int status, String body})> Function(String method, Uri url, Map<String, String> headers, String? body);

/// A link to something in Notion.
class NotionLink {
  const NotionLink({required this.id, required this.url, this.board = false});

  /// What it links to, as Notion's API names it: 32 hex digits with dashes.
  final String id;
  final String url;

  /// The link has a view (`?v=`), so it is probably a database: asked for as one first.
  final bool board;

  static final _hosts = RegExp(r'^(?:[a-z0-9-]+\.)?(?:notion\.so|notion\.site|notion\.com)$');
  static final _id = RegExp(r'([0-9a-f]{32})$');
  static final _dashed = RegExp(r'([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$');
  static final _urls = RegExp(r'https://[^\s<>()\[\]"]+', caseSensitive: false);

  static String _dash(String hex) => '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';

  static String? _idIn(String s) {
    final lower = s.toLowerCase();
    final plain = _id.firstMatch(lower);
    if (plain != null) return _dash(plain.group(1)!);
    final dashed = _dashed.firstMatch(lower);
    return dashed == null ? null : _dash([for (var i = 1; i <= 5; i++) dashed.group(i)!].join());
  }

  /// The Notion link [url] is; null for any other address, and for one of Notion's that names no page (its home, its
  /// help pages).
  static NotionLink? of(String url) {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.scheme != 'https' || !_hosts.hasMatch(u.host.toLowerCase())) return null;
    // A row opened over its database (`?p=`) is the row; otherwise the page the path ends with.
    final peek = u.queryParameters['p'];
    final row = peek == null ? null : _idIn(peek);
    if (row != null) return NotionLink(id: row, url: url.trim());
    final last = u.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    final id = last == null ? null : _idIn(last);
    if (id == null) return null;
    return NotionLink(id: id, url: url.trim(), board: u.queryParameters.containsKey('v'));
  }

  /// The Notion links in [text], each thing linked to once, in the order written; [most] at most.
  static List<NotionLink> allIn(String text, {int most = 3}) {
    final out = <NotionLink>[];
    for (final m in _urls.allMatches(text)) {
      // A full stop or a comma after a link is the sentence's, not the link's.
      final link = of(m.group(0)!.replaceFirst(RegExp(r'[.,;:!?]+$'), ''));
      if (link == null || out.any((x) => x.id == link.id)) continue;
      out.add(link);
      if (out.length >= most) break;
    }
    return out;
  }
}

/// One thing a database says of a page: "Status", "In progress".
class NotionFact {
  const NotionFact(this.name, this.value, {this.colour});
  final String name;
  final String value;

  /// Notion's own name for the colour of a status or a choice ("blue", "green"); null where it has none.
  final String? colour;
}

/// A row of a database, in a board.
class NotionRow {
  const NotionRow({required this.title, required this.url, this.icon});
  final String title;
  final String url;
  final String? icon;
}

/// A column of a board: the rows with one status.
class NotionColumn {
  const NotionColumn({required this.name, required this.rows, this.colour});
  final String name;
  final String? colour;
  final List<NotionRow> rows;
}

/// What a link is drawn as.
class NotionCard {
  const NotionCard({required this.title, required this.url, this.icon, this.excerpt = '', this.facts = const [], this.columns, this.by, this.more = false});
  final String title;
  final String url;

  /// An emoji, where the page or database has one for its icon.
  final String? icon;

  /// A page: what it says first.
  final String excerpt;

  /// A page of a database: what the database says of it.
  final List<NotionFact> facts;

  /// A database: its rows in columns; null for a page.
  final List<NotionColumn>? columns;

  /// The property the columns are (its name), where the database has a status or a choice to stand them by.
  final String? by;

  /// The database has more rows than were read.
  final bool more;

  bool get isBoard => columns != null;
  int get count => columns?.fold<int>(0, (n, c) => n + c.rows.length) ?? 0;
}

enum NotionProblem {
  /// The token was refused: wrong, or taken away in Notion.
  token,

  /// Notion says there is no such page for this token: it was not shared with the integration.
  notShared,

  /// Too many asked at once; worth asking again later.
  busy,

  /// Notion could not be reached, or answered with something else.
  other,
}

class NotionError implements Exception {
  const NotionError(this.problem, [this.detail = '']);
  final NotionProblem problem;
  final String detail;

  /// What the card says in the link's place.
  String get words => switch (problem) {
        NotionProblem.token => 'This circle\'s Notion token was refused. Whoever set Notion up here can put in a new one.',
        NotionProblem.notShared => 'Not shared with this circle\'s Notion. In Notion, open the page\'s ••• menu, Connections, and add the circle\'s integration.',
        NotionProblem.busy => 'Notion is busy. Try again in a moment.',
        NotionProblem.other => 'Notion could not be read${detail.isEmpty ? '' : ': $detail'}.',
      };

  @override
  String toString() => 'NotionError(${problem.name}${detail.isEmpty ? '' : ', $detail'})';
}

/// Reads Notion with one integration token.
class Notion {
  Notion(this.token, {required this.send, DateTime Function()? now}) : _now = now ?? DateTime.now;
  final String token;
  final NotionSend send;
  final DateTime Function() _now;

  /// The version of Notion's API these requests are written for.
  static const version = '2022-06-28';

  /// How long what was read is shown again without asking: a board changes, and a chat scrolled past is not a reason
  /// to ask Notion again.
  static const keep = Duration(minutes: 5);

  /// The rows of a database read for a board, and the most of a column drawn.
  static const rowsRead = 60;

  /// A token as Notion makes them, so a note pasted by mistake is not sent to Notion as one.
  static bool looksLikeToken(String s) => RegExp(r'^(?:secret_|ntn_)[A-Za-z0-9_]{20,}$').hasMatch(s.trim());

  final Map<String, ({DateTime at, NotionCard card})> _kept = {};
  final Map<String, Future<NotionCard>> _asking = {};

  /// What was read of [link] lately, without asking.
  NotionCard? kept(NotionLink link) {
    final k = _kept[link.id];
    return k != null && _now().difference(k.at) < keep ? k.card : null;
  }

  /// What [link] links to. Throws a [NotionError] where it cannot be read.
  Future<NotionCard> card(NotionLink link, {bool fresh = false}) {
    if (!fresh) {
      final had = kept(link);
      if (had != null) return Future.value(had);
    }
    return _asking[link.id] ??= _read(link).then((c) {
      _kept[link.id] = (at: _now(), card: c);
      return c;
    }).whenComplete(() {
      // In a block: an arrow would hand whenComplete the very future it is finishing, to wait on for good.
      _asking.remove(link.id);
    });
  }

  /// Whether the token is one Notion takes: asks who it is. The integration's name where it is.
  Future<String> check() async {
    final j = await _ask('GET', 'users/me');
    final name = j['name'];
    return name is String && name.trim().isNotEmpty ? name.trim() : 'Notion integration';
  }

  Future<NotionCard> _read(NotionLink link) async {
    // A link does not say whether it is a page or a database: the likelier is asked for first, then the other.
    Future<NotionCard> page() async => _page(await _ask('GET', 'pages/${link.id}'), link);
    Future<NotionCard> board() async => _board(await _ask('GET', 'databases/${link.id}'), link);
    try {
      return await (link.board ? board() : page());
    } on NotionError catch (e) {
      if (e.problem != NotionProblem.notShared) rethrow;
      return await (link.board ? page() : board());
    }
  }

  Future<Map<String, Object?>> _ask(String method, String path, {Map<String, Object?>? body}) async {
    final ({int status, String body}) r;
    try {
      r = await send(
        method,
        Uri.parse('https://api.notion.com/v1/$path'),
        {'Authorization': 'Bearer $token', 'Notion-Version': version, if (body != null) 'Content-Type': 'application/json'},
        body == null ? null : jsonEncode(body),
      ).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const NotionError(NotionProblem.other, 'no answer');
    } on NotionError {
      rethrow;
    } catch (_) {
      throw const NotionError(NotionProblem.other, 'no connection');
    }
    if (r.status == 401 || r.status == 403) throw const NotionError(NotionProblem.token);
    // Notion answers 404 for what the integration was not given, and 400 for an id that is the other kind of thing.
    if (r.status == 404 || r.status == 400) throw const NotionError(NotionProblem.notShared);
    if (r.status == 429) throw const NotionError(NotionProblem.busy);
    if (r.status < 200 || r.status >= 300) throw NotionError(NotionProblem.other, 'Notion answered ${r.status}');
    try {
      final j = jsonDecode(r.body);
      if (j is Map<String, Object?>) return j;
    } catch (_) {}
    throw const NotionError(NotionProblem.other, 'an answer that could not be read');
  }

  // --- shaping ---------------------------------------------------------------------------------------------------

  static String _plain(Object? rich) => rich is List ? [for (final x in rich) if (x is Map && x['plain_text'] is String) x['plain_text'] as String].join().trim() : '';

  static String? _icon(Object? icon) => icon is Map && icon['type'] == 'emoji' && icon['emoji'] is String ? icon['emoji'] as String : null;

  /// A page's title: its property of the kind `title`, whatever the database calls it.
  static String _titleOf(Map<String, Object?> page) {
    final props = page['properties'];
    if (props is Map) {
      for (final p in props.values) {
        if (p is Map && p['type'] == 'title') {
          final t = _plain(p['title']);
          if (t.isNotEmpty) return t;
        }
      }
    }
    return 'Untitled';
  }

  static String _dateWords(Object? d) {
    if (d is! Map || d['start'] is! String) return '';
    String day(String s) => s.length >= 10 ? s.substring(0, 10) : s;
    final end = d['end'];
    return end is String ? '${day(d['start'] as String)} to ${day(end)}' : day(d['start'] as String);
  }

  /// What a property says, where it is one a card has room for; null for the rest (long words, files, relations).
  static NotionFact? _fact(String name, Map p) {
    switch (p['type']) {
      case 'status' || 'select':
        final v = p[p['type']];
        return v is Map && v['name'] is String ? NotionFact(name, v['name'] as String, colour: v['color'] as String?) : null;
      case 'multi_select':
        final v = p['multi_select'];
        final names = v is List ? [for (final x in v) if (x is Map && x['name'] is String) x['name'] as String] : const <String>[];
        return names.isEmpty ? null : NotionFact(name, names.take(4).join(', '));
      case 'people':
        final v = p['people'];
        final names = v is List ? [for (final x in v) if (x is Map && x['name'] is String) x['name'] as String] : const <String>[];
        return names.isEmpty ? null : NotionFact(name, names.take(3).join(', '));
      case 'date':
        final w = _dateWords(p['date']);
        return w.isEmpty ? null : NotionFact(name, w);
      case 'checkbox':
        return p['checkbox'] == true ? NotionFact(name, 'Yes') : null;
      case 'number':
        return p['number'] is num ? NotionFact(name, '${p['number']}') : null;
    }
    return null;
  }

  Future<NotionCard> _page(Map<String, Object?> page, NotionLink link) async {
    final facts = <NotionFact>[];
    final props = page['properties'];
    if (props is Map) {
      // A status first, as a board's card leads with it.
      final entries = props.entries.where((e) => e.value is Map).toList()
        ..sort((a, b) => ((b.value as Map)['type'] == 'status' ? 1 : 0) - ((a.value as Map)['type'] == 'status' ? 1 : 0));
      for (final e in entries) {
        final f = _fact('${e.key}', e.value as Map);
        if (f != null) facts.add(f);
        if (facts.length >= 4) break;
      }
    }
    // What it says first: its opening blocks of words. A page with none of these it may read is drawn without.
    var excerpt = '';
    try {
      final blocks = await _ask('GET', 'blocks/${link.id}/children?page_size=12');
      final lines = <String>[];
      for (final b in (blocks['results'] as List? ?? const [])) {
        if (b is! Map) continue;
        final inner = b[b['type']];
        final words = inner is Map ? _plain(inner['rich_text']) : '';
        if (words.isNotEmpty) lines.add(words);
        if (lines.join(' ').length > 280) break;
      }
      excerpt = lines.join(' ');
      if (excerpt.length > 280) excerpt = '${excerpt.substring(0, 277).trimRight()}…';
    } on NotionError {
      excerpt = '';
    }
    return NotionCard(title: _titleOf(page), url: (page['url'] as String?) ?? link.url, icon: _icon(page['icon']), excerpt: excerpt, facts: facts);
  }

  Future<NotionCard> _board(Map<String, Object?> db, NotionLink link) async {
    final title = _plain(db['title']);
    // The property its columns are: its status where it has one, else its first single choice.
    String? by;
    var options = const <Map>[];
    final props = db['properties'];
    if (props is Map) {
      for (final kind in const ['status', 'select']) {
        for (final e in props.entries) {
          final p = e.value;
          if (by == null && p is Map && p['type'] == kind) {
            by = '${e.key}';
            final o = (p[kind] as Map?)?['options'];
            options = o is List ? [for (final x in o) if (x is Map) x] : const [];
          }
        }
      }
    }
    final rows = await _ask('POST', 'databases/${link.id}/query', body: {'page_size': rowsRead});
    final under = <String, List<NotionRow>>{};
    final loose = <NotionRow>[];
    for (final r in (rows['results'] as List? ?? const [])) {
      if (r is! Map<String, Object?>) continue;
      final row = NotionRow(title: _titleOf(r), url: (r['url'] as String?) ?? link.url, icon: _icon(r['icon']));
      final p = by == null ? null : (r['properties'] as Map?)?[by];
      final v = p is Map ? p[p['type']] : null;
      final name = v is Map && v['name'] is String ? v['name'] as String : null;
      if (name == null) {
        loose.add(row);
      } else {
        (under[name] ??= []).add(row);
      }
    }
    final columns = <NotionColumn>[
      // In the order Notion keeps the choices, and only those with something in them.
      for (final o in options)
        if (under['${o['name']}']?.isNotEmpty ?? false) NotionColumn(name: '${o['name']}', colour: o['color'] as String?, rows: under.remove('${o['name']}')!),
      for (final e in under.entries) NotionColumn(name: e.key, rows: e.value),
      if (loose.isNotEmpty) NotionColumn(name: by == null ? 'Pages' : 'No ${by.toLowerCase()}', rows: loose),
    ];
    return NotionCard(
      title: title.isEmpty ? 'Untitled' : title,
      url: (db['url'] as String?) ?? link.url,
      icon: _icon(db['icon']),
      columns: columns,
      by: by,
      more: rows['has_more'] == true,
    );
  }
}
