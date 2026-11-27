/// Souls sent to a friend from a chat with them (GMFB-39, "Payments between friends": "Send or request money in a
/// chat"; Matt, 2026-11-23: "Tip souls in a chat"). Souls are the app's points (lib/ui/souls.dart) and nothing else:
/// some of yours become a friend's, and a card in the conversation says so.
///
/// Three parts, none of them drawn here (the page and the card are lib/ui/souls_send.dart):
///
/// - [SoulsApi]: the relay's two routes (relay/lib/souls_send.dart), signed with this account's hub key as feedback
///   is. `send` moves the souls and answers a receipt; `receipt` reads one back. A relay from before the routes
///   answers something that is not theirs, which is [SoulsSendError.notHere]: said plainly, nothing sent.
/// - [SoulsCard]: what the card is carried as. A message between friends is words and nothing else, kept and copied
///   to one's other devices as words, so the card is words too: a build from before this shows them as a message that
///   reads well enough ("I sent you 20 souls."), and this one draws them as a card.
/// - [SoulsReceipts]: whether a card is true. Anyone can write those words, so a card is drawn as souls sent only once
///   the relay's receipt of that name agrees with it: the same number, from the one who wrote the message, to the
///   other. The device that sent them has the receipt from the sending itself; every other asks the relay once and
///   keeps the answer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../net/crypto.dart';
import '../net/hub_carrier.dart';
import '../net/net.dart';
import '../platform_info.dart';
import '../web/http.dart' show pageHttp;

/// The most souls one sending moves, as the relay has it (Handles.sendAtOnce), and the longest note that goes with it.
const soulsAtOnce = 100;
const soulsNoteMost = 80;

/// "1 soul", "20 souls".
String soulsWords(int n) => '$n ${n == 1 ? 'soul' : 'souls'}';

/// A sending as its card is carried in a conversation: how many, the note that went with them ('' for none), and the
/// name of the relay's receipt for it.
class SoulsCard {
  const SoulsCard({required this.souls, required this.id, this.note = ''});
  final int souls;
  final String note;
  final String id;

  static final _words = RegExp(r'^I sent you (\d{1,3}) souls?\.\n(?:([^\n]{1,' '$soulsNoteMost' r'})\n)?Souls receipt: ([0-9a-f]{32})$');

  /// A note as it is sent: one line, its ends trimmed, [soulsNoteMost] characters at most.
  static String tidyNote(String note) {
    final one = note.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length > soulsNoteMost ? one.substring(0, soulsNoteMost).trim() : one;
  }

  /// The message a card is sent as. A build from before cards shows these words as they are.
  String get words => 'I sent you ${soulsWords(souls)}.\n${note.isEmpty ? '' : '${tidyNote(note)}\n'}Souls receipt: $id';

  /// The card [body] is, where a message is one whole: null for any other words, and for a number no sending has.
  static SoulsCard? of(String body) {
    final m = _words.firstMatch(body.trim());
    if (m == null) return null;
    final n = int.parse(m.group(1)!);
    if (n < 1 || n > soulsAtOnce) return null;
    return SoulsCard(souls: n, note: m.group(2) ?? '', id: m.group(3)!);
  }

  static final _receiptLine = RegExp(r'\s*Souls receipt: [0-9a-f]{0,32}\s*$');

  /// [text] as a list's preview shows it: a card's words without its receipt line, which is for the app and not for
  /// reading (GMFB-39). Any other words come back as they are.
  static String preview(String text) => text.startsWith('I sent you ') ? text.replaceFirst(_receiptLine, '') : text;

  /// A name for a new sending: 32 hex digits, made up afresh. The relay moves souls once for each name, so a sending
  /// asked again under its name (its answer lost on the way) is never sent twice.
  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    return NetCrypto.hex([for (var i = 0; i < 16; i++) r.nextInt(256)]);
  }
}

/// The relay's receipt for a sending: its name, when, from whom, to whom (Uplink ids), and how many.
class SoulsReceipt {
  const SoulsReceipt({required this.id, required this.at, required this.from, required this.to, required this.souls});
  final String id;
  final int at;
  final String from;
  final String to;
  final int souls;

