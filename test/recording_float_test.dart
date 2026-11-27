import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/recording_float.dart';
import 'package:ghost_messaging/ui/recording_ui.dart' show RecordingBanner;
import 'package:ghost_messaging/ui/space_designs/space_design.dart' show CallBanners;
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/voice/recorder.dart';
import 'package:ghost_messaging/voice/recording_playback.dart';

import 'support/list_harness.dart';

/// The recording over the app (lib/ui/recording_float.dart; Matt, 2026-11-20: "show the different audio tracks being
/// recorded and the sound waves from each audio track, collapse it to a button that can be moved around the app when
/// expanded the tracks and stuff should appear similar to adobe premiere"). Pictures in build/themes/recording.
void main() {
  test('the meter reads each voice\'s file a tenth of a second at a time, the loudest sample of each', () {
    final dir = Directory.systemTemp.createTempSync('ghost-meter');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/me.pcm');
    // Two and a half steps: silence, a step peaking at half, and half a step not yet whole.
    final d = ByteData(RecordingMeter.step * 2 * 2 + RecordingMeter.step);
    d.setInt16((RecordingMeter.step + 10) * 2, 16384, Endian.little);
    d.setInt16((RecordingMeter.step + 20) * 2, -8000, Endian.little);
    f.writeAsBytesSync(d.buffer.asUint8List());
    final m = RecordingMeter();
    m.read({'me': f.path});
    expect(m.levels['me'], [0.0, 0.5]);
    // The rest of the third step comes: it is read, and only it.
    f.writeAsBytesSync(Uint8List(RecordingMeter.step), mode: FileMode.append);
    m.read({'me': f.path, 'gone': '${dir.path}/none.pcm'});
    expect(m.levels['me'], [0.0, 0.5, 0.0]);
    expect(m.levels.containsKey('gone'), isFalse);
  });

  test('the meter says each voice now: its peak and its average power, silence once it stops, and a clip that stays', () {
    final dir = Directory.systemTemp.createTempSync('ghost-meter-now');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/me.pcm');
    // A window of a square wave at half scale: its peak and its RMS are both a half.
    final d = ByteData(RecordingMeter.window * 2);
    for (var i = 0; i < RecordingMeter.window; i++) {
      d.setInt16(i * 2, i.isEven ? 16384 : -16384, Endian.little);
    }
    f.writeAsBytesSync(d.buffer.asUint8List());
    final m = RecordingMeter();
    m.read({'me': f.path});
    expect(m.now['me']!.peak, closeTo(0.5, 0.001));
    expect(m.now['me']!.rms, closeTo(0.5, 0.001));
    expect(m.clipped, isEmpty);
    // Nothing more written: the voice has stopped, and its meter falls to nothing.
    m.read({'me': f.path});
    expect(m.now['me'], (peak: 0.0, rms: 0.0));
    // A sample at the top: clipped, and still so after quieter sound, until cleared.
    final loud = ByteData(RecordingMeter.window * 2)..setInt16(100, 32767, Endian.little);
    f.writeAsBytesSync(loud.buffer.asUint8List(), mode: FileMode.append);
    m.read({'me': f.path});
    expect(m.clipped, {'me'});
    f.writeAsBytesSync(Uint8List(RecordingMeter.window * 2), mode: FileMode.append);
    m.read({'me': f.path});
    expect(m.now['me']!.peak, 0);
    expect(m.clipped, {'me'});
    m.clearClip('me');
    expect(m.clipped, isEmpty);
  });

  test('the mixer keeps each change with its moment: a fader, a mute, and a solo that takes the others out', () {
    final mix = RecordingMix();
    expect(mix.gain('a'), 1);
    expect(mix.points('a'), isEmpty);
    mix.setFader('a', 0.5, 48000);
    // Dragged on in the same moment: one point, the last value.
    mix.setFader('a', 0.25, 48000);
    expect(mix.points('a'), [(sample: 48000, gain: 0.25)]);
    mix.setFader('a', 9, 96000);
    expect(mix.fader('a'), RecordingMix.most, reason: 'held to +6 dB');
    mix.setMuted('a', true, 144000);
    expect(mix.gain('a'), 0);
    expect(mix.fader('a'), RecordingMix.most, reason: 'the fader stays where it was under the mute');
    mix.setMuted('a', false, 192000);
    expect(mix.points('a').map((p) => p.gain), [0.25, 2.0, 0.0, 2.0]);
    // A solo moves the others: b and c leave the mix, and come back when it ends.
    mix.setSolo('b', true, 240000, among: ['a', 'b', 'c']);
    expect([mix.gain('a'), mix.gain('b'), mix.gain('c')], [0.0, 1.0, 0.0]);
    expect(mix.points('b'), isEmpty, reason: 'b itself is as it was');
    expect(mix.points('c'), [(sample: 240000, gain: 0.0)]);
    mix.setSolo('b', false, 288000, among: ['a', 'b', 'c']);
    expect(mix.points('c'), [(sample: 240000, gain: 0.0), (sample: 288000, gain: 1.0)]);
    expect(mix.gainAt('c', 250000), 0);
    expect(mix.gainAt('c', 300000), 1);
    expect(mix.gainAt('a', 0), 1, reason: 'as recorded before its first change');
  });

  test('the mix follows the faders as they were moved, with no click at a change; each voice\'s own file is untouched', () {
    final dir = Directory.systemTemp.createTempSync('ghost-mix-gain');
    addTearDown(() => dir.deleteSync(recursive: true));
    // Two voices, three seconds each, steady at 8000 and 4000.
    File steady(String name, int value) {
      final d = ByteData(48000 * 3 * 2);
      for (var i = 0; i < 48000 * 3; i++) {
        d.setInt16(i * 2, value, Endian.little);
      }
      return File('${dir.path}/$name.pcm')..writeAsBytesSync(d.buffer.asUint8List());
    }

    final a = steady('a', 8000), b = steady('b', 4000);
    final before = a.readAsBytesSync();
    // a: halved from the first second, muted from the second (across a block's edge). b: as recorded.
    mixPcm([a.path, b.path], '${dir.path}/mix.pcm', gains: [
      [(sample: 48000, gain: 0.5), (sample: 96000, gain: 0.0)],
      const [],
    ]);
    final d = ByteData.sublistView(File('${dir.path}/mix.pcm').readAsBytesSync());
    int at(int sample) => d.getInt16(sample * 2, Endian.little);
    expect(d.lengthInBytes, 48000 * 3 * 2);
    expect(at(100), 12000, reason: 'both as recorded');
    expect(at(47999), 12000);
    expect(at(48000 + 2000), 8000, reason: 'a at half, b whole');
    expect(at(96000 + 2000), 4000, reason: 'a out of the mix');
    expect(at(48000 * 3 - 1), 4000);
    // Reached over a hundredth of a second, never a step: no two samples differ by more than a few.
    var jump = 0;
    for (var i = 1; i < 48000 * 3; i++) {
      jump = math.max(jump, (at(i) - at(i - 1)).abs());
    }
    expect(jump, lessThan(64));
    expect(a.readAsBytesSync(), before);
    // With no gains it is the plain sum.
    mixPcm([a.path, b.path], '${dir.path}/plain.pcm');
    expect(ByteData.sublistView(File('${dir.path}/plain.pcm').readAsBytesSync()).getInt16(100000 * 2, Endian.little), 12000);
  });

  for (final (size, at) in [('phone', const Size(412, 892)), ('wide', const Size(1100, 760))]) {
    for (final dark in [false, true]) {
      testWidgets('Mixer opens the tracks as a timeline in a drawer filling the window ($size, ${dark ? 'dark' : 'light'})', (tester) async {
        final rec = CallRecorder.standing(
          names: {'me': 'Matt', 'a1b2c3d4': 'Maya Chen', 'e5f6a7b8': 'Theo', 'c9d0e1f2': 'Sam Ortiz'},
          since: DateTime.now().subtract(const Duration(seconds: 47)),
          left: {'c9d0e1f2'},
          markers: [21.5],
        );
        rec.meter.seed({
          'me': _speech(470, seed: 1),
          'a1b2c3d4': _speech(470, seed: 2, from: 40),
          'e5f6a7b8': _speech(470, seed: 3, quiet: true),
          'c9d0e1f2': _speech(230, seed: 4),
        }, live: {
          'me': (peak: 0.62, rms: 0.31),
          'a1b2c3d4': (peak: 0.34, rms: 0.16),
          'e5f6a7b8': (peak: 0.99, rms: 0.5),
          'c9d0e1f2': (peak: 0, rms: 0),
        }, clipping: {'e5f6a7b8'});
        final sheet = await loadSheet(tester);
        await pumpScreen(
          tester,
          sheet,
          Builder(builder: (context) => GestureDetector(key: const ValueKey('open-mixer'), behavior: HitTestBehavior.opaque, onTap: () => showRecordingMixer(context, recorder: rec), child: const SizedBox.expand())),
          AppState()..set('theme', dark ? 'dark' : 'light'),
          size: at,
        );
        // Nothing floats over the app while recording: the banner's Mixer opens the drawer (recording_ui.dart).
        expect(find.byKey(const ValueKey('recording-float')), findsNothing);
        await tester.tap(find.byKey(const ValueKey('open-mixer')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final drawer = find.byKey(const ValueKey('recording-drawer'));
        expect(drawer, findsOneWidget);
        expect(tester.getSize(drawer), at, reason: 'the whole window');
        // The timeline: a header per track (the mix first) and the lanes.
        expect(find.byKey(const ValueKey('recording-timeline')), findsOneWidget);
        for (final k in ['*mix', 'me', 'a1b2c3d4', 'e5f6a7b8', 'c9d0e1f2']) {
          expect(find.byKey(ValueKey('recording-track-$k')), findsOneWidget, reason: k);
        }
        expect(find.text('Left'), findsOneWidget, reason: 'Sam left: their track keeps what it has');
        expect(find.text('A1'), findsOneWidget);
        // Every track has its meter; a voice has mute and solo, the mix has neither.
        for (final k in ['*mix', 'me', 'a1b2c3d4']) {
          expect(find.byKey(ValueKey('recording-lane-meter-$k')), findsOneWidget, reason: k);
        }
        expect(find.byKey(const ValueKey('recording-lane-mute-*mix')), findsNothing);
        // Maya muted in the mix: said to the recorder, and her lane's M is lit (the picture).
        await tester.tap(find.byKey(const ValueKey('recording-lane-mute-a1b2c3d4')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(rec.mix.muted('a1b2c3d4'), isTrue);
        expect(rec.mix.gain('a1b2c3d4'), 0);
        expect(rec.mix.points('a1b2c3d4').single.gain, 0);
        // A moment marked: a flag on the ruler, kept by the recorder.
        await tester.tap(find.byKey(const ValueKey('recording-mark')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(rec.markers, hasLength(2));
        expect(rec.markers.last, closeTo(47, 2));
        await _keep(tester, '$size-timeline-${dark ? 'dark' : 'light'}');
        // The mixer: a strip per track, a fader per voice.
        await tester.tap(find.byKey(const ValueKey('recording-view')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const ValueKey('recording-mixer')), findsOneWidget);
        expect(find.byKey(const ValueKey('recording-lanes')), findsNothing);
        expect(find.byKey(const ValueKey('recording-strip-*mix')), findsOneWidget);
        expect(find.byKey(const ValueKey('recording-fader-*mix')), findsNothing, reason: 'the mix is what the faders make');
        final fader = find.byKey(const ValueKey('recording-fader-me'));
        expect(fader, findsOneWidget);
        expect(tester.widget<Text>(find.byKey(const ValueKey('recording-gain-me'))).data, '0.0');
        // Dragged down, Matt is quieter in the mix; up past the notch, louder; pressed twice, as recorded again.
        await tester.drag(fader, const Offset(0, 60));
        await tester.pump(const Duration(milliseconds: 100));
        expect(rec.mix.fader('me'), lessThan(1));
        expect(rec.mix.points('me'), isNotEmpty);
        final quiet = rec.mix.fader('me');
        // Far enough to reach the head of a fader of any height (the drawer fills the window).
        await tester.drag(fader, const Offset(0, -1200));
        await tester.pump(const Duration(milliseconds: 100));
        expect(rec.mix.fader('me'), greaterThan(quiet));
        expect(tester.widget<Text>(find.byKey(const ValueKey('recording-gain-me'))).data, '+6.0', reason: 'the strip says what the fader is at');
        // The "Marked" toast gone first: in the drawer the strips reach the window's foot, where it shows.
        await tester.pump(const Duration(seconds: 8));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(find.byKey(const ValueKey('recording-solo-e5f6a7b8')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(rec.mix.gain('me'), 0, reason: 'Theo soloed: the others are out of the mix');
        expect(rec.mix.gain('e5f6a7b8'), 1);
        await _keep(tester, '$size-mixer-${dark ? 'dark' : 'light'}');
        await tester.tap(find.byKey(const ValueKey('recording-solo-e5f6a7b8')));
        await tester.pump(const Duration(milliseconds: 100));
        expect(rec.mix.gain('me'), greaterThan(0));
        // Back to the timeline.
        await tester.tap(find.byKey(const ValueKey('recording-view')));
        await tester.pump(const Duration(milliseconds: 200));
        expect(find.byKey(const ValueKey('recording-lanes')), findsOneWidget);
        // Closed, the app as it was.
        await tester.tap(find.byKey(const ValueKey('recording-collapse')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const ValueKey('recording-drawer')), findsNothing);
        expect(find.byKey(const ValueKey('open-mixer')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  // The pictures on gogho.st/docs/record-call (Matt, 2026-11-22: "include screenshots of the mixer and timeline from the
  // record call with many participants as an example"): a call of eight on a computer, in both themes, kept in
  // build/themes/recording/docs-*.png, made into site/shots/record-*.webp. The drawer is drawn dark in either theme.
  for (final dark in [true]) {
    testWidgets('the docs\' pictures: the timeline and the mixer of a call of eight (${dark ? 'dark' : 'light'})', (tester) async {
      await tester.runAsync(_fonts);
      const people = {
        'me': 'Matt', 'a1b2c3d4': 'Maya Chen', 'e5f6a7b8': 'Theo', 'c9d0e1f2': 'Sam Ortiz',
        'b3c4d5e6': 'Priya', 'f7a8b9c0': 'Jonah Reyes', 'd1e2f3a4': 'Lena', 'a5b6c7d8': 'Kofi Mensah',
      };
      final rec = CallRecorder.standing(
        names: people,
        since: DateTime.now().subtract(const Duration(minutes: 3, seconds: 12)),
        markers: [38.0, 121.5],
      );
      final ids = people.keys.toList();
      rec.meter.seed({
        for (var i = 0; i < ids.length; i++)
          ids[i]: _speech(1920, seed: 11 + i, from: i == 5 ? 260 : (i == 7 ? 90 : 0), quiet: i == 2 || i == 6),
      }, live: {
        'me': (peak: 0.58, rms: 0.29),
        'a1b2c3d4': (peak: 0.41, rms: 0.2),
        'e5f6a7b8': (peak: 0.12, rms: 0.05),
        'c9d0e1f2': (peak: 0.72, rms: 0.37),
        'b3c4d5e6': (peak: 0.05, rms: 0.02),
        'f7a8b9c0': (peak: 0.33, rms: 0.15),
        'd1e2f3a4': (peak: 0.27, rms: 0.12),
        'a5b6c7d8': (peak: 0.49, rms: 0.24),
      });
      // A mix being set: Sam brought down, Theo and Lena up, Kofi muted.
      rec.mix.setFader('c9d0e1f2', 0.6, 48000 * 60);
      rec.mix.setFader('e5f6a7b8', 0.88, 48000 * 70);
      rec.mix.setFader('d1e2f3a4', 0.82, 48000 * 80);
      rec.mix.setMuted('a5b6c7d8', true, 48000 * 150);
      final sheet = await loadSheet(tester);
      await pumpScreen(
        tester,
        sheet,
        Builder(builder: (context) => GestureDetector(key: const ValueKey('open-mixer'), behavior: HitTestBehavior.opaque, onTap: () => showRecordingMixer(context, recorder: rec), child: const SizedBox.expand())),
        AppState()..set('theme', dark ? 'dark' : 'light'),
        size: const Size(1280, 624),
      );
      await tester.tap(find.byKey(const ValueKey('open-mixer')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final k in ids) {
        expect(find.byKey(ValueKey('recording-track-$k')), findsOneWidget, reason: k);
      }
      await _keep(tester, 'docs-timeline-${dark ? 'dark' : 'light'}');
      await tester.tap(find.byKey(const ValueKey('recording-view')));
      await tester.pump(const Duration(milliseconds: 200));
      for (final k in ids) {
        expect(find.byKey(ValueKey('recording-strip-$k')), findsOneWidget, reason: k);
      }
      await _keep(tester, 'docs-mixer-${dark ? 'dark' : 'light'}');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('a saved recording\'s track decoded at another rate or in stereo becomes 48 kHz mono; its waveform and level read from it', () {
    final dir = Directory.systemTemp.createTempSync('ghost-playback');
    addTearDown(() => dir.deleteSync(recursive: true));
    // A second of stereo at 24 kHz: left at 0.5, right at 0.25.
    final raw = ByteData(24000 * 2 * 2);
    for (var i = 0; i < 24000; i++) {
      raw.setInt16(i * 4, 16384, Endian.little);
      raw.setInt16(i * 4 + 2, 8192, Endian.little);
    }
    File('${dir.path}/t.raw').writeAsBytesSync(raw.buffer.asUint8List());
    toMono48k('${dir.path}/t.raw', '${dir.path}/t.pcm', fromRate: 24000, channels: 2);
    final pcm = File('${dir.path}/t.pcm').readAsBytesSync();
    expect(pcm.length, 48000 * 2, reason: 'a second at 48 kHz, one channel');
    expect(ByteData.sublistView(pcm).getInt16(1000 * 2, Endian.little), 12288, reason: 'the channels averaged');
    // As made (48 kHz mono): a copy.
    toMono48k('${dir.path}/t.pcm', '${dir.path}/same.pcm', fromRate: 48000, channels: 1);
    expect(File('${dir.path}/same.pcm').readAsBytesSync(), pcm);
    final wave = waveform('${dir.path}/t.pcm');
    expect(wave, hasLength(10));
    expect(wave.first, closeTo(0.375, 0.001));
    final f = File('${dir.path}/t.pcm').openSync();
    addTearDown(f.closeSync);
    expect(levelAt(f, 24000).peak, closeTo(0.375, 0.001));
    expect(levelAt(f, 24000).rms, closeTo(0.375, 0.001));
    expect(levelAt(f, 96000), (peak: 0.0, rms: 0.0), reason: 'past its end');
    // A WAV for its player: the header says 48 kHz mono 16-bit and how much follows.
    wrapWav('${dir.path}/t.pcm', '${dir.path}/t.wav');
    final wav = ByteData.sublistView(File('${dir.path}/t.wav').readAsBytesSync());
    expect(String.fromCharCodes(File('${dir.path}/t.wav').readAsBytesSync().sublist(0, 4)), 'RIFF');
    expect(wav.getUint32(24, Endian.little), 48000);
    expect(wav.getUint16(22, Endian.little), 1);
    expect(wav.getUint32(40, Endian.little), 48000 * 2);
    expect(wav.lengthInBytes, 44 + 48000 * 2);
  });

  test('a recording mixed again in the mixer is kept with the one it came from', () {
    final r = Recording(id: 'rec2', path: '/x.mp4', space: 'general', at: DateTime(2026, 11, 21), seconds: 60, people: const ['Matt', 'Maya'], mixedFrom: 'rec1');
    final back = Recording.fromJson(r.toJson())!;
    expect(back.mixedFrom, 'rec1');
    expect(Recording.fromJson({...r.toJson()}..remove('from'))!.mixedFrom, isNull);
  });

  for (final (size, at) in [('phone', const Size(412, 892)), ('wide', const Size(1100, 760))]) {
    testWidgets('a saved recording opens in the timeline and the mixer, to play and mix again ($size)', (tester) async {
      // Matt, 2026-11-21: "I'd like to be able to open recordings saved from calls in the multi track view with the mixer".
      final r = Recording(id: 'rec-saved', path: '/none.mp4', space: 'general', at: DateTime(2026, 11, 21, 14, 5), seconds: 47, people: const ['Matt', 'Maya Chen', 'Theo'], markers: const [21.5]);
      final p = RecordingPlayback.standing(r, levels: {
        'v1': _speech(470, seed: 1),
        'v2': _speech(470, seed: 2, from: 40),
        'v3': _speech(470, seed: 3, quiet: true),
      }, atSecond: 12.4, now: {'v1': (peak: 0.5, rms: 0.25), 'v2': (peak: 0.3, rms: 0.12), 'v3': (peak: 0.05, rms: 0.02)});
      addTearDown(p.dispose);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, RecordingPlaybackDrawer(recording: r, playback: p), AppState()..set('theme', 'dark'), size: at);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('recording-timeline')), findsOneWidget);
      for (final k in ['*mix', 'v1', 'v2', 'v3']) {
        expect(find.byKey(ValueKey('recording-track-$k')), findsOneWidget, reason: k);
      }
      // Played, not recorded: Play and Save mix in place of the red dot and Stop; nothing to mark.
      expect(find.byKey(const ValueKey('recording-play')), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-save-mix')), findsOneWidget);
      expect(find.byKey(const ValueKey('recording-stop')), findsNothing);
      expect(find.byKey(const ValueKey('recording-mark')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('recording-timecode'))).data, contains('12'), reason: 'the time is the playhead\'s');
      // Pressed on the lanes: the playhead goes there.
      final lanes = find.byKey(const ValueKey('recording-lanes'));
      await tester.tapAt(tester.getTopLeft(lanes) + const Offset(48, 60));
      await tester.pump(const Duration(milliseconds: 100));
      expect(p.at, closeTo(2, 0.2), reason: 'two seconds in at 24 points a second');
      // Maya muted in the mix.
      await tester.tap(find.byKey(const ValueKey('recording-lane-mute-v2')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(p.mix.gain('v2'), 0);
      await _keep(tester, 'saved-$size-timeline');
      // The mixer: a fader per voice moves that voice in what is heard.
      await tester.tap(find.byKey(const ValueKey('recording-view')));
      await tester.pump(const Duration(milliseconds: 200));
      final fader = find.byKey(const ValueKey('recording-fader-v1'));
      expect(fader, findsOneWidget);
      await tester.drag(fader, const Offset(0, 60));
      await tester.pump(const Duration(milliseconds: 100));
      expect(p.mix.fader('v1'), lessThan(1));
      await _keep(tester, 'saved-$size-mixer');
      await tester.tap(find.byKey(const ValueKey('recording-view')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the drawer closes by itself a moment after the recording ends', (tester) async {
    final rec = CallRecorder.standing(names: {'me': 'Matt'}, since: DateTime.now().subtract(const Duration(seconds: 5)));
    final sheet = await loadSheet(tester);
    await pumpScreen(
      tester,
      sheet,
      Builder(builder: (context) => GestureDetector(key: const ValueKey('open-mixer'), behavior: HitTestBehavior.opaque, onTap: () => showRecordingMixer(context, recorder: rec), child: const SizedBox.expand())),
      AppState(),
    );
    await tester.tap(find.byKey(const ValueKey('open-mixer')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('recording-drawer')), findsOneWidget);
    rec.endForTest();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('recording-drawer')), findsOneWidget, reason: 'still there while the saved toast shows');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('recording-drawer')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the recording banner over the call has Mixer beside Stop, and Mixer opens the drawer', (tester) async {
    final v = Voice.instance;
    v.session = VoiceSession(channel: VoiceChannel.make('Lounge'), route: _NoRoute(), media: _NoMedia(), name: 'Matt')..recording = 'rec-1';
    addTearDown(() => v.session = null);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Align(alignment: Alignment.topCenter, child: RecordingBanner()), AppState());
    expect(find.byKey(const ValueKey('recording-mine')), findsOneWidget);
    expect(find.text('Mixer'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Mixer')).dx, lessThan(tester.getTopLeft(find.text('Stop')).dx), reason: 'Mixer first, Stop at the end');
    await tester.tap(find.text('Mixer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('recording-drawer')), findsOneWidget);
    // Nothing is recorded on this device here, so it closes again by itself.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('recording-drawer')), findsNothing);
  });
  // GMFB-42: a recording that takes cameras and shared screens asks for both, in the same one answer.
  testWidgets('someone else\'s recording asks for the voice, or for voice and video where it takes pictures', (tester) async {
    final v = Voice.instance;
    final s = v.session = VoiceSession(channel: VoiceChannel.make('Lounge'), route: _NoRoute(), media: _NoMedia(), name: 'Matt');
    addTearDown(() => v.session = null);
    s.members['kev'] = const VoiceMember('kev', name: 'Kevin', notices: true, recording: 'rec-1');
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Align(alignment: Alignment.topCenter, child: RecordingBanner()), AppState());
    expect(find.textContaining('Include your voice?'), findsOneWidget);
    await tester.tap(find.text('Include me'));
    await tester.pump();
    expect(find.textContaining('your voice is in it'), findsOneWidget);
    expect(s.pictured, isEmpty, reason: 'a yes to the voice is not one to the picture');

    s.members['kev'] = const VoiceMember('kev', name: 'Kevin', notices: true, recording: 'rec-2', recordsVideo: true);
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    s.notifyListeners();
    await tester.pump();
    expect(find.textContaining('Include your voice and video?'), findsOneWidget);
    await tester.tap(find.text('Include me'));
    await tester.pump();
    expect(find.textContaining('your voice and video are in it'), findsOneWidget);
    expect(s.pictured, {'rec-2'});
    await tester.tap(find.text('Leave me out'));
    await tester.pump();
    expect(find.textContaining('your voice and video aren\'t in it'), findsOneWidget);
    expect(s.pictured, isEmpty);
  });

  // GMFB-16 (@kevin, Android 0.11.5: "Audio recording banner covers ui elements in a way that makes them unusable and
  // cannot be moved").
  testWidgets('the lines over a call move when dragged, and fold to a chip that unfolds them', (tester) async {
    final v = Voice.instance;
    v.session = VoiceSession(channel: VoiceChannel.make('Lounge'), route: _NoRoute(), media: _NoMedia(), name: 'Matt')..recording = 'rec-1';
    CallBanners.moved = null;
    CallBanners.folded = false;
    addTearDown(() {
      v.session = null;
      CallBanners.moved = null;
      CallBanners.folded = false;
    });
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Stack(children: [SizedBox.expand(), CallBanners(top: 110, children: [RecordingBanner()])]), AppState());
    final line = find.byKey(const ValueKey('recording-mine'));
    final before = tester.getTopLeft(line).dy;
    await tester.drag(find.byKey(const ValueKey('call-banners-grip')), const Offset(0, 300));
    await tester.pump();
    expect(tester.getTopLeft(line).dy, closeTo(before + 300, 30), reason: 'dragged down, out of the way');

    await tester.tap(find.byKey(const ValueKey('call-banners-grip')));
    await tester.pump();
    expect(line, findsNothing, reason: 'folded away');
    expect(find.byKey(const ValueKey('call-banners-folded')), findsOneWidget);
    final chip = tester.getRect(find.byKey(const ValueKey('call-banners-folded')));
    expect(chip.width, lessThan(80), reason: 'a small chip at the side, not a line across the call');

    await tester.tap(find.byKey(const ValueKey('call-banners-folded')));
    await tester.pump();
    expect(line, findsOneWidget, reason: 'unfolded again, where it was left');
    expect(tester.getTopLeft(line).dy, closeTo(before + 300, 30));
    expect(tester.takeException(), isNull);
  });
  // Matt, 2026-11-22: "the recording pill gets stuck on the screen even when not recording". A plugin's line (the
  // soundboard's, the voice changer's) is listed while the plugin is on and draws nothing until it has something to
  // say; the grip and the folded chip stayed over the call after the recording had stopped.
  testWidgets('with nothing drawn in the lines over a call, neither the grip nor the chip shows', (tester) async {
    final v = Voice.instance;
    final s = VoiceSession(channel: VoiceChannel.make('Lounge'), route: _NoRoute(), media: _NoMedia(), name: 'Matt')..recording = 'rec-1';
    v.session = s;
    CallBanners.moved = null;
    CallBanners.folded = false;
    addTearDown(() {
      v.session = null;
      CallBanners.moved = null;
      CallBanners.folded = false;
    });
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const Stack(children: [SizedBox.expand(), CallBanners(top: 110, children: [RecordingBanner(), SizedBox.shrink()])]), AppState());
    await tester.pump();
    expect(find.byKey(const ValueKey('call-banners-grip')), findsOneWidget, reason: 'recording: the line and its grip');

    s.recording = null;
    s.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('recording-mine')), findsNothing);
    expect(find.byKey(const ValueKey('call-banners-grip')), findsNothing, reason: 'stopped: no grip left over the call');

    s.recording = 'rec-2';
    s.notifyListeners();
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call-banners-grip')));
    await tester.pump();
    expect(find.byKey(const ValueKey('call-banners-folded')), findsOneWidget);
    s.recording = null;
    s.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('call-banners-folded')), findsNothing, reason: 'stopped while folded: the chip goes too');
    expect(tester.takeException(), isNull);
  });
}

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

/// Speech's loudness by step: phrases and pauses, made up but the same each run.
List<double> _speech(int steps, {required int seed, int from = 0, bool quiet = false}) {
  final r = math.Random(seed);
  final out = <double>[];
  var talking = false;
  var left = 0;
  for (var i = 0; i < steps; i++) {
    if (left-- <= 0) {
      talking = !talking;
      left = talking ? 8 + r.nextInt(30) : 4 + r.nextInt(25);
    }
    final base = i < from ? 0.0 : (talking ? (quiet ? 0.08 : 0.25) + r.nextDouble() * (quiet ? 0.12 : 0.55) : r.nextDouble() * 0.01);
    out.add(base);
  }
  return out;
}

Future<void> _keep(WidgetTester tester, String name) async {
  final element = find.byType(WidgetsApp).evaluate().single;
  await tester.runAsync(() async {
    final image = await captureImage(element);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File('build/themes/recording/$name.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// The app's fonts (as test/themes_test.dart loads them), so the docs' pictures show words.
Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
}
