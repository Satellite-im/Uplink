import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/keys.dart';
import 'package:ghost_messaging/ui/markdown_field.dart';

/// The keyboard's commands (lib/keys.dart; Matt, 2026-11-20: "add push to talk and full keyboard commands with a
/// keyboard shortcuts setting in settings").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  // What the frame is handed as a key comes down, with what is held held (simulated).
  Future<KeyCommand?> press(WidgetTester tester, Keys keys, LogicalKeyboardKey key, {List<LogicalKeyboardKey> held = const [], bool typing = false}) async {
    KeyCommand? got;
    bool handler(KeyEvent e) {
      if (e is KeyDownEvent && e.logicalKey == key) got = keys.commandFor(e, typing: typing);
      return false;
    }

    HardwareKeyboard.instance.addHandler(handler);
    for (final h in held) {
      await tester.sendKeyDownEvent(h);
    }
    await tester.sendKeyEvent(key);
    for (final h in held.reversed) {
      await tester.sendKeyUpEvent(h);
    }
    HardwareKeyboard.instance.removeHandler(handler);
    return got;
  }

  final primary = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;

  testWidgets('every command has its own keys, and the keys pressed find it: Shift and the rest must match', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final keys = Keys.forTest()..start(AppState());
    final used = {for (final c in KeyCommand.values) Keys.defaults[c]};
    expect(used.length, KeyCommand.values.length, reason: 'no two on the same keys');
    expect(await press(tester, keys, LogicalKeyboardKey.keyN, held: [primary]), KeyCommand.newChat);
    expect(await press(tester, keys, LogicalKeyboardKey.keyM, held: [primary, LogicalKeyboardKey.shiftLeft]), KeyCommand.toggleMute);
    expect(await press(tester, keys, LogicalKeyboardKey.keyM, held: [primary]), isNull, reason: 'without Shift it is not Mute');
    expect(await press(tester, keys, LogicalKeyboardKey.backquote), KeyCommand.pushToTalk);
  });

  testWidgets('a command on a key alone waits while typing; one with Cmd or Ctrl does not', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final keys = Keys.forTest()..start(AppState());
    expect(await press(tester, keys, LogicalKeyboardKey.backquote, typing: true), isNull);
    expect(await press(tester, keys, LogicalKeyboardKey.keyK, held: [primary], typing: true), KeyCommand.quickSwitch);
  });

  testWidgets('keys changed are kept; keys taken from another leave it on none; each can be put back', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final app = AppState();
    final keys = Keys.forTest()..start(app);
    const f2 = KeyBinding(LogicalKeyboardKey.f2);
    keys.set(KeyCommand.pushToTalk, f2);
    expect(keys.of(KeyCommand.pushToTalk), f2);
    expect(keys.changed(KeyCommand.pushToTalk), isTrue);
    // Kept with the app's choices: a new start reads them back.
    final again = Keys.forTest()..start(app);
    expect(again.of(KeyCommand.pushToTalk), f2);
    expect(await press(tester, again, LogicalKeyboardKey.f2), KeyCommand.pushToTalk);
    // New chat's keys given to Search: New chat is on none.
    again.set(KeyCommand.search, Keys.defaults[KeyCommand.newChat]);
    expect(again.of(KeyCommand.newChat), isNull);
    expect(await press(tester, again, LogicalKeyboardKey.keyN, held: [primary]), KeyCommand.search);
    again.reset(KeyCommand.newChat);
    expect(again.of(KeyCommand.newChat), Keys.defaults[KeyCommand.newChat]);
    expect(again.of(KeyCommand.search), isNull, reason: 'putting New chat back takes its keys back');
    again.resetAll();
    expect(KeyCommand.values.where(again.changed), isEmpty);
    expect(again.pushToTalk, isFalse, reason: 'push to talk is off unless switched on');
    again.setPushToTalk(true);
    expect((Keys.forTest()..start(app)).pushToTalk, isTrue);
  });

  test('keys are written as each computer writes them', () {
    const b = KeyBinding(LogicalKeyboardKey.keyM, primary: true, shift: true);
    expect(b.label, Platform.isMacOS ? 'Cmd+Shift+M' : 'Ctrl+Shift+M');
    expect(const KeyBinding(LogicalKeyboardKey.backquote).label, '`');
    expect(KeyBinding.fromJson(b.toJson()), b);
  });

  // GMFB-41 (from the Uplink gap review: "Customization: ... keybinds").
  group('conversations and writing', () {
    testWidgets('the new commands are on their own keys and found by them, the Writing ones while typing', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final keys = Keys.forTest()..start(AppState());
      expect(await press(tester, keys, LogicalKeyboardKey.keyK, held: [primary]), KeyCommand.quickSwitch);
      expect(await press(tester, keys, LogicalKeyboardKey.keyF, held: [primary], typing: true), KeyCommand.search, reason: 'Search moved to Cmd+F for the switcher');
      expect(await press(tester, keys, LogicalKeyboardKey.arrowDown, held: [LogicalKeyboardKey.altLeft], typing: true), KeyCommand.nextChat);
      expect(await press(tester, keys, LogicalKeyboardKey.arrowUp, held: [LogicalKeyboardKey.altLeft]), KeyCommand.previousChat);
      expect(await press(tester, keys, LogicalKeyboardKey.arrowDown), isNull, reason: 'the arrow alone is the list\'s and the field\'s');
      expect(await press(tester, keys, LogicalKeyboardKey.keyR, held: [primary, LogicalKeyboardKey.shiftLeft]), KeyCommand.markRead);
      expect(await press(tester, keys, LogicalKeyboardKey.backslash, held: [primary]), KeyCommand.toggleSidebar);
      expect(await press(tester, keys, LogicalKeyboardKey.keyB, held: [primary], typing: true), KeyCommand.bold);
      expect(await press(tester, keys, LogicalKeyboardKey.keyI, held: [primary], typing: true), KeyCommand.italic);
      expect(await press(tester, keys, LogicalKeyboardKey.keyE, held: [primary], typing: true), KeyCommand.code);
      expect(await press(tester, keys, LogicalKeyboardKey.keyE, held: [primary, LogicalKeyboardKey.shiftLeft]), KeyCommand.leaveCall, reason: 'Shift makes it another command');
      // GMFB-35: strikethrough, spoiler and quote, each on keys of its own and nobody else's.
      expect(await press(tester, keys, LogicalKeyboardKey.keyX, held: [primary, LogicalKeyboardKey.shiftLeft], typing: true), KeyCommand.strike);
      expect(await press(tester, keys, LogicalKeyboardKey.keyP, held: [primary, LogicalKeyboardKey.shiftLeft], typing: true), KeyCommand.spoiler);
      expect(await press(tester, keys, LogicalKeyboardKey.keyB, held: [primary, LogicalKeyboardKey.shiftLeft], typing: true), KeyCommand.quote);
      expect(Keys.defaults.values.toSet().length, Keys.defaults.length, reason: 'no two commands start on the same keys');
      expect(Keys.defaults.keys.toSet(), KeyCommand.values.toSet());
      for (final c in Keys.markers.keys) {
        expect(c.group, 'Writing');
      }
    });

    testWidgets('a command moved onto another\'s keys is a clash: found, and the other left on none; copy and paste are never taken', (tester) async {
      await tester.pumpWidget(const SizedBox());
      final keys = Keys.forTest()..start(AppState());
      final boldKeys = Keys.defaults[KeyCommand.bold]!;
      expect(keys.usedBy(boldKeys, except: KeyCommand.quickSwitch), KeyCommand.bold);
      expect(keys.usedBy(boldKeys, except: KeyCommand.bold), isNull, reason: 'its own keys are no clash');
      keys.set(KeyCommand.quickSwitch, boldKeys);
      expect(keys.of(KeyCommand.bold), isNull);
      expect(await press(tester, keys, LogicalKeyboardKey.keyB, held: [primary], typing: true), KeyCommand.quickSwitch);
      // Rebinding to keys nobody has: no clash at all.
      const f6 = KeyBinding(LogicalKeyboardKey.f6);
      expect(keys.usedBy(f6, except: KeyCommand.nextChat), isNull);
      keys.set(KeyCommand.nextChat, f6);
      expect(await press(tester, keys, LogicalKeyboardKey.f6), KeyCommand.nextChat);
      // Every field's own keys.
      expect(Keys.reservedFor(const KeyBinding(LogicalKeyboardKey.keyC, primary: true)), 'Copy');
      expect(Keys.reservedFor(const KeyBinding(LogicalKeyboardKey.keyV, primary: true)), 'Paste');
      expect(Keys.reservedFor(const KeyBinding(LogicalKeyboardKey.keyZ, primary: true, shift: true)), 'Redo');
      expect(Keys.reservedFor(const KeyBinding(LogicalKeyboardKey.keyC, primary: true, shift: true)), isNull);
      expect(Keys.reservedFor(const KeyBinding(LogicalKeyboardKey.keyC)), isNull);
      for (final b in Keys.defaults.values) {
        expect(Keys.reservedFor(b), isNull, reason: '${b.label} is a default and must be free');
      }
    });

    testWidgets('Bold, Italic and Code wrap the words chosen in a composer that formats; not a text\'s', (tester) async {
      final chat = MarkdownController(text: 'see you soon');
      final text = MarkdownController(text: 'see you soon')..dims = () => false;
      final chatFocus = FocusNode(), textFocus = FocusNode();
      addTearDown(() {
        chat.dispose();
        text.dispose();
        chatFocus.dispose();
        textFocus.dispose();
      });
      EditableText field(TextEditingController c, FocusNode f) => EditableText(
            controller: c,
            focusNode: f,
            style: const TextStyle(fontSize: 14),
            cursorColor: const Color(0xFF000000),
            backgroundCursorColor: const Color(0xFF888888),
          );
      await tester.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: Column(children: [field(chat, chatFocus), field(text, textFocus)])));
      // Nothing focused: nothing to format, and the key goes on.
      expect(Keys.format(KeyCommand.bold), isFalse);
      chatFocus.requestFocus();
      await tester.pump();
      chat.selection = const TextSelection(baseOffset: 4, extentOffset: 7);
      expect(Keys.format(KeyCommand.bold), isTrue);
      expect(chat.text, 'see **you** soon');
      expect(chat.selection, const TextSelection(baseOffset: 6, extentOffset: 9), reason: 'the same words stay chosen');
      expect(Keys.format(KeyCommand.italic), isTrue);
      expect(chat.text, 'see ***you*** soon');
      chat.selection = TextSelection.collapsed(offset: chat.text.length);
      expect(Keys.format(KeyCommand.code), isTrue);
      expect(chat.text, 'see ***you*** soon``');
      expect(chat.selection, TextSelection.collapsed(offset: chat.text.length - 1), reason: 'at a cursor, typing goes between the two');
      expect(Keys.format(KeyCommand.newChat), isFalse, reason: 'not a Writing command');
      // Strikethrough and Spoiler go round the words; Quote goes before each line chosen, and comes off again.
      chat.text = 'one\ntwo\nthree';
      chat.selection = const TextSelection(baseOffset: 4, extentOffset: 7);
      expect(Keys.format(KeyCommand.strike), isTrue);
      expect(chat.text, 'one\n~~two~~\nthree');
      expect(Keys.format(KeyCommand.spoiler), isTrue);
      expect(chat.text, 'one\n~~||two||~~\nthree');
      chat.text = 'one\ntwo\nthree';
      chat.selection = const TextSelection(baseOffset: 5, extentOffset: 11);
      expect(Keys.format(KeyCommand.quote), isTrue);
      expect(chat.text, 'one\n> two\n> three');
      expect(chat.selection.textInside(chat.text), 'wo\n> thr', reason: 'the same words stay chosen');
      expect(Keys.format(KeyCommand.quote), isTrue);
      expect(chat.text, 'one\ntwo\nthree');
      expect(chat.selection, const TextSelection(baseOffset: 5, extentOffset: 11));
      chat.selection = const TextSelection.collapsed(offset: 1);
      expect(Keys.format(KeyCommand.quote), isTrue);
      expect(chat.text, '> one\ntwo\nthree');
      expect(chat.selection, const TextSelection.collapsed(offset: 3), reason: 'the cursor stays in its word');
      // A text shows the markers as written: none are put in.
      textFocus.requestFocus();
      await tester.pump();
      text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      expect(Keys.format(KeyCommand.bold), isFalse);
      expect(text.text, 'see you soon');
    });

    test('next and previous go down and up the list, held at its ends; from nothing open, the first or the last', () {
      expect(Keys.stepTo(5, 2, 1), 3);
      expect(Keys.stepTo(5, 2, -1), 1);
      expect(Keys.stepTo(5, 4, 1), 4);
      expect(Keys.stepTo(5, 0, -1), 0);
      expect(Keys.stepTo(5, -1, 1), 0);
      expect(Keys.stepTo(5, -1, -1), 4);
    });

    test('the new keys are written as each computer writes them', () {
      expect(Keys.defaults[KeyCommand.nextChat]!.label, Platform.isMacOS ? 'Option+Down' : 'Alt+Down');
      expect(Keys.defaults[KeyCommand.toggleSidebar]!.label, Platform.isMacOS ? r'Cmd+\' : r'Ctrl+\');
      expect(Keys.defaults[KeyCommand.quickSwitch]!.label, Platform.isMacOS ? 'Cmd+K' : 'Ctrl+K');
    });
  });
}
