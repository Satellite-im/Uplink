import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ghost_relay/bounty.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/sha256.dart';

/// Pays a feedback bounty in souls through the relay's /bounty (lib/bounty.dart; Matt, 2026-11-21: "i want you to pay
/// the bounties for me", then "A bounty key on the relay").
///
///     dart run tool/pay_bounty.dart key                      makes the key once; prints its public half for GHOST_BOUNTY_KEY
///     dart run tool/pay_bounty.dart pay <ghost id> <souls> <why> [--relay https://gogho.st]
///
/// The key is kept in ~/.config/mattssoftware/ghost-bounty-key.json (readable by this Mac's user alone), never in the
/// repository, which is public.
File get _file => File('${Platform.environment['HOME']}/.config/mattssoftware/ghost-bounty-key.json');

/// The bounty key's private half (32 bytes): read from the file, or made on first use and written there with its
/// public half, mode 600.
List<int> _scalar() {
  if (_file.existsSync()) {
    final hex = (jsonDecode(_file.readAsStringSync()) as Map)['scalar'] as String;
    return [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
  }
  final r = Random.secure();
  final scalar = sha256([for (var i = 0; i < 64; i++) r.nextInt(256)]);
  _file.parent.createSync(recursive: true);
  _file.writeAsStringSync(jsonEncode({'scalar': hexOf(scalar), 'public': hexOf(P256.publicOf(scalar))}));
  Process.runSync('chmod', ['600', _file.path]);
  return scalar;
}

/// `key` prints the public half; `pay` signs the body as lib/bounty.dart checks it, posts it, and prints the relay's
/// answer (exit code 1 where it is not 200).
Future<void> main(List<String> args) async {
  final scalar = _scalar();
  final public = P256.publicOf(scalar);
  if (args.isEmpty || args.first == 'key') {
    stdout.writeln('GHOST_BOUNTY_KEY=${hexOf(public)}');
    return;
  }
  if (args.first != 'pay' || args.length < 4) {
    stderr.writeln('usage: pay <ghost id> <souls> <why> [--relay https://gogho.st]');
    exit(2);
  }
  final at = args.indexOf('--relay');
  final relay = at >= 0 ? args[at + 1] : 'https://gogho.st';
  final body = utf8.encode(jsonEncode({'to': args[1], 'souls': int.parse(args[2]), 'why': args[3]}));
  final time = DateTime.now().millisecondsSinceEpoch;
  final words = Bounty.signedWords(time, hexOf(sha256(body)));
  final r = Random.secure();
  // The signature's own secret number, never used twice: a hash of the key, 32 fresh random bytes and the words.
  final nonce = sha256([...scalar, for (var i = 0; i < 32; i++) r.nextInt(256), ...utf8.encode(words)]);
  final sig = P256.sign(scalar, utf8.encode(words), nonce);
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse('$relay/bounty'));
    req.headers
      ..set('x-ghost-key', base64Encode(public))
      ..set('x-ghost-time', '$time')
      ..set('x-ghost-sig', base64Encode(sig))
      ..contentType = ContentType.json;
    req.add(body);
    final res = await req.close();
    final said = await res.transform(utf8.decoder).join();
    stdout.writeln('${res.statusCode} $said');
    if (res.statusCode != 200) exitCode = 1;
  } finally {
    client.close(force: true);
  }
}
