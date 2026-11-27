import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/aside.dart';
import 'package:ghost_messaging/aside_web.dart' as web;

/// Changed by the work in the tests below: an isolate changes its own copy, work done in place changes this one.
var _touched = 0;

/// Heavy work done aside (lib/aside.dart; Matt: "the full web client"): on an isolate of its own wherever there are
/// isolates, in place in a browser, and asked for the same way in both.
void main() {
  setUp(() => _touched = 0);

  test('where there are isolates, the work is done on another and its answer handed back', () async {
    expect(await runAside(() => ++_touched * 42), 42);
    // The other isolate counted on its own copy.
    expect(_touched, 0);
    expect(await runAside(() async => 'later'), 'later');
    await expectLater(runAside<int>(() => throw StateError('no')), throwsStateError);
    await expectLater(runAside<int>(() async => throw const FormatException('nor this')), throwsFormatException);
  });

  test('in a browser it is done here: begun at once, answered later, and what it throws is the future\'s', () async {
    final answer = web.runAside(() => ++_touched * 42);
    // Begun before the call came back, so it read what it was given as it stood; the answer is still to come.
    expect(_touched, 1);
    var heard = false;
    unawaited(answer.then((_) => heard = true));
    expect(heard, isFalse);
    expect(await answer, 42);
    expect(await web.runAside(() async => 'later'), 'later');

    // Thrown at once or later, it is the future's error: the call itself never throws, as Isolate.run's doesn't.
    final Future<int> failed;
    try {
      failed = web.runAside<int>(() => throw StateError('no'));
    } catch (e) {
      fail('thrown by the call itself: $e');
    }
    await expectLater(failed, throwsStateError);
    await expectLater(web.runAside<int>(() async => throw const FormatException('nor this')), throwsFormatException);
  });

  test('one fits wherever the other does', () async {
    // lib/invites/invite_seal.dart keeps the worker in a variable of this type.
    Future<R> Function<R>(FutureOr<R> Function() work) worker = runAside;
    expect(await worker(() => 1), 1);
    worker = web.runAside;
    expect(await worker(() => 2), 2);
  });

  test('nothing in lib/ calls Isolate.run itself', () {
    // Where `Isolate.run` may be called, and why.
    const allowed = {
      'lib/aside_io.dart': 'the half of lib/aside.dart that is Isolate.run',
    };
    final use = RegExp(r'(?<![A-Za-z0-9_$])Isolate\s*\.\s*run\b');
    final found = <String>[];
    var files = 0;
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll('\\', '/');
      if (allowed.containsKey(path)) continue;
      files++;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        // What a comment says of it is no call.
        if (line.startsWith('//')) continue;
        if (use.hasMatch(line)) found.add('$path:${i + 1}: ${line.length > 120 ? '${line.substring(0, 120)}…' : line}');
      }
    }
    expect(files, greaterThan(300));
    expect(File('lib/aside_io.dart').readAsStringSync(), contains('Isolate.run<R>(work)'));
    expect(found, isEmpty, reason: 'Isolate.run throws in a browser before it has begun: call runAside (lib/aside.dart) instead.\n${found.join('\n')}');
  });
}
