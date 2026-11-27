import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:glacier/glacier.dart';

/// What a space's call page (lib/ui/space_designs) is drawn and tried with: a call made up of people, levels
/// and a chat, with no relay and no WebRTC, and a way to draw a page and keep its picture (test/shots).
///
///   final h = await SpaceHarness.load(tester);
///   final c = h.call(log: log);                  // five people, Maya talking, Sam muted, Riley a guest with video
///   await h.shoot(tester, TelegramCall(call: c), 'space-telegram', phone: true, dark: false);

class _NoRoute implements VoiceRoute {
  _NoRoute(this.me);
  @override
  final String me;
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

class SpaceHarness {
  SpaceHarness._(this.sheet);
  final TokenSheet sheet;

  static bool _fontsIn = false;

  /// The app's own fonts, so the pictures show words, not blocks.
  static Future<void> _fonts() async {
    if (_fontsIn) return;
    Future<void> family(String name, String file) async {
      final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
      await loader.load();
    }

    await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
    await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
    await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
    await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
    _fontsIn = true;
  }

  /// The app's tokens and fonts, and the platform channels the pages touch answered with nothing.
  static Future<SpaceHarness> load(WidgetTester tester) async {
    await tester.runAsync(_fonts);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost/voicefx'), (call) async => null);
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    return SpaceHarness._(sheet);
  }

  /// How loud each one is in the made-up call; change it to see faces move.
  final levels = ValueNotifier<Map<String, double>>(const {'a': 0.42, 'me': 0.18});

  /// A space's chat with a few messages, this device its owner, Maya a moderator.
  /// [threaded]: Maya's first message has a thread of two replies (GMFB-36).
  HangoutRoom room({bool threaded = false}) {
    final keys = NetKeys.generate();
    final channel = VoiceChannel.make('Friday hang', owner: NetCrypto.hex(keys.public));
    final store = MemoryHangoutStore();
    final at = DateTime(2026, 11, 16, 19, 40).millisecondsSinceEpoch;
    store.keepMessages(channel.chatRoom, [
      HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Starting the movie in 10, hop in', at: at),
      HangoutMessage(id: '2', from: 'a', name: 'Maya Chen', text: 'Bring snacks 🍿', at: at + 20000),
      HangoutMessage(id: '3', from: 'c', name: 'Riley', text: 'On my way!', at: at + 60000),
      HangoutMessage(id: '4', from: keys.id, name: 'Me', text: 'Saving you a seat', at: at + 90000),
      if (threaded) ...[
        HangoutMessage(id: 't1', from: 'c', name: 'Riley', text: 'Which movie?', at: at + 30000, thread: '1'),
        HangoutMessage(id: 't2', from: 'a', name: 'Maya Chen', text: 'The new one with the robots', at: at + 40000, thread: '1'),
      ],
    ]);
    store.keepRoster(channel.chatRoom, Roster.first(channel.owner).next(assigned: {'a': Role.moderator}));
    return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
  }

  /// A made-up call. [people]: how many besides this device (0 is alone, up to 8). [video]: who has video on (ids:
  /// `me`, `a` Maya, `b` Sam, `c` Riley, `d` Jordan, `e` Priya, `f` Alex, `g` Noor, `h` Hana). Every button's press is written to
  /// [log] ("mute", "leave", "person a", ...), so a test can see the buttons do what they say.
  SpaceCall call({int people = 4, Set<String> video = const {'c'}, bool muted = false, bool deafened = false, bool myVideo = false, bool withChat = true, List<String>? log, bool micLocked = false, bool canShare = false, bool sharing = false}) {
    final room = withChat ? this.room() : null;
    final roster = room?.roster;
    const names = {'a': 'Maya Chen', 'b': 'Sam Ortiz', 'c': 'Riley', 'd': 'Jordan Lee', 'e': 'Priya Natarajan', 'f': 'Alex Kim', 'g': 'Noor Haddad', 'h': 'Hana Sato'};
    final ids = names.keys.take(people.clamp(0, 8)).toList();
    final meId = room?.me ?? 'me-id';
    void say(String what) => log?.add(what);
    return SpaceCall(
      channel: room?.channel ?? VoiceChannel.make('Friday hang'),
      people: [
        SpacePerson(id: 'me', name: 'Me', me: true, muted: muted || deafened, video: myVideo || video.contains('me'), role: roster?.roleOf(meId), owner: roster?.isOwner(meId) ?? false),
        for (final id in ids)
          SpacePerson(
            id: id,
            name: names[id]!,
            muted: id == 'b',
            guest: id == 'c',
            video: video.contains(id),
            role: roster?.roleOf(id),
            username: id == 'a' ? 'maya' : null,
          ),
      ],
      levels: levels,
      changes: Listenable.merge([levels]),
      room: room,
      muted: muted,
      deafened: deafened,
      video: myVideo || video.contains('me'),
      micLocked: micLocked,
      screen: sharing,
      onScreen: canShare || sharing ? (context) => say('screen') : null,
      since: DateTime.now().subtract(const Duration(minutes: 12, seconds: 5)),
      onMute: () => say('mute'),
      onDeafen: () => say('deafen'),
      onVideo: () => say('video'),
      onLeave: () => say('leave'),
      onMinimize: () => say('minimize'),
      onPerson: (context, p) => say('person ${p.id}'),
      onSettings: (context) => say('settings'),
      onInvite: (context) => say('invite'),
      onDevices: (context) => say('devices'),
      chatBuilder: room == null ? null : ({double bottom = 0}) => HangoutChat(room: room, bottom: bottom),
    );
  }

  /// A phone held upright, a phone's width, or a computer's window.
  static const phone = Size(412, 892), computer = Size(1280, 800);

  /// Draws [page] at [size] in the app's theme, light or [dark], and keeps its picture as test/shots/[name]-light.png
  /// or -dark.png when run with --update-goldens (pictures are written, never compared: they hold the time). [dir]: the
  /// folder beside test/ the picture goes in, for pictures not kept in the repo (`../build/...`).
  Future<void> shoot(WidgetTester tester, Widget page, String name, {Size size = phone, bool dark = false, String dir = 'shots'}) async {
    tester.view.physicalSize = Size(size.width * 2, size.height * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    final state = AppState()..setTheme(dark ? 'dark' : 'light');
    await tester.pumpWidget(AppScope(
      state: state,
      child: WidgetsApp(
        color: const Color(0xFF4F5BD5),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => GlacierTheme(
          sheet: sheet,
          attrs: ghostAttrs(state, 'mobile'),
          typography: ghostTypography('noto'),
          child: InkOverrides(child: GlacierToastProvider(child: child!)),
        ),
        home: KeyedSubtree(key: ValueKey('$name-$dark'), child: page),
      ),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 500));
    if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('$dir/$name-${dark ? 'dark' : 'light'}.png'));
  }

  /// The picture again, as it stands now (after a tap), under the same name with [suffix].
  Future<void> again(WidgetTester tester, String name, {bool dark = false, String dir = 'shots'}) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('$dir/$name-${dark ? 'dark' : 'light'}.png'));
  }
}

/// The tokens the page is drawn with (for sizes in a test).
Tokens tokensIn(WidgetTester tester) => tester.element(find.byType(GlacierTheme).first).tokens;
