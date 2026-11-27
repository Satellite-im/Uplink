import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/home_record.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/kept_log.dart';
import 'package:ghost_relay/p256.dart';
import 'package:test/test.dart';

import 'fed_support.dart';

/// The relay's growing files kept as logs (lib/kept_log.dart; found in the second review, 2026-11-23): `hub-v2.json`
/// was rewritten whole on the event loop within two seconds of any change (7 MB at 200,000 keys: 47 ms), and
/// `homes.json` could reach 22 MB. Now a change is a line appended, and the whole is written again only in an isolate.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ghost-kept-log-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a change is a line appended: what was written is never written again for it', () async {
    final file = File('${dir.path}/kept.json');
    final log = KeptLog(file);
    log.load();
    for (var i = 0; i < 50000; i++) {
      log.set('k$i', i);
    }
    await log.flush(standing: 50000);
    final before = file.readAsBytesSync();
    log.set('k7', 'again');
    log.remove('k8');
    await log.flush(standing: 49999);
    final after = file.readAsBytesSync();
    expect(after.sublist(0, before.length), before, reason: 'the 50,000 lines as they were');
    expect(utf8.decode(after.sublist(before.length)), '${jsonEncode({'s': 'k7', 'x': 'again'})}\n${jsonEncode({'d': 'k8'})}\n');
    final back = KeptLog(file).load();
    expect([back.length, back.keys.last, back['k7'], back.containsKey('k8')], [49999, 'k7', 'again', false], reason: 'the last line for a key stands, in the order last set');
  });

  test('past so many lines more than stand, it is written again whole in an isolate, and what changes meanwhile is kept', () async {
    final file = File('${dir.path}/kept.json');
    final log = KeptLog(file, compactPast: 100);
    log.load();
    for (var round = 0; round < 3; round++) {
      for (var i = 0; i < 60; i++) {
        log.set('k$i', round);
      }
      final going = log.flush(standing: 60);
      // Said while the file may be being written again: written after it.
      log.set('late$round', round);
      await going;
    }
    await log.flush(standing: 63);
    final lines = file.readAsLinesSync();
    expect(lines.length, lessThan(100), reason: '183 changes, written again as what stands');
    final back = KeptLog(file).load();
    expect([back.length, back['k0'], back['late0'], back['late2']], [63, 2, 0, 2]);
  });

  test('a file of the kind written before is read, and written as a log from the next change', () async {
    final file = File('${dir.path}/hub-v2.json')..writeAsStringSync(jsonEncode({'v': 1, 'ids': ['a' * 32, 'b' * 32]}));
    final log = KeptLog(file);
    final read = log.load(whole: (all) => [for (final id in all['ids'] as List) MapEntry(id as String, 1)]);
    expect(read.keys, ['a' * 32, 'b' * 32]);
    expect(log.dirty, isTrue);
    await log.flush(standing: 2, all: () => read);
    expect(file.readAsLinesSync(), [jsonEncode({'s': 'a' * 32, 'x': 1}), jsonEncode({'s': 'b' * 32, 'x': 1})]);
  });

  test('the hub\'s kept keys and the relay\'s own records go through it, and come back after a restart', () async {
    final upgraded = someBytes(32);
    final hub = Hub(names: ['gogho.st'], dataDir: dir)..start();
    final (mine, theirs) = MemSocket.pair();
    final heard = <String>[];
    mine.incoming.listen((d) => heard.add(d as String));
    hub.attach(theirs);
    await pumpEventQueue();
    final nonce = unhex((jsonDecode(heard.first) as Map)['hello'] as String);
    final key = P256.publicOf(upgraded);
    mine.add(jsonEncode({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(P256.sign(upgraded, Hub.signedV2('gogho.st', nonce), someBytes(32))), 'v': 2, 'host': 'gogho.st'}));
    await pumpEventQueue();
    hub.stop();
    final again = Hub(names: ['gogho.st'], dataDir: dir)..start();
    expect(again.signsV2(Hub.nameOf(key)), isTrue);
    again.stop();
    // The records.
    final net = FakeNet();
    final alice = Install();
    final file = File('${dir.path}/homes.json');
    final book = HomeBook(file: file, now: net.now)..load();
    book.keep(HomeRecord.read(alice.record(['wss://a.test/hub']), now: net.now()).rec!, byOwner: true);
    await book.save();
    final back = HomeBook(file: file, now: net.now)..load();
    expect([back.own, back.isOwn(alice.id), back.ownSince(alice.id)], [1, true, net.now()]);
  });
}
