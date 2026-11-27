import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glacier/glacier.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/games/game_activity.dart';
import 'package:ghost_messaging/me/lookup_budget.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/presence.dart';
import 'package:ghost_messaging/standalone/chats.dart';
import 'package:ghost_messaging/ui/add_friend_drawer.dart';
import 'package:ghost_messaging/ui/username_friends.dart';

/// Friends by username (lib/friends/buddies.dart). Matt, 2026-11-14: "create a profile and username under "me" to
/// register a username and add friends on the platform".
///
/// Two installs, each with its own key pair, a directory that maps usernames to them, and routes that pass what one
/// sends to the other: sealed only once the sender holds a key for them (it has them in its list), in the clear only
/// as a greeting, as the switchboard does.
class _World {
  final Map<String, _Port> byName = {};
  final Map<String, _Port> byId = {};
}

class _Port implements BuddiesPort {
  _Port(this.world, this.name, {this.display = '', this.line = ''}) : keys = NetKeys.generate() {
    world.byName[name] = this;
    world.byId[keys.id] = this;
  }

  final _World world;
  final String name;
  final NetKeys keys;
  String display, line;
  String list = '[]';
  final _in = StreamController<({String from, Envelope envelope})>.broadcast();
  final _hellos = StreamController<({String from, Envelope envelope})>.broadcast();

  bool _holds(String id) => (jsonDecode(list) as List).any((b) => (b as Map)['i'] == id);

  @override
  Future<({String id, String key})> me() async => (id: keys.id, key: base64Encode(keys.public));
  @override
  String? get username => name;
  @override
  String get displayName => display;
  @override
  String get bio => line;
  /// The relay can't be asked: the directory answers nothing (Me.whois throws).
  bool directoryDown = false;

  /// Told of each lookup asked of the directory.
  void Function()? onWhois;

  @override
  Future<({String id, String key})?> whois(String username) async {
    onWhois?.call();
    if (directoryDown) throw MeError('The relay server can\'t be reached right now.');
    final p = world.byName[username];
    return p == null ? null : (id: p.keys.id, key: base64Encode(p.keys.public));
  }

  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;

  /// Lost on the way, as the hub loses what it was holding when the relay restarts: the next ones sent go nowhere.
  int drop = 0;

  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async {
    if (drop > 0) {
      drop--;
      return true;
    }
    final to = world.byId[id];
    if (to == null) return false;
    // Sealed needs a key on both sides: each must have the other in its list.
    if (sealed && (!_holds(id) || !to._holds(keys.id))) return false;
    scheduleMicrotask(() => (sealed ? to._in : to._hellos).add((from: keys.id, envelope: envelope)));
    return true;
  }

  @override
  Stream<({String from, Envelope envelope})> get received => _in.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => _hellos.stream;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  // Matt, 2026-11-24: "please see what you can do about the high CPU usage on the app". A paired computer asks for
  // the friends every twenty seconds, and was sent them all each time (lib/desk_stamp.dart).
  test('a computer that asks for the friends again is answered in a word while nothing has changed', () async {
    final world = _World();
    final maya = _Port(world, 'maya', display: 'Maya Chen');
    final sam = _Port(world, 'sam', display: 'Sam');
    final a = Buddies(maya), b = Buddies(sam);
    await a.start();
    await b.start();
    final first = await a.forComputer({'op': 'list'}) as Map;
    expect(first['list'], isEmpty);
    final stamp = first['stamp'] as String;
    expect(await a.forComputer({'op': 'list', 'have': stamp}), {'same': 1, 'stamp': stamp});
    await a.add('@Sam');
    await _settle();
    final after = await a.forComputer({'op': 'list', 'have': stamp}) as Map;
    expect(after['list'], hasLength(1));
    expect(after['stamp'], isNot(stamp));
    // A computer from before says no mark, and anything else it asks is answered with the list, as ever.
    expect((await a.forComputer({'op': 'list'}) as Map)['list'], hasLength(1));
    expect((await a.forComputer({'op': 'share', 'have': after['stamp']}) as Map)['list'], hasLength(1));
  });

