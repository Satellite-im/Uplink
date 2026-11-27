import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/common.dart' show GhostSpinner;
import 'package:ghost_messaging/ui/connecting_banner.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart' show SpaceSplit;
import 'package:ghost_messaging/ui/skeleton.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/voice_screen.dart' show CallBanner, CallPanel;
import 'package:ghost_messaging/voice/call_wait.dart';
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

// Matt, 2026-11-24: "show better loading states with skeletal loaders and a connecting banner so it doesn't just seem
// like the app is frozen". What a call is waiting for is worked out in lib/voice/call_wait.dart and drawn by
// lib/ui/connecting_banner.dart; the pages in bones are lib/ui/skeleton.dart. Run with --update-goldens, the pictures
// are build/loading/*.png.

Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

Future<void> _shot(String name) async {
  if (!autoUpdateGoldenFiles) return;
  await expectLater(find.byType(WidgetsApp), matchesGoldenFile('../build/loading/$name.png'));
}

/// A relay server the test speaks for: who is in the room when it is joined, and what it says after.
class _Route implements VoiceRoute {
  _Route(this.me, {this.there = const []});
  @override
  final String me;
  List<String> there;

  /// Held until the test lets the room's answer through; null answers at once.
  Completer<void>? hold;
  final said = StreamController<RoomEvent>.broadcast();

  int joins = 0;
  final left = <String>[];

  @override
  Future<List<String>> join(String room, String token) async {
    joins++;
    await hold?.future;
    return there;
  }

  @override
  void leave(String room) => left.add(room);
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => said.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

/// A microphone the test starts when it chooses.
class _Media implements VoiceMedia {
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  Completer<void>? hold;

