import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/voice/open_space.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/open_space_fakes.dart';

/// An open space's floor (lib/voice/open_space.dart; Matt, 2026-11-23: "a new kind of space called a "open space" ...
/// lets you move around in the space so we can hear people louder or quieter depending on where in the space we are,
/// allow creating groups in the space that display as a targeted circle that expands as more people enter it"): where
/// people stand reaches everyone, how loud each is played goes by how far off they are and by the groups, and the
/// groups are the same on every device and still there for whoever comes back.

Future<void> _until(bool Function() ok, [String what = '']) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHub hub;
  late VoiceChannel c;
  final media = <String, FakeMedia>{};
  final sessions = <String, VoiceSession>{};
  final floors = <String, OpenSpace>{};
  final stores = <String, FakeStore>{};

  /// [id] comes into the call and onto the floor, standing at [at].
  Future<OpenSpace> come(String id, Offset2 at) async {
    media[id] = FakeMedia();
    final s = sessions[id] = VoiceSession(channel: c, route: FakeRoute(hub, id), media: media[id]!, name: id);
    await s.join();
    final f = floors[id] = OpenSpace(s, store: stores[id] ??= FakeStore(), random: math.Random(1));
    f.walkTo(at);
    while (f.walking) {
      f.step(10);
    }
    return f;
  }

  Future<void> go(String id) async {
    floors.remove(id)?.dispose();
    await sessions.remove(id)?.leave();
  }

  setUp(() {
    hub = FakeHub();
    c = VoiceChannel.make('Plaza', kind: SpaceKind.open);
    media.clear();
    stores.clear();
  });

  tearDown(() async {
    for (final id in sessions.keys.toList()) {
      await go(id);
    }
  });

  test('how much is heard: whole when near, nothing far off, whole anywhere in one\'s own group, faint through its edge', () {
    expect(OpenWorld.gain(0), 1);
    expect(OpenWorld.gain(OpenWorld.near), 1);
    expect(OpenWorld.gain(OpenWorld.far), 0);
    expect(OpenWorld.gain(OpenWorld.far + 500), 0);
    final half = OpenWorld.gain((OpenWorld.near + OpenWorld.far) / 2);
    expect(half, inExclusiveRange(0.1, 0.5), reason: 'falling away quickly at first');
    expect(OpenWorld.gain(600, together: true), 1);
    expect(OpenWorld.gain(100, edge: true), OpenWorld.throughEdge);
    // Never louder for being further.
    var last = 1.0;
    for (var d = 0.0; d < 900; d += 10) {
      final g = OpenWorld.gain(d);
      expect(g, lessThanOrEqualTo(last));
      last = g;
    }
  });

  test('where someone stands reaches the others, and they are played louder or quieter by how far off they are', () async {
    final a = await come('a', const Offset2(400, 400));
    final b = await come('b', const Offset2(460, 400));
    await _until(() => b.placeOf('a').said && a.placeOf('b').said, 'each knows where the other stands');
    expect(b.placeOf('a').at, const Offset2(400, 400));
    await _until(() => media['a']!.gains['b'] == 1 && media['b']!.gains['a'] == 1, 'side by side: heard whole');

    // a walks off: quieter for b step by step, then not heard.
    a.walkTo(const Offset2(900, 400));
    while (a.walking) {
      a.step(0.5);
    }
    await _until(() => (media['b']!.gains['a'] ?? 1) < 0.6 && (media['b']!.gains['a'] ?? 0) > 0, 'quieter at a distance');
    expect(media['a']!.gains['b'], closeTo(media['b']!.gains['a']!, 0.02), reason: 'each hears the other the same');
    a.walkTo(const Offset2(1600, 400));
    while (a.walking) {
      a.step(0.5);
    }
    await _until(() => media['b']!.gains['a'] == 0, 'out of earshot');
    // And back again: nobody was cut off.
    a.walkTo(const Offset2(470, 400));
    while (a.walking) {
      a.step(0.5);
    }
    await _until(() => media['b']!.gains['a'] == 1, 'heard whole again');
  });

  test('a floor made as its call is begun, before the relay answers (Voice.join), says where it stands once the call is in', () async {
    await come('b', const Offset2(460, 400));
    media['a'] = FakeMedia();
    final s = sessions['a'] = VoiceSession(channel: c, route: FakeRoute(hub, 'a'), media: media['a']!, name: 'a');
    final a = floors['a'] = OpenSpace(s, store: stores['a'] = FakeStore(), random: math.Random(1));
    a.walkTo(const Offset2(400, 400));
    while (a.walking) {
      a.step(10);
    }
    // Nothing said yet: not in the call.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(floors['b']!.placeOf('a').said, isFalse);
    final w = Stopwatch()..start();
    await s.join();
    await _until(() => floors['b']!.placeOf('a').said && a.placeOf('b').said, 'each knows where the other stands');
    expect(w.elapsed, lessThan(OpenSpace.beatEvery), reason: 'said as the call came in, not at the next beat');
    expect(floors['b']!.placeOf('a').at, const Offset2(400, 400));
  });

  test('walking by the keys:a heading moves this device until it is let go, and never off the floor', () async {
    final a = await come('a', const Offset2(100, 100));
    a.head(-1, -1);
    expect(a.walking, isTrue);
    for (var i = 0; i < 20; i++) {
      a.step(0.1);
    }
    expect(a.me.at, const Offset2(0, 0), reason: 'held at the floor\'s corner');
    a.head(1, 0);
    a.step(1);
    expect(a.me.at.x, closeTo(OpenWorld.speed, 0.01));
    expect(a.me.facing, closeTo(0, 0.001), reason: 'facing the way it walks, for a character later');
    a.head(0, 0);
    expect(a.walking, isFalse);
    expect(a.me.walking, isFalse);
  });

  test('someone who says nothing of their place (an older build) stands in the middle, and is heard from there', () async {
    final a = await come('a', OpenWorld.middle);
    // b is in the call with no floor of its own.
    media['b'] = FakeMedia();
    final s = sessions['b'] = VoiceSession(channel: c, route: FakeRoute(hub, 'b'), media: media['b']!, name: 'b');
    await s.join();
    await _until(() => a.people.contains('b'));
    expect(a.placeOf('b').said, isFalse);
    expect(a.placeOf('b').at, OpenWorld.middle);
    await _until(() => media['a']!.gains['b'] == 1, 'heard whole from the middle');
    a.walkTo(const Offset2(60, 60));
    while (a.walking) {
      a.step(0.5);
    }
    expect(media['a']!.gains['b'], 0);
  });

  test('a group: made by one, there for all; whole inside it, faint across its edge, and its circle grows with who is in it', () async {
    final a = await come('a', const Offset2(600, 600));
    final b = await come('b', const Offset2(700, 600));
    final far = await come('c', const Offset2(600, 800));
    final g = a.addGroup('  Valorant  ')!;
    expect(g.name, 'Valorant');
    await _until(() => b.groups.length == 1 && far.groups.length == 1, 'everyone has the group');
    expect(b.groups.single.name, 'Valorant');

    // a and b stand in it; c stands near enough to hear a well in the open, but outside the circle.
    await _until(() => b.groupOf(OpenSpace.meId) == g.id && b.groupOf('a') == g.id);
    expect(a.countIn(g.id), 2);
    expect(a.radiusOf(g.id), closeTo(OpenWorld.radiusFor(2), 0.001));
    expect(a.radiusOf(g.id), greaterThan(OpenWorld.radiusEmpty));
    expect(far.groupOf(OpenSpace.meId), isNull);
    await _until(() => media['a']!.gains['b'] == 1 && media['b']!.gains['a'] == 1, 'whole inside the group');
    final murmur = OpenWorld.gain(200, edge: true);
    expect(murmur, lessThan(OpenWorld.gain(200) / 3));
    await _until(() => media['c']!.gains['a'] == murmur, 'a murmur from outside');
    expect(media['a']!.gains['c'], murmur, reason: 'and the one outside is faint inside');

    // Anywhere inside it they are whole, however far apart; and the circle grows for each who steps in.
    final d = await come('d', Offset2(600 + OpenWorld.radiusFor(2) - 5, 600));
    await _until(() => a.groupOf('d') == g.id, 'd stepped in at its edge');
    expect(a.countIn(g.id), 3);
    expect(a.radiusOf(g.id), closeTo(OpenWorld.radiusFor(3), 0.001), reason: 'grown for the third');
    expect(media['a']!.gains['d'], 1);
    expect(d.me.at.to(a.me.at), greaterThan(OpenWorld.near), reason: 'further than is heard whole in the open');
  });

  test('a group renamed, moved and taken away is the same for everyone, the newest word winning', () async {
    final a = await come('a', const Offset2(500, 500));
    final b = await come('b', const Offset2(520, 500));
    final g = a.addGroup('Chat')!;
    await _until(() => b.groups.isNotEmpty);
    b.renameGroup(g.id, 'Casual chat');
    await _until(() => a.groups.single.name == 'Casual chat', 'renamed by another');
    b.walkTo(const Offset2(1500, 900));
    while (b.walking) {
      b.step(0.5);
    }
    b.moveGroupHere(g.id);
    await _until(() => a.groups.single.at == const Offset2(1500, 900), 'moved');
    expect(a.groupOf(OpenSpace.meId), isNull, reason: 'a is left outside where it stood');
    a.removeGroup(g.id);
    await _until(() => b.groups.isEmpty, 'taken away for all');
    // Said again by someone who still had it, it stays gone.
    b.renameGroup(g.id, 'Back again');
    expect(b.groups, isEmpty);
  });

  test('a space\'s groups are kept, and there again for whoever comes back to an empty room', () async {
    final a = await come('a', const Offset2(500, 500));
    a.addGroup('Movie night');
    await go('a');
    // Later, alone: the group is on the floor from what this device kept.
    final again = await come('a', const Offset2(900, 900));
    expect(again.groups.single.name, 'Movie night');
    // And a newcomer who never saw it is told.
    final b = await come('b', const Offset2(920, 900));
    await _until(() => b.groups.length == 1 && b.groups.single.name == 'Movie night', 'said to whoever comes in');
  });

  test('leaving the floor plays everyone as anyone is again', () async {
    await come('a', const Offset2(200, 200));
    await come('b', const Offset2(1800, 1200));
    await _until(() => media['a']!.gains['b'] == 0);
    floors.remove('a')!.dispose();
    expect(media['a']!.gains['b'], 1);
  });

  test('what is not a place or a group is passed over, and a space takes no more groups than it holds', () async {
    final a = await come('a', const Offset2(300, 300));
    final b = await come('b', const Offset2(320, 300));
    sessions['b']!.sayPlace({'t': 'os', 'x': 'left', 'y': double.nan});
    // Once b's own last word about its place is in.
    await _until(() => a.placeOf('b').at == const Offset2(320, 300));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sessions['b']!.sayPlace({'t': 'os', 'x': 99999, 'y': -5});
    await _until(() => a.placeOf('b').at == const Offset2(OpenWorld.width, 0), 'held to the floor');
    sessions['b']!.sayPlace({'t': 'osg', 'g': [{'i': '', 'n': 'x'}, 'nonsense', {'i': 'ok', 'n': 'N' * 200, 'x': 10, 'y': 10, 'at': 5}]});
    await _until(() => a.groups.length == 1);
    expect(a.groups.single.name.length, OpenWorld.longestName);
    for (var i = 0; i < OpenWorld.mostGroups + 5; i++) {
      b.addGroup('Group $i');
    }
    expect(b.groups.length, lessThanOrEqualTo(OpenWorld.mostGroups));
  });
}
