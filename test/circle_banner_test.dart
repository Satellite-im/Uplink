import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circle.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// A circle's banner at full size (Matt, 2026-11-19: "when uploading a banner from camera roll it's not uploading the
/// full resolution image"): the circle names the full picture, kept on the relay, beside its small stand-in.
void main() {
  test('the circle names the full picture as a file, beside its stand-in, and an older build passes both on', () {
    final full = SpaceFile.fromJson({'id': 'ab' * 16, 'n': 'banner.jpg', 'z': 4200000, 'm': 'image/jpeg', 'k': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=', 'p': 'AAAAAAAAAAA=', 'u': 'Book Club', 'at': 1}, by: 'x')!;
    final m = CircleManifest(owner: '02${'ab' * 32}', name: 'Book Club', version: 2);
    final set = m.next(extra: {...m.extra, 'bn': 'c21hbGw=', 'bf': full.toJson()});
    expect(set.banner, 'c21hbGw=');
    final again = CircleManifest.fromJson(set.toJson())!;
    final f = SpaceFile.fromJson(again.bannerFile, by: '');
    expect(f!.name, 'banner.jpg');
    expect(f.size, 4200000, reason: 'the picture as it was chosen, not the stand-in');
    expect(again.next(name: 'Book Club 2').bannerFile, isNotNull, reason: 'kept through an unrelated change');
  });

  test('the circle\'s own files are kept under its own seed, apart from its spaces', () {
    final c = Circle(seed: '7' * 64, owner: '', manifest: CircleManifest.placeholder(owner: '', name: 'Book Club'));
    expect(c.bannerChannel.seed, c.seed);
    expect(c.bannerChannel.kind, SpaceKind.files);
    expect(c.bannerChannel.room, isNot(c.room));
  });
}
