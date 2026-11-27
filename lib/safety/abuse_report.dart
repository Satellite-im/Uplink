/// Reporting a person or a message (GMFB-40, from the Uplink gap review: "Report a user or message"; Matt approved the
/// reporting half, and no scanning of anyone's messages, which end-to-end encryption promises nobody does).
///
/// - **What a report holds** ([AbuseReport]): why (a [ReportReason]), the reporter's own words, who is reported, where,
///   and for a message, that message with a little of what was said round it. The relay can't read chats, so the
///   messages go only because the reporter chooses to hand them over.
/// - **Signed** by the reporter's hub key over the report's bytes, so the reviewer knows whose report it is and that
///   nobody changed it on the way.
/// - **Sealed to the review keys** ([sealReport]): the keys the Marketplace's approvals are made with, pinned in the app
///   (lib/plugins/pack/review_keys.dart), Matt's. A fresh key pair each time; for each review key, ECDH with it makes the
///   key that wraps the report's own random key; AES-256-GCM over the signed report. The relay keeps the envelope
///   (relay/lib/market.dart route 23) and can open nothing in it.
/// - **Opened** only on a device holding a review key ([openReport]): Settings › Admin › Reports of people, on Matt's
///   phone or a computer that is the same him.
///
/// Pure Dart, no Flutter: the relay's tests and the app's share none of this, but test/abuse_report_test.dart holds it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../net/crypto.dart';
import '../net/hub_carrier.dart' show NetSigner;

/// Why someone is reported, as the report names it.
enum ReportReason {
  spam('spam', 'Spam', 'Unwanted ads, scams or the same message again and again'),
  harassment('harassment', 'Harassment', 'Threats, bullying or hateful words'),
  impersonation('impersonation', 'Impersonation', 'Pretending to be someone they aren\'t'),
  illegal('illegal', 'Illegal content', 'Something against the law'),
  other('other', 'Something else', 'Say what in the note');

  const ReportReason(this.wire, this.label, this.hint);

  /// Its name in a report, what the person picks it by, and the line under that.
  final String wire;
  final String label;
  final String hint;

  /// The reason a report names as [wire]; null where it is none of them.
  static ReportReason? of(Object? wire) => values.where((r) => r.wire == wire).firstOrNull;
}

/// One message in a report: who sent it (an Uplink id, or a username chat's `@name`), their name as shown, when, its
/// words, and whether it is the one reported (the rest are what was said round it).
class ReportedMessage {
  const ReportedMessage({required this.from, required this.name, required this.at, required this.text, this.reported = false, this.mine = false});
  final String from;
  final String name;
  final int at;
  final String text;
  final bool reported;

  /// Sent by the reporter themselves.
  final bool mine;

  Map<String, Object> toJson() => {'f': from, 'n': name, 'a': at, 't': text, if (reported) 'r': true, if (mine) 'm': true};

  /// A message as a report carries it, each part cut to its most; null where [j] isn't one.
  static ReportedMessage? fromJson(Object? j) {
    if (j is! Map) return null;
    final f = j['f'], n = j['n'], a = j['a'], t = j['t'];
    if (f is! String || n is! String || a is! int || t is! String) return null;
    return ReportedMessage(from: _cut(f, 80), name: _cut(n, 80), at: a, text: _cut(t, AbuseReport.textMost), reported: j['r'] == true, mine: j['m'] == true);
  }
}

/// A report, before it is signed and sealed.
class AbuseReport {
  const AbuseReport({
    required this.kind,
    required this.reason,
    this.note = '',
    required this.subjectId,
    this.subjectUsername = '',
    this.subjectName = '',
    required this.place,
    this.placeName = '',
    this.messages = const [],
    this.reporterUsername = '',
    required this.at,
    this.platform = '',
    this.version = '',
  });

  /// 'message' or 'person'.
  final String kind;
  final ReportReason reason;
  final String note;

  /// Who is reported: their Uplink id where it is known ('' where only their username is), their username, their name
  /// as the reporter sees it.
  final String subjectId, subjectUsername, subjectName;

  /// Where: 'chat' (a username chat or a group of friends), 'space', or 'profile' (a profile card).
  final String place;
  final String placeName;
  final List<ReportedMessage> messages;

  /// The reporter's username, where they have one; their id and key are the signature's.
  final String reporterUsername;
  final int at;
  final String platform, version;

  bool get isMessage => kind == 'message';

  AbuseReport copyWith({String? note, List<ReportedMessage>? messages}) => AbuseReport(
        kind: kind,
        reason: reason,
        note: note ?? this.note,
        subjectId: subjectId,
        subjectUsername: subjectUsername,
        subjectName: subjectName,
        place: place,
        placeName: placeName,
        messages: messages ?? this.messages,
        reporterUsername: reporterUsername,
        at: at,
        platform: platform,
        version: version,
      );

