import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:glacier/glacier.dart' show GlacierSwitch;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/spotify.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/spotify_panel.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/music_sink.dart';
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/spotify.dart';
import 'package:ghost_messaging/voice/spotify_app.dart';
import 'package:ghost_messaging/voice/spotify_link.dart';
import 'package:ghost_messaging/voice/spotify_queue.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/voice/voice_settings.dart';

import 'support/lossless_stand_ins.dart';
import 'support/space_call_harness.dart';
import 'support/spotify_stand_ins.dart';

/// Spotify in a call, on the screen (lib/ui/spotify_panel.dart): the queue's page, the line over the call, and the music
/// among the people. Pictures: build/spotify (--update-goldens). And the connections themselves, over a stand-in for
/// WebRTC.
const a = '4cOdK2wGLETKBW3PvgPWqT', b = '11dFghVXANMlKmJXsNCbNl', c = '3n3Ppam7vgaVa1iaRUc9Lp', d = '0VjIjW4GlUZAMYd2vXMi3b';
const songs = [
  Song(track: a, title: 'Never Gonna Give You Up', artist: 'Rick Astley', cover: 'ab67616d00001e02baf89eb11ec7c657805d2da0', length: Duration(seconds: 213)),
  Song(track: b, title: 'Cut To The Feeling', artist: 'Carly Rae Jepsen', cover: 'ab67616d00001e027359994525d219f64872d3b1', length: Duration(seconds: 208)),
  Song(track: c, title: 'A song with a name a good deal longer than any row has room for, and then some', artist: 'A very long band name indeed'),
  Song(track: d),
];

/// A cover made here: two colours across it.
Future<MemoryImage> _made() async {
  final r = ui.PictureRecorder();
  final canvas = Canvas(r);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 80, 80), Paint()..shader = ui.Gradient.linear(Offset.zero, const Offset(80, 80), const [Color(0xFF7A3FD1), Color(0xFFE2735A)]));
  final i = await r.endRecording().toImage(80, 80);
  return MemoryImage((await i.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List());
}

class Call {
  Call(this.session, this.other, this.spotify, this.source, this.ears);
  final VoiceSession session, other;
  final FakeSpotify spotify;
  final FakeSource source;
  final List<FakeEar> ears;
}

/// This device in a call with one other, and what that other says of the music heard by the app's own instance.
Future<Call> _call(WidgetTester tester, {bool computer = false, bool speaks = true, FakeSink? sink}) async {
  final m = SpotifyMusic.instance;
  final hub = FakeHub();
  final channel = VoiceChannel.make('Friday');
  final me = VoiceSession(channel: channel, route: FakeRoute(hub, 'me-id'), media: FakeMedia(), name: 'Me');
  final other = VoiceSession(channel: channel, route: FakeRoute(hub, 'maya'), media: FakeMedia(), name: 'Maya');
  final spotify = FakeSpotify(), source = FakeSource();
  final ears = <FakeEar>[];
  m
    ..isOn = (() => true)
    ..maySpeak = ((_) => speaks)
    ..app = (() => computer ? spotify : null)
    ..source = (() => computer ? source : null)
    ..clock = (() => DateTime(2026, 11, 25, 20))
    ..lookUp = ((id) async => songs.firstWhere((s) => s.track == id, orElse: () => Song(track: id)))
    ..ways = (() => (servers: const [], relay: false))
    ..player = (() => sink)
    ..store = AppState()
    ..speaker = (() => null)
    ..makeEar = ({required servers, required relayOnly, required onCandidate, required onState, required onLossless}) {
      final e = FakeEar(servers, relayOnly, onCandidate, onState, onLossless);
      ears.add(e);
      return e;
    };
  final cover = await tester.runAsync(_made);
  SongCover.image = (_) => cover!;
  await tester.runAsync(() async {
    await other.join();
    await me.join();
    await settle();
    m.followSession(me);
  });
  Voice.instance.session = me;
  addTearDown(() async {
    Voice.instance.session = null;
    m.followSession(null);
    m.store = null;
    SongCover.image = (url) => NetworkImage(url);
  });
  return Call(me, other, spotify, source, ears);
}

