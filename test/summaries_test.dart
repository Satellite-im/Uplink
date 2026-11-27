import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/summaries.dart';

/// Summaries of unread conversations by the phone's own model (lib/summaries.dart; Matt, 2026-11-14: "Use a local AI
/// to summarize unread message conversations like apple does").
Message _m(int id, String body, {bool out = false, String from = '+15551230001'}) =>
    Message.from({'id': id, 'kind': 'sms', 'address': out ? '' : from, 'body': body, 'date': 1000 + id, 'outgoing': out});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const maya = Person(address: '+15551230001', name: 'Maya Chen');

  group('what the model is given', () {
    test('the unread run, oldest first, a line a text with who wrote it', () {
      // Newest first, as the phone gives them: three from Maya since the person last wrote.
      final recent = [_m(5, 'bring the cable'), _m(4, 'and snacks'), _m(3, 'movie at 7?'), _m(2, 'sure!', out: true), _m(1, 'hey')];
      expect(Summaries.conversationFor(recent, const [maya]), 'Maya Chen: movie at 7?\nMaya Chen: and snacks\nMaya Chen: bring the cable');
    });

    test('one short text is left as it is; one long one is summed up', () {
      expect(Summaries.conversationFor([_m(2, 'ok see you'), _m(1, 'hi', out: true)], const [maya]), isNull);
      final long = 'So here is the plan for Saturday. ' * 8;
      expect(Summaries.conversationFor([_m(2, long)], const [maya]), startsWith('Maya Chen: So here is the plan'));
      expect(Summaries.conversationFor([_m(1, 'yes', out: true)], const [maya]), isNull, reason: 'nothing unread from them');
    });

    test('in a group, each line names its writer; someone not known is "Them"', () {
      const sam = Person(address: '+15551230003', name: 'Sam');
      final recent = [_m(3, 'in', from: '+15551230003'), _m(2, 'who is in for pizza?')];
      expect(Summaries.conversationFor(recent, const [maya, sam]), 'Maya Chen: who is in for pizza?\nSam: in');
      expect(Summaries.conversationFor([_m(2, 'b'), _m(1, 'a')], const [Person(address: '+15550000000')]), 'Them: a\nThem: b');
    });
  });

  group('in the app', () {
    late List<String> asked;
    var newer = false;
    setUp(() {
      asked = [];
      newer = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
        asked.add(call.method);
        switch (call.method) {
          case 'summaryStatus':
            return 'available';
          case 'messages':
            return [
              if (newer) {'id': 4, 'kind': 'sms', 'address': '+15551230001', 'body': 'and popcorn', 'date': 4000, 'outgoing': false},
              {'id': 3, 'kind': 'sms', 'address': '+15551230001', 'body': 'bring the cable', 'date': 3000, 'outgoing': false},
              {'id': 2, 'kind': 'sms', 'address': '+15551230001', 'body': 'movie at 7?', 'date': 2000, 'outgoing': false},
            ];
          case 'summarize':
            return 'Maya asks about a movie at 7 and the cable.';
        }
        return null;
      });
    });

    test('an unread conversation is summed up once for its newest text, kept, and made again for a new one', () async {
      final app = AppState();
      await Summaries.instance.start(app);
      expect(Summaries.instance.status, 'available');
      final c = Conversation.from({'id': 7, 'date': 3000, 'people': [{'address': '+15551230001', 'name': 'Maya Chen'}], 'snippet': 'bring the cable', 'unread': true});
      expect(Summaries.instance.of(c), isNull);
      Summaries.instance.want(c);
      await pumpEventQueue();
      expect(Summaries.instance.of(c), 'Maya asks about a movie at 7 and the cable.');
      expect(asked.where((m) => m == 'summarize'), hasLength(1));
      // Asked again for the same newest text: nothing new is made.
      Summaries.instance.want(c);
      await pumpEventQueue();
      expect(asked.where((m) => m == 'summarize'), hasLength(1));
      expect(app.choice('summary_7', ''), startsWith('3000\t'), reason: 'kept across the app being closed');
      // Read: the words come back.
      expect(Summaries.instance.of(Conversation.from({'id': 7, 'date': 3000, 'people': [{'address': '+15551230001', 'name': 'Maya Chen'}], 'snippet': 'x', 'unread': false})), isNull);
      // A newer text: a new summary (the same words again are answered from what the model said, lib/local_ai.dart).
      newer = true;
      final next = Conversation.from({'id': 7, 'date': 4000, 'people': [{'address': '+15551230001', 'name': 'Maya Chen'}], 'snippet': 'x', 'unread': true});
      expect(Summaries.instance.of(next), isNull);
      Summaries.instance.want(next);
      await pumpEventQueue();
      expect(asked.where((m) => m == 'summarize'), hasLength(2));
      // Turned off: none shown.
      app.setFlag('summaries', false);
      expect(Summaries.instance.of(next), isNull);
    });
  });
}
