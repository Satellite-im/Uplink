// Pictures of features for a post in the testers' Updates channel, written to build/update-shots/ (not kept in git):
//
//   flutter test tool/update_shots_test.dart
//
// Each screen is drawn as test/screens_test.dart draws its own (the app's fonts, stylesheets and theme, dark, the
// default look), with the setup of the feature's own test, made-up people only. A picture is at most 1600 px on its
// long side and under 600 KB.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/drive.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/files/folder_sync.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/me/own_links.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/chat_rail.dart';
import 'package:ghost_messaging/ui/custom_css_editor.dart';
import 'package:ghost_messaging/ui/export_ui.dart';
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/ui/files_space/folder_sync_entry.dart';
import 'package:ghost_messaging/ui/files_space/my_files.dart';
import 'package:ghost_messaging/ui/files_space/send_to_chat.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/ui/profile.dart';
import 'package:ghost_messaging/ui/profile_card.dart';
import 'package:ghost_messaging/ui/screen_share.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/settings_panes.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';
import 'package:ghost_messaging/ui/text_scale.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:glacier/glacier.dart';

import '../test/support/space_call_harness.dart';
import '../test/support/vouch_world.dart';

const _out = 'build/update-shots';
const _phone = Size(390, 844), _computer = Size(1100, 720);

Finder _key(String k) => find.byKey(ValueKey(k));

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
  await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
}

/// The app's stylesheets, as it reads them when it starts (lib/main.dart).
Future<AccentSheets> _sheets(WidgetTester tester) async {
  final accents = (await tester.runAsync(AccentSheets.load))!;
  installSettingsStyles(accents.base);
  return accents;
}

AppState _dark() => AppState()
  ..setTheme('dark')
  ..set(NavStyle.pref, NavStyle.classic.name);

/// Draws [screen] as the app would, dark, on a phone (3x) or a computer's window (2x).
Future<void> _pump(WidgetTester tester, AccentSheets accents, Widget screen, AppState state, {bool computer = false, Size? size, Object? key}) async {
  final at = size ?? (computer ? _computer : _phone);
  final ratio = computer ? 2.0 : 3.0;
  tester.view.physicalSize = at * ratio;
  tester.view.devicePixelRatio = ratio;
  if (!computer) tester.view.padding = const FakeViewPadding(top: 44 * 3, bottom: 24 * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: state,
    child: ListenableBuilder(
      listenable: state,
      builder: (context, _) => WidgetsApp(
        color: const Color(0xFF4F5BD5),
        debugShowCheckedModeBanner: false,
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
        builder: (context, child) => GlacierTheme(
          sheet: accents.of(state),
          attrs: ghostAttrs(state, computer ? 'desktop' : 'mobile'),
          typography: ghostTypography('noto'),
          child: InkOverrides(child: GlacierToastProvider(child: AppTextScale(child: child!))),
        ),
        home: KeyedSubtree(key: ValueKey(key ?? screen.runtimeType), child: screen),
      ),
    ),
  ));
  await _settle(tester, 20);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Scrolls the list [inside] is in a little further, so no line is cut by the page's title.
void _nudge(WidgetTester tester, Finder inside, double by) {
  final position = Scrollable.of(tester.element(inside)).position;
  position.jumpTo((position.pixels + by).clamp(0, position.maxScrollExtent));
}

