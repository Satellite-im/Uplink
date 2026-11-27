import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'files.dart';
import 'files_roster.dart';
import 'p256.dart';
import 'sha256.dart';

/// Feedback from the app's Share feedback button, filed as a ticket in a Notion board (Matt, 2026-11-19: "wire up
/// notion to create user feedback tickets add a "share feedback" button ... upload screenshots and explain a bug,
/// suggest a feature or a few other options ... optionally provide their username automatically so we can give out
/// bug bounties").
///
/// `POST /feedback`, signed with the sender's hub key as a Files write is (headers `x-ghost-key`, `x-ghost-time`,
/// `x-ghost-sig` over `ghost-feedback v1\nPOST\n<path>\n<time>\n<body's sha256>`), with a JSON body:
/// `{type, title, text, username?, platform, version, shots: [{name, mime, data (base64)}]}`. The Notion token never
/// leaves this server: the app only ever speaks to the relay. A username is filed only where the sender's key holds
/// it ([ownsName], the handles' directory), so nobody claims another's bounty; one that doesn't check out is filed as
/// said, marked unverified. Limited by sender and in all ([perIdAnHour], [perIdADay], [allADay]).
///
/// The board's properties (made in Notion with the Notion connector, 2026-11-19): Title, Type (Bug, Feature idea,
/// Something confusing, Praise, Other), Status (New first), Description, Username, Screenshots (files), Platform
/// (Android, iPhone, Mac, Windows, Linux), Version, Bounty, Reported, ID (GMFB-n).
class FeedbackConfig {
  const FeedbackConfig({this.notionToken = '', this.dataSource = ''});

  /// The Notion integration's secret (`ntn_…`), and the board's data source id (a UUID).
  final String notionToken;
  final String dataSource;

  /// Whether both are set; where not, `/feedback` answers 503.
  bool get on => notionToken.isNotEmpty && dataSource.isNotEmpty;

  /// `GHOST_NOTION_TOKEN` and `GHOST_NOTION_FEEDBACK`, from the relay's environment file (tool/deploy-relay.mjs --env).
  factory FeedbackConfig.fromEnvironment(Map<String, String> env) =>
      FeedbackConfig(notionToken: (env['GHOST_NOTION_TOKEN'] ?? '').trim(), dataSource: (env['GHOST_NOTION_FEEDBACK'] ?? '').trim());
}

/// How Notion is spoken to: a method, an address, headers and a body, answered with a status and words. The app's
/// is [httpNotion]; a test gives its own.
typedef NotionCall = Future<(int, String)> Function(String method, Uri url, Map<String, String> headers, List<int> body);

/// Takes `POST /feedback`, checks who sent it and how often, and files it in Notion (the words above [FeedbackConfig]
/// say what is sent and what the board holds).
class Feedback {
  Feedback({required this.config, required this.ownsName, this.accountOf, NotionCall? notion, DateTime Function()? now, this.verbose = false})
      : _notion = notion ?? httpNotion,
        _now = now ?? DateTime.now;

  final FeedbackConfig config;

  /// Whether the install [id] holds the username [name] (Handles.ownsName).
  final bool Function(String id, String name) ownsName;

  /// The Uplink account an install's identity belongs to (Accounts.accountOf), or null.
  final String? Function(String id)? accountOf;
  final NotionCall _notion;
  final DateTime Function() _now;
  final bool verbose;

  /// The version of Notion's API asked for (the `Notion-Version` header).
  static const notionVersion = '2026-03-11';

  /// [most]: the largest request body, in bytes. [shotsMost] and [shotMost]: how many screenshots are taken, and each
  /// one's bytes; more or bigger are left out. [textMost], [titleMost]: characters kept of the words and the title.
  /// [skew]: how far the signed time may be from this server's. [perIdAnHour], [perIdADay]: reports from one sender's
  /// key. [allADay]: reports from everyone together.
  static const most = 10 * 1024 * 1024;
  static const shotsMost = 3;
  static const shotMost = 3 * 1024 * 1024;
  static const textMost = 5000;
  static const titleMost = 120;
  static const skew = Duration(minutes: 5);
  static const perIdAnHour = 5;
  static const perIdADay = 20;
  static const allADay = 300;

