import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/paste_images.dart';

/// A picture pasted on a computer goes to the message field the cursor is in, and to none that can take no more (Matt,
/// 2026-11-20: "pasting a screenshot into the compose bar isn't adding attachements"; lib/ui/paste_images.dart).
void main() {
  testWidgets('a pasted picture goes to the field with the cursor, not to a full one, nor to none', (tester) async {
    final a = FocusNode(), b = FocusNode();
    final toA = <String>[], toB = <String>[];
    var bFull = false;
    late StateSetter set;
    Widget field(FocusNode f, TextEditingController c) => EditableText(controller: c, focusNode: f, style: const TextStyle(fontSize: 14), cursorColor: const Color(0xFF000000), backgroundCursorColor: const Color(0xFF888888));
    final ca = TextEditingController(), cb = TextEditingController();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: StatefulBuilder(builder: (context, s) {
          set = s;
          return Column(children: [
            PasteImages(focusNode: a, onImage: toA.add, child: field(a, ca)),
            PasteImages(focusNode: b, enabled: !bFull, onImage: toB.add, child: field(b, cb)),
          ]);
        }),
      ),
    ));
    expect(PasteImages.pastedForTest('/tmp/none.png'), isFalse, reason: 'no field has the cursor');
    a.requestFocus();
    await tester.pump();
    expect(PasteImages.pastedForTest('/tmp/one.png'), isTrue);
    b.requestFocus();
    await tester.pump();
    PasteImages.pastedForTest('/tmp/two.png');
    expect(toA, ['/tmp/one.png']);
    expect(toB, ['/tmp/two.png']);
    set(() => bFull = true);
    await tester.pump();
    expect(PasteImages.pastedForTest('/tmp/three.png'), isFalse, reason: 'the field with the cursor holds all it may');
    expect(toB, ['/tmp/two.png']);
  });
}
