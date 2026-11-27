import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/tile_grid.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show TileTools;

import 'support/space_call_harness.dart';

/// The video tiles of a call. GMFB-70 (Matt): "Move the flip video setting to show up as a button hovered over the
/// video when available and add it to the menu that pops up when tapping on a video": Flip camera is a small button
/// over one's own picture, no longer a line of the call's menu. GMFB-68: on a computer the button there is Change
/// camera. GMFB-71 (Matt): "Videos are still rectangular on mobile and don't show the whole camera resolution": a
/// phone's tile is the shape of the picture in it.

/// [c] with this device's camera on and what its tile's buttons do, and each person's picture shaped as [shapes] says.
SpaceCall _with(SpaceCall c, {VoidCallback? onFlip, void Function(BuildContext)? onCamera, Map<String, double> shapes = const {}}) => SpaceCall(
      channel: c.channel,
      people: [
        for (final p in c.people) SpacePerson(id: p.id, name: p.name, me: p.me, muted: p.muted, guest: p.guest, video: p.video, shape: shapes[p.id], role: p.role, owner: p.owner, username: p.username),
      ],
      levels: c.levels,
      changes: c.changes,
      room: c.room,
      since: c.since,
      video: true,
      onFlip: onFlip,
      onCamera: onCamera,
      onMute: c.onMute,
      onVideo: c.onVideo,
      onDeafen: c.onDeafen,
      onLeave: c.onLeave,
      onMinimize: c.onMinimize,
      onPerson: c.onPerson,
      onSettings: c.onSettings,
      onInvite: c.onInvite,
      onDevices: c.onDevices,
      chatBuilder: c.chatBuilder,
    );

const _menu = 'More: invite, devices, settings, leave';

