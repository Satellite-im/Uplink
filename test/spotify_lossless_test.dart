import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/voice/music_sink.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/spotify.dart';
import 'package:ghost_messaging/voice/spotify_app.dart';
import 'package:ghost_messaging/voice/spotify_link.dart';
import 'package:ghost_messaging/voice/spotify_lossless.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

import 'support/lossless_stand_ins.dart';
import 'support/spotify_stand_ins.dart';

/// A circle's music without loss (lib/voice/spotify_lossless.dart, spotify_link.dart, spotify.dart): what comes and how it
/// is played, what is sent and to whom. The player, WebRTC and the hub are stood in for; the packing is test/flac_test.dart's
/// and native/voicefx's, the sending from a Mac tool/spotify's.
const track = '4cOdK2wGLETKBW3PvgPWqT';
const n = 1920;

/// The music at frame [i]: loud, and never the same twice near by.
int at(int i, int side) => ((sin(i / (side == 0 ? 17 : 11)) * 9000) + (i * 7919 + side * 31) % 2000 - 1000).round();
Int16List block(int from, [int frames = n]) => Int16List.fromList([for (var i = from; i < from + frames; i++) ...[at(i, 0), at(i, 1)]]);

/// The listener's side, fed a chunk for each 40 ms that go by.
class Listening {
  Listening(this.tester) {
    ear = LosslessEar(sink: sink, onHeard: heard.add, onGiveUp: gone.add, clock: () => now);
  }
  final WidgetTester tester;
  final sink = FakeSink();
  late final LosslessEar ear;
  final List<bool> heard = [];
  final List<LosslessWhy> gone = [];
  DateTime now = DateTime(2026, 11, 25, 20);
  int next = 100000;