  /// What is checked before any of a body is read, since who sent it is known only after: [perAddressAnHour] bodies
  /// read from one address in an hour (several people may share one), [bodiesInFlight] being read at once (so at most
  /// that many times [most] held for strangers), and [bodyWhole] for a body to arrive, however steadily it drips.
  static const perAddressAnHour = 30;
  static const bodiesInFlight = 4;
  static const bodyWhole = Duration(minutes: 3);

  /// What the app sends for a report's kind and platform, and the board's name for each; and the pictures taken.
  static const types = {'bug': 'Bug', 'feature': 'Feature idea', 'confusing': 'Something confusing', 'praise': 'Praise', 'other': 'Other'};
  static const platforms = {'android': 'Android', 'iphone': 'iPhone', 'mac': 'Mac', 'windows': 'Windows', 'linux': 'Linux'};
  static const mimes = {'image/png', 'image/jpeg', 'image/webp', 'image/gif'};

  /// The words a sender signs (`path` as the relay is asked for it, `/feedback`).
  static String signedWords(String path, int time, String bodySha) => 'ghost-feedback v1\nPOST\n$path\n$time\n$bodySha';

  // When each sender filed a report in the last day, when anyone did, and the signed requests already taken (a hash
  // of the key and what it signed -> its time), so one is not taken twice.
  final Map<String, List<DateTime>> _byId = {};
  final List<DateTime> _all = [];
  final Map<String, int> _replays = {};

  // Bodies being read now, and how many each address had read in which hour (at most [_addressesMost] addresses, the
  // longest unseen forgotten first).
  int _reading = 0;
  final Map<String, (int, int)> _byAddress = {};
  static const _addressesMost = 10000;

  /// Whether [address] may have one more body read this hour: counted where it may.
  bool _mayRead(String address, int now) {
    final hour = now - now % Duration.millisecondsPerHour;
    final had = _byAddress.remove(address);
    final n = had != null && had.$1 == hour ? had.$2 : 0;
    _byAddress[address] = (hour, n < perAddressAnHour ? n + 1 : n);
    while (_byAddress.length > _addressesMost) {
      _byAddress.remove(_byAddress.keys.first);
    }
    return n < perAddressAnHour;
  }