  test('ask by username, the other says yes, and both are friends with each other\'s name', () async {
    final world = _World();
    final maya = _Port(world, 'maya', display: 'Maya Chen', line: 'climbing most days');
    final sam = _Port(world, 'sam', display: 'Sam');
    final a = Buddies(maya), b = Buddies(sam);
    await a.start();
    await b.start();

    final asked = await a.add('@Sam');
    expect(asked.state, 'asked');
    await _settle();
    // Sam sees who asked, with what Maya says about herself.
    expect(b.requests.single.username, 'maya');
    expect(b.requests.single.name, 'Maya Chen');
    expect(b.requests.single.bio, 'climbing most days');

    await b.accept(b.requests.single);
    await _settle();
    expect(a.friends.single.username, 'sam');
    expect(a.friends.single.name, 'Sam');
    expect(b.friends.single.username, 'maya');
    // Kept for the phone to make the sealing keys from.
    expect(jsonDecode(maya.list), [containsPair('s', 'yes')]);

    // A new name reaches friends.
    maya.display = 'Maya C.';
    await a.shareProfile();
    await _settle();
    expect(b.friends.single.name, 'Maya C.');

    // Removed: gone on both.
    await b.remove(b.friends.single);
    await _settle();
    expect(a.all, isEmpty);
    expect(b.all, isEmpty);
  });