  /// [chunks] come and as much is played; [come] false: nothing comes. [plays]: frames played in that time.
  Future<void> go(int chunks, {bool come = true, int plays = n}) async {
    for (var i = 0; i < chunks; i++) {
      if (come) {
        ear.take(plainChunk(next, block(next)));
        next += n;
      }
      now = now.add(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 40));
      sink.play(plays);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the listener\'s side', () {
    testWidgets('it waits for 600 ms, plays a second unheard, and is heard then: bit for bit, at the loudness there is', (tester) async {
      final l = Listening(tester);
      l.ear.set(volume: 0.6, silent: false);
      await l.go(14);
      expect(l.sink.opened, isFalse, reason: '560 ms is not enough');
      await l.go(2);
      expect(l.sink.opened, isTrue);
      expect(l.sink.silent, isTrue, reason: 'proved first');
      expect(l.heard, isEmpty);
      await l.go(20);
      expect(l.heard, isEmpty, reason: 'not yet a second');
      await l.go(10);
      expect(l.heard, [true]);
      expect((l.sink.silent, l.sink.volume), (false, 0.6));
      await l.go(200);
      expect(l.ear.evened, 0);
      final want = block(100000, l.sink.heard.length ~/ 2);
      for (var i = 0; i < want.length; i++) {
        if (want[i] != l.sink.heard[i]) fail('sample $i of ${want.length}: ${l.sink.heard[i]} and not ${want[i]}');
      }
      expect(l.ear.evened, 0);
      expect(l.ear.level(), greaterThan(0.2));
      l.ear.set(volume: 0.6, silent: true);
      expect(l.sink.silent, isTrue, reason: 'deafened');
      l.ear.set(volume: 0.2, silent: false);
      expect((l.sink.silent, l.sink.volume), (false, 0.2));
      l.ear.output('headset');
      expect(l.sink.device, 'headset');
      l.ear.close();
      expect(l.heard, [true, false]);
      expect(l.sink.closed, isTrue);
      expect(l.gone, isEmpty);
    });

    testWidgets('nothing coming: the Opus is heard before the player runs out, and it is proved again after', (tester) async {
      final l = Listening(tester);
      await l.go(60);
      expect(l.heard, [true]);
      final had = l.sink.waiting;
      await l.go(13, come: false);
      expect(l.heard, [true, false]);
      expect(l.sink.dry, 0, reason: 'foreseen');
      expect(had, greaterThan(LosslessEar.low));
      expect(l.sink.silent, isTrue);
      await l.go(10, come: false);
      await l.go(60);
      expect(l.heard, [true, false, true]);
      expect(l.gone, isEmpty);
      l.ear.close();
    });

    testWidgets('paused by the DJ, nothing coming is no trouble, however often', (tester) async {
      final l = Listening(tester);
      await l.go(60);
      for (var i = 0; i < 6; i++) {
        l.ear.playing = false;
        await l.go(30, come: false);
        l.ear.playing = true;
        await l.go(60);
      }
      expect(l.gone, isEmpty);
      expect(l.heard.last, isTrue);
      l.ear.close();
    });

    testWidgets('a gap is kept as silence of its length, and what comes after keeps its time; the Opus meanwhile', (tester) async {
      final l = Listening(tester);
      await l.go(60);
      expect(l.heard, [true]);
      final before = l.sink.heard.length ~/ 2;
      l.next += n * 2;
      await l.go(10);
      expect(l.heard, [true, false]);
      expect(l.ear.gaps, 1);
      expect(l.sink.heard.sublist(before * 2, (before + n * 2) * 2).toSet(), {0});
      expect(l.sink.heard.sublist((before + n * 2) * 2, (before + n * 3) * 2), block(100000 + before + n * 2));
      await l.go(30);
      expect(l.heard, [true, false, true]);
      // A gap too long to wait through: from the beginning.
      l.next += losslessRate * 5;
      await l.go(3);
      expect(l.heard.last, isFalse);
      expect(l.sink.log.last, 'clear');
      await l.go(60);
      expect(l.heard.last, isTrue);
      l.ear.close();
    });

    testWidgets('repeats and what comes late are let go of', (tester) async {
      final l = Listening(tester);
      await l.go(60);
      final had = l.sink.heard.length;
      l.ear.take(plainChunk(l.next - n, block(l.next - n)));
      l.ear.take(plainChunk(100000, block(100000)));
      await tester.pump();
      expect(l.sink.heard.length, had);
      expect(l.ear.repeats, 2);
      expect(l.heard, [true], reason: 'and it goes on');
      l.ear.close();
    });

    testWidgets('three times in trouble within a minute, and it isn\'t tried for now; further apart, it is', (tester) async {
      final l = Listening(tester);
      await l.go(60);
      for (var i = 0; i < 3; i++) {
        expect(l.gone, isEmpty);
        l.next += n;
        await l.go(30);
      }
      expect(l.gone, [LosslessWhy.slow]);
      expect(l.sink.closed, isTrue);
      expect(l.heard.last, isFalse);
      final had = l.sink.heard.length;
      await l.go(30);
      expect(l.sink.heard.length, had, reason: 'nothing more is taken');

      final m = Listening(tester);
      await m.go(60);
      for (var i = 0; i < 6; i++) {
        m.next += n;
        await m.go(30);
        m.now = m.now.add(const Duration(minutes: 1));
      }
      expect(m.gone, isEmpty);
      m.ear.close();
    });

    testWidgets('broken chunks are trouble, another version the end of it; neither is ever played', (tester) async {
      final l = Listening(tester);
      await l.go(60);
      final had = l.sink.heard.length;
      final broken = plainChunk(l.next, block(l.next))..[1] = 1;
      l.ear.take(broken);
      l.ear.take(Uint8List(3)..[0] = 1);
      await tester.pump();
      expect(l.sink.heard.length, had);
      expect(l.heard, [true, false]);
      expect(l.ear.broken, 2);
      expect(l.gone, isEmpty);
      l.ear.take(plainChunk(l.next, block(l.next), version: 9));
      expect(l.gone, [LosslessWhy.version]);

      final m = Listening(tester);
      m.ear.take(Uint8List(0));
      m.ear.take(Uint8List(1 << 16)..[0] = 1);
      expect(m.sink.opened, isFalse);
      m.ear.close();
    });

    testWidgets('sent faster than it plays, no more than two seconds are ever held', (tester) async {
      final l = Listening(tester);
      for (var i = 0; i < 400 && l.gone.isEmpty; i++) {
        l.ear.take(plainChunk(l.next, block(l.next)));
        l.next += n;
        await tester.pump();
        expect(l.sink.waiting, lessThanOrEqualTo(LosslessEar.most));
      }
      expect(l.gone, [LosslessWhy.slow]);
      expect(l.heard, isEmpty);
    });

    testWidgets('a player that can\'t be opened, or stops taking, is given up', (tester) async {
      final l = Listening(tester);
      l.sink.opens = false;
      await l.go(20);
      expect(l.gone, [LosslessWhy.sink]);
      // Opened, and nothing of it plays: never heard.
      final m = Listening(tester);
      await m.go(400, plays: 0);
      expect(m.heard, isEmpty);
      expect(m.gone, isNotEmpty);
    });

    for (final (name, plays) in const [('slower', 1919), ('faster', 1921)]) {
      testWidgets('a clock that runs $name is evened out, a frame at a time and nothing else, with no trouble', (tester) async {
        final l = Listening(tester);
        // 260 in a million, which is more than two real clocks are apart, for nine minutes.
        await l.go(50);
        for (var i = 0; i < 14000; i++) {
          await l.go(1, plays: i.isEven ? plays : n);
        }
        expect(l.heard, [true]);
        expect(l.gone, isEmpty);
        expect(l.ear.evened, inInclusiveRange(2500, 7500));
        expect(l.sink.waiting, inInclusiveRange(LosslessEar.start - 6000, LosslessEar.start + 6000));
        // What was put in or taken out is one frame in a chunk at most.
        expect((l.sink.heard.length ~/ 2 - (l.next - 100000)).abs(), lessThanOrEqualTo(l.ear.evened));
        l.ear.close();
      });
    }

    test('drift: the frame put in or taken out is where the step is least', () {
      final x = block(0, 480);
      for (var i = 200; i < 210; i++) {
        x[i * 2] = x[i * 2 + 1] = 55;
      }
      final fewer = Drift.fewer(x), more = Drift.more(x);
      expect((fewer.length, more.length), (958, 962));
      expect(fewer.sublist(0, 400), x.sublist(0, 400));
      expect(fewer.sublist(420), x.sublist(422));
      expect(more.sublist(0, 400), x.sublist(0, 400));
      expect(more.sublist(422), x.sublist(420));
      expect(Drift.fewer(Int16List(4)), hasLength(4));
    });
  });

