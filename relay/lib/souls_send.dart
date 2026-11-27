import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'files.dart';
import 'files_roster.dart';
import 'p256.dart';
import 'sha256.dart';

/// Souls sent from one person to another (GMFB-39, "Payments between friends"; Matt, 2026-11-23: "Tip souls in a
/// chat"). Souls are the app's points and nothing else: this moves some of one person's to another, and never makes or
/// ends any (the moving itself is Handles.sendSouls, which keeps the counts).
///
/// Two routes, each a POST with a small JSON body, signed by the asker's own hub key as feedback is: headers
/// `x-ghost-key` (base64 of the key's 33 bytes), `x-ghost-time` (ms) and `x-ghost-sig` (base64, 64 bytes) over
/// [signedWords]. Who asks is the id of the key that signed, so nobody sends anyone else's souls.
///
/// - `POST /souls/send`, body `{to, souls, id}`: moves `souls` (a whole number, 1 to 100) from the asker to `to` (a
///   Uplink id that holds a username here). `id` is the asker's own name for this sending, 32 hex digits made up
///   afresh for each: asked again with the same `id` (an answer lost on the way) the relay answers the first receipt
///   and moves nothing. Answers `{ok, receipt: {id, at, from, to, souls}, n}` (n: the asker's souls after), with
///   `again: true` for a repeat.
/// - `POST /souls/receipt`, body `{id}`: `{ok, receipt}` for one of the two people in that sending, `receipt: null`
///   for anyone else or where there is none. The app shows a "sent you souls" card as real only once this agrees with
///   it, since the card itself is only a message and anyone can write one.
///
/// A refusal is `{ok: false, error: <code>, message: <words>}`. Every answer here is JSON with `ok`: the app takes any
/// other answer (a relay from before this says 200 and a line of text) as "not here yet".
class SoulsSend {
  SoulsSend({required this.send, required this.receiptOf, required this.soulsOf, DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// Handles.sendSouls, Handles.soulsReceipt and Handles.soulsOf.
  final ({String? error, Map<String, Object?>? receipt, bool again}) Function(String from, String to, int souls, String id) send;
  final Map<String, Object?>? Function(String id, String asker) receiptOf;
  final int Function(String id) soulsOf;
  final DateTime Function() _now;

  /// [most]: the longest body read, in bytes. [skew]: how far the signed time may be from this relay's clock.
  /// [perAddressAnHour]: requests from one address whose signature is checked in an hour (several people may share
  /// one). [sendsAnHour], [receiptsAnHour]: what one person may ask in an hour, refused ones counted too (the day's
  /// limits on what is sent are Handles.sendsADay and Handles.sendADay).
  static const most = 1024;
  static const skew = Duration(minutes: 5);
  static const perAddressAnHour = 600;
  static const sendsAnHour = 20;
  static const receiptsAnHour = 300;

  /// The words a request's key signs ([path] as the relay is asked for it).
  static String signedWords(String path, int time, String bodySha) => 'ghost-souls v1\nPOST\n$path\n$time\n$bodySha';

  static final _hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// What each refusal says, by its code. Plain words, and souls only ever called souls.
  static const words = {
    'amount': 'Send between 1 and 100 souls at a time.',
    'yourself': 'These are your souls already.',
    'no_account': 'Choose a username first, then send souls.',
    'no_receiver': 'They aren\'t on this relay, so souls can\'t reach them.',
    'id_used': 'That was sent already. Start again.',
    'daily_limit': 'That\'s all the souls you can send today. More tomorrow.',
    'not_enough': 'You don\'t have that many souls.',
    'rate_limited': 'Too many at once. Try again in a while.',
    'bad_signature': 'The app\'s signature didn\'t check out. Make sure your clock is right, then try again.',
    'bad_request': 'That couldn\'t be read.',
    'too_large': 'That\'s too long.',
    'method': 'Souls are sent with POST.',
  };

  // Signed requests already taken (a hash of the key and what it signed -> its time), so one heard on the wire is not
  // taken twice; and when each address, and each person, asked in the last hour.
  final Map<String, int> _replays = {};
  final Map<String, List<int>> _byAddress = {};
  final Map<String, List<int>> _sendsBy = {};
  final Map<String, List<int>> _receiptsBy = {};
  static const _kept = 20000;

  /// Whether [who] has asked fewer than [most] times in the last hour in [list]: counted where so.
  static bool _room(Map<String, List<int>> list, String who, int most, int now) {
    final mine = list.remove(who) ?? [];
    mine.removeWhere((t) => now - t > Duration.millisecondsPerHour);
    final ok = mine.length < most;
    if (ok) mine.add(now);
    // Put back last, so the one longest unheard from is the first forgotten.
    list[who] = mine;
    while (list.length > _kept) {
      list.remove(list.keys.first);
    }
    return ok;
  }

  /// Takes a request for `/souls/<what>`: `send` or `receipt`.
  Future<void> handle(HttpRequest r, String what) async {
    Future<void> answer(int status, Map<String, Object?> body) async {
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await r.response.close();
    }

    Future<void> refuse(int status, String code) => answer(status, {'ok': false, 'error': code, 'message': words[code] ?? code});
    // Refused before its body is read: the body, and the connection, are let go (as feedback.dart does).
    Future<void> unread(int status, String code) {
      try {
        r.listen(null).cancel();
        r.response.persistentConnection = false;
      } catch (_) {}
      return refuse(status, code);
    }

    if (r.method != 'POST') return unread(HttpStatus.methodNotAllowed, 'method');
    if (r.contentLength > most) return unread(HttpStatus.requestEntityTooLarge, 'too_large');
    final now = _now().millisecondsSinceEpoch;
    // What a signed request carries, each header once (dart:io's value() throws where one comes twice), before
    // anything is read or checked.
    final List<int> key, sig;
    final int time;
    try {
      String one(String name) {
        final v = r.headers[name];
        if (v == null || v.length != 1) throw const FormatException();
        return v.single.trim();
      }

      key = base64Decode(one('x-ghost-key'));
      sig = base64Decode(one('x-ghost-sig'));
      time = int.parse(one('x-ghost-time'));
      if (key.length != 33 || (key[0] != 2 && key[0] != 3) || sig.length != 64 || (now - time).abs() > skew.inMilliseconds) throw const FormatException();
    } catch (_) {
      return unread(HttpStatus.unauthorized, 'bad_signature');
    }
    // A signature costs this relay a P-256 check: so many an address an hour.
    if (!_room(_byAddress, Files.addressOf(r), perAddressAnHour, now)) return unread(HttpStatus.tooManyRequests, 'rate_limited');
    final bytes = <int>[];
    try {
      await for (final piece in r.timeout(const Duration(seconds: 15))) {
        bytes.addAll(piece);
        if (bytes.length > most) {
          r.response.persistentConnection = false;
          return refuse(HttpStatus.requestEntityTooLarge, 'too_large');
        }
      }
    } catch (_) {
      return refuse(HttpStatus.badRequest, 'bad_request');
    }
    final signed = utf8.encode(signedWords(r.uri.path, time, hexOf(sha256(bytes))));
    // Remembered by what was signed, not by the signature, which has a twin that checks out as well (market.dart).
    final said = hexOf(sha256([...key, ...signed]));
    _replays.removeWhere((_, at) => (now - at).abs() > skew.inMilliseconds * 2);
    if (_replays.containsKey(said) || _replays.length >= _kept) return refuse(HttpStatus.unauthorized, 'bad_signature');
    bool good;
    try {
      good = P256.verify(key, signed, sig);
    } catch (_) {
      good = false;
    }
    if (!good) return refuse(HttpStatus.unauthorized, 'bad_signature');
    _replays[said] = time;
    final asker = FilesRoster.idOf(key);
    final Map<String, dynamic> j;
    try {
      j = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>();
    } catch (_) {
      return refuse(HttpStatus.badRequest, 'bad_request');
    }
    final id = j['id'];
    if (id is! String || !_hex32.hasMatch(id)) return refuse(HttpStatus.badRequest, 'bad_request');
    if (what == 'receipt') {
      if (!_room(_receiptsBy, asker, receiptsAnHour, now)) return refuse(HttpStatus.tooManyRequests, 'rate_limited');
      return answer(HttpStatus.ok, {'ok': true, 'receipt': receiptOf(id, asker)});
    }
    if (!_room(_sendsBy, asker, sendsAnHour, now)) return refuse(HttpStatus.tooManyRequests, 'rate_limited');
    final to = j['to'], souls = j['souls'];
    if (to is! String || !_hex32.hasMatch(to)) return refuse(HttpStatus.badRequest, 'bad_request');
    // A whole number, as JSON has it: 20, never 20.5 or "20".
    if (souls is! int) return refuse(HttpStatus.badRequest, 'amount');
    final done = send(asker, to, souls, id);
    final error = done.error;
    if (error != null) {
      return refuse(
        switch (error) {
          'amount' || 'yourself' => HttpStatus.badRequest,
          'daily_limit' => HttpStatus.tooManyRequests,
          _ => HttpStatus.conflict,
        },
        error,
      );
    }
    return answer(HttpStatus.ok, {'ok': true, 'receipt': done.receipt, 'n': soulsOf(asker), if (done.again) 'again': true});
  }
}
