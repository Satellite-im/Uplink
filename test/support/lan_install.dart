import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/p256.dart';

/// Another device on the local network, in a process of its own (test/relay_host_lan_test.dart): an install that
/// signs in to a hub over a plain WebSocket as the app does, bound to the host it dialled where the hub takes that,
/// with a pass phrase's proof where it is given one. It says on stdout what happens, a line each:
///
///     ID <its name>              signed in
///     REFUSED <the hub's answer> not let in
///     GOT <from> <packet, hex>   a packet came; it answers it with the same bytes the other way round
///     CLOSED                     the hub closed the connection (and then it ends)
///
///   dart test/support/lan_install.dart ws://127.0.0.1:7787/hub [pass phrase]
///
/// Plain Dart, no Flutter: run with the `dart` beside Flutter, from the app's folder. Closing its stdin ends it.
Future<void> main(List<String> args) async {
  final url = args.first;
  final phrase = args.length > 1 ? args[1] : null;
  final random = Random.secure();
  List<int> bytes(int n) => [for (var i = 0; i < n; i++) random.nextInt(256)];
  String hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  List<int> unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

  final scalar = bytes(32);
  final key = P256.publicOf(scalar);
  final id = Hub.nameOf(key);
  final u = Uri.parse(url);
  final host = '${u.host.toLowerCase()}${u.hasPort ? ':${u.port}' : ''}';
  final ws = await WebSocket.connect(url);
  var signedIn = false;
  var seq = 0;
  ws.listen((data) {
    if (data is String) {
      final m = jsonDecode(data) as Map;
      if (m['hello'] is String && !signedIn) {
        final nonce = unhex(m['hello'] as String);
        final v2 = m['v2'] == true;
        final sig = P256.sign(scalar, v2 ? Hub.signedV2(host, nonce) : [...utf8.encode(Hub.greeting), ...nonce], bytes(32));
        ws.add(jsonEncode({'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), if (v2) 'v': 2, if (v2) 'host': host, if (phrase != null) 'pass': hex(Hub.passProof(Hub.passKeyOf(phrase, m['salt'] as String), nonce, id))}));
      } else if (m.containsKey('ok') && !signedIn) {
        if (m['ok'] != true) {
          stdout.writeln('REFUSED ${jsonEncode(m)}');
          return;
        }
        signedIn = true;
        stdout.writeln('ID $id');
      }
      return;
    }
    final b = data as List<int>;
    if (b.length > 17 && b[0] == Hub.toPeer) {
      final from = hex(b.sublist(1, 17)), packet = b.sublist(17);
      stdout.writeln('GOT $from ${hex(packet)}');
      final n = ByteData(4)..setUint32(0, ++seq);
      ws.add(Uint8List.fromList([Hub.toPeer, ...n.buffer.asUint8List(), ...unhex(from), ...packet.reversed]));
    }
  }, onDone: () async {
    stdout.writeln('CLOSED');
    await stdout.flush();
    exit(0);
  });
  stdin.listen((_) {}, onDone: () => exit(0));
}