  group('the DJ\'s side', () {
    test('a listener who can\'t be sent it in time loses the oldest, whole; nothing is sent until no relay is known', () async {
      final sent = <int>[];
      var buffered = 0;
      final w = LosslessWay(send: (c) async {
        sent.add(c[0]);
        buffered += c.length;
      }, buffered: () async => buffered);
      Uint8List c(int i) => Uint8List(6000)..[0] = i;
      w.push(c(99));
      w.isOpen = true;
      w.push(c(98));
      await settle();
      expect(sent, isEmpty, reason: 'not known to go through no relay');
      w.allowed = true;
      for (var i = 0; i < 40; i++) {
        w.push(c(i));
        await settle();
      }
      expect(sent, [for (var i = 0; i < 8; i++) i], reason: 'no more than 48 KB is ever given to it');
      expect(w.dropped, 40 - 8 - LosslessWay.mostChunks);
      buffered = 0;
      w.push(c(40));
      await settle();
      expect(sent.sublist(8, 13), [36, 37, 38, 39, 40], reason: 'the newest are the ones kept');
      w.allowed = false;
      w.push(c(41));
      await settle();
      expect(sent, hasLength(13));
      expect((w.sent, w.bytes), (13, 13 * 6000));
    });

    late DateTime now;
    late LosslessDesk desk;
    late Map<String, LosslessState> how;
    setUp(() {
      now = DateTime(2026, 11, 25, 20);
      desk = LosslessDesk(clock: () => now);
      how = {};
    });
    void come(String id, {bool wants = true, bool channel = true}) {
      desk.asked(id, wants: wants);
      desk.offered(id, channel: channel);
      if (channel) how[id] = (open: true, bytes: 0, dropped: 0, relay: false);
      now = now.add(const Duration(milliseconds: 1));
    }

    void grow(String id, {int bytes = 0, int dropped = 0, bool? relay = false}) => how[id] = (open: true, bytes: how[id]!.bytes + bytes, dropped: how[id]!.dropped + dropped, relay: relay);

    /// A second goes by; what was to be done is done.
    List<String> second([int s = 1]) {
      now = now.add(Duration(seconds: s));
      return [
        for (final d in desk.look(how))
          switch (d) {
            LosslessBegin(:final id) => () {
                how[id] = (open: true, bytes: 0, dropped: 0, relay: false);
                return 'begin $id';
              }(),
            LosslessEnd(:final id, :final why) => () {
                how.remove(id);
                return 'end $id ${why.name}';
              }(),
            LosslessTell(:final id, :final why) => 'tell $id ${why?.name}',
          },
      ];
    }

    test('those who want it have it, six at most, the first first; one goes, the next has it', () {
      for (var i = 0; i < 8; i++) {
        come('p$i');
      }
      expect(second(), ['end p7 full', 'end p6 full']);
      expect(desk.having, 6);
      expect(second(), isEmpty, reason: 'said once');
      desk.gone('p2');
      how.remove('p2');
      expect(second(), ['begin p6']);
      for (final id in how.keys.toList()) {
        grow(id, bytes: 125000);
      }
      second();
      expect(desk.bitsPerSecond, closeTo(6e6, 1e4), reason: 'what it takes is told');
    });

    test('who does not want it isn\'t sent it, and is when they do; a build from before it has no room for it', () {
      come('speakers', wants: false);
      come('old', wants: true, channel: false);
      expect(second(), ['end speakers off']);
      expect(second(), isEmpty);
      desk.said('speakers', wants: true);
      expect(second(), ['begin speakers']);
      desk.said('speakers', wants: false);
      expect(second(), ['end speakers off']);
      desk.said('nobody', wants: true);
      expect(second(), isEmpty);
    });

    test('never over a relay: such a connection takes no place, is told after a while, and begins if it goes direct', () {
      for (var i = 0; i < 7; i++) {
        come('p$i');
      }
      how['p0'] = (open: true, bytes: 0, dropped: 0, relay: true);
      expect(second(), isEmpty, reason: 'six of seven go direct');
      expect(desk.having, 6);
      expect(second(9), isEmpty);
      expect(second(2), ['tell p0 relay']);
      expect(second(60), isEmpty);
      grow('p0');
      expect(second(), ['tell p0 null', 'end p6 full']);
    });

    test('one who can\'t keep up has the Opus for a while, longer each time, and a short while again once it goes well', () {
      come('slow');
      come('fine');
      second();
      for (final minutes in [1, 2, 4, 8, 8]) {
        grow('slow', dropped: 9);
        expect(second(), isEmpty, reason: 'a few are let go by');
        grow('slow', dropped: 3);
        expect(second(), ['end slow slow']);
        expect(second(minutes * 60 - 2), isEmpty);
        expect(second(2), ['begin slow']);
      }
      now = now.add(const Duration(minutes: 11));
      grow('slow', dropped: 12);
      expect(second(), ['end slow slow']);
      expect(second(61), ['begin slow']);
      expect(desk.cap, 6, reason: 'theirs, not this device\'s');
      // Dropped now and then, never ten in ten seconds, is let be.
      for (var i = 0; i < 20; i++) {
        grow('fine', dropped: 3);
        expect(second(4), isEmpty);
      }
      // Said by the listener itself, which heard it.
      desk.said('fine', wants: false, slow: true);
      expect(second(), ['end fine slow']);
      expect(second(60), ['begin fine']);
    });

    test('several at once is this device\'s own connection: fewer have it, and one more again after a good while', () {
      for (var i = 0; i < 4; i++) {
        come('p$i');
      }
      second();
      for (var i = 0; i < 4; i++) {
        grow('p$i', dropped: 12);
      }
      expect(second(), ['end p3 full']);
      expect(desk.cap, 3);
      for (var i = 0; i < 3; i++) {
        grow('p$i', dropped: 12);
      }
      expect(second(), ['end p2 full']);
      expect(second(299), isEmpty);
      expect(second(), ['begin p3'], reason: 'the one waiting longest');
      for (final id in ['p0', 'p1', 'p3']) {
        grow(id, dropped: 12);
      }
      second();
      for (final id in how.keys.toList()) {
        grow(id, dropped: 12);
      }
      second();
      expect(desk.cap, 1);
      grow('p0', dropped: 12);
      expect(second(), ['end p0 slow', startsWith('begin ')], reason: 'never below one');
      desk.clear();
      expect((desk.cap, desk.having, desk.isEmpty), (6, 0, true));
    });

    test('whether a connection goes through a relay, as WebRTC says', () {
      rtc.StatsReport r(String id, String type, Map<String, Object?> v) => rtc.StatsReport(id, type, 0, v);
      List<rtc.StatsReport> way(String? mine, String? theirs, {bool chosen = true}) => [
            r('T', 'transport', {if (chosen) 'selectedCandidatePairId': 'P'}),
            r('P', 'candidate-pair', {'localCandidateId': 'L', 'remoteCandidateId': 'R'}),
            r('L', 'local-candidate', {'candidateType': ?mine}),
            r('R', 'remote-candidate', {'candidateType': ?theirs}),
          ];
      expect(WindowsMusic.relayed(way('host', 'srflx')), isFalse);
      expect(WindowsMusic.relayed(way('relay', 'host')), isTrue);
      expect(WindowsMusic.relayed(way('prflx', 'relay')), isTrue);
      expect(WindowsMusic.relayed(way('host', null)), isNull);
      expect(WindowsMusic.relayed(way('host', 'host', chosen: false)), isNull);
      expect(WindowsMusic.relayed(const []), isNull);
    });
  });

