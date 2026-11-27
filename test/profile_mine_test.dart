import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/me/own_links.dart';
import 'package:ghost_messaging/me/picture_make.dart';
import 'package:ghost_messaging/net/packet.dart';

import 'support/vouch_world.dart';

/// Matt, 2026-11-25: "Photos are still not syncing for profile and banner pictures between mobile and desktop on my mac
/// i updated my profile picture and the banner but it didn't sync to my phone". The profile was put in place once, as a
/// device signed in; a change on one device was told to friends and never to the account's others. Now each part
/// changed is told to them (Buddies.profileKind) and taken where it is newer (Me.takeOwn).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<Me> device() async {
    final me = Me.forTest();
    await me.start(MemoryMeStore(), ValueNotifier(0), () => null);
    return me;
  }

  Map<String, Object> joined(List<Map<String, Object>> pieces) => {for (final p in pieces) ...p};

  test('a picture, banner and status changed on the Mac are taken on the phone, and an older telling is not', () async {
    final mac = await device(), phone = await device();
    final changed = <String>[];
    mac.ownChanged.listen(changed.add);
    mac.setPicture(const ProfilePicture(sharp: 'c2hhcnA=', small: 'c21hbGw=', full: 'ZnVsbA=='));
    mac.setBanner('YmFubmVy');
    mac.setProfile(displayName: 'Sam', bio: 'hi', status: 'Out walking');
    mac.setOwnLinks([const OwnLink('Site', 'https://example.com')]);
    await pumpEventQueue();
    expect(changed, containsAll(['picture', 'banner', 'words']));

    // The picture goes in two pieces: the small one and the sharp one apart.
    expect(mac.ownPieces('picture'), hasLength(2));
    for (final part in Me.ownParts) {
      expect(phone.takeOwn(part, mac.ownAt(part), joined(mac.ownPieces(part))), isTrue, reason: part);
    }
    expect((phone.picture, phone.pictureSharp), ('c21hbGw=', 'c2hhcnA='));
    expect(phone.pictureOwn, 'c2hhcnA=', reason: 'the larger one stays the Mac\'s own');
    expect(phone.banner, 'YmFubmVy');
    expect((phone.displayName, phone.bio, phone.status), ('Sam', 'hi', 'Out walking'));
    expect(phone.ownLinks.single.address, 'https://example.com');

    // Told again: nothing new.
    expect(phone.takeOwn('picture', mac.ownAt('picture'), joined(mac.ownPieces('picture'))), isFalse);
    // The phone changes its status after: the Mac's older words don't take it back.
    final before = mac.ownAt('words');
    await Future<void>.delayed(const Duration(milliseconds: 2));
    phone.setProfile(status: 'Home');
    expect(phone.ownAt('words'), greaterThan(before));
    expect(phone.takeOwn('words', before, joined(mac.ownPieces('words'))), isFalse);
    expect(phone.status, 'Home');
    // And the picture taken away on the Mac is taken away on the phone.
    mac.setPicture(null);
    expect(mac.ownPieces('picture'), [
      {'p': ''},
    ]);
    expect(phone.takeOwn('picture', mac.ownAt('picture'), joined(mac.ownPieces('picture'))), isTrue);
    expect(phone.pictureOwn, isEmpty);
    expect(phone.picturesPast, contains('c2hhcnA='), reason: 'still there to go back to');
  });

  test('saving the profile page with nothing changed tells nobody', () async {
    final me = await device();
    me.setProfile(displayName: 'Sam', bio: '', status: '');
    final changed = <String>[];
    me.ownChanged.listen(changed.add);
    me.setProfile(displayName: 'Sam', bio: '', status: '');
    me.setBanner(me.banner);
    await pumpEventQueue();
    expect(changed, isEmpty);
  });

  test('what cannot be one is passed over', () async {
    final me = await device();
    expect(me.takeOwn('banner', 5, {'bp': 'not base64!'}), isFalse);
    expect(me.takeOwn('picture', 5, {'p': 42}), isFalse);
    expect(me.takeOwn('nothing', 5, {}), isFalse);
    expect(me.ownAt('banner'), 0);
  });

  group('between devices', () {
    late Me me;
    setUp(() async {
      me = Me.instance;
      await me.start(MemoryMeStore(), ValueNotifier(0), () => null);
    });

    test('pieces from the account\'s own devices are taken once all are here; a friend\'s are not', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya');
      final phone = _Device(w, 'sam');
      final b = await makeFriends([(maya, phone)]);
      final at = DateTime.now().millisecondsSinceEpoch + 1000;
      Envelope piece(int i, Map<String, Object> body) => Envelope(kind: Buddies.profileKind, body: {'m': 'picture', 't': at, 'i': i, 'of': 2, ...body});

      // A friend sends the kind: not this account's.
      maya.deliver(phone, piece(0, {'p': 'bWF5YQ=='}));
      maya.deliver(phone, piece(1, {'pp': 'bWF5YQ=='}));
      await pumpEventQueue();
      expect(me.picture, isNot('bWF5YQ=='));

      // From the Mac: the first piece alone is held, both are taken.
      phone.deliver(phone, piece(0, {'p': 'c21hbGw='}));
      await pumpEventQueue();
      expect(me.picture, isNot('c21hbGw='));
      phone.deliver(phone, piece(1, {'pp': 'c2hhcnA='}));
      await pumpEventQueue();
      expect((me.picture, me.pictureSharp), ('c21hbGw=', 'c2hhcnA='));
      expect(me.ownAt('picture'), at);
      for (final x in b.values) {
        x.dispose();
      }
    });

    test('a device that asks is told the parts it is behind on, and one that is ahead is asked back', () async {
      final w = VouchWorld();
      final maya = VouchPort(w, 'maya');
      final phone = _Device(w, 'sam');
      final b = await makeFriends([(maya, phone)]);
      me.setBanner('YmFubmVy');
      // The phone is told it is behind on the banner only.
      phone.deliver(phone, Envelope(kind: Buddies.profileKind, body: {'q': {'words': me.ownAt('words'), 'picture': me.ownAt('picture') + 99999999, 'banner': 0}}));
      await pumpEventQueue();
      final told = phone.mine.where((e) => e.kind == Buddies.profileKind).map((e) => e.body).toList();
      expect(told.where((t) => t['m'] == 'banner').single['bp'], 'YmFubmVy');
      expect(told.where((t) => t['m'] == 'words'), isEmpty);
      expect(told.where((t) => t['q'] is Map), hasLength(1), reason: 'the asker has a newer picture: asked for it');
      for (final x in b.values) {
        x.dispose();
      }
    });
  });
}

/// One device of an account that has others: what it tells them is written down.
class _Device extends VouchPort implements BuddiesMine {
  _Device(super.world, super.name);
  final mine = <Envelope>[];

  @override
  Future<bool> sendMine(Envelope envelope) async {
    mine.add(envelope);
    return true;
  }
}
