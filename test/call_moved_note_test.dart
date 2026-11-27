import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/call_moved_note.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

/// A call taken over by another of the person's devices says so on the one it left, until answered (GMFB-50, Kevin:
/// "If you are on your pc talking in a call and switch to your phone a "would you like to reconnect" notification
/// could be nice. Maybe a sticky toast notification?"). The device left used to go quietly, with nothing to say where
/// the call went or to get it back.

/// The relay's room as one_identity_test.dart stands it in: a packet goes to every other connection there, the
/// sender's own other devices included, and nobody is told 'came' for an id already there.
class _Hub {
  final Map<String, List<_Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= [];
    final first = !r.any((o) => o.me == me);
    final others = {for (final o in r) if (o.me != me) o.me}.toList();
    if (!r.contains(this)) r.add(this);
    if (first) {
      for (final o in r) {
        if (o.me != me) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
      }
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    if (r == null || !r.remove(this)) return;
    if (r.any((o) => o.me == me)) return;
    for (final o in r) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  @override
  void send(String room, Uint8List bytes) {
    for (final o in [...?hub.rooms[room]]) {
      if (!identical(o, this)) scheduleMicrotask(() => o._packets.add((room: room, from: me, bytes: bytes)));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => _events.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => _looks.stream;
}

class _Media implements VoiceMedia {
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
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => _Peer();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements VoicePeer {
  static const _opus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  @override
  Future<String> makeOffer() async => _opus;
  @override
  Future<String> takeOffer(String sdp) async => _opus;
  @override
  Future<void> takeAnswer(String sdp) async {}
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async {}
}

/// One device of the person's: the call it is in and its note, wired as Voice.join wires them (the session's
/// onMovedAway leaves and notes it; Bring it back here joins again).
class _Device {
  _Device(this.hub, this.id, {Duration keep = const Duration(minutes: 10)}) {
    note = MovedAway(bring: join, keep: keep);
  }
  final _Hub hub;
  final String id;
  late final MovedAway note;
  VoiceSession? session;

  Future<void> join(VoiceChannel c) async {
    note.dismiss();
    final s = session = VoiceSession(channel: c, route: _Route(hub, id), media: _Media(), name: 'Matt');
    s.onMovedAway = () async {
      if (!identical(session, s)) return;
      session = null;
      await s.leave();
      note.moved(c);
    };
    await s.join();
  }

  bool get inCall => session?.joined ?? false;
}

/// Waits until [ok] holds, or five seconds go by: never a fixed sleep, which a busy machine outruns.
Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('the device a call left is told, brings it back, and the other is told in its turn', () async {
    final hub = _Hub();
    final matt = NetKeys.generate().id;
    final c = VoiceChannel.make('Lounge');
    final mac = _Device(hub, matt), phone = _Device(hub, matt);
    await mac.join(c);
    expect(mac.note.value, isNull);

    // The same person comes in on the phone: the call goes there, and the computer says so.
    await phone.join(c);
    await _until(() => mac.note.value != null);
    expect(mac.note.value?.channel.room, c.room);
    expect(mac.inCall, isFalse);
    expect(phone.inCall, isTrue);
    expect(phone.note.value, isNull);

    // Left alone, the computer stays out: nothing joins by itself.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(mac.inCall, isFalse);
    expect(phone.inCall, isTrue);

    // Bring it back here: the computer is in the call again, and now the phone has the note.
    await mac.note.bringBack();
    await _until(() => phone.note.value != null);
    expect(mac.inCall, isTrue);
    expect(mac.note.value, isNull);
    expect(phone.inCall, isFalse);
    expect(phone.note.value?.channel.room, c.room);

    // Put away on the phone: gone, and the call stays where it is.
    phone.note.dismiss();
    expect(phone.note.value, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(phone.note.value, isNull);
    expect(mac.inCall, isTrue);
    await mac.session?.leave();
  });

  test('the note goes by itself when the call is over, or after its time', () async {
    final c = VoiceChannel.make('Lounge'), other = VoiceChannel.make('Den');
    var brought = 0;
    final note = MovedAway(bring: (_) async => brought++, keep: const Duration(milliseconds: 40));
    note.moved(c);
    // Still someone in it (this person's other device): it stays. Another room emptying is not this call ending.
    note.looked(c.room, ['someone']);
    note.looked(other.room, const []);
    expect(note.value, isNotNull);
    note.looked(c.room, const []);
    expect(note.value, isNull);

    note.moved(c);
    await _until(() => note.value == null);
    expect(note.value, isNull, reason: 'stale after its time');
    // Nothing to bring back once it is gone.
    await note.bringBack();
    expect(brought, 0);
  });

  testWidgets('the note is drawn over the page with its button and its cross', (tester) async {
    final c = VoiceChannel.make('Lounge');
    final brought = <VoiceChannel>[];
    final note = MovedAway(bring: (c) async => brought.add(c));
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    // As the app has it: round the pages, inside the toasts, above the navigator.
    await tester.pumpWidget(WidgetsApp(
      color: const Color(0xFF4F5BD5),
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder w) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => w(c)),
      builder: (context, child) => GlacierTheme(sheet: sheet, attrs: const {'platform': 'mobile'}, child: GlacierToastProvider(child: CallMovedNote(note: note, child: child!))),
      home: const SizedBox.expand(),
    ));
    expect(find.byKey(const ValueKey('call-moved-note')), findsNothing);

    note.moved(c);
    await tester.pump();
    expect(find.text('This call moved to another of your devices'), findsOneWidget);
    await tester.tap(find.text('Bring it back here'));
    await tester.pump();
    expect(brought, [c]);
    expect(find.byKey(const ValueKey('call-moved-note')), findsNothing);

    note.moved(c);
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Dismiss'));
    await tester.pump();
    expect(find.byKey(const ValueKey('call-moved-note')), findsNothing);
    expect(brought, [c]);
    // The note's own clock, so the test leaves no timer behind.
    note.dismiss();
  });
}
