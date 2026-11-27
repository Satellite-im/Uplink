import 'dart:convert';
import 'dart:typed_data';

import '../net/crypto.dart';

/// An account's name for the rest of the world (GMFB-33): a `did:key` made from its P-256 public key, the key the
/// network already knows it by (lib/net/crypto.dart, NetKeys). Nothing is looked up anywhere to read one: the key is
/// written inside it.
///
/// How it is written (the W3C did:key method): `did:key:z` then, in base58btc, the multicodec for a P-256 public key
/// (0x1200, as the varint bytes 0x80 0x24) followed by the 33-byte compressed key. Every P-256 one starts `did:key:zDn`.
class Did {
  static const prefix = 'did:key:z';
  static const _codec = [0x80, 0x24];

  /// The DID of [publicKey] (33 bytes, compressed).
  static String ofKey(List<int> publicKey) {
    if (publicKey.length != 33 || (publicKey[0] != 2 && publicKey[0] != 3)) throw ArgumentError('not a compressed P-256 key');
    return '$prefix${Base58.encode([..._codec, ...publicKey])}';
  }

  /// The 33-byte key [did] is made from, or null where it is not a P-256 did:key.
  static Uint8List? keyOf(String did) {
    final d = did.trim();
    if (!d.startsWith(prefix)) return null;
    final bytes = Base58.decode(d.substring(prefix.length));
    if (bytes == null || bytes.length != 35 || bytes[0] != _codec[0] || bytes[1] != _codec[1]) return null;
    final key = Uint8List.fromList(bytes.sublist(2));
    if (key[0] != 2 && key[0] != 3) return null;
    return key;
  }

  /// [did] cut short for a row: the start and the end, the middle as an ellipsis.
  static String short(String did) => did.length <= 28 ? did : '${did.substring(0, 18)}…${did.substring(did.length - 6)}';
}

/// Base58 with Bitcoin's alphabet (base58btc), as did:key writes its bytes.
class Base58 {
  static const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static String encode(List<int> bytes) {
    var zeros = 0;
    while (zeros < bytes.length && bytes[zeros] == 0) {
      zeros++;
    }
    var n = BigInt.zero;
    for (final b in bytes) {
      n = (n << 8) | BigInt.from(b & 0xff);
    }
    final out = StringBuffer();
    final digits = <int>[];
    final base = BigInt.from(58);
    while (n > BigInt.zero) {
      digits.add((n % base).toInt());
      n = n ~/ base;
    }
    for (var i = 0; i < zeros; i++) {
      out.write('1');
    }
    for (final d in digits.reversed) {
      out.write(alphabet[d]);
    }
    return out.toString();
  }

  /// The bytes [text] spells, or null where it has a letter that isn't base58's.
  static Uint8List? decode(String text) {
    var n = BigInt.zero;
    final base = BigInt.from(58);
    var zeros = 0;
    while (zeros < text.length && text[zeros] == '1') {
      zeros++;
    }
    for (var i = 0; i < text.length; i++) {
      final d = alphabet.indexOf(text[i]);
      if (d < 0) return null;
      n = n * base + BigInt.from(d);
    }
    final body = <int>[];
    while (n > BigInt.zero) {
      body.add((n & BigInt.from(0xff)).toInt());
      n = n >> 8;
    }
    return Uint8List.fromList([...List.filled(zeros, 0), ...body.reversed]);
  }
}

/// What a pasted proof turned out to be ([Proof.check]).
class ProofCheck {
  const ProofCheck._({required this.good, this.did = '', this.key, this.statement = '', this.signed, this.problem = ''});

  /// Whether the signature is the account's over these words and this time.
  final bool good;

  /// The account it names, its key, the words, and when it says it was signed. Filled in as far as it could be read.
  final String did;
  final Uint8List? key;
  final String statement;
  final DateTime? signed;

  /// Why it doesn't check out, in words to show; '' where it does.
  final String problem;
}

/// A statement signed with the account's key, to paste anywhere (GMFB-33: "Sign a short statement with the account key
/// so people can prove an account is theirs elsewhere"). docs/proofs.md is the format for anyone checking one with
/// standard tools, and tool/check-proof.mjs checks one with nothing but Node.
///
///     -----BEGIN GHOST PROOF-----
///     Account: did:key:zDn…
///     Signed: 2026-11-23T10:15:00Z
///     Signature: (r then s, 64 bytes, base64url without padding)
///
///     I am @matt on Uplink
///     -----END GHOST PROOF-----
///
/// The signature is ECDSA on P-256 with SHA-256 over the UTF-8 of `ghost-proof v1`, a newline, the DID, a newline, the
/// time as written, a newline, and the statement. The statement is tidied the same way before signing and checking
/// (line ends made `\n`, each line trimmed, blank lines at either end dropped), so a site that changes line ends or
/// spaces round a line doesn't break it.
class Proof {
  static const begin = '-----BEGIN GHOST PROOF-----';
  static const end = '-----END GHOST PROOF-----';
  static const words = 'ghost-proof v1\n';

