import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'p256.dart';
import 'sha256.dart';

/// Bounties paid in souls without the admin page (Matt, 2026-11-21: "i want you to pay the bounties for me", then "A
/// bounty key on the relay"): 50 souls for each bug a tester reported that was fixed, 75 for each idea of theirs that
/// was built, from the feedback board.
///
/// `POST /bounty`, signed by the bounty key alone (its public half is GHOST_BOUNTY_KEY, 33 bytes in hex, from the
/// relay's environment; its private half stays on the Mac that pays): headers `x-ghost-key`, `x-ghost-time`,
/// `x-ghost-sig` over `ghost-bounty v1\nPOST\n/bounty\n<time>\n<body's sha256>`, as the app signs its feedback; a body
/// `{to, souls, why}`. It gives souls and nothing else: between 1 and [mostAtOnce] at a time, at most [mostADay]
/// grants a day, each with why (the ticket), recorded in the admin log as the admin page's are ([give]). Off where the
/// key is not set.
class Bounty {
  Bounty({required this.key, required this.give, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The bounty key's public half, in hex; empty for off.
  final String key;

  /// Gives [souls] to [to] for [why], as the admin page's `admin-give` does: their total after.
  final int Function(String to, int souls, String why) give;
  final DateTime Function() _now;

  /// The most souls one bounty gives, the most bounties in any day, how far the signed time may be from this relay's
  /// clock either way, and the longest body read, in bytes.
  static const mostAtOnce = 500;
  static const mostADay = 30;
  static const skew = Duration(minutes: 5);
  static const most = 4096;

  /// The words the key signs.
  static String signedWords(int time, String bodySha) => 'ghost-bounty v1\nPOST\n/bounty\n$time\n$bodySha';

  /// Whether bounties are paid here at all: the key set is a public key (33 bytes in hex, beginning 02 or 03).
  bool get on => RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(key);

  /// GHOST_BOUNTY_KEY from the relay's environment file (tool/deploy-relay.mjs --env).
  static String keyFrom(Map<String, String> env) => (env['GHOST_BOUNTY_KEY'] ?? '').trim().toLowerCase();

  /// When each bounty of the last day was paid; and the signatures taken lately (a hash of each, with its signed time),
  /// so one heard on the wire can't be sent a second time while its time is still good.
  final List<DateTime> _today = [];
  final Map<String, int> _replays = {};

  /// `POST /bounty`. Answers `{ok, to, souls, n}` (n: their total after), or `{error}` with 405 (not a POST), 404 (no
  /// key set), 413 (body too long), 401 (not signed by the key, too old, or sent before), 400 (a body that can't be
  /// read or is out of range) or 429 (the day's bounties are used up).
  Future<void> handle(HttpRequest r) async {
    Future<void> answer(int status, Map<String, Object?> body) async {
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await r.response.close();
    }

    if (r.method != 'POST') return answer(HttpStatus.methodNotAllowed, {'error': 'A bounty is paid with POST.'});
    if (!on) return answer(HttpStatus.notFound, {'error': 'Not here.'});
    final bytes = <int>[];
    try {
      await for (final piece in r.timeout(const Duration(seconds: 15))) {
        bytes.addAll(piece);
        if (bytes.length > most) return answer(HttpStatus.requestEntityTooLarge, {'error': 'Too long to be a bounty.'});
      }
    } catch (_) {
      return answer(HttpStatus.badRequest, {'error': 'It didn\'t arrive whole.'});
    }
    if (!_signed(r, hexOf(sha256(bytes)))) return answer(HttpStatus.unauthorized, {'error': 'Not signed by the bounty key, or too old.'});
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
    } catch (_) {
      return answer(HttpStatus.badRequest, {'error': 'It couldn\'t be read.'});
    }
    final to = j['to'], souls = j['souls'], why = j['why'];
    if (to is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(to)) return answer(HttpStatus.badRequest, {'error': 'to is an Uplink id: 32 hex characters.'});
    if (souls is! int || souls < 1 || souls > mostAtOnce) return answer(HttpStatus.badRequest, {'error': 'Between 1 and $mostAtOnce souls.'});
    if (why is! String || why.trim().isEmpty || why.length > 200) return answer(HttpStatus.badRequest, {'error': 'Say why (the ticket), in at most 200 characters.'});
    final now = _now();
    _today.removeWhere((t) => now.difference(t) > const Duration(days: 1));
    if (_today.length >= mostADay) return answer(HttpStatus.tooManyRequests, {'error': 'That\'s $mostADay bounties today; more tomorrow.'});
    _today.add(now);
    final total = give(to, souls, why.trim());
    return answer(HttpStatus.ok, {'ok': true, 'to': to, 'souls': souls, 'n': total});
  }

  /// Whether the request's headers carry the bounty key, a time within [skew] of now, and that key's signature over
  /// [signedWords] for this body, not taken before. A signature is remembered only once it has checked out.
  bool _signed(HttpRequest r, String bodySha) {
    try {
      final k = base64Decode(r.headers.value('x-ghost-key') ?? '');
      if (hexOf(k) != key) return false;
      final sig = base64Decode(r.headers.value('x-ghost-sig') ?? '');
      final time = int.parse(r.headers.value('x-ghost-time') ?? '');
      final now = _now().millisecondsSinceEpoch;
      if ((now - time).abs() > skew.inMilliseconds) return false;
      final words = signedWords(time, bodySha);
      final said = hexOf(sha256(utf8.encode('$words|${base64Encode(sig)}')));
      _replays.removeWhere((_, at) => (now - at).abs() > skew.inMilliseconds * 2);
      if (_replays.containsKey(said)) return false;
      if (!P256.verify(k, utf8.encode(words), sig)) return false;
      _replays[said] = time;
      return true;
    } catch (_) {
      return false;
    }
  }
}
