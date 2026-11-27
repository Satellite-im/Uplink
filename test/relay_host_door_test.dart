import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/hub_link.dart' show doorFullWords;
import 'package:ghost_messaging/relay_host/hosting.dart';
import 'package:ghost_messaging/relay_host/relay_host_io.dart';

import 'support/host_support.dart';

/// The local network's door of a relay hosted from the app (lib/relay_host/lan_door.dart). From the review's probe
/// (2026-11-23): with dart:io's HttpServer alone at the door, one device's half-made requests, 300 of them, were each
/// held open (an app's file descriptor each) until dart:io's two-minute idle timeout, past the hub's 200 connections,
/// which never saw them: a Mac app from the Dock has 256 descriptors. Now the door counts connections as it takes them
/// (8 from one address, 64 in all) and closes one that hasn't finished its request in five seconds.

/// The `dart` beside the Flutter running this test.
String get _dart {
  final root = Platform.environment['FLUTTER_ROOT'];
  return root == null ? 'dart' : '$root${Platform.pathSeparator}bin${Platform.pathSeparator}dart';
}

/// This process's open file descriptors, as lsof lists them (those with a number).
int _fds() => (Process.runSync('lsof', ['-n', '-P', '-p', '$pid']).stdout as String).split('\n').where((l) => RegExp(r'\s\d+[urw]\s').hasMatch(l)).length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('one device\'s 300 half-made requests: at most 8 held at once, each closed within seconds, the app\'s descriptors its own; then a device signs in', () async {
    final host = makeHost(Kept(), lan: true);
    addTearDown(host.shutdown);
    await host.setOn(true);
    expect(host.state, HostState.up);
    final url = host.lanUrls.single;
    final port = Uri.parse(url).port;
    final fdsBefore = _fds();

    final flood = await Process.start(_dart, ['test/support/lan_flood.dart', '$port', '300']);
    addTearDown(() => flood.kill(ProcessSignal.sigkill));
    final lines = <String>[];
    var most = 0;
    flood.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      lines.add(l);
      if (host.doorOpen > most) most = host.doorOpen;
    });
    await waitFor(() => lines.any((l) => l.startsWith('OPEN ')), 'the flood never finished opening', most: const Duration(seconds: 90));
    final held = _fds() - fdsBefore;
    // ignore: avoid_print
    print('door: ${lines.firstWhere((l) => l.startsWith('OPEN '))}; at the door ${host.doorOpen} (most seen $most), closed ${host.doorClosed}; the app holds $held more descriptors');
    expect(host.doorOpen, lessThanOrEqualTo(RelayHost.doorEach), reason: 'one address holds 8 at most');
    expect(most, lessThanOrEqualTo(RelayHost.doorEach));
    expect(held, lessThan(40), reason: 'the rest were closed as they came');

    // None finishes its request: every one is closed, within the door's few seconds (generous here, for a busy machine).
    await waitFor(() => lines.isNotEmpty && lines.last == 'STILL 0', 'the half-made requests were never closed', most: const Duration(seconds: 60));
    expect(host.doorOpen, 0);
    expect(host.connections, 0);

    // And a device on the network signs in as ever, through the same door.
    final other = await Process.start(_dart, ['test/support/lan_install.dart', url]);
    addTearDown(() => other.kill(ProcessSignal.sigkill));
    final said = <String>[];
    other.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(said.add);
    await waitFor(() => said.any((l) => l.startsWith('ID ')), 'the device never signed in (said: $said)', most: const Duration(seconds: 60));
    expect(host.connections, 1);
    expect(host.doorOpen, 1, reason: 'its connection counted at the door while it lasts');
    await flood.stdin.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('one address holds three connections that got through at most: 8 addresses can\'t fill the door with sign-ins (the third review, 2026-11-23)', () async {
    final host = makeHost(Kept(), lan: true);
    addTearDown(host.shutdown);
    await host.setOn(true);
    final url = host.lanUrls.single;
    final held = <WebSocket>[];
    var refused = 0;
    final why = <Object?>{};
    for (var i = 0; i < 5; i++) {
      final ws = await WebSocket.connect(url);
      final said = StreamIterator(ws);
      await said.moveNext();
      final first = jsonDecode(said.current as String) as Map;
      if (first['door'] == 'full') await said.moveNext();
      if (first['door'] == 'full') {
        refused++;
        why.add(first['err']);
        expect(ws.closeCode, 4429);
      } else {
        held.add(ws);
      }
    }
    expect(why, {doorFullWords}, reason: 'told why, not dropped without a word (the fourth review, 2026-11-23)');
    addTearDown(() async {
      for (final w in held) {
        await w.close();
      }
    });
    expect([held.length, refused], [RelayHost.doorThrough, 2]);
    expect(host.doorOpen, RelayHost.doorThrough);
    // One goes, and another may come.
    await held.removeAt(0).close();
    await waitFor(() => host.doorOpen == RelayHost.doorThrough - 1, 'the one that went was still counted');
    final again = await WebSocket.connect(url);
    held.add(again);
    final hello = StreamIterator(again);
    await hello.moveNext();
    expect((jsonDecode(hello.current as String) as Map).containsKey('hello'), isTrue);
    expect(host.doorOpen, RelayHost.doorThrough);
  });
}
