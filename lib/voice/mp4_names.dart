/// Names the tracks of an MP4 after it is written (lib/voice/recorder.dart: neither Android's MediaMuxer nor Apple's
/// AVAssetWriter can name a track), and says which one a player plays by itself.
///
/// For each track, in order: its name is written three ways, since players disagree on where it is read from:
/// `udta/name` (VLC, FFmpeg's "name"), `udta/©nam` (FFmpeg's and so libmpv's "title", the app's own player) and the
/// handler's name (`mdia/hdlr`). Every audio track is put in one alternate group, and only the first is enabled: a
/// player that plays one track plays the mix (Apple asks for one enabled track a group). A track of video (GMFB-42:
/// the call's cameras and screens, after the voices) is left enabled and in no group, so it plays beside the mix.
///
/// The movie box is rebuilt in memory; where it comes before the media (a "fast start" file) every chunk offset is
/// moved by however much it grew. The media itself is never read.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Static only: [apply] for a file, [rename] for a movie box in memory.
class Mp4Names {
  Mp4Names._();

  /// Names [path]'s tracks [names], in their order; a track past the list keeps its name. Throws [FormatException] on a
  /// file that is not an MP4 it can read.
  static Future<void> apply(String path, List<String> names) async {
    final file = File(path);
    final raf = await file.open(mode: FileMode.append);
    try {
      final length = await raf.length();
      final boxes = await _topLevel(raf, length);
      final moov = boxes.where((b) => b.type == 'moov').firstOrNull;
      if (moov == null) throw const FormatException('no movie box');
      await raf.setPosition(moov.start);
      final old = await raf.read(moov.size);
      // With the media after the movie box, a longer movie box pushes the media along: the box is made once to learn
      // how much it grows, then again with every chunk offset moved by that much.
      final before = boxes.any((b) => b.type == 'mdat' && b.start > moov.start);
      var made = rename(old, names, shift: 0);
      if (before) made = rename(old, names, shift: made.length - old.length);
      final after = boxes.where((b) => b.start > moov.start).toList();
      if (!before && after.isEmpty) {
        // The usual case: the movie box last. Cut it off and write the new one in its place.
        await raf.truncate(moov.start);
        await raf.setPosition(moov.start);
        await raf.writeFrom(made);
        return;
      }
      // Anything after the movie box is written again behind the new one.
      final tmp = File('$path.naming');
      final out = await tmp.open(mode: FileMode.write);
      try {
        for (final b in boxes) {
          if (b.type == 'moov') {
            await out.writeFrom(made);
            continue;
          }
          await raf.setPosition(b.start);
          var left = b.size;
          while (left > 0) {
            final chunk = await raf.read(left > 1 << 20 ? 1 << 20 : left);
            if (chunk.isEmpty) break;
            await out.writeFrom(chunk);
            left -= chunk.length;
          }
        }
      } finally {
        await out.close();
      }
      await raf.close();
      await tmp.rename(path);
      return;
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  /// The tracks of [path], in order: each one's name as [apply] wrote it (`udta/name`, else `udta/©nam`, else the
  /// handler's name) and what it carries (`soun` for sound, `vide` for a picture). How a file is known for a call's
  /// recording again once it has left the device that made it (lib/voice/recording_playback.dart: recordingIn; Matt,
  /// 2026-11-23: "i want to see the mixer when viewing sounds recordings but it just loads the media player view").
  /// Only the movie box is read. Throws [FormatException] on a file that is not an MP4 it can read.
  static Future<List<({String name, String kind})>> tracks(String path) async {
    final raf = await File(path).open();
    try {
      final boxes = await _topLevel(raf, await raf.length());
      final moov = boxes.where((b) => b.type == 'moov').firstOrNull;
      // A movie box is a few kilobytes a track; one past 64 MB is not a recording's, and is not read whole.
      if (moov == null || moov.size > 64 << 20) throw const FormatException('no movie box');
      await raf.setPosition(moov.start);
      return read(await raf.read(moov.size));
    } finally {
      await raf.close();
    }
  }

  /// [tracks] of a movie box in memory.
  static List<({String name, String kind})> read(Uint8List moov) {
    String words(Uint8List bytes) => utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '').trim();
    final out = <({String name, String kind})>[];
    for (final trak in _children(moov, 8)) {
      if (_type(trak) != 'trak') continue;
      String? name, title, handler;
      var kind = '';
      for (final c in _children(trak, 8)) {
        if (_type(c) == 'mdia') {
          for (final m in _children(c, 8)) {
            // The handler: version and flags, pre_defined, its type at byte 16, twelve reserved bytes, then its name.
            if (_type(m) != 'hdlr' || m.length < 32) continue;
            kind = latin1.decode(m.sublist(16, 20));
            handler = words(m.sublist(32));
          }
        } else if (_type(c) == 'udta') {
          for (final u in _children(c, 8)) {
            if (_type(u) == 'name') name = words(u.sublist(8));
            // Two bytes of length and two of language before the words (_udta).
            if (_type(u) == '©nam' && u.length >= 12) title = words(u.sublist(12));
          }
        }
      }
      out.add((name: name ?? title ?? handler ?? '', kind: kind));
    }
    return out;
  }

  /// The movie box [moov] with its tracks named [names], every chunk offset moved by [shift].
  static Uint8List rename(Uint8List moov, List<String> names, {int shift = 0}) {
    var track = 0;
    Uint8List walk(Uint8List box) {
      final type = _type(box);
      switch (type) {
        case 'moov':
        case 'mdia':
        case 'minf':
        case 'stbl':
          return _box(type, [for (final c in _children(box, 8)) walk(c)]);
        case 'trak':
          final i = track++;
          final name = i < names.length ? names[i] : null;
          final kids = [for (final c in _children(box, 8)) c];
          // What it carries, from its handler: only sound is one of the voices to choose between.
          var sound = true;
          for (final c in kids) {
            if (_type(c) != 'mdia') continue;
            for (final m in _children(c, 8)) {
              if (_type(m) == 'hdlr' && m.length >= 20) sound = latin1.decode(m.sublist(16, 20)) == 'soun';
            }
          }
          final out = <Uint8List>[];
          var hadUdta = false;
          for (final c in kids) {
            final t = _type(c);
            if (t == 'tkhd') {
              // A picture's header is left as it was written: enabled, in no group.
              out.add(sound ? _tkhd(c, first: i == 0) : c);
            } else if (t == 'mdia') {
              out.add(_box('mdia', [for (final m in _children(c, 8)) _type(m) == 'hdlr' && name != null ? _hdlr(m, name) : walk(m)]));
            } else if (t == 'udta') {
              hadUdta = true;
              out.add(name == null ? c : _udta([for (final u in _children(c, 8)) if (_type(u) != 'name' && _type(u) != '©nam') u], name));
            } else {
              out.add(c);
            }
          }
          if (!hadUdta && name != null) out.add(_udta(const [], name));
          return _box('trak', out);
        // Chunk offsets, 32-bit (stco) or 64-bit (co64): a count at byte 12, then the offsets from byte 16.
        case 'stco':
          if (shift == 0) return box;
          final b = Uint8List.fromList(box);
          final d = ByteData.sublistView(b);
          final n = d.getUint32(12);
          for (var k = 0; k < n; k++) {
            d.setUint32(16 + 4 * k, d.getUint32(16 + 4 * k) + shift);
          }
          return b;
        case 'co64':
          if (shift == 0) return box;
          final b = Uint8List.fromList(box);
          final d = ByteData.sublistView(b);
          final n = d.getUint32(12);
          for (var k = 0; k < n; k++) {
            d.setUint64(16 + 8 * k, d.getUint64(16 + 8 * k) + shift);
          }
          return b;
        default:
          return box;
      }
    }

    return walk(moov);
  }

  /// A track's header, enabled only for the first track, every track in alternate group 1.
  static Uint8List _tkhd(Uint8List box, {required bool first}) {
    final b = Uint8List.fromList(box);
    final d = ByteData.sublistView(b);
    final version = b[8];
    // Flags: enabled 1, in the movie 2, in a preview 4.
    final flags = first ? 0x7 : 0x6;
    b[9] = 0;
    b[10] = 0;
    b[11] = flags;
    // Where alternate_group is: after the header, the times and ids (64-bit in version 1), the reserved bytes and the
    // layer.
    final group = version == 1 ? 8 + 4 + 8 + 8 + 4 + 4 + 8 + 8 + 2 : 8 + 4 + 4 + 4 + 4 + 4 + 4 + 8 + 2;
    if (group + 2 <= b.length) d.setUint16(group, 1);
    return b;
  }

  /// The handler box with its name [name] (the type and the rest as they were).
  static Uint8List _hdlr(Uint8List box, String name) {
    // Version and flags, pre_defined, the handler type and twelve reserved bytes: 24 bytes after the header.
    if (box.length < 32) return box;
    final head = box.sublist(8, 32);
    return _box('hdlr', [head, Uint8List.fromList([...utf8.encode(name), 0])]);
  }

  /// A user-data box with [keep] and the name boxes for [name].
  static Uint8List _udta(List<Uint8List> keep, String name) {
    final words = utf8.encode(name);
    final nam = BytesBuilder()
      ..add(_u16(words.length))
      // The language: 0x55c4 is "und", undetermined.
      ..add(_u16(0x55c4))
      ..add(words);
    return _box('udta', [...keep, _box('name', [Uint8List.fromList(words)]), _box('©nam', [nam.toBytes()])]);
  }

  /// [v] as two bytes, big-endian as everything in an MP4 is.
  static Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);

