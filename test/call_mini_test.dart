import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/mini_window.dart';
import 'package:ghost_messaging/keys.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent;
import 'package:ghost_messaging/ui/call_mini.dart';
import 'package:ghost_messaging/ui/ripple_avatar.dart';
import 'package:ghost_messaging/voice/channels.dart' show Voice;
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

/// GMFB-41, box 4 ("An always-on-top call overlay for games on desktop"): the call's mini window
/// (lib/desktop/mini_window.dart, lib/ui/call_mini.dart). The window itself is the runners' (MainFlutterWindow.swift,
/// splash.cpp) and is not drawn under `flutter test`: what is tried here is what the app asks of it, and what it draws.
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
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => throw UnimplementedError();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

/// Some state of its own, to see it is the same after: a number pressed up.
class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  Size? laidOut;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        laidOut = box.biggest;
        return GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => setState(() => n++), child: Text('count $n', key: const ValueKey('count')));
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ghost_desktop/window');
  final said = <Map<Object?, Object?>>[];
  var answer = true;
  setUp(() {
    said.clear();
    answer = true;
    CallMini.offeredForTest = true;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'mini') return null;
      said.add(call.arguments as Map<Object?, Object?>);
      return (call.arguments as Map)['on'] == true ? answer : true;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (_) async => null);
  });
  tearDown(() {
    CallMini.offeredForTest = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    Voice.instance.session = null;
  });

  group('the state', () {
    test('in a call: the window is asked to be small and on top, then for itself back', () async {
      final calls = ValueNotifier(0);
      final mini = CallMini(inCall: () => true, calls: calls);
      var told = 0;
      mini.addListener(() => told++);
      expect(await mini.enter(), isTrue);
      expect(mini.on, isTrue);
      expect(said, [
        {'on': true, 'width': 340, 'height': 236},
      ]);
      expect(await mini.enter(), isTrue, reason: 'already small: nothing asked again');
      expect(said.length, 1);
      await mini.leave();
      expect(mini.on, isFalse);
      expect(said.last, {'on': false});
      expect(told, 2);
      // The toggle the shortcut and the dock's button are.
      expect(await mini.toggle(), isTrue);
      expect(await mini.toggle(), isFalse);
      expect(said.map((m) => m['on']), [true, false, true, false]);
    });

    test('no call, a device without it, or a window that won\'t: it stays as it is', () async {
      expect(await CallMini(inCall: () => false, calls: ValueNotifier(0)).enter(), isFalse);
      CallMini.offeredForTest = false;
      expect(await CallMini(inCall: () => true, calls: ValueNotifier(0)).enter(), isFalse);
      expect(said, isEmpty, reason: 'the window is not even asked');
      CallMini.offeredForTest = true;
      answer = false;
      final refused = CallMini(inCall: () => true, calls: ValueNotifier(0));
      expect(await refused.enter(), isFalse, reason: 'a Mac at full screen says no');
      expect(refused.on, isFalse);
      // A runner from before, with no mini window: no answer at all.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      final old = CallMini(inCall: () => true, calls: ValueNotifier(0));
      expect(await old.enter(), isFalse);
      expect(old.on, isFalse);
    });

    test('the call ending gives the window back by itself', () async {
      var calling = true;
      final calls = ValueNotifier(0);
      final mini = CallMini(inCall: () => calling, calls: calls);
      await mini.enter();
      calls.value++;
      expect(mini.on, isTrue, reason: 'a change to the call, still on');
      calling = false;
      calls.value++;
      await Future<void>.delayed(Duration.zero);
      expect(mini.on, isFalse);
      expect(said.last, {'on': false});
      // Not listening any more: another change asks nothing.
      final before = said.length;
      calls.value++;
      await Future<void>.delayed(Duration.zero);
      expect(said.length, before);
    });
  });

  group('the command', () {
    testWidgets('Mini window is a command of the calls\', on Cmd or Ctrl+Shift+O, offered where the window can be made small', (tester) async {
      await tester.pumpWidget(const SizedBox());
      expect(KeyCommand.miniWindow.group, 'Calls');
      expect(Keys.defaults[KeyCommand.miniWindow], const KeyBinding(LogicalKeyboardKey.keyO, primary: true, shift: true));
      final used = {for (final c in KeyCommand.values) Keys.defaults[c]};
      expect(used.length, KeyCommand.values.length, reason: 'on keys of its own');
      CallMini.offeredForTest = true;
      expect(Keys.offered(KeyCommand.miniWindow), isTrue);
      CallMini.offeredForTest = false;
      expect(Keys.offered(KeyCommand.miniWindow), isFalse, reason: 'Linux, a phone, a browser');
      CallMini.offeredForTest = true;
      final keys = Keys.forTest()..start(AppState());
      KeyCommand? got;
      bool handler(KeyEvent e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.keyO) got = keys.commandFor(e, typing: true);
        return false;
      }

      HardwareKeyboard.instance.addHandler(handler);
      final primary = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(primary);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(primary);
      HardwareKeyboard.instance.removeHandler(handler);
      expect(got, KeyCommand.miniWindow, reason: 'with Cmd or Ctrl it works while typing in a game\'s chat, too');
    });
  });

  group('the window', () {
    Future<TokenSheet> sheet(WidgetTester tester) async => (await tester.runAsync(AccentSheets.load))!.base;

    Widget frame(TokenSheet s, CallMini mini, {WidgetBuilder? view, Widget child = const _Counter()}) => Directionality(
          textDirection: TextDirection.ltr,
          child: GlacierTheme(
            sheet: s,
            attrs: const {'platform': 'desktop', 'theme': 'dark'},
            child: GlacierToastProvider(child: CallMiniFrame(controller: mini, mini: view, child: child)),
          ),
        );

    testWidgets('while small, the call is drawn in the app\'s place; the app is kept, at its own size, and is there after', (tester) async {
      final s = await sheet(tester);
      tester.view.physicalSize = const Size(1100, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final mini = CallMini(inCall: () => true, calls: ValueNotifier(0));
      await tester.pumpWidget(frame(s, mini, view: (_) => const ColoredBox(key: ValueKey('the-call'), color: Color(0xFF112233))));
      await tester.tap(find.byKey(const ValueKey('count')));
      await tester.pump();
      expect(find.text('count 1'), findsOneWidget);
      final state = tester.state<_CounterState>(find.byType(_Counter));
      expect(state.laidOut, const Size(1100, 740));
      await mini.enter();
      // The runner makes the window small.
      tester.view.physicalSize = CallMini.size;
      await tester.pump();
      expect(find.byKey(const ValueKey('the-call')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('the-call'))), CallMini.size);
      expect(find.text('count 1').hitTestable(), findsNothing, reason: 'not drawn, not pressed');
      expect(identical(tester.state<_CounterState>(find.byType(_Counter, skipOffstage: false)), state), isTrue, reason: 'the same app, not one built anew');
      expect(state.laidOut, const Size(1100, 740), reason: 'laid out at the size it had, not squeezed into the small window');
      expect(tester.takeException(), isNull, reason: 'nothing overflows');
      await mini.leave();
      tester.view.physicalSize = const Size(1100, 740);
      await tester.pump();
      expect(find.byKey(const ValueKey('the-call')), findsNothing);
      expect(identical(tester.state<_CounterState>(find.byType(_Counter)), state), isTrue);
      expect(find.text('count 1').hitTestable(), findsOneWidget);
    });

    testWidgets('the faces ripple as each talks; Mute, Deafen and Leave work, and Leave gives the window back', (tester) async {
      final s = await sheet(tester);
      tester.view.physicalSize = CallMini.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final media = _Media();
      final session = VoiceSession(channel: VoiceChannel.make('Raid night'), route: _NoRoute(), media: media, name: 'Me')
        ..members['a'] = const VoiceMember('a', name: 'Maya Chen')
        ..members['b'] = const VoiceMember('b', name: 'Sam Ortiz', muted: true);
      Voice.instance.session = session;
      final mini = CallMini.instance;
      expect(await mini.enter(), isTrue);
      addTearDown(mini.leave);
      await tester.pumpWidget(frame(s, mini, child: const SizedBox()));
      expect(find.text('Raid night'), findsOneWidget);
      for (final id in ['me', 'a', 'b']) {
        expect(find.byKey(ValueKey('call-mini-face-$id')), findsOneWidget);
      }
      RippleAvatar face(String id) => tester.widget<RippleAvatar>(find.descendant(of: find.byKey(ValueKey('call-mini-face-$id')), matching: find.byType(RippleAvatar)));
      expect(face('a').level, 0);
      media.levels.value = {'a': 0.4, 'b': 0.5};
      await tester.pump();
      expect(face('a').level, 0.4, reason: 'Maya talking: her rings');
      expect(face('b').level, 0, reason: 'Sam muted: no rings, whatever is heard');
      expect(face('b').muted, isTrue);
      await tester.tap(find.byKey(const ValueKey('call-mini-mute')));
      await tester.pump();
      expect(session.muted, isTrue);
      expect(face('me').muted, isTrue);
      await tester.tap(find.byKey(const ValueKey('call-mini-deafen')));
      await tester.pump();
      expect(session.deafened, isTrue);
      expect(tester.takeException(), isNull, reason: 'it fits the small window');
      await tester.tap(find.byKey(const ValueKey('call-mini-leave')));
      await tester.pump();
      await tester.pump();
      expect(Voice.instance.session, isNull);
      expect(mini.on, isFalse, reason: 'the call ended: the window comes back');
      expect(said.last, {'on': false});
      expect(find.byKey(const ValueKey('call-mini')), findsNothing);
    });

    testWidgets('Back to the full window', (tester) async {
      final s = await sheet(tester);
      tester.view.physicalSize = CallMini.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Voice.instance.session = VoiceSession(channel: VoiceChannel.make('Raid night'), route: _NoRoute(), media: _Media(), name: 'Me');
      final mini = CallMini.instance;
      await mini.enter();
      addTearDown(mini.leave);
      await tester.pumpWidget(frame(s, mini, child: const SizedBox()));
      await tester.tap(find.byKey(const ValueKey('call-mini-back')));
      await tester.pump();
      expect(mini.on, isFalse);
      expect(Voice.instance.session, isNotNull, reason: 'still in the call');
      expect(said.map((m) => m['on']), [true, false]);
    });
  });
}
