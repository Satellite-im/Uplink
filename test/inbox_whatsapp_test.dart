import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/whatsapp.dart';
import 'package:ghost_messaging/ui/inbox_signin_whatsapp.dart';

import 'support/list_harness.dart' show loadSheet, pumpScreen, settle;

/// A stand-in for the WhatsApp helper (sidecar/whatsapp/PROTOCOL.md): answers what it is asked, and says what
/// WhatsApp would.
class FakeHelper implements WhatsAppLink {
  final asked = <Map<String, Object?>>[];
  final _out = StreamController<Map<String, Object?>>.broadcast();
  Object? Function(Map<String, Object?> r) answer = (_) => null;
  bool linked = false;

  void event(Map<String, Object?> e) => _out.add(e);

  @override
  Stream<Map<String, Object?>> get heard => _out.stream;

  @override
  void say(Map<String, Object?> line) {
    asked.add(line);
    final r = line['op'] == 'status' ? {'linked': linked, 'jid': linked ? '15550100199@s.whatsapp.net' : '', 'number': linked ? '+15550100199' : ''} : answer(line);
    scheduleMicrotask(() => _out.add({'id': line['id'], 'ok': true, 'result': r}));
  }

  @override
  Future<void> close() async {}
}

Future<void> drain() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const me = '15550100199@s.whatsapp.net';
const jo = '15550100@s.whatsapp.net';
const sam = '15550111@s.whatsapp.net';
const crew = '120363000000000001@g.us';

