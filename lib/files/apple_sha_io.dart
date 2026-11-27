import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../platform_info.dart';

/// CommonCrypto's, which every Mac and iPhone has (libSystem): CC_SHA256_Init, _Update, _Final.
class AppleSha {
  AppleSha._(this._update, this._final, this._ctx, this._buf);

  /// How many bytes are handed to CommonCrypto at once: the size of the buffer copied into.
  static const _room = 4 << 20;

  /// A hash begun; null where this is no Mac or iPhone, or the functions are not there.
  static AppleSha? open() {
    if (!PlatformInfo.isMacOS && !PlatformInfo.isIOS) return null;
    try {
      final lib = ffi.DynamicLibrary.process();
      final init = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Void>)>('CC_SHA256_Init');
      final update = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, ffi.Uint32), int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int)>('CC_SHA256_Update');
      final end = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Void>), int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Void>)>('CC_SHA256_Final');
      // CC_SHA256_CTX is 104 bytes; more than enough is asked for.
      final ctx = pkg_ffi.calloc<ffi.Uint8>(256).cast<ffi.Void>();
      final buf = pkg_ffi.malloc<ffi.Uint8>(_room);
      init(ctx);
      return AppleSha._(update, end, ctx, buf);
    } catch (_) {
      return null;
    }
  }

  final int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint8>, int) _update;
  final int Function(ffi.Pointer<ffi.Uint8>, ffi.Pointer<ffi.Void>) _final;
  final ffi.Pointer<ffi.Void> _ctx;
  final ffi.Pointer<ffi.Uint8> _buf;

  /// Takes the first [length] bytes of [bytes]; then [end] gives the 32 bytes of the hash, and [close] frees what
  /// was held.
  void add(Uint8List bytes, int length) {
    for (var at = 0; at < length; at += _room) {
      final n = math.min(_room, length - at);
      _buf.asTypedList(n).setRange(0, n, bytes, at);
      _update(_ctx, _buf, n);
    }
  }

  Uint8List end() {
    _final(_buf, _ctx);
    return Uint8List.fromList(_buf.asTypedList(32));
  }

  void close() {
    pkg_ffi.calloc.free(_ctx);
    pkg_ffi.malloc.free(_buf);
  }
}