  group('in a call', () {
    setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));
    late FakeHub hub;
    late VoiceChannel channel;
    final devices = <Someone>[];
    setUp(() {
      hub = FakeHub();
      channel = VoiceChannel.make('Friday');
    });
    tearDown(() async {
      for (final d in devices) {
        d.music.followSession(null);
        await d.session.leave();
      }
      devices.clear();
      await settle();
    });
    Someone someone(String id, {bool dj = false, FakeSink? sink}) {
      final d = Someone(hub, channel, id, dj: dj, sink: sink);
      devices.add(d);
      return d;
    }

    Future<(Someone, Someone)> playing({FakeSink? sink, bool relay = false}) async {
      final maya = someone('maya', dj: true)..relay = relay, sam = someone('sam', sink: sink ?? FakeSink());
      await maya.join();
      await sam.join();
      expect(await maya.music.start(), isTrue);
      await maya.music.add('spotify:track:$track');
      await settle();
      return (maya, sam);
    }

    test('a listener with headphones is sent it beside the Opus, and told; both see how it goes', () async {
      final (maya, sam) = await playing();
      expect(maya.source.log, contains('offer sam with a channel'));
      expect(sam.ear.take, isTrue);
      expect(sam.music.hearingLossless, isFalse);
      expect(sam.music.losslessWords, isNull, reason: 'on its way');
      sam.ear.onState(true);
      sam.ear.onLossless(true, null);
      expect(sam.music.hearingLossless, isTrue);
      maya.source.ways['sam'] = (open: true, bytes: 0, dropped: 0, relay: false);
      await maya.look();
      maya.source.ways['sam'] = (open: true, bytes: 125000, dropped: 0, relay: false);
      await maya.look();
      expect((maya.music.sentLossless, maya.music.listeners), (1, 1));
      expect(maya.music.losslessBits, closeTo(1e6, 1e3));
      expect(maya.music.capturedLow, isFalse);
      maya.source.hz = 24000;
      await maya.look();
      expect(maya.music.capturedLow, isTrue);
      // Stopped: nothing is left of it.
      await maya.music.stop();
      await settle();
      expect((maya.music.sentLossless, maya.music.capturedLow), (0, false));
      expect(sam.music.hearingLossless, isFalse);
    });

    test('a build from before it, on either side, has the Opus as ever', () async {
      final (maya, sam) = await playing();
      // An older listener says nothing of it.
      final zoe = someone('zoe');
      await zoe.join();
      await settle();
      expect(maya.source.log, contains('offer zoe'));
      await maya.look();
      expect(maya.source.ways.keys, ['sam']);
      expect(zoe.music.losslessCan, isFalse);
      expect(zoe.music.losslessWords, contains('high quality'));
      // An older DJ offers no channel and says nothing back.
      sam.session.onMusic!('maya', {'k': 'offer', 'to': 'sam', 'l': 'mark', 'sdp': 'plain'});
      await settle();
      sam.ear.onState(true);
      expect(sam.music.hearing, isTrue);
      expect(sam.music.hearingLossless, isFalse);
      expect(sam.music.losslessWords, contains('DJ\'s version'));
      final said = sam.out.length;
      sam.sink!.where = const MusicWay(MusicTo.speakers, 48000);
      sam.music.setVolume(50);
      await sam.lookWay();
      expect(sam.out.skip(said).where((m) => m['k'] == 'll'), isEmpty);
    });

