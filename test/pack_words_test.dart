import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The words the review key signs (Matt, 2026-11-20: "I'd like to be able to verify them for the store through a review
/// process") are written in one file of the app and the relay's market alone: no later feature can become a way to have
/// the review key sign an approval, a withdrawal or a retirement.
void main() {
  test('the review\'s words are only in lib/plugins/pack/review.dart and relay/lib/market*.dart', () {
    const words = ['ghost-market approve', 'ghost-market revoke', 'ghost-market retire'];
    final allowed = RegExp(r'^(lib/plugins/pack/review\.dart|relay/lib/market[^/]*\.dart)$');
    final found = <String>[];
    var read = 0;
    for (final root in ['lib', 'relay/lib']) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        final path = f.path.replaceAll(r'\', '/');
        if (allowed.hasMatch(path)) continue;
        final String text;
        try {
          text = f.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        read++;
        for (final w in words) {
          if (text.contains(w)) found.add('$path: $w');
        }
      }
    }
    expect(read, greaterThan(100), reason: 'run from messaging/, where lib/ is');
    expect(found, isEmpty);
    expect(File('lib/plugins/pack/review.dart').readAsStringSync(), allOf(contains(words[0]), contains(words[1]), contains(words[2])));
  });
}