void main() {
  testWidgets('Flip camera is a button over your own video, and no longer in the call\'s menu (GMFB-70)', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    final flip = find.bySemanticsLabel('Flip camera');
    // Nothing to flip: no button over the tile.
    await h.shoot(tester, TelegramCall(call: _with(h.call(log: log, myVideo: true))), 'tile-tools', dir: '../build/tile-tools');
    expect(flip, findsNothing);
    expect(find.bySemanticsLabel('Change camera'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await h.shoot(tester, TelegramCall(call: _with(h.call(log: log, myVideo: true), onFlip: () => log.add('flip'))), 'tile-tools', dir: '../build/tile-tools');
    // One button, inside your own tile and not Riley's.
    expect(flip, findsOneWidget);
    final mine = tester.getRect(find.byWidgetPredicate((w) => w is TileTools && w.tools.isNotEmpty));
    expect(mine.contains(tester.getCenter(flip)), isTrue);
    expect(find.byWidgetPredicate((w) => w is TileTools && w.tools.isEmpty), findsOneWidget);
    await tester.tap(flip);
    await tester.pump(const Duration(milliseconds: 300));
    expect(log, ['flip']);
    // The rest of the tile still opens what a press on a video opens.
    await tester.tapAt(mine.center);
    await tester.pump(const Duration(milliseconds: 300));
    expect(log, ['flip', 'person me']);
    // The menu has it no more.
    await tester.tap(find.bySemanticsLabel(_menu).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Devices'), findsOneWidget);
    expect(flip, findsOneWidget);
    expect(find.text('Front or back'), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with a mouse the button shows only while the pointer is over the video; on a computer it is Change camera (GMFB-70, GMFB-68)', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(2, 2));
    addTearDown(mouse.removePointer);
    await h.shoot(tester, TelegramCall(call: _with(h.call(log: log, myVideo: true), onCamera: (_) => log.add('camera'))), 'tile-tools', size: SpaceHarness.computer, dir: '../build/tile-tools');
    final change = find.bySemanticsLabel('Change camera');
    expect(change, findsNothing);
    final mine = tester.getRect(find.byWidgetPredicate((w) => w is TileTools && w.tools.isNotEmpty));
    await mouse.moveTo(mine.center);
    await tester.pump();
    expect(change, findsOneWidget);
    await tester.tap(change);
    await tester.pump(const Duration(milliseconds: 300));
    expect(log, ['camera']);
    await mouse.moveTo(const Offset(2, 2));
    await tester.pump();
    expect(change, findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  test('a tile for the whole of a picture: as wide as its place, or as tall as allowed and narrower (GMFB-71)', () {
    // A wide picture across a phone: all of the width.
    expect(wholeTile(width: 360, shape: 16 / 9, most: 500), const Size(360, 202.5));
    // An upright phone's picture: as tall as allowed, as narrow as it is then.
    final tall = wholeTile(width: 360, shape: 9 / 16, most: 480);
    expect(tall.height, 480);
    expect(tall.width, closeTo(270, 0.01));
  });

  test('a picture\'s shape is kept by its stream as it is said, and said again when it turns', () {
    var told = 0;
    void count() => told++;
    VideoShapes.changes.addListener(count);
    addTearDown(() => VideoShapes.changes.removeListener(count));
    expect(VideoShapes.of('s-new'), isNull);
    VideoShapes.say('s-new', 9 / 16);
    VideoShapes.say('s-new', 9 / 16);
    expect(VideoShapes.of('s-new'), 9 / 16);
    expect(told, 1);
    VideoShapes.say('s-new', 16 / 9);
    expect(VideoShapes.of('s-new'), 16 / 9);
    expect(told, 2);
    VideoShapes.say('s-new', 0);
    expect(VideoShapes.of('s-new'), 16 / 9);
  });

  testWidgets('on a phone a video tile is the shape of its picture, all of it shown (GMFB-71)', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    Size tile(String id) => tester.getSize(find.byKey(ValueKey('tg-whole-$id')));
    // You alone with video, the phone upright: 9:16, not a strip 200 high across the screen.
    await h.shoot(tester, TelegramCall(call: _with(h.call(video: const {}, myVideo: true), shapes: const {'me': 9 / 16})), 'tile-whole', dir: '../build/tile-tools');
    expect(tester.takeException(), isNull);
    var me = tile('me');
    expect(me.width / me.height, closeTo(9 / 16, 0.01));
    expect(me.height, greaterThan(300));
    expect(tester.widget<SpaceVideo>(find.byType(SpaceVideo)).whole, isTrue);
    await tester.pumpWidget(const SizedBox());
    // A computer's wide picture: across the whole width, 16:9.
    await h.shoot(tester, TelegramCall(call: _with(h.call(video: const {}, myVideo: true), shapes: const {'me': 16 / 9})), 'tile-whole', dir: '../build/tile-tools');
    me = tile('me');
    expect(me.width / me.height, closeTo(16 / 9, 0.01));
    expect(me.width, greaterThan(360));
    await tester.pumpWidget(const SizedBox());
    // Two side by side, each its own shape.
    await h.shoot(tester, TelegramCall(call: _with(h.call(myVideo: true), shapes: const {'me': 9 / 16, 'c': 4 / 3})), 'tile-whole', dir: '../build/tile-tools');
    expect(tester.takeException(), isNull);
    expect(tile('me').width / tile('me').height, closeTo(9 / 16, 0.01));
    expect(tile('c').width / tile('c').height, closeTo(4 / 3, 0.01));
    await tester.pumpWidget(const SizedBox());
    // Until a picture's shape is known the tile is as it was: one alone 200 high.
    await h.shoot(tester, TelegramCall(call: _with(h.call(video: const {}, myVideo: true))), 'tile-whole', dir: '../build/tile-tools');
    expect(find.byKey(const ValueKey('tg-whole-me')), findsNothing);
    expect(tester.getSize(find.byType(SpaceVideo)).height, closeTo(200, 6));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('on a computer the tiles stay 4:3 whatever the picture\'s shape', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    await h.shoot(tester, TelegramCall(call: _with(h.call(video: const {}, myVideo: true), shapes: const {'me': 9 / 16})), 'tile-whole', size: SpaceHarness.computer, dir: '../build/tile-tools');
    expect(find.byKey(const ValueKey('tg-whole-me')), findsNothing);
    final s = tester.getSize(find.byType(SpaceVideo));
    expect(s.width / s.height, closeTo(4 / 3, 0.03));
    await tester.pumpWidget(const SizedBox());
  });
}
