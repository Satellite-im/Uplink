import 'dart:io';

import 'package:flutter/gestures.dart' show TapGestureRecognizer;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/bluesky.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/telegram.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/plugins/embeds.dart' show EmbedCard;
import 'package:ghost_messaging/ui/thread.dart' show LinkedText;
import 'package:ghost_messaging/ui/common.dart' show IconTap, clock;
import 'package:ghost_messaging/ui/composer_box.dart';
import 'package:ghost_messaging/ui/contacts.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/inbox_ui.dart';
import 'package:ghost_messaging/ui/me.dart' show NetworkMark;
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:glacier/glacier.dart';

import 'support/list_harness.dart';

/// A network signed in, held in memory: what the screens of the inbox (lib/ui/inbox_ui.dart) draw from.
class FakeNetwork extends InboxNetwork {
  FakeNetwork(this.id, this.name, this._chats, this._messages, {this.official = false});
  @override
  final bool official;
  @override
  final String id;
  @override
  final String name;
  final List<InboxChat> _chats;
  final Map<String, List<InboxMessage>> _messages;
  final sent = <(String, String)>[];
  final read = <String>[];
  String? watched;

  @override
  InboxState get state => InboxState.ready;
  @override
  String? get error => null;
  @override
  String? get account => '@matt';
  @override
  List<InboxChat> get chats => _chats;
  @override
  bool get canSendFiles => true;
  final wanted = <int>[];
  @override
  void wantFile(int fileId) => wanted.add(fileId);
  @override
  List<InboxMessage> messagesOf(String chatId) => _messages[chatId] ?? const [];
  @override
  Future<void> load(String chatId, {bool older = false}) async {}
  @override
  Future<void> send(String chatId, String text) async {
    sent.add((chatId, text));
    _messages[chatId] = [...messagesOf(chatId), InboxMessage(id: 'n${sent.length}', text: text, date: DateTime.now(), mine: true)];
    notifyListeners();
  }

  @override
  Future<void> markRead(String chatId) async => read.add(chatId);
  @override
  set watching(String? chatId) => watched = chatId;
  @override
  Future<void> start(AppState app) async {}
  @override
  Future<void> signOut() async {}
}

/// A network with contacts of its own (Telegram's, Signal's), and the chats asked for with them.
class ContactsNetwork extends FakeNetwork {
  ContactsNetwork(String id, String name, this.people) : super(id, name, const [], {});
  final List<InboxContact> people;
  final chatsWith = <String>[];
  @override
  List<InboxContact> get contacts => people;
  @override
  Future<String?> chatWith(InboxContact contact) async {
    chatsWith.add(contact.id);
    return 'chat-${contact.id}';
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
  await _again(tester, name, dark: dark);
}

Future<void> _again(WidgetTester tester, String name, {required bool dark}) async {
  await settle(tester);
  // Written with --update-goldens, as screens_test.dart's are; a plain run builds every screen and fails on an exception.
  if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/$name-${dark ? 'dark' : 'light'}.png'));
}

Future<void> _fonts() async {
  for (final (name, file) in [('Inter Variable', 'assets/fonts/InterVariable-latin.ttf'), ('Arimo', 'assets/fonts/ArimoVariable.ttf'), ('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf')]) {
    await (FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)))).load();
  }
}

