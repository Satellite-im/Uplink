import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/file_kinds.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/files/local_thumbs.dart';
import 'package:ghost_messaging/files/video_frame.dart';
import 'package:ghost_messaging/ui/files_space/file_badge.dart';

import 'support/list_harness.dart';

/// Previews in a Files space's list and grid (Matt, 2026-11-18: "Please make the files have previews in the files page
/// in the app like gifs images and videos having a frame from the first minute of the video").
void main() {
  Future<Uint8List> png(int w, int h) async {
    final r = ui.PictureRecorder();
    ui.Canvas(r).drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF3366CC));
    final img = await r.endRecording().toImage(w, h);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  SpaceFile file(String name, {Uint8List? thumb}) => SpaceFile(id: '0' * 31 + '1', name: name, size: 1000, mime: FileKind.mimeOf(name), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'maya', byName: 'Maya', at: 1, thumb: thumb);

  test('a video\'s frame is a tenth of the way in, at least a second, never past the first minute', () {
    expect(frameAt(const Duration(seconds: 150)), const Duration(seconds: 15));
    expect(frameAt(const Duration(minutes: 45)), const Duration(minutes: 1));
    expect(frameAt(const Duration(seconds: 5)), const Duration(seconds: 1));
    expect(frameAt(const Duration(milliseconds: 1200)), const Duration(milliseconds: 600));
    expect(frameAt(Duration.zero), const Duration(seconds: 1));
  });

  test('a big picture is made small: no more than 160 across and 18 KB', () async {
    final made = (await FilesStore.thumbnailOf(await png(1600, 900)))!;
    expect((made.width, made.height), (1600, 900));
    expect(made.png.length, lessThanOrEqualTo(18 * 1024));
    final codec = await ui.instantiateImageCodec(made.png);
    final f = await codec.getNextFrame();
    expect(f.image.width, lessThanOrEqualTo(160));
  });

  testWidgets('a picture shows its picture; a video its frame with a play mark; a file without one its kind\'s mark', (tester) async {
    final thumb = (await tester.runAsync(() => png(160, 90)))!;
    final sheet = await loadSheet(tester);
    LocalThumbs.instance.reset();
    await pumpScreen(
      tester,
      sheet,
      Column(children: [
        FileFace(key: const ValueKey('photo'), file: file('beach.jpg', thumb: thumb)),
        FileFace(key: const ValueKey('video'), file: file('trip.mp4', thumb: thumb)),
        FileFace(key: const ValueKey('doc'), file: file('notes.pdf')),
        SizedBox(width: 200, height: 200, child: FileTilePicture(key: const ValueKey('tile'), file: file('trip.mkv', thumb: thumb))),
      ]),
      AppState(),
    );
    expect(find.descendant(of: find.byKey(const ValueKey('photo')), matching: find.byType(Image)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('photo')), matching: find.byKey(const ValueKey('file-video-mark'))), findsNothing);
    expect(find.descendant(of: find.byKey(const ValueKey('video')), matching: find.byKey(const ValueKey('file-video-mark'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('tile')), matching: find.byKey(const ValueKey('file-video-mark'))), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('doc')), matching: find.byType(FileBadge)), findsOneWidget);
  });
}
