import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/plugins/pack/review_keys.dart';
import 'package:ghost_messaging/safety/abuse_report.dart';

/// GMFB-40: a report of a person or a message is signed by the reporter and sealed to the review keys, so only the
/// reviewer opens it, and the relay keeps what it can't read.
void main() {
  final reviewer = NetKeys.generate();
  final reporter = NetKeys.generate();
  final stranger = NetKeys.generate();
  final reviewKey = base64Encode(reviewer.public);

  AbuseReport sample() => AbuseReport(
        kind: 'message',
        reason: ReportReason.harassment,
        note: 'They keep writing this.',
        subjectId: 'a4bbad8bc42293e4a4bbad8bc42293e4',
        subjectUsername: 'pest',
        subjectName: 'Pest',
        place: 'space',
        placeName: 'Book club',
        messages: withContext([
          for (var i = 0; i < 20; i++) ReportedMessage(from: i.isEven ? 'pest' : 'me', name: i.isEven ? 'Pest' : 'You', at: 1000 + i, text: 'message $i', mine: i.isOdd),
        ], 10),
        reporterUsername: 'ada',
        at: 1763800000000,
        platform: 'android',
        version: '0.12.12',
      );

  test('the reported message comes with five either side, marked', () {
    final msgs = sample().messages;
    expect(msgs.length, 11);
    expect([for (final m in msgs) m.text], [for (var i = 5; i <= 15; i++) 'message $i']);
    expect([for (final m in msgs) if (m.reported) m.text], ['message 10']);
    final edge = withContext([const ReportedMessage(from: 'x', name: 'X', at: 1, text: 'only')], 0);
    expect(edge.single.reported, isTrue);
    expect(withContext(const [], 0), isEmpty);
    final long = withContext([ReportedMessage(from: 'x', name: 'X', at: 1, text: 'a' * 5000)], 0);
    expect(long.single.text.length, AbuseReport.textMost);
  });

  test('a report reads back as it was written', () {
    final r = sample();
    final back = AbuseReport.fromJson(jsonDecode(jsonEncode(r.toJson())))!;
    expect(back.toJson(), r.toJson());
    expect(AbuseReport.fromJson({'v': 2}), isNull);
    expect(AbuseReport.fromJson({...r.toJson(), 'why': 'boring'}), isNull);
    expect(AbuseReport.fromJson({...r.toJson(), 'k': 'plugin'}), isNull);
  });

  test('sealed to the review key, it opens for the reviewer alone, signed by the reporter', () async {
    final sealed = await sealReport(sample(), signer: KeysSigner(reporter), reviewKeys: [reviewKey]);
    // What the relay keeps says nothing of what is inside.
    final envelope = latin1.decode(base64Decode(sealed));
    for (final words in ['Pest', 'pest', 'Book club', 'message 10', 'harassment', 'ada', reporter.id]) {
      expect(envelope.contains(words), isFalse, reason: '"$words" is sealed');
    }
    final opened = openReport(sealed, reviewer)!;
    expect(opened.verified, isTrue);
    expect(opened.reporterId, reporter.id);
    expect(opened.report.toJson(), sample().toJson());
    // Not a review key: nothing.
    expect(openReport(sealed, stranger), isNull);
    expect(openReport(sealed, reporter), isNull);
  });

  test('a changed envelope does not open, and a report signed by another key says so', () async {
    final sealed = await sealReport(sample(), signer: KeysSigner(reporter), reviewKeys: [reviewKey]);
    final bytes = base64Decode(sealed);
    for (final at in [0, 1, 40, bytes.length - 1]) {
      final changed = Uint8List.fromList(bytes);
      changed[at] ^= 1;
      expect(openReport(base64Encode(changed), reviewer), isNull, reason: 'byte $at changed');
    }
    expect(openReport(base64Encode(bytes.sublist(0, bytes.length - 5)), reviewer), isNull, reason: 'cut short');
    expect(openReport('not an envelope', reviewer), isNull);

    // A signer whose signature isn't over these words: opened, and marked not verified.
    final liar = _WrongSigner(reporter);
    final lied = openReport(await sealReport(sample(), signer: liar, reviewKeys: [reviewKey]), reviewer)!;
    expect(lied.verified, isFalse);
  });

  test('sealed to every review key given, skipping what is no key; none at all is refused', () async {
    final second = NetKeys.generate();
    final sealed = await sealReport(sample(), signer: KeysSigner(reporter), reviewKeys: [reviewKey, 'junk!', base64Encode(second.public)]);
    expect(openReport(sealed, reviewer), isNotNull);
    expect(openReport(sealed, second), isNotNull);
    expect(() => sealReport(sample(), signer: KeysSigner(reporter), reviewKeys: ['junk!']), throwsStateError);
  });

  test('the pinned review key is a key a report can be sealed to, and a full report fits the relay', () async {
    expect(marketReviewKeys, isNotEmpty);
    final full = AbuseReport(
      kind: 'message',
      reason: ReportReason.other,
      note: 'n' * AbuseReport.noteMost,
      subjectId: 'a' * 32,
      subjectUsername: 'u' * 20,
      subjectName: 'N' * 80,
      place: 'space',
      placeName: 'P' * 120,
      messages: [for (var i = 0; i < AbuseReport.messagesMost; i++) ReportedMessage(from: 'f' * 32, name: 'N' * 80, at: i, text: '😀' * (AbuseReport.textMost ~/ 2))],
      reporterUsername: 'r' * 20,
      at: 1,
    );
    final sealed = await sealReport(full, signer: KeysSigner(reporter), reviewKeys: marketReviewKeys);
    // relay/lib/market.dart Market.abuseSealedMost.
    expect(sealed.length, lessThan(48000));
    // Fitted, it keeps the reported message whatever else goes.
    final fitted = fitReport(full);
    expect(utf8.encode(jsonEncode(fitted.toJson())).length, lessThanOrEqualTo(reportBytesMost));

    final huge = full.copyWith(messages: [
      for (var i = 0; i < AbuseReport.messagesMost; i++) ReportedMessage(from: 'f', name: 'N', at: i, text: '😀' * 3000, reported: i == 8),
    ]);
    final cut = fitReport(huge);
    expect(utf8.encode(jsonEncode(cut.toJson())).length, lessThanOrEqualTo(reportBytesMost));
    expect(cut.messages.where((m) => m.reported).length, 1);
    expect((await sealReport(huge, signer: KeysSigner(reporter), reviewKeys: marketReviewKeys)).length, lessThan(48000));
  });

  test('the reports made here are kept newest first, at most a hundred', () {
    var raw = '[]';
    for (var i = 0; i < 105; i++) {
      raw = MadeReport.withAdded(raw, MadeReport(id: 'r$i', kind: 'person', reason: ReportReason.spam, who: '@x$i', where: 'Profile', at: i, blocked: i.isEven));
    }
    final list = MadeReport.readAll(raw);
    expect(list.length, MadeReport.most);
    expect(list.first.id, 'r104');
    expect(list.first.blocked, isTrue);
    expect(MadeReport.readAll('not json'), isEmpty);
  });
}

class _WrongSigner implements NetSigner {
  _WrongSigner(this.keys);
  final NetKeys keys;
  @override
  String get id => keys.id;
  @override
  Uint8List get publicKey => keys.public;
  @override
  Future<Uint8List> sign(List<int> message) async => NetCrypto.sign(keys, utf8.encode('something else'));
}
