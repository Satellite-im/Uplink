import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/emoji_data.dart';
import 'package:ghost_messaging/ui/emoji_picker.dart';

import 'support/space_call_harness.dart';

/// The app's own emoji picker (Matt, 2026-11-19: "roll an in house emoji picker we should be able to pull the code out
/// from other apps we've built"): Ghost Keyboard's emoji data and search, ported.
final _data = EmojiData.parse(File('assets/emoji/emoji.tsv').readAsStringSync());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('every group has emoji, none newer than a font has, and the hand has five tones', () {
    expect(_data.all.length, greaterThan(1700));
    for (final (group, _, name) in EmojiData.groups) {
      expect(_data.inGroup(group), isNotEmpty, reason: name);
    }
    expect(_data.all.every((e) => e.version <= EmojiData.newest), isTrue);
    final wave = _data.all.firstWhere((e) => e.emoji == '👋');
    expect(wave.toned(3), '👋🏽');
    expect(wave.toned(0), '👋');
    expect(_data.all.firstWhere((e) => e.emoji == '😀').toned(3), '😀', reason: 'a face has no tones');
  });

  test('search: a shortcode or name first, then names and keywords that start with it; every word must match', () {
    expect(_data.search('pizza').first.emoji, '🍕');
    expect(_data.search(':thumbsup:').first.emoji, '👍');
    expect(_data.search('heart').take(3).map((e) => e.emoji), contains('❤️'));
    expect(_data.search('red heart').first.emoji, '❤️');
    expect(_data.search('zzzqqq'), isEmpty);
    expect(_data.search('  '), isEmpty);
  });

  test('an emoji goes in where the cursor is, in place of what is selected', () {
    final c = TextEditingController(text: 'hi there');
    c.selection = const TextSelection.collapsed(offset: 2);
    insertEmoji(c, '👋');
    expect((c.text, c.selection.baseOffset), ('hi👋 there', 4));
    c.selection = const TextSelection(baseOffset: 5, extentOffset: 10);
    insertEmoji(c, '🎉');
    expect(c.text, 'hi👋 🎉');
    final empty = TextEditingController();
    insertEmoji(empty, '🔥');
    expect(empty.text, '🔥');
  });

  test('picked emoji are kept as recent, newest first, once each; the tone is kept', () {
    final choices = EmojiChoices(AppState());
    choices
      ..used('👍')
      ..used('🔥')
      ..used('👍');
    expect(choices.recent, ['👍', '🔥']);
    choices.tone = 4;
    expect(choices.tone, 4);
  });

  testWidgets('the sheet: search, tone, tabs and the grid; a press picks and keeps it open', (tester) async {
    final h = await SpaceHarness.load(tester);
    final picked = <String>[];
    await h.shoot(tester, Stack(children: [const SizedBox.expand(), EmojiSheet(onPick: picked.add, data: _data)]), 'emoji-picker');
    expect(find.byKey(const ValueKey('emoji-search')), findsOneWidget);
    expect(find.text('SMILEYS'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('emoji-😀')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(picked, ['😀']);
    expect(find.byKey(const ValueKey('emoji-sheet')), findsOneWidget, reason: 'still up, for another');
    expect(find.text('RECENT'), findsOneWidget, reason: 'what was picked comes first');
    await tester.enterText(find.byKey(const ValueKey('emoji-search')), 'pizza');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('emoji-🍕')), findsOneWidget);
    expect(find.text('SMILEYS'), findsNothing);
  });
}
