import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/replies.dart';

/// Replies (lib/plugins/replies.dart; Matt, 2026-11-14: "Smart replies", "Follow-up nudges").
void main() {
  final now = DateTime(2026, 11, 14, 10);

  test('what asks something of the reader', () {
    expect(asksSomething('Are you free Saturday?'), isTrue);
    expect(asksSomething('let me know when you land'), isTrue);
    expect(asksSomething('can you grab milk'), isTrue);
    expect(asksSomething('Sounds good, see you'), isFalse);
    expect(asksSomething('haha'), isFalse);
  });

  test('replies that fit the text', () {
    expect(repliesFor('Thanks so much!').first, 'You\'re welcome!');
    expect(repliesFor('Are you coming tonight?'), contains('Yes'));
    expect(repliesFor('Dinner Friday at 7?'), contains('Sounds good!'));
    expect(repliesFor('where are you'), contains('On my way'));
    expect(repliesFor('what time works for you?'), contains('Let me check'));
    expect(repliesFor('ok cool'), hasLength(3));
  });

  test('a promise of yours, and when to be reminded of it', () {
    final p = promiseIn('I\'ll send you the photos tonight at 8', now)!;
    expect(p.at, DateTime(2026, 11, 14, 19, 45), reason: 'a quarter of an hour before the time it said');
    expect(p.label, 'Today 8 PM');
    expect(promiseIn('will call you later', now)!.label, 'Later');
    expect(promiseIn('See you tonight at 8', now), isNull, reason: 'a plan, not a promise to do something');
    expect(promiseIn('I sent it', now), isNull);
  });

  test('No Needs a reply tab (Matt, 2026-11-16: "Remove the "needs a reply" section and functionality")', () {
    final registry = PluginRegistry(const [RepliesPlugin()]);
    final store = MemoryStore({'plugin_replies_tab': 'on'});
    final facts = MessageFacts(thread: 1, senders: const ['+15551230001'], text: 'Are you free Saturday?', contact: true, unread: true);
    expect(registry.sectionOf(facts, registry.classify(facts, store), store), isNull);
    expect(registry.sections(store), isEmpty);
    expect(remindTimes(now).map((t) => t.label), ['In an hour', 'This evening', 'Tomorrow morning']);
    expect(shippedPlugins.whereType<RepliesPlugin>(), hasLength(1));
  });
}
