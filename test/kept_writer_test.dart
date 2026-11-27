import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/kept_writer.dart';

/// docs/performance-audit.md, finding 4: a network's chats are written by another isolate, a run of changes as one
/// write, where the whole store was written on the thread that draws after every event.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('kept-writer'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a run of changes is one write of what stands at the end', () async {
    final file = File('${dir.path}/deep/chats.json');
    final data = <String, Object?>{'messages': <Object?>[]};
    var asked = 0;
    final w = KeptWriter(
      file: () => file,
      snapshot: () {
        asked++;
        return data;
      },
      wait: const Duration(milliseconds: 80),
    );
    for (var i = 0; i < 50; i++) {
      (data['messages']! as List).add({'ts': i, 'text': 'message $i'});
      w.save();
    }
    expect(w.waiting, isTrue);
    expect(file.existsSync(), isFalse, reason: 'nothing written on the calling thread');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await w.settled;
    expect(asked, 1, reason: 'fifty changes, one snapshot');
    final kept = jsonDecode(file.readAsStringSync()) as Map;
    expect((kept['messages'] as List).length, 50);
    expect((kept['messages'] as List).last, {'ts': 49, 'text': 'message 49'});
    expect(File('${file.path}.tmp').existsSync(), isFalse, reason: 'written beside itself and moved into place');
    expect(w.waiting, isFalse);
  });

  test('a steady stream still reaches the file: no longer than `most` after the first change', () async {
    final file = File('${dir.path}/chats.json');
    var n = 0;
    final w = KeptWriter(file: () => file, snapshot: () => {'n': n}, wait: const Duration(milliseconds: 100), most: const Duration(milliseconds: 250));
    final end = DateTime.now().add(const Duration(milliseconds: 600));
    while (DateTime.now().isBefore(end)) {
      n++;
      w.save();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await w.settled;
    expect(file.existsSync(), isTrue, reason: 'a change every 30 ms never lets the 100 ms wait run out; `most` does');
    w.flush();
    expect((jsonDecode(file.readAsStringSync()) as Map)['n'], n);
  });

  test('flush writes what waits at once, and nothing where nothing waits', () {
    final file = File('${dir.path}/chats.json');
    final w = KeptWriter(file: () => file, snapshot: () => {'a': 1});
    w.flush();
    expect(file.existsSync(), isFalse);
    w.save();
    w.flush();
    expect(jsonDecode(file.readAsStringSync()), {'a': 1});
    expect(w.waiting, isFalse);
  });
}