  /// A box's four-letter type, which follows its four-byte size.
  static String _type(Uint8List box) => latin1.decode(box.sublist(4, 8));

  /// The boxes inside [box], from [from] (after its header and, for a full box, its version and flags).
  static Iterable<Uint8List> _children(Uint8List box, int from) sync* {
    final d = ByteData.sublistView(box);
    var at = from;
    while (at + 8 <= box.length) {
      var size = d.getUint32(at);
      var header = 8;
      // A size of 1 means the real size follows the type as 64 bits; 0 means the box runs to its parent's end.
      if (size == 1) {
        size = d.getUint64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = box.length - at;
      }
      if (size < header || at + size > box.length) throw const FormatException('a box runs past its parent');
      yield Uint8List.sublistView(box, at, at + size);
      at += size;
    }
  }

  /// A box of [type] holding [body]: its size, its type, then the parts in order.
  static Uint8List _box(String type, List<Uint8List> body) {
    final size = 8 + body.fold<int>(0, (n, b) => n + b.length);
    final out = BytesBuilder(copy: false)
      ..add(Uint8List(4)..buffer.asByteData().setUint32(0, size))
      ..add(latin1.encode(type));
    for (final b in body) {
      out.add(b);
    }
    return out.toBytes();
  }

  /// The file's outermost boxes, by their headers alone: each one's type, where it starts and how long it is.
  static Future<List<({String type, int start, int size})>> _topLevel(RandomAccessFile raf, int length) async {
    final out = <({String type, int start, int size})>[];
    var at = 0;
    while (at + 8 <= length) {
      await raf.setPosition(at);
      final h = await raf.read(16);
      final d = ByteData.sublistView(h);
      var size = d.getUint32(0);
      final type = latin1.decode(h.sublist(4, 8));
      if (size == 1) {
        size = d.getUint64(8);
      } else if (size == 0) {
        size = length - at;
      }
      if (size < 8 || at + size > length) throw FormatException('a top-level box ($type) runs past the file');
      out.add((type: type, start: at, size: size));
      at += size;
    }
    return out;
  }
}
