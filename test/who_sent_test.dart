import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/friends/groups.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/packet.dart';

import 'support/direct_world.dart' show PlainCarrier;

// Who sent something, and where something goes, as the app decides it (found in review, 2026-11-23): the real routes
// (lib/net/net.dart, the switchboard, its sealing), Friends and Groups as the app holds them, and the phone under them
// a stand-in channel answering as Android does.
//
// On Android the people the routes reach are those encryption is on with, the members of this phone's groups and friends
// by username, in that order (MainActivity's netPeers), and a member of a group is there under whatever address the
// group's admin wrote. Here an admin wrote Eve under Ben's number and Ivy as "@maya". Ben is a friend by number and Maya
// a friend by username; each of the four has a key of their own, and only what is sealed with that key opens as theirs.

const benNumber = '+15550002222';

/// Waits for [ok], however long a busy machine takes (ten seconds at most), not for a length of time.
Future<void> until(bool Function() ok, String what) async {
  for (var i = 0; i < 2000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = NetKeys.generate(), ben = NetKeys.generate(), maya = NetKeys.generate(), eve = NetKeys.generate(), ivy = NetKeys.generate();
  Uint8List keyWith(NetKeys them) => NetCrypto.netKey(NetCrypto.conversationKey(me, them.public)!);
  String named(String id) => {me.id: 'me', ben.id: 'Ben', maya.id: 'Maya', eve.id: 'Eve', ivy.id: 'Ivy'}[id] ?? id;

  late List<Map<String, Object?>> peers;
  late List<Map<String, Object?>> e2e;
  late List<({String address, String words})> textsIn;
  late List<({String address, String state})> friendSets;
  late Map<int, String> rowStates;
  late List<Map<String, dynamic>> joined;
  late PlainCarrier hub;
  late Friends friends;
  late Groups groups;

  /// A member of a group as Groups.peers gives one, under [address]; one encryption is on with as Net.peers does.
  Map<String, Object?> peer(NetKeys who, String address) => {'id': who.id, 'address': address, 'key': keyWith(who)};

  setUp(() {
    HttpOverrides.global = null;
    // Android's netPeers as it was: encryption records, then group members, then friends by username, each id once.
    peers = [peer(ben, benNumber), peer(eve, benNumber), peer(ivy, '@maya'), peer(maya, '@maya')];
    // What e2eList answers on the phone: its encryption records, then friends by username (lib/standalone/overlay.dart),
    // each naming the install its key makes.
    e2e = [
      {'address': benNumber, 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': ben.id},
      {'address': '@maya', 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': maya.id, 'others': <String>[]},
    ];
    textsIn = [];
    friendSets = [];
    rowStates = {};
    joined = [];
    var rows = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final a = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (a['message'] as List).cast<int>());
        case 'netPeers':
          return peers;
        case 'e2eList':
          return e2e;
        case 'netSmsDrain':
          return const <Object>[];
        case 'friendSet':
          friendSets.add((address: '${a['address']}', state: '${a['state']}'));
          return null;
        case 'netTextIn':
          textsIn.add((address: '${a['address']}', words: '${a['body']}'));
          return null;
        case 'netTextOut':
          return ++rows;
        case 'netTextState':
          rowStates[(a['id'] as num).toInt()] = '${a['state']}';
          return null;
        case 'groups':
          return [for (final s in joined) _view(s, me.id)];
        case 'groupSave':
          final s = (jsonDecode('${a['state']}') as Map).cast<String, dynamic>();
          joined.add(s);
          return _view(s, me.id);
      }
      return null;
    });
  });

  /// The routes set up, over a relay's route that carries whatever it is given, and Friends and Groups as the app has them.
  Future<void> open() async {
    hub = PlainCarrier('hub');
    await Net.instance.start(AppState(), carriers: [hub]);
    Friends.instance = null;
    friends = Friends.instance;
    await friends.start();
    Groups.instance = null;
    groups = Groups.instance;
    await groups.start();
  }

  tearDown(() async {
    await friends.shutdown();
    Friends.instance = null;
    await groups.shutdown();
    Groups.instance = null;
    await Net.instance.shutdown();
  });

  /// [envelope] comes by the relay, sealed with [from]'s key: only they could have sent it.
  void arrive(NetKeys from, Envelope envelope) => hub.take(Packet.wrap(from: from.id, sealed: true, payload: NetCrypto.seal(keyWith(from), envelope.encode())), from: from.id);

  /// The words of each friend's text the relay was handed for [who], as only [who]'s key opens them.
  List<String> textsTo(NetKeys who) => [
        for (final (i, to) in hub.to.indexed)
          if (to == who.id)
            if (Packet.parse(hub.carried[i]) case final p? when p.sealed && !p.fs)
              if (NetCrypto.open(keyWith(who), p.payload) case final clear?)
                if (Envelope.decode(clear) case final e? when e.kind == 'text') '${e.body['t']}',
      ];

  /// What was said about being friends to [who], sealed for them alone.
  List<String> friendWordsTo(NetKeys who) => [
        for (final (i, to) in hub.to.indexed)
          if (to == who.id)
            if (Packet.parse(hub.carried[i]) case final p? when p.sealed && !p.fs)
              if (NetCrypto.open(keyWith(who), p.payload) case final clear?)
                if (Envelope.decode(clear) case final e? when e.kind == 'friend') '${e.body['do']}',
      ];

  test('a member of a group listed under a friend\'s number is not that friend: what they write is not kept as his, and what they say does not change where he stands', () async {
    await open();
    arrive(eve, Envelope(kind: 'text', body: {'t': 'It\'s Ben, on a new phone'}));
    arrive(eve, Envelope(kind: 'friend', body: {'do': 'end'}));
    // Ben himself, after: kept as his.
    arrive(ben, Envelope(kind: 'text', body: {'t': 'Ben here'}));
    await until(() => textsIn.isNotEmpty, 'Ben\'s words kept');
    await until(() => friendWordsTo(eve).isNotEmpty, 'Eve told');
    await pumpEventQueue(times: 50);
    expect(textsIn, [(address: benNumber, words: 'Ben here')], reason: 'Eve\'s words are nobody\'s here');
    expect(friendSets, isEmpty, reason: 'Eve\'s "end" is not Ben\'s');
    expect(friends.isFriend(benNumber), isTrue);
    // Eve was answered "end", sealed for her key, so her app stops writing as a friend's (the review's follow-up); her
    // own "end" was not answered, and Ben, a friend, was told nothing.
    expect(friendWordsTo(eve), ['end']);
    expect(friendWordsTo(ben), isEmpty);
  });

  test('a member of a group listed as "@maya" is not the friend by username Maya', () async {
    await open();
    arrive(ivy, Envelope(kind: 'text', body: {'t': 'Maya here, new account'}));
    arrive(ivy, Envelope(kind: 'friend', body: {'do': 'end'}));
    arrive(maya, Envelope(kind: 'text', body: {'t': 'The real Maya'}));
    await until(() => textsIn.isNotEmpty, 'Maya\'s words kept');
    await pumpEventQueue(times: 50);
    expect(textsIn, [(address: '@maya', words: 'The real Maya')]);
    expect(friendSets, isEmpty);
    expect(friends.isFriend('@maya'), isTrue);
  });

  test('what is written to a friend goes to the install their record names, sealed with its key, never to someone listed under their address', () async {
    await open();
    expect(await friends.sendText('@maya', 'For Maya only'), isTrue);
    expect(await friends.sendText(benNumber, 'For Ben only'), isTrue);
    await until(() => textsTo(maya).isNotEmpty && textsTo(ben).isNotEmpty, 'sent, each sealed for the friend: carried to ${hub.to.map(named).toList()}');
    expect(textsTo(maya), ['For Maya only']);
    expect(textsTo(ben), ['For Ben only']);
    expect([...textsTo(ivy), ...textsTo(eve)], isEmpty, reason: 'nothing written to a friend reaches anyone listed under their address');
  });

  test('a key changed under a friend\'s number: what waits for his answer is not sent again to whoever else is listed under it', () async {
    await open();
    expect(await friends.sendText(benNumber, 'Are you there?'), isTrue);
    await until(() => friends.unanswered == 1, 'waiting for Ben\'s app to say it has it');
    // A different key comes from Ben's number (a new phone, or someone sending texts in his name): his record waits for
    // the person's yes, he is a friend no longer until then, and the routes no longer have him. A group still lists Eve
    // under his number.
    final other = NetKeys.generate();
    e2e[0] = {'address': benNumber, 'state': 'pending', 'changed': true, 'friend': '', 'hasGhost': true, 'id': other.id};
    peers.removeAt(0);
    await Net.instance.refresh();
    // Friends reads where everyone stands again, and sends again what waits for an answer.
    await until(() => friends.of(benNumber)?.state == 'pending', 'read again');
    for (var i = 0; i < 100 && textsTo(eve).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(textsTo(eve), isEmpty, reason: 'Ben\'s words are never sealed for Eve');
    expect(textsTo(ben), ['Are you there?'], reason: 'sent to Ben once, and to nobody since');
    // And it is said to have failed now, the record naming another key (the review's follow-up), not three days on.
    expect(rowStates.values, contains('failed'));
    expect(friends.unanswered, 0);
  });

  test('a group is joined at a friend\'s asking, by the key that sealed it: not at the asking of someone listed under a friend\'s address', () async {
    await open();
    Map<String, Object?> state(NetKeys admin, String name) => {
          'g': NetCrypto.hex(NetCrypto.randomBytes(16)),
          'do': 'state',
          's': {
            'name': name,
            'v': 1,
            'members': [
              {'i': admin.id, 'k': base64Encode(admin.public), 'a': ''},
              {'i': me.id, 'k': base64Encode(me.public), 'a': ''},
            ],
            'admins': [admin.id],
          },
        };
    arrive(eve, Envelope(kind: 'group', body: state(eve, 'Ben\'s party')));
    arrive(ivy, Envelope(kind: 'group', body: state(ivy, 'Maya\'s party')));
    // Ben and Maya, after: joined, and each known by their own record's address.
    arrive(ben, Envelope(kind: 'group', body: state(ben, 'Hike')));
    arrive(maya, Envelope(kind: 'group', body: state(maya, 'Dinner')));
    await until(() => joined.length >= 2, 'Ben\'s and Maya\'s groups joined');
    await pumpEventQueue(times: 50);
    expect(joined.map((s) => s['name']).toList(), ['Hike', 'Dinner']);
    String addressIn(Map<String, dynamic> s, NetKeys who) => '${(s['members'] as List).cast<Map>().firstWhere((m) => m['i'] == who.id)['a']}';
    expect(addressIn(joined[0], ben), benNumber);
    expect(addressIn(joined[1], maya), '@maya');
    expect(groups.all.map((g) => g.name).toSet(), {'Hike', 'Dinner'});
  });

  test('a friend by username who is in a group too is heard, and written to, as that friend: whatever address the routes have for them', () async {
    // As Android's list had it: the group's entry for Maya came first, under the address the group gave her, and her
    // own entry as a friend by username was left out.
    peers = [peer(ben, benNumber), peer(maya, '')];
    await open();
    arrive(maya, Envelope(kind: 'text', body: {'t': 'Hi from Maya'}));
    await until(() => textsIn.isNotEmpty, 'kept');
    expect(textsIn, [(address: '@maya', words: 'Hi from Maya')]);
    expect(await friends.sendText('@maya', 'Hi Maya'), isTrue);
    await until(() => textsTo(maya).isNotEmpty, 'sent to Maya');
    expect(textsTo(maya), ['Hi Maya']);
  });

  // From the independent review of this fix (2026-11-23), its probe 1: usernames may hold digits (Me.goodUsername), and a
  // friend request's username was taken as written. Friends.digits read "@ben.5550002222" as Ben's number, so the
  // username's record stood in for Ben's.
  test('a friend by username whose username holds a friend\'s number\'s digits is not that friend: what is written to him goes to him, and his own words are kept as his', () async {
    peers = [peer(ben, benNumber), peer(eve, '@ben.5550002222')];
    e2e = [
      {'address': benNumber, 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': ben.id},
      {'address': '@ben.5550002222', 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': eve.id, 'others': <String>[]},
    ];
    await open();
    expect(await friends.sendText(benNumber, 'For Ben only'), isTrue);
    await until(() => textsTo(ben).isNotEmpty || textsTo(eve).isNotEmpty, 'sent');
    arrive(ben, Envelope(kind: 'text', body: {'t': 'Ben here'}));
    arrive(eve, Envelope(kind: 'text', body: {'t': 'The username'}));
    await until(() => textsIn.length >= 2, 'both kept');
    expect(textsTo(ben), ['For Ben only']);
    expect(textsTo(eve), isEmpty);
    expect(textsIn.toSet(), {(address: benNumber, words: 'Ben here'), (address: '@ben.5550002222', words: 'The username')});
  });

  // The review's probe 8 (its second round): a friend by username's "end" (or "no") marked them no friend here until the
  // records were read again, and nothing written to them went meanwhile. Where two stand is Buddies' to say.
  test('a friend by username\'s "end" or "no" leaves them a friend here, and what is written to them goes', () async {
    final matt = NetKeys.generate();
    peers = [peer(matt, '@matt')];
    e2e = [
      {'address': '@matt', 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': matt.id, 'others': <String>[]},
    ];
    await open();
    arrive(matt, Envelope(kind: 'friend', body: {'do': 'end'}));
    arrive(matt, Envelope(kind: 'friend', body: {'do': 'no'}));
    arrive(matt, Envelope(kind: 'text', body: {'t': 'after the end'}));
    await until(() => textsIn.isNotEmpty, 'his words kept');
    expect(friends.isFriend('@matt'), isTrue);
    expect(await friends.sendText('@matt', 'still there?'), isTrue);
    await until(() => textsTo(matt).isNotEmpty, 'sent to him');
    expect(friendSets, isEmpty);
  });

  // The review's probes 2, 3 and 5: one person, one phone and its one key, with encryption on here under two of their
  // numbers (two SIMs, or a number they moved to and sent the key from again). Both records name the key; the two were
  // said to be nobody's and everything from it dropped, while their phone was told it had arrived.
  group('one key on two of a friend\'s numbers', () {
    const benOther = '+15550007777';
    setUp(() => peers = [peer(ben, benNumber), peer(ben, benOther)]);

    test('both friends here: what they write is kept, under one of the two, the same one each time', () async {
      e2e = [
        {'address': benOther, 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': ben.id},
        {'address': benNumber, 'state': 'on', 'friend': 'yes', 'hasGhost': true, 'id': ben.id},
      ];
      await open();
      arrive(ben, Envelope(kind: 'text', body: {'t': 'Ben here'}));
      arrive(ben, Envelope(kind: 'text', body: {'t': 'Still Ben'}));
      await until(() => textsIn.length >= 2, 'kept');
      expect(textsIn.map((t) => t.words), ['Ben here', 'Still Ben']);
      expect(textsIn.map((t) => t.address).toSet(), hasLength(1));
    });

    test('neither a friend yet: their friend request is heard', () async {
      e2e = [
        {'address': benNumber, 'state': 'on', 'friend': '', 'hasGhost': true, 'id': ben.id},
        {'address': benOther, 'state': 'on', 'friend': '', 'hasGhost': true, 'id': ben.id},
      ];
      await open();
      arrive(ben, Envelope(kind: 'friend', body: {'do': 'ask'}));
      await until(() => friendSets.isNotEmpty, 'heard');
      expect(friendSets.map((s) => s.state), ['invited']);
    });

    test('this phone asked from one of the two: their yes is heard there, and what they write after it is kept', () async {
      e2e = [
        {'address': benOther, 'state': 'on', 'friend': '', 'hasGhost': true, 'id': ben.id},
        {'address': benNumber, 'state': 'on', 'friend': 'asked', 'hasGhost': true, 'id': ben.id},
      ];
      await open();
      arrive(ben, Envelope(kind: 'friend', body: {'do': 'yes'}));
      arrive(ben, Envelope(kind: 'text', body: {'t': 'Now we are friends'}));
      await until(() => textsIn.isNotEmpty, 'kept');
      await pumpEventQueue(times: 50);
      expect(friendSets.map((s) => '${s.address} ${s.state}'), ['$benNumber yes']);
      expect(textsIn, [(address: benNumber, words: 'Now we are friends')]);
    });
  });
}

/// A group as android Groups.view gives one, from the state kept.
Map<String, Object?> _view(Map<String, dynamic> s, String me) {
  final admins = (s['admins'] as List).cast<String>();
  return {
    'id': s['id'],
    'name': s['name'] ?? '',
    'v': s['v'] ?? 1,
    'thread': 9,
    'gone': s['gone'] == true,
    'members': [
      for (final m in (s['members'] as List).cast<Map>()) {'id': m['i'], 'key': m['k'], 'address': m['a'], 'admin': admins.contains(m['i']), 'me': m['i'] == me},
    ],
  };
}