/// WhatsApp through whatsmeow (lib/inbox/whatsapp.dart; Matt, 2026-11-17: "enable whatsapp but warn the user that it's
/// unsupported by whatsapp"): linked by the QR code, its history kept as chats, messages in and out, replies,
/// reactions, read, deletes, and unlinking.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });

  test('linked; history arrives as chats; a message in and out, a reply, a reaction, read, a delete; unlinked', () async {
    final dir = Directory.systemTemp.createTempSync('whatsapp');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper();
    var sent = 0;
    helper.answer = (r) => switch (r['op']) {
          'contacts' => [{'jid': jo, 'name': 'Jo Park', 'number': '+15550100'}],
          'groups' => [{'id': crew, 'title': 'Weekend crew', 'members': [jo, sam, me]}],
          'send' => {'id': 'OUT${++sent}', 'ts': 1763200500000 + sent},
          _ => null,
        };
    final w = WhatsApp(link: () async => helper, folder: dir.path);
    await w.start(AppState());
    await drain();
    expect(w.state, InboxState.signedOut);
    expect(w.id, 'whatsapp');
    expect(w.name, 'WhatsApp');

    await w.begin();
    expect(helper.asked.last, containsPair('op', 'link'));
    helper.event({'ev': 'qr', 'url': '2@abc,def,ghi', 'timeout': 60});
    await drain();
    expect(w.qr, '2@abc,def,ghi');
    helper.event({'ev': 'linked', 'jid': me, 'number': '+15550100199', 'name': 'Matt'});
    await drain();
    expect(w.state, InboxState.ready);
    expect(w.account, '+15550100199');
    expect(w.qr, isNull);
    expect(w.contacts.single.name, 'Jo Park');

    // History: a person and a group, as WhatsApp gives a newly linked device.
    helper.event({
      'ev': 'history', 'chat': jo, 'group': false, 'name': 'Jo Park', 'unread': 1, 'last': 1763200100000,
      'messages': [
        {'chat': jo, 'group': false, 'id': 'H1', 'from': me, 'mine': true, 'ts': 1763200000000, 'text': 'hi Jo', 'media': [], 'history': true},
        {'chat': jo, 'group': false, 'id': 'H2', 'from': jo, 'name': 'Jo', 'mine': false, 'ts': 1763200100000, 'text': 'are you coming tonight?', 'media': [], 'history': true, 'reactions': {me: '❤️'}},
      ],
    });
    helper.event({
      'ev': 'history', 'chat': crew, 'group': true, 'name': 'Weekend crew', 'unread': 0, 'last': 1763190000000,
      'messages': [
        {
          'chat': crew, 'group': true, 'id': 'G1', 'from': sam, 'name': 'Sam', 'mine': false, 'ts': 1763190000000, 'text': '',
          'media': [{'pointer': {'kind': 'image', 'msg': {'directPath': '/v/x', 'mediaKey': 'a2V5'}}, 'mime': 'image/jpeg', 'name': '', 'size': 2048, 'width': 800, 'height': 600}],
          'history': true,
        },
      ],
    });
    await drain();
    var chats = w.chats;
    expect(chats.map((c) => c.id), [jo, crew], reason: 'newest first');
    expect((chats[0].title, chats[0].snippet, chats[0].unread, chats[0].group), ('Jo Park', 'are you coming tonight?', 1, false));
    expect((chats[1].title, chats[1].snippet, chats[1].group), ('Weekend crew', 'Photo', true));
    final pic = w.messagesOf(crew).single;
    expect((pic.sender, pic.media.single.kind, pic.media.single.width), ('Sam', 'photo', 800));
    final h2 = w.messagesOf(jo).last;
    expect(h2.reactions.single.emoji, '❤️');
    expect(h2.reactions.single.mine, isTrue);
    // The same history again (a later sync) adds nothing.
    helper.event({'ev': 'history', 'chat': jo, 'group': false, 'name': 'Jo Park', 'unread': 1, 'last': 1763200100000, 'messages': [
      {'chat': jo, 'group': false, 'id': 'H2', 'from': jo, 'mine': false, 'ts': 1763200100000, 'text': 'are you coming tonight?', 'media': []},
    ]});
    await drain();
    expect(w.messagesOf(jo), hasLength(2));

    // A message in, in the group.
    helper.event({'ev': 'message', 'chat': crew, 'group': true, 'id': 'G2', 'from': jo, 'name': 'Jo Park', 'mine': false, 'ts': 1763200200000, 'text': 'who is driving?', 'media': []});
    await drain();
    chats = w.chats;
    expect(chats.first.id, crew);
    expect((chats.first.unread, chats.first.snippet), (1, 'who is driving?'));

    // A message out.
    await w.send(jo, 'on my way');
    final out = helper.asked.lastWhere((r) => r['op'] == 'send');
    expect((out['to'], out['text'], out.containsKey('quote')), (jo, 'on my way', false));
    final mine = w.messagesOf(jo).last;
    expect((mine.id, mine.mine, mine.state), ('OUT1', true, 'sent'));

    // A reply, in the group, to Jo's message.
    await w.reply(crew, 'G2', 'I can');
    final rep = helper.asked.lastWhere((r) => r['op'] == 'send');
    expect(rep['quote'], {'id': 'G2', 'author': jo, 'text': 'who is driving?'});
    final answered = w.messagesOf(crew).last;
    expect((answered.text, answered.replyTo, answered.replyText, answered.replySender), ('I can', 'G2', 'who is driving?', 'Jo Park'));

    // A reaction, given and received.
    await w.react(jo, 'H2', '👍');
    final react = helper.asked.lastWhere((r) => r['op'] == 'react');
    expect((react['to'], react['author'], react['target'], react['emoji'], react['remove']), (jo, jo, 'H2', '👍', false));
    expect(w.messagesOf(jo).firstWhere((m) => m.id == 'H2').reactions.single.emoji, '👍');
    helper.event({'ev': 'reaction', 'chat': jo, 'from': jo, 'target_id': 'OUT1', 'target_mine': true, 'emoji': '😂', 'remove': false});
    await drain();
    expect(w.messagesOf(jo).last.reactions.single, isA<InboxReaction>().having((r) => r.emoji, 'emoji', '😂').having((r) => r.mine, 'mine', false));
    helper.event({'ev': 'reaction', 'chat': jo, 'from': jo, 'target_id': 'OUT1', 'emoji': '', 'remove': true});
    await drain();
    expect(w.messagesOf(jo).last.reactions, isEmpty);

    // Read: receipts sent for what came in, by its sender; a receipt for what went out.
    await w.markRead(crew);
    final read = helper.asked.where((r) => r['op'] == 'read').toList();
    expect(read.map((r) => '${r['author']} ${(r['ids'] as List).join(',')}'), containsAll(['$jo G2', '$sam G1']));
    expect(w.chats.firstWhere((c) => c.id == crew).unread, 0);
    helper.event({'ev': 'receipt', 'chat': jo, 'from': jo, 'ids': ['OUT1'], 'kind': 'read'});
    await drain();

    // A delete: your own for everyone, and one Jo took back.
    expect(w.canDeleteForEveryone(jo, w.messagesOf(jo).last), isTrue);
    await w.deleteMessage(jo, 'OUT1', forEveryone: true);
    expect(helper.asked.lastWhere((r) => r['op'] == 'delete'), containsPair('target', 'OUT1'));
    expect(w.messagesOf(jo).map((m) => m.id), ['H1', 'H2']);
    helper.event({'ev': 'deleted', 'chat': crew, 'target_id': 'G2'});
    await drain();
    expect(w.messagesOf(crew).map((m) => m.id), isNot(contains('G2')));

    // Blocking a person, never a group.
    await w.block(jo, name: 'Jo Park');
    expect(helper.asked.lastWhere((r) => r['op'] == 'block'), allOf(containsPair('jid', jo), containsPair('on', true)));
    expect(() => w.block(crew, name: 'Weekend crew'), throwsStateError);

    // Kept across a restart.
    w.flush();
    w.dispose();
    final again = FakeHelper()..linked = true;
    final w2 = WhatsApp(link: () async => again, folder: dir.path);
    await w2.start(AppState());
    await drain();
    expect(w2.state, InboxState.ready);
    expect(w2.chats.map((c) => c.title), containsAll(['Jo Park', 'Weekend crew']));
    expect(w2.messagesOf(jo).map((m) => m.text), ['hi Jo', 'are you coming tonight?']);

    // WhatsApp removes the device.
    again.event({'ev': 'unlinked'});
    await drain();
    expect(w2.state, InboxState.signedOut);
    expect(w2.error, contains('removed this device'));
    w2.dispose();
  });

  test('linking with a phone number gives the eight-letter code', () async {
    final helper = FakeHelper();
    helper.answer = (r) => r['op'] == 'pair_phone' ? {'code': 'ABCD-EFGH'} : null;
    final dir = Directory.systemTemp.createTempSync('whatsapp');
    addTearDown(() => dir.deleteSync(recursive: true));
    final w = WhatsApp(link: () async => helper, folder: dir.path);
    await w.start(AppState());
    await drain();
    expect(await w.pairWithPhone('12'), isNull);
    expect(w.error, contains('country code'));
    expect(await w.pairWithPhone('+1 (555) 010-0199'), 'ABCD-EFGH');
    expect(helper.asked.lastWhere((r) => r['op'] == 'pair_phone')['phone'], '15550100199');
    expect(w.pairCode, 'ABCD-EFGH');
    w.dispose();
  });

  testWidgets('the link screen warns first, and asks WhatsApp for no QR code until "I understand" is pressed', (tester) async {
    final sheet = await loadSheet(tester);
    final helper = FakeHelper();
    final dir = Directory.systemTemp.createTempSync('whatsapp');
    addTearDown(() => dir.deleteSync(recursive: true));
    final w = WhatsApp(link: () async => helper, folder: dir.path);
    await tester.runAsync(() async {
      await w.start(AppState());
      await drain();
    });
    await pumpScreen(tester, sheet, WhatsAppLinkScreen(network: w), AppState());
    expect(find.textContaining('may suspend or ban accounts'), findsOneWidget);
    expect(find.text('I understand, link WhatsApp'), findsOneWidget);
    expect(helper.asked.where((r) => r['op'] == 'link'), isEmpty);
    expect(find.textContaining('then point it at this code'), findsNothing);

    await tester.tap(find.text('I understand, link WhatsApp'));
    await settle(tester);
    expect(helper.asked.where((r) => r['op'] == 'link'), hasLength(1));
    expect(find.textContaining('then point it at this code'), findsOneWidget);
    expect(find.text('Link with phone number instead'), findsOneWidget);
    // The warning stays in sight beneath.
    expect(find.textContaining('may suspend or ban accounts'), findsOneWidget);

    await tester.tap(find.text('Link with phone number instead'));
    await settle(tester);
    expect(find.text('Get a code'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    w.dispose();
  });

  test('the warning says WhatsApp does not support it and may ban accounts', () {
    expect(whatsAppWarning, contains('doesn\'t support or allow other apps'));
    expect(whatsAppWarning, contains('suspend or ban'));
    expect(whatsAppWarning, contains('own risk'));
  });
}
