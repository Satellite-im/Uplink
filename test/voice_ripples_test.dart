import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/ripple_avatar.dart';

/// The rings that go out from whoever is talking, round a face and round a tile (Matt, 2026-11-25: "make sure everywhere
/// voice activity is logged uses the ripple animation").
void main() {
  for (final corner in [null, 0.0, 18.0]) {
    testWidgets('rings while loud, gone and at rest once quiet, muted or not shown (corner $corner)', (tester) async {
      var strength = -1.0;
      Future<void> at(double level, {bool muted = false}) => tester.pumpWidget(Center(
            child: VoiceRipples(level: level, muted: muted, reach: 10, corner: corner, color: const Color(0xFF00AA00), builder: (_, s) {
              strength = s;
              return const SizedBox(width: 60, height: 40);
            }),
          ));
      await at(0);
      await tester.pump(const Duration(milliseconds: 100));
      expect(strength, 0);
      expect(tester.hasRunningAnimations, isFalse);
      await at(0.6);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(strength, greaterThan(0.5));
      expect(tester.hasRunningAnimations, isTrue);
      // Takes no room of its own.
      expect(tester.getSize(find.byType(VoiceRipples)), const Size(60, 40));
      await at(0.6, muted: true);
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(strength, lessThan(0.02));
      expect(tester.hasRunningAnimations, isFalse, reason: 'nothing runs once quiet');
      expect(tester.takeException(), isNull);
    });
  }
}
