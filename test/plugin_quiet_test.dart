import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/kinds.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/quiet.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/strangers.dart';


/// Quiet hours and Unknown numbers (Matt, 2026-11-14: "let's add all of the additional ones to a plugins,
/// some can be grouped into the same plugin").
void main() {
  test('Quiet hours: the hidden kinds are muted as they come, while chosen', () {
    final registry = PluginRegistry(const [KindsPlugin(), QuietPlugin()]);
    final store = MemoryStore();
    MessageFacts f(String text) => MessageFacts(thread: 1, senders: const ['+15559870000'], text: text, contact: false);
    List<IncomingAction> asked(MessageFacts facts) => [for (final b in registry.incoming(facts, registry.classify(facts, store), store)) b.action];
    expect(asked(f('Election day is Tuesday. Paid for by Friends of Pat')).whereType<MuteNotification>(), hasLength(1));
    expect(asked(f('Your package is out for delivery')), isEmpty, reason: 'a kind that is shown is not muted');
    store.write('plugin_quiet_kinds', 'off');
    expect(asked(f('Election day is Tuesday. Paid for by Friends of Pat')), isEmpty);
  });

  test('Unknown numbers: a guess from the number and the words', () {
    expect(strangerGuess('+15559870000', 'Congratulations! You\'ve won a gift card. Claim now: http://prize.example/win'), 'spam');
    expect(strangerGuess('28777', 'USPS: your package is out for delivery'), 'business');
    expect(strangerGuess('+15559870000', 'Thanks for choosing us. Reply STOP to opt out'), 'business');
    expect(strangerGuess('+15559870000', 'hey it\'s Sam from the gym, got your number from Jess'), 'person');
    for (final p in [QuietPlugin, StrangersPlugin]) {
      expect(shippedPlugins.where((s) => s.runtimeType == p), hasLength(1), reason: '$p ships');
    }
    // Your day was unshipped (Matt, 2026-11-14: "remove the plugin that gives you the digest for now"), then deleted
    // (2026-11-16: "Remove the your day plugin as well").
    expect(shippedPlugins.map((p) => p.id), isNot(contains('day')));
  });
}
