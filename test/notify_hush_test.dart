import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/plugins/notify_hush.dart';
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/registry.dart';

/// The rules the phone's side reads to keep a hidden kind's texts from notifying (lib/plugins/notify_hush.dart; GMFB-18,
/// Matt, Android 0.12.3: "If we dont have a specific kind of message enabled like political messages we shouldn't get
/// notified via sms for those messages").
///
/// test/notify_hush_vectors.json holds the rules written out for a few sets of choices, and texts with what the list
/// does with each (hidden or not); android/.../NotifyHushTest.kt reads the same file for NotifyHush.hushes. Run with
/// UPDATE_HUSH_VECTORS=1 to write it again after a kind's or a spam sign's patterns change.

const _vectors = 'test/notify_hush_vectors.json';

/// The sets of choices the file holds.
const _scenarios = <String, Map<String, String>>{
  'as the app ships': {},
  'political shown, sales off, strict, words of their own, filed by hand': {
    'filter_political': 'on',
    'plugin_kinds_kind_sales': 'off',
    'plugin_kinds_level': 'strict',
    'plugin_kinds_words_debt': 'acme recovery, balance owed',
    'plugin_spam_always_words': 'crypto club',
    'filter_deliveries': 'off',
    'plugins_filed': '41:,42:spam,43:political,44:debt',
  },
  'kinds off, spam strictest': {
    'plugin_kinds': 'off',
    'plugin_spam_level': 'strictest',
  },
};

/// The texts each set of choices is asked about.
const _texts = <Map<String, Object>>[
  {'text': 'Chip in \$5 to keep us in this race! Paid for by Friends of Pat Rivera'},
  {'text': 'Election day is Tuesday. Make a plan to vote.'},
  {'text': 'The vote on the campaign is this week', 'note': 'two lesser signs'},
  {'text': 'Who is the best candidate for the job?', 'note': 'one lesser sign'},
  {'text': 'This is an attempt to collect a debt. Call 800-555-0100.'},
  {'text': 'Hi, this is Acme Recovery about your account'},
  {'text': 'Hi neighbor! Our crew is in your neighborhood this week doing tree trimming.'},
  {'text': 'Long time no see! I sent you the pictures from the trip'},
  {'text': 'Your package is out for delivery. Tracking number 1Z999AA10123456784'},
  {'text': 'USPS: your package is on hold, pay the redelivery fee at usps-redeliver.top now', 'note': 'a fake delivery'},
  {'text': 'Congratulations! You have won a \$500 gift card, claim now at prizes.xyz'},
  {'text': 'URGENT: your account is suspended, verify your account at bit.ly/x1'},
  {'text': 'Join our crypto club today'},
  {'text': 'Your Chase verification code is 482913. If this wasn\'t you, act immediately: chase.com', 'note': 'a code'},
  {'text': 'Hey, are we still on for dinner tonight?'},
  {'text': 'See you at 7'},
  {'text': 'Paid for by Friends of Pat Rivera', 'contact': true},
  {'text': 'Paid for by Friends of Pat Rivera', 'group': true},
  {'text': 'Hello friend', 'senders': ['+447700900123', 'promo@example.com'], 'note': 'two sender signs'},
  {'text': 'Paid for by Friends of Pat Rivera', 'thread': 41},
  {'text': 'See you at 7', 'thread': 42},
  {'text': 'See you at 7', 'thread': 43},
  {'text': 'Your package is out for delivery', 'thread': 44},
];

/// What the list does with [c] under [store]: whether it lands in a kind the filter hides.
bool _hiddenByList(PluginRegistry registry, PluginStore store, Map<String, Object> c) {
  final group = c['group'] == true;
  final facts = MessageFacts(
    thread: (c['thread'] as int?) ?? 7,
    senders: (c['senders'] as List<String>?) ?? (group ? const ['+15559870001', '+15559870002'] : const ['+15559870001']),
    text: c['text']! as String,
    contact: c['contact'] == true,
    group: group,
    outgoing: false,
  );
  final s = registry.sectionOf(facts, registry.classify(facts, store), store);
  return s != null && s.section.filter && !NotifyHush.shown(s, store);
}

Map<String, Object?> _build() {
  final out = <Map<String, Object?>>[];
  for (final e in _scenarios.entries) {
    final registry = PluginRegistry(shippedPlugins);
    final store = MemoryStore(e.value);
    out.add({
      'name': e.key,
      'rules': jsonEncode(NotifyHush.export(registry, store)),
      'cases': [
        for (final c in _texts)
          {
            'text': c['text'],
            'senders': (c['senders'] as List<String>?) ?? (c['group'] == true ? const ['+15559870001', '+15559870002'] : const ['+15559870001']),
            'group': c['group'] == true,
            'stranger': c['contact'] != true,
            'thread': (c['thread'] as int?) ?? 7,
            'hush': _hiddenByList(registry, store, c),
          },
      ],
    });
  }
  return {'scenarios': out};
}

void main() {
  test('the rules written out: the kinds that are on, which are hidden, Spam, and the filings', () {
    final registry = PluginRegistry(shippedPlugins);
    final ships = NotifyHush.export(registry, MemoryStore());
    final kinds = ships['kinds']! as Map<String, Object?>;
    final list = (kinds['list']! as List).cast<Map<String, Object?>>();
    expect({for (final k in list) if (k['hide'] == true) k['id']}, {'debt', 'political', 'sales', 'scams'});
    expect(list.map((k) => k['id']).first, 'debt', reason: 'in the order a text is asked about them');
    expect(kinds['weakNeeded'], 2);
    expect((ships['spam']! as Map)['hide'], isTrue);
    expect(ships['filed'], isEmpty);

    final chosen = NotifyHush.export(registry, MemoryStore(_scenarios.values.elementAt(1)));
    final chosenKinds = chosen['kinds']! as Map<String, Object?>;
    final chosenList = (chosenKinds['list']! as List).cast<Map<String, Object?>>();
    expect(chosenList.any((k) => k['id'] == 'sales'), isFalse, reason: 'a kind switched off sorts nothing');
    expect(chosenList.firstWhere((k) => k['id'] == 'political')['hide'], isFalse);
    expect(chosenList.firstWhere((k) => k['id'] == 'deliveries')['hide'], isTrue);
    expect(chosenList.firstWhere((k) => k['id'] == 'debt')['words'], [RegExp.escape('acme recovery'), RegExp.escape('balance owed')]);
    expect(chosenKinds['weakNeeded'], 1);
    // "Not political" (the main list) lets it through; Spam and debt are hidden; political is shown here.
    expect(chosen['filed'], {'41': false, '42': true, '43': false, '44': true});

    final off = NotifyHush.export(registry, MemoryStore(_scenarios.values.elementAt(2)));
    expect(off['kinds'], isNull);
    expect((off['spam']! as Map)['base'], 1);
  });

  test('the file the phone\'s side is held to says what the list does', () {
    final built = _build();
    final file = File(_vectors);
    if (Platform.environment['UPDATE_HUSH_VECTORS'] == '1' || !file.existsSync()) {
      file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(built)}\n');
    }
    final kept = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    expect(kept, jsonDecode(jsonEncode(built)), reason: 'run with UPDATE_HUSH_VECTORS=1 to write $_vectors again');
    // Each set of choices hides some texts and lets others through, so the file can catch the two sides disagreeing.
    for (final s in built['scenarios']! as List) {
      final hush = [for (final c in (s as Map)['cases'] as List) (c as Map)['hush']];
      expect(hush, containsAll([true, false]), reason: s['name'] as String);
    }
  });
}
