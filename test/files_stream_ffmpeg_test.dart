// FFmpeg's own HTTP reader (the one libmpv plays http addresses with, on the Mac and Windows) against the loopback
// server of lib/files/file_stream.dart (Matt, 2026-11-18: "would it be possible to setup streaming and buffering of
// the file?"): an MKV served as it comes down is probed, and played from the middle (a seek, by Range). Opt in, as it
// needs ffmpeg on the machine: STREAM_FFMPEG=/path/to/clip.mkv flutter test test/files_stream_ffmpeg_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/files/file_stream.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';

void main() {
  final clip = Platform.environment['STREAM_FFMPEG'];
  test('ffprobe and ffmpeg read an MKV from the stream, from the start and from the middle', () async {
    final dir = await Directory.systemTemp.createTemp('ghost-stream-ffmpeg');
    final data = File(clip!).readAsBytesSync();
    final key = NetCrypto.randomBytes(32), prefix = NetCrypto.randomBytes(8);
    const id = '00112233445566778899aabbccddeeff';
    final sealed = FileSeal.sealRun(SealRun(key: key, prefix: prefix, fileId: id, size: data.length, first: 0, plain: data));
    final f = SpaceFile(id: id, name: 'clip.mkv', size: data.length, mime: 'video/x-matroska', sha: NetCrypto.hex(NetCrypto.sha256(data)), key: key, prefix: prefix, by: 'x', byName: 'x', at: 0);
    final asked = <String>[];
    final s = FileStream(
      file: f,
      cacheDir: Directory('${dir.path}/cache'),
      assembledPath: '${dir.path}/cache/$id/clip.mkv',
      // Two chunks a request and nothing ahead, so a 2.6 MB clip is many requests and a seek skips some.
      readAhead: 0,
      runChunks: 2,
      read: (a, z) async {
        asked.add('$a-$z');
        return Stream.value(Uint8List.sublistView(sealed, a, z + 1));
      },
    );
    try {
      final url = await s.open();
      final probe = await Process.run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration:stream=codec_name', '-of', 'csv=p=0', url]);
      expect(probe.exitCode, 0, reason: '${probe.stderr}');
      expect('${probe.stdout}', contains('h264'));
      expect(double.parse('${probe.stdout}'.trim().split('\n').last), closeTo(20, 0.5));
      final seek = await Process.run('ffmpeg', ['-v', 'error', '-ss', '14', '-i', url, '-t', '2', '-f', 'null', '-']);
      expect(seek.exitCode, 0, reason: '${seek.stderr}');
      // ignore: avoid_print
      print('relay asked for ${asked.length} runs; ${s.haveBytes} of ${data.length} bytes held');
      // An open-ended read goes on until the reader lets it go, so a short clip may all come; nothing comes twice.
      expect(asked.toSet().length, asked.length, reason: 'no run asked for twice: $asked');
    } finally {
      s.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await dir.delete(recursive: true);
    }
  }, skip: clip == null ? 'set STREAM_FFMPEG to an MKV to run it' : false);
}