  static SoulsReceipt? of(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], at = j['at'], from = j['from'], to = j['to'], souls = j['souls'];
    if (id is! String || at is! int || from is! String || to is! String || souls is! int) return null;
    return SoulsReceipt(id: id, at: at, from: from, to: to, souls: souls);
  }

  /// Whether this is the receipt [card] names, for that many souls, from [from] to [to]: the whole of what makes a
  /// card true.
  bool agrees(SoulsCard card, {required String from, required String to}) => id == card.id && souls == card.souls && this.from == from && this.to == to && from.isNotEmpty && to.isNotEmpty;
}

/// Why souls weren't sent, or a receipt not read: the relay's own code with its words, or one of this app's
/// ([notHere], 'unreachable', 'no_identity').
class SoulsSendError implements Exception {
  const SoulsSendError(this.code, this.message);
  final String code;
  final String message;

  /// The relay has no such route: one from before souls could be sent.
  static const notHere = SoulsSendError('not_here', 'Sending souls isn\'t available yet. Try again later.');
  static const unreachable = SoulsSendError('unreachable', 'Couldn\'t reach the relay. Check your connection and try again.');
  static const noIdentity = SoulsSendError('no_identity', 'Sign in first, then send souls.');

  @override
  String toString() => message;
}

/// One request to the relay: dart:io's HttpClient, the page's own fetch in a browser, or a test's.
typedef SoulsTransport = Future<({int status, Map<String, String> headers, Uint8List body})> Function(String method, Uri url, Map<String, String> headers, List<int> body, {required int most});

/// Where the relay at [hubUrl] takes `/souls/<what>`: its hub's address over http(s), without the `/hub`.
Uri soulsUrlFor(String hubUrl, String what) {
  final u = Uri.parse(hubUrl.trim());
  final segments = [...u.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isNotEmpty && segments.last == 'hub') segments.removeLast();
  return u.replace(scheme: u.scheme == 'ws' ? 'http' : (u.scheme == 'wss' ? 'https' : u.scheme), pathSegments: [...segments, 'souls', what], query: null, fragment: null);
}

/// The relay's routes for sending souls (relay/lib/souls_send.dart), signed by [signer].
class SoulsApi {
  SoulsApi({required this.hubUrl, required this.signer, SoulsTransport? transport, DateTime Function()? now})
      : _transport = transport ?? (PlatformInfo.isWeb ? pageHttp : _http),
        _now = now ?? DateTime.now;

  /// This account's own relay, where its souls are kept, signed with its hub key.
  factory SoulsApi.live() {
    final hub = Net.instance.hub;
    return SoulsApi(hubUrl: hub?.url ?? Net.instance.hubUrl, signer: hub?.signer);
  }

  final String hubUrl;
  final NetSigner? signer;
  final SoulsTransport _transport;
  final DateTime Function() _now;

  /// This account's Uplink id, which the relay keeps its souls under; '' signed out.
  String get me => signer?.id ?? '';

  /// The last signed time sent: two requests in one millisecond would replay each other.
  int _last = 0;

  /// Sends [souls] to the Uplink id [to] under the name [id] ([SoulsCard.newId]): the relay's receipt, and this
  /// account's souls after. Safe to ask again with the same [id]: the relay answers the first receipt and moves
  /// nothing more. Throws a [SoulsSendError] where nothing was sent, or (unreachable) where it can't be known.
  Future<({SoulsReceipt receipt, int n})> send({required String to, required int souls, required String id}) async {
    final j = await _ask('send', {'to': to, 'souls': souls, 'id': id});
    final receipt = SoulsReceipt.of(j['receipt']);
    final n = j['n'];
    // An answer that says ok and is not a receipt for what was asked is nobody's word that souls moved.
    if (receipt == null || n is! int || receipt.id != id || receipt.souls != souls || receipt.to != to || receipt.from != me) throw SoulsSendError.unreachable;
    return (receipt: receipt, n: n);
  }