  // GMFB-40: "Reporting a person also offers to block them".
  test('a blocked person is no longer a friend, their requests are dropped, and asking them again takes the block away', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam'), theo = _Port(world, 'theo');
    final a = Buddies(maya), b = Buddies(sam), c = Buddies(theo);
    await a.start();
    await b.start();
    await c.start();
    await a.add('sam');
    await _settle();
    await b.accept(b.requests.single);
    await _settle();
    expect(a.friends.single.username, 'sam');

    // Maya blocks Sam, her friend: Sam is told, as a removal tells him; she keeps him as blocked, with no friends.
    await a.block(sam.keys.id, username: 'sam');
    await _settle();
    expect(a.friends, isEmpty);
    expect(a.blocked.single.username, 'sam');
    expect(a.isBlocked(sam.keys.id), isTrue);
    expect(b.all, isEmpty, reason: 'Sam was told they are no longer friends');
    // Kept with the list, as 'blocked', which the phone gives no sealing key.
    expect(jsonDecode(maya.list), [allOf(containsPair('s', 'blocked'), containsPair('i', sam.keys.id))]);

    // Sam asks again: nothing reaches Maya.
    await b.add('maya');
    await _settle();
    expect(a.requests, isEmpty);
    expect(a.blocked.single.state, 'blocked');

    // Someone met in a space, never a friend, blocked by id alone; their request goes nowhere either.
    await a.block(theo.keys.id, username: 'theo');
    await c.add('maya');
    await _settle();
    expect(a.requests, isEmpty);
    expect(a.blocked.map((x) => x.username).toSet(), {'sam', 'theo'});

    // Unblocked: forgotten, and Theo's next request is a request.
    await a.unblock(a.blocked.firstWhere((x) => x.username == 'theo'));
    expect(a.isBlocked(theo.keys.id), isFalse);
    await c.askAgain();
    await _settle();
    expect(a.requests.single.username, 'theo');

    // Maya asks Sam to be friends again: the block is gone, and he is asked.
    final asked = await a.add('sam');
    expect(asked.state, 'asked');
    expect(a.isBlocked(sam.keys.id), isFalse);
  });

  // Matt, 2026-11-20: "what about game presence sensing like discord has?" (lib/games/game_activity.dart).
  test('a friend is told what you are playing, and that you stopped; someone who is not a friend is told nothing', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam'), theo = _Port(world, 'theo');
    final a = Buddies(maya), b = Buddies(sam), c = Buddies(theo);
    await a.start();
    await b.start();
    await c.start();
    await a.add('@sam');
    await _settle();
    await b.accept(b.requests.single);
    await _settle();
    // Theo asked Maya and she has not answered: not a friend.
    await c.add('@maya');
    await _settle();
    final heard = GameActivities.instance = GameActivities();
    addTearDown(() => GameActivities.instance = GameActivities());
    final since = DateTime.now().subtract(const Duration(minutes: 25));
    await a.sayActivity(GameActivity('Hades', since));
    await _settle();
    expect(heard.of(maya.keys.id)?.name, 'Hades', reason: 'Sam, her friend, was told');
    expect(heard.of(maya.keys.id)!.words(), 'Playing Hades · 25 min');
    expect(b.friends.single.status, '', reason: 'nothing of it is kept with the list');
    await a.sayActivity(null);
    await _settle();
    expect(heard.of(maya.keys.id), isNull, reason: 'and told she stopped');
    // What someone who is not a friend says is not taken.
    await sam.send(theo.keys.id, Envelope(kind: 'buddy', body: {'s': 'ga', 'ga': {'n': 'Doom', 's': 1}}), sealed: false);
    await _settle();
    expect(heard.of(sam.keys.id), isNull);
  });

  test('a request lost on its way, and then the yes, are asked again until both are friends', () async {
    // Matt, 2026-11-19: "my friend request to morgan never went through i also sent one from her phone and it didn't go
    // out". The hub drops what it holds when the relay restarts; nothing asked again.
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam');
    final a = Buddies(maya), b = Buddies(sam);
    await a.start();
    await b.start();
    maya.drop = 1;
    await a.add('sam');
    await _settle();
    expect(b.requests, isEmpty);
    // Asked again: Sam has it now, once.
    expect(await a.askAgain(), 1);
    await _settle();
    expect(b.requests.single.username, 'maya');
    await a.askAgain();
    await _settle();
    expect(b.requests, hasLength(1));
    // Sam's yes is lost too: Maya is still waiting, and asks again; Sam, a friend already, says yes again.
    sam.drop = 1;
    await b.accept(b.requests.single);
    await _settle();
    expect(a.friends, isEmpty);
    await a.askAgain();
    await _settle();
    expect(a.friends.single.username, 'sam');
    expect(b.friends.single.username, 'maya');
    // Answered: nothing left to ask.
    expect(await a.askAgain(), 0);
    a.dispose();
    b.dispose();
  });

  test('two who ask each other are friends at once; nobody, yourself, or no username of your own is refused', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam');
    final a = Buddies(maya), b = Buddies(sam);
    await a.start();
    await b.start();
    await a.add('sam');
    await _settle();
    await b.add('maya');
    await _settle();
    expect(a.friends.map((f) => f.username), ['sam']);
    expect(b.friends.map((f) => f.username), ['maya']);
    await expectLater(a.add('nobody'), throwsA(isA<MeError>()));
    await expectLater(a.add('maya'), throwsA(isA<MeError>()));
  });

  // From the independent review of the who-sent fix (2026-11-23), its probe 4: a request names its own username, and
  // anyone can send one. Accepted, one that named itself "maya" stood for @maya (the newest install under a username
  // does), and took what was written to her.
  test('a request is not kept where the directory gives its username to someone else; one whose username it doesn\'t know waits, saying so', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam'), eve = _Port(world, 'eve');
    final b = Buddies(sam);
    await b.start();
    await Buddies(maya).start();
    // Eve asks Sam calling herself "maya", with her own key; then as a username nobody has here (a friend's username
    // can be another relay's: the review's follow-up S3); then as herself.
    void ask(_Port from, String calling) => sam._hellos.add((from: from.keys.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': calling, 'n': 'Maya', 'k': base64Encode(from.keys.public)})));
    ask(eve, 'maya');
    await _settle();
    expect(b.requests, isEmpty, reason: 'not who it says');
    ask(eve, 'nobody.here');
    await _settle();
    expect(b.requests.map((r) => (r.username, r.check)).toList(), [('nobody.here', 'nobody')]);
    expect(requestLine(b.requests.single), contains('this relay doesn\'t know'));
    ask(eve, 'eve');
    await _settle();
    expect(b.requests.map((r) => (r.username, r.check)).toList(), [('eve', 'ok')]);
    // Maya herself, after: checked.
    ask(maya, 'maya');
    await _settle();
    expect(b.requests.map((r) => (r.username, r.check)).toSet(), {('eve', 'ok'), ('maya', 'ok')});
  });

  test('where the relay can\'t be asked, a request waits unchecked and can\'t be accepted; asked again, what the directory says is kept with each', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam'), eve = _Port(world, 'eve');
    final a = Buddies(maya), b = Buddies(sam);
    await a.start();
    await b.start();
    sam.directoryDown = true;
    await a.add('sam');
    sam._hellos.add((from: eve.keys.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'maya.c', 'k': base64Encode(eve.keys.public)})));
    await _settle();
    expect(b.requests.map((r) => (r.username, r.check)).toList(), [('maya', ''), ('maya.c', '')]);
    await expectLater(b.accept(b.requests.first), throwsA(isA<MeError>().having((e) => e.message, 'says why', contains('can\'t be checked'))));
    expect(b.friends, isEmpty);
    // The relay answers again: Maya's is checked, and Eve's, under a username it doesn't know, waits, saying so.
    sam.directoryDown = false;
    expect(await b.checkRequests(), 2);
    expect(b.requests.map((r) => (r.username, r.check)).toList(), [('maya', 'ok'), ('maya.c', 'nobody')]);
    await b.accept(b.requests.first);
    await _settle();
    expect(a.friends.single.username, 'sam');
    expect(b.friends.single.username, 'maya');
  });

  test('a request not checked yet, accepted once the relay answers, is refused where its username is someone else\'s, and stays, shown so: never forgotten on one answer', () async {
    final world = _World();
    final sam = _Port(world, 'sam'), eve = _Port(world, 'eve');
    _Port(world, 'maya');
    final b = Buddies(sam);
    await b.start();
    sam.directoryDown = true;
    sam._hellos.add((from: eve.keys.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'maya', 'k': base64Encode(eve.keys.public)})));
    await _settle();
    expect(b.requests.single.checked, isFalse);
    sam.directoryDown = false;
    await expectLater(b.accept(b.requests.single), throwsA(isA<MeError>().having((e) => e.message, 'says why', contains('someone else'))));
    expect(b.requests.map((r) => (r.username, r.check)).toList(), [('maya', 'other')]);
    expect(requestLine(b.requests.single), contains('gives to someone else'));
    // Asked about again, and the same: it stays.
    await b.checkRequests();
    expect(b.requests, hasLength(1));
    expect(b.friends, isEmpty);
  });

  // The review's follow-up S2 (2026-11-23): the relay answers an account 120 lookups an hour, all its devices together,
  // and strangers' requests, each looked up as it came, could use them up: then nothing could be accepted or added for an
  // hour. They are held to the account's budget of lookups made of the app's own accord, which the name watch shares
  // (test/name_watch_test.dart has the two together, and the account's devices).
  test('requests are looked up of this phone\'s own accord within the account\'s budget, each once; past that, only when Accept is pressed', () async {
    final world = _World();
    final sam = _Port(world, 'sam');
    var asked = 0;
    sam.onWhois = () => asked++;
    final lookups = LookupBudget();
    final b = Buddies(sam, lookups: lookups);
    await b.start();
    final cap = lookups.forRequests;
    expect(cap, lessThan(LookupBudget.mostAnHour), reason: 'a third left to the name watch');
    final strangers = [for (var i = 0; i < cap + 10; i++) NetKeys.generate()];
    void ask(NetKeys from, int i) => sam._hellos.add((from: from.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'stranger.$i', 'k': base64Encode(from.public)})));
    for (final (i, s) in strangers.indexed) {
      ask(s, i);
    }
    await _settle();
    expect(b.requests, hasLength(strangers.length), reason: 'every one is kept');
    expect(asked, cap);
    // The same requests again (their apps ask again every few minutes): none is looked up again, nor asked about again.
    for (final (i, s) in strangers.indexed) {
      ask(s, i);
    }
    await _settle();
    expect(await b.checkRequests(), 0);
    expect(asked, cap);
    // Accept, pressed on one never looked up: it is looked up then.
    final last = b.requests.firstWhere((r) => r.username == 'stranger.${strangers.length - 1}');
    await expectLater(b.accept(last), throwsA(isA<MeError>().having((e) => e.message, 'says why', contains('doesn\'t know'))));
    expect(asked, cap + 1);
  });

  test('the friend by username a conversation and a face stand for is one who said yes, never a request or someone blocked under the same username', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam'), eve = _Port(world, 'eve');
    final b = Buddies(sam);
    // Listed first: Eve, asking as "maya" (kept by a build from before requests were checked), and someone blocked under it.
    sam.list = jsonEncode([
      Buddy(username: 'maya', id: eve.keys.id, key: base64Encode(eve.keys.public), name: 'Not Maya', state: 'invited', at: 9).toJson(),
      Buddy(username: 'maya', id: 'f' * 32, key: 'x', name: 'Blocked', state: 'blocked', at: 8).toJson(),
      Buddy(username: 'maya', id: maya.keys.id, key: base64Encode(maya.keys.public), name: 'Maya', at: 1).toJson(),
    ]);
    await b.start();
    final was = Buddies.instance;
    Buddies.instance = b;
    addTearDown(() => Buddies.instance = was);
    expect(b.standingFor('@maya')?.id, maya.keys.id);
    expect(Presence.ghostIdOf('@maya'), maya.keys.id);
    expect(Presence.ghostIdOf('@nobody'), isNull);
    // And the conversation's name, as the overlay gives it (UsernameChats.person).
    final chats = UsernameChats(save: () {}, buddies: () => b.all);
    expect(chats.person('@maya')['name'], 'Maya');
  });

  test('a request in someone else\'s name is not taken: its key must be the sender\'s', () async {
    final world = _World();
    final maya = _Port(world, 'maya'), sam = _Port(world, 'sam');
    final b = Buddies(sam);
    await b.start();
    final other = NetKeys.generate();
    sam._hellos.add((from: maya.keys.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'maya', 'k': base64Encode(other.public)})));
    await _settle();
    expect(b.requests, isEmpty);
    expect(Me.goodUsername('ab'), isFalse);
    expect(Me.goodUsername('Maya_C'), isTrue);
  });

  group('on Contacts (UsernameFriends)', () {
    // Matt, 2026-11-16: "We need a way to add friends on the network by username on the contacts page and see friend
    // requests".
    Future<Me> me(String? username) async {
      final store = MemoryMeStore();
      if (username != null) store.set('me_username', username);
      final m = Me.forTest();
      await m.start(store, ValueNotifier(0), () => null);
      return m;
    }

    Future<void> show(WidgetTester tester, Buddies b, Me m) async {
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      await tester.pumpWidget(WidgetsApp(
        color: const Color(0xFF4F5BD5),
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder w) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => w(c)),
        builder: (context, child) => GlacierTheme(sheet: sheet, attrs: const {'platform': 'mobile'}, child: GlacierToastProvider(child: child!)),
        home: ListView(children: [UsernameFriends(buddies: b, me: m)]),
      ));
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(_settle);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('a request shows with Accept and Decline, and Accept makes friends of both', (tester) async {
      final world = _World();
      final a = Buddies(_Port(world, 'maya', display: 'Maya Chen')), b = Buddies(_Port(world, 'sam'));
      await tester.runAsync(() async {
        await a.start();
        await b.start();
        await a.add('sam');
        await _settle();
      });
      await show(tester, b, await tester.runAsync(() => me('sam')) as Me);
      expect(find.text('Friend request'), findsOneWidget);
      expect(find.text('Maya Chen'), findsOneWidget);
      expect(find.byKey(const ValueKey('decline-maya')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('accept-maya')));
      await settle(tester);
      expect(find.text('Friend request'), findsNothing);
      // A friend now: listed On Uplink in Contacts with the friends by number, not here (2026-11-19).
      expect(find.text('Friends by username'), findsNothing);
      expect(find.text('Maya Chen'), findsNothing);
      expect(b.friends.single.username, 'maya');
      expect(a.friends.single.username, 'sam', reason: 'Maya hears the yes');
    });

    testWidgets('a request the relay couldn\'t check says so, and Accept says why it can\'t be yet', (tester) async {
      final world = _World();
      final sam = _Port(world, 'sam');
      final a = Buddies(_Port(world, 'maya', display: 'Maya Chen')), b = Buddies(sam);
      sam.directoryDown = true;
      await tester.runAsync(() async {
        await a.start();
        await b.start();
        await a.add('sam');
        await _settle();
      });
      await show(tester, b, await tester.runAsync(() => me('sam')) as Me);
      expect(find.text('@maya, not checked with the relay yet'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('accept-maya')));
      await settle(tester);
      expect(find.textContaining('can\'t be checked with the relay server right now'), findsOneWidget);
      expect(b.friends, isEmpty);
      await tester.pump(const Duration(seconds: 7));
    });

    Future<void> drawer(WidgetTester tester, Buddies b, Me m) async {
      final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
      await tester.pumpWidget(WidgetsApp(
        color: const Color(0xFF4F5BD5),
        pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder w) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => w(c)),
        builder: (context, child) => GlacierTheme(sheet: sheet, attrs: const {'platform': 'mobile'}, child: GlacierToastProvider(child: child!)),
        home: AddFriendDrawer(buddies: b, me: m),
      ));
      await tester.pump();
    }

    /// Types [words] into the drawer and lets the look-up (a short wait, then the server) answer.
    Future<void> type(WidgetTester tester, String words) async {
      await tester.enterText(find.byType(EditableText), words);
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
    }

    // Matt, 2026-11-16: "move the Add button to the side of search and have it open a drawer to search and add users
    // as well as setup username if hasn't been done already".
    testWidgets('the drawer looks a username up as it is typed, and Add asks them', (tester) async {
      final world = _World();
      final a = Buddies(_Port(world, 'maya')), b = Buddies(_Port(world, 'sam'));
      await tester.runAsync(() async {
        await a.start();
        await b.start();
      });
      await drawer(tester, a, await tester.runAsync(() => me('maya')) as Me);
      expect(find.text('Add a friend'), findsOneWidget);
      await type(tester, '@nobody');
      expect(find.text('Nobody has this username'), findsOneWidget);
      expect(find.byKey(const ValueKey('add-found')), findsNothing);
      await type(tester, '@maya');
      expect(find.text('That\'s you'), findsOneWidget);
      await type(tester, '@sam');
      expect(find.text('On Uplink'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('add-found')));
      await settle(tester);
      expect(find.text('Friend request sent'), findsOneWidget);
      expect(b.requests.single.username, 'maya', reason: 'Sam sees the request');
      await tester.pump(const Duration(seconds: 7));
    });

    testWidgets('without a username of your own the drawer has one chosen first', (tester) async {
      final b = Buddies(_Port(_World(), 'maya'));
      await tester.runAsync(b.start);
      await drawer(tester, b, await tester.runAsync(() => me(null)) as Me);
      expect(find.text('Choose your username'), findsOneWidget);
      expect(find.byKey(const ValueKey('username-field')), findsOneWidget);
      expect(find.text('Add a friend'), findsNothing);
      await tester.enterText(find.byType(EditableText), 'x');
      await tester.tap(find.byKey(const ValueKey('claim-username')));
      await tester.pump();
      expect(find.textContaining('3 to 20 letters'), findsOneWidget);
    });

    testWidgets('the list keeps the requests and friends, and no field of its own', (tester) async {
      final b = Buddies(_Port(_World(), 'maya'));
      await tester.runAsync(b.start);
      await show(tester, b, await tester.runAsync(() => me(null)) as Me);
      expect(find.byType(EditableText), findsNothing);
    });
  });
}
