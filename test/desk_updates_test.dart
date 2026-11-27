import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/desktop/ui/launch_splash.dart';
import 'package:ghost_messaging/desktop/updates.dart';

/// The Mac app's own updates (lib/desktop/updates.dart), against a server standing in for gogho.st and a
/// stand-in for the Mac's half, which on a Mac is macos/Runner/UpdatesChannel.swift.
class _FakeMac implements UpdateHost {
  _FakeMac(this.here, {this.answer = 'ready'});
  final InstalledMac? here;
  String answer;
  final handed = <(String, String, int, int)>[];
  int restarts = 0;

  @override
  Future<InstalledMac?> installed() async => here;

  @override
  Future<String> install(String path, {required String sha256, required int bytes}) async {
    handed.add((path, sha256, bytes, File(path).lengthSync()));
    return answer;
  }

  @override
  Future<String> restart() async {
    restarts++;
    return 'restarting';
  }
}

void main() {
  final sha = 'ab' * 32;
  late HttpServer server;
  late Directory dir;
  late Uri feed;
  // What the server says for mac.json, and what it sends for the zip.
  Object? description;
  Uint8List zip = Uint8List(0);
  int? declared;
  var zipAsked = 0;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ghost-desk-updates');
    zipAsked = 0;
    declared = null;
    zip = Uint8List.fromList(List.generate(1200 * 1024, (i) => i % 251));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/mac.json') {
        if (description == null) {
          request.response.statusCode = 404;
        } else if (description is int) {
          request.response.statusCode = description! as int;
        } else {
          request.response.write(description is String ? description : jsonEncode(description));
        }
      } else if (request.uri.path == '/ghost-messaging-mac.zip') {
        zipAsked++;
        request.response.contentLength = -1;
        request.response.add(zip);
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    feed = Uri.parse('http://127.0.0.1:${server.port}/mac.json');
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Map<String, Object?> says({int build = 500, String version = '0.7.0', int? bytes, String url = 'ghost-messaging-mac.zip'}) =>
      {'version': version, 'versionCode': build, 'sha256': sha, 'bytes': bytes ?? declared ?? zip.length, 'url': url, 'build': '20261114020000'};

  InstalledMac here({int build = 400}) => InstalledMac(version: '0.6.2', build: build, dir: '${dir.path}/updates');

  Future<MacUpdates> looked(_FakeMac mac) async {
    final updates = MacUpdates(feed: feed, host: mac, every: const Duration(days: 1));
    addTearDown(updates.dispose);
    await updates.start();
    // start() looks without being waited for: this look waits for that one to end.
    for (var i = 0; i < 400 && (updates.phase == MacUpdatePhase.checking || updates.phase == MacUpdatePhase.downloading || updates.checked == null && updates.phase == MacUpdatePhase.idle); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return updates;
  }

  test('a release\'s description is read, and what is not one is refused', () {
    final at = Uri.parse('https://gogho.st/mac.json');
    final r = MacRelease.parse(jsonEncode({'version': '0.7.0', 'versionCode': 455123, 'sha256': sha.toUpperCase(), 'bytes': 31000000, 'url': 'ghost-messaging-mac.zip'}), at)!;
    expect(r.version, '0.7.0');
    expect(r.build, 455123);
    expect(r.sha256, sha);
    expect(r.bytes, 31000000);
    expect(r.url, Uri.parse('https://gogho.st/ghost-messaging-mac.zip'));
    Map<String, Object?> one([Map<String, Object?> change = const {}]) => {'version': '0.7.0', 'versionCode': 455123, 'sha256': sha, 'bytes': 31000000, 'url': 'ghost-messaging-mac.zip', ...change};
    expect(MacRelease.parse(jsonEncode(one()), at), isNotNull);
    expect(MacRelease.parse('not json', at), isNull);
    expect(MacRelease.parse('[]', at), isNull);
    expect(MacRelease.parse(jsonEncode(one({'versionCode': '455123'})), at), isNull, reason: 'a build that is not a number');
    expect(MacRelease.parse(jsonEncode(one({'versionCode': 0})), at), isNull);
    expect(MacRelease.parse(jsonEncode(one({'sha256': 'abc'})), at), isNull);
    expect(MacRelease.parse(jsonEncode(one({'bytes': 12})), at), isNull, reason: 'no app is twelve bytes');
    expect(MacRelease.parse(jsonEncode(one({'bytes': 900 << 20})), at), isNull);
    expect(MacRelease.parse(jsonEncode(one({'version': 'latest'})), at), isNull);
    // The zip is beside its description: another server's, or one spoken to another way, is not taken.
    expect(MacRelease.parse(jsonEncode(one({'url': 'https://elsewhere.example/app.zip'})), at), isNull);
    expect(MacRelease.parse(jsonEncode(one({'url': 'http://gogho.st/ghost-messaging-mac.zip'})), at), isNull);
    expect(MacRelease.parse(jsonEncode(one({'url': 'https://gogho.st/other/app.zip'})), at)!.url.path, '/other/app.zip');
  });

  test('a newer release is brought down whole and handed to the Mac, and Restart swaps it in', () async {
    description = says();
    final mac = _FakeMac(here());
    final updates = await looked(mac);
    expect(updates.phase, MacUpdatePhase.ready);
    expect(updates.release!.version, '0.7.0');
    expect(updates.progress, 1);
    expect(mac.handed, hasLength(1));
    final (path, sha256, bytes, onDisk) = mac.handed.single;
    expect(path, '${dir.path}/updates/ghost-messaging-mac-500.zip');
    expect(sha256, sha);
    expect(bytes, zip.length);
    expect(onDisk, zip.length);
    expect(File(path).readAsBytesSync(), zip);
    // One in place is not fetched again by the next look.
    await updates.check();
    expect(zipAsked, 1);
    await updates.restart();
    expect(mac.restarts, 1);
    expect(updates.phase, MacUpdatePhase.restarting);
  });

  test('the same version, an older one, or nothing published: nothing is fetched', () async {
    for (final d in <Object?>[says(build: 400), says(build: 399), null]) {
      description = d;
      final mac = _FakeMac(here());
      final updates = await looked(mac);
      expect(updates.phase, MacUpdatePhase.idle, reason: '$d');
      expect(updates.release, isNull);
      expect(updates.checked, isNotNull);
      expect(mac.handed, isEmpty);
    }
    expect(zipAsked, 0);
  });

  test('a download that is not the size the release says is not handed over', () async {
    declared = zip.length + 4096;
    description = says();
    var mac = _FakeMac(here());
    var updates = await looked(mac);
    expect(updates.phase, MacUpdatePhase.failed);
    expect(updates.problem, contains('before it was whole'));
    expect(mac.handed, isEmpty);
    expect(Directory('${dir.path}/updates').listSync(), isEmpty, reason: 'the part that came is not kept');
    declared = zip.length - 4096;
    description = says();
    mac = _FakeMac(here());
    updates = await looked(mac);
    expect(updates.phase, MacUpdatePhase.failed);
    expect(updates.problem, contains('larger than the release says'));
    expect(mac.handed, isEmpty);
  });

  test('what the Mac answers is what is said: refused, or a copy that cannot replace itself', () async {
    description = says();
    var mac = _FakeMac(here(), answer: 'the download is not signed by Uplink’s developer');
    var updates = await looked(mac);
    expect(updates.phase, MacUpdatePhase.failed);
    expect(updates.problem, contains('not signed by'));
    // Tried again at the next look.
    mac.answer = 'ready';
    await updates.check();
    expect(updates.phase, MacUpdatePhase.ready);
    mac = _FakeMac(here(), answer: 'manual: Uplink can’t write to /Applications.');
    updates = await looked(mac);
    expect(updates.phase, MacUpdatePhase.manual);
    expect(updates.problem, 'Uplink can’t write to /Applications.');
    final asked = zipAsked;
    await updates.check();
    expect(zipAsked, asked, reason: 'what this copy cannot take is not fetched again each time');
  });

  test('a server in trouble, or a description that is not one, is said and tried again', () async {
    description = 503;
    final mac = _FakeMac(here());
    final updates = await looked(mac);
    expect(updates.phase, MacUpdatePhase.failed);
    expect(updates.problem, contains('503'));
    description = '{"version": 7}';
    await updates.check();
    expect(updates.phase, MacUpdatePhase.failed);
    expect(updates.problem, contains('could not be read'));
    description = says();
    await updates.check();
    expect(updates.phase, MacUpdatePhase.ready);
  });

  test('where there is no Mac half nothing is looked for, and the environment says where to look', () async {
    description = says();
    final mac = _FakeMac(null);
    final updates = MacUpdates(feed: feed, host: mac);
    addTearDown(updates.dispose);
    await updates.start();
    await updates.check();
    expect(updates.installed, isNull);
    expect(updates.phase, MacUpdatePhase.idle);
    expect(zipAsked, 0);
    expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATES': 'off'}), isNull);
    expect(MacUpdates.fromEnvironment(const {})!.feed, Uri.parse('https://gogho.st/mac.json'));
    expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATES': 'http://127.0.0.1:8123/mac.json'})!.feed, Uri.parse('http://127.0.0.1:8123/mac.json'));
    expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATES': 'nonsense'})!.feed, Uri.parse('https://gogho.st/mac.json'));
    expect(MacUpdates.fromEnvironment(const {})!.restartWhenReady, isFalse);
    expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATE_RESTART': 'now'})!.restartWhenReady, isTrue);
  });

  test('asked to, it restarts into an update as soon as one is in place', () async {
    description = says();
    final mac = _FakeMac(here());
    final updates = MacUpdates(feed: feed, host: mac, every: const Duration(days: 1), restartWhenReady: true);
    addTearDown(updates.dispose);
    await updates.start();
    for (var i = 0; i < 400 && mac.restarts == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(mac.restarts, 1);
    expect(updates.phase, MacUpdatePhase.restarting);
  });

  group('Windows (WindowsUpdateHost)', () {
    const local = r'C:\Users\riley\AppData\Local';
    const exe = r'C:\Users\riley\AppData\Local\Programs\Ghost Messaging\ghost_messaging.exe';

    test('only a copy the installer put in place, made with a build number, looks for updates', () async {
      expect(await WindowsUpdateHost(env: const {'LOCALAPPDATA': local}, exe: exe, build: 36, version: '0.7.24').installed(), isNotNull);
      expect(await WindowsUpdateHost(env: const {'LOCALAPPDATA': local}, exe: exe, build: 0, version: '0.7.24').installed(), isNull);
      expect(await WindowsUpdateHost(env: const {'LOCALAPPDATA': local}, exe: r'D:\src\build\ghost_messaging.exe', build: 36).installed(), isNull);
      expect(await WindowsUpdateHost(env: const {}, exe: exe, build: 36).installed(), isNull);
      final here = await WindowsUpdateHost(env: const {'LOCALAPPDATA': local}, exe: exe.toUpperCase(), build: 36, version: '0.7.24').installed();
      expect(here!.build, 36);
      expect(here.dir, r'C:\Users\riley\AppData\Local\Ghost Messaging\updates');
    });

    test('the installer is held to its size and SHA-256, then run silently and the app quits', () async {
      final dir = Directory.systemTemp.createTempSync('win-update');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bytes = Uint8List.fromList(List.generate(4096, (i) => i % 13));
      final file = File('${dir.path}/setup.exe')..writeAsBytesSync(bytes);
      // SHA-256 worked out apart from the app's own code.
      final r = Process.runSync('shasum', ['-a', '256', file.path]);
      final sha = (r.stdout as String).split(' ').first;
      final launched = <String>[];
      var quit = 0;
      final host = WindowsUpdateHost(env: const {'LOCALAPPDATA': local}, exe: exe, build: 36, launch: (p) async => launched.add(p), quit: () => quit++);

      expect(await host.restart(), isNot('restarting'), reason: 'nothing to run yet');
      expect(await host.install(file.path, sha256: sha, bytes: bytes.length + 1), contains('size'));
      expect(await host.install(file.path, sha256: 'a' * 64, bytes: bytes.length), contains('not the one'));
      expect(file.existsSync(), isFalse, reason: 'a changed installer is not kept');

      file.writeAsBytesSync(bytes);
      expect(await host.install(file.path, sha256: sha.toUpperCase(), bytes: bytes.length), 'ready');
      expect(launched, isEmpty);
      expect(await host.restart(), 'restarting');
      expect(launched, [file.path]);
      expect(quit, 1);
    });

    test('fromEnvironment reads windows.json on Windows, and GHOST_DESK_UPDATES still names another', () {
      expect(MacUpdates.fromEnvironment(const {}, windows: true)!.feed.toString(), windowsFeed);
      expect(MacUpdates.fromEnvironment(const {})!.feed.toString(), macFeed);
      expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATES': 'http://127.0.0.1:9/w.json'}, windows: true)!.feed.toString(), 'http://127.0.0.1:9/w.json');
      expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATES': 'off'}, windows: true), isNull);
    });
  });

  // The launch splash (lib/desktop/ui/launch_splash.dart; Matt, 2026-11-20: "a checking for updates splash window that
  // shows before the app launches ... similar to how discord does on launch").
  group('at launch', () {
    test('a newer version is brought down and restarted into from the splash, which says so', () async {
      description = says();
      final mac = _FakeMac(here());
      final updates = MacUpdates(feed: feed, host: mac, every: const Duration(days: 1));
      addTearDown(updates.dispose);
      final step = ValueNotifier<SplashStep>((words: '', progress: null));
      final said = <String>{};
      step.addListener(() => said.add(step.value.words));
      await checkAtLaunch(updates, step, restartWait: Duration.zero);
      expect(said, containsAll(['Checking for updates', 'Downloading 0.7.0', 'Restarting to update']));
      expect(mac.handed, hasLength(1));
      expect(mac.restarts, 1);
    });

    test('with nothing newer the app opens at once, nothing restarted', () async {
      description = says(build: 400);
      final mac = _FakeMac(here());
      final updates = MacUpdates(feed: feed, host: mac, every: const Duration(days: 1));
      addTearDown(updates.dispose);
      final step = ValueNotifier<SplashStep>((words: '', progress: null));
      final at = DateTime.now();
      await checkAtLaunch(updates, step);
      expect(DateTime.now().difference(at), lessThan(const Duration(seconds: 5)));
      expect(updates.phase, MacUpdatePhase.idle);
      expect(mac.restarts, 0);
      expect(step.value.words, 'Checking for updates');
    });

    test('a site that does not answer in time is not waited on: the app opens, the look goes on behind it', () async {
      // Accepts and says nothing.
      final quiet = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      quiet.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await quiet.close();
      });
      final mac = _FakeMac(here());
      final updates = MacUpdates(feed: Uri.parse('http://127.0.0.1:${quiet.port}/mac.json'), host: mac, every: const Duration(days: 1));
      addTearDown(updates.dispose);
      final step = ValueNotifier<SplashStep>((words: '', progress: null));
      final at = DateTime.now();
      await checkAtLaunch(updates, step, lookFor: const Duration(milliseconds: 600));
      expect(DateTime.now().difference(at), lessThan(const Duration(seconds: 3)));
      expect(updates.phase, MacUpdatePhase.checking, reason: 'still looking, behind the app');
      expect(mac.restarts, 0);
    });
  });
}