  /// The app's limits; a report is fitted to [reportBytesMost] as well before it is sealed.
  static const noteMost = 1000, textMost = 1000, messagesMost = 11, contextEachSide = 5;

  Map<String, Object> toJson() => {
        'v': 1,
        'k': kind,
        'why': reason.wire,
        if (note.isNotEmpty) 'note': note,
        'who': {'i': subjectId, 'u': subjectUsername, 'n': subjectName},
        'where': {'k': place, 'n': placeName},
        if (messages.isNotEmpty) 'msgs': [for (final m in messages) m.toJson()],
        if (reporterUsername.isNotEmpty) 'by': reporterUsername,
        'at': at,
        if (platform.isNotEmpty) 'p': platform,
        if (version.isNotEmpty) 'ver': version,
      };

  /// A report as it was written (version 1), each part cut to its most; null where [j] isn't one.
  static AbuseReport? fromJson(Object? j) {
    if (j is! Map || j['v'] != 1) return null;
    final kind = j['k'], why = ReportReason.of(j['why']), who = j['who'], where = j['where'], at = j['at'];
    if ((kind != 'message' && kind != 'person') || why == null || who is! Map || where is! Map || at is! int) return null;
    String s(Object? v, int most) => v is String ? _cut(v, most) : '';
    return AbuseReport(
      kind: kind as String,
      reason: why,
      note: s(j['note'], noteMost),
      subjectId: s(who['i'], 80),
      subjectUsername: s(who['u'], 40),
      subjectName: s(who['n'], 80),
      place: s(where['k'], 20),
      placeName: s(where['n'], 120),
      messages: [for (final m in (j['msgs'] is List ? j['msgs'] as List : const []).take(messagesMost)) ?ReportedMessage.fromJson(m)],
      reporterUsername: s(j['by'], 40),
      at: at,
      platform: s(j['p'], 20),
      version: s(j['ver'], 40),
    );
  }
}

/// [s], no longer than [most].
String _cut(String s, int most) => s.length > most ? s.substring(0, most) : s;

/// [all] as a report hands them over: the one at [index] marked reported, with up to [AbuseReport.contextEachSide]
/// before and after it, each cut to [AbuseReport.textMost].
List<ReportedMessage> withContext(List<ReportedMessage> all, int index) {
  if (index < 0 || index >= all.length) return const [];
  final from = (index - AbuseReport.contextEachSide).clamp(0, all.length);
  final to = (index + AbuseReport.contextEachSide + 1).clamp(0, all.length);
  return [
    for (var i = from; i < to; i++)
      ReportedMessage(from: all[i].from, name: all[i].name, at: all[i].at, text: _cut(all[i].text, AbuseReport.textMost), reported: i == index, mine: all[i].mine),
  ];
}

/// What a reporter's key signs: these words and the SHA-256 of the report's bytes.
String reportSignedWords(List<int> reportBytes) => 'ghost-abuse-report v1\n${NetCrypto.hex(NetCrypto.sha256(reportBytes))}';

const _wrapLabel = 'abuse report wrap';

/// The most of a report's JSON bytes that is sealed: its envelope's base64 then stays under the relay's most
/// (Market.abuseSealedMost, 48,000 characters). [fitReport] drops what was said round the message to fit.
const reportBytesMost = 34000;

/// [report], made to fit [reportBytesMost]: the messages said furthest from the one reported dropped first, then the
/// note cut, then the reported message's own words.
AbuseReport fitReport(AbuseReport report) {
  int size(AbuseReport r) => utf8.encode(jsonEncode(r.toJson())).length;
  var r = report;
  while (size(r) > reportBytesMost && r.messages.length > 1) {
    final at = r.messages.indexWhere((m) => m.reported);
    final msgs = [...r.messages];
    // The end further from the reported one; with none reported, the oldest.
    if (at < 0 || at >= msgs.length - 1 - at) {
      msgs.removeAt(0);
    } else {
      msgs.removeLast();
    }
    r = r.copyWith(messages: msgs);
  }
  while (size(r) > reportBytesMost && r.note.length > 100) {
    r = r.copyWith(note: r.note.substring(0, r.note.length ~/ 2));
  }
  while (size(r) > reportBytesMost && r.messages.isNotEmpty && r.messages.first.text.length > 100) {
    final m = r.messages.first;
    r = r.copyWith(messages: [ReportedMessage(from: m.from, name: m.name, at: m.at, text: m.text.substring(0, m.text.length ~/ 2), reported: m.reported, mine: m.mine)]);
  }
  return r;
}

