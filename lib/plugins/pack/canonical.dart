/// A pack's canonical JSON and its SHA-256 (A.13): one way of writing any value, so a file's hash and its content's
/// hash are the same thing, and the reviewer's signature covers exactly what installs. The relay has its own copy
/// (relay/lib/market_pack.dart), and both are held to the same vectors.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../net/crypto.dart';
import 'format.dart';

/// [value] written with every object's keys sorted by String.compareTo (UTF-16 code units) at every depth, arrays in
/// order, strings as dart:convert writes them, integers in decimal and no whitespace. ArgumentError for a double, a
/// map key that isn't a String, or anything JSON doesn't have. It is only ever called on a value whose bytes passed
/// [jsonDepthOk], so its recursion is at most [PackLimits.depth] deep.
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

// [value] with every object's keys in order, at every depth; an ArgumentError for what a pack can't hold.
Object? _sorted(Object? value) {
  if (value == null || value is bool || value is int || value is String) return value;
  if (value is double) throw ArgumentError.value(value, 'value', 'A pack has no fractions');
  if (value is List) return [for (final v in value) _sorted(v)];
  if (value is Map) {
    final keys = <String>[];
    for (final k in value.keys) {
      if (k is! String) throw ArgumentError.value(k, 'key', 'A JSON object\'s keys are strings');
      keys.add(k);
    }
    keys.sort();
    // A map literal keeps the order its keys went in, so jsonEncode writes them sorted.
    return <String, Object?>{for (final k in keys) k: _sorted(value[k])};
  }
  throw ArgumentError.value(value, 'value', 'Not a JSON value');
}

/// utf8.encode(canonicalJson(value)): no BOM, no trailing newline.
Uint8List canonicalBytes(Object? value) => utf8.encode(canonicalJson(value));

/// The lower-case hex of [bytes]' SHA-256.
String sha256Hex(List<int> bytes) => NetCrypto.hex(NetCrypto.sha256(bytes));

/// A.1's pass over the bytes, before any decoding: false as soon as `[` and `{` outside strings nest deeper than [most].
/// A `"` starts or ends a string; inside one, `\` makes the next byte part of it. Never recursive, never throws: a file
/// of 131,072 brackets would decode, and then overflow the stack in [canonicalJson] and in jsonEncode.
bool jsonDepthOk(List<int> bytes, {int most = PackLimits.depth}) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final b in bytes) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (b == 0x5C) {
        escaped = true;
      } else if (b == 0x22) {
        inString = false;
      }
    } else if (b == 0x22) {
      inString = true;
    } else if (b == 0x5B || b == 0x7B) {
      if (++depth > most) return false;
    } else if ((b == 0x5D || b == 0x7D) && depth > 0) {
      depth--;
    }
  }
  return true;
}