    test('never asked over the relay: every path is tried first, and the relay alone carries Opus alone', () async {
      final (maya, sam) = await playing(relay: true);
      expect(maya.source.log.where((l) => l.startsWith('offer')), ['offer sam with a channel'], reason: 'every path first');
      // It did not get through: asked again, and the relay this time, with no channel.
      maya.now = sam.now = maya.now.add(const Duration(seconds: 10));
      sam.session.sayMusic({'k': 'ask', 'to': 'maya', 'n': 1, 'll': 1});
      await settle();
      expect(maya.source.log.last == 'offer sam by the relay' || maya.source.log.contains('offer sam by the relay'), isTrue);
      expect(maya.source.ways, isEmpty);
      expect(sam.music.losslessWords, contains('relay'));
      // Someone who takes no lossless goes by the relay first, as before.
      final zoe = someone('zoe');
      await zoe.join();
      await settle();
      expect(maya.source.log, contains('offer zoe by the relay'));
      await maya.look();
      expect(maya.source.ways, isEmpty);
    });

    test('on speakers it is not asked for; with headphones put on it is, at once where there is room', () async {
      final sink = FakeSink()..where = const MusicWay(MusicTo.speakers, 48000);
      final (maya, sam) = await playing(sink: sink);
      expect(maya.source.log, contains('offer sam with a channel'), reason: 'room, for later');
      expect(sam.ear.take, isFalse);
      expect(sam.music.losslessWords, contains('headphones'));
      expect(sam.music.asksHeadphones, isFalse, reason: 'they are speakers');
      await maya.look();
      expect(maya.source.log.last, 'lossless sam off');
      sink.where = const MusicWay(MusicTo.headphones, 48000);
      await sam.lookWay();
      expect(sam.ear.take, isTrue);
      expect(sam.ears, hasLength(1), reason: 'no new connection');
      await maya.look();
      expect(maya.source.log.last, 'lossless sam on');
      expect(sam.music.losslessWords, isNull);
      // Taken off again: at once, here, whatever the DJ's does.
      sink.where = const MusicWay(MusicTo.speakers, 48000);
      await sam.lookWay();
      expect(sam.ear.take, isFalse);
      await maya.look();
      expect(maya.source.log.last, 'lossless sam off');
      // The system can't tell, and the person says so: of what they hear it on now, and of nothing else.
      sink.where = const MusicWay(MusicTo.unknown, 48000, 'usb box');
      await sam.lookWay();
      expect(sam.ear.take, isFalse);
      expect(sam.music.asksHeadphones, isTrue);
      expect(sam.music.losslessWords, contains('can\'t tell'));
      sam.music.setHeadphones(true);
      await settle();
      expect(sam.ear.take, isTrue);
      expect(sam.music.asksHeadphones, isTrue, reason: 'to take it back');
      sink.where = const MusicWay(MusicTo.unknown, 48000, 'the television');
      await sam.lookWay();
      expect((sam.ear.take, sam.music.headphones), (false, false));
      sink.where = const MusicWay(MusicTo.speakers, 48000, 'usb box');
      await sam.lookWay();
      expect(sam.ear.take, isFalse, reason: 'what the system knows is believed before it');
      sink.where = const MusicWay(MusicTo.unknown, 48000, 'usb box');
      await sam.lookWay();
      expect(sam.ear.take, isTrue);
      sam.music.setHeadphones(false);
      await settle();
      expect(sam.ear.take, isFalse);
      sink.where = const MusicWay(MusicTo.unknown, 48000);
      await sam.lookWay();
      expect(sam.music.asksHeadphones, isFalse, reason: 'nothing to remember it by');
    });

    test('through the relay when there was no use for it, it is connected again once there is', () async {
      final sink = FakeSink()..where = const MusicWay(MusicTo.speakers, 48000);
      final (maya, sam) = await playing(sink: sink, relay: true);
      expect(maya.source.log, contains('offer sam by the relay'));
      sink.where = const MusicWay(MusicTo.headphones, 44100);
      maya.now = maya.now.add(const Duration(seconds: 5));
      await sam.lookWay();
      await settle();
      expect(maya.source.log, contains('offer sam with a channel'));
      expect(sam.ears.first.closed, isTrue);
    });

    test('a headset in a call, the switch, and no device: each is said in its own words', () async {
      final sink = FakeSink()..where = const MusicWay(MusicTo.callHeadset, 16000);
      final (_, sam) = await playing(sink: sink);
      expect(sam.music.losslessWords, contains('Bluetooth'));
      sink.where = const MusicWay(MusicTo.headphones, 16000);
      await sam.lookWay();
      expect(sam.music.losslessWords, contains('Bluetooth'), reason: 'at a call\'s rate, whatever it says it is');
      sam.music.setLossless(false);
      await settle();
      expect(sam.music.losslessWords, contains('off on this device'));
      expect(sam.app.choice(SpotifyMusic.losslessKey, ''), '0', reason: 'kept');
      sink.where = const MusicWay(MusicTo.headphones, 48000);
      await sam.lookWay();
      expect(sam.ear.take, isFalse, reason: 'switched off it stays off');
      sam.music.setLossless(true);
      await settle();
      expect(sam.ear.take, isTrue);
      expect(sam.music.losslessWords, isNull);
    });

