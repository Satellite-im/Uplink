import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/add_friend_drawer.dart';
import 'package:ghost_messaging/ui/contacts.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// The Add button beside Contacts' search and the drawer it opens (lib/ui/add_friend_drawer.dart), drawn in light and
/// dark into test/shots/ with `--update-goldens`.

/// A server that knows @sam and @jo, and this install as @matt.
class _Port implements BuddiesPort {
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => switch (username) {
        'sam' => (id: 'sam', key: 'k1'),
        'jo' => (id: 'jo', key: 'k2'),
        'matt' => (id: 'me', key: 'k'),
        _ => null,
      };
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => '[]';
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

Future<void> _fonts() async {
  for (final (name, file) in [('Inter Variable', 'assets/fonts/InterVariable-latin.ttf'), ('Arimo', 'assets/fonts/ArimoVariable.ttf'), ('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf')]) {
    await (FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)))).load();
  }
}

Future<void> _shoot(WidgetTester tester, TokenSheet sheet, Widget screen, String name, {required bool dark}) async {
  final state = AppState()..setTheme(dark ? 'dark' : 'light');
  tester.view.physicalSize = const Size(412, 892) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
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
      home: KeyedSubtree(key: ValueKey('$name-$dark'), child: screen),
    ),
  ));
  await settle(tester);
}

Future<void> _picture(WidgetTester tester, String name, {required bool dark}) async {
  await settle(tester);
  if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/$name-${dark ? 'dark' : 'light'}.png'));
}

Future<Me> _me(String? username) async {
  final store = MemoryMeStore();
  if (username != null) store.set('me_username', username);
  final m = Me.forTest();
  await m.start(store, ValueNotifier(0), () => null);
  return m;
}

void main() {
  setUpAll(_fonts);
  setUp(() => ListPhone(const []).install());

  testWidgets('Contacts has Add beside its search; it opens the drawer', (tester) async {
    final sheet = await loadSheet(tester);
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, const ContactsScreen(), '17-add-friend-contacts', dark: dark);
      expect(find.byKey(const ValueKey('add-friend')), findsOneWidget);
      await _picture(tester, '17-add-friend-contacts', dark: dark);
      await tester.tap(find.byKey(const ValueKey('add-friend')));
      await settle(tester);
      expect(find.byType(AddFriendDrawer), findsOneWidget);
      await _picture(tester, '17-add-friend-opened', dark: dark);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle(tester);
    }
  });

  testWidgets('the drawer: someone found, and a username chosen first', (tester) async {
    final sheet = await loadSheet(tester);
    final buddies = Buddies(_Port());
    for (final dark in [false, true]) {
      final me = (await tester.runAsync(() => _me('matt')))!;
      await _shoot(tester, sheet, Builder(builder: (context) => AddFriendDrawer(buddies: buddies, me: me)), '17-add-friend-drawer', dark: dark);
      await tester.enterText(find.byType(EditableText), '@sam');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(tester);
      expect(find.text('On Uplink'), findsOneWidget);
      await _picture(tester, '17-add-friend-drawer', dark: dark);

      final none = (await tester.runAsync(() => _me(null)))!;
      await _shoot(tester, sheet, AddFriendDrawer(buddies: buddies, me: none), '17-add-friend-username', dark: dark);
      expect(find.text('Choose your username'), findsOneWidget);
      await _picture(tester, '17-add-friend-username', dark: dark);
    }
  });
}
