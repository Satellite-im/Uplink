import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/ui/common.dart';
import 'package:ghost_messaging/ui/composer_box.dart';

import 'support/list_harness.dart';

final typingNow = ValueNotifier(false);

class _Box extends StatelessWidget {
  const _Box();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(valueListenable: typingNow, builder: (context, typing, _) => _inner(typing));

  Widget _inner(bool typing) {
    final send = IconTap(icon: Lucide.arrowUp, label: 'Send', filled: true, size: 16, box: 36, onPressed: typing ? () {} : null);
    final mic = IconTap(icon: Lucide.mic, label: 'Mic', size: 19, box: 36, onPressed: () {});
    final sticker = IconTap(icon: Lucide.sticker, label: 'Stickers', size: 19, box: 36, onPressed: () {});
    return RepaintBoundary(
      key: const ValueKey('shot'),
      child: Container(
        color: const Color(0xFF000000),
        height: 130,
        alignment: Alignment.bottomCenter,
        child: ComposerBox(
          typing: typing,
          plus: IconTap(icon: Lucide.plus, label: 'Plus', size: 19, box: 36, onPressed: () {}),
          ends: typing ? [send] : [sticker, const SizedBox(width: 4), mic],
          below: [mic, send],
          field: SizedBox(height: 36, child: Align(alignment: Alignment.centerLeft, child: Text(typing ? 'On my way' : 'Text message', style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 16)))),
        ),
      ),
    );
  }
}

void main() {
  // Matt, 2026-11-15: "The animation on the compose is a bit weird thr buttons don't slide straight down they move out
  // first": the composer from empty to typing, a frame every 30 ms, drawn into one picture to be looked at.
  testWidgets('the composer\'s frames from empty to typing, drawn top to bottom', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Align(alignment: Alignment.bottomCenter, child: _Box()), AppState());
    await tester.pump(const Duration(milliseconds: 400));
    final shots = <ui.Image>[];
    Future<void> grab() async {
      final ro = tester.renderObject(find.byKey(const ValueKey('shot'))) as RenderRepaintBoundary;
      shots.add(await tester.runAsync(() => ro.toImage(pixelRatio: 1)) as ui.Image);
    }
    await grab();
    typingNow.value = true;
    for (final ms in [0, 30, 30, 30, 30, 30, 120]) {
      await tester.pump(Duration(milliseconds: ms));
      await grab();
    }
    final w = shots.first.width, h = shots.first.height;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    for (final (i, s) in shots.indexed) {
      c.drawImage(s, Offset(0, (h + 4) * i.toDouble()), Paint());
    }
    final img = await tester.runAsync(() => rec.endRecording().toImage(w, (h + 4) * shots.length));
    final png = await tester.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
    // A picture of the frames, top to bottom, kept with the other screens (test/shots/22-composer-frames.png).
    File('test/shots/22-composer-frames.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
