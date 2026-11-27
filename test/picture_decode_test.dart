import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/kit/picture_decode.dart';

/// docs/performance-audit.md, finding 6.
void main() {
  test('a base64 picture is the same bytes each time it is asked for, so the image cache knows it', () {
    final b64 = base64Encode(List.generate(300, (i) => i % 251));
    final first = pictureBytes(b64);
    expect(first, isNotNull);
    expect(identical(first, pictureBytes(b64)), isTrue);
    expect(MemoryImage(first!), MemoryImage(pictureBytes(b64)!), reason: 'one key in the image cache, where each build made a new one');
    expect(pictureBytes('not base64 !!'), isNull);
    // The newest are kept: after many others, the first is made again (and is equal, if not the same).
    for (var i = 0; i < 200; i++) {
      pictureBytes(base64Encode([i, i + 1, i + 2]));
    }
    expect(pictureBytes(b64), first);
  });

  test('a file\'s bytes are read once while the file stands as it was, and again when it changes', () {
    final dir = Directory.systemTemp.createTempSync('picture-bytes');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/a.png')..writeAsBytesSync([1, 2, 3]);
    final first = fileBytes(f.path);
    expect(first, [1, 2, 3]);
    expect(identical(first, fileBytes(f.path)), isTrue);
    f.writeAsBytesSync([4, 5, 6, 7]);
    expect(fileBytes(f.path), [4, 5, 6, 7]);
    expect(fileBytes('${dir.path}/none.png'), isNull);
  });

  testWidgets('a face is unpacked at its own size on this screen, not the photograph\'s', (tester) async {
    late int face, fill;
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(400, 800), devicePixelRatio: 3),
      child: Builder(builder: (context) {
        face = faceDecodeWidth(context, 40);
        fill = fillDecodeWidth(context);
        return const SizedBox();
      }),
    ));
    expect(face, 240);
    expect(fill, 1200);
  });
}
