import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart' show ghostAttrs;
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/ui/compose.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:glacier/glacier.dart';

/// People on the networks signed in, found from New message (lib/ui/compose.dart; GMFB-61, Matt, Android 0.12.25:
/// "I'd like to be able to lookup contacts from connected platforms to start new chats for example slack or
/// telegram").
class _Net extends InboxNetwork {
  _Net(this.id, this.name, this.people);
  @override
  final String id;
  @override
  final String name;
  final List<InboxContact> people;
  final asked = <String>[];
  final opened = <String>[];
  @override
  List<InboxContact> get contacts => people;
  @override
  Future<List<InboxContact>> findPeople(String query) {
    asked.add(query);
    return super.findPeople(query);
  }

  @override
  Future<String?> chatWith(InboxContact contact) async {
    opened.add(contact.id);
    return 'chat-${contact.id}';
  }

  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => null;
  @override
  List<InboxChat> get chats => const [];
  @override
  List<InboxMessage> messagesOf(String chatId) => const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {}
  @override
  Future<void> markRead(String chatId) async {}
  @override
  set watching(String? chatId) {}
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
}

/// A network whose search fails: nobody else's is lost with it.
class _Broken extends _Net {
  _Broken() : super('discord', 'Discord', const []);
  @override
  Future<List<InboxContact>> findPeople(String query) => Future.error(StateError('Discord isn\'t connected'));
}

const _phone = [
  {'name': 'Ben Carter', 'address': '+1 555-123-0001', 'photo': null, 'label': 'Mobile'},
];

Future<void> _pumps(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
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
      home: const ComposeScreen(),
    ),
  ));
  await _pumps(tester);
}

void main() {
  late _Net telegram, slack;
  setUp(() {
    telegram = _Net('telegram', 'Telegram', const [
      InboxContact(network: 'telegram', id: '77', name: 'Benita Moss', handle: '@benita', number: '+1 555 000 1234'),
      InboxContact(network: 'telegram', id: '78', name: 'Kevin Moss'),
    ]);
    slack = _Net('slack', 'Slack', const [InboxContact(network: 'slack', id: 'UBEN', name: 'Ben Okoro', handle: '@ben')]);
    Inbox.instance = Inbox.of([telegram, _Broken(), slack]);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      switch (call.method) {
        case 'status':
          return const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true};
        case 'searchContacts':
          final q = '${(call.arguments as Map?)?['query'] ?? ''}'.toLowerCase();
          return [for (final c in _phone) if (q.isEmpty || c['name']!.toLowerCase().contains(q)) c];
        default:
          return null;
      }
    });
  });
  tearDown(() => Inbox.instance = null);

  testWidgets('typing finds people on the networks signed in, each named with its network; a press opens the chat there', (tester) async {
    await _show(tester);
    // Nothing typed: the phone's own list, as before, and no network is asked.
    expect(find.text('Ben Carter'), findsOneWidget);
    expect(find.text('Benita Moss'), findsNothing);
    expect(telegram.asked, isEmpty);

    await tester.enterText(find.byType(EditableText), 'ben');
    await _pumps(tester);
    expect(telegram.asked.last, 'ben');
    expect(find.text('Ben Carter'), findsOneWidget, reason: 'the phone\'s own first');
    expect(find.text('Benita Moss'), findsOneWidget);
    expect(find.text('Telegram · @benita'), findsOneWidget);
    expect(find.text('Ben Okoro'), findsOneWidget);
    expect(find.text('Slack · @ben'), findsOneWidget, reason: 'found though the network before it failed');
    expect(find.text('Kevin Moss'), findsNothing);
    expect(tester.getTopLeft(find.text('Ben Carter')).dy, lessThan(tester.getTopLeft(find.text('Benita Moss')).dy));

    await tester.tap(find.text('Ben Okoro'));
    await _pumps(tester);
    expect(slack.opened, ['UBEN']);
    final chat = tester.widget<InboxChatScreen>(find.byType(InboxChatScreen));
    expect((chat.network.id, chat.chatId), ('slack', 'chat-UBEN'));
  });

  testWidgets('with someone chosen for a text, nobody on a network is offered', (tester) async {
    await _show(tester);
    await tester.tap(find.text('Ben Carter'));
    await _pumps(tester);
    await tester.enterText(find.byType(EditableText), 'ben');
    await _pumps(tester);
    expect(find.text('Ben Okoro'), findsNothing);
    expect(find.text('Benita Moss'), findsNothing);
  });
}
