import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/export_chat.dart';
import 'package:ghost_messaging/snooze.dart';

/// Snoozing a conversation and exporting one (GMFB-36, from the Uplink gap review: snoozed messages were in Uplink's
/// backlog, #53, and exporting conversations in Warp's, #373).
void main() {
  group('snooze', () {
    late DateTime now;
    late List<String> told;
    setUp(() {
      now = DateTime(2026, 11, 22, 14, 0);
      told = [];
      Snoozed.now = () => now;
      Snoozed.woke = (key, title) => told.add('$key $title');
      Snoozed.instance.reset();
    });
    tearDown(() {
      Snoozed.instance.reset();
      Snoozed.now = DateTime.now;
      Snoozed.woke = (_, _) {};
    });

    test('out of Messages until its time, then back at the top with a notification, until it is opened', () {
      final app = AppState();
      Snoozed.instance.start(app);
      final key = Snoozed.text(42);
      Snoozed.instance.snooze(key, now.add(const Duration(hours: 1)), title: 'Maya');
      expect(Snoozed.instance.hides(key), isTrue);
      expect(Snoozed.instance.until(key), now.add(const Duration(hours: 1)));

      now = now.add(const Duration(minutes: 59));
      Snoozed.instance.wakeDue();
      expect(told, isEmpty);
      expect(Snoozed.instance.hides(key), isTrue);

      now = now.add(const Duration(minutes: 2));
      Snoozed.instance.wakeDue();
      expect(told, ['text:42 Maya']);
      expect(Snoozed.instance.hides(key), isFalse);
      expect(Snoozed.instance.woken(key), isTrue, reason: 'at the top until opened');
      Snoozed.instance.wakeDue();
      expect(told.length, 1, reason: 'told once');

      Snoozed.instance.opened(key);
      expect(Snoozed.instance.woken(key), isFalse);
    });

    test('kept with the app\'s choices: a snooze that came due while closed ends when the app opens', () {
      final app = AppState();
      Snoozed.instance.start(app);
      Snoozed.instance.snooze(Snoozed.text(7), now.add(const Duration(hours: 3)), title: 'Sam');
      Snoozed.instance.reset();
      now = now.add(const Duration(hours: 4));
      Snoozed.instance.start(app);
      expect(told, ['text:7 Sam']);
      expect(Snoozed.instance.woken(Snoozed.text(7)), isTrue);
    });

    test('unsnoozed: back at once, and nothing said', () {
      Snoozed.instance.start(AppState());
      Snoozed.instance.snooze(Snoozed.text(1), now.add(const Duration(days: 1)));
      Snoozed.instance.unsnooze(Snoozed.text(1));
      expect(Snoozed.instance.hides(Snoozed.text(1)), isFalse);
      expect(Snoozed.instance.woken(Snoozed.text(1)), isFalse);
    });

    test('a space\'s chat is snoozed under a key of its own, beside a conversation\'s (GMFB-36)', () {
      Snoozed.instance.start(AppState());
      final space = Snoozed.space('room-1');
      expect(space, 'space:room-1');
      Snoozed.instance.snooze(space, now.add(const Duration(hours: 1)), title: 'Weekend');
      expect(Snoozed.instance.hides(space), isTrue);
      expect(Snoozed.instance.hides(Snoozed.text(1)), isFalse);
      now = now.add(const Duration(hours: 2));
      Snoozed.instance.wakeDue();
      expect(told, ['space:room-1 Weekend']);
      expect(Snoozed.instance.woken(space), isTrue);
    });

    test('the times offered: an hour, three, this evening while it is before five, tomorrow at nine, Monday at nine', () {
      final sunday2pm = Snoozed.choices(DateTime(2026, 11, 22, 14, 0));
      expect(sunday2pm.map((c) => c.label), ['For an hour', 'For 3 hours', 'Until this evening (6 PM)', 'Until tomorrow (9 AM)', 'Until next week (Monday, 9 AM)']);
      expect(sunday2pm[2].at, DateTime(2026, 11, 22, 18));
      expect(sunday2pm[3].at, DateTime(2026, 11, 23, 9));
      expect(sunday2pm[4].at, DateTime(2026, 11, 23, 9), reason: 'Sunday: next Monday is tomorrow');
      final wednesdayEvening = Snoozed.choices(DateTime(2026, 11, 25, 19, 30));
      expect(wednesdayEvening.length, 4, reason: 'no "this evening" after five');
      expect(wednesdayEvening.last.at, DateTime(2026, 11, 30, 9));
    });

    group('one message (GMFB-36)', () {
      late List<String> toldMessages;
      setUp(() {
        toldMessages = [];
        Snoozed.wokeMessage = (chat, id, title, words) => toldMessages.add('$chat $id $title $words');
      });
      tearDown(() => Snoozed.wokeMessage = (_, _, _, _) {});

      test('back at its time with a notification, pinned in its conversation, which comes to the top of Messages', () {
        Snoozed.instance.start(AppState());
        final chat = Snoozed.text(42);
        Snoozed.instance.snoozeMessage(chat, 'sms:7', now.add(const Duration(hours: 1)), title: 'Maya', words: 'Dinner at 8?');
        expect(Snoozed.instance.messageUntil(chat, 'sms:7'), now.add(const Duration(hours: 1)));
        expect(Snoozed.instance.hides(chat), isFalse, reason: 'the conversation stays in Messages');
        expect(Snoozed.instance.remindersIn(chat), isEmpty);

        now = now.add(const Duration(minutes: 30));
        Snoozed.instance.wakeDue();
        expect(toldMessages, isEmpty);

        now = now.add(const Duration(minutes: 31));
        Snoozed.instance.wakeDue();
        expect(toldMessages, ['text:42 sms:7 Maya Dinner at 8?']);
        expect(told, isEmpty, reason: 'a message\'s, not a conversation\'s');
        expect(Snoozed.instance.messageUntil(chat, 'sms:7'), isNull);
        expect(Snoozed.instance.remindersIn(chat).map((r) => (r.id, r.words)), [('sms:7', 'Dinner at 8?')]);
        expect(Snoozed.instance.woken(chat), isTrue, reason: 'its conversation at the top of Messages');
        expect(Snoozed.instance.remindersIn(Snoozed.text(4)), isEmpty, reason: 'only in its own conversation');

        Snoozed.instance.opened(chat);
        expect(Snoozed.instance.remindersIn(chat).length, 1, reason: 'pinned until shown or put away, not only opened');
        Snoozed.instance.dismiss(chat, 'sms:7');
        expect(Snoozed.instance.remindersIn(chat), isEmpty);
      });

      test('kept on this device: one due while the app was closed is back as it opens; reminders stay', () {
        final app = AppState();
        Snoozed.instance.start(app);
        final chat = Snoozed.space('room-1');
        Snoozed.instance.snoozeMessage(chat, 'm1', now.add(const Duration(hours: 3)), title: 'Weekend', words: 'Tickets');
        Snoozed.instance.snoozeMessage(chat, 'm2', now.add(const Duration(days: 2)), title: 'Weekend', words: 'Later');
        Snoozed.instance.reset();
        now = now.add(const Duration(hours: 4));
        Snoozed.instance.start(app);
        expect(toldMessages, ['space:room-1 m1 Weekend Tickets']);
        expect(Snoozed.instance.messageUntil(chat, 'm2'), isNotNull);
        Snoozed.instance.reset();
        Snoozed.instance.start(app);
        expect(Snoozed.instance.remindersIn(chat).map((r) => r.id), ['m1'], reason: 'the reminder is kept too');
        expect(toldMessages.length, 1);
      });

      test('unsnoozed: nothing comes back', () {
        Snoozed.instance.start(AppState());
        final chat = Snoozed.text(3);
        Snoozed.instance.snoozeMessage(chat, 'a', now.add(const Duration(hours: 1)));
        Snoozed.instance.unsnoozeMessage(chat, 'a');
        now = now.add(const Duration(hours: 2));
        Snoozed.instance.wakeDue();
        expect(toldMessages, isEmpty);
        expect(Snoozed.instance.remindersIn(chat), isEmpty);
      });

      test('a notification pressed: its message is shown once as its conversation opens', () {
        expect(Snoozed.message(Snoozed.text(9), 'sms:1'), 'text:9#sms:1');
        expect(Snoozed.chatOf('text:9#sms:1'), 'text:9');
        expect(Snoozed.chatOf('space:r'), 'space:r');
        Snoozed.instance.showOnOpen(Snoozed.text(9), 'sms:1');
        expect(Snoozed.instance.takeShow(Snoozed.text(8)), isNull, reason: 'another conversation');
        expect(Snoozed.instance.takeShow(Snoozed.text(9)), 'sms:1');
        expect(Snoozed.instance.takeShow(Snoozed.text(9)), isNull, reason: 'once');
      });
    });
  });

  group('export', () {
    test('Markdown: a heading, a heading a day, each message with who and when, files and quotes, oldest first', () {
      final md = chatMarkdown('Maya Chen', [
        (at: DateTime(2026, 11, 22, 9, 5), who: 'You', text: 'Coffee?\nAt 10', files: const [], replyTo: null, edited: false),
        (at: DateTime(2026, 11, 21, 18, 0), who: 'Maya Chen', text: 'Here is the *plan*', files: const ['plan.pdf'], replyTo: null, edited: true),
        (at: DateTime(2026, 11, 22, 9, 6), who: 'Maya Chen', text: 'Yes!', files: const [], replyTo: 'Replying to You: Coffee?', edited: false),
      ], now: DateTime(2026, 11, 22, 20, 0));
      expect(md, startsWith('# Maya Chen\n\nExported from Uplink on 2026-11-22 at 20:00 · 3 messages\n'));
      expect(md.indexOf('## 2026-11-21'), lessThan(md.indexOf('## 2026-11-22')));
      expect(md, contains('**Maya Chen** 18:00 (edited)\nHere is the *plan*\n- 📎 plan.pdf'));
      expect(md, contains('**You** 09:05\nCoffee?  \nAt 10'));
      expect(md, contains('**Maya Chen** 09:06\n> Replying to You: Coffee?\nYes!'));
    });

    final three = <ExportLine>[
      (at: DateTime(2026, 11, 22, 9, 5), who: 'You', text: 'Coffee?', files: const ['IMG 1.jpg', 'IMG 1.jpg'], replyTo: null, edited: false),
      (at: DateTime(2026, 11, 21, 18, 0), who: 'Maya', text: 'The plan', files: const ['plan.pdf', 'gone.mov', 'huge.bin'], replyTo: 'Replying to You: ok', edited: true),
    ];

    test('JSON: what it is, then each message oldest first with who, when, words and files (GMFB-36)', () {
      final j = jsonDecode(chatJson('Maya', three, now: DateTime(2026, 11, 22, 20, 0), where: 'a space')) as Map;
      expect(j['app'], 'Uplink');
      expect(j['title'], 'Maya');
      expect(j['where'], 'a space');
      expect(j['exported'], '2026-11-22T20:00:00.000');
      final messages = j['messages'] as List;
      expect(messages.map((m) => (m as Map)['who']), ['Maya', 'You']);
      expect(messages.first, {'at': '2026-11-21T18:00:00.000', 'who': 'Maya', 'text': 'The plan', 'replyTo': 'Replying to You: ok', 'edited': true, 'files': [{'name': 'plan.pdf'}, {'name': 'gone.mov'}, {'name': 'huge.bin'}]});
      expect((messages.last as Map).containsKey('edited'), isFalse);
      expect((jsonDecode(chatJson('Maya', three.sublist(0, 1))) as Map).containsKey('where'), isFalse);
    });

    test('with its files: a zip of the export and a files folder, each file linked where it is named (GMFB-36)', () async {
      final dir = await Directory.systemTemp.createTemp('ghost-export-test');
      addTearDown(() => dir.delete(recursive: true));
      final onDisk = File('${dir.path}/plan.pdf')..writeAsBytesSync([1, 2, 3, 4]);
      final files = <ExportFile>[
        (line: 0, file: 0, name: 'IMG 1.jpg', size: 0, read: () async => Uint8List.fromList([9, 9])),
        (line: 0, file: 1, name: 'IMG 1.jpg', size: 0, read: () async => Uint8List.fromList([8])),
        (line: 1, file: 0, name: 'plan.pdf', size: 4, read: () async => onDisk.path),
        (line: 1, file: 1, name: 'gone.mov', size: 0, read: () async => null),
        (line: 1, file: 2, name: 'huge.bin', size: 5000, read: () async => fail('past the most: never read')),
      ];
      final zip = await writeExportZip('Maya 2026-11-22.zip', 'Maya 2026-11-22.md', files, (links) => chatMarkdown('Maya', three, links: links), most: 1000);
      addTearDown(() => File(zip.path).parent.delete(recursive: true));
      expect(zip.packed, 3);
      expect(zip.named, 2);
      expect(zip.path, endsWith('Maya 2026-11-22.zip'));
      final held = ZipDecoder().decodeBytes(File(zip.path).readAsBytesSync());
      expect(held.files.map((f) => f.name).toSet(), {'files/IMG 1.jpg', 'files/IMG 1 (2).jpg', 'files/plan.pdf', 'Maya 2026-11-22.md'});
      expect(held.findFile('files/plan.pdf')!.content, [1, 2, 3, 4]);
      expect(held.findFile('files/IMG 1 (2).jpg')!.content, [8]);
      final md = utf8.decode(held.findFile('Maya 2026-11-22.md')!.content);
      expect(md, contains('- 📎 [IMG 1.jpg](files/IMG%201.jpg)\n- 📎 [IMG 1.jpg](files/IMG%201%20(2).jpg)'));
      expect(md, contains('- 📎 [plan.pdf](files/plan.pdf)\n- 📎 gone.mov\n- 📎 huge.bin'));
      // The same as JSON: where each went is its path.
      final asJson = await writeExportZip('m.zip', 'm.json', files.sublist(2, 4), (links) => chatJson('Maya', three, links: links));
      addTearDown(() => File(asJson.path).parent.delete(recursive: true));
      final j = jsonDecode(utf8.decode(ZipDecoder().decodeBytes(File(asJson.path).readAsBytesSync()).findFile('m.json')!.content)) as Map;
      expect(((j['messages'] as List).first as Map)['files'], [{'name': 'plan.pdf', 'path': 'files/plan.pdf'}, {'name': 'gone.mov'}, {'name': 'huge.bin'}]);
      // Without links, the Markdown is as it ever was.
      expect(chatMarkdown('Maya', three), contains('- 📎 plan.pdf\n- 📎 gone.mov'));
    });

    test('a file name a file system takes, with the day', () {
      expect(exportName('Maya', now: DateTime(2026, 11, 22), ending: 'json'), 'Maya 2026-11-22.json');
      final taken = <String>{};
      expect([exportFileName('a/b.txt', taken), exportFileName('A b.txt', taken), exportFileName('', taken), exportFileName('..', taken)], ['a b.txt', 'A b (2).txt', 'file', 'file (2)']);
      expect(exportName('Maya: plans/ideas?', now: DateTime(2026, 11, 22)), 'Maya plans ideas 2026-11-22.md');
      expect(exportName('   ', now: DateTime(2026, 11, 22)), 'Conversation 2026-11-22.md');
    });
  });
}