/// [report], fitted ([fitReport]), signed by [signer] and sealed to each of [reviewKeys] (base64 of 33-byte compressed
/// P-256 keys): base64 of the envelope, as the relay keeps it. [ephemeral] is a test's; a fresh pair otherwise.
///
/// The envelope's bytes: 1 (its version), the fresh public key (33), how many review keys (1), and for each its key
/// (33) and the report's own key wrapped for it (60: nonce, 32 bytes, tag); then the sealed body. The body opens to
/// the reporter's signature (64), their key (33), then the report's JSON.
Future<String> sealReport(AbuseReport report, {required NetSigner signer, required List<String> reviewKeys, NetKeys? ephemeral}) async {
  final bytes = utf8.encode(jsonEncode(fitReport(report).toJson()));
  final sig = await signer.sign(utf8.encode(reportSignedWords(bytes)));
  if (sig.length != 64 || signer.publicKey.length != 33) throw StateError('This device\'s key can\'t sign a report.');
  final e = ephemeral ?? NetKeys.generate();
  final cek = NetCrypto.randomBytes(32);
  final to = <List<int>>[];
  for (final k in reviewKeys.toSet()) {
    final Uint8List pub;
    try {
      pub = base64Decode(k);
    } catch (_) {
      continue;
    }
    final shared = NetCrypto.conversationKey(e, pub);
    if (shared == null) continue;
    to.add([...pub, ...NetCrypto.seal(NetCrypto.derive(shared, _wrapLabel), cek)]);
  }
  if (to.isEmpty) throw StateError('No review key to seal the report to.');
  final body = NetCrypto.seal(cek, [...sig, ...signer.publicKey, ...bytes]);
  return base64Encode([1, ...e.public, to.length, for (final t in to) ...t, ...body]);
}

/// A report opened by a reviewer: what it says, the reporter's key and id, and whether their signature holds.
class OpenedReport {
  const OpenedReport({required this.report, required this.reporterKey, required this.verified});
  final AbuseReport report;
  final Uint8List reporterKey;
  final bool verified;

  /// The reporter's Uplink id (NetCrypto.idOf their key).
  String get reporterId => NetCrypto.idOf(reporterKey);
}

/// [sealed] (as [sealReport] made it) opened with [mine], a review key's pair; null where it isn't sealed to that key,
/// was changed on the way, or doesn't read as a report.
OpenedReport? openReport(String sealed, NetKeys mine) {
  try {
    final env = base64Decode(sealed);
    if (env.length < 1 + 33 + 1 || env[0] != 1) return null;
    final epub = env.sublist(1, 34);
    final n = env[34];
    const each = 33 + 60;
    final bodyAt = 35 + n * each;
    if (n == 0 || env.length < bodyAt + 28) return null;
    List<int>? wrapped;
    for (var i = 0; i < n; i++) {
      final at = 35 + i * each;
      if (_same(env.sublist(at, at + 33), mine.public)) wrapped = env.sublist(at + 33, at + each);
    }
    if (wrapped == null) return null;
    final shared = NetCrypto.conversationKey(mine, epub);
    if (shared == null) return null;
    final cek = NetCrypto.open(NetCrypto.derive(shared, _wrapLabel), wrapped);
    if (cek == null || cek.length != 32) return null;
    final inner = NetCrypto.open(cek, env.sublist(bodyAt));
    if (inner == null || inner.length < 64 + 33 + 2) return null;
    final sig = inner.sublist(0, 64);
    final key = Uint8List.fromList(inner.sublist(64, 97));
    final bytes = inner.sublist(97);
    final report = AbuseReport.fromJson(jsonDecode(utf8.decode(bytes)));
    if (report == null) return null;
    final verified = NetCrypto.verify(key, utf8.encode(reportSignedWords(bytes)), sig);
    return OpenedReport(report: report, reporterKey: key, verified: verified);
  } catch (_) {
    return null;
  }
}

/// Whether [a] and [b] are the same bytes.
bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A report this device made, as Settings › Privacy › Reports you've made lists it: kept on the device alone, with no
/// messages in it, only who, why and when.
class MadeReport {
  const MadeReport({required this.id, required this.kind, required this.reason, required this.who, required this.where, required this.at, this.blocked = false});
  final String id;
  final String kind;
  final ReportReason reason;
  final String who;
  final String where;
  final int at;

  /// They were blocked with the report.
  final bool blocked;

  Map<String, Object> toJson() => {'id': id, 'k': kind, 'why': reason.wire, 'who': who, 'where': where, 'at': at, if (blocked) 'b': true};

  /// A report made here, as it was kept; null where [j] isn't one.
  static MadeReport? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], k = j['k'], why = ReportReason.of(j['why']), who = j['who'], where = j['where'], at = j['at'];
    if (id is! String || k is! String || why == null || who is! String || where is! String || at is! int) return null;
    return MadeReport(id: id, kind: k, reason: why, who: who, where: where, at: at, blocked: j['b'] == true);
  }

  /// The list as kept (newest first), and kept again with [added] at the top; at most [most].
  static const most = 100;
  static List<MadeReport> readAll(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [for (final x in j) ?fromJson(x)];
    } catch (_) {
      return const [];
    }
  }

  static String withAdded(String raw, MadeReport added) => jsonEncode([added.toJson(), for (final x in readAll(raw).take(most - 1)) x.toJson()]);
}
