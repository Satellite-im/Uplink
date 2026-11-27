import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/art/lucide_more.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart' show RoleTag;
import 'package:ghost_messaging/ui/ripple_avatar.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart';
import 'package:ghost_messaging/ui/space_designs/telegram.dart';

import 'support/space_call_harness.dart';

/// The Telegram-like voice chat (lib/ui/space_designs/telegram.dart), the app's default call screen in its own colours:
/// drawn on a phone and a computer, full, alone, with the chat open and with video; its buttons do what they say; your
/// own face is there and moving when alone; the chat docked a third of a computer's window; no gradients; the app's
/// ripples on every face.
void main() {
  Future<void> both(WidgetTester tester, SpaceHarness h, Widget Function() page, String name, {Size size = SpaceHarness.phone}) async {
    for (final dark in [false, true]) {
      await h.shoot(tester, page(), name, size: size, dark: dark);
      expect(tester.takeException(), isNull, reason: '$name dark: $dark');
    }
  }

  testWidgets('pictures: phone, computer, alone, chat, video', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await both(tester, h, () => TelegramCall(call: h.call()), 'space-telegram-phone');
    await both(tester, h, () => TelegramCall(call: h.call()), 'space-telegram-computer', size: SpaceHarness.computer);
    await both(tester, h, () => TelegramCall(call: h.call(people: 0, video: const {})), 'space-telegram-alone');
    await both(tester, h, () => TelegramCall(call: h.call(people: 0, video: const {})), 'space-telegram-alone-computer', size: SpaceHarness.computer);
    await both(tester, h, () => TelegramCall(call: h.call(people: 5, video: const {'a', 'c', 'd'}, myVideo: true)), 'space-telegram-video');
    for (final dark in [false, true]) {
      await h.shoot(tester, TelegramCall(call: h.call()), 'space-telegram-chat-closed', dark: dark);
      await tester.tap(find.bySemanticsLabel('Chat'));
      await h.again(tester, 'space-telegram-chat', dark: dark);
      expect(find.text('Saving you a seat'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('the buttons write what they say', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    await h.shoot(tester, TelegramCall(call: h.call(log: log)), 'space-telegram-buttons');
    Future<void> tap(String label) async {
      await tester.tap(find.bySemanticsLabel(label).first);
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tap('Mute');
    await tap('Video');
    await tap('Deafen');
    await tap('Leave');
    await tap('Back'); // the way back puts the call away (it was a chevron, Minimise)
    await tap('Invite to space');
    await tap('Maya Chen');
    await tap('More: invite, devices, settings, leave');
    await tap('Settings');
    await tap('More: invite, devices, settings, leave');
    await tap('Devices');
    await tap('More: invite, devices, settings, leave');
    await tap('Invite');
    expect(log, ['mute', 'video', 'deafen', 'leave', 'minimize', 'invite', 'person a', 'settings', 'devices', 'invite']);

    // Held, a person opens too.
    log.clear();
    await tester.longPress(find.bySemanticsLabel('Sam Ortiz').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(log, ['person b']);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  // GMFB-49 (Kevin: "muting should be split in communities"): which mute it is, on each person's row.
  testWidgets('muted for everyone, muted for you and muted are told apart; a locked microphone says why when pressed', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final base = h.call(people: 0, withChat: false);
    const why = 'A moderator muted you for everyone. Only a moderator can unmute you.';
    final call = SpaceCall(
      channel: base.channel,
      levels: base.levels,
      changes: base.changes,
      muted: true,
      micLocked: true,
      micLockedWhy: why,
      people: const [
        SpacePerson(id: 'me', name: 'Me', me: true, muted: true, mutedForAll: true),
        SpacePerson(id: 'a', name: 'Maya Chen', muted: true, mutedForAll: true),
        SpacePerson(id: 'b', name: 'Sam Ortiz', muted: true, mutedForMe: true),
        SpacePerson(id: 'c', name: 'Riley', muted: true),
      ],
    );
    expect(SpaceWords.mutedIcon(call.people[1]), Lucide.lock);
    expect(SpaceWords.mutedIcon(call.people[2]), LucideMore.volumeX);
    expect(SpaceWords.mutedIcon(call.people[3]), LucideMore.micOff);
    await h.shoot(tester, TelegramCall(call: call), 'space-telegram-mutes');
    expect(find.text('muted for everyone'), findsNWidgets(2));
    expect(find.text('muted for you'), findsOneWidget);
    expect(find.text('muted'), findsOneWidget);
    await tester.tap(find.text('Muted by a moderator'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(why), findsOneWidget);
    // A stage's listener is locked by their role, not by a moderator.
    await h.shoot(tester, TelegramCall(call: SpaceCall(channel: base.channel, levels: base.levels, changes: base.changes, muted: true, micLocked: true, micLockedByRole: true, people: const [SpacePerson(id: 'me', name: 'Me', me: true, muted: true)])), 'space-telegram-listener');
    expect(find.text('Muted by a moderator'), findsNothing);
    expect(find.text('Your role can\'t speak'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a moderator\'s mute disables the microphone and says why', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    await h.shoot(tester, TelegramCall(call: h.call(log: log, muted: true, micLocked: true)), 'space-telegram-locked');
    expect(find.text('Muted by a moderator'), findsOneWidget);
    await tester.tap(find.text('Muted by a moderator'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log, isEmpty);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('deafened, the big button undeafens rather than muting you', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final log = <String>[];
    await h.shoot(tester, TelegramCall(call: h.call(log: log, deafened: true)), 'space-telegram-deafened');
    expect(find.text('Undeafen'), findsWidgets);
    expect(find.text('Tap to listen and speak'), findsOneWidget);
    expect(find.text('Unmute'), findsNothing);
    await tester.tap(find.text('Tap to listen and speak'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log, ['deafen']);
    // The words a screen reader hears are the ones on the button.
    expect(find.bySemanticsLabel('Undeafen'), findsNWidgets(2));
    expect(find.bySemanticsLabel('Mute'), findsNothing);

    // Muted as well, undeafening brings back hearing only, and says so.
    await h.shoot(tester, TelegramCall(call: h.call(log: log, deafened: true, muted: true)), 'space-telegram-deafened-muted');
    expect(find.text('Tap to listen'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('on a computer the chat is docked open, a third of the window', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    await h.shoot(tester, TelegramCall(call: h.call()), 'space-telegram-docked', size: SpaceHarness.computer);
    final chat = tester.getSize(find.byKey(const ValueKey('tg-chat-panel')));
    final voice = tester.getSize(find.byKey(const ValueKey('tg-voice-panel')));
    expect(chat.width, closeTo(1280 / 3, 2));
    expect(voice.width, closeTo(1280 - chat.width, 2));
    expect(find.text('Saving you a seat'), findsOneWidget);
    // Closed, the voice chat takes the whole window; Chat opens it again at a third.
    await tester.tap(find.bySemanticsLabel('Close chat'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('tg-chat-panel')), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('tg-voice-panel'))).width, closeTo(1280, 1));
    await tester.tap(find.bySemanticsLabel('Chat'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(find.byKey(const ValueKey('tg-chat-panel'))).width, closeTo(1280 / 3, 2));
    await tester.pumpWidget(const SizedBox());
  });

  test('the design has no gradients', () {
    final source = File('lib/ui/space_designs/telegram.dart').readAsStringSync();
    expect(source.contains('Gradient'), isFalse);
    expect(source.contains('ShaderMask'), isFalse);
  });

  testWidgets('faces are the app\'s rippling faces, alone too', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    await h.shoot(tester, TelegramCall(call: h.call()), 'space-telegram-faces');
    expect(find.byType(SpaceFace), findsNWidgets(5 + 1)); // five in the list, Riley's video tile
    expect(find.byType(RippleAvatar), findsWidgets);
    await h.shoot(tester, TelegramCall(call: h.call(people: 0, video: const {})), 'space-telegram-faces-alone');
    expect(find.byType(SpaceFace), findsNWidgets(2)); // the list's row and the big one
    expect(find.byKey(const ValueKey('tg-alone-me')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('tg-alone-me')), matching: find.byType(RippleAvatar)), findsOneWidget);
    // The microphone wears the ripples too.
    expect(find.byKey(const ValueKey('tg-mic-ripples')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('alone, your own face is drawn and its ripples follow your voice', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await h.shoot(tester, TelegramCall(call: h.call(people: 0, video: const {})), 'space-telegram-alone-check');
    expect(find.byKey(const ValueKey('tg-face-me')), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    expect(find.text('talking'), findsOneWidget);
    expect(find.text('Waiting for others to join'), findsOneWidget);
    expect(find.text('Mic on'), findsOneWidget);
    expect(find.text('Just you'), findsOneWidget);
    h.levels.value = const {'me': 0};
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('listening'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('the words are the app\'s: the space\'s name, in voice, talking, Mic on and Muted, RoleTag', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    final call = h.call();
    await h.shoot(tester, TelegramCall(call: call), 'space-telegram-words');
    // Headed by the space's name and how many are in voice, not "Voice Chat" and participants.
    expect(find.text(call.channel.name), findsWidgets);
    expect(find.text('${call.people.length} in voice'), findsOneWidget);
    expect(find.text('Voice Chat'), findsNothing);
    expect(find.textContaining('participant'), findsNothing);
    expect(find.textContaining('members'), findsNothing);
    expect(find.text('talking'), findsWidgets);
    expect(find.text('speaking'), findsNothing);
    expect(find.text('listening'), findsWidgets);
    expect(find.text('muted'), findsWidgets);
    expect(find.text('Mic on'), findsOneWidget);
    expect(find.text('Tap to mute'), findsOneWidget);
    expect(find.text('Invite to space'), findsOneWidget);
    // No role tags: names in their role's colour, and the owner (this device) has a crown alone (Matt, 2026-11-17:
    // "Don't show the badges for owner moderator etc, instead assign role colors like discord does and for the owner
    // just show a singlular crown icon"); Riley is a quiet "guest".
    expect(find.byType(RoleTag), findsNothing);
    // No crown: the owner shows by their role's colour alone (Matt, 2026-11-18: "Remove the crown icon").
    expect(find.bySemanticsLabel('Owner'), findsNothing);
    expect(find.text('Owner'), findsNothing);
    expect(find.text('guest'), findsOneWidget);

    await h.shoot(tester, TelegramCall(call: h.call(muted: true)), 'space-telegram-muted');
    expect(find.text('Muted'), findsOneWidget);
    expect(find.text('Tap to unmute'), findsOneWidget);
    expect(find.text('Mic on'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  // Matt, 2026-11-16: "the chatbar doesn't move up when in the chat section of a space".
  testWidgets('on a phone the chat\'s message bar stands above the keyboard', (tester) async {
    final h = await SpaceHarness.load(tester);
    addTearDown(tester.view.reset);
    await h.shoot(tester, TelegramCall(call: h.call()), 'space-telegram-chat-closed');
    await tester.tap(find.bySemanticsLabel('Chat'));
    await h.again(tester, 'space-telegram-chat');
    final field = find.byType(EditableText);
    expect(field, findsOneWidget);
    final before = tester.getRect(field).bottom;
    // A keyboard 300 high comes up (the view's insets, in device pixels).
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final after = tester.getRect(field).bottom;
    expect(after, lessThanOrEqualTo(SpaceHarness.phone.height - 300), reason: 'above the keyboard');
    expect(after, greaterThan(SpaceHarness.phone.height - 300 - 80), reason: 'just above it, not far up');
    expect(after, lessThan(before));
    tester.view.resetViewInsets();
    await tester.pump();
    expect(tester.getRect(field).bottom, closeTo(before, 1), reason: 'back down when it goes');
    await tester.pumpWidget(const SizedBox());
  });
}
