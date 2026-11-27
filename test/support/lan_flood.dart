import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// For test/relay_host_door_test.dart (from the review's probe, 2026-11-23): another device on the local network that
/// opens [count] TCP connections to a hosted relay's door at 127.0.0.1:[port], says half a request line on each and
/// nothing more, and holds them. Says `OPEN <open> <refused>` once it has tried them all, then `STILL <n>` every 200 ms
/// with how many the far end hasn't closed. Closing its stdin ends it.
///
///   dart test/support/lan_flood.dart <port> <count>
Future<void> main(List<String> args) => runZonedGuarded(() => _flood(args), (_, _) {})!;

Future<void> _flood(List<String> args) async {
  final port = int.parse(args[0]), count = int.parse(args[1]);
  final open = <Socket>{};
  var refused = 0;
  for (var i = 0; i < count; i++) {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 5));
      // The door may close it at once: that is no failure here.
      s.done.then((_) {}, onError: (Object _) {});
      s.write('GET /hub HTTP/1.1\r\nHost: 127.0.0.1\r\n');
      open.add(s);
      s.listen((_) {}, onDone: () => open.remove(s), onError: (Object _) => open.remove(s), cancelOnError: true);
    } catch (_) {
      refused++;
    }
  }
  stdout.writeln('OPEN ${open.length} $refused');
  Timer.periodic(const Duration(milliseconds: 200), (_) => stdout.writeln('STILL ${open.length}'));
  stdin.transform(utf8.decoder).listen((_) {}, onDone: () => exit(0));
}
