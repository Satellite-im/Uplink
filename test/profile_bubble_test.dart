import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/ui/profile.dart';
import 'package:ghost_messaging/ui/shell.dart';

import 'support/list_harness.dart';

/// The profile bubble at the rail's foot (lib/ui/profile_bubble.dart; Matt, 2026-11-25: "in the bottom of the
/// navigation rail just above the settings add a profile bubble with our indicator status (online afk etc) and have a
/// popup for quickly managing a few profile settings ... and have a button at the bottom to open all profile
/// settings"): where it stands, the mark it wears, and what its card does.
Finder _key(String k) => find.byKey(ValueKey(k));

const _phone = Size(412, 892), _wide = Size(1000, 760);

void main() {
  late AppState state;

  setUp(() {
    ListPhone([ListPhone.conversation(1, '+15551230001', 'See you at 7', name: 'Maya Chen')]).install();
    state = AppState();
  });

  Future<void> frame(WidgetTester tester, {Size size = _wide, Map<String, String> more = const {}}) async {
    final store = MemoryMeStore()..set('me_username', 'matt')..set('me_display', 'Matt');
    more.forEach(store.set);
    await tester.runAsync(() => Me.instance.start(store, ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
    state.set(NavStyle.pref, NavStyle.rail.name);
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const AppShell(), state, size: size);
  }

  testWidgets('it stands just above Settings and wears how you are shown', (tester) async {
    await frame(tester);
    final bubble = tester.getRect(_key('rail-profile')), settings = tester.getRect(_key('rail-settings')), market = tester.getRect(_key('rail-marketplace'));
    expect(bubble.top, greaterThan(market.bottom - 1));
    expect(bubble.bottom, lessThan(settings.top + 1));
    expect(_key('profile-bubble-mode-online'), findsOneWidget);
    // No card until it is pressed.
    expect(_key('profile-peek-name'), findsNothing);
  });

  testWidgets('its card: who you are, how you are shown changed in place, the status kept', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    expect(find.descendant(of: _key('profile-peek-name'), matching: find.text('Matt')), findsOneWidget);
    expect(find.text('@matt'), findsOneWidget);
    // Beside the rail, inside the window, its foot no lower than the window's.
    final card = tester.getRect(_key('profile-peek-all'));
    expect(card.left, greaterThan(tester.getRect(_key('rail-profile')).right));
    expect(card.bottom, lessThan(_wide.height));
    // The ways of being shown open out under the one chosen.
    expect(_key('profile-peek-mode-busy'), findsNothing);
    await tester.tap(_key('profile-peek-mode'));
    await settle(tester);
    await tester.tap(_key('profile-peek-mode-busy'));
    await settle(tester);
    expect(Me.instance.presenceMode, 'busy');
    expect(_key('profile-bubble-mode-busy'), findsOneWidget);
    expect(_key('profile-peek-mode-busy'), findsNothing);
    // A status written and Enter pressed.
    await tester.enterText(find.descendant(of: _key('profile-peek-status'), matching: find.byType(EditableText)), 'Out  walking');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(Me.instance.status, 'Out walking');
  });

  testWidgets('a status half written is kept as the card is put away', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    await tester.enterText(find.descendant(of: _key('profile-peek-status'), matching: find.byType(EditableText)), 'Heads down');
    // A press anywhere else puts the card away.
    await tester.tapAt(const Offset(700, 100));
    await settle(tester);
    expect(_key('profile-peek-name'), findsNothing);
    expect(Me.instance.status, 'Heads down');
  });

  testWidgets('All profile settings opens the profile and puts the card away', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    await tester.tap(_key('profile-peek-all'));
    await settle(tester);
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(_key('profile-peek-name'), findsNothing);
    // Messages takes its place again.
    await tester.tap(_key('rail-home'));
    await settle(tester);
    expect(find.byType(ProfileScreen), findsNothing);
  });

  // Matt, 2026-11-25: "I need a setting to change my banner"; "add the ability to pick your badge (show it next to your
  // name) and show a popover when picking the badge".
  testWidgets('the banner is changed from the card: the pencil on it opens the banners, a press wears one', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    expect(_key('profile-peek-banners'), findsNothing);
    await tester.tap(_key('profile-peek-banner-change'));
    await settle(tester);
    expect(_key('profile-peek-banner-none'), findsOneWidget);
    await tester.tap(_key('profile-peek-banner-midnight-fog'));
    await settle(tester);
    expect(Me.instance.cosmetics.banner, 'midnight-fog');
    expect(_key('profile-peek-name'), findsOneWidget, reason: 'the card stays');
    await tester.tap(_key('profile-peek-banner-none'));
    await settle(tester);
    expect(Me.instance.cosmetics.banner, isEmpty);
    // The pencil again puts them away.
    await tester.tap(_key('profile-peek-banner-change'));
    await settle(tester);
    expect(_key('profile-peek-banners'), findsNothing);
  });

  testWidgets('the badge beside your name is chosen from a list hung from it, and the card stays open', (tester) async {
    await frame(tester, more: {'me_special': 'founder,alpha'});
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    expect(_key('profile-peek-badge'), findsOneWidget);
    expect(_key('profile-peek-badge-alpha'), findsNothing);
    await tester.tap(_key('profile-peek-badge'));
    await settle(tester);
    expect(find.text('Founder'), findsOneWidget);
    expect(find.text('Tried it before anyone else'), findsOneWidget);
    await tester.tap(_key('profile-peek-badge-alpha'));
    await settle(tester);
    expect(Me.instance.showcase, 'alpha');
    expect(_key('profile-peek-badge-alpha'), findsNothing, reason: 'the list is put away');
    expect(_key('profile-peek-name'), findsOneWidget, reason: 'the card is not');
    // A press outside both now puts the card away.
    await tester.tapAt(const Offset(700, 100));
    await settle(tester);
    expect(_key('profile-peek-name'), findsNothing);
  });

  testWidgets('no badge to choose where you have none', (tester) async {
    await frame(tester);
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    expect(_key('profile-peek-badge'), findsNothing);
  });

  testWidgets('on a phone the card fits beside the rail', (tester) async {
    await frame(tester, size: _phone);
    await tester.tap(_key('rail-profile'));
    await settle(tester);
    final all = tester.getRect(_key('profile-peek-all'));
    expect(all.left, greaterThan(tester.getRect(_key('rail-profile')).right));
    expect(all.right, lessThan(_phone.width));
    expect(tester.takeException(), isNull);
  });
}
