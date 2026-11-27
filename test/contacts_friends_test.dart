import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/people.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart' show ghostAttrs;
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/ui/contacts.dart';
import 'package:glacier/glacier.dart';

import 'support/fake_friends.dart';

/// Friends on Uplink in Contacts (lib/ui/contacts.dart, lib/inbox/people.dart): a Friends filter of their own,
/// and first in All. Matt, 2026-11-17: "add the ability to sort contacts by friends in ghost".
void main() {
  group('the list (people.dart)', () {
    final people = gather(
      [
        const PhoneContact(address: '+15550000001', name: 'Maya Chen'),
        const PhoneContact(address: '+15550000002', name: 'Theo Park', friend: true),
        const PhoneContact(address: '+15550000003', name: 'Mom'),
        const PhoneContact(address: '+15550000004', name: 'Sam Rivera', friend: true),
      ],
      [const InboxContact(network: 'telegram', id: '9', name: 'Jo Park')],
    );

    test('Friends narrows to the friends alone', () {
      expect(narrowed(people, 'friends').map((s) => s.name), ['Theo Park', 'Sam Rivera']);
      expect(narrowed(people, 'all'), hasLength(5), reason: 'All is still everyone');
    });

    test('friends come first, by name; the rest keep the order they came in', () {
      expect(friendsFirst(people).map((s) => s.name), ['Sam Rivera', 'Theo Park', 'Maya Chen', 'Mom', 'Jo Park']);
      expect(friendsFirst(narrowed(people, 'telegram')).map((s) => s.name), ['Jo Park'], reason: 'nobody to put first');
    });
  });

  group('on Contacts', () {
    setUp(_answerChannel);
    tearDown(() => Friends.instance = null);

    testWidgets('a Friends chip shows only friends; All puts them first under their heading', (tester) async {
      Friends.instance = Friends(FakePort('+15551239999')
        ..stand('+15551230002', friend: 'yes')
        ..stand('+15551230003', friend: 'yes'));
      await Friends.instance.refresh();
      await _show(tester);

      expect(find.text('Friends'), findsOneWidget, reason: 'the chip');
      expect(_names(tester), ['Sam Rivera', 'Theo Park', 'Maya Chen', 'Mom']);
      expect(find.text('On Uplink'), findsOneWidget);
      // Blocked is a round button beside Add, under every filter (Matt, 2026-11-19: "move blocked to the right of the
      // add friend button instead of making it it's whole own rown"), not a row of the list.
      expect(find.byKey(const ValueKey('contacts-blocked')), findsOneWidget);
      expect(find.text('Blocked'), findsNothing);

      await tester.tap(find.text('Friends'));
      await _pumps(tester);
      expect(_names(tester), ['Sam Rivera', 'Theo Park']);
      expect(find.text('On Uplink'), findsNothing, reason: 'under Friends everyone is one');
      expect(find.text('The people you text most. Search to find anyone else.'), findsNothing);

      await tester.tap(find.text('Phone'));
      await _pumps(tester);
      expect(find.byKey(const ValueKey('contacts-blocked')), findsOneWidget);

      await tester.tap(find.text('All'));
      await _pumps(tester);
      expect(_names(tester), ['Sam Rivera', 'Theo Park', 'Maya Chen', 'Mom']);
    });

    testWidgets('with no friends and no network linked there is nothing to filter by', (tester) async {
      Friends.instance = Friends(FakePort('+15551239999'));
      await Friends.instance.refresh();
      await _show(tester);
      expect(find.text('Friends'), findsNothing);
      expect(find.text('All'), findsNothing);
      expect(_names(tester), ['Maya Chen', 'Theo Park', 'Sam Rivera', 'Mom'], reason: 'the phone\'s order');
    });
  });
}

const _contacts = [
  {'name': 'Maya Chen', 'address': '+1 555-123-0001', 'photo': null, 'label': 'Mobile'},
  {'name': 'Theo Park', 'address': '+1 555-123-0002', 'photo': null, 'label': 'Mobile'},
  {'name': 'Sam Rivera', 'address': '+1 555-123-0003', 'photo': null, 'label': 'Work'},
  {'name': 'Mom', 'address': '+1 555-123-0010', 'photo': null, 'label': 'Mobile'},
];

/// The names in the list, top to bottom.
List<String> _names(WidgetTester tester) {
  final known = {for (final c in _contacts) c['name']!};
  final shown = [for (final e in find.byType(Text).evaluate()) (e.widget as Text).data].whereType<String>().where(known.contains).toList();
  shown.sort((a, b) => tester.getTopLeft(find.text(a).first).dy.compareTo(tester.getTopLeft(find.text(b).first).dy));
  return shown;
}

Future<void> _show(WidgetTester tester) async {
  tester.view.physicalSize = const Size(412, 892) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
  installSettingsStyles(sheet);
  final state = AppState();
  await tester.pumpWidget(AppScope(
    state: state,
    child: WidgetsApp(
      color: const Color(0xFF4F5BD5),
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), typography: ghostTypography('noto'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
      home: const ContactsScreen(),
    ),
  ));
  await _pumps(tester);
}

Future<void> _pumps(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _answerChannel() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    switch (call.method) {
      case 'status':
        return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
      case 'searchContacts':
        return _contacts;
      default:
        return null;
    }
  });
}
