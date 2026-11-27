import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/open_space_chat.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/open_space.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/open_space_fakes.dart';

/// An open space's chat as bubbles over its floor (lib/ui/open_space_chat.dart; Matt, 2026-11-23: "make the chat show
/// up in bubbles hovering over the side that stack and fade away after a few messages if they're said within a circle
/// make them stack above the circle and make them fade away the further you are away from them").

/// Someone in the space: in its call with a place on the floor, and in its chat.
class _Person {
  _Person(FakeHub hub, this.name, VoiceChannel c) : keys = NetKeys.generate() {
    route = FakeRoute(hub, keys.id);
    session = VoiceSession(channel: c, route: route, media: FakeMedia(), name: name);
    room = HangoutRoom(channel: c, route: route, name: name, signer: KeysSigner(keys), store: MemoryHangoutStore());
  }
  final String name;
  final NetKeys keys;
  late final FakeRoute route;
  late final VoiceSession session;
  late final HangoutRoom room;
  late final OpenSpace floor;
  String get id => keys.id;

  Future<void> come(Offset2 at) async {
    await session.join();
    await room.open();
    floor = OpenSpace(session, store: FakeStore(), random: math.Random(2));
    walk(at);
  }

  void walk(Offset2 at) {
    floor.walkTo(at);
    while (floor.walking) {
      floor.step(10);
    }
  }

  Future<void> go() async {
    floor.dispose();
    await room.close();
    await session.leave();
  }
}

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
  late _Person matt, maya;
  late FloorBubbles bubbles;
  var clock = DateTime(2026, 11, 23, 12);

  setUp(() async {
    hub = FakeHub();
    final owner = NetKeys.generate();
    c = VoiceChannel.make('Plaza', owner: NetCrypto.hex(owner.public), kind: SpaceKind.open);
    matt = _Person(hub, 'Matt', c);
    maya = _Person(hub, 'Maya', c);
    await matt.come(const Offset2(600, 600));
    await maya.come(const Offset2(660, 600));
    await _until(() => matt.floor.placeOf(maya.id).said && matt.floor.placeOf(maya.id).at == const Offset2(660, 600), 'Matt knows where Maya stands');
    clock = DateTime(2026, 11, 23, 12);
    bubbles = FloorBubbles(matt.floor, now: () => clock)..follow(matt.room);
  });

  tearDown(() async {
    bubbles.dispose();
    await matt.go();
    await maya.go();
  });

  test('what is said comes up at the side, and what was said before the floor was opened does not', () async {
    expect(maya.room.sendWith(text: 'Before'), isTrue);
    await _until(() => matt.room.messages.any((m) => m.text == 'Before'));
    // Followed again, as a floor opened now would be: nothing of the chat so far is shown.
    bubbles.follow(null);
    bubbles.follow(matt.room);
    expect(bubbles.side, isEmpty);

    expect(maya.room.sendWith(text: 'Anyone for a game?'), isTrue);
    await _until(() => bubbles.side.length == 1, 'Maya\'s words over the floor');
    final b = bubbles.side.single;
    expect(b.text, 'Anyone for a game?');
    expect(b.name, 'Maya');
    expect(b.from, maya.id);
    expect(bubbles.opacityOf(b), 1, reason: 'she stands beside him');

    // His own are his own, whole.
    expect(matt.room.sendWith(text: 'Yes'), isTrue);
    await _until(() => bubbles.side.length == 2);
    expect(bubbles.side.last.from, OpenSpace.meId);
    expect(bubbles.opacityOf(bubbles.side.last), 1);
  });

  test('fainter the further off the writer stands, never gone', () async {
    expect(maya.room.sendWith(text: 'Hello'), isTrue);
    await _until(() => bubbles.side.length == 1);
    final b = bubbles.side.single;
    expect(bubbles.opacityOf(b), 1);
    maya.walk(const Offset2(1000, 600));
    await _until(() => matt.floor.placeOf(maya.id).at == const Offset2(1000, 600));
    final mid = bubbles.opacityOf(b);
    expect(mid, inExclusiveRange(FloorBubbles.faintest, 1.0));
    maya.walk(const Offset2(2200, 1500));
    await _until(() => matt.floor.placeOf(maya.id).at == const Offset2(2200, 1500));
    expect(bubbles.opacityOf(b), closeTo(FloorBubbles.faintest, 0.001), reason: 'out of earshot: faint, still there');
  });

  test('said in a group, it hangs over the group, and is fainter from outside the further off the group is', () async {
    final g = matt.floor.addGroup('Valorant')!;
    await _until(() => maya.floor.groups.length == 1 && maya.floor.groupOf(OpenSpace.meId) == g.id, 'Maya is in the group');
    await _until(() => matt.floor.groupOf(maya.id) == g.id);
    expect(maya.room.sendWith(text: 'Push B'), isTrue);
    await _until(() => bubbles.over(g.id).length == 1, 'over the group, not at the side');
    expect(bubbles.side, isEmpty);
    final b = bubbles.over(g.id).single;
    expect(bubbles.opacityOf(b), 1, reason: 'Matt is in the group too');

    // He walks out: fainter by how far its edge is, whatever became of who wrote it.
    matt.walk(const Offset2(600, 600 + 500));
    expect(matt.floor.groupOf(OpenSpace.meId), isNull);
    final outside = bubbles.opacityOf(b);
    expect(outside, inExclusiveRange(FloorBubbles.faintest, 1.0));
    matt.walk(const Offset2(2300, 1500));
    expect(bubbles.opacityOf(b), closeTo(FloorBubbles.faintest, 0.001));
    // The group taken away: its bubbles are at the side.
    matt.floor.removeGroup(g.id);
    expect(bubbles.over(g.id), isEmpty);
    expect(bubbles.side.single.id, b.id);
  });

  test('a stack keeps the newest few, and a bubble fades out and goes after a while', () async {
    for (var i = 1; i <= FloorBubbles.most + 3; i++) {
      expect(maya.room.sendWith(text: 'Line $i'), isTrue);
      await _until(() => matt.room.messages.any((m) => m.text == 'Line $i'));
    }
    await _until(() => bubbles.side.isNotEmpty && bubbles.side.last.text == 'Line ${FloorBubbles.most + 3}');
    expect(bubbles.side.length, FloorBubbles.most);
    expect(bubbles.side.first.text, 'Line 4');

    final last = bubbles.side.last;
    expect(bubbles.opacityOf(last), 1);
    clock = clock.add(FloorBubbles.life - const Duration(milliseconds: 900));
    expect(bubbles.opacityOf(last), closeTo(0.5, 0.01), reason: 'half way through fading');
    clock = clock.add(const Duration(seconds: 2));
    expect(bubbles.opacityOf(last), 0);
    await _until(() => bubbles.side.isEmpty, 'gone once their time is up');
  });

  test('a message with no words says what it is', () {
    HangoutMessage m({String text = '', String? sticker}) => HangoutMessage(id: 'x', from: 'a', name: 'A', text: text, at: 1, sticker: sticker);
    expect(FloorBubbles.wordsOf(m(text: '  hi  ')), 'hi');
    expect(FloorBubbles.wordsOf(m(sticker: 'love-03')), 'Sticker');
    expect(FloorBubbles.wordsOf(m()), '');
  });
}