  /// The most a statement may be, in characters.
  static const most = 280;

  /// The most a block (from BEGIN to END) may be: anything longer is not one of ours. What is around it is not counted.
  static const _mostRead = 8192;

  /// [text] as it is signed and checked.
  static String tidy(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').map(_trim).toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  /// Spaces and tabs off both ends, and nothing else: tool/check-proof.mjs and any other checker trim the same.
  static String _trim(String line) => line.replaceAll(_ends, '');
  static final _ends = RegExp(r'^[ \t]+|[ \t]+$');

  /// What a time and a signature must look like, exactly (the signature after + and / are read as - and _).
  static final timeShape = RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$');
  static final signatureShape = RegExp(r'^[A-Za-z0-9_-]{86}$');

  /// A time as a proof writes it: UTC, to the second.
  static String timeOf(DateTime at) {
    final u = at.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
  }

  /// What is signed.
  static Uint8List signedBytes(String did, String time, String statement) => Uint8List.fromList(utf8.encode('$words$did\n$time\n$statement'));

  /// Why [statement] can't be signed, in words to show; null where it can.
  static String? refuse(String statement) {
    final s = tidy(statement);
    if (s.isEmpty) return 'Write what you want to say first.';
    if (s.runes.length > most) return 'That is ${s.runes.length} characters. A statement is $most at most.';
    if (s.contains(begin) || s.contains(end)) return 'A statement can\'t hold the lines that start and end a proof.';
    return null;
  }

  /// [statement] signed by the holder of [publicKey] with [sign] (r then s, 64 bytes), as a block to paste.
  static Future<String> make(String statement, {required List<int> publicKey, required Future<Uint8List> Function(List<int> message) sign, DateTime? now}) async {
    final why = refuse(statement);
    if (why != null) throw ArgumentError(why);
    final s = tidy(statement), did = Did.ofKey(publicKey), time = timeOf(now ?? DateTime.now());
    final sig = await sign(signedBytes(did, time, s));
    return [begin, 'Account: $did', 'Signed: $time', 'Signature: ${base64Url.encode(sig).replaceAll('=', '')}', '', s, end].join('\n');
  }

  static ProofCheck _bad(String problem, {String did = '', Uint8List? key, String statement = '', DateTime? signed}) => ProofCheck._(good: false, problem: problem, did: did, key: key, statement: statement, signed: signed);

  /// Whose [pasted] is, where it is a proof whose signature checks out: what is around the block is passed over.
  static ProofCheck check(String pasted) {
    final text = pasted.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final a = text.indexOf(begin);
    final b = a < 0 ? -1 : text.indexOf(end, a + begin.length);
    if (a < 0 || b < 0) return _bad('No proof found. Paste the whole block, from its BEGIN line to its END line.');
    if (b + end.length - a > _mostRead) return _bad('That is too long to be a proof.');
    final lines = text.substring(a + begin.length, b).split('\n').map(_trim).toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    final fields = <String, String>{};
    var i = 0;
    for (; i < lines.length && lines[i].isNotEmpty; i++) {
      final at = lines[i].indexOf(':');
      if (at < 0) return _bad('The proof\'s lines were changed: "${lines[i]}" isn\'t one of them.');
      fields[_trim(lines[i].substring(0, at)).toLowerCase()] = _trim(lines[i].substring(at + 1));
    }
    final did = fields['account'] ?? '', time = fields['signed'] ?? '', sigText = fields['signature'] ?? '';
    final statement = tidy(lines.skip(i).join('\n'));
    final key = Did.keyOf(did);
    final signed = timeShape.hasMatch(time) ? DateTime.tryParse(time) : null;
    if (key == null) return _bad('The account it names isn\'t one this app can read.', did: did, statement: statement);
    Uint8List? sig;
    final url = sigText.replaceAll('+', '-').replaceAll('/', '_');
    if (signatureShape.hasMatch(url)) {
      try {
        sig = base64Url.decode('$url==');
      } catch (_) {}
    }
    if (sig == null || sig.length != 64 || signed == null) return _bad('Part of the proof is missing or was changed.', did: did, key: key, statement: statement, signed: signed);
    if (!NetCrypto.verify(key, signedBytes(did, time, statement), sig)) {
      return _bad('The signature doesn\'t match: the words, the time or the account were changed, or it was never signed by that account.', did: did, key: key, statement: statement, signed: signed);
    }
    return ProofCheck._(good: true, did: did, key: key, statement: statement, signed: signed);
  }
}
