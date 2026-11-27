import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/ui/profile_card.dart';
import 'package:ghost_messaging/ui/vouches_ui.dart';

import 'support/list_harness.dart';
import 'support/vouch_world.dart';

/// Vouches on screen (GMFB-33; lib/ui/vouches_ui.dart): a friend's card says how many of the viewer's own friends vouch
/// for them, with their names on a tap, and offers Vouch for and its taking back; Profile › Vouches counts this
/// account's and hides them from friends.
void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

  testWidgets('a friend\'s card: "Vouched for by 1 of your friends", the name on a tap, and Vouch for, then Take back', (tester) async {
    final sheet = await loadSheet(tester);
    final w = VouchWorld();
    final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
    final b = (await tester.runAsync(() async {
      final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)]);
      await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
      await pumpEventQueue();
      return b;
    }))!;
    Buddies.instance = b[theo]!;
    addTearDown(() => Buddies.instance = null);
    await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(onTap: () => showProfile(context, ProfileSubject.ghost(id: maya.keys.id)), child: const Text('open'))), AppState(), size: const Size(412, 1200));
    await tester.tap(find.text('open'));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('profile-vouches'), skipOffstage: false));
    await settle(tester);
    expect(find.text('Vouched for by 1 of your friends'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-vouches-names')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('profile-vouches-count')));
    await settle(tester);
    expect(find.text('sam'), findsOneWidget, reason: 'the names, on a tap');
    expect(find.byKey(const ValueKey('profile-vouches-mine')), findsNothing);

    await tester.tap(find.text('Vouch for @maya'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(b[theo]!.vouchedFor(b[theo]!.byId(maya.keys.id)!), isTrue);
    expect([for (final v in b[maya]!.vouchersOf(null)) v.username]..sort(), ['sam', 'theo']);
    // Opened again: Theo's own vouch is said, and the choice is to take it back.
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(find.text(yourVouchWords(b[theo]!.vouchRunsOut(b[theo]!.byId(maya.keys.id)!)!)), findsOneWidget);
    expect(find.text('Vouch for @maya again'), findsOneWidget, reason: 'renewing is offered');
    expect(find.text('Vouched for by 1 of your friends'), findsOneWidget, reason: 'Theo isn\'t his own friend');
    await tester.tap(find.text('Take back your vouch for @maya'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect([for (final v in b[maya]!.vouchersOf(null)) v.username], ['sam']);
    for (final x in b.values) {
      x.dispose();
    }
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Profile › Vouches counts this account\'s, and its switch hides them from friends', (tester) async {
    final sheet = await loadSheet(tester);
    final w = VouchWorld();
    final maya = VouchPort(w, 'maya'), sam = VouchPort(w, 'sam'), theo = VouchPort(w, 'theo');
    final b = (await tester.runAsync(() async {
      final b = await makeFriends([(maya, sam), (maya, theo), (sam, theo)]);
      await b[sam]!.vouch(b[sam]!.byId(maya.keys.id)!);
      await b[theo]!.vouch(b[theo]!.byId(maya.keys.id)!);
      await pumpEventQueue();
      return b;
    }))!;
    await pumpScreen(tester, sheet, ListView(children: [VouchesSection(buddies: b[maya]!)]), AppState());
    expect(find.text('Vouched for by 2 of your friends'), findsOneWidget);
    expect(find.text('sam and theo'), findsOneWidget);
    expect(b[theo]!.vouchersOf(b[theo]!.byId(maya.keys.id)).length, 1);
    await tester.tap(find.byKey(const ValueKey('vouches-show')));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(b[maya]!.vouches.hidden, isTrue);
    expect(b[theo]!.vouchersOf(b[theo]!.byId(maya.keys.id)), isEmpty, reason: 'friends are told at once');
    for (final x in b.values) {
      x.dispose();
    }
    await tester.pump(const Duration(seconds: 5));
  });

  test('the words say who receives a vouch: all of their friends, though only mutual friends count it (review, 2026-11-23)', () {
    expect(vouchHint, contains('Their friends receive it; only those who are your friends too count it.'));
    expect(vouchHint, isNot(contains('Only your friends who are theirs too will see it')));
  });
}