  /// Whether [r] carries what a signed request does, before its body is read: a key and a signature of the right
  /// sizes, and a time within [skew]. The signature itself is checked once the body's hash is known ([_who]).
  bool _looksSigned(HttpRequest r) {
    try {
      final key = base64Decode(r.headers.value('x-ghost-key') ?? '');
      final sig = base64Decode(r.headers.value('x-ghost-sig') ?? '');
      final time = int.parse(r.headers.value('x-ghost-time') ?? '');
      return key.length == 33 && sig.length == 64 && (_now().millisecondsSinceEpoch - time).abs() <= skew.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  /// Takes a request for `/feedback`.
  Future<void> handle(HttpRequest r) async {
    Future<void> answer(int status, Map<String, Object?> body) async {
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await r.response.close();
    }

    if (r.method != 'POST') return answer(HttpStatus.methodNotAllowed, {'error': 'Feedback is sent with POST.'});
    if (!config.on) return answer(HttpStatus.serviceUnavailable, {'error': 'Feedback isn\'t set up on this server yet.'});
    // The signature is over the body's hash, so who sent it is known only after the body is read whole. What can be
    // told before is, so a stranger can't have this server hold megabytes for nothing: the length it says, the
    // headers a signed request has, how many its address has sent, and how many bodies are being read. Refused here it
    // is refused unread: dart:io holds an answer back until the body is read, so the body (and the connection) is let go.
    Future<void> unread(int status, Map<String, Object?> body) {
      try {
        r.listen(null).cancel();
        r.response.persistentConnection = false;
      } catch (_) {}
      return answer(status, body);
    }

    const tooBig = {'error': 'That\'s too big to send. Try fewer or smaller screenshots.'};
    if (r.contentLength > most) return unread(HttpStatus.requestEntityTooLarge, tooBig);
    if (!_looksSigned(r)) return unread(HttpStatus.unauthorized, {'error': 'The app\'s signature didn\'t check out. Make sure your clock is right, then try again.'});
    if (!_mayRead(Files.addressOf(r), _now().millisecondsSinceEpoch)) return unread(HttpStatus.tooManyRequests, {'error': 'That\'s a lot of feedback at once. Thank you! Try again in a while.'});
    if (_reading >= bodiesInFlight) return unread(HttpStatus.serviceUnavailable, {'error': 'A lot of feedback is arriving just now. Try again in a moment.'});
    // Into a BytesBuilder (never a List<int>, at 8 bytes a byte).
    final Uint8List bytes;
    final into = BytesBuilder(copy: false);
    final since = Stopwatch()..start();
    var over = false;
    _reading++;
    try {
      await for (final piece in r.timeout(const Duration(seconds: 30))) {
        if (into.length + piece.length > most) {
          over = true;
          break;
        }
        if (since.elapsed > bodyWhole) throw TimeoutException('too slow');
        into.add(piece);
      }
    } catch (_) {
      return answer(HttpStatus.badRequest, {'error': 'The feedback didn\'t arrive whole. Try again.'});
    } finally {
      _reading--;
    }
    if (over) {
      // The rest of it is not waited for.
      r.response.persistentConnection = false;
      return answer(HttpStatus.requestEntityTooLarge, tooBig);
    }
    bytes = into.takeBytes();
    final id = _who(r, hexOf(sha256(bytes)));
    if (id == null) return answer(HttpStatus.unauthorized, {'error': 'The app\'s signature didn\'t check out. Make sure your clock is right, then try again.'});
    final now = _now();
    final mine = _byId[id] ??= [];
    mine.removeWhere((t) => now.difference(t) > const Duration(days: 1));
    _all.removeWhere((t) => now.difference(t) > const Duration(days: 1));
    if (mine.where((t) => now.difference(t) <= const Duration(hours: 1)).length >= perIdAnHour || mine.length >= perIdADay || _all.length >= allADay) {
      return answer(HttpStatus.tooManyRequests, {'error': 'That\'s a lot of feedback at once. Thank you! Try again in a while.'});
    }
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
    } catch (_) {
      return answer(HttpStatus.badRequest, {'error': 'The feedback couldn\'t be read.'});
    }
    final report = FeedbackReport.read(j);
    if (report == null) return answer(HttpStatus.badRequest, {'error': 'Say what happened, in a few words at least.'});
    mine.add(now);
    _all.add(now);
    final named = report.username;
    final username = named == null ? '' : (ownsName(id, named) ? '@$named' : '@$named (not verified)');
    try {
      // Who sent it, by what stays theirs when the name changes (Matt, 2026-11-20: "tie users names to their accounts ...
      // so that we can give out bug bounties properly"): the install's id, which the admin page gives souls to, and its
      // account, which signing back in on another device or after a reinstall keeps. Only where they gave their name.
      final account = accountOf?.call(id);
      final reporter = named == null ? '' : 'Reporter: $username · Uplink id $id${account == null ? '' : ' · account $account'}';
      final ticket = await file(report, username: username, reporter: reporter);
      if (verbose) stdout.writeln('${now.toIso8601String()} feedback filed: $ticket');
      return answer(HttpStatus.ok, {'ok': true, 'id': ticket});
    } on _NotionError catch (e) {
      stderr.writeln('${now.toIso8601String()} feedback not filed: Notion said ${e.status} ${e.words.length > 300 ? e.words.substring(0, 300) : e.words}');
      return answer(HttpStatus.badGateway, {'error': 'The feedback board didn\'t take it just now. Try again in a while.'});
    } catch (e) {
      stderr.writeln('${now.toIso8601String()} feedback not filed: $e');
      return answer(HttpStatus.badGateway, {'error': 'The feedback board couldn\'t be reached. Try again in a while.'});
    }
  }

  /// The sender's id, where the request is signed by them, recently, and not seen before; null otherwise.
  String? _who(HttpRequest r, String bodySha) {
    try {
      final key = base64Decode(r.headers.value('x-ghost-key') ?? '');
      final sig = base64Decode(r.headers.value('x-ghost-sig') ?? '');
      final time = int.parse(r.headers.value('x-ghost-time') ?? '');
      final now = _now().millisecondsSinceEpoch;
      if ((now - time).abs() > skew.inMilliseconds) return null;
      final words = signedWords(r.uri.path, time, bodySha);
      final said = hexOf(sha256([...key, ...utf8.encode(words)]));
      _replays.removeWhere((_, at) => (now - at).abs() > skew.inMilliseconds * 2);
      if (_replays.containsKey(said) || _replays.length >= 10000) return null;
      if (!P256.verify(key, utf8.encode(words), sig)) return null;
      _replays[said] = time;
      return FilesRoster.idOf(key);
    } catch (_) {
      return null;
    }
  }

  /// What every call to Notion carries: the integration's secret and the API version.
  Map<String, String> get _headers => {'Authorization': 'Bearer ${config.notionToken}', 'Notion-Version': notionVersion};

  /// Files [report] as a page in the board, its screenshots uploaded to Notion first: the ticket's id, `GMFB-12`.
  Future<String> file(FeedbackReport report, {String username = '', String reporter = ''}) async {
    final uploads = <(String, String)>[];
    for (final s in report.shots) {
      uploads.add((await _upload(s), s.name));
    }
    List<Map<String, Object>> text(String words) => [
          // Notion takes at most 2000 characters in one piece of text.
          for (var i = 0; i < words.length; i += 2000) {'type': 'text', 'text': {'content': words.substring(i, min(i + 2000, words.length))}},
        ];
    final title = report.title.isNotEmpty ? report.title : _titleFrom(report.text);
    final page = {
      'parent': {'data_source_id': config.dataSource},
      'properties': {
        'Title': {'title': text(title)},
        'Type': {'select': {'name': types[report.type]!}},
        'Description': {'rich_text': text(report.text)},
        if (username.isNotEmpty) 'Username': {'rich_text': text(username)},
        if (report.platform != null) 'Platform': {'select': {'name': platforms[report.platform]!}},
        if (report.version.isNotEmpty) 'Version': {'rich_text': text(report.version)},
        if (uploads.isNotEmpty) 'Screenshots': {'files': [for (final (u, name) in uploads) {'type': 'file_upload', 'file_upload': {'id': u}, 'name': name}]},
      },
      // The words and the screenshots in the page itself too, to read without opening the properties.
      'children': [
        if (reporter.isNotEmpty) {'object': 'block', 'type': 'callout', 'callout': {'rich_text': text(reporter), 'icon': {'type': 'emoji', 'emoji': '🏷️'}}},
        for (final para in report.text.split(RegExp(r'\n{2,}')).where((p) => p.trim().isNotEmpty).take(50))
          {'object': 'block', 'type': 'paragraph', 'paragraph': {'rich_text': text(para.trim())}},
        for (final (u, _) in uploads) {'object': 'block', 'type': 'image', 'image': {'type': 'file_upload', 'file_upload': {'id': u}}},
      ],
    };
    final (status, words) = await _notion('POST', Uri.parse('https://api.notion.com/v1/pages'), {..._headers, 'Content-Type': 'application/json'}, utf8.encode(jsonEncode(page)));
    if (status != 200) throw _NotionError(status, words);
    return ticketOf(jsonDecode(words));
  }

  /// The ticket's id as the board shows it, from the page Notion made: its ID property, `GMFB-12`; else the page's id.
  static String ticketOf(Object? page) {
    if (page is! Map) return '';
    final id = (page['properties'] as Map?)?['ID'];
    final u = id is Map ? id['unique_id'] : null;
    if (u is Map && u['number'] is int) return u['prefix'] is String ? '${u['prefix']}-${u['number']}' : '${u['number']}';
    return '${page['id'] ?? ''}';
  }

  /// A title for a report sent without one: its first line, cut to 80 characters.
  static String _titleFrom(String text) {
    final line = text.trim().split('\n').first.trim();
    return line.length <= 80 ? line : '${line.substring(0, 77)}…';
  }

  /// Uploads one screenshot to Notion in its two steps (an upload is made, then the file sent to it as a form); the
  /// upload's id, which the page then names.
  Future<String> _upload(FeedbackShot s) async {
    // The name goes into a header of the form: without its quotes and anything a line could be ended or begun with.
    final (st1, w1) = await _notion('POST', Uri.parse('https://api.notion.com/v1/file_uploads'), {..._headers, 'Content-Type': 'application/json'}, utf8.encode(jsonEncode({'filename': s.name, 'content_type': s.mime})));
    if (st1 != 200) throw _NotionError(st1, w1);
    final id = '${(jsonDecode(w1) as Map)['id']}';
    final boundary = 'ghost${Random.secure().nextInt(1 << 30)}${Random.secure().nextInt(1 << 30)}';
    final body = <int>[
      ...utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="${s.name.replaceAll(RegExp(r'["\x00-\x1f\x7f]'), '')}"\r\nContent-Type: ${s.mime}\r\n\r\n'),
      ...s.bytes,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final (st2, w2) = await _notion('POST', Uri.parse('https://api.notion.com/v1/file_uploads/$id/send'), {..._headers, 'Content-Type': 'multipart/form-data; boundary=$boundary'}, body);
    if (st2 != 200) throw _NotionError(st2, w2);
    return id;
  }
}

