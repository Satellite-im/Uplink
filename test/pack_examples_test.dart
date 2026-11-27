import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The docs' example plugins (examples/plugins, Matt, 2026-11-20: "Please include documents on how users can develop
/// plugins") are the packs the tests hold to the format, byte for byte (test/fixtures/packs): what a reader copies is
/// what is checked.
void main() {
  final examples = Directory('examples/plugins');
  test('examples/plugins/*.ghostplugin equal test/fixtures/packs/*.ghostplugin byte for byte', () {
    final fixtures = Directory('test/fixtures/packs').listSync().whereType<File>().where((f) => f.path.endsWith('.ghostplugin')).toList();
    expect(fixtures.map((f) => f.uri.pathSegments.last).toSet(), {'bills.ghostplugin', 'parcels.ghostplugin'});
    for (final f in fixtures) {
      final name = f.uri.pathSegments.last;
      final example = File('${examples.path}/$name');
      expect(example.existsSync(), isTrue, reason: '$name is in examples/plugins');
      expect(example.readAsBytesSync(), f.readAsBytesSync(), reason: name);
    }
  }, skip: examples.existsSync() ? false : 'examples/plugins is the docs\' (section E.6), and comes when they are merged');
}