  /// Held until the test lets the sound be let go of, as a Mac takes seconds to; null stops at once.
  Completer<void>? holdStop;
  int stops = 0;
  @override
  Future<void> start() async => hold?.future;
  @override
  Future<void> stop() async {
    stops++;
    await holdStop?.future;
  }
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

void main() {
  final lounge = VoiceChannel.make('Lounge');
  String name(String id) => const {'a': 'Maya', 'b': 'Sam'}[id] ?? '';

  group('what a call is waiting for', () {
    test('nothing, for a call that nothing is bringing in', () {
      final s = VoiceSession(channel: lounge, route: _Route('me'), media: _Media(), name: 'Me');
      expect(CallWait.of(s, joining: false), isNull, reason: 'a call only made, as the screens\' own tests make one');
    });

    test('each step of coming in is said in its turn, then nothing', () async {
      final route = _Route('me')..hold = Completer<void>();
      final media = _Media()..hold = Completer<void>();
      final s = VoiceSession(channel: lounge, route: route, media: media, name: 'Me');
      var told = 0;
      s.addListener(() => told++);
      expect(CallWait.of(s, joining: true), const CallWait('Connecting…', 'Reaching the relay server'), reason: 'before the chat\'s room is open');
      final coming = s.join();
      expect(CallWait.of(s, joining: true), const CallWait('Connecting…', 'Starting the microphone'));
      expect(told, 1, reason: 'the screens are told at each step');
      media.hold!.complete();
      await Future<void>.delayed(Duration.zero);
      expect(CallWait.of(s, joining: true), const CallWait('Connecting…', 'Joining the call'));
      expect(told, 2);
      route.hold!.complete();
      await coming;
      expect(s.joined, isTrue);
      expect(s.step, JoinStep.done);
      expect(CallWait.of(s, joining: false), isNull, reason: 'alone in it and the microphone heard: through');
      await s.leave();
    });

    test('with others in it, until one of them can be heard', () async {
      final s = VoiceSession(channel: lounge, route: _Route('me', there: const ['a', 'b']), media: _Media(), name: 'Me');
      await s.join();
      expect(s.members.keys, ['a', 'b']);
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.connecting, 'b': PeerLink.connecting}, nameOf: name), const CallWait('Connecting…', 'Reaching 2 people'));
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.connecting}, nameOf: name), const CallWait('Connecting…', 'Reaching Maya'), reason: 'one, by name');
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.connecting}), const CallWait('Connecting…', 'Reaching the other person'), reason: 'with no name to say');
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.connected, 'b': PeerLink.connecting}, nameOf: name), isNull, reason: 'one through: each face says its own');
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.poor, 'b': PeerLink.connecting}, nameOf: name), isNull);
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.failed, 'b': PeerLink.failed}, nameOf: name), isNull, reason: 'no way through is said on the faces, not as connecting');
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.reconnecting}, nameOf: name), const CallWait('Reconnecting…', 'Reaching Maya'));
      expect(CallWait.of(s, joining: false, links: const {}, nameOf: name), isNull, reason: 'nobody being reached (two listeners on a stage make no connection)');
      await s.leave();
    });

    // Leave is on the screen from the first moment now, so it is pressed while the call is still connecting.
    test('left while it is still coming in, the call is not come into after all', () async {
      // While the microphone starts.
      var route = _Route('me', there: const ['a']);
      var media = _Media()..hold = Completer<void>();
      var s = VoiceSession(channel: lounge, route: route, media: media, name: 'Me');
      var coming = s.join();
      await s.leave();
      media.hold!.complete();
      await coming;
      expect(s.joined, isFalse, reason: 'not in the call with nothing on the screen saying so');
      expect(route.joins, 0, reason: 'the relay server was never asked');
      expect(media.stops, 2, reason: 'the microphone that had just started is let go of again');
      // While the relay server answers.
      route = _Route('me', there: const ['a'])..hold = Completer<void>();
      media = _Media();
      s = VoiceSession(channel: lounge, route: route, media: media, name: 'Me');
      coming = s.join();
      await Future<void>.delayed(Duration.zero);
      await s.leave();
      route.hold!.complete();
      await coming;
      expect(s.joined, isFalse);
      expect(s.members, isEmpty, reason: 'nobody offered a connection');
      expect(route.left, [lounge.room], reason: 'out of the room it had just been let into');
    });

    test('the microphone starting after the call is joined, for a while and no longer', () async {
      final s = VoiceSession(channel: lounge, route: _Route('me'), media: _Media(), name: 'Me');
      await s.join();
      final since = s.since!;
      expect(CallWait.of(s, joining: false, micLive: false, now: since.add(const Duration(seconds: 2))), const CallWait('Connecting…', 'Starting the microphone'));
      expect(CallWait.of(s, joining: false, micLive: true, now: since.add(const Duration(seconds: 2))), isNull);
      expect(CallWait.of(s, joining: false, micLive: false, now: since.add(CallWait.micPatience)), isNull, reason: 'never heard (levels are not read out of sight): the line goes anyway');
      await s.leave();
    });

    test('the relay server lost in the middle of a call', () async {
      final route = _Route('me', there: const ['a']);
      final s = VoiceSession(channel: lounge, route: route, media: _Media(), name: 'Me');
      await s.join();
      route.said.add(RoomEvent(lounge.room, closed: true));
      await Future<void>.delayed(Duration.zero);
      expect(s.reconnecting, isTrue);
      expect(CallWait.of(s, joining: false, links: const {'a': PeerLink.connected}), const CallWait('Reconnecting…', 'The relay server was lost'), reason: 'said even with someone still heard');
      await s.leave();
    });
  });

  group('leaving a call', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      ListPhone(const []).install();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
    });

    // Matt, 2026-11-24: "on the macbook air it lagged on the call end". Closing a call's connections and letting go
    // of the microphone takes seconds there, and the call stood on the screen until it was all done.
    test('is said to the screens at once, while its sound is still being let go of; the next call waits for that', () async {
      final media = _Media()..holdStop = Completer<void>();
      final v = Voice.instance;
      v.session = VoiceSession(channel: lounge, route: _Route('me'), media: media, name: 'Me');
      var told = 0;
      void listen() => told++;
      v.addListener(listen);
      addTearDown(() => v.removeListener(listen));

      var left = false, again = false;
      final leaving = v.leave().then((_) => left = true);
      expect(v.session, isNull);
      expect(told, 1, reason: 'out of the call on the screen before anything is waited for');
      await Future<void>.delayed(Duration.zero);
      expect(left, isFalse, reason: 'the microphone is still being let go of');
      // Leaving again, as coming into another call does first: it waits for the one still closing.
      final second = v.leave().then((_) => again = true);
      await Future<void>.delayed(Duration.zero);
      expect(again, isFalse, reason: 'the next call is not come into while the last still holds the microphone');
      media.holdStop!.complete();
      await leaving;
      await second;
      expect(left && again, isTrue);
      expect(told, greaterThanOrEqualTo(2), reason: 'and told again once it is all let go of');
    });
  });

  group('the line over a call', () {
    setUpAll(_fonts);

    late Voice v;
    late VoiceSession s;
    late RtcMedia media;

    /// In [lounge]'s call as Voice.join has it part way: the call made and being come into.
    void coming({JoinStep step = JoinStep.room, List<String> seen = const []}) {
      v = Voice.instance;
      media = RtcMedia();
      s = VoiceSession(channel: lounge, route: _Route('me-id'), media: _Media(), name: 'Me')..step = step;
      v
        ..session = s
        ..media = media
        ..joining = lounge
        ..putLook(lounge.room, seen);
      s.addListener(v.notifyListeners);
    }

    /// Joined, as Voice.join leaves it.
    Future<void> joined() async {
      await s.join();
      v.joining = null;
      v.notifyListeners();
    }

    tearDown(() {
      final v = Voice.instance;
      v
        ..session = null
        ..media = null
        ..joining = null;
    });

    Future<void> draw(WidgetTester tester, Widget child, {Size size = const Size(412, 600), bool dark = false, String platform = 'mobile'}) async {
      final sheet = await loadSheet(tester);
      final app = AppState();
      if (dark) app.setTheme('dark');
      await pumpScreen(tester, sheet, ColoredBox(color: const Color(0x00000000), child: child), app, size: size, platform: platform);
    }

    testWidgets('says each wait as it comes, turns while it waits, and says Connected for a moment', (tester) async {
      coming(seen: const ['a', 'b']);
      await draw(tester, Builder(builder: (context) => ColoredBox(color: context.tokens.color('glacier-bg'), child: ListView(padding: const EdgeInsets.all(16), children: [CallPanel(session: s)]))));
      expect(find.byKey(const ValueKey('call-connecting')), findsOneWidget);
      expect(find.textContaining('Reaching the relay server', findRichText: true), findsOneWidget);
      expect(find.descendant(of: find.byType(ConnectingBanner), matching: find.byType(GhostSpinner)), findsOneWidget, reason: 'something moving, so the app is seen to be at work');
      expect(tester.hasRunningAnimations, isTrue);
      // Those the relay server says are in the call, as bones until they are really there.
      expect(find.byKey(const ValueKey('call-coming')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('call-coming')), matching: find.byType(Bone)), findsNWidgets(4), reason: 'two people: a face and a name each');
      expect(find.bySemanticsLabel('2 people in the call'), findsOneWidget);
      await _shot('call-connecting-phone');

      s.step = JoinStep.microphone;
      v.notifyListeners();
      await tester.pump();
      expect(find.textContaining('Starting the microphone', findRichText: true), findsOneWidget);

      await tester.runAsync(joined);
      await tester.pump();
      expect(find.byKey(const ValueKey('call-coming')), findsNothing, reason: 'in the call: nobody is bones');
      // Alone and joined, the microphone not heard yet: still said, in the same line.
      expect(find.textContaining('Starting the microphone', findRichText: true), findsOneWidget);
      media.micLive.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('call-connected')), findsOneWidget);
      expect(find.text('Connected', findRichText: true), findsOneWidget);
      await _shot('call-connected-phone');
      await tester.pump(CallWaitBuilder.said + const Duration(milliseconds: 100));
      await settle(tester);
      expect(find.byKey(const ValueKey('call-connected')), findsNothing);
      expect(find.byKey(const ValueKey('call-connecting')), findsNothing);
      expect(tester.hasRunningAnimations, isFalse, reason: 'through: nothing left turning');
      expect(tester.getSize(find.byType(ConnectingBanner)).height, 0, reason: 'and no room kept for it');
    });

    testWidgets('the microphone is given a while, and then the line goes by itself', (tester) async {
      coming();
      await draw(tester, Align(alignment: Alignment.topCenter, child: SizedBox(width: 380, child: ConnectingBanner(voice: Voice.instance))));
      await tester.runAsync(joined);
      await tester.pump();
      expect(find.textContaining('Starting the microphone', findRichText: true), findsOneWidget);
      // The call's clock is the real one: its patience is over once that long has really passed since it came in.
      s.since = DateTime.now().subtract(CallWait.micPatience);
      v.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('call-connecting')), findsNothing, reason: 'never heard, and not said for ever');
      await tester.pump(CallWaitBuilder.said + const Duration(milliseconds: 100));
      await settle(tester);
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('is not there at all for a call nothing is bringing in', (tester) async {
      coming();
      Voice.instance.joining = null;
      await draw(tester, Align(alignment: Alignment.topCenter, child: SizedBox(width: 380, child: ConnectingBanner(voice: Voice.instance))));
      expect(find.byKey(const ValueKey('call-connecting')), findsNothing);
      expect(find.byType(GhostSpinner), findsNothing);
      expect(tester.hasRunningAnimations, isFalse);
    });

    // A space's call is drawn by its own page (lib/ui/space_designs): the line is over it, under its header, and the
    // page's own words follow, so nothing on it says the call is connected or that nobody else is here.
    testWidgets('is over a space\'s call page, whose own words wait with it', (tester) async {
      coming(step: JoinStep.microphone, seen: const ['a']);
      await draw(tester, const SpaceCallPage(inline: true), size: const Size(412, 892));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('call-connecting')), findsOneWidget);
      expect(find.descendant(of: find.byType(ConnectingPill), matching: find.textContaining('Starting the microphone', findRichText: true)), findsOneWidget);
      // What says so keeps its room and is not drawn (onceThrough): nothing that can be seen or pressed says it.
      for (final said in ['Waiting for others', 'Just you']) {
        expect(find.textContaining(said).hitTestable(), findsNothing, reason: '"$said" while it is still connecting');
      }
      expect(find.text('Connecting…'), findsOneWidget, reason: 'under the space\'s name, where "Just you" goes');
      // The one already in the call is in bones until they are really there.
      expect(find.byKey(const ValueKey('tg-coming')), findsOneWidget);
      expect(find.bySemanticsLabel('1 person in the call'), findsOneWidget);
      // The line is part of the page, above its people: it covers nothing, and they move down for it.
      final pill = tester.getRect(find.byType(ConnectingPill));
      expect(pill.bottom, lessThanOrEqualTo(tester.getRect(find.text('Invite to space')).top), reason: 'above the people, not over them');
      expect(pill.top, greaterThanOrEqualTo(tester.getRect(find.text('Lounge')).bottom), reason: 'under the header');
      await _shot('space-call-connecting-phone');
      // Through: the page is as it was before there was such a line.
      await tester.runAsync(joined);
      media.micLive.value = true;
      await tester.pump();
      await tester.pump(CallWaitBuilder.said + const Duration(milliseconds: 100));
      await settle(tester);
      expect(find.byType(ConnectingPill), findsNothing);
      expect(find.byKey(const ValueKey('tg-coming')), findsNothing);
      expect(find.text('Waiting for others to join').hitTestable(), findsOneWidget);
      expect(find.text('Just you'), findsOneWidget);
    });

    // On a computer the call is the top of the space's pane, its chat under it (SpaceSplit): the line is over the
    // call's part, and the people already in the call are bones in its list.
    testWidgets('is over the call in a computer\'s pane, with the chat under it left alone', (tester) async {
      coming(step: JoinStep.room, seen: const ['a', 'b', 'c']);
      await draw(
        tester,
        Builder(
          builder: (context) => ColoredBox(
            color: context.tokens.color('glacier-bg'),
            child: SpaceSplit(
              call: const SpaceCallPage(inline: true, chatBelow: true),
              chat: const Stack(children: [
                Positioned.fill(child: SkeletonChat(label: 'Connecting to Lounge', faces: true)),
                Positioned(left: 16, right: 16, top: 12, child: Center(heightFactor: 1, child: ConnectingPill(title: 'Connecting to Lounge…', detail: 'Reaching the relay server'))),
              ]),
            ),
          ),
        ),
        size: const Size(760, 760),
        platform: 'desktop',
      );
      expect(tester.takeException(), isNull);
      final pill = tester.getRect(find.descendant(of: find.byType(ConnectingBanner), matching: find.byType(ConnectingPill)));
      expect(pill.bottom, lessThanOrEqualTo(tester.getRect(find.text('Invite to space')).top), reason: 'above the people, in the call\'s part of the pane');
      expect(find.byKey(const ValueKey('tg-coming')), findsOneWidget);
      expect(find.bySemanticsLabel('3 people in the call'), findsOneWidget);
      await _shot('split-connecting-desktop');
    });

    testWidgets('the sidebar\'s banner says the call is connecting where its clock goes', (tester) async {
      coming(step: JoinStep.microphone);
      await draw(tester, Align(alignment: Alignment.topCenter, child: SizedBox(width: 380, child: Padding(padding: const EdgeInsets.all(12), child: CallBanner(onOpen: () {})))), dark: true, platform: 'desktop');
      expect(find.byKey(const ValueKey('call-banner-connecting')), findsOneWidget);
      expect(find.text('Connecting… Starting the microphone'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Lounge\. Connecting… Starting the microphone\. Open the call\.')), findsOneWidget);
      await _shot('sidebar-connecting-dark');
      await tester.runAsync(joined);
      media.micLive.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('call-banner-connecting')), findsNothing);
      expect(find.textContaining('just you'), findsOneWidget, reason: 'the clock and who is here, as before');
    });
  });

  group('a page in bones', () {
    setUpAll(_fonts);

    Future<void> draw(WidgetTester tester, Widget child, {Size size = const Size(412, 892), bool dark = false, String platform = 'mobile', bool still = false}) async {
      final sheet = await loadSheet(tester);
      final app = AppState();
      if (dark) app.setTheme('dark');
      await pumpScreen(tester, sheet, Builder(builder: (context) {
        final page = ColoredBox(color: context.tokens.color('glacier-bg'), child: child);
        return still ? MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: page) : page;
      }), app, size: size, platform: platform);
    }

    testWidgets('a list of conversations: read aloud as loading, moving, and cut off at the foot without a scroll', (tester) async {
      await draw(tester, const SkeletonCards(label: 'Loading your conversations…'));
      expect(find.bySemanticsLabel('Loading your conversations…'), findsOneWidget);
      expect(find.byType(Bone), findsWidgets);
      expect(tester.hasRunningAnimations, isTrue, reason: 'the light passes: the app is seen to be alive');
      expect(tester.takeException(), isNull, reason: 'more rows than fit, and nothing overflows');
      await tester.drag(find.byKey(const ValueKey('skeleton-cards')), const Offset(0, -300));
      await tester.pump();
      expect(tester.getTopLeft(find.byType(Bone).first).dy, greaterThan(0), reason: 'bones are not a list to scroll');
      await _shot('cards-phone');
    });

    testWidgets('the light is one band across the page: bones at one height are lit one after another', (tester) async {
      await draw(tester, const SkeletonCards(), size: const Size(900, 600), platform: 'desktop', dark: true);
      // Drawn part way through the light's crossing: the picture shows the band over the window's left half.
      await _shot('cards-desktop-dark');
      expect(tester.takeException(), isNull);
    });

    testWidgets('still under "Remove animations"', (tester) async {
      await draw(tester, const SkeletonChat(label: 'Loading messages…', faces: true), still: true);
      expect(find.bySemanticsLabel('Loading messages…'), findsOneWidget);
      expect(tester.hasRunningAnimations, isFalse);
      await _shot('chat-phone-still');
    });

    testWidgets('a chat, people and a folder each draw in a phone and a window', (tester) async {
      await draw(tester, const SkeletonChat(label: 'Loading messages…'));
      expect(tester.takeException(), isNull);
      await _shot('chat-phone');
      await draw(tester, const SkeletonPeople(label: 'Reading your contacts…'), dark: true);
      expect(find.bySemanticsLabel('Reading your contacts…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _shot('people-phone-dark');
      await draw(tester, const SkeletonFiles(label: 'Loading files…'), size: const Size(900, 600), platform: 'desktop');
      expect(find.bySemanticsLabel('Loading files…'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _shot('files-desktop');
      // In a list of other things: as tall as its rows.
      await draw(tester, const SingleChildScrollView(child: SkeletonPeople(label: 'Loading the group', most: 5, shrink: true)));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(SkeletonPeople)).height, lessThan(500));
    });

    // Matt, 2026-11-24: "make sure all parts of the app have skeletal loaders where data may be loading includeing
    // the sidebar chats". The pieces that stand inside a list of real rows, a picture's place, and a file's lines.
    testWidgets('more rows at a list\'s foot, earlier messages at a chat\'s top, a picture and a file: each as tall as it needs', (tester) async {
      await draw(
        tester,
        ListView(children: const [
          SkeletonCards(label: 'Loading chats…', most: 3, shrink: true),
          SkeletonChat(label: 'Loading earlier messages…', most: 3, shrink: true, faces: true),
          Align(alignment: Alignment.centerLeft, child: SizedBox(width: 200, height: 120, child: SkeletonPicture())),
          SkeletonLines(label: 'Opening the file', most: 4, shrink: true),
        ]),
      );
      expect(tester.takeException(), isNull);
      for (final said in ['Loading chats…', 'Loading earlier messages…', 'Loading the picture', 'Opening the file']) {
        expect(find.bySemanticsLabel(said), findsOneWidget);
      }
      expect(tester.getSize(find.byType(SkeletonCards)).height, inInclusiveRange(150, 330), reason: 'three cards, no more');
      expect(tester.getSize(find.byType(SkeletonChat)).height, lessThan(260));
      expect(tester.getSize(find.descendant(of: find.byType(SkeletonPicture), matching: find.byType(Bone))), const Size(200, 120), reason: 'the whole of the picture\'s place');
      await _shot('pieces-phone');
    });

    testWidgets('a line that something is being reached, as a space\'s chat has before the relay server answers', (tester) async {
      await draw(
        tester,
        const Stack(children: [
          Positioned.fill(child: SkeletonChat(label: 'Connecting to Lounge', faces: true)),
          Positioned(left: 16, right: 16, top: 12, child: Center(heightFactor: 1, child: ConnectingPill(title: 'Connecting to Lounge…', detail: 'Reaching the relay server'))),
        ]),
      );
      expect(find.bySemanticsLabel('Connecting to Lounge… Reaching the relay server'), findsOneWidget);
      expect(find.byType(GhostSpinner), findsOneWidget);
      await _shot('space-connecting-phone');
    });
  });
}