  /// The relay's receipt of the sending [id], for one of the two people in it; null where it has none for this
  /// account. Throws a [SoulsSendError] where the relay couldn't be asked.
  Future<SoulsReceipt?> receipt(String id) async => SoulsReceipt.of((await _ask('receipt', {'id': id}))['receipt']);

  Future<Map> _ask(String what, Map<String, Object?> body) async {
    final by = signer;
    if (by == null) throw SoulsSendError.noIdentity;
    final url = soulsUrlFor(hubUrl, what);
    final bytes = utf8.encode(jsonEncode(body));
    // Signed over what the relay sees: the path, the time and the body's hash.
    final time = _last = math.max(_now().millisecondsSinceEpoch, _last + 1);
    final ({int status, Map<String, String> headers, Uint8List body}) r;
    try {
      final sig = await by.sign(utf8.encode('ghost-souls v1\nPOST\n${url.path}\n$time\n${NetCrypto.hex(NetCrypto.sha256(bytes))}'));
      r = await _transport(
        'POST',
        url,
        {'content-type': 'application/json; charset=utf-8', 'x-ghost-key': base64Encode(by.publicKey), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(sig)},
        bytes,
        most: 16 * 1024,
      ).timeout(const Duration(seconds: 20));
    } catch (_) {
      // A socket, a handshake, a timeout: the same words whichever.
      throw SoulsSendError.unreachable;
    }
    // Every answer of these routes is JSON that says `ok`, yes or no. Anything else is a relay without them: one from
    // before this answers any address it doesn't know with 200 and a line of text.
    Object? j;
    try {
      j = jsonDecode(utf8.decode(r.body));
    } catch (_) {
      j = null;
    }
    if (j is! Map || j['ok'] is! bool) {
      // A server in front that is having trouble is not a relay that hasn't got the routes.
      if (r.status >= 500) throw SoulsSendError.unreachable;
      throw SoulsSendError.notHere;
    }
    if (j['ok'] == true && r.status == 200) return j;
    final code = j['error'], message = j['message'];
    throw SoulsSendError(code is String && code.isNotEmpty ? code : 'refused', message is String && message.trim().isNotEmpty ? message.trim() : 'The relay didn\'t send them.');
  }

  /// The app's own way to the relay: 15 s to connect, the answer read no further than [most].
  static Future<({int status, Map<String, String> headers, Uint8List body})> _http(String method, Uri url, Map<String, String> headers, List<int> body, {required int most}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl(method, url);
      headers.forEach(req.headers.set);
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close();
      final read = BytesBuilder(copy: false);
      await for (final piece in res) {
        read.add(piece);
        if (read.length > most) throw const FormatException('too long');
      }
      return (status: res.statusCode, headers: const <String, String>{}, body: read.takeBytes());
    } finally {
      client.close(force: true);
    }
  }
}

/// Sends [souls] to the friend whose Uplink id is [to], then writes the card into the conversation with [write] (true
/// where the message went). The souls first: a card is only ever written for a receipt the relay gave. Where the
/// relay's answer is lost on the way it is asked once more under the same [id], which can't send twice.
///
/// Throws a [SoulsSendError] where no souls were sent (or, unreachable twice over, where that can't be known: asking
/// again with the same [id] is safe). `written` is false where the souls went and the card's message didn't.
Future<({SoulsCard card, SoulsReceipt receipt, int n, bool written})> sendSoulsCard({
  required SoulsApi api,
  required String to,
  required int souls,
  required String id,
  String note = '',
  required Future<bool> Function(String words) write,
  SoulsReceipts? receipts,
}) async {
  ({SoulsReceipt receipt, int n}) sent;
  try {
    sent = await api.send(to: to, souls: souls, id: id);
  } on SoulsSendError catch (e) {
    if (e.code != 'unreachable') rethrow;
    sent = await api.send(to: to, souls: souls, id: id);
  }
  (receipts ?? SoulsReceipts.instance).keep(sent.receipt);
  final card = SoulsCard(souls: souls, id: id, note: SoulsCard.tidyNote(note));
  var written = false;
  try {
    written = await write(card.words);
  } catch (_) {}
  return (card: card, receipt: sent.receipt, n: sent.n, written: written);
}