/// A report as the app sent it, checked: its kind, words and screenshots.
class FeedbackReport {
  const FeedbackReport({required this.type, required this.text, this.title = '', this.username, this.platform, this.version = '', this.shots = const []});
  final String type;
  final String text;
  final String title;
  final String? username;
  final String? platform;
  final String version;
  final List<FeedbackShot> shots;

  /// From the body, or null where it has no words or no kind this board has.
  static FeedbackReport? read(Map<String, dynamic> j) {
    final type = j['type'];
    final text = j['text'] is String ? (j['text'] as String).trim() : '';
    if (type is! String || !Feedback.types.containsKey(type) || text.isEmpty) return null;
    String cut(Object? s, int most) {
      final w = s is String ? s.trim() : '';
      return w.length > most ? w.substring(0, most) : w;
    }

    // A username is kept without its "@" and in lower case, as the handles' directory compares them; one that isn't
    // of a username's shape is left out. Screenshots that aren't a picture of a kind taken, or are too big, are too.
    final u = j['username'];
    final username = u is String && RegExp(r'^@?[A-Za-z0-9][A-Za-z0-9._]{2,19}$').hasMatch(u.trim()) ? u.trim().replaceFirst('@', '').toLowerCase() : null;
    final p = j['platform'];
    final shots = <FeedbackShot>[];
    for (final s in (j['shots'] is List ? j['shots'] as List : const []).take(Feedback.shotsMost)) {
      if (s is! Map || s['data'] is! String || !Feedback.mimes.contains(s['mime'])) continue;
      final Uint8List bytes;
      try {
        bytes = base64Decode(s['data'] as String);
      } catch (_) {
        continue;
      }
      if (bytes.isEmpty || bytes.length > Feedback.shotMost) continue;
      final name = s['name'] is String && (s['name'] as String).trim().isNotEmpty ? cut(s['name'], 80) : 'screenshot';
      shots.add(FeedbackShot(name: name, mime: s['mime'] as String, bytes: bytes));
    }
    return FeedbackReport(
      type: type,
      text: cut(text, Feedback.textMost),
      title: cut(j['title'], Feedback.titleMost),
      username: username,
      platform: p is String && Feedback.platforms.containsKey(p) ? p : null,
      version: cut(j['version'], 40),
      shots: shots,
    );
  }
}

/// One screenshot of a report: its file name, its kind and its bytes.
class FeedbackShot {
  const FeedbackShot({required this.name, required this.mime, required this.bytes});
  final String name;
  final String mime;
  final Uint8List bytes;
}

/// Notion answered something other than 200: its status and what it said.
class _NotionError implements Exception {
  _NotionError(this.status, this.words);
  final int status;
  final String words;
}

/// Notion over HTTPS, as the relay speaks to it.
Future<(int, String)> httpNotion(String method, Uri url, Map<String, String> headers, List<int> body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close().timeout(const Duration(seconds: 60));
    final words = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 60));
    return (res.statusCode, words);
  } finally {
    client.close(force: true);
  }
}
