/// Reads a circle's music packed without loss (native/voicefx/music_pack.c): one FLAC frame of 48 kHz stereo 16-bit,
/// standing by itself. Only what that writes of FLAC (RFC 9639) is read, and anything else, or anything broken, is
/// refused: what comes is from another person's device. No shift here passes 32 bits and nothing is left signed after
/// one, so it reads the same in a browser.
library;

import 'dart:typed_data';

abstract final class Flac {
  /// The most frames (of two samples) in one.
  static const most = 4096;

  /// The samples of [bytes], interleaved, where it is whole, right, and of [frames] frames; else null.
  static Int16List? read(Uint8List bytes, int frames) {
    try {
      return _read(bytes, frames);
    } on _Broken {
      return null;
    }
  }

  static Int16List _read(Uint8List bytes, int frames) {
    if (bytes.length < 12 || frames < 16 || frames > most) throw const _Broken();
    final b = _Bits(bytes);
    // Its mark, a count of its own, 48 kHz, two channels told one of four ways, 16 bits.
    if (b.take(16) != 0xfff8 || b.take(8) != 0x7a) throw const _Broken();
    final how = b.take(8), way = how >> 4;
    if ((how & 0x0f) != 8 || !(way == 1 || (way >= 8 && way <= 10))) throw const _Broken();
    var more = 0;
    final lead = b.take(8);
    if (lead >= 0xc0) {
      while (more < 8 && (lead & (0x80 >> more)) != 0) {
        more++;
      }
      more--;
      if (more > 5) throw const _Broken();
    } else if (lead >= 0x80) {
      throw const _Broken();
    }
    while (more-- > 0) {
      if ((b.take(8) & 0xc0) != 0x80) throw const _Broken();
    }
    if (b.take(16) + 1 != frames) throw const _Broken();
    final head = b.at >> 3;
    if (_crc8(bytes, head) != b.take(8)) throw const _Broken();
    if (_crc16(bytes, bytes.length - 2) != ((bytes[bytes.length - 2] << 8) | bytes[bytes.length - 1])) throw const _Broken();

    final first = Int32List(frames), second = Int32List(frames);
    _channel(b, first, way == 9 ? 17 : 16);
    _channel(b, second, way == 8 || way == 10 ? 17 : 16);
    b.toByte();
    if ((b.at >> 3) != bytes.length - 2) throw const _Broken();

    final out = Int16List(frames * 2);
    for (var i = 0; i < frames; i++) {
      var l = first[i], r = second[i];
      switch (way) {
        case 8:
          r = l - r;
        case 9:
          l = l + r;
        case 10:
          final sum = l * 2 + (r.isOdd ? 1 : 0);
          l = (sum + r) ~/ 2;
          r = (sum - r) ~/ 2;
      }
      if (l < -32768 || l > 32767 || r < -32768 || r > 32767) throw const _Broken();
      out[i * 2] = l;
      out[i * 2 + 1] = r;
    }
    return out;
  }

  static void _channel(_Bits b, Int32List x, int depth) {
    final n = x.length, type = b.take(8);
    if (type == 0x00) {
      x.fillRange(0, n, b.signed(depth));
      return;
    }
    if (type == 0x02) {
      for (var i = 0; i < n; i++) {
        x[i] = b.signed(depth);
      }
      return;
    }
    final order = (type >> 1) - 8;
    if (type.isOdd || order < 0 || order > 4) throw const _Broken();
    for (var i = 0; i < order; i++) {
      x[i] = b.signed(depth);
    }
    if (b.take(2) != 0) throw const _Broken();
    final parts = b.take(4), each = n >> parts;
    if (each <= order || (each << parts) != n) throw const _Broken();
    for (var q = 0; q < (1 << parts); q++) {
      final k = b.take(4);
      if (k == 15) throw const _Broken();
      for (var i = q == 0 ? order : q * each; i < (q + 1) * each; i++) {
        final u = (b.zeros(0x7fffff >> k) << k) | (k == 0 ? 0 : b.take(k));
        var v = u.isEven ? u >> 1 : -(u >> 1) - 1;
        switch (order) {
          case 1:
            v += x[i - 1];
          case 2:
            v += 2 * x[i - 1] - x[i - 2];
          case 3:
            v += 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3];
          case 4:
            v += 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4];
        }
        // What can't be a sample is broken, and is never let grow.
        if (v < -65536 || v > 65535) throw const _Broken();
        x[i] = v;
      }
    }
  }

  static final Uint8List _table8 = () {
    final t = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xff : (c << 1) & 0xff;
      }
      t[i] = c;
    }
    return t;
  }();

  static final Uint16List _table16 = () {
    final t = Uint16List(256);
    for (var i = 0; i < 256; i++) {
      var c = i << 8;
      for (var k = 0; k < 8; k++) {
        c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x8005) & 0xffff : (c << 1) & 0xffff;
      }
      t[i] = c;
    }
    return t;
  }();

  static int _crc8(Uint8List p, int n) {
    var c = 0;
    for (var i = 0; i < n; i++) {
      c = _table8[c ^ p[i]];
    }
    return c;
  }

  static int _crc16(Uint8List p, int n) {
    var c = 0;
    for (var i = 0; i < n; i++) {
      c = ((c << 8) & 0xff00) ^ _table16[(c >> 8) ^ p[i]];
    }
    return c;
  }
}

class _Broken implements Exception {
  const _Broken();
}

/// Bits read high first. Reading past the end is broken.
class _Bits {
  _Bits(this.p) : end = p.length * 8;
  final Uint8List p;
  final int end;
  int at = 0;

  /// The next [n], 1 to 24.
  int take(int n) {
    if (at + n > end) throw const _Broken();
    var v = 0, left = n;
    while (left > 0) {
      final room = 8 - (at & 7), some = left < room ? left : room;
      v = (v << some) | ((p[at >> 3] >> (room - some)) & ((1 << some) - 1));
      at += some;
      left -= some;
    }
    return v;
  }

  int signed(int n) {
    final v = take(n);
    return v >= (1 << (n - 1)) ? v - (1 << n) : v;
  }

  /// How many noughts there are before the next one, and no more than [most]; the one is taken too.
  int zeros(int most) {
    var n = 0;
    while (true) {
      if (at >= end) throw const _Broken();
      final room = 8 - (at & 7), rest = p[at >> 3] & ((1 << room) - 1);
      if (rest == 0) {
        n += room;
        at += room;
      } else {
        final skip = room - rest.bitLength;
        n += skip;
        at += skip + 1;
        if (n > most) throw const _Broken();
        return n;
      }
      if (n > most) throw const _Broken();
    }
  }

  void toByte() {
    if ((at & 7) != 0 && take(8 - (at & 7)) != 0) throw const _Broken();
  }
}
