/// One MP4 of several sound tracks made from several MP4s of one track each (lib/voice/recorder.dart, on Windows:
/// Media Foundation's writer makes a good AAC file of one voice, and is not relied on for more than one in a file;
/// Matt, 2026-11-21: "my friend is not able to see plugins added for recording calls on his pc").
///
/// The file made is `ftyp`, one `mdat` holding every input whole, one after another, then `moov`. Nothing is decoded or
/// encoded again: each input's sound track is taken as it is, given the next track number, and every chunk offset in
/// it moved by where its file now begins. An input's own movie box rides along inside the media, unread: a few
/// hundred bytes a track.
///
/// A recording with video (GMFB-42, lib/voice/recording_video.dart): the picture is a file of its own too, one video
/// track made by Media Foundation's H.264 writer (windows/runner/call_video.cpp), and it is put in the same way, as
/// the last track, after the voices.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Puts one-track MP4s together into one file of many tracks, by moving their boxes about: [merge] is all of it.
class Mp4Merge {
  /// Writes [out] with the first sound track of each of [inputs], in their order, and after them the first video
  /// track of [video] where one is named. True where the file has that picture: a [video] that can't be read (no
  /// file, no movie box, no video in it) is left out and the voices are made as they would be without it.
  static Future<bool> merge(List<String> inputs, String out, {String? video}) async {
    if (inputs.isEmpty) throw const FormatException('nothing to put together');
    // The picture's movie box, read before anything is written: null where it can't be used.
    Uint8List? pictureMoov;
    if (video != null) {
      try {
        final moov = await _moovOf(video, File(video).lengthSync());
        final has = _children(moov, 8).any((b) => _type(b) == 'trak' && _handler(b) == 'vide') && _children(moov, 8).any((b) => _type(b) == 'mvhd');
        if (has) pictureMoov = moov;
      } on FormatException {
        // Left out.
      } on FileSystemException {
        // Left out.
      }
    }
    final files = [...inputs, if (pictureMoov != null) video!];
    final lengths = [for (final p in files) File(p).lengthSync()];
    final media = lengths.fold<int>(0, (a, b) => a + b);
    final ftyp = _box('ftyp', [latin1.encode('isom'), _u32(0x200), latin1.encode('isomiso2mp41')]);
    // A 64-bit length for the media always: a long call of many voices is past four gigabytes only rarely, and a
    // player reads either.
    final mdatHead = Uint8List(16)
      ..buffer.asByteData().setUint32(0, 1)
      ..setRange(4, 8, latin1.encode('mdat'))
      ..buffer.asByteData().setUint64(8, 16 + media);
    var at = ftyp.length + mdatHead.length;
    final traks = <Uint8List>[];
    Uint8List? mvhd;
    var scale = 0;
    var longest = 0;
    for (var i = 0; i < inputs.length; i++) {
      final moov = await _moovOf(inputs[i], lengths[i]);
      final head = _children(moov, 8).where((b) => _type(b) == 'mvhd').firstOrNull;
      if (head == null) throw FormatException('no movie header in ${inputs[i]}');
      final its = _mvhdTimes(head);
      mvhd ??= head;
      if (scale == 0) scale = its.scale;
      final trak = _children(moov, 8).where((b) => _type(b) == 'trak' && _isSound(b)).firstOrNull;
      if (trak == null) throw FormatException('no sound in ${inputs[i]}');
      final made = _trak(trak, id: i + 1, shift: at, from: its.scale, to: scale);
      traks.add(made.box);
      if (made.duration > longest) longest = made.duration;
      at += lengths[i];
    }
    if (pictureMoov != null) {
      final its = _mvhdTimes(_children(pictureMoov, 8).firstWhere((b) => _type(b) == 'mvhd'));
      final trak = _children(pictureMoov, 8).firstWhere((b) => _type(b) == 'trak' && _handler(b) == 'vide');
      final made = _trak(trak, id: inputs.length + 1, shift: at, from: its.scale, to: scale, picture: true);
      traks.add(made.box);
      if (made.duration > longest) longest = made.duration;
    }
    final moov = _box('moov', [_mvhd(mvhd!, duration: longest, next: files.length + 1), ...traks]);
    final sink = await File(out).open(mode: FileMode.write);
    try {
      await sink.writeFrom(ftyp);
      await sink.writeFrom(mdatHead);
      for (final p in files) {
        final raf = await File(p).open();
        try {
          while (true) {
            final chunk = await raf.read(1 << 20);
            if (chunk.isEmpty) break;
            await sink.writeFrom(chunk);
          }
        } finally {
          await raf.close();
        }
      }
      await sink.writeFrom(moov);
    } finally {
      await sink.close();
    }
    return pictureMoov != null;
  }