    test('a listener who can\'t keep up says so, has the Opus, and is begun again after a minute', () async {
      final (maya, sam) = await playing();
      sam.ear.onState(true);
      sam.ear.onLossless(true, null);
      sam.ear.onLossless(false, LosslessWhy.slow);
      await settle();
      expect(sam.music.losslessWords, contains('keep up'));
      await maya.look();
      expect(maya.source.log.last, 'lossless sam off');
      for (var i = 0; i < 12; i++) {
        await maya.look(seconds: 5);
      }
      expect(maya.source.log.last, 'lossless sam on');
      expect(sam.music.losslessWords, isNull);
      // A player that could not be opened is not tried over and over.
      sam.ear.onLossless(false, LosslessWhy.sink);
      await settle();
      for (var i = 0; i < 40; i++) {
        await maya.look(seconds: 30);
      }
      expect(maya.source.log.last, 'lossless sam off');
      expect(sam.music.losslessWords, contains('player'));
    });

    test('nothing of it is taken from anyone but who it is between, nor of any shape but its own', () async {
      final (maya, sam) = await playing();
      final zoe = someone('zoe', sink: FakeSink());
      await zoe.join();
      await settle();
      final mark = sam.heardOffers.last['l'];
      await maya.look();
      final before = maya.source.log.length;
      for (final m in [
        {'k': 'll', 'to': 'maya', 'l': mark, 'w': 0},
        {'k': 'll', 'to': 'maya', 'w': 0},
        {'k': 'll', 'to': 'maya', 'l': 7, 'w': 0},
      ]) {
        zoe.session.sayMusic(m);
      }
      zoe.session.sayMusic({'k': 'll', 'to': 'sam', 'l': mark, 'w': 'slow'});
      await settle();
      expect(sam.music.losslessWords, isNull, reason: 'not the DJ');
      for (final w in [7, null, {'x': 1}, 'made up', 'slow' * 1000]) {
        maya.session.sayMusic({'k': 'll', 'to': 'sam', 'l': mark, 'w': w});
      }
      maya.session.sayMusic({'k': 'll', 'to': 'sam', 'l': 'another', 'w': 'slow'});
      for (final ll in ['1', true, 2, -1, {}, 1.5]) {
        maya.now = maya.now.add(const Duration(seconds: 5));
        zoe.session.sayMusic({'k': 'ask', 'to': 'maya', 'n': 0, 'll': ll});
        await settle();
        expect(maya.source.log.where((l) => l.startsWith('offer')).last, 'offer zoe', reason: '$ll is as nothing said');
      }
      await settle();
      expect(sam.music.losslessWords, isNull);
      expect(sam.music.hearing, isFalse);
      await maya.look();
      expect(maya.source.log.skip(before).where((l) => l.startsWith('lossless sam')), isEmpty);
      // The asking is bounded, as everything asked is.
      for (var i = 0; i < 100; i++) {
        sam.session.sayMusic({'k': 'll', 'to': 'maya', 'l': mark, 'w': i % 2});
      }
      await settle();
      expect(maya.music.mine, isTrue);
    });

