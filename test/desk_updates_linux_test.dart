import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/ui/launch_splash.dart';
import 'package:ghost_messaging/desktop/updates.dart';

/// Linux's own updates (GMFB-32, lib/desktop/updates.dart LinuxUpdateHost): linux.json read for the file this copy
/// takes, the folder's archive unpacked beside it and swapped in, and the .deb's command given.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ghost-linux-updates'));
  tearDown(() => dir.deleteSync(recursive: true));

  String sha(File f) => (Process.runSync('shasum', ['-a', '256', f.path]).stdout as String).split(' ').first;

  // As tool/release-linux.mjs writes it (the live one, 2026-11-22, with its sizes).
  Map<String, Object?> linuxJson({int build = 141, String version = '0.12.13', int debBytes = 39082738, int tarBytes = 44331219}) => {
        'version': version,
        'versionCode': build,
        'url': 'ghost-messaging-linux.deb',
        'bytes': debBytes,
        'sha256': 'd7' * 32,
        'tar': {'url': 'ghost-messaging-linux-x64.tar.gz', 'bytes': tarBytes, 'sha256': '2f' * 32},
        'build': '2026-11-20T18:51:06.718Z',
        'run': 44795721248,
      };

  test('linux.json is read for the .deb at its top, or the folder\'s archive under tar', () {
    final feed = Uri.parse('https://gogho.st/linux.json');
    final deb = MacRelease.parse(jsonEncode(linuxJson()), feed)!;
    expect(deb.url.toString(), 'https://gogho.st/ghost-messaging-linux.deb');
    expect(deb.bytes, 39082738);
    expect(deb.build, 141);
    final tar = MacRelease.parse(jsonEncode(linuxJson()), feed, part: 'tar')!;
    expect(tar.url.toString(), 'https://gogho.st/ghost-messaging-linux-x64.tar.gz');
    expect(tar.bytes, 44331219);
    expect(tar.sha256, '2f' * 32);
    expect(tar.version, '0.12.13');
    // No such part, or one elsewhere: not a description.
    expect(MacRelease.parse(jsonEncode(linuxJson()), feed, part: 'appimage'), isNull);
    final away = linuxJson()..['tar'] = {'url': 'https://elsewhere.example/x.tar.gz', 'bytes': 44331219, 'sha256': '2f' * 32};
    expect(MacRelease.parse(jsonEncode(away), feed, part: 'tar'), isNull);
  });

  test('how it was installed decides what it takes: the .deb from /opt, a folder of the person\'s own', () async {
    final deb = LinuxUpdateHost(env: const {'HOME': '/home/riley'}, exe: '/opt/ghost-messaging/ghost-messaging', build: 141, version: '0.12.13');
    expect(deb.kind, LinuxInstall.deb);
    expect(deb.part, isNull);
    final here = (await deb.installed())!;
    expect(here.build, 141);
    expect(here.dir, '/home/riley/.cache/ghost-messaging/updates');

    Directory('${dir.path}/ghost-messaging').createSync();
    final folder = LinuxUpdateHost(env: {'XDG_CACHE_HOME': '${dir.path}/cache'}, exe: '${dir.path}/ghost-messaging/ghost-messaging', build: 141);
    expect(folder.kind, LinuxInstall.folder);
    expect(folder.part, 'tar');
    expect((await folder.installed())!.dir, '${dir.path}/cache/ghost-messaging/updates');

    // A build with no build number (one run from flutter's build folder) never looks.
    expect(await LinuxUpdateHost(exe: '/opt/ghost-messaging/ghost-messaging', build: 0).installed(), isNull);
  });

  test('fromEnvironment reads linux.json on Linux, for the file this copy takes', () {
    final deb = LinuxUpdateHost(exe: '/opt/ghost-messaging/ghost-messaging', build: 141);
    final u = MacUpdates.fromEnvironment(const {}, linux: true, linuxHost: deb)!;
    expect(u.feed.toString(), linuxFeed);
    expect(u.part, isNull);
    final own = LinuxUpdateHost(exe: '/x/ghost-messaging/ghost-messaging', build: 141, install: LinuxInstall.folder);
    expect(MacUpdates.fromEnvironment(const {}, linux: true, linuxHost: own)!.part, 'tar');
    expect(MacUpdates.fromEnvironment(const {'GHOST_DESK_UPDATES': 'off'}, linux: true, linuxHost: own), isNull);
  });

  test('a folder: the archive is checked, unpacked beside it, and Restart swaps it in and starts the new one', () async {
    // The app as installed, and an archive of a newer one as the workflow makes it.
    final app = Directory('${dir.path}/apps/ghost-messaging')..createSync(recursive: true);
    File('${app.path}/ghost-messaging').writeAsStringSync('old');
    final made = Directory('${dir.path}/made/ghost-messaging')..createSync(recursive: true);
    File('${made.path}/ghost-messaging').writeAsStringSync('new');
    final archive = File('${dir.path}/update.tar.gz');
    expect(Process.runSync('tar', ['-czf', archive.path, '-C', '${dir.path}/made', 'ghost-messaging']).exitCode, 0);
    final launched = <String>[];
    var quits = 0;
    final host = LinuxUpdateHost(exe: '${app.path}/ghost-messaging', build: 140, launch: (p) async => launched.add(p), quit: () => quits++);
    expect(host.kind, LinuxInstall.folder);

    expect(await host.restart(), isNot('restarting'), reason: 'nothing in place yet');
    expect(await host.install(archive.path, sha256: sha(archive), bytes: archive.lengthSync() + 1), contains('size'));
    expect(await host.install(archive.path, sha256: 'a' * 64, bytes: archive.lengthSync()), contains('not the one'));
    expect(archive.existsSync(), isFalse, reason: 'a changed download is not kept');

    expect(Process.runSync('tar', ['-czf', archive.path, '-C', '${dir.path}/made', 'ghost-messaging']).exitCode, 0);
    expect(await host.install(archive.path, sha256: sha(archive).toUpperCase(), bytes: archive.lengthSync()), 'ready');
    expect(File('${app.path}/ghost-messaging').readAsStringSync(), 'old', reason: 'nothing swapped before Restart');
    expect(launched, isEmpty);

    expect(await host.restart(), 'restarting');
    expect(File('${app.path}/ghost-messaging').readAsStringSync(), 'new');
    expect(File('${app.path}.old/ghost-messaging').readAsStringSync(), 'old');
    expect(Directory('${dir.path}/apps/.ghost-messaging-update').existsSync(), isFalse);
    expect(launched, ['${app.path}/ghost-messaging']);
    expect(quits, 1);

    // The next start, from the new folder, clears the one moved aside.
    await LinuxUpdateHost(exe: '${app.path}/ghost-messaging', build: 141).installed();
    expect(Directory('${app.path}.old').existsSync(), isFalse);
  });

  test('an archive that does not hold the app is refused, and nothing is swapped', () async {
    final app = Directory('${dir.path}/apps/ghost-messaging')..createSync(recursive: true);
    File('${app.path}/ghost-messaging').writeAsStringSync('old');
    Directory('${dir.path}/made/other').createSync(recursive: true);
    File('${dir.path}/made/other/x').writeAsStringSync('x');
    final archive = File('${dir.path}/update.tar.gz');
    Process.runSync('tar', ['-czf', archive.path, '-C', '${dir.path}/made', 'other']);
    final host = LinuxUpdateHost(exe: '${app.path}/ghost-messaging', build: 140, launch: (_) async {}, quit: () {});
    expect(await host.install(archive.path, sha256: sha(archive), bytes: archive.lengthSync()), contains('does not hold'));
    expect(await host.restart(), isNot('restarting'));
    expect(File('${app.path}/ghost-messaging').readAsStringSync(), 'old');
  });

  test('the .deb: brought down, checked, and the command that installs it given, through the updater', () async {
    final deb = List<int>.generate(1100 * 1024, (i) => i % 241);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final file = File('${dir.path}/probe.deb')..writeAsBytesSync(deb);
    var said = linuxJson(build: 141, debBytes: deb.length)..['sha256'] = sha(file);
    server.listen((r) async {
      if (r.uri.path == '/linux.json') {
        r.response.write(jsonEncode(said));
      } else if (r.uri.path == '/ghost-messaging-linux.deb') {
        r.response.add(deb);
      } else {
        r.response.statusCode = 404;
      }
      await r.response.close();
    });
    final feed = Uri.parse('http://127.0.0.1:${server.port}/linux.json');
    final host = LinuxUpdateHost(env: {'XDG_CACHE_HOME': '${dir.path}/my cache'}, exe: '/opt/ghost-messaging/ghost-messaging', build: 141, version: '0.12.13');

    // The same build: nothing fetched.
    var u = MacUpdates(feed: feed, host: host, part: host.part, every: const Duration(days: 1));
    await u.start();
    await pumpUntil(() => u.phase != MacUpdatePhase.checking);
    expect(u.phase, MacUpdatePhase.idle);
    expect(u.installCommand, isNull);
    u.dispose();

    // A newer one.
    said = linuxJson(build: 142, debBytes: deb.length)..['sha256'] = sha(file);
    u = MacUpdates(feed: feed, host: host, part: host.part, every: const Duration(days: 1));
    addTearDown(u.dispose);
    await u.startChecking();
    expect(u.phase, MacUpdatePhase.manual);
    final path = '${dir.path}/my cache/ghost-messaging/updates/ghost-messaging-linux-142.deb';
    expect(File(path).lengthSync(), deb.length);
    expect(u.installCommand, "sudo apt install '$path'");
    expect(u.problem, contains(u.installCommand!));
    expect(LinuxUpdateHost.aptCommand('/home/riley/.cache/x.deb'), 'sudo apt install /home/riley/.cache/x.deb');
    expect(LinuxUpdateHost.aptCommand("/home/o'neil/x.deb"), "sudo apt install '/home/o'\\''neil/x.deb'");
  });

  group('the .deb where the desktop can ask for a password (pkexec)', () {
    const pk = '/usr/bin/pkexec';
    late File deb;
    late List<List<String>> ran;
    late List<String> launched;
    late int quits;
    setUp(() {
      deb = File('${dir.path}/ghost-messaging-linux-142.deb')..writeAsStringSync('a newer package');
      ran = [];
      launched = [];
      quits = 0;
    });
    LinuxUpdateHost host({int answer = 0, String? pkexec = pk}) => LinuxUpdateHost(
          env: {'XDG_CACHE_HOME': '${dir.path}/cache'},
          exe: '/opt/ghost-messaging/ghost-messaging',
          build: 141,
          pkexec: () => pkexec,
          asRoot: (command) async {
            ran.add(command);
            return answer;
          },
          launch: (p) async => launched.add(p),
          quit: () => quits++,
        );

    test('what is run: apt by its whole path, through pkexec, told yes', () {
      expect(LinuxUpdateHost.installAsRoot(pk, '/home/riley/.cache/ghost-messaging/updates/x 1.deb'), [pk, '/usr/bin/apt-get', 'install', '-y', '/home/riley/.cache/ghost-messaging/updates/x 1.deb']);
    });

    test('pkexec is looked for along PATH', () {
      final none = LinuxUpdateHost(env: const {'PATH': '/nowhere/at/all'}, exe: '/opt/ghost-messaging/ghost-messaging', build: 141);
      expect(none.pkexec, isNull);
    });

    test('ready as any other; Restart installs it as root, starts the new copy and quits', () async {
      final h = host();
      expect(h.asksPassword, isFalse);
      expect(await h.restart(), isNot('restarting'), reason: 'nothing brought down yet');
      expect(await h.install(deb.path, sha256: sha(deb), bytes: deb.lengthSync()), 'ready');
      expect(h.asksPassword, isTrue);
      expect(ran, isEmpty, reason: 'no password is asked for until Restart');
      expect(await h.restart(), 'restarting');
      expect(ran, [
        [pk, '/usr/bin/apt-get', 'install', '-y', deb.path],
      ]);
      expect(launched, ['/opt/ghost-messaging/ghost-messaging']);
      expect(quits, 1);
    });

    test('the password window put away: nothing installed, nothing quit, and the command to run instead', () async {
      final h = host(answer: 126);
      await h.install(deb.path, sha256: sha(deb), bytes: deb.lengthSync());
      final said = await h.restart();
      expect(said, startsWith('manual: The password wasn\'t given'));
      expect(said, contains('sudo apt install ${deb.path}'));
      expect(launched, isEmpty);
      expect(quits, 0);
      expect(h.asksPassword, isFalse);
      // Nobody to ask (no polkit agent), or apt refusing: the command too.
      final h2 = host(answer: 127);
      await h2.install(deb.path, sha256: sha(deb), bytes: deb.lengthSync());
      expect(await h2.restart(), startsWith('manual: It couldn\'t be installed from here.'));
    });

    test('no pkexec: the command, as before', () async {
      final h = host(pkexec: null);
      expect(await h.install(deb.path, sha256: sha(deb), bytes: deb.lengthSync()), startsWith('manual: It came from the .deb'));
      expect(h.asksPassword, isFalse);
      expect(h.command, 'sudo apt install ${deb.path}');
    });

    test('a package changed since it was checked is never installed as root', () async {
      final h = host();
      await h.install(deb.path, sha256: sha(deb), bytes: deb.lengthSync());
      deb.writeAsStringSync('something else now');
      expect(await h.restart(), 'The download is not the one the release describes');
      expect(ran, isEmpty);
      expect(quits, 0);
    });

    test('through the updater: ready and said to ask for a password; refused, it stands at the command', () async {
      final h = host(answer: 126);
      await h.install(deb.path, sha256: sha(deb), bytes: deb.lengthSync());
      final u = MacUpdates.standing(installed: const InstalledMac(version: '0.12.13', build: 141, dir: '/tmp'), phase: MacUpdatePhase.ready, host: h);
      addTearDown(u.dispose);
      expect(u.asksPassword, isTrue);
      expect(u.installCommand, isNull);
      // Opening the app never brings the password window up: only a press does.
      final step = ValueNotifier<SplashStep>((words: '', progress: null));
      await checkAtLaunch(u, step, lookFor: const Duration(milliseconds: 50));
      expect(ran, isEmpty);
      expect(u.phase, MacUpdatePhase.ready);
      await u.restart();
      expect(u.phase, MacUpdatePhase.manual);
      expect(u.asksPassword, isFalse);
      expect(u.installCommand, 'sudo apt install ${deb.path}');
      expect(u.problem, contains('The password wasn\'t given'));
    });
  });
}

Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