/// Where a card stands: [confirmed] (the relay's receipt agrees with it), [refused] (the relay has no such receipt
/// for these two people, or it says something else), or [unknown] (not asked yet, or the relay couldn't be asked).
enum SoulsCardState { confirmed, refused, unknown }

/// Which cards are true ([SoulsReceipt.agrees]). Receipts that agreed are kept with the app's choices, so a card is
/// asked about once on each device; a refusal is kept until the app closes; a relay that couldn't be asked is asked
/// again after [askAgain].
class SoulsReceipts extends ChangeNotifier {
  SoulsReceipts({AppState? app, DateTime Function()? now})
      : _app = app,
        _now = now ?? DateTime.now;

  static SoulsReceipts instance = SoulsReceipts();

  AppState? _app;
  final DateTime Function() _now;

  /// Where what is confirmed is kept ('souls_receipts'): given by the first card drawn.
  void attach(AppState app) {
    if (identical(_app, app)) return;
    _app = app;
    _kept = null;
  }

  static const askAgain = Duration(minutes: 1);
  static const mostKept = 400;

  // id -> "from,to,souls", oldest first.
  Map<String, String>? _kept;
  // Each by the card's whole claim (its receipt's name, from whom, to whom, how many): words written over a true
  // receipt's name are refused, and held back, without the true card being either.
  final Set<String> _refused = {};
  final Map<String, DateTime> _failed = {};
  final Set<String> _asking = {};

  Map<String, String> get _all {
    final have = _kept;
    if (have != null) return have;
    final read = <String, String>{};
    try {
      final j = jsonDecode(_app?.choice('souls_receipts', '{}') ?? '{}');
      if (j is Map) j.forEach((k, v) => v is String ? read['$k'] = v : null);
    } catch (_) {}
    return _kept = read;
  }

  static String _line(String from, String to, int souls) => '$from,$to,$souls';

  /// A receipt the relay gave this device: kept as true.
  void keep(SoulsReceipt r) {
    final all = _all;
    final line = _line(r.from, r.to, r.souls);
    if (all[r.id] == line) return;
    all[r.id] = line;
    while (all.length > mostKept) {
      all.remove(all.keys.first);
    }
    _app?.set('souls_receipts', jsonEncode(all));
    _refused.remove('${r.id}|$line');
    notifyListeners();
  }

  /// Where [card] stands as one from [from] to [to] (Uplink ids).
  SoulsCardState stateOf(SoulsCard card, {required String from, required String to}) {
    final line = _line(from, to, card.souls);
    final kept = _all[card.id];
    if (kept != null) return kept == line && from.isNotEmpty && to.isNotEmpty ? SoulsCardState.confirmed : SoulsCardState.refused;
    if (_refused.contains('${card.id}|$line')) return SoulsCardState.refused;
    return SoulsCardState.unknown;
  }

  /// Asks the relay about [card] where that isn't known yet: true once it is confirmed. One asking at a time for a
  /// card, and not again within [askAgain] of one that couldn't be asked.
  Future<bool> check(SoulsCard card, {required String from, required String to, SoulsApi? api}) async {
    final state = stateOf(card, from: from, to: to);
    if (state != SoulsCardState.unknown) return state == SoulsCardState.confirmed;
    final claim = '${card.id}|${_line(from, to, card.souls)}';
    if (from.isEmpty || to.isEmpty || _asking.contains(claim)) return false;
    final last = _failed[claim];
    if (last != null && _now().difference(last) < askAgain) return false;
    _asking.add(claim);
    try {
      final r = await (api ?? SoulsApi.live()).receipt(card.id);
      if (r != null && r.agrees(card, from: from, to: to)) {
        keep(r);
        return true;
      }
      // The relay answered, and not with this: the card is somebody's words and no more.
      _refused.add(claim);
      notifyListeners();
      return false;
    } on SoulsSendError {
      // Not asked: it stays unknown, and is asked again later.
      _failed[claim] = _now();
      return false;
    } finally {
      _asking.remove(claim);
    }
  }
}