Future<void> _says(WidgetTester tester, Call call, MusicState s) async {
  await tester.runAsync(() async {
    call.other.sayMusic({'k': 'state', ...s.toWire()});
    await settle();
  });
  await tester.pump();
}

MusicState _state({bool playing = true, String trouble = '', String by = 'maya', int songsOf = 3}) => MusicState(
      now: const QueuedSong(id: 1, song: Song(track: a, title: 'Never Gonna Give You Up', artist: 'Rick Astley', cover: 'ab67616d00001e02baf89eb11ec7c657805d2da0', length: Duration(seconds: 213)), by: 'me-id'),
      position: const Duration(seconds: 61),
      playing: playing,
      next: [for (final (i, s) in songs.skip(1).take(songsOf).indexed) QueuedSong(id: 10 + i, song: s, by: i == 1 ? 'me-id' : by)],
      at: DateTime(2026, 11, 25, 20),
      trouble: trouble,
    );

/// A WebRTC connection stood in for: what was asked of it.
class _Pc implements rtc.RTCPeerConnection {
  _Pc(this.configuration);
  final Map<String, dynamic> configuration;
  final List<String> log = [];
  rtc.RTCSessionDescription? local, remote;
  @override
  void Function(rtc.RTCIceCandidate candidate)? onIceCandidate;
  @override
  void Function(rtc.RTCTrackEvent event)? onTrack;
  @override
  void Function(rtc.RTCPeerConnectionState state)? onConnectionState;
  static const sdp = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\na=fmtp:111 minptime=10;useinbandfec=1\r\n';

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({rtc.MediaStreamTrack? track, rtc.RTCRtpMediaType? kind, rtc.RTCRtpTransceiverInit? init}) async {
    log.add('${kind!.name} ${track?.id} ${init!.direction!.name} ${init.sendEncodings!.first.maxBitrate}');
    return _Way();
  }

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async => rtc.RTCSessionDescription(sdp, 'offer');
  @override
  Future<rtc.RTCSessionDescription> createAnswer([Map<String, dynamic>? constraints]) async => rtc.RTCSessionDescription(sdp, 'answer');
  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async => local = description;
  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription description) async => remote = description;
  @override
  Future<void> addCandidate(rtc.RTCIceCandidate candidate) async => log.add('ice ${candidate.candidate}');
  @override
  Future<void> close() async => log.add('close');
  @override
  Future<void> dispose() async => log.add('dispose');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Way implements rtc.RTCRtpTransceiver {
  @override
  rtc.RTCRtpSender get sender => _Sender();
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Sender implements rtc.RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Track implements rtc.MediaStreamTrack {
  @override
  String get id => 'their-music';
  @override
  String get kind => 'audio';
  @override
  bool enabled = true;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Came implements rtc.RTCTrackEvent {
  _Came(this.track);
  @override
  final rtc.MediaStreamTrack track;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a device that can\'t be the DJ says who can; a computer has Start', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    await _call(tester);
    await h.shoot(tester, const SpotifyScreen(), 'quiet-phone', dir: '../build/spotify');
    expect(find.text('Nobody is playing music here. Someone on a Mac or a PC with Spotify can start it.'), findsOneWidget);
    expect(find.byKey(const ValueKey('spotify-start')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    final call = await _call(tester, computer: true);
    SpotifyMusic.instance.followSession(null);
    SpotifyMusic.instance.followSession(call.session);
    call.spotify.refuse = 'denied';
    await h.shoot(tester, const SpotifyScreen(), 'start', size: SpaceHarness.computer, dir: '../build/spotify');
    await tester.tap(find.byKey(const ValueKey('spotify-start')));
    await tester.runAsync(settle);
    await tester.pump();
    expect(find.byKey(const ValueKey('spotify-start-problem')), findsOneWidget);
    expect(find.textContaining('Automation'), findsOneWidget);
    call.spotify.refuse = null;
    await tester.tap(find.byKey(const ValueKey('spotify-start')));
    await tester.runAsync(settle);
    await tester.pump();
    expect(SpotifyMusic.instance.mine, isTrue);
    expect(find.byKey(const ValueKey('spotify-stop')), findsOneWidget);
    expect(find.byKey(const ValueKey('spotify-volume')), findsNothing, reason: 'the DJ hears it from Spotify itself');
    // A song added, and one that isn't a song's link.
    await tester.enterText(find.byType(EditableText), 'https://open.spotify.com/album/$a');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('spotify-add')));
    await tester.runAsync(settle);
    await tester.pump();
    expect(find.textContaining('Paste a song\'s link. In'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'https://open.spotify.com/track/$a?si=1');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('spotify-add')));
    await tester.runAsync(settle);
    await tester.pump();
    expect(find.byKey(const ValueKey('spotify-add-problem')), findsNothing);
    expect(call.spotify.log, ['play $a']);
    expect(find.text('Never Gonna Give You Up'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('spotify-stop')), warnIfMissed: false);
    await tester.runAsync(settle);
    await tester.pump();
    expect(SpotifyMusic.instance.mine, isFalse);
    expect(call.source.begun, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, size, dark) in const [('queue-phone', SpaceHarness.phone, false), ('queue-phone', SpaceHarness.phone, true), ('queue-desktop', SpaceHarness.computer, false), ('queue-desktop', SpaceHarness.computer, true), ('queue-narrow', Size(320, 640), false)]) {
    testWidgets('the queue, $name${dark ? ' dark' : ''}: what plays, what waits, and what each may do', (tester) async {
      final h = await SpaceHarness.load(tester);
      addTearDown(tester.view.reset);
      final call = await _call(tester);
      await _says(tester, call, _state());
      await h.shoot(tester, const SpotifyScreen(), name, size: size, dark: dark, dir: '../build/spotify');
      expect(tester.takeException(), isNull);
      expect(find.text('Never Gonna Give You Up'), findsOneWidget);
      expect(find.textContaining('Maya\'s Spotify'), findsWidgets);
      expect(find.bySemanticsLabel('1:01 of 3:33'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('spotify-volume')), 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.text('Song'), findsOneWidget, reason: 'one whose name is not known');
      // Their own can be taken away; another's can't.
      expect(find.byKey(const ValueKey('spotify-remove-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('spotify-remove-10')), findsNothing);
      expect(find.byKey(const ValueKey('spotify-stop')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (name, size, dark) in const [('phone', SpaceHarness.phone, false), ('phone', SpaceHarness.phone, true), ('desktop', SpaceHarness.computer, false), ('desktop', SpaceHarness.computer, true), ('narrow', Size(320, 640), false)]) {
    testWidgets('what a listener hears of it, why it isn\'t without loss, and the switch, $name${dark ? ' dark' : ''}', (tester) async {
      final h = await SpaceHarness.load(tester);
      addTearDown(tester.view.reset);
      final sink = FakeSink()..where = const MusicWay(MusicTo.unknown, 48000, 'usb box');
      final call = await _call(tester, sink: sink);
      final said = <Map<String, dynamic>>[];
      call.other.onMusic = (from, m) => said.add(m);
      final m = SpotifyMusic.instance;
      m.setLossless(true);
      m.setHeadphones(false);
      await tester.runAsync(settle);
      await _says(tester, call, _state(songsOf: 1));
      await tester.runAsync(settle);
      expect(said.where((m) => m['k'] == 'ask').last['ll'], 0);
      await tester.runAsync(() async {
        call.other.sayMusic({'k': 'offer', 'to': 'me-id', 'l': 'mark', 'sdp': 'm=application'});
        await settle();
      });
      call.ears.last.onState(true);
      Future<void> at(String key) async {
        await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 120, scrollable: find.byType(Scrollable).first);
        await tester.pump();
      }

      await h.shoot(tester, const SpotifyScreen(), 'lossless-ask-$name', size: size, dark: dark, dir: '../build/spotify');
      await at('spotify-headphones');
      await h.again(tester, 'lossless-speakers-$name', dark: dark, dir: '../build/spotify');
      expect(tester.takeException(), isNull);
      expect(find.text('High quality'), findsOneWidget);
      expect(find.textContaining('can\'t tell whether you wear'), findsOneWidget);
      // They say they wear them: it is taken, and heard.
      await tester.ensureVisible(find.byKey(const ValueKey('spotify-headphones')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('spotify-headphones')), matching: find.byType(GlacierSwitch)));
      await tester.runAsync(settle);
      await tester.pump();
      expect(call.ears.last.take, isTrue);
      expect(said.last, {'t': 'mu', 'k': 'll', 'to': 'maya', 'l': 'mark', 'w': 1});
      expect(find.text('Lossless begins once it has played cleanly for a second.'), findsOneWidget);
      call.ears.last.onLossless(true, null);
      await tester.pump(const Duration(milliseconds: 400));
      await at('spotify-quality');
      expect(find.text('Lossless'), findsOneWidget);
      await h.again(tester, 'lossless-$name', dark: dark, dir: '../build/spotify');
      // Off: kept, and the Opus.
      m.setLossless(false);
      await tester.runAsync(settle);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Lossless music is off on this device.'), findsOneWidget);
      expect(find.byKey(const ValueKey('spotify-headphones')), findsNothing);
      expect(call.ears.last.take, isFalse);
      m.setLossless(true);
      m.setHeadphones(false);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the DJ sees how many have it without loss, what it takes, and that the headset brings it down, $name${dark ? ' dark' : ''}', (tester) async {
      final h = await SpaceHarness.load(tester);
      addTearDown(tester.view.reset);
      final call = await _call(tester, computer: true);
      final m = SpotifyMusic.instance;
      var now = DateTime(2026, 11, 25, 20);
      m.clock = () => now;
      await tester.runAsync(() async {
        await m.start();
        await m.add('spotify:track:$a');
        call.other.sayMusic({'k': 'ask', 'to': 'me-id', 'n': 0, 'll': 1});
        await settle();
        for (final bytes in [0, 118000]) {
          call.source.ways['maya'] = (open: true, bytes: bytes, dropped: 0, relay: false);
          now = now.add(const Duration(seconds: 1));
          call.spotify.to(20);
          await m.look();
        }
        call.source.hz = 24000;
        await m.look();
        await settle();
      });
      await h.shoot(tester, const SpotifyScreen(), 'dj-$name', size: size, dark: dark, dir: '../build/spotify');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('spotify-low')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('spotify-listeners')), 120, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(find.text('1, 1 lossless'), findsOneWidget);
      expect(find.byKey(const ValueKey('spotify-quality')), findsNothing);
      await h.again(tester, 'dj-lossless-$name', dark: dark, dir: '../build/spotify');
      await tester.runAsync(m.stop);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the buttons ask the DJ, and one who may not speak has none', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final call = await _call(tester);
    final asked = <String>[];
    call.other.onMusic = (from, m) {
      if (m['k'] == 'do') asked.add('${m['w']}${m['e'] == null ? '' : ' ${m['e']}'}${m['i'] == null ? '' : ' to ${m['i']}'}');
    };
    await _says(tester, call, _state());
    await h.shoot(tester, const SpotifyScreen(), 'buttons', size: const Size(800, 1400), dir: '../build/spotify');
    for (final k in ['spotify-toggle', 'spotify-skip', 'spotify-up-11', 'spotify-down-10', 'spotify-remove-11']) {
      await tester.tap(find.byKey(ValueKey(k)));
      await tester.runAsync(settle);
      await tester.pump();
    }
    expect(asked, ['pause', 'skip', 'mv 11 to 0', 'mv 10 to 1', 'rm 11']);
    for (final label in ['Pause', 'Skip', 'Take ${songs[2].title} out of the queue'.substring(0, 10), 'Move Cut To The Feeling down']) {
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}')), findsWidgets, reason: label);
    }
    SpotifyMusic.instance.maySpeak = (id) => id != 'me-id';
    SpotifyMusic.instance.setVolume(40);
    await tester.pump();
    expect(find.byKey(const ValueKey('spotify-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('spotify-up-11')), findsNothing);
    expect(find.byKey(const ValueKey('spotify-remove-11')), findsNothing);
    expect(find.textContaining('can\'t speak'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (size, dark) in const [(SpaceHarness.phone, false), (SpaceHarness.phone, true), (SpaceHarness.computer, false), (SpaceHarness.computer, true), (Size(320, 640), false)]) {
    testWidgets('the line over the call and the music among its people, ${size.width.round()}${dark ? ' dark' : ''}', (tester) async {
      final h = await SpaceHarness.load(tester);
      addTearDown(tester.view.reset);
      final call = await _call(tester);
      await _says(tester, call, _state());
      final person = SpaceCall.musicPerson()!;
      expect(person.doing, 'playing Never Gonna Give You Up');
      expect(person.tag, 'Music');
      final made = h.call(people: 2, video: const {});
      final pressed = <String>[];
      final withMusic = SpaceCall(channel: made.channel, people: [...made.people, person], levels: made.levels, changes: made.changes, room: made.room, since: made.since, onMute: () {}, onLeave: () {}, onPerson: (_, p) => pressed.add(p.id), chatBuilder: made.chatBuilder);
      expect(withMusic.count, 3);
      expect(withMusic.others.map((p) => p.id), ['a', 'b'], reason: 'it is nobody');
      await h.shoot(tester, Stack(children: [TelegramCall(call: withMusic), const CallBanners(top: 110, children: [MusicLine()])]), 'line-${size.width.round()}', size: size, dark: dark, dir: '../build/spotify');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('music-line')), findsOneWidget);
      expect(find.text('3 in voice'), findsOneWidget);
      expect(find.text('Spotify'), findsOneWidget);
      await tester.tap(find.text('Spotify'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(pressed, ['music']);
      // Trouble is said on the line.
      await _says(tester, call, _state(playing: false, trouble: 'closed'));
      expect(find.text('Spotify was closed on their computer.'), findsOneWidget);
      expect(SpaceCall.musicPerson()!.doing, 'paused');
      // Queue opens the page.
      await tester.tap(find.byKey(const ValueKey('music-queue')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(SpotifyScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      // Nobody playing, there is neither.
      await tester.runAsync(() async {
        call.other.sayMusic({'k': 'stop'});
        await settle();
      });
      expect(SpaceCall.musicPerson(), isNull);
      await h.shoot(tester, const CallBanners(top: 110, children: [MusicLine()]), 'line-none', size: size, dir: '../build/spotify');
      expect(find.byKey(const ValueKey('music-line')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('the plugin: for a circle and nothing else, off until it is turned on', () {
    const p = SpotifyPlugin();
    expect(shippedPlugins.whereType<SpotifyPlugin>(), hasLength(1));
    expect(p.scopes, {PluginScope.circle});
    expect(p.onByDefault, isFalse);
    expect(PluginRegistry.instance.circlePlugins.map((x) => x.id), contains('spotify'));
    expect(PluginRegistry.instance.isOnIn(p, MemoryStore(), inCircle: true, circleOn: null), isFalse);
    expect(PluginRegistry.instance.isOnIn(p, MemoryStore(), inCircle: true, circleOn: true), isTrue);
    expect(SpotifyPlugin.onInCall(), isFalse, reason: 'no call');
    expect(p.reaches.map((r) => '${r.label} ${r.hint}').join(' '), allOf(contains('personal use'), contains('nothing of it is stored')));
  });

  // --- the connections ------------------------------------------------------------------------------------------------------

  test('a PC sends the one track it made, and only sends; a listener only listens', () async {
    final made = <_Pc>[];
    RtcMedia.connect = (config) async {
      final pc = _Pc(config);
      made.add(pc);
      return pc;
    };
    addTearDown(() => RtcMedia.connect = null);
    final messenger = binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SpotifyChannel.channel, (call) async => call.method == 'begin' ? 'the-music' : null);
    addTearDown(() => messenger.setMockMethodCallHandler(SpotifyChannel.channel, null));
    final volumes = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (call) async {
      if (call.method == 'setVolume') volumes.add('${(call.arguments as Map)['volume']}');
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), null));

    final source = WindowsMusic(const VoiceSettings());
    await source.begin();
    final states = <String>[], ways = <String>[];
    source
      ..onState = ((id, s) => states.add('$id $s'))
      ..onCandidate = ((id, c) => ways.add('$id ${c['candidate']}'));
    final sdp = await source.offer('sam', servers: const [{'urls': 'turn:x'}], relayOnly: true, lossless: false);
    expect(made.single.configuration['iceTransportPolicy'], 'relay');
    expect(made.single.log, ['RTCRtpMediaTypeAudio the-music SendOnly 510000']);
    expect(sdp, contains('stereo=1'));
    expect(sdp, contains('maxaveragebitrate=510000'));
    expect(sdp, contains('useinbandfec=0'));
    expect(sdp, contains('usedtx=0'));
    made.single.onIceCandidate!(rtc.RTCIceCandidate('way', '0', 0));
    made.single.onConnectionState!(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    expect(ways, ['sam way']);
    expect(states, ['sam failed']);
    expect(await source.answer('sam', _Pc.sdp), isTrue);
    expect(made.single.remote!.sdp, contains('stereo=1'), reason: 'the rate and stereo it sends are what the answer asks for');
    expect(await source.answer('nobody', _Pc.sdp), isFalse);
    // Asked again: the one before goes first, and says nothing more.
    await source.offer('sam', servers: const [], relayOnly: false, lossless: false);
    expect(made.first.log, containsAll(['close', 'dispose']));
    made.first.onConnectionState!(rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed);
    expect(states, hasLength(1));
    await source.end();
    expect(made.last.log, containsAll(['close', 'dispose']));

    // The listener's.
    made.clear();
    final ups = <bool>[];
    final ear = RtcMusicEar(servers: const [], relayOnly: false, onCandidate: (_) {}, onState: ups.add, onLossless: (_, _) {});
    await ear.candidate({'candidate': 'early', 'sdpMid': '0', 'sdpMLineIndex': 0});
    expect(made, isEmpty, reason: 'held until the offer is taken');
    final answer = await ear.takeOffer(sdp!);
    expect(made.single.remote!.type, 'offer');
    expect(made.single.log, ['ice early'], reason: 'nothing of this device\'s is put in it');
    expect(answer, contains('stereo=1'));
    final track = _Track();
    made.single.onTrack!(_Came(track));
    ear.set(volume: 0.5, silent: false);
    expect(track.enabled, isTrue);
    ear.set(volume: 0.5, silent: true);
    expect(track.enabled, isFalse);
    made.single.onConnectionState!(rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected);
    made.single.onConnectionState!(rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed);
    expect(ups, [true, false]);
    await ear.close();
    expect(made.single.log, containsAll(['close', 'dispose']));
    made.single.onConnectionState!(rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed);
    expect(ups, hasLength(2));
  });

  testWidgets('while it plays the DJ says all of it every five seconds, and not while it is paused', (tester) async {
    final hub = FakeHub();
    final channel = VoiceChannel.make('Friday');
    final dj = VoiceSession(channel: channel, route: FakeRoute(hub, 'maya'), media: FakeMedia(), name: 'Maya');
    final sam = VoiceSession(channel: channel, route: FakeRoute(hub, 'sam'), media: FakeMedia(), name: 'Sam');
    Future<void> soon() async {
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(settle);
    }

    await tester.runAsync(() async {
      await dj.join();
      await sam.join();
      await settle();
    });
    var now = DateTime(2026, 11, 25, 20);
    final spotify = FakeSpotify();
    final m = SpotifyMusic.forTest(isOn: () => true, maySpeak: (_) => true, app: () => spotify, source: FakeSource.new, makeEar: RtcMusicEar.make, clock: () => now)..followSession(dj);
    var states = 0;
    sam.onMusic = (from, w) => w['k'] == 'state' ? states++ : null;
    await m.start();
    await m.add('spotify:track:$a');
    Future<void> second(int i) async {
      spotify.to(i, state: spotify.doing.state);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await soon();
    }

    for (var i = 0; i < 4; i++) {
      await second(i);
    }
    states = 0;
    for (var i = 4; i < 24; i++) {
      await second(i);
    }
    expect(states, 4);
    m.pause();
    await soon();
    states = 0;
    for (var i = 0; i < 30; i++) {
      await second(24);
    }
    expect(states, 0);
    m.followSession(null);
    await tester.runAsync(() async {
      await dj.leave();
      await sam.leave();
    });
  });
}
