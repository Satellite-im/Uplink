import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/files_model.dart' show SpaceFile;
import 'package:ghost_messaging/plugins/list.dart' show ListPlugins;
import 'package:ghost_messaging/plugins/plugin.dart' show MessageFacts;
import 'package:ghost_messaging/plugins/spam.dart' show isNetworkChat;
import 'package:ghost_messaging/standalone/overlay.dart' show UsernameOverlay;

/// What the source keeps for every build, read before a release builds anything (tool/lib/guards.mjs, run by
/// tool/release.mjs and tool/release-mac.mjs): each half of a file split for the browser reached only through the
/// file that chooses it, the right way round; dart:ffi named only by the halves a browser's build leaves out; and no
/// shift by 32 bits or more, which keeps 32 bits in a browser. With test/platform_info_test.dart (no raw `Platform.`)
/// and test/aside_test.dart (no `Isolate.run`). Nothing here reads the web page, its policy or the extension's pins:
/// those are the web build's own (test/web_build_test.dart, run by tool/build-web.mjs), so a phone's or a computer's
/// release never waits on them.
void main() {
  // A file that can't be compiled for a browser, or would be wrong in one, has a half for each (lib/platform_info.dart,
  // lib/aside.dart, lib/net/fast_gcm.dart, …), chosen by a file that exports one or the other, or imports one or the
  // other under a name (lib/net/hub_link.dart, lib/web/browser.dart). Naming a half from anywhere else takes the
  // choice away: fast_gcm_64.dart in a browser seals bytes nothing else can open, and td_json_io.dart stops the build.
  test('a half is reached only through the file that chooses it, and a browser gets the one for a browser', () {
    final chooses = RegExp(r"^(?:export|import)\s+'([^']+)'\s+if\s+\(dart\.library\.js_interop\)\s+'([^']+)'(?:\s+as\s+\w+)?(?:\s+(?:show|hide)\s+[\w\s,]+)?;", multiLine: true);
    final conditional = RegExp(r"^(?:export|import)\s+'[^']+'\s+if\s*\(([^)]*)\)", multiLine: true);
    final directive = RegExp(r'''^\s*(?:import|export)\s+'([^']+)'(?:\s+if\s+\([^)]*\)\s+'([^']+)')?''', multiLine: true);
    final files = [for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) if (f.path.endsWith('.dart')) f.path.replaceAll('\\', '/')];
    expect(files.length, greaterThan(300));
    String resolve(String from, String uri) => uri.startsWith('package:ghost_messaging/') ? 'lib/${uri.substring('package:ghost_messaging/'.length)}' : File(from).parent.uri.resolve(uri).path.replaceFirst(RegExp(r'^.*?(?=lib/)'), '');

    // Each half, and the file that chooses it.
    final halves = <String, String>{};
    final choosers = <String>{};
    for (final path in files) {
      final text = File(path).readAsStringSync();
      // Every choice in lib/ is this one, written this way: for a browser or not. Another condition, or another
      // spelling, would be a choice this test does not see.
      for (final m in conditional.allMatches(text)) {
        expect(m.group(1), 'dart.library.js_interop', reason: '$path chooses by something else');
      }
      expect(conditional.allMatches(text).length, chooses.allMatches(text).length, reason: '$path has a conditional import or export this test does not read');
      for (final m in chooses.allMatches(text)) {
        choosers.add(path);
        final other = resolve(path, m.group(1)!), browsers = resolve(path, m.group(2)!);
        for (final at in [other, browsers]) {
          expect(File(at).existsSync(), isTrue, reason: '$path chooses $at, which is not there');
          expect(halves.containsKey(at), isFalse, reason: '$at is chosen twice');
          halves[at] = path;
        }
        // Which way round: the half after `if (dart.library.js_interop)` is the browser's, and is named so. Turned
        // round, a pair that names no dart:ffi or JavaScript of its own compiles everywhere and is wrong everywhere.
        expect(browsers, endsWith('_web.dart'), reason: '$path: the half a browser gets is the one named _web.dart');
        expect(other, isNot(endsWith('_web.dart')), reason: '$path: the half for a phone or a computer is not the one named _web.dart');
      }
    }
    expect(choosers, {
      'lib/platform_info.dart',
      'lib/aside.dart',
      'lib/net/fast_gcm.dart',
      'lib/net/hub_link.dart',
      'lib/account/gzip.dart',
      'lib/account/argon2_browser.dart',
      'lib/inbox/td_json.dart',
      'lib/files/apple_sha.dart',
      'lib/voice/mpv_property.dart',
      'lib/voice/call_sound.dart',
      'lib/web/browser.dart',
      'lib/web/http.dart',
      'lib/net/p2p/node_ffi.dart',
      'lib/net/kept_files.dart',
      // A Files space in a browser (docs/OPEN_NETWORK.md, part 6).
      'lib/net/file_seal_async.dart',
      'lib/files/files_http.dart',
      'lib/files/file_sink.dart',
      'lib/files/browser_files.dart',
      'lib/relay_host/relay_host.dart',
      // What the app is spending, read from the system for the Performance plugin; nothing in a browser.
      'lib/perf/cpu_source.dart',
      // The local network route's sockets (GMFB-24); a browser has none, and no such route.
      'lib/net/lan/lan_ground.dart',
    });
    expect(halves.keys, containsAll(['lib/platform_info_io.dart', 'lib/platform_info_web.dart', 'lib/aside_io.dart', 'lib/aside_web.dart', 'lib/net/fast_gcm_64.dart', 'lib/net/fast_gcm_web.dart', 'lib/account/gzip_io.dart', 'lib/account/gzip_web.dart', 'lib/inbox/td_json_io.dart', 'lib/inbox/td_json_web.dart', 'lib/files/apple_sha_io.dart', 'lib/files/apple_sha_web.dart', 'lib/net/hub_link_io.dart', 'lib/net/hub_link_web.dart', 'lib/voice/mpv_property_io.dart', 'lib/voice/mpv_property_web.dart', 'lib/voice/call_sound_none.dart', 'lib/voice/call_sound_web.dart', 'lib/account/argon2_browser_none.dart', 'lib/account/argon2_browser_web.dart', 'lib/web/browser_none.dart', 'lib/web/browser_web.dart', 'lib/web/http_none.dart', 'lib/web/http_web.dart', 'lib/net/p2p/node_ffi_io.dart', 'lib/net/p2p/node_ffi_web.dart', 'lib/net/file_seal_async_io.dart', 'lib/net/file_seal_async_web.dart', 'lib/files/files_http_io.dart', 'lib/files/files_http_web.dart', 'lib/files/file_sink_none.dart', 'lib/files/file_sink_web.dart', 'lib/files/browser_files_none.dart', 'lib/files/browser_files_web.dart', 'lib/relay_host/relay_host_io.dart', 'lib/relay_host/relay_host_web.dart']));

    final found = <String>[];
    for (final path in files) {
      for (final m in directive.allMatches(File(path).readAsStringSync())) {
        for (final uri in [m.group(1)!, ?m.group(2)]) {
          if (uri.startsWith('dart:') || (uri.startsWith('package:') && !uri.startsWith('package:ghost_messaging/'))) continue;
          final at = resolve(path, uri);
          final chooser = halves[at];
          if (chooser != null && chooser != path) found.add('$path names $at: name $chooser instead');
        }
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));

    // And JavaScript is spoken to only from a browser's half: anywhere else it stops every other build.
    final speaks = RegExp(r"^\s*import\s+'(?:dart:js_interop|dart:js_interop_unsafe|dart:html|dart:js|package:web/)", multiLine: true);
    final speaking = [for (final path in files) if (speaks.hasMatch(File(path).readAsStringSync())) path];
    expect(speaking, isNotEmpty);
    for (final path in speaking) {
      expect(halves[path], isNotNull, reason: '$path speaks to JavaScript and is no half of a pair');
      expect(path, endsWith('_web.dart'), reason: path);
    }
  });

  test('dart:ffi is named only by the halves a browser\'s build leaves out', () {
    // Each is the `_io` half of a pair chosen by a conditional export; its `_web` half is what a browser gets.
    const allowed = {
      'lib/inbox/td_json_io.dart': 'TDLib (lib/inbox/td_json.dart)',
      'lib/files/apple_sha_io.dart': 'CommonCrypto\'s SHA-256 (lib/files/apple_sha.dart)',
      'lib/net/p2p/node_ffi_io.dart': 'the direct network\'s core (lib/net/p2p/node_ffi.dart)',
      'lib/perf/cpu_source_io.dart': 'the system\'s count of the processor time the app has used, for the Performance plugin (lib/perf/cpu_source.dart)',
    };
    final named = RegExp(r'''^\s*(?:import|export)\s+['"](?:dart:ffi|package:ffi/)''');
    final roots = [Directory('lib'), for (final p in Directory('packages').listSync().whereType<Directory>()) Directory('${p.path}/lib')];
    final found = <String>[];
    var files = 0;
    for (final root in roots) {
      for (final file in root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final path = file.path.replaceAll('\\', '/');
        files++;
        final lines = file.readAsLinesSync();
        final here = [for (var i = 0; i < lines.length; i++) if (named.hasMatch(lines[i])) '$path:${i + 1}: ${lines[i].trim()}'];
        if (allowed.containsKey(path)) {
          expect(here, isNotEmpty, reason: '$path is allowed dart:ffi and no longer names it: take it off the list.');
          // And the pair is there: the file that chooses, and the half without dart:ffi.
          final pair = path.replaceFirst('_io.dart', '.dart'), web = path.replaceFirst('_io.dart', '_web.dart');
          expect(File(pair).readAsStringSync(), contains("export '${path.split('/').last}' if (dart.library.js_interop) '${web.split('/').last}';"));
          expect(File(web).existsSync(), isTrue);
        } else {
          found.addAll(here);
        }
      }
    }
    expect(files, greaterThan(300));
    expect(found, isEmpty, reason: 'A build for a browser stops at dart:ffi wherever it is imported from: split the file as lib/files/apple_sha.dart is.\n${found.join('\n')}');
    // A pair split for the same build that names no dart:ffi of its own: mpv's properties (lib/voice/mpv_property.dart),
    // whose `_io` half reaches the library through media_kit's. Nothing above reads which way round it chooses, and
    // turned round it compiles everywhere and no player plays; so it is read here, as written.
    expect(File('lib/voice/mpv_property.dart').readAsStringSync(), contains("export 'mpv_property_io.dart' if (dart.library.js_interop) 'mpv_property_web.dart';"));
    expect(File('lib/voice/mpv_property_io.dart').existsSync(), isTrue);
    expect(File('lib/voice/mpv_property_web.dart').existsSync(), isTrue);
  });

  // The relay itself (relay/: dart:io, and dart:ffi for its key file's mode) is in the app for the relay it can host
  // (lib/relay_host; docs/OPEN_NETWORK.md, section 5), and a browser's build would stop at it wherever it is named: so it
  // is named by the half of lib/relay_host/relay_host.dart a browser's build leaves out, and nothing else.
  test('the relay package is named only by the half a browser\'s build leaves out', () {
    final named = RegExp(r'''^\s*(?:import|export)\s+['"]package:ghost_relay/''');
    final found = <String>{};
    var files = 0;
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      files++;
      if (file.readAsLinesSync().any(named.hasMatch)) found.add(file.path.replaceAll('\\', '/'));
    }
    expect(files, greaterThan(300));
    expect(found, {'lib/relay_host/relay_host_io.dart'}, reason: 'name lib/relay_host/relay_host.dart instead, which chooses the half');
  });

  // In a browser an integer is JavaScript's number, and `<<`, `>>` and `>>>` keep 32 bits of it: `1 << 40` is 0 there,
  // at run time and as a constant alike, with nothing to say so. (So a file's most size was 0, and every file over it.)
  // A number past 32 bits is written out (0x10000000000), which a browser holds exactly up to 2^53.
  test('nothing in lib/ shifts by 32 bits or more', () {
    // Where it may, and why.
    const allowed = {
      'lib/net/fast_gcm_64.dart': 'the half of lib/net/fast_gcm.dart for 64-bit integers; a browser gets fast_gcm_web.dart',
    };
    final shift = RegExp(r'(?:<<|>>>?)=?\s*\(?\s*(?:3[2-9]|[4-9][0-9]|[1-9][0-9]{2,})\b');
    final found = <String>[];
    var files = 0;
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final path = file.path.replaceAll('\\', '/');
      files++;
      final lines = file.readAsLinesSync();
      final here = [
        for (var i = 0; i < lines.length; i++)
          if (!lines[i].trimLeft().startsWith('//') && shift.hasMatch(lines[i])) '$path:${i + 1}: ${lines[i].trim().length > 120 ? '${lines[i].trim().substring(0, 120)}…' : lines[i].trim()}',
      ];
      if (allowed.containsKey(path)) {
        expect(here, isNotEmpty, reason: '$path is allowed such shifts and has none: take it off the list.');
      } else {
        found.addAll(here);
      }
    }
    expect(files, greaterThan(300));
    expect(found, isEmpty, reason: 'A shift keeps 32 bits in a browser: write the number out, or split the file as lib/net/fast_gcm.dart is.\n${found.join('\n')}');
    // And the four that were `1 << 40` are still 2^40 here.
    expect(SpaceFile.maxSize, 1099511627776);
    expect(UsernameOverlay.base, 1099511627776);
    expect(ListPlugins.chatThread('a'), lessThanOrEqualTo(-1099511627776));
    expect(ListPlugins.chatThread('a'), greaterThan(-1099511627776 - 0x40000000));
    expect(isNetworkChat(MessageFacts(thread: ListPlugins.chatThread('a'), senders: const [], text: '', contact: false)), isTrue);
    expect(isNetworkChat(const MessageFacts(thread: 7, senders: [], text: '', contact: false)), isFalse);
  });
}
