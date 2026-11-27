import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/poof.dart';

import 'support/list_harness.dart';

final _gone = ValueNotifier(false);

/// A deleted message's puff (lib/ui/poof.dart; Matt, 2026-11-15: "show a poof animation when one is deleted"): the
/// bubble shrinks and fades, puffs burst out, its room closes, and only then is it taken away.
void main() {
  testWidgets('a bubble goes in a puff, then its room closes and it is taken away', (tester) async {
    final sheet = await loadSheet(tester);
    var done = 0;
    await pumpScreen(
      tester,
      sheet,
      Center(
        child: RepaintBoundary(
          key: const ValueKey('shot'),
          child: Container(
            width: 412,
            color: const Color(0xFF000000),
            padding: const EdgeInsets.symmetric(vertical: 40),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ValueListenableBuilder<bool>(
                valueListenable: _gone,
                builder: (context, gone, _) => Poof(
                  gone: gone,
                  side: AxisDirection.right,
                  onDone: () => done++,
                  // Your own, at the right of a row the width of the screen, as a conversation has it.
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(color: const Color(0xFF0A84FF), borderRadius: BorderRadius.circular(18)),
                    child: const Text('See you at 7', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 16)),
                  ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
      AppState(),
    );
    final height = tester.getSize(find.byType(Poof)).height;
    final shots = <ui.Image>[];
    Future<void> grab() async {
      final ro = tester.renderObject(find.byKey(const ValueKey('shot'))) as RenderRepaintBoundary;
      shots.add(await tester.runAsync(() => ro.toImage(pixelRatio: 1)) as ui.Image);
    }

    await grab();
    _gone.value = true;
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 70));
      await grab();
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(done, 1, reason: 'taken away once the puff is over');
    expect(tester.getSize(find.byType(Poof)).height, lessThan(height * 0.1), reason: 'its room closed');
    // The frames, top to bottom, kept with the other pictures (test/shots/23-poof-frames.png).
    final w = shots.first.width, h = shots.first.height;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    for (final (i, s) in shots.indexed) {
      c.drawImage(s, Offset(0, h * i.toDouble()), Paint());
    }
    final img = await tester.runAsync(() => rec.endRecording().toImage(w, h * shots.length));
    final png = await tester.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
    File('test/shots/23-poof-frames.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