  /// The movie box (`moov`) of the file at [path], found by stepping over its top-level boxes. Throws a
  /// [FormatException] where there is none, a box runs past the end, or the file is in fragments (`moof`).
  static Future<Uint8List> _moovOf(String path, int length) async {
    final raf = await File(path).open();
    try {
      var at = 0;
      while (at + 8 <= length) {
        await raf.setPosition(at);
        final h = await raf.read(16);
        if (h.length < 8) break;
        final d = ByteData.sublistView(h);
        var size = d.getUint32(0);
        final type = latin1.decode(h.sublist(4, 8));
        // A size of 1: the real one is the 64 bits after the type. Of 0: the box runs to the end of the file.
        if (size == 1 && h.length >= 16) {
          size = d.getUint64(8);
        } else if (size == 0) {
          size = length - at;
        }
        if (size < 8 || at + size > length) throw FormatException('a box ($type) runs past the end of $path');
        if (type == 'moof') throw FormatException('$path is in fragments');
        if (type == 'moov') {
          await raf.setPosition(at);
          return await raf.read(size);
        }
        at += size;
      }
    } finally {
      await raf.close();
    }
    throw FormatException('no movie box in $path');
  }

  /// Whether a track is sound: its handler says `soun`.
  static bool _isSound(Uint8List trak) => _handler(trak) == 'soun';

  /// What a track is, by its handler (`mdia` › `hdlr`): `soun`, `vide`; empty where it has none.
  static String _handler(Uint8List trak) {
    final mdia = _children(trak, 8).where((b) => _type(b) == 'mdia').firstOrNull;
    if (mdia == null) return '';
    final hdlr = _children(mdia, 8).where((b) => _type(b) == 'hdlr').firstOrNull;
    return hdlr != null && hdlr.length >= 20 ? latin1.decode(hdlr.sublist(16, 20)) : '';
  }

  /// A movie header's units a second and its length in them; version 1 keeps its times in 64 bits, so they sit
  /// further in.
  static ({int scale, int duration}) _mvhdTimes(Uint8List mvhd) {
    final d = ByteData.sublistView(mvhd);
    return mvhd[8] == 1 ? (scale: d.getUint32(28), duration: d.getUint64(32)) : (scale: d.getUint32(20), duration: d.getUint32(24));
  }

  /// The movie header with how long the longest track is and the next free track number.
  static Uint8List _mvhd(Uint8List mvhd, {required int duration, required int next}) {
    final out = Uint8List.fromList(mvhd);
    final d = ByteData.sublistView(out);
    if (out[8] == 1) {
      d.setUint64(32, duration);
    } else {
      d.setUint32(24, duration);
    }
    d.setUint32(out.length - 4, next);
    return out;
  }