/// Writes what is on the screen now to build/update-shots/[name].png, made smaller until it is at most 1600 px on
/// its long side and under 600 KB.
Future<void> _snap(WidgetTester tester, String name) async {
  await _settle(tester);
  final element = find.byType(WidgetsApp).evaluate().single;
  await tester.runAsync(() async {
    final whole = await captureImage(element);
    var most = 1600.0;
    while (true) {
      final long = whole.width > whole.height ? whole.width : whole.height;
      final scale = long > most ? most / long : 1.0;
      final w = (whole.width * scale).round(), h = (whole.height * scale).round();
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(whole, Rect.fromLTWH(0, 0, whole.width.toDouble(), whole.height.toDouble()), Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..filterQuality = FilterQuality.high);
      final small = await recorder.endRecording().toImage(w, h);
      final png = (await small.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      small.dispose();
      if (png.length < 600 * 1024 || most < 600) {
        Directory(_out).createSync(recursive: true);
        File('$_out/$name.png').writeAsBytesSync(png);
        // ignore: avoid_print
        print('$_out/$name.png  ${w}x$h  ${(png.length / 1024).round()} KB');
        break;
      }
      most -= 200;
    }
    whole.dispose();
  });
}

/// A phone that answers the conversation with Maya with [messages] (newest first), and nothing else.
void _phoneWith(List<Map<String, Object?>> messages) {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    switch (call.method) {
      case 'status':
        return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
      case 'messages':
        return messages;
      case 'e2e':
        return {'address': (call.arguments as Map)['address'], 'state': 'none', 'verified': false, 'changed': false};
      case 'prefs':
        return <String, String>{};
      case 'ghostPeers':
      case 'netSmsAvailable':
        return false;
      default:
        return null;
    }
  });
}

void _quietPhone() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => switch (call.method) {
        'prefs' => <String, String>{},
        'status' => const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true},
        _ => null,
      });
}

const _maya = [Person(address: '+15550100001', name: 'Maya')];
final _now = DateTime.now().millisecondsSinceEpoch;
Map<String, Object?> _text(int id, String body, {bool mine = false, int minutes = 1, List<Map<String, Object?>> parts = const []}) =>
    {'id': id, 'kind': parts.isEmpty ? 'sms' : 'mms', 'address': mine ? '' : '+15550100001', 'body': body, 'date': _now - minutes * 60000, 'outgoing': mine, 'state': mine ? 'sent' : 'received', 'read': true, if (parts.isNotEmpty) 'parts': parts};

/// A long chat with Maya, newest first: [n] short messages over a few weeks, in bursts with pauses between, so the
/// chat's map has long lines and short ones, and more of them than it has room for.
List<Map<String, Object?>> _longChat(int n) {
  const said = [
    'Did you find the keys?', 'They were in my coat the whole time', 'Of course they were', 'Lunch on Thursday?',
    'Yes, the noodle place', 'I\'ll book for one o\'clock', 'Train is late again', 'How late?', 'Twenty minutes, they say',
    'I\'ll save you a seat', 'The garden looks great', 'Thanks, the tomatoes finally came in', 'Bring some over!',
    'Already bagged a few for you', 'Have you seen the forecast?', 'Rain all weekend', 'Board games then',
    'I\'ll bring the long one', 'Not the six hour one', 'The six hour one', 'Fine, but I pick the snacks',
    'Did the parcel come?', 'Yes, this morning', 'And?', 'It fits perfectly', 'Send a picture later',
    'How was the dentist?', 'Quick, for once', 'Lucky', 'Are you up?', 'Barely', 'Coffee at the corner in ten?',
    'Make it fifteen', 'Deal', 'That film was so long', 'But the ending!', 'I did not see it coming', 'Nobody did',
    'Can you water the plants next week?', 'Sure, same as last time?', 'Yes, the fern is the fussy one',
    'I remember the fern', 'It remembers you too', 'What was the name of that bakery?', 'The one by the bridge?',
    'Yes, with the green door', 'Fenwick\'s, I think', 'That\'s it, thank you', 'Home safe', 'Good, sleep well',
    'You too', 'Morning!', 'Is it though', 'It is after eleven', 'Then no', 'The cat is on the shelf again',
    'Which shelf?', 'The top one, somehow', 'Impressive, honestly', 'Did you send the form?', 'Doing it now',
    'It closes at five', 'Sent, with a minute to spare', 'Classic', 'Want anything from the market?',
    'Lemons, if they have them', 'They have a mountain of them', 'Two then', 'Walk after dinner?', 'Yes, the long way',
    'I\'ll bring the torch', 'New haircut?', 'Is it that obvious?', 'It looks good', 'Thank you, I was nervous',
  ];
  final out = <Map<String, Object?>>[];
  var minutes = 1;
  for (var i = 0; i < n; i++) {
    // Who wrote it: a few in a row from one, then the other, never the same pattern for long.
    final mine = (i * 5 + i ~/ 4 + i ~/ 9) % 3 == 0;
    out.add(_text(1000 + n - i, said[(n - 1 - i) % said.length], mine: mine, minutes: minutes));
    // A burst of quick answers, a slower stretch, and now and then hours or days of nothing.
    minutes += switch (i % 23) { 22 => 2 * 24 * 60 + 35, 11 => 7 * 60, 5 || 16 => 26, _ => i % 4 == 3 ? 6 : 1 };
  }
  return out;
}