    test('its loudness, deafened and the speaker go to it as to the Opus', () async {
      final (_, sam) = await playing();
      expect((sam.ear.volume, sam.ear.silent, sam.ear.plays, sam.ear.speaker), (0.6, false, true, ''));
      sam.music.setVolume(25);
      sam.session.setDeafened(true);
      await settle();
      expect((sam.ear.volume, sam.ear.silent), (0.25, true));
      sam.speaker.value = 'the headset';
      await settle();
      expect(sam.ear.speaker, 'the headset');
      expect(sam.sink!.asked, contains('the headset'));
    });
  });

  group('over a connection', () {
    testWidgets('the Opus is heard until it has played cleanly for a second, and at once when it stops: never both', (tester) async {
      late final _Pc pc;
      RtcMedia.connect = (c) async => pc = _Pc();
      final sink = FakeSink();
      RtcMusicEar.makeSink = () => sink;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (_) async => null);
      addTearDown(() {
        RtcMedia.connect = null;
        RtcMusicEar.makeSink = MusicSink.here;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), null);
      });
      final heard = <(bool, LosslessWhy?)>[];
      final ear = RtcMusicEar(servers: const [], relayOnly: false, onCandidate: (_) {}, onState: (_) {}, onLossless: (on, why) => heard.add((on, why)));
      await ear.takeOffer('v=0');
      final opus = _Track();
      pc.onTrack!(_Came(opus));
      ear.set(volume: 0.5, silent: false);
      ear.playing(true);
      unawaited(ear.output('phones'));

      // Not to be taken, or another's label: shut at once.
      final early = _Channel('music'), odd = _Channel('files');
      pc.onDataChannel!(early);
      ear.lossless(true);
      pc.onDataChannel!(odd);
      expect((early.shut, odd.shut), (true, true));

      var next = 5000;
      Future<void> go(_Channel c, int chunks) async {
        for (var i = 0; i < chunks; i++) {
          c.say(plainChunk(next, block(next)));
          next += n;
          await tester.pump(const Duration(milliseconds: 40));
          sink.play(n);
          expect(opus.enabled && !sink.silent && sink.running, isFalse, reason: 'never both');
        }
      }

      final one = _Channel('music');
      pc.onDataChannel!(one);
      await go(one, 30);
      expect((opus.enabled, sink.silent), (true, true));
      await go(one, 30);
      expect((opus.enabled, sink.silent, sink.volume, sink.device), (false, false, 0.5, 'phones'));
      expect(heard, [(true, null)]);
      expect(await ear.level(), greaterThan(0.2));
      // Deafened: neither.
      ear.set(volume: 0.5, silent: true);
      expect((opus.enabled, sink.silent), (false, true));
      ear.set(volume: 0.8, silent: false);
      expect((opus.enabled, sink.silent, sink.volume), (false, false, 0.8));
      // Text, or what is no chunk, plays nothing.
      one.onMessage!(rtc.RTCDataChannelMessage('1'));
      // The DJ shut it: the Opus, at once.
      one.onDataChannelState!(rtc.RTCDataChannelState.RTCDataChannelClosed);
      expect((opus.enabled, sink.closed), (true, true));
      expect(heard, [(true, null), (false, null)]);
      one.say(plainChunk(next, block(next)));

      // Another, later, on the same connection; and then not to be taken any more.
      sink
        ..closed = false
        ..waiting = 0;
      final two = _Channel('music');
      pc.onDataChannel!(two);
      await go(two, 60);
      expect(opus.enabled, isFalse);
      ear.lossless(false);
      expect((opus.enabled, sink.closed, two.shut), (true, true, true));
      await ear.close();
    });

    test('a PC sends chunks the native half made, on an ordered channel beside the one track, and only then are they made', () async {
      late _Pc pc;
      RtcMedia.connect = (c) async => pc = _Pc();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(SpotifyChannel.channel, (call) async {
        calls.add('${call.method} ${call.arguments}');
        return call.method == 'begin' ? 'the-music' : null;
      });
      addTearDown(() {
        RtcMedia.connect = null;
        messenger.setMockMethodCallHandler(SpotifyChannel.channel, null);
      });
      Future<void> made(Uint8List chunk) async {
        await messenger.handlePlatformMessage('ghost/spotify', const StandardMethodCodec().encodeMethodCall(MethodCall('chunk', chunk)), (_) {});
        await settle();
      }

      final m = WindowsMusic(const VoiceSettings());
      await m.begin();
      await m.offer('old', servers: const [], relayOnly: false, lossless: false);
      expect(pc.channels, isEmpty);
      await m.offer('sam', servers: const [], relayOnly: false, lossless: true);
      final c = pc.channels.single;
      expect((c.label, c.how!.ordered, c.how!.negotiated, c.how!.id, c.how!.maxRetransmits <= 0), ('music', true, false, -1, true), reason: 'in order, and nothing given up by WebRTC');
      expect(calls.last, 'pack {on: true}');
      final chunk = Uint8List.fromList(List.filled(500, 7));
      await made(chunk);
      c.onDataChannelState!(rtc.RTCDataChannelState.RTCDataChannelOpen);
      await made(chunk);
      expect(c.sent, isEmpty, reason: 'whether it goes through a relay isn\'t known');
      pc.relay = true;
      expect((await m.losslessState())['sam']!.relay, isTrue);
      await made(chunk);
      expect(c.sent, isEmpty, reason: 'it does');
      pc.relay = false;
      expect((await m.losslessState())['sam'], (open: true, bytes: 0, dropped: 0, relay: false));
      await made(chunk);
      expect(c.sent.single, chunk);
      expect((await m.losslessState())['sam'], (open: true, bytes: 500, dropped: 0, relay: false));
      await m.lossless('sam', on: false);
      expect(c.shut, isTrue);
      expect(calls.last, 'pack {on: false}');
      expect(await m.losslessState(), isEmpty);
      await m.lossless('sam', on: true);
      expect(pc.channels, hasLength(2));
      expect(calls.last, 'pack {on: true}');
      await m.end();
      expect(pc.channels.last.shut, isTrue);
      expect(calls.sublist(calls.length - 2), ['pack {on: false}', 'end null']);
    });
  });

  group('this device\'s own player, by its channel', () {
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ChannelSink.channel, null));
    test('what the native half says is read, and anything else is nothing', () async {
      Object? answer;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ChannelSink.channel, (c) async {
        calls.add(c);
        return answer;
      });
      final s = ChannelSink();
      for (final (said, way) in [
        ({'to': 'headphones', 'rate': 48000.0}, const MusicWay(MusicTo.headphones, 48000)),
        ({'to': 'call', 'rate': 16000}, const MusicWay(MusicTo.callHeadset, 16000)),
        ({'to': 'none'}, const MusicWay(MusicTo.none, 0)),
        ({'to': 'unknown', 'rate': 48000, 'id': 'usb'}, const MusicWay(MusicTo.unknown, 48000, 'usb')),
        ({'to': 'something new', 'rate': 44100}, const MusicWay(MusicTo.speakers, 44100)),
        (null, const MusicWay(MusicTo.none, 0)),
      ]) {
        answer = said;
        expect(await s.way('x'), way);
      }
      answer = [960, 2];
      final w = (await s.write(Uint8List(4)))!;
      expect((w.waiting, w.dry), (960, 2));
      answer = ['x'];
      expect(await s.write(Uint8List(4)), isNull);
      answer = null;
      expect(await s.open('x'), isFalse);
      await s.set(volume: 0.5, silent: true);
      expect(calls.last.arguments, {'volume': 0.5, 'silent': true});
    });

    test('with no native half at all, nothing can be played', () async {
      final s = ChannelSink();
      expect(await s.open(''), isFalse);
      expect(await s.write(Uint8List(4)), isNull);
      expect((await s.way('')).to, MusicTo.none);
      await s.close();
    });
  });
}

