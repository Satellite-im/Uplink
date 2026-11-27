import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/voice_screen.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Flip camera (GMFB-57, Kevin: "Add a button to flip camera on mobile versions"): the call changes between the
/// front and the back camera where its media can, remembers which while video is off, and does nothing where it
/// can't; the button is in the dock and in each of the six designs only while there is something to flip.
void main() {
  group('the call', () {
    VoiceSession session(VoiceMedia media) => VoiceSession(channel: VoiceChannel.make('Friday hang'), route: _NoRoute(), media: media, name: 'Me');

    test('flips only while video is on and the screen is not shared, and tells its listeners', () async {
      final media = _PhoneMedia();
      final s = session(media);
      var told = 0;
      s.addListener(() => told++);
      // Video off: nothing to flip, no button.
      expect(s.canFlipCamera, isFalse);
      await s.flipCamera();
      expect(media.flips, 0);
      await s.setVideo(true);
      expect(s.canFlipCamera, isTrue);
      expect(s.backCamera, isFalse);
      told = 0;
      await s.flipCamera();
      expect(media.flips, 1);
      expect(s.backCamera, isTrue);
      expect(told, 1);
      // The screen shared in the camera's place: no button, and nothing flips.
      s.screen = true;
      expect(s.canFlipCamera, isFalse);
      await s.flipCamera();
      expect(media.flips, 1);
      s.screen = false;
      // Video off and on again in the same call: still the back camera.
      await s.setVideo(false);
      expect(s.canFlipCamera, isFalse);
      await s.setVideo(true);
      expect(s.backCamera, isTrue);
      expect(media.opened, [false, true]);
      await s.flipCamera();
      expect(s.backCamera, isFalse);
    });

    test('does nothing with media that has one camera, or none to flip', () async {
      final plain = session(_NoMedia());
      await plain.setVideo(true);
      expect(plain.canFlipCamera, isFalse);
      expect(plain.backCamera, isFalse);
      await plain.flipCamera();
      final computer = _PhoneMedia(phone: false);
      final s = session(computer);
      await s.setVideo(true);
      expect(s.canFlipCamera, isFalse);
      await s.flipCamera();
      expect(computer.flips, 0);
    });

    test('a camera that will not change leaves the call as it was', () async {
      final media = _PhoneMedia(fails: true);
      final s = session(media);
      await s.setVideo(true);
      await s.flipCamera();
      expect(s.backCamera, isFalse);
      expect(s.video, isTrue);
    });

    test('the real media flips nothing on a computer (where the tests run)', () async {
      final media = RtcMedia();
      expect(media.canFlipCamera, isFalse);
      await media.flipCamera();
      expect(media.backCamera, isFalse);
    });
  });

  testWidgets('the dock has Flip camera only while there is a camera to flip', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final media = _PhoneMedia();
    final s = VoiceSession(channel: VoiceChannel.make('Friday hang'), route: _NoRoute(), media: media, name: 'Me');
    await h.shoot(tester, Center(child: CallDock(session: s)), 'flip-dock');
    expect(find.bySemanticsLabel('Flip camera'), findsNothing);
    await s.setVideo(true);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Flip camera'));
    await tester.pump();
    expect(media.flips, 1);
    expect(s.backCamera, isTrue);
    s.screen = true;
    await s.setVideo(true);
    await tester.pump();
    expect(find.bySemanticsLabel('Flip camera'), findsNothing);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a space\'s call has a flip button while there is a camera to flip, and none otherwise', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final designs = <String, Widget Function(SpaceCall)>{'telegram': (c) => TelegramCall(call: c)};
    // The button is over one's own video now (GMFB-70; test/video_tile_tools_test.dart), no longer in the call's own
    // menu: nothing to open first.
    const menus = <String, String>{};
    final flip = find.bySemanticsLabel(RegExp(r'^Flip( camera)?$'));
    for (final MapEntry(key: name, value: build) in designs.entries) {
      for (final (size, where) in [(SpaceHarness.phone, 'phone'), (SpaceHarness.computer, 'computer')]) {
        final log = <String>[];
        final c = h.call(log: log, myVideo: true);
        // Nothing to flip (a computer, video off, the screen shared): no button, in the bar or the menu.
        await h.shoot(tester, build(c), 'flip-$name', size: size);
        final menu = menus['$name-$where'];
        if (menu != null) {
          await tester.tap(find.bySemanticsLabel(menu).first);
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(flip, findsNothing, reason: '$name $where');
        await tester.pumpWidget(const SizedBox());
        await h.shoot(tester, build(_flipping(c, () => log.add('flip'))), 'flip-$name', size: size);
        if (menu != null) {
          await tester.tap(find.bySemanticsLabel(menu).first);
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(flip, findsOneWidget, reason: '$name $where');
        await tester.tap(flip);
        await tester.pump(const Duration(milliseconds: 400));
        expect(log, ['flip'], reason: '$name $where');
        expect(tester.takeException(), isNull, reason: '$name $where');
        await tester.pumpWidget(const SizedBox());
      }
    }
    semantics.dispose();
  });
}

/// [c] on a phone with video on: the same call, with a camera to flip.
SpaceCall _flipping(SpaceCall c, VoidCallback onFlip) => SpaceCall(
      channel: c.channel,
      people: c.people,
      levels: c.levels,
      changes: c.changes,
      room: c.room,
      since: c.since,
      video: true,
      onFlip: onFlip,
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

/// A phone's cameras, with no camera: which one each turning on of video opened, and how often it was flipped.
class _PhoneMedia extends _NoMedia implements CameraMedia {
  _PhoneMedia({this.phone = true, this.fails = false});
  final bool phone, fails;
  int flips = 0;

  /// Each time video was turned on: whether it opened the back camera.
  final List<bool> opened = [];
  bool _back = false;

  @override
  bool get canFlipCamera => phone;
  @override
  bool get backCamera => _back;
  @override
  Future<void> flipCamera() async {
    if (fails) throw StateError('one camera');
    flips++;
    _back = !_back;
  }

  @override
  Future<void> setVideo(bool on) async {
    if (on) opened.add(_back);
  }
}

/// A relay that is never reached.
class _NoRoute implements VoiceRoute {
  @override
  String get me => 'me-id';
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

/// No microphone, no camera.
class _NoMedia implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  set muted(bool on) {}
  @override
  set deafened(bool on) {}
  @override
  Future<void> setVideo(bool on) async {}
  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => throw UnimplementedError();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}
