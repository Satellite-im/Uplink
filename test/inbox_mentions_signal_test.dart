import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/inbox/signal.dart';

/// Signal's @mentions (Matt, 2026-11-19: "when clicking on a @mention anywhere including signal and telegram chats show
/// this profile popup"): each U+FFFC the helper's words hold, named, with its place in the words now shown.
void main() {
  const a = '5c6c3c8e-3b0f-4b5a-9a0e-1f2a3b4c5d6e';
  const b = '8a1c2b3d-0000-4000-8000-000000000001';
  String? names(String aci) => const {a: 'Esther', b: '+15550100'}[aci];

  String at(({String text, List<InboxMention> mentions}) got, int i) => got.text.substring(got.mentions[i].start, got.mentions[i].start + got.mentions[i].length);

  test('each placeholder named, later places moved by what the names add', () {
    final got = signalMentions('hi ￼ and ￼!', [
      {'start': 9, 'length': 1, 'aci': b},
      {'start': 3, 'length': 1, 'aci': a},
    ], nameOf: names);
    expect(got.text, 'hi @Esther and @+15550100!');
    expect(got.mentions.map((m) => m.user), [a, b]);
    expect(at(got, 0), '@Esther');
    expect(at(got, 1), '@+15550100');
  });

  test('someone nothing names is @Someone', () {
    final got = signalMentions('￼ look', [
      {'start': 0, 'length': 1, 'aci': 'c0ffee00-0000-4000-8000-000000000000'},
    ], nameOf: names);
    expect(got.text, '@Someone look');
    expect(got.mentions.single, const InboxMention(start: 0, length: 8, user: 'c0ffee00-0000-4000-8000-000000000000'));
  });

  test('offsets are UTF-16: an emoji before a mention', () {
    final got = signalMentions('😀 ￼', [
      {'start': 3, 'length': 1, 'aci': a},
    ], nameOf: names);
    expect(got.text, '😀 @Esther');
    expect(at(got, 0), '@Esther');
  });

  test('an older helper (no mentions) leaves the words as they are', () {
    final got = signalMentions('hi ￼', null, nameOf: names);
    expect(got.text, 'hi ￼');
    expect(got.mentions, isEmpty);
  });

  test('a range over words, not a placeholder, is kept as it stands; a broken one is left out', () {
    final got = signalMentions('hi Esther', [
      {'start': 3, 'length': 6, 'aci': a},
      {'start': 8, 'length': 5, 'aci': b},
    ], nameOf: names);
    expect(got.text, 'hi Esther');
    expect(got.mentions.single, const InboxMention(start: 3, length: 6, user: a));
  });
}
