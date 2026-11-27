import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/groups.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/network.dart' show peerLabel;

import 'support/fake_groups.dart';

// Groups of friends (lib/friends/groups.dart) among phones that are not there: each has a stand-in for the routes
// and the phone (test/support/fake_groups.dart). Ann is friends with Ben, Cat and Dan; none of those three is a
// friend of another, so what passes between them passes because they are in a group together.

const ann = '+15550001', ben = '+15550002', cat = '+15550003', dan = '+15550004', eve = '+15550005';

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late World world;
  late Map<String, FakeGroupsPort> port;
  late Map<String, Groups> phone;

  setUp(() async {
    world = World();
    port = {for (final n in [ann, ben, cat, dan, eve]) n: FakeGroupsPort(world, n)};
    for (final n in [ben, cat, dan]) {
      port[ann]!.friends.add(n);
      port[n]!.friends.add(ann);
    }
    phone = {for (final e in port.entries) e.key: Groups(e.value)};
    for (final g in phone.values) {
      await g.start();
    }
  });

  tearDown(() async {
    for (final g in phone.values) {
      await g.shutdown();
    }
  });

  /// Ann's group "Crew" with Ben and Cat, everyone told.
  Future<String> crew() async {
    final g = await phone[ann]!.create('Crew', [ben, cat]);
    await settle();
    return g.id;
  }

  test('a group is made out of friends, and each of them has it', () async {
    final id = await crew();
    for (final n in [ann, ben, cat]) {
      final g = phone[n]!.of(id)!;
      expect(g.name, 'Crew', reason: n);
      expect(g.members.map((m) => m.address).toSet(), {if (n == ann) '' else ann, ben, cat}, reason: 'Ann\'s number is known to the others by her having sent it');
      expect(g.members.where((m) => m.admin).map((m) => m.id), [port[ann]!.me]);
      expect(g.mine!.id, port[n]!.me);
    }
    expect(phone[ann]!.of(id)!.amAdmin, isTrue);
    expect(phone[ben]!.of(id)!.amAdmin, isFalse);
    expect(port[ann]!.lines[id], ['* You made the group "Crew"']);
    expect(port[ben]!.lines[id], ['* $ann added you to "Crew"']);
    // It is its own conversation on each phone.
    expect(phone[ben]!.ofThread(phone[ben]!.of(id)!.thread)!.id, id);
  });

  test('what one member writes reaches the others, friends of theirs or not', () async {
    final id = await crew();
    expect(await phone[ben]!.sendText(id, 'Hike on Saturday?'), isTrue);
    await settle();
    expect(port[ann]!.lines[id]!.last, '$ben: Hike on Saturday?');
    expect(port[cat]!.lines[id]!.last, '$ben: Hike on Saturday?', reason: 'Ben and Cat never exchanged keys: the group is how they reach each other');
    expect(port[ben]!.rows.values.single, (group: id, words: 'Hike on Saturday?', state: 'sent'));
    // One envelope to each of the other two, of kind group.
    final texts = port[ben]!.sent.where((s) => s.envelope.body['do'] == 'text').toList();
    expect(texts.map((s) => s.to).toSet(), {port[ann]!.me, port[cat]!.me});
    expect(texts.every((s) => s.envelope.kind == 'group'), isTrue);
  });

  test('an admin names it; a member cannot, and a state from one is not taken', () async {
    final id = await crew();
    await phone[ann]!.rename(id, 'Weekend crew');
    await settle();
    expect(phone[cat]!.of(id)!.name, 'Weekend crew');
    expect(port[cat]!.lines[id]!.last, '* $ann named the group "Weekend crew"');
    expect(() => phone[ben]!.rename(id, 'Mine now'), throwsStateError);
    // Ben's phone says it anyway, as if it were an admin: nobody takes it.
    final forged = phone[ben]!.of(id)!.state(name: 'Mine now', v: 99, admins: [port[ben]!.me])..remove('id');
    await port[ben]!.send(port[ben]!.peer(port[cat]!.me)!, Envelope(kind: 'group', body: {'g': id, 'do': 'state', 's': forged}));
    await settle();
    expect(phone[cat]!.of(id)!.name, 'Weekend crew');
    expect(phone[cat]!.of(id)!.members.where((m) => m.admin).single.id, port[ann]!.me);
  });

  test('a member is added and another taken out', () async {
    final id = await crew();
    await phone[ann]!.add(id, dan);
    await settle();
    expect(phone[dan]!.of(id)!.members.length, 4);
    expect(port[dan]!.lines[id], ['* $ann added you to "Crew"']);
    expect(port[ben]!.lines[id]!.last, '* $ann added $dan');
    // Dan, a friend of Ann alone, now reaches Ben through the group.
    expect(await phone[dan]!.sendText(id, 'Hello all'), isTrue);
    await settle();
    expect(port[ben]!.lines[id]!.last, '$dan: Hello all');
    // Ben is taken out: his phone keeps the conversation and can write in it no more; nothing of his is taken.
    await phone[ann]!.remove(id, port[ben]!.me);
    await settle();
    expect(phone[ben]!.of(id)!.gone, isTrue);
    expect(port[ben]!.lines[id]!.last, '* $ann removed you');
    expect(port[cat]!.lines[id]!.last, '* $ann removed $ben');
    expect(phone[cat]!.of(id)!.member(port[ben]!.me), isNull);
    expect(await phone[ben]!.sendText(id, 'Still here?'), isFalse);
    final before = port[cat]!.lines[id]!.length;
    await port[ben]!.send(peerOf(port[cat]!), Envelope(kind: 'group', body: {'g': id, 'do': 'text', 't': 'Let me in'}));
    await settle();
    expect(port[cat]!.lines[id]!.length, before);
    // And he can be added again, by the friend who is its admin.
    await phone[ann]!.add(id, ben);
    await settle();
    expect(phone[ben]!.of(id)!.gone, isFalse);
    expect(port[ben]!.lines[id]!.last, '* $ann added you to "Crew"');
  });

  test('an admin makes another, who can then change the group', () async {
    final id = await crew();
    await phone[ann]!.setAdmin(id, port[cat]!.me, true);
    await settle();
    expect(phone[cat]!.of(id)!.amAdmin, isTrue);
    expect(port[ben]!.lines[id]!.last, '* $ann made $cat an admin');
    await phone[cat]!.rename(id, 'Cat\'s crew');
    await settle();
    expect(phone[ann]!.of(id)!.name, 'Cat\'s crew');
    expect(phone[ben]!.of(id)!.name, 'Cat\'s crew');
  });

  test('a member leaves; where the only admin leaves, the same member is made one on every phone', () async {
    final id = await crew();
    await phone[ben]!.leave(id);
    await settle();
    expect(phone[ben]!.of(id)!.gone, isTrue);
    expect(phone[ann]!.of(id)!.member(port[ben]!.me), isNull);
    expect(port[cat]!.lines[id]!.last, '* $ben left');
    await phone[ann]!.add(id, dan);
    await settle();
    await phone[ann]!.leave(id);
    await settle();
    final first = ([port[cat]!.me, port[dan]!.me]..sort()).first;
    expect(phone[cat]!.of(id)!.members.where((m) => m.admin).single.id, first);
    expect(phone[dan]!.of(id)!.members.where((m) => m.admin).single.id, first);
  });

  test('a group is joined only at a friend\'s asking, and an older state is not taken', () async {
    // Eve, nobody's friend, makes a group with Ben in it by hand and tells him: his phone does not take it.
    port[eve]!.friends.add(ben);
    final hers = await phone[eve]!.create('Free prizes', [ben]);
    await settle();
    expect(phone[ben]!.of(hers.id), isNull);
    // An admin's older word does not undo a newer one.
    final id = await crew();
    final old = phone[ann]!.of(id)!.state()..remove('id');
    await phone[ann]!.rename(id, 'Newer');
    await settle();
    await port[ann]!.send(port[ann]!.peer(port[ben]!.me)!, Envelope(kind: 'group', body: {'g': id, 'do': 'state', 's': old}));
    await settle();
    expect(phone[ben]!.of(id)!.name, 'Newer');
  });

  test('with no route up nothing is sent or kept; a member who is away is kept for and woken', () async {
    final id = await crew();
    port[ben]!.up = false;
    expect(await phone[ben]!.sendText(id, 'hello?'), isFalse);
    expect(port[ben]!.rows, isEmpty);
    expect(phone[ben]!.online, isFalse);
    port[ben]!.up = true;
    port[cat]!.here = false;
    expect(await phone[ben]!.sendText(id, 'Cat is away'), isTrue);
    await settle();
    expect(port[ben]!.woken, [port[cat]!.me]);
    expect(port[cat]!.lines[id]!.where((l) => l.contains('Cat is away')), isEmpty);
    port[cat]!.back();
    await settle();
    expect(port[cat]!.lines[id]!.last, '$ben: Cat is away');
  });

  // The review's follow-up (2026-11-23): in the group's own conversation a stranger listed under Mom's number was shown as
  // Mom. A member is shown as this phone knows them (android Groups.shownAddress: Groups.view says it as `shown`), and the
  // record keeps the address the admin wrote, for what this phone tells the others when it changes the group.
  group('what a member was not handed (a route that is up need not reach everyone)', () {
    /// What [from] wrote in the group, as [at]'s conversation has it.
    List<String> said(String at, String id, String from) => [
          for (final l in port[at]!.lines[id] ?? const <String>[])
            if (l.startsWith('$from: ')) l.substring(from.length + 2),
        ];

    /// The routes changed on [who]'s phone, and what is owed has had its moment to go.
    Future<void> changed(String who) async {
      port[who]!.routesChanged();
      await Future<void>.delayed(const Duration(milliseconds: 450));
    }

    test('is owed to them, and goes once a route reaches them: in the order it was written, once, under the name it first had', () async {
      final id = await crew();
      // No relay, and the local network linked to Ben's phone alone: no route takes what is for Cat.
      port[ann]!.unreached.add(port[cat]!.me);
      expect(await phone[ann]!.sendText(id, 'one'), isTrue);
      expect(await phone[ann]!.sendText(id, 'two'), isTrue);
      await settle();
      expect([said(ben, id, ann), said(cat, id, ann)], [['one', 'two'], isEmpty]);
      expect(port[ann]!.rows.values.map((r) => r.state), ['sent', 'sent'], reason: 'handed to someone');
      expect(phone[ann]!.owedCount, 2, reason: 'it said sent, and Cat never had it');
      // The routes change, and she still can't be reached: it waits.
      await changed(ann);
      expect([said(cat, id, ann), phone[ann]!.owedCount], [isEmpty, 2]);
      // Her phone comes onto the network.
      port[ann]!.unreached.clear();
      await changed(ann);
      expect([said(cat, id, ann), said(ben, id, ann), phone[ann]!.owedCount], [['one', 'two'], ['one', 'two'], 0]);
      // Each went again as the very thing it was: the same name and the same time, so a phone that had it after all
      // keeps it once.
      final toCat = [for (final x in port[ann]!.sent) if (x.to == port[cat]!.me && x.envelope.body['do'] == 'text') x.envelope];
      // (While she could not be reached the first was tried again and the second waited behind it.)
      expect(toCat.map((e) => e.body['t']), ['one', 'two', 'one', 'one', 'two']);
      expect([toCat[0].id == toCat[2].id, toCat[2].id == toCat[3].id, toCat[0].at == toCat[3].at, toCat[1].id == toCat[4].id, toCat[1].at == toCat[4].at, toCat[0].id == toCat[1].id], [true, true, true, true, true, false]);
      // And nothing more of it after.
      await changed(ann);
      expect(said(cat, id, ann), ['one', 'two']);
    });

    test('is still owed after the app is closed and opened again', () async {
      final id = await crew();
      port[ann]!.unreached.add(port[cat]!.me);
      await phone[ann]!.sendText(id, 'kept');
      await settle();
      await phone[ann]!.shutdown();
      expect(port[ann]!.keptOwed, contains('kept'));
      port[ann]!.unreached.clear();
      phone[ann] = Groups(port[ann]!);
      await phone[ann]!.start();
      await settle();
      expect([said(cat, id, ann), phone[ann]!.owedCount], [['kept'], 0], reason: 'tried as the app starts');
      expect(port[ann]!.keptOwed, '[]');
    });

    test('handed to nobody, it failed and nothing is owed: it is the person\'s to send again', () async {
      final id = await crew();
      port[ann]!.unreached.addAll([port[ben]!.me, port[cat]!.me]);
      expect(await phone[ann]!.sendText(id, 'anyone?'), isTrue);
      await settle();
      expect([port[ann]!.rows.values.single.state, phone[ann]!.owedCount], ['failed', 0]);
      port[ann]!.unreached.clear();
      await changed(ann);
      expect([said(ben, id, ann), said(cat, id, ann)], [isEmpty, isEmpty]);
    });

    test('is let go after a week, and words are not sent to someone no longer in the group', () async {
      final id = await crew();
      port[ann]!.unreached.add(port[cat]!.me);
      await phone[ann]!.sendText(id, 'stale');
      await settle();
      expect(phone[ann]!.owedCount, 1);
      phone[ann]!.clock = () => DateTime.now().add(Groups.owedFor + const Duration(hours: 1));
      port[ann]!.unreached.clear();
      await changed(ann);
      expect([said(cat, id, ann), phone[ann]!.owedCount], [isEmpty, 0]);

      // Words for Cat, who is then taken out of the group before a route reaches her: she is told she is out (that is
      // owed too), and never has the words.
      phone[ann]!.clock = DateTime.now;
      port[ann]!.unreached.add(port[cat]!.me);
      await phone[ann]!.sendText(id, 'not for her');
      await phone[ann]!.remove(id, port[cat]!.me);
      await settle();
      expect(phone[ann]!.owedCount, 2);
      port[ann]!.unreached.clear();
      await changed(ann);
      expect([said(cat, id, ann), phone[ann]!.owedCount, said(ben, id, ann)], [isEmpty, 0, ['stale', 'not for her']]);
      expect(phone[cat]!.of(id)!.gone, isTrue, reason: 'her phone learned she was taken out, late');
    });

    test('a change to the group is owed as the group then is', () async {
      final id = await crew();
      port[ann]!.unreached.add(port[cat]!.me);
      await phone[ann]!.rename(id, 'Crew 2');
      await phone[ann]!.rename(id, 'Crew 3');
      await settle();
      expect([phone[ben]!.of(id)!.name, phone[cat]!.of(id)!.name, phone[ann]!.owedCount], ['Crew 3', 'Crew', 1], reason: 'one change owed, not two');
      final before = port[ann]!.sent.length;
      port[ann]!.unreached.clear();
      await changed(ann);
      expect([phone[cat]!.of(id)!.name, phone[ann]!.owedCount, port[ann]!.sent.length - before], ['Crew 3', 0, 1]);
    });
  });

  test('a member is shown as this phone knows them, and the group\'s record keeps what its admin wrote', () {
    final g = Group.from({
      'id': 'f' * 32,
      'name': '',
      'v': 1,
      'thread': 3,
      'members': [
        {'id': 'a' * 32, 'key': 'k1', 'address': '', 'me': true, 'admin': true},
        // Listed under Mom's number, whose record names another key: shown under a stand-in that is nobody's.
        {'id': 'e' * 32, 'key': 'k2', 'address': '+15550002222', 'shown': '${'e' * 32}@member.ghost-sms.com', 'name': 'Someone · eeee'},
        // Ben, listed under another number of his: shown under the one this phone's record has for his key.
        {'id': 'b' * 32, 'key': 'k3', 'address': '+15550009999', 'shown': '+15550001111', 'name': 'Ben'},
      ],
    });
    final eve = g.member('e' * 32)!, benM = g.member('b' * 32)!;
    expect([eve.label, eve.standIn, eve.person.address], ['Someone · eeee', true, '${'e' * 32}@member.ghost-sms.com']);
    expect([benM.label, benM.standIn, benM.person.address], ['Ben', false, '+15550001111']);
    expect(g.title, 'Someone, Ben', reason: 'first names, as a group\'s title has them');
    expect([for (final m in (g.state()['members'] as List).cast<Map>()) m['a']], ['', '+15550002222', '+15550009999']);
    // A view that says nothing of it (the screens' pictures): as listed.
    expect(GroupMember.from({'id': 'x', 'address': '+15550003333'}).shown, '+15550003333');
  });

  // The review's follow-up (2026-11-23): Settings › Network's row for someone whose address is none here was blank.
  test('one of the routes\' people with no address known here is called after their group, else their install\'s name', () {
    final crew = Group.from({
      'id': 'f' * 32,
      'name': 'Crew',
      'v': 1,
      'thread': 3,
      'members': [
        {'id': 'a' * 32, 'key': 'k', 'me': true},
        {'id': 'e' * 32, 'key': 'k'},
      ],
    });
    expect(peerLabel(const Peer(id: 'b0b0b0b0b0b0', address: '+15550001111', name: 'Ben'), groups: [crew]), 'Ben');
    expect(peerLabel(const Peer(id: 'b0b0b0b0b0b0', address: '+15550001111'), groups: [crew]), '+15550001111');
    expect(peerLabel(Peer(id: 'e' * 32, address: ''), groups: [crew]), 'A member of Crew');
    expect(peerLabel(const Peer(id: 'c0c0c0c0c0c0c0c0', address: '', name: ''), groups: [crew]), 'c0c0c0c0');
  });
}

/// A phone as the routes name it, for sending to one by hand in a test.
Peer peerOf(FakeGroupsPort p) => Peer(id: p.me, address: p.number);