Future<void> _me(Map<String, String> kept) async {
  final store = MemoryMeStore();
  kept.forEach(store.set);
  await Me.instance.start(store, ValueNotifier(0), () => null);
}

class _NoDrive implements SyncDrive {
  @override
  String get id => 'none';
  @override
  int get maxFile => 0;
  @override
  int? get free => null;
  @override
  Future<List<DriveFile>?> list() async => const [];
  @override
  Future<DriveFile?> upload(String local, String? folder, String name) async => null;
  @override
  Future<String> fetch(DriveFile f) async => throw const SyncSkip('none');
  @override
  Future<bool> delete(DriveFile f) async => false;
}

/// What stands in for a shared screen's picture: a slide.
class _Slide extends StatelessWidget {
  const _Slide();

  @override
  Widget build(BuildContext context) {
    Widget bar(double w, Color c, [double h = 14]) => Container(width: w, height: h, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(7)));
    const ink = Color(0xFFE9ECF5), dim = Color(0xFF5B6688);
    return ColoredBox(
      color: const Color(0xFF1B2440),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(64, 120, 64, 64),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Spring launch plan', style: TextStyle(fontFamily: 'Inter Variable', fontSize: 40, fontWeight: FontWeight.w700, color: ink)),
              const SizedBox(height: 10),
              const Text('Design team · week 3', style: TextStyle(fontFamily: 'Inter Variable', fontSize: 18, color: Color(0xFF9AA6CC))),
              const SizedBox(height: 40),
              bar(360, dim),
              bar(420, dim),
              bar(300, dim),
              bar(380, dim),
            ]),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final (h, c) in [(120.0, Color(0xFF6C7BFF)), (200.0, Color(0xFF6C7BFF)), (160.0, Color(0xFF6C7BFF)), (280.0, Color(0xFF7FE0B0))])
              Container(width: 44, height: h, margin: const EdgeInsets.only(left: 16, top: 60), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(8))),
          ]),
        ]),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  // 1. Settings › Appearance › Custom CSS (test/custom_css_test.dart, "the page: written, used…").
  testWidgets('custom-css', (tester) async {
    _quietPhone();
    final accents = await _sheets(tester);
    final app = _dark();
    await _pump(tester, accents, CustomCssEditor(app: app), app, size: const Size(390, 1180));
    await tester.tap(_key('custom-css-example'));
    await tester.pump();
    final field = tester.widget<EditableText>(_key('custom-css-text'));
    // The example, and one value the app can't read: listed as left out.
    field.controller.text = '${field.controller.text.trimRight()}\n:root { --app-danger: nope; }\n';
    await tester.pump();
    await tester.ensureVisible(_key('custom-css-apply'));
    await _settle(tester);
    await tester.tap(_key('custom-css-apply'));
    await _settle(tester);
    expect(_key('custom-css-problem-0'), findsOneWidget);
    await tester.ensureVisible(_key('custom-css-problem-0'));
    await _snap(tester, 'custom-css');
  });

  // 2. Settings › Appearance › Text: the slider at 125% (test/text_scale_test.dart).
  testWidgets('text-size', (tester) async {
    _quietPhone();
    final accents = await _sheets(tester);
    final app = _dark()..setTextPercent(125);
    final model = SettingsModel(app);
    addTearDown(model.dispose);
    final section = settingsSections.firstWhere((s) => s.id == 'appearance');
    // A little shorter than the other phones: the page ends just under Text, and at this height no line is cut by the title.
    await _pump(tester, accents, SectionPage(section: section, model: model), app, size: const Size(390, 808));
    final slider = _key('text-size');
    await tester.scrollUntilVisible(slider, 120, scrollable: find.byType(Scrollable).first);
    await _settle(tester);
    await Scrollable.ensureVisible(tester.element(slider), alignment: 0.36);
    _nudge(tester, slider, 36);
    await _settle(tester);
    expect(find.text('125%'), findsOneWidget);
    await _snap(tester, 'text-size');
  });

  // 3. Lists in a message (test/linked_text_format_test.dart; lib/message_format.dart).
  testWidgets('lists', (tester) async {
    _phoneWith([
      _text(14, 'Perfect. I\'ll bring:\n1. The **projector**\n2. Two long cables\n3. Snacks for *everyone*', mine: true, minutes: 1),
      _text(13, 'For Saturday we still need:\n- A **room** for ten\n- Slides\n  - intro\n  - the demo\n- Someone to take **notes**', minutes: 3),
      _text(12, 'Sure, send it over', mine: true, minutes: 5),
      _text(11, 'Can I send you the list for the workshop?', minutes: 6),
    ]);
    final accents = await _sheets(tester);
    await _pump(tester, accents, const ThreadScreen(thread: 1, people: _maya), _dark());
    expect(find.textContaining('projector', findRichText: true), findsWidgets);
    await _snap(tester, 'lists');
  });

  // 3b. The chat's map down the right of a long chat, read part of the way back (test/chat_rail_test.dart;
  // lib/ui/chat_rail.dart).
  testWidgets('chat-map', (tester) async {
    _phoneWith(_longChat(150));
    final accents = await _sheets(tester);
    await _pump(tester, accents, const ThreadScreen(thread: 1, people: _maya), _dark());
    expect(find.byType(ChatRail), findsOneWidget);
    // Back through the chat, far enough that the bright lines of what is on the screen are in the map's middle.
    final position = tester.state<ScrollableState>(find.descendant(of: find.byType(ChatRail), matching: find.byType(Scrollable)).first).position;
    for (var i = 0; i < 6; i++) {
      position.jumpTo((position.pixels + 600).clamp(0, position.maxScrollExtent));
      await _settle(tester, 4);
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _settle(tester, 20);
    await _snap(tester, 'chat-map');
  });

  // 4. Export a conversation: Markdown or JSON, alone or with its pictures and files (lib/ui/export_ui.dart).
  testWidgets('export', (tester) async {
    _phoneWith([
      _text(24, 'Got it, thank you!', mine: true, minutes: 1),
      _text(23, 'Here is the plan for the trip', minutes: 2, parts: [{'id': 931, 'type': 'application/pdf', 'name': 'trip-plan.pdf'}]),
      _text(22, 'Yes please', mine: true, minutes: 4),
      _text(21, 'Want the itinerary?', minutes: 5, parts: [{'id': 930, 'type': 'application/pdf', 'name': 'tickets.pdf'}]),
    ]);
    final accents = await _sheets(tester);
    await _pump(tester, accents, const ThreadScreen(thread: 1, people: _maya), _dark());
    final page = tester.element(find.byType(ThreadScreen));
    final asked = exportTexts(page, 1, 'Maya', _maya);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await _settle(tester, 20);
    expect(find.text('JSON, with pictures and files'), findsOneWidget);
    await _snap(tester, 'export');
    Navigator.of(page, rootNavigator: true).pop();
    await _settle(tester);
    await asked;
  });

  // 5. A shared screen's stage, with Full screen and Pin (test/call_stage_test.dart; lib/ui/screen_share.dart).
  testWidgets('share-stage', (tester) async {
    _quietPhone();
    final accents = await _sheets(tester);
    await _pump(tester, accents, ScreenStage(name: 'Maya', stream: null, picture: const _Slide(), desk: true, onPin: () {}, onBack: () {}), _dark(), computer: true);
    expect(find.text('Maya\'s screen'), findsOneWidget);
    await _snap(tester, 'share-stage');
  });

  // 6. A stage says how many are listening (test/call_stage_test.dart).
  testWidgets('stage-listening', (tester) async {
    final h = await SpaceHarness.load(tester);
    final accents = await _sheets(tester);
    final base = h.call(people: 3, withChat: false);
    final channel = VoiceChannel.make('Town hall');
    await _pump(tester, accents, TelegramCall(call: SpaceCall(channel: channel, people: base.people, levels: base.levels, changes: base.changes, listening: 12, hands: 1)), _dark());
    expect(find.text('Stage · 12 listening · 1 hand raised'), findsOneWidget);
    await _snap(tester, 'stage-listening');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  // 7a. Profile › Links (test/profile_extras_test.dart; lib/ui/own_links_ui.dart).
  testWidgets('profile-links', (tester) async {
    _quietPhone();
    final accents = await _sheets(tester);
    await tester.runAsync(() => _me({'me_username': 'sam', 'me_name': 'Sam'}));
    addTearDown(() => tester.runAsync(() => _me({})));
    Me.instance.setOwnLinks(const [OwnLink('Website', 'https://example.com/sam'), OwnLink('Portfolio', 'https://portfolio.example.com/')]);
    Buddies.instance = Buddies(VouchPort(VouchWorld(), 'sam'));
    addTearDown(() => Buddies.instance = null);
    await _pump(tester, accents, const ProfileScreen(), _dark());
    await tester.scrollUntilVisible(_key('own-link-add'), 150, scrollable: find.byType(Scrollable).first);
    await _settle(tester);
    await Scrollable.ensureVisible(tester.element(_key('own-link-0')), alignment: 0.22);
    _nudge(tester, _key('own-link-0'), 34);
    await _settle(tester);
    await _snap(tester, 'profile-links');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  // 7b. A friend's card with Elsewhere (lib/ui/profile_card.dart).
  testWidgets('profile-card-links', (tester) async {
    _quietPhone();
    final accents = await _sheets(tester);
    final w = VouchWorld();
    final sam = VouchPort(w, 'sam'), maya = VouchPort(w, 'maya');
    final b = (await tester.runAsync(() async {
      final b = await makeFriends([(sam, maya)]);
      maya.deliver(
        sam,
        Envelope(kind: 'buddy', body: const {
          's': 'me', 'u': 'maya', 'n': 'Maya', 'b': 'Design team. Coffee, maps and long walks.', 'st': '',
          'ol': [{'l': 'Website', 'u': 'https://maya.example.com/'}, {'l': 'Portfolio', 'u': 'https://example.com/maya/work'}],
        }),
      );
      await pumpEventQueue();
      return b;
    }))!;
    Buddies.instance = b[sam]!;
    addTearDown(() => Buddies.instance = null);
    await _pump(tester, accents, Builder(builder: (context) => GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => showProfile(context, ProfileSubject.ghost(id: maya.keys.id)), child: const ColoredBox(color: Color(0xFF0B0B0C), child: SizedBox.expand()))), _dark(), key: 'card');
    await tester.tapAt(const Offset(100, 300));
    await _settle(tester, 20);
    await tester.ensureVisible(find.byKey(const ValueKey('profile-own-links'), skipOffstage: false));
    await _settle(tester);
    expect(find.text('maya.example.com'), findsOneWidget);
    await _snap(tester, 'profile-card-links');
    for (final x in b.values) {
      x.dispose();
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  group('files', () {
    final drive = Drive.channelOf(Me.mineKeyOf(AccountCrypto.newWords()));
    late Directory dir;
    late FilesStore store;
    SpaceFile file(int n, String name, int size, {String by = '', String byName = 'Sam'}) =>
        SpaceFile(id: n.toRadixString(16).padLeft(32, '0'), name: name, size: size, mime: FileKind.mimeOf(name), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: by.isEmpty ? Drive.signerOf(drive)!.id : by, byName: byName, at: _now - n * 3600000);

    setUp(() {
      _quietPhone();
      dir = Directory(Directory.systemTemp.createTempSync('ghost-update-shots').resolveSymbolicLinksSync());
      store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: Directory('${dir.path}/store'));
    });
    tearDown(() async {
      await store.clear();
      dir.deleteSync(recursive: true);
    });

    // 8. My files › Send to a chat: spaces, then friends (test/my_files_screen_test.dart).
    testWidgets('send-to-friend', (tester) async {
      store.put(drive, [file(1, 'trip-plan.pdf', 482000), file(2, 'lease.pdf', 1250000), file(3, 'cabin.jpg', 2100000), file(4, 'notes.txt', 3400)], info: const FilesInfo(used: 3835400, quota: 1 << 30));
      final accents = await _sheets(tester);
      await _pump(tester, accents, MyFilesScreen(drive: () async => drive, store: store), _dark());
      const design = VoiceChannel(seed: '1111111111111111111111111111111111111111111111111111111111111111', name: 'Design team', kind: SpaceKind.text);
      const weekend = VoiceChannel(seed: '2222222222222222222222222222222222222222222222222222222222222222', name: 'Weekend plans', kind: SpaceKind.text);
      const shared = VoiceChannel(seed: '3333333333333333333333333333333333333333333333333333333333333333', name: 'Shared files', kind: SpaceKind.files);
      Buddy friend(String username, String name) => Buddy(username: username, id: 'id-$username', key: '', name: name, state: 'yes', at: 0);
      sendFileToChat(tester.element(find.byType(MyFilesScreen)), drive, file(1, 'trip-plan.pdf', 482000), store: store, spaces: const [design, weekend, shared], friends: [friend('maya', 'Maya'), friend('sam', 'Sam'), friend('riley', 'Riley')]);
      await _settle(tester, 20);
      expect(find.text('Maya'), findsOneWidget);
      await _snap(tester, 'send-to-friend');
    });

    // 9. A Files space on a computer, "Sync a folder" at its top (test/folder_sync_entry_test.dart).
    testWidgets('space-folder-sync', (tester) async {
      const space = VoiceChannel(seed: '4444444444444444444444444444444444444444444444444444444444444444', name: 'Design team', kind: SpaceKind.files);
      store.put(space, [
        file(1, 'brand-guide.pdf', 3400000, by: 'a', byName: 'Maya'),
        file(2, 'logo-final.png', 820000, by: 'b', byName: 'Sam'),
        file(3, 'launch-plan.md', 12400, by: 'a', byName: 'Maya'),
        file(4, 'homepage-v3.jpg', 1900000, by: 'c', byName: 'Riley'),
        file(5, 'budget.xlsx', 48000, by: 'b', byName: 'Sam'),
      ], info: const FilesInfo(used: 6180400, quota: 1 << 30));
      final accents = await _sheets(tester);
      final sync = FolderSync(data: () => Directory('${dir.path}/app/folder-sync'), drive: () async => _NoDrive(), home: () => '${dir.path}/home', own: () => ['${dir.path}/app'], quiet: Duration.zero, space: space.seed, driveName: space.name);
      await _pump(tester, accents, FilesSpaceScreen(channel: space, store: store, above: FolderSyncEntry(sync: sync, pick: () async => null)), _dark(), computer: true);
      expect(find.text('Sync a folder'), findsOneWidget);
      await _snap(tester, 'space-folder-sync');
    });
  });
}
