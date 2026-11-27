import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/telegram.dart';

/// Telegram's @mentions (Matt, 2026-11-19: "when clicking on a @mention anywhere including signal and telegram chats
/// show this profile popup"): TDLib's entities, as places in the words the app shows.
Map<String, Object?> textMessage(String text, List<Map<String, Object?>> entities) => {
      '@type': 'message',
      'content': {
        '@type': 'messageText',
        'text': {'@type': 'formattedText', 'text': text, 'entities': entities},
      },
    };

Map<String, Object?> entity(int offset, int length, Map<String, Object?> type) => {'@type': 'textEntity', 'offset': offset, 'length': length, 'type': type};

void main() {
  test('a typed @username and a person named without one', () {
    const text = 'hi @esther and Bo!';
    final m = textMessage(text, [
      entity(3, 7, {'@type': 'textEntityTypeMention'}),
      entity(0, 2, {'@type': 'textEntityTypeBold'}),
      entity(15, 2, {'@type': 'textEntityTypeMentionName', 'user_id': 42}),
    ]);
    final got = telegramMentions(m);
    expect(got, const [InboxMention(start: 3, length: 7, username: 'esther'), InboxMention(start: 15, length: 2, user: '42')]);
    expect(text.substring(got[0].start, got[0].start + got[0].length), '@esther');
    expect(text.substring(got[1].start, got[1].start + got[1].length), 'Bo');
  });

  test('offsets are UTF-16, as Dart counts them', () {
    const text = '😀 @zed';
    final got = telegramMentions(textMessage(text, [entity(3, 4, {'@type': 'textEntityTypeMention'})]));
    expect(got.single.start, 3);
    expect(text.substring(3, 7), '@zed');
  });

  test('a caption shown trimmed, or after a word of the app\'s own, moves the places to match', () {
    final m = {
      'content': {
        '@type': 'messageAudio',
        'caption': {'text': '  for @amy', 'entities': [entity(6, 4, {'@type': 'textEntityTypeMention'})]},
      },
    };
    final trimmed = telegramMentions(m, shown: 'for @amy').single;
    expect('for @amy'.substring(trimmed.start, trimmed.start + trimmed.length), '@amy');
    const shown = 'Audio: for @amy';
    final after = telegramMentions(m, shown: shown).single;
    expect(shown.substring(after.start, after.start + after.length), '@amy');
    expect(after.username, 'amy');
  });

  test('nothing where there are no entities, the words shown are others, or a range runs past the end', () {
    expect(telegramMentions(textMessage('plain', const [])), isEmpty);
    expect(telegramMentions({'content': {'@type': 'messageText', 'text': {'text': 'x'}}}), isEmpty);
    expect(telegramMentions(textMessage('hi @a', [entity(3, 2, {'@type': 'textEntityTypeMention'})]), shown: 'Esther joined the group'), isEmpty);
    expect(telegramMentions(textMessage('hi @a', [entity(3, 9, {'@type': 'textEntityTypeMention'})])), isEmpty);
  });
}