/// One device in the call: the DJ's, or a listener's with a player or without.
class Someone {
  Someone(this.hub, VoiceChannel channel, this.id, {this.dj = false, this.sink}) : session = VoiceSession(channel: channel, route: FakeRoute(hub, id), media: FakeMedia(), name: id);
  final FakeHub hub;
  final String id;
  final bool dj;
  final FakeSink? sink;
  final VoiceSession session;
  final spotify = FakeSpotify();
  final source = FakeSource();
  final List<FakeEar> ears = [];
  final app = AppState();
  final speaker = ValueNotifier('');
  DateTime now = DateTime(2026, 11, 25, 20);
  bool relay = false;

  /// What this device heard of offers, and what it said of the music's way.
  final List<Map<String, dynamic>> heardOffers = [], out = [];

  late final music = SpotifyMusic.forTest(
    isOn: () => true,
    maySpeak: (_) => true,
    app: () => dj ? spotify : null,
    source: () => dj ? source : null,
    makeEar: ({required servers, required relayOnly, required onCandidate, required onState, required onLossless}) {
      final e = FakeEar(servers, relayOnly, onCandidate, onState, onLossless);
      ears.add(e);
      return e;
    },
    clock: () => now,
    ways: () => (servers: const [], relay: relay),
    store: app,
    player: () => sink,
    speaker: () => speaker,
  );

  FakeEar get ear => ears.last;

  Future<void> join() async {
    await session.join();
    music.followSession(session);
    final heard = session.onMusic!;
    session.onMusic = (from, m) {
      if (m['k'] == 'offer' && m['to'] == id) heardOffers.add(m);
      heard(from, m);
    };
    await settle();
  }

  /// Where the sound goes is looked at, as it is every two seconds.
  Future<void> lookWay() async {
    speaker.value = '${speaker.value} ';
    await settle();
  }

  Future<void> look({int seconds = 1}) async {
    now = now.add(Duration(seconds: seconds));
    spotify.to(50);
    await music.look();
    await settle();
  }
}

class _Track implements rtc.MediaStreamTrack {
  @override
  String? id = 'opus';
  @override
  String? kind = 'audio';
  @override
  bool enabled = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Came implements rtc.RTCTrackEvent {
  _Came(this.track);
  @override
  final rtc.MediaStreamTrack track;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Channel implements rtc.RTCDataChannel {
  _Channel(this.label, [this.how]);
  @override
  final String label;
  final rtc.RTCDataChannelInit? how;
  final List<Uint8List> sent = [];
  bool shut = false;
  @override
  void Function(rtc.RTCDataChannelMessage data)? onMessage;
  @override
  void Function(rtc.RTCDataChannelState state)? onDataChannelState;
  void say(Uint8List b) => onMessage?.call(rtc.RTCDataChannelMessage.fromBinary(b));
  @override
  Future<void> send(rtc.RTCDataChannelMessage message) async => sent.add(message.binary);
  @override
  Future<int> getBufferedAmount() async => 0;
  @override
  Future<void> close() async => shut = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Pc implements rtc.RTCPeerConnection {
  final List<_Channel> channels = [];
  bool relay = false;
  @override
  void Function(rtc.RTCTrackEvent event)? onTrack;
  @override
  void Function(rtc.RTCDataChannel channel)? onDataChannel;
  @override
  void Function(rtc.RTCIceCandidate candidate)? onIceCandidate;
  @override
  void Function(rtc.RTCPeerConnectionState state)? onConnectionState;
  static const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  @override
  Future<rtc.RTCDataChannel> createDataChannel(String label, rtc.RTCDataChannelInit how) async {
    final c = _Channel(label, how);
    channels.add(c);
    return c;
  }

  @override
  Future<List<rtc.StatsReport>> getStats([rtc.MediaStreamTrack? track]) async => [
        rtc.StatsReport('T', 'transport', 0, {'selectedCandidatePairId': 'P'}),
        rtc.StatsReport('P', 'candidate-pair', 0, {'localCandidateId': 'L', 'remoteCandidateId': 'R'}),
        rtc.StatsReport('L', 'local-candidate', 0, {'candidateType': 'host'}),
        rtc.StatsReport('R', 'remote-candidate', 0, {'candidateType': relay ? 'relay' : 'host'}),
      ];
  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({rtc.MediaStreamTrack? track, rtc.RTCRtpMediaType? kind, rtc.RTCRtpTransceiverInit? init}) async => _Way();
  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async => rtc.RTCSessionDescription(sdp, 'offer');
  @override
  Future<rtc.RTCSessionDescription> createAnswer([Map<String, dynamic>? constraints]) async => rtc.RTCSessionDescription(sdp, 'answer');
  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription d) async {}
  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription d) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Way implements rtc.RTCRtpTransceiver {
  @override
  final rtc.RTCRtpSender sender = _Sender();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Sender implements rtc.RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
