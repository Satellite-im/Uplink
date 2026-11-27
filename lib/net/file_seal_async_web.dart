import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_seal.dart';

/// FileSeal's chunks sealed and opened by the browser's own AES-GCM (lib/net/file_seal_async.dart): each chunk under
/// [FileSeal.nonceOf] and bound to [FileSeal.aadOf], with a 128-bit tag after its bytes, as FastGcm writes it.
class SealAsync {
  SealAsync._();

  static web.SubtleCrypto get _subtle => web.window.crypto.subtle;

  static JSObject _object(Map<String, JSAny?> fields) {
    final o = JSObject();
    fields.forEach((name, value) => o[name] = value);
    return o;
  }

  /// The file's key, for this run alone, as the browser holds keys: one it can't hand back.
  static Future<web.CryptoKey> _key(Uint8List raw, String use) async =>
      await _subtle.importKey('raw', raw.toJS, _object({'name': 'AES-GCM'.toJS}), false, [use.toJS].toJS).toDart;

  static JSObject _params(Uint8List nonce, Uint8List aad) => _object({'name': 'AES-GCM'.toJS, 'iv': nonce.toJS, 'additionalData': aad.toJS, 'tagLength': 128.toJS});

  static Future<Uint8List> sealRun(SealRun run) async {
    final key = await _key(run.key, 'encrypt');
    final out = BytesBuilder(copy: false);
    for (final c in FileSeal.runChunks(size: run.size, first: run.first, length: run.plain.length, chunkSize: run.chunkSize, sealed: false)) {
      final plain = Uint8List.sublistView(run.plain, c.start, c.end);
      final sealed = (await _subtle.encrypt(_params(FileSeal.nonceOf(run.prefix, c.index), FileSeal.aadOf(run.fileId, c.index, c.last)), key, plain.toJS).toDart) as JSArrayBuffer;
      out.add(sealed.toDart.asUint8List());
    }
    return out.takeBytes();
  }

  static Future<Uint8List?> openRun(OpenRun run) async {
    if (run.sealed.isEmpty) return Uint8List(0);
    final web.CryptoKey key;
    try {
      key = await _key(run.key, 'decrypt');
    } catch (_) {
      return null;
    }
    final out = BytesBuilder(copy: false);
    for (final c in FileSeal.runChunks(size: run.size, first: run.first, length: run.sealed.length, chunkSize: run.chunkSize, sealed: true)) {
      if (c.end < 0) return null;
      try {
        final sealed = Uint8List.sublistView(run.sealed, c.start, c.end);
        final plain = (await _subtle.decrypt(_params(FileSeal.nonceOf(run.prefix, c.index), FileSeal.aadOf(run.fileId, c.index, c.last)), key, sealed.toJS).toDart) as JSArrayBuffer;
        out.add(plain.toDart.asUint8List());
      } catch (_) {
        // A tag that doesn't match: changed, moved, cut short or under another key.
        return null;
      }
    }
    return out.takeBytes();
  }

  static Future<Uint8List> sha256(Uint8List bytes) async => ((await _subtle.digest('SHA-256'.toJS, bytes.toJS).toDart) as JSArrayBuffer).toDart.asUint8List();
}
