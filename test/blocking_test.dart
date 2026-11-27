import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/signal.dart';
import 'package:ghost_messaging/inbox/telegram.dart';

import 'inbox_signal_test.dart' show FakeHelper;
import 'inbox_telegram_test.dart' show FakeTd;

Future<void> settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Blocking a Telegram or Signal person on the network itself, and in Uplink's own list so they are gone from here at
/// once (lib/inbox/inbox.dart; Matt, 2026-11-17: "I'd like to be able to block signal and telegram users"; "add the
/// signal helper and do your recommendation").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });

  Future<(Telegram, FakeTd)> readyTelegram() async {
    final td = FakeTd();
    td.answer = (r) => switch (r['@type']) {
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Matt'},
          'loadChats' => {'@type': 'error', 'code': 404, 'message': 'Not Found'},
          _ => {'@type': 'ok'},
        };
    final tg = Telegram(apiId: 12345, apiHash: 'hash', folder: Directory.systemTemp.createTempSync('tg').path, transport: () async => td)..listStore = AppState();
    await tg.start(AppState());
    await tg.begin();
    td.auth('authorizationStateReady');
    await settle();
    // A person (a one-to-one chat's id is the person's, as Telegram has it) and a group.
    td.say({'@type': 'updateUser', 'user': {'id': 7, 'first_name': 'Jo', 'last_name': 'Park'}});
    for (final (id, title, type) in [(7, 'Jo Park', {'@type': 'chatTypePrivate', 'user_id': 7}), (20, 'Weekend crew', {'@type': 'chatTypeBasicGroup', 'basic_group_id': 2})]) {
      td.say({
        '@type': 'updateNewChat',
        'chat': {
          'id': id,
          'title': title,
          'type': type,
          'positions': [
            {'list': {'@type': 'chatListMain'}, 'order': '$id'},
          ],
          'last_message': {'id': 1, 'chat_id': id, 'is_outgoing': false, 'date': 1763200000, 'content': {'@type': 'messageText', 'text': {'text': 'hi'}}},
        },
      });
    }
    await settle();
    return (tg, td);
  }

  test('Telegram: blocked on Telegram itself and gone from the list; unblocked comes back', () async {
    final (tg, td) = await readyTelegram();
    expect(tg.canBlock, isTrue);
    expect(tg.shownChats.map((c) => c.title), contains('Jo Park'));

    await tg.block('7', name: 'Jo Park');
    final asked = td.sent.lastWhere((r) => r['@type'] == 'setMessageSenderBlockList');
    expect(asked['sender_id'], {'@type': 'messageSenderUser', 'user_id': 7});
    expect(asked['block_list'], {'@type': 'blockListMain'});
    expect(tg.isBlocked('7'), isTrue);
    expect(tg.shownChats.map((c) => c.title), isNot(contains('Jo Park')));
    expect(tg.blockedPeople, [(id: '7', name: 'Jo Park')]);

    await tg.block('7', name: 'Jo Park', on: false);
    expect(td.sent.lastWhere((r) => r['@type'] == 'setMessageSenderBlockList')['block_list'], isNull);
    expect(tg.isBlocked('7'), isFalse);
    expect(tg.shownChats.map((c) => c.title), contains('Jo Park'));
    tg.dispose();
  });

  test('Telegram: a refusal is said and nothing changes here', () async {
    final (tg, td) = await readyTelegram();
    td.answer = (r) => r['@type'] == 'setMessageSenderBlockList' ? {'@type': 'error', 'code': 400, 'message': 'USER_ID_INVALID'} : {'@type': 'ok'};
    await expectLater(tg.block('7', name: 'Jo Park'), throwsA(isA<StateError>()));
    expect(tg.isBlocked('7'), isFalse);
    tg.dispose();
  });

  test('Telegram: someone blocked or unblocked in Telegram\'s own app follows here, and its list is read in', () async {
    final (tg, td) = await readyTelegram();
    td.say({'@type': 'updateChatBlockList', 'chat_id': 7, 'block_list': {'@type': 'blockListMain'}});
    await settle();
    expect(tg.isBlocked('7'), isTrue);
    td.say({'@type': 'updateChatBlockList', 'chat_id': 7, 'block_list': null});
    await settle();
    expect(tg.isBlocked('7'), isFalse);

    td.answer = (r) => r['@type'] == 'getBlockedMessageSenders'
        ? {'@type': 'messageSenders', 'total_count': 1, 'senders': [{'@type': 'messageSenderUser', 'user_id': 7}]}
        : {'@type': 'ok'};
    await tg.refreshBlocked();
    expect(tg.blockedPeople, [(id: '7', name: 'Jo Park')]);
    // Unblocked in Telegram since: the whole list says so.
    td.answer = (r) => r['@type'] == 'getBlockedMessageSenders' ? {'@type': 'messageSenders', 'total_count': 0, 'senders': []} : {'@type': 'ok'};
    await tg.refreshBlocked();
    expect(tg.blockedPeople, isEmpty);
    tg.dispose();
  });

  test('Signal: blocked through the helper, which tells the phone; a group can\'t be; the phone\'s list is read in', () async {
    final dir = Directory.systemTemp.createTempSync('signal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper()..linked = true;
    var phoneList = <Map<String, Object?>>[];
    helper.answer = (r) => switch (r['op']) {
          'contacts' => [{'aci': 'aci-jo', 'name': 'Jo Park', 'number': '+15550100'}],
          'groups' => [{'id': 'grp1', 'title': 'Weekend crew', 'members': ['aci-jo']}],
          'blocked' => phoneList,
          _ => null,
        };
    final s = Signal(link: () async => helper, folder: dir.path)..listStore = AppState();
    await s.start(AppState());
    await settle();
    expect(s.state, InboxState.ready);
    expect(s.canBlock, isTrue);

    await s.block('aci-jo', name: 'Jo Park');
    expect(helper.asked.lastWhere((r) => r['op'] == 'block'), allOf(containsPair('aci', 'aci-jo'), containsPair('on', true)));
    expect(s.isBlocked('aci-jo'), isTrue);

    await s.block('aci-jo', name: 'Jo Park', on: false);
    expect(helper.asked.lastWhere((r) => r['op'] == 'block'), containsPair('on', false));
    expect(s.isBlocked('aci-jo'), isFalse);

    await expectLater(s.block('grp1', name: 'Weekend crew'), throwsA(isA<StateError>()));

    // Blocked on the phone: Signal's synced settings bring it to the helper, and here.
    phoneList = [{'aci': 'aci-sam', 'name': '', 'number': '+15550111'}];
    await s.refreshBlocked();
    expect(s.blockedPeople, [(id: 'aci-sam', name: '+15550111')]);
    s.dispose();
  });
}
