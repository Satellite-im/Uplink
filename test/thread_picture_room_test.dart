import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:image/image.dart' as img;

import 'support/list_harness.dart';

/// GMFB-73 (@kevin, Android 0.12.47: "When an image is present on mobile scrolling down seems to loop or jitter"). A
/// picture scrolled away and come back to was a grey square, then nothing while it was decoded, then its own shape:
/// three heights in a list held from its foot, so what was above it jumped. It keeps the room it was last drawn in.
class _Phone implements SmsCalls {
  _Phone(this.bytes);
  final Uint8List bytes;
  var asked = 0;

  /// While set, a picture's bytes wait for it: the phone still reading them.
  Completer<void>? hold;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method != 'part') return null;
    asked++;
    await hold?.future;
    // Read anew each time, as the phone's are: not the picture Flutter already has made of the same bytes.
    return Uint8List.fromList(bytes) as T?;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a picture read again keeps the room it was drawn in, from its first frame until it is drawn', (tester) async {
    // Twice as wide as tall: nothing like the square that stands for one not seen before.
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 400, height: 200)));
    final phone = _Phone(png);
    Sms.calls = phone;
    final sheet = await loadSheet(tester);
    const width = 300.0, id = 730001;
    Future<void> show(Key key) => pumpScreen(tester, sheet, Align(alignment: Alignment.topLeft, child: KeyedSubtree(key: key, child: threadPictureForTest(id: id, maxWidth: width))), AppState());
    Size room(Key key) => tester.getSize(find.descendant(of: find.byKey(key), matching: find.byType(FutureBuilder<Uint8List?>)));
    Future<void> drawn() async {
      for (var i = 0; i < 20 && find.byKey(const ValueKey('picture-waiting')).evaluate().isNotEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    const first = ValueKey('first'), again = ValueKey('again');
    await show(first);
    expect(room(first), const Size(width * 0.7, width * 0.7), reason: 'never seen: a square stands for it');
    await drawn();
    expect(find.byKey(const ValueKey('picture-waiting')), findsNothing);
    final own = room(first);
    expect(own, const Size(width, width / 2), reason: 'its own shape once drawn');

    // Scrolled away, let go, and come back to: the widget is made again and its bytes are asked for again.
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 50; i++) {
      await Sms.instance.part(740000 + i);
    }
    imageCache.clear();
    imageCache.clearLiveImages();
    final before = phone.asked;
    phone.hold = Completer<void>();
    await show(again);
    expect(find.byKey(const ValueKey('picture-waiting')), findsOneWidget, reason: 'its bytes not read yet');
    expect(room(again), own, reason: 'the room it had, while it is read');
    // Its bytes here and not yet a picture: still that room, never nothing.
    phone.hold!.complete();
    phone.hold = null;
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('picture-waiting')), findsOneWidget, reason: 'read, and not yet made into a picture');
    expect(room(again), own, reason: 'the room it had, while it is made');
    await drawn();
    expect(phone.asked, greaterThan(before), reason: 'it was read from the phone again');
    expect(find.byKey(const ValueKey('picture-waiting')), findsNothing);
    expect(room(again), own);
    expect(tester.takeException(), isNull);
  });
}