  /// [trak] as track [id], its chunk offsets moved by [shift] and its length (in the movie's time, [from] a second)
  /// said in [to] a second.
  static ({Uint8List box, int duration}) _trak(Uint8List trak, {required int id, required int shift, required int from, required int to, bool picture = false}) {
    var duration = 0;
    int scaled(int v) => from == to || from == 0 ? v : (v * to / from).round();
    // Rebuilds the track box by box: the header takes the new number, the edit list the new time, the chunk offsets
    // the shift; the boxes that hold those are made again around them, and every other box is kept as it is.
    Uint8List walk(Uint8List box, List<String> path) {
      final type = _type(box);
      switch (type) {
        case 'tkhd':
          final out = Uint8List.fromList(box);
          final d = ByteData.sublistView(out);
          if (out[8] == 1) {
            d.setUint32(28, id);
            duration = scaled(d.getUint64(36));
            d.setUint64(36, duration);
          } else {
            d.setUint32(20, id);
            duration = scaled(d.getUint32(28));
            d.setUint32(28, duration);
          }
          return out;
        case 'elst':
          if (from == to) return box;
          final out = Uint8List.fromList(box);
          final d = ByteData.sublistView(out);
          final n = d.getUint32(12);
          final wide = out[8] == 1;
          for (var i = 0, at = 16; i < n && at + (wide ? 20 : 12) <= out.length; i++, at += wide ? 20 : 12) {
            if (wide) {
              d.setUint64(at, scaled(d.getUint64(at)));
            } else {
              d.setUint32(at, scaled(d.getUint32(at)));
            }
          }
          return out;
        case 'stco':
          // Written wide: where the file now begins may be past four gigabytes.
          final d = ByteData.sublistView(box);
          final n = d.getUint32(12);
          final body = Uint8List(8 + n * 8);
          final o = ByteData.sublistView(body);
          o.setUint32(4, n);
          for (var i = 0; i < n; i++) {
            o.setUint64(8 + i * 8, d.getUint32(16 + i * 4) + shift);
          }
          return _box('co64', [body]);
        case 'co64':
          final out = Uint8List.fromList(box);
          final d = ByteData.sublistView(out);
          final n = d.getUint32(12);
          for (var i = 0; i < n; i++) {
            d.setUint64(16 + i * 8, d.getUint64(16 + i * 8) + shift);
          }
          return out;
        case 'stsd' when picture:
          return _coloured(box);
        case 'trak' || 'mdia' || 'minf' || 'stbl' || 'edts':
          return _box(type, [for (final c in _children(box, 8)) walk(c, [...path, type])]);
        default:
          return box;
      }
    }

    final box = walk(trak, const []);
    return (box: box, duration: duration);
  }

  /// A video track's sample description with its colours said: BT.709, the narrow range, which is how the picture is
  /// made (windows/runner/call_video.cpp). Media Foundation's H.264 writer says nothing of them in the file, and a
  /// player then guesses: some take a 720-line video for BT.709 and some for BT.601, and with the wrong guess a green
  /// or a pink is plainly another colour. Said here in a `colr` box at the end of each entry that has none; anything
  /// that is not as expected is left as it is.
  static Uint8List _coloured(Uint8List stsd) {
    if (stsd.length < 16) return stsd;
    final d = ByteData.sublistView(stsd);
    final entries = <Uint8List>[];
    var at = 16;
    while (at + 8 <= stsd.length) {
      final size = d.getUint32(at);
      if (size < 8 || at + size > stsd.length) return stsd;
      final entry = Uint8List.sublistView(stsd, at, at + size);
      // A picture's entry: 8 bytes of box, 78 of what every picture's entry has, then boxes.
      final said = size < 86 || _children(entry, 86).any((b) => _type(b) == 'colr');
      if (said) {
        entries.add(entry);
      } else {
        // nclx: primaries 1, transfer 1 and matrix 1 (BT.709), then a byte whose top bit would say the full range.
        final colr = _box('colr', [latin1.encode('nclx'), const [0, 1, 0, 1, 0, 1, 0]]);
        final made = Uint8List(size + colr.length)
          ..setRange(0, size, entry)
          ..setRange(size, size + colr.length, colr);
        ByteData.sublistView(made).setUint32(0, made.length);
        entries.add(made);
      }
      at += size;
    }
    if (at != stsd.length) return stsd;
    return _box('stsd', [stsd.sublist(8, 16), ...entries]);
  }

  /// [v] as four bytes, big-endian, as every number in an MP4 is.
  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

  /// A box's four-letter type.
  static String _type(Uint8List box) => latin1.decode(box.sublist(4, 8));

  /// The boxes inside [box], from [from] bytes in.
  static Iterable<Uint8List> _children(Uint8List box, int from) sync* {
    var at = from;
    while (at + 8 <= box.length) {
      final size = ByteData.sublistView(box).getUint32(at);
      if (size < 8 || at + size > box.length) break;
      yield Uint8List.sublistView(box, at, at + size);
      at += size;
    }
  }

  /// A box of [type] holding [body]: its length, its type, then the parts one after another.
  static Uint8List _box(String type, List<List<int>> body) {
    final length = body.fold<int>(8, (a, b) => a + b.length);
    final out = BytesBuilder(copy: false)
      ..add(_u32(length))
      ..add(latin1.encode(type));
    for (final b in body) {
      out.add(b);
    }
    return out.takeBytes();
  }
}
