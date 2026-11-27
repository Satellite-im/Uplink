import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';

/// A pack's canonical JSON and its SHA-256 (lib/plugins/pack/canonical.dart; Matt, 2026-11-20: "I'd like to be able to
/// verify them for the store through a review process"): one way of writing any value, so the hash the reviewer signs
/// is the hash of what installs. The relay's copy is held to these same vectors (relay/test/market_pack_test.dart), and
/// so is the pass over the bytes that refuses deep nesting before anything is decoded.
void main() {
  group('A.13 vectors', () {
    // Input as JSON, canonical text, its bytes, their SHA-256.
    const vectors = <(String, String, int, String)>[
      (r'{"b":1,"a":[true,false,null],"c":{"y":"é\"\\\n","x":-5}}', r'{"a":[true,false,null],"b":1,"c":{"x":-5,"y":"é\"\\\n"}}', 57, '4157b09b53d6d810c08dc572c9b40fdb8ea1b09626f8a5a7b13e7aef2899b5fd'),
      (r'{"z":"\u0001\t\u001f","emoji":"👻","slash":"a/b","lt":"<&>"}', r'{"emoji":"👻","lt":"<&>","slash":"a/b","z":"\u0001\t\u001f"}', 62, '45b8ee121777576252e347968447e5cddbc0772ab78c5b729744d2a8130965f0'),
      ('{"b":0,"B":0,"a":0,"_":0,"wordsFrom":1,"when":2}', '{"B":0,"_":0,"a":0,"b":0,"when":2,"wordsFrom":1}', 48, '017d8fea09cd7f8525ea10ca1954727b8c6000c75296982ed9b0b05cb8f1745f'),
      ('[]', '[]', 2, '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945'),
      ('{"nested":{"list":[{"k":"v","a":[]},"x"],"empty":{}}}', '{"nested":{"empty":{},"list":[{"a":[],"k":"v"},"x"]}}', 53, '6b10ee38785e35387bd511c8a4be0c824eb88cb951d72de3feca80c5f44baf11'),
    ];
    for (final (input, text, length, sha) in vectors) {
      test(input, () {
        final value = jsonDecode(input);
        expect(canonicalJson(value), text);
        final bytes = canonicalBytes(value);
        expect(bytes, hasLength(length));
        expect(sha256Hex(bytes), sha);
        expect(canonicalBytes(jsonDecode(utf8.decode(bytes))), bytes, reason: 'the canonical form is its own canonical form');
      });
    }
  });

  test('the empty body\'s SHA-256', () {
    expect(sha256Hex(const []), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  });

  test('a fraction, a key that isn\'t a string, or anything JSON hasn\'t throws', () {
    expect(() => canonicalJson({'a': 1.5}), throwsArgumentError);
    expect(() => canonicalJson([1.0]), throwsArgumentError);
    expect(() => canonicalJson({1: 'a'}), throwsArgumentError);
    expect(() => canonicalJson(DateTime(2026)), throwsArgumentError);
  });

  group('B.3 jsonDepthOk', () {
    List<int> b(String s) => utf8.encode(s);

    test('eight deep is fine, nine is not', () {
      expect(jsonDepthOk(b('[[[[[[[[1]]]]]]]]')), isTrue);
      expect(jsonDepthOk(b('[[[[[[[[[1]]]]]]]]]')), isFalse);
      expect(jsonDepthOk(b('{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":1}}}}}}}}')), isTrue);
      expect(jsonDepthOk(b('{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":1}}}}}}}}}')), isFalse);
    });

    test('brackets inside a string are words, and an escaped quote doesn\'t end it', () {
      expect(jsonDepthOk(b('{"a":"[[[[[[[[[[["}')), isTrue);
      expect(jsonDepthOk(b(r'{"a":"\"[[[[[[[[[["}')), isTrue);
      expect(jsonDepthOk(b(r'{"a":"\\"}')), isTrue, reason: 'an escaped backslash ends with the string');
      expect(jsonDepthOk(b(r'{"a":"\\",' '"b":[[[[[[[[[1]]]]]]]]]}')), isFalse, reason: 'after it, brackets count again');
    });

    test('131,072 brackets are refused, in well under a millisecond each time', () {
      final deep = [...List.filled(131072, 0x5B), ...List.filled(131072, 0x5D)];
      final times = <int>[];
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        expect(jsonDepthOk(deep), isFalse);
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      // It stops at the ninth bracket: what it costs is that, not the file.
      expect(times[2], lessThan(5000), reason: '${times[2]} µs');
    });
  });
}
