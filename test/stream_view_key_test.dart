import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ghost_messaging/ui/voice_screen.dart';

/// GMFB-5 (Matt, Mac 0.11.3: "When I switch off video, it shows a still frame of my video on someone elses stream and
/// the video for their stream never shows up"): call tiles are laid out by place, so when my tile goes the next person's
/// moved into the place my renderer had, and was drawn on it. Each picture is now keyed by its stream: a renderer only
/// ever shows the one stream it was made for.
class _Stream implements MediaStream {
  _Stream(this.id);
  @override
  final String id;
  @override
  String get ownerTag => 'test';
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a picture that stays is never drawn on the renderer of one that left', (tester) async {
    var next = 1;
    final shown = <int, String>{}; // texture -> the stream it was told to draw last
    final ever = <int, Set<String>>{}; // texture -> every stream it was ever told to draw
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
      final args = (call.arguments as Map?) ?? const {};
      switch (call.method) {
        case 'createVideoRenderer':
          return {'textureId': next++};
        case 'videoRendererSetSrcObject':
          shown[args['textureId'] as int] = args['streamId'] as String;
          (ever[args['textureId'] as int] ??= {}).add(args['streamId'] as String);
      }
      return null;
    });
    for (var i = 1; i < 5; i++) {
      tester.binding.defaultBinaryMessenger.setMockStreamHandler(EventChannel('FlutterWebRTC/Texture$i'), MockStreamHandler.inline(onListen: (_, _) {}));
    }
    final mine = _Stream('mine'), theirs = _Stream('theirs');
    Widget tiles(List<MediaStream> streams) => Directionality(
          textDirection: TextDirection.ltr,
          child: Row(children: [for (final s in streams) SizedBox(width: 100, height: 100, child: StreamView(key: ObjectKey(s), stream: s))]),
        );

    await tester.pumpWidget(tiles([mine, theirs]));
    await tester.pumpAndSettle();
    final mineTexture = shown.entries.firstWhere((e) => e.value == 'mine').key;
    final theirTexture = shown.entries.firstWhere((e) => e.value == 'theirs').key;

    // My video goes off: their picture moves into the first place.
    await tester.pumpWidget(tiles([theirs]));
    await tester.pumpAndSettle();
    expect(shown[mineTexture], 'mine', reason: 'my renderer was not handed their stream');
    expect(shown[theirTexture], 'theirs');
    for (final e in ever.entries) {
      expect(e.value.where((id) => id.isNotEmpty), hasLength(1), reason: 'texture ${e.key} drew ${e.value}: one renderer, one person');
    }
    expect(shown.values, contains('theirs'), reason: 'their picture is still drawn');
  });
}