void main() {
  setUpAll(_fonts);
  late FakeNetwork telegram;
  final now = DateTime.now();

  setUp(() {
    ListPhone([
      ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7!', name: 'Maya Chen', minutes: 4),
      ListPhone.conversation(2, '+15551230005', 'Call me when you land', name: 'Dad', minutes: 300),
    ]).install();
    telegram = FakeNetwork('telegram', 'Telegram', [
      InboxChat(network: 'telegram', id: '10', title: 'Jo Park', date: now.subtract(const Duration(minutes: 2)), snippet: 'are you coming tonight?', unread: 2),
      InboxChat(network: 'telegram', id: '20', title: 'Weekend crew', date: now.subtract(const Duration(hours: 3)), snippet: 'tent is packed', group: true),
      InboxChat(network: 'telegram', id: '30', title: 'Sam Rivera', date: now.subtract(const Duration(days: 2)), snippet: 'thanks!', lastFromMe: true),
    ], {
      '10': [
        InboxMessage(id: '1', text: 'hey! long time', date: now.subtract(const Duration(minutes: 30)), mine: false),
        InboxMessage(id: '2', text: 'I know, how have you been?', date: now.subtract(const Duration(minutes: 28)), mine: true),
        InboxMessage(id: '3', text: 'good! there\'s a thing at the park later', date: now.subtract(const Duration(minutes: 3)), mine: false),
        InboxMessage(id: '4', text: 'are you coming tonight?', date: now.subtract(const Duration(minutes: 2)), mine: false),
        InboxMessage(id: '5', text: 'the park', date: now.subtract(const Duration(minutes: 1)), mine: false, media: const [InboxMedia(kind: 'photo', fileId: 42, width: 800, height: 600)]),
        InboxMessage(id: '6', text: '', date: now.subtract(const Duration(seconds: 30)), mine: false, media: const [InboxMedia(kind: 'file', fileId: 43, name: 'tickets.pdf', size: 245760)]),
      ],
    }, official: true);
    Inbox.instance = Inbox.of([telegram, FakeNetwork('bluesky', 'Bluesky', const [], const {})]);
  });

  tearDown(() => Inbox.instance = null);

  testWidgets('a signed-in network\'s chats are among the texts, newest first, marked with its logo; one opens, is read, and is answered', (tester) async {
    final sheet = await loadSheet(tester);
    for (final dark in [false, true]) {
      // Mixed into Messages (Matt, 2026-11-15: "Id like the telegram chats to be mixed into the normal text messages
      // (same with bluesky) just add a telegram icon in thr corner of the bubble"): no tab of their own.
      await _shoot(tester, sheet, const ConversationsScreen(), '16-inbox-list', dark: dark);
      expect(find.bySemanticsLabel(RegExp('^Telegram')), findsNothing);
      expect(find.text('Jo Park'), findsOneWidget);
      expect(find.text('Maya Chen'), findsWidgets);
      final rows = find.byType(InboxChatRow);
      expect(rows, findsWidgets);
      final badges = find.descendant(of: rows.first, matching: find.byType(NetworkMark));
      expect(badges, findsOneWidget, reason: 'Telegram\'s logo on the corner of the face');
      // The newest first: Jo Park (two minutes ago) above Weekend crew (three hours).
      expect(tester.getTopLeft(find.text('Jo Park')).dy, lessThan(tester.getTopLeft(find.text('Weekend crew')).dy));

      await tester.tap(find.text('Jo Park'));
      await settle(tester);
      expect(telegram.watched, '10');
      expect(telegram.read, contains('10'));
      expect(find.text('are you coming tonight?'), findsOneWidget);
      await _again(tester, '16-inbox-chat', dark: dark);

      await tester.enterText(find.byType(EditableText).last, 'on my way');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(telegram.sent.last, ('10', 'on my way'));
      expect(find.text('on my way'), findsWidgets);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle(tester);
    }
  });

  // Matt, 2026-11-15: "Also use the same composer for telegram and if possible proxy the archive and delete messages
  // too, if we can't actually delete telegram messages add them to a ignore or archive list".
  testWidgets('a chat slid is archived and pinned (in Uplink\'s own lists where the network keeps none); its page has the same composer, and a message is deleted', (tester) async {
    final sheet = await loadSheet(tester);
    telegram.listStore = AppState();
    await _shoot(tester, sheet, const ConversationsScreen(), '16-inbox-list-archive', dark: false);
    // Slid left to Archive and let go, as a conversation of texts is (Matt, 2026-11-15: "Don't use a press and hold
    // menu on telegram chats use the same slide solution normal messages use").
    final left = await tester.startGesture(tester.getCenter(find.text('Weekend crew')));
    await left.moveBy(const Offset(-30, 0));
    await left.moveBy(const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await left.up();
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Weekend crew'), findsNothing);
    expect(telegram.archivedChats.map((c) => c.title), ['Weekend crew']);
    // Slid right, pinned: at the top, above the newest text.
    final right = await tester.startGesture(tester.getCenter(find.text('Sam Rivera')));
    await right.moveBy(const Offset(30, 0));
    await right.moveBy(const Offset(80, 0));
    await tester.pump(const Duration(milliseconds: 200));
    await right.up();
    await settle(tester);
    expect(telegram.localList('pinned'), {'30'});
    expect(tester.getTopLeft(find.text('Sam Rivera')).dy, lessThan(tester.getTopLeft(find.text('Jo Park')).dy));

    await tester.tap(find.text('Jo Park'));
    await settle(tester);
    expect(find.byType(ComposerBox), findsOneWidget);
    // Laid out as a conversation of texts is (Matt, 2026-11-15: "The compose window should also use the exact same
    // layout as messages"): + at its start, the microphone at its end while it is empty.
    expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Add an attachment'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Record a voice message'), findsOneWidget);
    // A picture is asked for as it is drawn; a file is its name and size.
    expect(telegram.wanted, contains(42));
    expect(find.text('tickets.pdf'), findsOneWidget);
    expect(find.text('240 KB'), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, 'hi');
    await settle(tester);
    expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send' && w.onPressed != null), findsOneWidget);
    await tester.enterText(find.byType(EditableText).last, '');
    await settle(tester);
    await tester.longPress(find.text('hey! long time'));
    await settle(tester);
    expect(find.text('Delete for everyone'), findsNothing, reason: 'this network says nothing can be');
    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(find.text('hey! long time'), findsNothing);
    expect(find.text('I know, how have you been?'), findsOneWidget);
  });

  // Matt, 2026-11-15: "proxy telegram codes through to the codes tab as well".
  test('a sign-in code from Telegram\'s own account or a bot is a code; a friend\'s is not', () {
    final now = DateTime.now();
    InboxChat chat(String text, {bool service = true, bool mine = false}) => InboxChat(network: 'telegram', id: '1', title: 'Telegram', date: now, snippet: text, service: service, lastFromMe: mine);
    expect(inboxCode(chat('Login code: 48213. Do not give this code to anyone')), '48213');
    expect(inboxCode(chat('Login code: 48213', service: false)), isNull, reason: 'a person\'s chat');
    expect(inboxCode(chat('Login code: 48213', mine: true)), isNull);
    expect(inboxCode(chat('Welcome to Telegram')), isNull);
  });

  testWidgets('the filters sort Telegram\'s and Signal\'s chats as they sort texts: a kind hidden from Messages hides a chat of it too', (tester) async {
    // Matt, 2026-11-16: "Filters should apply to all chats including telegram and signal make sure the filters are
    // processing all chats".
    final sheet = await loadSheet(tester);
    final net = FakeNetwork('telegram', 'Telegram', [
      InboxChat(network: 'telegram', id: '10', title: 'Jo Park', date: now.subtract(const Duration(minutes: 2)), snippet: 'are you coming tonight?'),
      InboxChat(network: 'telegram', id: '40', title: 'Pat for Senate', date: now.subtract(const Duration(minutes: 1)), snippet: 'Chip in \$5 to keep us in this race! Paid for by Friends of Pat Rivera', unread: 1, stranger: true),
    ], {});
    Inbox.instance = Inbox.of([net]);
    await _shoot(tester, sheet, const ConversationsScreen(), 'x-inbox-filtered', dark: false);
    expect(find.text('Jo Park'), findsOneWidget);
    expect(find.text('Pat for Senate'), findsNothing, reason: 'political, which Messages hides as it ships');
  });

  testWidgets('in a group, the sender\'s name and their words start at the same left edge, the time after the name', (tester) async {
    // Matt, 2026-11-25: "For channels on slack and other groups please use the same chat UI without the bubbles we use
    // with text channels on circles" (lib/ui/flat_line.dart; test/flat_groups_test.dart).
    final sheet = await loadSheet(tester);
    final at = now.subtract(const Duration(minutes: 5));
    final crew = FakeNetwork('telegram', 'Telegram', [
      InboxChat(network: 'telegram', id: '20', title: 'Weekend crew', date: at, snippet: 'tent is packed', group: true),
    ], {
      '20': [InboxMessage(id: '1', text: 'tent is packed', date: at, mine: false, sender: 'Priya')],
    });
    await _shoot(tester, sheet, InboxChatScreen(network: crew, chatId: '20'), 'x-inbox-group-align', dark: false);
    expect(tester.getTopLeft(find.text('Priya')).dx, moreOrLessEquals(tester.getTopLeft(find.text('tent is packed')).dx, epsilon: 0.5));
    expect(tester.getTopLeft(find.text(clock(at))).dx, greaterThan(tester.getTopRight(find.text('Priya')).dx));
  });

  testWidgets('a sticker, sent or received, is drawn on its own with no bubble behind it; a picture keeps its bubble', (tester) async {
    // Matt, 2026-11-20: "stickers in telegram chat and others render inside chat bubbles instead of transparent
    // backgrounds when sent and when recieved".
    final sheet = await loadSheet(tester);
    final dir = Directory.systemTemp.createTempSync('stickers');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sticker = File('${dir.path}/sticker.png')..writeAsBytesSync(File('assets/stickers/mischief/14.png').readAsBytesSync());
    final at = now.subtract(const Duration(minutes: 5));
    final crew = FakeNetwork('telegram', 'Telegram', [
      InboxChat(network: 'telegram', id: '30', title: 'Priya', date: at, snippet: 'Sticker'),
    ], {
      '30': [
        InboxMessage(id: '1', text: 'look at this', date: at, mine: false),
        InboxMessage(id: '2', text: '', date: at, mine: false, media: [InboxMedia(kind: 'sticker', fileId: 50, path: sticker.path, width: 512, height: 512)]),
        InboxMessage(id: '3', text: '', date: at.add(const Duration(minutes: 1)), mine: true, media: [InboxMedia(kind: 'sticker', fileId: 51, path: sticker.path, width: 512, height: 512)]),
        InboxMessage(id: '4', text: 'and a photo', date: at.add(const Duration(minutes: 2)), mine: true, media: const [InboxMedia(kind: 'photo', fileId: 52, width: 800, height: 600)]),
      ],
    });
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, InboxChatScreen(network: crew, chatId: '30'), 'x-inbox-stickers', dark: dark);
      // The stickers' files read and decoded for real, then the picture taken again with them drawn.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await _again(tester, 'x-inbox-stickers', dark: dark);
      expect(find.byType(InboxSticker), findsNWidgets(2));
      bool bubble(Widget w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color != null;
      for (final e in find.byType(InboxSticker).evaluate()) {
        expect(find.ancestor(of: find.byWidget(e.widget), matching: find.byWidgetPredicate(bubble)), findsNothing, reason: 'no bubble behind a sticker');
      }
      expect(find.ancestor(of: find.text('and a photo'), matching: find.byWidgetPredicate(bubble)), findsOneWidget, reason: 'words keep their bubble');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a group chat opened with unread messages marks where they begin; a chat with one person does not', (tester) async {
    // Matt, 2026-11-16: "Add a "new messages" divider like discord has for all group chats across telegram signal and
    // RCS".
    final sheet = await loadSheet(tester);
    DateTime ago(int m) => now.subtract(Duration(minutes: m));
    final messages = [
      InboxMessage(id: '1', text: 'who is driving', date: ago(30), mine: false, sender: 'Priya'),
      InboxMessage(id: '2', text: 'I can', date: ago(25), mine: true),
      InboxMessage(id: '3', text: 'tent is packed', date: ago(10), mine: false, sender: 'Priya'),
      InboxMessage(id: '4', text: 'leaving at 8', date: ago(5), mine: false, sender: 'Dev'),
    ];
    final crew = FakeNetwork('telegram', 'Telegram', [
      InboxChat(network: 'telegram', id: '20', title: 'Weekend crew', date: ago(5), snippet: 'leaving at 8', group: true, unread: 2),
      InboxChat(network: 'telegram', id: '21', title: 'Jo Park', date: ago(5), snippet: 'leaving at 8', unread: 2),
    ], {'20': messages, '21': messages});
    await _shoot(tester, sheet, InboxChatScreen(network: crew, chatId: '20'), 'x-inbox-new-messages', dark: false);
    expect(find.byKey(const ValueKey('new-messages')), findsOneWidget);
    final divider = tester.getRect(find.byKey(const ValueKey('new-messages')));
    expect(divider.bottom, lessThanOrEqualTo(tester.getTopLeft(find.text('tent is packed')).dy), reason: 'above the older of the two unread');
    expect(divider.top, greaterThanOrEqualTo(tester.getBottomLeft(find.text('I can')).dy - 0.01));
    await _shoot(tester, sheet, InboxChatScreen(network: crew, chatId: '21'), 'x-inbox-new-messages-one', dark: false);
    expect(find.byKey(const ValueKey('new-messages')), findsNothing);
  });

  testWidgets('signing in: Bluesky\'s page, and Telegram\'s steps', (tester) async {
    final sheet = await loadSheet(tester);
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, BlueskySignInScreen(network: Bluesky(entryway: 'http://127.0.0.1:9', plc: 'http://127.0.0.1:9')), '16-inbox-bluesky-sign-in', dark: dark);
      expect(find.textContaining('Allow access to your direct messages'), findsOneWidget);

      final unavailable = Telegram(apiId: 0, apiHash: '');
      await _shoot(tester, sheet, TelegramSignInScreen(network: unavailable), '16-inbox-telegram-unavailable', dark: dark);
      expect(find.textContaining('isn\'t in this build'), findsOneWidget);
    }
  });

  testWidgets('Bluesky is coming soon: no tab, no sign-in, and never started', (tester) async {
    Inbox.instance = null;
    final own = Inbox.instance;
    final bluesky = own.named('bluesky')!;
    expect(bluesky.soon, isTrue);
    expect(own.ready, isNot(contains(bluesky)));
    final sheet = await loadSheet(tester);
    addInboxSettings();
    addTearDown(() => SettingsSources.remove(inboxSettingsSections));
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, const SettingsSectionScreen('inbox-bluesky'), '16-inbox-bluesky-soon', dark: dark);
      expect(find.text('Coming soon'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);
    }
  });

  // Matt, 2026-11-17: "move the connections to it's own sub setting, label it as such and put connecting to telegram etc
  // all under that page so as to not crowd the main settings page there shuld be a sub section to pick and modify each".
  testWidgets('the networks are under Settings › Connections, each with a page of its own', (tester) async {
    final sections = inboxSettingsSections();
    expect(sections.map((s) => s.label), ['Connections', 'Telegram', 'Bluesky']);
    expect(sections.where((s) => s.listed).map((s) => s.id), ['connections'], reason: 'one row in Settings\' list, not one a network');
    final sheet = await loadSheet(tester);
    addInboxSettings();
    addTearDown(() => SettingsSources.remove(inboxSettingsSections));
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, SettingsSectionScreen('connections', key: ValueKey('connections-$dark')), '16-inbox-connections', dark: dark);
      expect(find.text('CONNECTED'), findsOneWidget);
      expect(find.byKey(const ValueKey('connection-telegram')), findsOneWidget);
      expect(find.byKey(const ValueKey('connection-bluesky')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('connection-telegram')));
      await tester.pumpAndSettle();
      expect(find.text('@matt'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      // Back to Connections, as its way back does.
      Navigator.of(tester.element(find.text('Sign out'))).pop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('connection-telegram')), findsOneWidget);
      await _shoot(tester, sheet, const SettingsSectionScreen('inbox-telegram'), '16-inbox-settings', dark: dark);
      expect(find.text('Sign out'), findsOneWidget);
    }
  });

  // Matt, 2026-11-16: "Show telegram and signal contacts when linked with icons to show which each is and filters, where
  // contacts can be messages on multiple platforms as which you like to use when stating a conversation".
  testWidgets('contacts: Telegram\'s and Signal\'s with the phone\'s, one row a person with each place\'s mark, filters, and which way to write', (tester) async {
    final sheet = await loadSheet(tester);
    final phone = ListPhone(const [])
      ..contacts.addAll([
        {'address': '+15551230001', 'name': 'Maya Chen', 'label': 'Mobile'},
        {'address': '+15551230005', 'name': 'Dad', 'label': 'Home'},
      ])
      ..install();
    final tg = ContactsNetwork('telegram', 'Telegram', const [
      InboxContact(network: 'telegram', id: '11', name: 'Maya C', number: '+15551230001', handle: '@mayac'),
      InboxContact(network: 'telegram', id: '12', name: 'Jo Park', handle: '@jopark'),
    ]);
    final sg = ContactsNetwork('signal', 'Signal', const [
      InboxContact(network: 'signal', id: 'aci-maya', name: 'Maya', number: '+1 555 123 0001'),
      InboxContact(network: 'signal', id: 'aci-riley', name: 'Riley Fox', number: '+447700900123'),
    ]);
    Inbox.instance = Inbox.of([tg, sg]);
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, const ContactsScreen(), '16-inbox-contacts', dark: dark);
    }
    // One row for Maya though she is in three places; Jo and Riley from the networks; filters for each network.
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('Jo Park'), findsOneWidget);
    expect(find.text('Riley Fox'), findsOneWidget);
    for (final f in ['All', 'Phone', 'Telegram', 'Signal']) {
      expect(find.text(f), findsOneWidget, reason: 'the $f filter');
    }

    // Signal's filter: only those on Signal.
    // The chips scroll since Friends joined them (2026-11-17): brought into view first.
    await tester.ensureVisible(find.text('Signal'));
    await tester.tap(find.text('Signal'));
    await settle(tester);
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('Riley Fox'), findsOneWidget);
    expect(find.text('Jo Park'), findsNothing);
    expect(find.text('Dad'), findsNothing);
    // The chips scroll since Friends joined them (2026-11-17): brought into view first.
    await tester.ensureVisible(find.text('All'));
    await tester.tap(find.text('All'));
    await settle(tester);

    // Maya can be written to three ways: which is asked, each with its mark.
    await tester.tap(find.text('Maya Chen'));
    await settle(tester);
    await _again(tester, '16-inbox-contacts-which', dark: true);
    expect(find.text('Message Maya Chen with'), findsOneWidget);
    expect(find.text('Text message'), findsOneWidget);
    expect(find.text('@mayac'), findsOneWidget, reason: 'Telegram\'s choice says who on Telegram');
    await tester.tap(find.widgetWithText(GlacierPressable, 'Signal').last);
    await settle(tester);
    expect(sg.chatsWith, ['aci-maya']);

    // Jo is on Telegram alone: straight there, nothing asked.
    await tester.pumpWidget(const SizedBox());
    await _shoot(tester, sheet, const ContactsScreen(), '16-inbox-contacts', dark: true);
    await tester.tap(find.text('Jo Park'));
    await settle(tester);
    expect(find.text('Message Jo Park with'), findsNothing);
    expect(tg.chatsWith, ['12']);

    // Dad is only on the phone: his conversation, by number.
    await tester.pumpWidget(const SizedBox());
    await _shoot(tester, sheet, const ContactsScreen(), '16-inbox-contacts', dark: true);
    await tester.tap(find.text('Dad'));
    await settle(tester);
    expect(phone.threads, ['+15551230005']);
  });

  // Matt, 2026-11-16: "Tabbing out and into thr app doesnt clear the focus on the signal convo so the keyboard can't be
  // toggled open".
  testWidgets('a chat\'s keyboard comes back on returning to the app, and on a press while the field has focus', (tester) async {
    final sheet = await loadSheet(tester);
    await _shoot(tester, sheet, InboxChatScreen(network: telegram, chatId: '10'), '16-inbox-chat-keys', dark: false);
    final field = find.byType(EditableText);
    await tester.tap(field);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue, reason: 'the first press opens it');

    // Leaving the app: Android hides the keyboard, the field keeps its focus.
    tester.testTextInput.hide();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);

    // Back: the keys come back with the cursor.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue, reason: 'shown again on returning');

    // Hidden by the back gesture, then a press on the field that still has focus: shown again.
    tester.testTextInput.hide();
    await tester.pump();
    await tester.tap(field);
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue, reason: 'a press asks for the keyboard even with focus already there');
  });

  // Matt, 2026-11-16: "I still can't mark telegram and signal messages as read with the read all even though they're
  // marked as unread".
  testWidgets('Mark all read reads every unread chat, the ones a filter hides too, and in a network\'s own tab', (tester) async {
    final sheet = await loadSheet(tester);
    final signal = FakeNetwork('signal', 'Signal', [
      InboxChat(network: 'signal', id: 's1', title: 'Ana', date: now.subtract(const Duration(minutes: 5)), snippet: 'lunch?', unread: 1),
      // Hidden from Messages by the filter as the app ships: still unread, still read by Mark all read.
      InboxChat(network: 'signal', id: 's2', title: 'Vote Pat', date: now.subtract(const Duration(minutes: 6)), snippet: 'Paid for by Friends of Pat. Election day is Tuesday!', unread: 1, stranger: true),
    ], const {});
    Inbox.instance = Inbox.of([telegram, signal]);
    await pumpScreen(tester, sheet, const ConversationsScreen(), AppState());
    await settle(tester);
    expect(find.text('Vote Pat'), findsNothing, reason: 'hidden by the filter');
    expect(tester.widget<QuickRow>(find.byKey(const ValueKey('quick-mark-read'))).count, greaterThanOrEqualTo(3), reason: 'the chats count, not the texts alone');
    await tester.tap(find.byKey(const ValueKey('quick-mark-read')));
    await settle(tester);
    expect(signal.read, containsAll(['s1', 's2']));
    expect(telegram.read, contains('10'));
  });

  // Matt, 2026-11-16: "The mark read button should work for telegram and signal as well as standard messages".
  testWidgets('Mark all read counts and reads Telegram\'s and Signal\'s chats with the texts', (tester) async {
    final phone = ListPhone([
      ListPhone.conversation(1, '+15551230001', 'Sounds good, see you at 7!', name: 'Maya Chen', minutes: 4, unread: true),
      ListPhone.conversation(2, '+15551230005', 'Call me when you land', name: 'Dad', minutes: 300),
    ])..install();
    final signal = FakeNetwork('signal', 'Signal', [
      InboxChat(network: 'signal', id: 's1', title: 'Ana', date: now.subtract(const Duration(minutes: 6)), snippet: 'see you there', unread: 1),
      InboxChat(network: 'signal', id: 's2', title: 'Ben', date: now.subtract(const Duration(hours: 5)), snippet: 'ok'),
    ], {});
    Inbox.instance = Inbox.of([telegram, signal]);
    final sheet = await loadSheet(tester);
    await _shoot(tester, sheet, const ConversationsScreen(), '16-inbox-mark-read', dark: false);
    final button = find.byKey(const ValueKey('quick-mark-read'));
    expect(tester.widget<QuickRow>(button).count, 3, reason: 'Maya\'s text, Jo Park on Telegram, Ana on Signal');
    await tester.tap(button);
    await settle(tester);
    expect(telegram.read, ['10'], reason: 'only the unread chat');
    expect(signal.read, ['s1']);
    expect(phone.asked, contains('markRead 1'));
    expect(phone.asked.where((a) => a == 'markRead 2'), isEmpty);
  });

  testWidgets('with only chats unread, the button is not greyed out and reads them', (tester) async {
    final signal = FakeNetwork('signal', 'Signal', [
      InboxChat(network: 'signal', id: 's1', title: 'Ana', date: now.subtract(const Duration(minutes: 6)), snippet: 'see you there', unread: 4),
    ], {});
    Inbox.instance = Inbox.of([telegram, signal]);
    final sheet = await loadSheet(tester);
    await _shoot(tester, sheet, const ConversationsScreen(), '16-inbox-mark-read-chats', dark: false);
    expect(tester.widget<QuickRow>(find.byKey(const ValueKey('quick-mark-read'))).count, 2, reason: 'no unread texts; Jo Park and Ana');
    await tester.tap(find.byKey(const ValueKey('quick-mark-read')));
    await settle(tester);
    expect(telegram.read, ['10']);
    expect(signal.read, ['s1']);
  });

  testWidgets('a link in a Signal or Telegram message is underlined, opens when pressed, and gets its card', (tester) async {
    // Matt, 2026-11-16: "links are not expanding or clickable on telegram and signal chats".
    final opened = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      if (call.method == 'openLink') {
        opened.add((call.arguments as Map)['url'] as String);
        return true;
      }
      return null;
    });
    final sheet = await loadSheet(tester);
    final at = now.subtract(const Duration(minutes: 5));
    final signal = FakeNetwork('signal', 'Signal', [
      InboxChat(network: 'signal', id: 's1', title: 'Ana', date: at, snippet: 'look'),
    ], {
      's1': [InboxMessage(id: '1', text: 'look at https://example.com/menu tonight', date: at, mine: false)],
    });
    await _shoot(tester, sheet, InboxChatScreen(network: signal, chatId: 's1'), 'x-inbox-link', dark: false);
    expect(find.byType(LinkedText), findsOneWidget);
    expect(find.byType(EmbedCard), findsOneWidget, reason: 'Link previews is on as the app ships');
    // The press on the link: its span's recognizer, as a tap on those words runs it.
    final rich = tester.widgetList<RichText>(find.descendant(of: find.byType(LinkedText), matching: find.byType(RichText))).first;
    TapGestureRecognizer? tap;
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.recognizer is TapGestureRecognizer) tap = span.recognizer as TapGestureRecognizer;
      return tap == null;
    });
    expect(tap, isNotNull, reason: 'the link is pressable');
    tap!.onTap!();
    await tester.pump();
    expect(opened.single, contains('example.com/menu'));
  });

  // Matt, 2026-11-17: "clicking on a telegram or signal chat does not highlight it as selected in the sidebar".
  testWidgets('a Telegram chat opened beside the list is marked in it, as a conversation of texts is', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), AppState(), size: const Size(1200, 800));
    await settle(tester);
    bool marked(String title) => tester.widget<InboxChatRow>(find.ancestor(of: find.text(title).first, matching: find.byType(InboxChatRow)).first).selected;
    expect(marked('Jo Park'), isFalse);
    await tester.tap(find.text('Jo Park').first);
    await settle(tester);
    expect(marked('Jo Park'), isTrue);
    expect(marked('Weekend crew'), isFalse);
  });
}
