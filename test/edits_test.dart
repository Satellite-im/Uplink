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

/// Edited messages on Telegram and Signal: marked edited, and what they said before kept, the original first (Matt,
/// 2026-11-17: "Add support for edited messages on telegram and signal and the ability to see the original message").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => null);
  });

  Future<(Telegram, FakeTd)> telegram(String folder) async {
    final td = FakeTd();
    td.answer = (r) => switch (r['@type']) {
          'getMe' => {'@type': 'user', 'id': 1, 'first_name': 'Matt'},
          'loadChats' => {'@type': 'error', 'code': 404, 'message': 'Not Found'},
          _ => {'@type': 'ok'},
        };
    final tg = Telegram(apiId: 12345, apiHash: 'hash', folder: folder, transport: () async => td);
    await tg.start(AppState());
    await tg.begin();
    td.auth('authorizationStateReady');
    await settle();
    td.say({'@type': 'updateUser', 'user': {'id': 7, 'first_name': 'Jo'}});
    td.say({
      '@type': 'updateNewChat',
      'chat': {'id': 7, 'title': 'Jo', 'type': {'@type': 'chatTypePrivate', 'user_id': 7}, 'positions': [{'list': {'@type': 'chatListMain'}, 'order': '7'}]},
    });
    await settle();
    return (tg, td);
  }

  Map<String, Object?> text(int id, String words, {int edited = 0}) => {
        'id': id, 'chat_id': 7, 'is_outgoing': false, 'date': 1763200000, 'edit_date': edited,
        'sender_id': {'@type': 'messageSenderUser', 'user_id': 7}, 'content': {'@type': 'messageText', 'text': {'text': words}},
      };

  test('Telegram: an edit changes the words, keeps the original, and keeps it after a restart', () async {
    final dir = Directory.systemTemp.createTempSync('tg-edits');
    addTearDown(() => dir.deleteSync(recursive: true));
    var (tg, td) = await telegram(dir.path);
    td.say({'@type': 'updateNewMessage', 'message': text(50, 'see you at 7')});
    await settle();
    expect(tg.messagesOf('7').single.edited, isFalse);

    td.say({'@type': 'updateMessageContent', 'chat_id': 7, 'message_id': 50, 'new_content': {'@type': 'messageText', 'text': {'text': 'see you at 8'}}});
    td.say({'@type': 'updateMessageEdited', 'chat_id': 7, 'message_id': 50, 'edit_date': 1763200300});
    await settle();
    var m = tg.messagesOf('7').single;
    expect(m.text, 'see you at 8');
    expect(m.edited, isTrue);
    expect(m.original, 'see you at 7');

    td.say({'@type': 'updateMessageContent', 'chat_id': 7, 'message_id': 50, 'new_content': {'@type': 'messageText', 'text': {'text': 'see you at 9'}}});
    await settle();
    m = tg.messagesOf('7').single;
    expect(m.versions, ['see you at 7', 'see you at 8'], reason: 'each wording on the way, the original first');

    // A message edited before this device saw it: marked edited, nothing earlier to show.
    td.say({'@type': 'updateNewMessage', 'message': text(51, 'fixed typo', edited: 1763200100)});
    await settle();
    final early = tg.messagesOf('7').firstWhere((x) => x.id == '51');
    expect(early.edited, isTrue);
    expect(early.original, isNull);
    tg.dispose();

    // Again, as after the app was closed: Telegram gives the message as it now is, and the original is still here.
    (tg, td) = await telegram(dir.path);
    td.say({'@type': 'updateNewMessage', 'message': text(50, 'see you at 9', edited: 1763200300)});
    await settle();
    expect(tg.messagesOf('7').single.versions, ['see you at 7', 'see you at 8']);
    tg.dispose();
  });

  test('Signal: the helper\'s edit changes the words and keeps the original, across a restart', () async {
    final dir = Directory.systemTemp.createTempSync('signal-edits');
    addTearDown(() => dir.deleteSync(recursive: true));
    final helper = FakeHelper()..linked = true;
    var s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await settle();
    expect(s.state, InboxState.ready);
    helper.event({'ev': 'message', 'chat': 'aci-jo', 'group': false, 'from': 'aci-jo', 'name': 'Jo', 'mine': false, 'ts': 1763200500000, 'text': 'running late', 'media': []});
    await settle();
    helper.event({'ev': 'edited', 'chat': 'aci-jo', 'from': 'aci-jo', 'target_ts': 1763200500000, 'ts': 1763200600000, 'text': 'running 10 min late'});
    await settle();
    var m = s.messagesOf('aci-jo').single;
    expect(m.text, 'running 10 min late');
    expect(m.edited, isTrue);
    expect(m.original, 'running late');
    s.dispose();

    s = Signal(link: () async => helper, folder: dir.path);
    await s.start(AppState());
    await settle();
    m = s.messagesOf('aci-jo').single;
    expect((m.text, m.edited, m.original), ('running 10 min late', true, 'running late'));
    s.dispose();
  });
}
