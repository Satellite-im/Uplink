import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/market.dart';
import 'package:ghost_relay/pushes.dart';
import 'package:ghost_relay/turn.dart';
import 'package:test/test.dart';

/// GMFB-25, "Self-hosting the relay, documented" (../docs/SELF_HOSTING.md): the relay runs with nothing in its
/// environment at all, and the sample env file names every variable it reads, with nothing of ours in it.
void main() {
  group('with an empty environment', () {
    test('every setting reads as off or its default', () {
      const env = <String, String>{};
      expect(TurnConfig.fromEnvironment(env).on, isFalse, reason: 'no coturn: calls are direct only');
      final h = HandlesConfig.fromEnvironment(env);
      expect([h.discordId, h.xId, h.telegramBot, h.twilioSid, h.adminUser, h.adminHash], everyElement(isEmpty), reason: 'no sign-ins, no number checks, no admin');
      expect(ApnsConfig.fromEnvironment(env).keyFile, isEmpty, reason: 'no iPhone wake-ups');
      expect(MarketConfig.fromEnvironment(env).on, isTrue);
      expect(FilesConfig.fromEnvironment(env).maxFile, const FilesConfig().maxFile);
    });

    test('the program starts, answers on its routes, and stops on SIGTERM', () async {
      final data = await Directory.systemTemp.createTemp('ghost-relay-selfhost-');
      addTearDown(() => data.delete(recursive: true));
      // The same `dart` that runs this test, the relay's own source, and no environment whatever.
      final p = await Process.start(Platform.resolvedExecutable, ['bin/relay.dart', '--host', '127.0.0.1', '--port', '0', '--data', data.path],
          environment: const {}, includeParentEnvironment: false);
      addTearDown(() => p.kill(ProcessSignal.sigkill));
      final err = StringBuffer();
      p.stderr.transform(utf8.decoder).listen(err.write);
      final listening = Completer<int>();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final m = RegExp(r'listening on ws://127\.0\.0\.1:(\d+)').firstMatch(line);
        if (m != null && !listening.isCompleted) listening.complete(int.parse(m.group(1)!));
      });
      final port = await listening.future.timeout(const Duration(seconds: 60), onTimeout: () => fail('it never said it was listening: $err'));

      // Plain HTTP: what a web server in front of it, or a person checking, sees.
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      Future<(int, String)> get(String path) async {
        final res = await (await http.get('127.0.0.1', port, path)).close();
        return (res.statusCode, await res.transform(utf8.decoder).join());
      }

      expect(await get('/'), (200, 'Ghost Messaging relay\n'));
      final market = await get('/market');
      expect(market.$1, 200);
      expect(jsonDecode(market.$2), containsPair('ok', true));

      // The hub greets, which is what the app's Settings › Routes checks before it moves to a relay.
      final ws = await WebSocket.connect('ws://127.0.0.1:$port/hub');
      final first = await ws.first.timeout(const Duration(seconds: 10));
      expect((jsonDecode(first as String) as Map)['hello'], matches(RegExp(r'^[0-9a-f]+$')));
      await ws.close();

      p.kill(ProcessSignal.sigterm);
      expect(await p.exitCode.timeout(const Duration(seconds: 20)), 0);
      expect(err.toString(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('the sample env file (deploy/relay.env.example)', () {
    final sample = File('deploy/relay.env.example').readAsStringSync();
    // Every name set or commented out: `NAME=` or `# NAME=`.
    final listed = {for (final m in RegExp(r'^#?\s*([A-Z][A-Z0-9_]+)=', multiLine: true).allMatches(sample)) m.group(1)!};

    test('names every variable the relay reads, and nothing else', () {
      final read = <String>{'PORT'};
      for (final f in [...Directory('lib').listSync().whereType<File>(), File('bin/relay.dart')]) {
        read.addAll(RegExp(r"'(GHOST_[A-Z0-9_]+)'").allMatches(f.readAsStringSync()).map((m) => m.group(1)!));
      }
      expect(listed.difference(read), isEmpty, reason: 'a name in the sample the relay never reads');
      expect(read.difference(listed), isEmpty, reason: 'a name the relay reads that the sample leaves out');
    });

    test('has nothing of ours in it: no secret filled in, no host of ours', () {
      for (final line in sample.split('\n')) {
        final m = RegExp(r'^([A-Z][A-Z0-9_]+)=(.*)$').firstMatch(line.trim());
        if (m == null) continue;
        expect(m.group(1), anyOf('GHOST_PUBLIC_URL', 'GHOST_ADMIN_NAMES', 'GHOST_MARKET_ON'), reason: 'only these are set in the sample; the rest are commented out');
      }
      for (final f in Directory('deploy').listSync().whereType<File>()) {
        final text = f.readAsStringSync();
        expect(text, isNot(contains('gogho.st')), reason: '${f.path} names our host');
        expect(text, isNot(contains('ghost-sms.com')), reason: '${f.path} names our host');
        expect(text, isNot(contains('18787')), reason: '${f.path} names our box\'s port');
      }
    });
  });
}
