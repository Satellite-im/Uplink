import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/add_friend_drawer.dart';
import 'package:ghost_messaging/ui/profile_card.dart';
import 'package:ghost_relay/federation.dart';

import 'support/hub_pair.dart';
import 'support/list_harness.dart';
import 'support/relay_app.dart';
import 'support/relay_net.dart';

/// The screens that say what relays now do (docs/OPEN_NETWORK.md, section 4), drawn over the app's own code and real
/// relays in memory (test/support/relay_app.dart): adding someone as name@relay in the add-friend drawer, what it says
/// where the request couldn't be passed on or they have no home record, and a friend's card naming the relay they are
/// on. The words of Settings › Routes are test/net_home_test.dart's.
void main() {
  late RelayNet net;
  late MemoryHub a, b;
  final apps = <RelayApp>[];

  setUp(() {
    net = RelayNet();
    a = net.relay('a.test');
    b = net.relay('b.test');
  });

  Future<RelayApp> app(String name, MemoryHub relay) async {
    final x = RelayApp(net, name, relay);
    apps.add(x);
    await x.start();
    return x;
  }

  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final x in apps) {
        await x.stop();
      }
    });
    apps.clear();
    await tester.pump(const Duration(seconds: 5));
  }

  Future<Me> meAs(WidgetTester tester, String username) async {
    final m = Me.forTest();
    await tester.runAsync(() => m.start(MemoryMeStore()..set('me_username', username), ValueNotifier(0), () => null));
    return m;
  }

  /// Lets what the screen started and what the relays answer take turns until [done], or for a while where there is
  /// nothing to wait for: the screen's own clock is the test's, and the relays' answers come on the real one.
  Future<void> turns(WidgetTester tester, {bool Function()? done, int most = 400}) async {
    for (var i = 0; i < (done == null ? 12 : most) && !(done?.call() ?? false); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
  }

  /// Types [typed] in the drawer's field and waits for it to be looked up.
  Future<void> look(WidgetTester tester, String typed) async {
    await tester.enterText(find.byType(EditableText), typed);
    await tester.pump(const Duration(milliseconds: 950));
    await turns(tester, done: () => find.text('Looking…').evaluate().isEmpty);
  }

  testWidgets('the add-friend drawer: someone on another relay is found as name@relay, named by their relay, and asked', (tester) async {
    final sheet = await loadSheet(tester);
    final (alex, maya) = (await tester.runAsync(() async => (await app('alex', a), await app('maya', b))))!;
    final me = await meAs(tester, 'alex');
    await pumpScreen(tester, sheet, AddFriendDrawer(buddies: alex.buddies, me: me), AppState());
    expect(find.text(addFriendWords('alex')), findsOneWidget, reason: 'how someone on another relay is added is said above the field');
    await look(tester, '@maya@b.test');
    expect(find.text('On b.test: Add asks that relay'), findsOneWidget, reason: 'the relay they are on is named, and nobody is asked until Add is pressed');
    expect(net.asked, isEmpty);
    expect(find.text('On Uplink'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-found')));
    // (The request is a greeting nobody answers: the route waits four seconds for an answer before it says "sent".)
    await turns(tester, done: () => find.text('Friend request sent to @maya@b.test').evaluate().isNotEmpty, most: 1200);
    expect(maya.buddies.requests, isNotEmpty, reason: 'the request never reached her');
    expect(alex.buddies.asked.single.username, 'maya@b.test');
    expect(find.text('Friend request sent to @maya@b.test'), findsOneWidget);
    expect(find.text('Friend request sent'), findsOneWidget, reason: 'and the row under the field says where they stand');
    expect(maya.buddies.requests.single.username, 'alex@a.test');
    await closeAll(tester);
  });

  testWidgets('nobody by that name there, and someone who can\'t be reached yet: said under the field', (tester) async {
    final sheet = await loadSheet(tester);
    final alex = (await tester.runAsync(() => app('alex', a)))!;
    // On b: an app from before, with a username and no home record.
    final old = HubCarrier(url: b.url, signer: KeysSigner(NetKeys.generate()), dial: b.dial);
    await tester.runAsync(() async {
      await old.start();
      await until(() => old.state.value == CarrierState.up, 'the old app never signed in');
      final claimed = old.handles.firstWhere((m) => m['dir'] == 'claim');
      old.sayHandles({'dir': 'claim', 'name': 'oldie'});
      await claimed;
    });
    final me = await meAs(tester, 'alex');
    await pumpScreen(tester, sheet, AddFriendDrawer(buddies: alex.buddies, me: me), AppState());
    // Nobody there: known only once Add asks.
    await look(tester, 'nobody@b.test');
    expect(find.text('On b.test: Add asks that relay'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-found')));
    await turns(tester, done: () => find.text('Nobody has the username @nobody on b.test.').evaluate().isNotEmpty);
    expect(find.text('Nobody has the username @nobody on b.test.'), findsOneWidget);
    await look(tester, 'oldie@b.test');
    expect(find.text('On b.test: Add asks that relay'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-found')));
    await turns(tester, done: () => find.textContaining('newer version').evaluate().isNotEmpty);
    expect(find.text('@oldie@b.test can\'t be reached from another relay yet. They need a newer version of Uplink.'), findsOneWidget);
    expect(alex.buddies.all, isEmpty);
    await tester.runAsync(old.stop);
    await closeAll(tester);
  });

  testWidgets('on a relay that doesn\'t pass messages on: they are found, and the drawer says the request waits', (tester) async {
    final sheet = await loadSheet(tester);
    final island = net.relay('island.test', mode: FedMode.off);
    final (alex, maya) = (await tester.runAsync(() async => (await app('alex', island), await app('maya', b))))!;
    final me = await meAs(tester, 'alex');
    await pumpScreen(tester, sheet, AddFriendDrawer(buddies: alex.buddies, me: me), AppState());
    await look(tester, 'maya@b.test');
    expect(find.text('On b.test: Add asks that relay'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('add-found')));
    await turns(tester, done: () => find.text(addUnreachedWords('maya@b.test')).evaluate().isNotEmpty);
    expect(alex.buddies.asked.single.username, 'maya@b.test', reason: 'she is kept, for when the request can go');
    expect(find.text(addUnreachedWords('maya@b.test')), findsOneWidget);
    expect(find.text('Friend request sent to @maya@b.test'), findsNothing, reason: 'it is not said to have gone');
    expect(maya.buddies.requests, isEmpty);
    await closeAll(tester);
  });

  testWidgets('a friend\'s card says which relay they are on where it isn\'t this one, and nothing of it where it is', (tester) async {
    final sheet = await loadSheet(tester);
    final (alex, maya, anna) = (await tester.runAsync(() async {
      final alex = await app('alex', a), maya = await app('maya', b), anna = await app('anna', a);
      await alex.buddies.add('maya@b.test');
      await alex.buddies.add('anna');
      await until(() => maya.buddies.requests.isNotEmpty && anna.buddies.requests.isNotEmpty, 'the requests never arrived');
      await maya.buddies.accept(maya.buddies.requests.single);
      await anna.buddies.accept(anna.buddies.requests.single);
      await until(() => alex.buddies.friends.length == 2, 'they never became friends');
      return (alex, maya, anna);
    }))!;
    Buddies.instance = alex.buddies;
    addTearDown(() => Buddies.instance = null);
    await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(key: const ValueKey('page'), behavior: HitTestBehavior.opaque, child: const SizedBox.expand())), AppState());
    final context = tester.element(find.byKey(const ValueKey('page')));
    showProfile(context, ProfileSubject.ghost(id: maya.id, username: 'maya@b.test', name: 'Maya'));
    await settle(tester);
    expect(find.byKey(const ValueKey('profile-relay')), findsOneWidget);
    expect(find.text(friendRelayWords('b.test')), findsOneWidget);
    expect(find.textContaining('@maya@b.test'), findsWidgets, reason: 'shown as @maya@b.test');
    Navigator.of(context, rootNavigator: true).pop();
    await settle(tester);
    showProfile(context, ProfileSubject.ghost(id: anna.id, username: 'anna', name: 'Anna'));
    await settle(tester);
    expect(find.byKey(const ValueKey('profile-relay')), findsNothing, reason: 'someone on this relay has nothing to say of it');
    Navigator.of(context, rootNavigator: true).pop();
    await settle(tester);
    await closeAll(tester);
  });
}
