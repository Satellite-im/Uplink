// A Files space drawn in every look (test/themes_test.dart): its list on a phone and a wide window, its grid, files
// going up, an empty one, and a picture opened. Matt, 2026-11-17: "add full functionality for filesharing in a space
// when the space is designated a Files Space ... use iconography and color where possible".
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show NetSigner;
import 'package:ghost_messaging/ui/files_space/file_preview.dart';
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'themes_test.dart' show ThemeScreen;

const _space = VoiceChannel(seed: '9999999999999999999999999999999999999999999999999999999999999999', name: 'Drop box', kind: SpaceKind.files);
const _empty = VoiceChannel(seed: '9898989898989898989898989898989898989898989898989898989898989898', name: 'Hand-ins', kind: SpaceKind.files);

final _dir = Directory.systemTemp.createTempSync('ghost-files-shots');
final _store = FilesStore.forTest(base: null, signer: _NoSigner(), data: _dir);

final _now = DateTime(2026, 11, 17, 15, 30);

SpaceFile _file(int n, String name, int size, String by, Duration ago, {String? folder, Uint8List? thumb}) => SpaceFile(
      id: n.toRadixString(16).padLeft(32, '0'),
      name: name,
      size: size,
      mime: FileKind.mimeOf(name),
      sha: '',
      key: Uint8List(32),
      prefix: Uint8List(8),
      by: 'id$by',
      byName: by,
      at: _now.subtract(ago).millisecondsSinceEpoch,
      folder: folder,
      thumb: thumb,
    );

final _sunset = png(96, 64, (x, y) => (255 - y * 2, 120 + x, 90 + y * 2));
final _sea = png(96, 64, (x, y) => (40 + x, 110 + y, 200 - y));
final _big = png(360, 240, (x, y) => (255 - y ~/ 2, 100 + x ~/ 3, 80 + y ~/ 2));

final _files = [
  _file(1, 'Sunset at the pier.jpg', 3200000, 'Maya', const Duration(minutes: 12), folder: 'Trip', thumb: _sunset),
  _file(2, 'Q3 report.pdf', 2100000, 'Sam', const Duration(hours: 3)),
  _file(3, 'budget 2027.xlsx', 84000, 'Priya', const Duration(hours: 5), folder: 'Work'),
  _file(4, 'Harbour.jpg', 2800000, 'Maya', const Duration(hours: 6), folder: 'Trip', thumb: _sea),
  _file(5, 'demo.mov', 128000000, 'Sam', const Duration(days: 1)),
  _file(6, 'voice note.m4a', 1400000, 'Leo', const Duration(days: 1, hours: 2)),
  _file(7, 'trip photos.zip', 48000000, 'Maya', const Duration(days: 2), folder: 'Trip'),
  _file(8, 'main.dart', 12000, 'Priya', const Duration(days: 3), folder: 'Work'),
  _file(9, 'pitch.pptx', 6400000, 'Leo', const Duration(days: 4), folder: 'Work'),
  _file(10, 'contract.docx', 210000, 'Sam', const Duration(days: 5)),
  _file(11, 'notes.md', 3000, 'Leo', const Duration(days: 6)),
  _file(12, 'firmware.bin', 900000, 'Priya', const Duration(days: 9)),
];

void _put() {
  // Each screen starts with nothing going up: a screen's `after` runs only once its look's screens are all drawn.
  _stopGoing();
  _store.put(_space, _files, folders: {'Trip', 'Work'}, info: FilesInfo(used: _files.fold(0, (n, f) => n + f.size), quota: 2 << 30, maxFile: 2 << 30));
  _store.put(_empty, const [], info: const FilesInfo(quota: 2 << 30));
  // The picture opened is on this device already.
  final at = File(_store.cachedPath(_files.first))..parent.createSync(recursive: true);
  if (!at.existsSync()) at.writeAsBytesSync(_big);
  final pdf = File(_store.cachedPath(_files[1]))..parent.createSync(recursive: true);
  if (!pdf.existsSync()) pdf.writeAsStringSync('%PDF-1.4');
}

void _going() {
  _put();
  _store.putTransfer(Transfer.shown(space: _space, name: 'Band rehearsal.mp4', size: 84000000, done: 34000000));
  _store.putTransfer(Transfer.shown(space: _space, name: 'slides final final.key', size: 9000000, state: TransferState.waiting, error: 'Waiting for the connection'));
  _store.putTransfer(Transfer.shown(space: _space, name: 'raw footage.zip', size: 4000000000, state: TransferState.failed, error: 'Too big: files can be up to 2.1 GB each.', retryable: false));
  // An upload left part way that nothing here can pick up (FilesStore.unfinished): Sam's, three hours quiet.
  _store.put(_space, _files, folders: {'Trip', 'Work'}, info: FilesInfo(used: _files.fold(0, (n, f) => n + f.size) + 26000000000, quota: 50000000000, maxFile: 30000000000, parts: [
    FilesPart(id: 'f' * 32, by: 'idSam', size: 26000000000, have: 12300000000, at: DateTime.now().subtract(const Duration(hours: 3))),
  ]));
}

void _stopGoing() {
  for (final t in [..._store.transfers]) {
    _store.transfers.remove(t);
  }
}

final filesThemeScreens = <ThemeScreen>[
  ThemeScreen('files', () => FilesSpaceScreen(channel: _space, store: _store), before: _put),
  ThemeScreen('files-grid', () => FilesSpaceScreen(channel: _space, store: _store), before: _put, choices: (s) => s.set('files_view', 'grid')),
  ThemeScreen('files-wide', () => FilesSpaceScreen(channel: _space, store: _store), size: ThemeScreen.wide, before: _put),
  ThemeScreen('files-uploading', () => FilesSpaceScreen(channel: _space, store: _store), before: _going, after: _stopGoing),
  ThemeScreen('files-empty', () => FilesSpaceScreen(channel: _empty, store: _store), before: _put),
  ThemeScreen('files-preview', () => FilePreviewScreen(channel: _space, file: _files.first, store: _store), before: _put),
  ThemeScreen('files-preview-pdf', () => FilePreviewScreen(channel: _space, file: _files[1], store: _store), before: _put),
];

/// A picture to draw: [w] by [h], each pixel's colour from [rgb], as a PNG made here (no codec needed to make one).
Uint8List png(int w, int h, (int, int, int) Function(int x, int y) rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      final (r, g, b) = rgb(x, y);
      raw
        ..addByte(r.clamp(0, 255))
        ..addByte(g.clamp(0, 255))
        ..addByte(b.clamp(0, 255));
    }
  }
  final out = BytesBuilder()..add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(_be(data.length))
      ..add(body)
      ..add(_be(_crc(body)));
  }

  chunk('IHDR', [..._be(w), ..._be(h), 8, 2, 0, 0, 0]);
  chunk('IDAT', ZLibCodec().encode(raw.takeBytes()));
  chunk('IEND', const []);
  return out.takeBytes();
}

List<int> _be(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

int _crc(List<int> bytes) {
  var c = 0xffffffff;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
    }
  }
  return c ^ 0xffffffff;
}

class _NoSigner implements NetSigner {
  @override
  String get id => 'shots';
  @override
  Uint8List get publicKey => Uint8List(33);
  @override
  Future<Uint8List> sign(List<int> message) async => Uint8List(64);
}
