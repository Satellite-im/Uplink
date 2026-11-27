import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/platform_info.dart';
import 'package:ghost_messaging/platform_info_web.dart' as web;

/// What kind of device this is (lib/platform_info.dart; Matt: "the full web client"): `dart:io`'s `Platform`'s own
/// answers wherever there is one, the browser's half where there isn't, and nothing in lib/ asking `Platform` itself,
/// since in a browser the first that did would stop the app.
void main() {
  test('where dart:io is, every answer is Platform\'s own', () {
    expect(PlatformInfo.isWeb, isFalse);
    expect(PlatformInfo.isAndroid, Platform.isAndroid);
    expect(PlatformInfo.isIOS, Platform.isIOS);
    expect(PlatformInfo.isMacOS, Platform.isMacOS);
    expect(PlatformInfo.isWindows, Platform.isWindows);
    expect(PlatformInfo.isLinux, Platform.isLinux);
    expect(PlatformInfo.operatingSystem, Platform.operatingSystem);
    expect(PlatformInfo.operatingSystemVersion, Platform.operatingSystemVersion);
    expect(PlatformInfo.localHostname, Platform.localHostname);
    expect(PlatformInfo.numberOfProcessors, Platform.numberOfProcessors);
    expect(PlatformInfo.pathSeparator, Platform.pathSeparator);
    expect(PlatformInfo.environment, Platform.environment);
    expect(PlatformInfo.resolvedExecutable, Platform.resolvedExecutable);
    // A test is told from the app by this, all over lib/: it must read as it always has.
    expect(PlatformInfo.environment.containsKey('FLUTTER_TEST'), isTrue);
  });

  test('in a browser: none of the five, and an answer to everything else without dart:io', () {
    expect(web.PlatformInfo.isWeb, isTrue);
    expect([web.PlatformInfo.isAndroid, web.PlatformInfo.isIOS, web.PlatformInfo.isMacOS, web.PlatformInfo.isWindows, web.PlatformInfo.isLinux], everyElement(isFalse));
    expect(web.PlatformInfo.operatingSystem, 'web');
    expect(web.PlatformInfo.operatingSystemVersion, '');
    expect(web.PlatformInfo.localHostname, 'browser');
    expect(web.PlatformInfo.numberOfProcessors, 1);
    expect(web.PlatformInfo.pathSeparator, '/');
    expect(web.PlatformInfo.environment, isEmpty);
    expect(web.PlatformInfo.environment.containsKey('FLUTTER_TEST'), isFalse);
    expect(() => web.PlatformInfo.environment['HOME'] = '/', throwsUnsupportedError);
    expect(web.PlatformInfo.resolvedExecutable, '');
  });

  // The app is built with one half or the other, so a question only one of them answers would compile on a phone and
  // stop the browser's build (or the other way about) with no test the wiser.
  test('the two halves answer the same questions', () {
    List<String> asked(String path) {
      final found = RegExp(r'^\s*static\s+(?:const\s+)?[\w<>, ?]+?\s+(?:get\s+)?(\w+)\s*(?:=>|=)', multiLine: true).allMatches(File(path).readAsStringSync());
      return [for (final m in found) m.group(1)!]..sort();
    }

    final io = asked('lib/platform_info_io.dart');
    expect(io, containsAll(['isWeb', 'isAndroid', 'isIOS', 'isMacOS', 'isWindows', 'isLinux', 'pathSeparator', 'environment']));
    expect(asked('lib/platform_info_web.dart'), io);
  });

  test('nothing in lib/ or packages/ asks dart:io\'s Platform itself', () {
    // Where `Platform` may be asked, and why it can't go through lib/platform_info.dart. Keep it this short.
    const allowed = {
      'lib/platform_info_io.dart': 'the half of lib/platform_info.dart that hands on Platform\'s answers',
    };
    // `Platform.` as a name of its own, with or without a prefix (`io.Platform.`): not FilePlatform. or
    // TargetPlatform., which are other things.
    final use = RegExp(r'(?<![A-Za-z0-9_$])Platform\s*\.');
    // And the name let in by an import of dart:io that lists what it takes.
    final shown = RegExp(r'''import\s+['"]dart:io['"][^;]*\bshow\b[^;]*\bPlatform\b''');
    final roots = [Directory('lib'), for (final p in Directory('packages').listSync().whereType<Directory>()) Directory('${p.path}/lib')];
    final found = <String>[];
    var files = 0;
    for (final root in roots) {
      for (final file in root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final path = file.path.replaceAll('\\', '/');
        if (allowed.containsKey(path)) continue;
        files++;
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          // What a comment says of it is no use of it.
          if (line.startsWith('//')) continue;
          if (use.hasMatch(line) || shown.hasMatch(line)) found.add('$path:${i + 1}: ${line.length > 120 ? '${line.substring(0, 120)}…' : line}');
        }
      }
    }
    // The whole of lib/ was read, not an empty folder from the wrong place to run a test in.
    expect(files, greaterThan(300));
    expect(File('lib/platform_info_io.dart').readAsStringSync(), contains('Platform.isAndroid'));
    expect(found, isEmpty, reason: 'dart:io\'s Platform throws in a browser whatever it is asked: ask PlatformInfo (lib/platform_info.dart) instead.\n${found.join('\n')}');
  });
}
