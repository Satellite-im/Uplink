import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/invites.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:test/test.dart';

/// Invites waiting for someone not on the app yet (invites.dart; Matt, 2026-11-17: "a link that eventually follows
/// through after they setup their account").

const alice = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
const bob = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';
const carol = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3';

final hers = Handles.keyOf('phone', '+15550100199');
final his = Handles.keyOf('phone', '+15550100142');

void main() {
  late Directory dir;
  late DateTime clock;
  late Map<String, String> verified;
  late Map<String, String> someone;
  late Invites inv;
  late Map<String, List<Map<String, Object?>>> heard;

  Invites make() => Invites(dataDir: dir, phoneKeyOf: (id) => verified[id], whoOf: (id) => someone[id], now: () => clock)..load();
  void say(Invites to, String id, Map<String, Object?> what) => to.said(id, what, (m) => (heard[id] ??= []).add(m));
  Map<String, Object?> last(String id) => heard[id]!.last;
  Map<String, Object?> leave(String h, String b, {String? t}) => {'h': h, 'b': b, 't': ?t};

  setUp(() {
    dir = Directory.systemTemp.createTempSync('invites');
    clock = DateTime.utc(2026, 11, 17, 12);
    verified = {};
    // Everyone who leaves invites here is someone (a verified number or a linked account), each a different one.
    someone = {alice: 'phone|alice', bob: 'phone|bob', carol: 'phone|carol'};
    heard = {};
    inv = make();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('left by someone, taken only by the install that verified the number', () {
    say(inv, alice, {'dir': 'invite', 'list': [leave(hers, 'c2VhbGVkMQ=='), leave(his, 'c2VhbGVkMg==')]});
    expect(last(alice), {'dir': 'invite', 'left': 2});
    expect(inv.waiting, 2);

    // Bob has verified no number: he cannot look, whichever hash he names.
    say(inv, bob, {'dir': 'invites', 'h': hers});
    expect(last(bob), containsPair('err', 'Verify this number first.'));
    // Bob verified his own: he sees his, and still not hers.
    verified[bob] = his;
    say(inv, bob, {'dir': 'invites', 'h': hers});
    expect(last(bob)['dir'], 'err');
    say(inv, bob, {'dir': 'invites', 'h': his});
    final bobs = last(bob)['list'] as List;
    expect(bobs, hasLength(1));
    expect((bobs.single as Map)['b'], 'c2VhbGVkMg==');

    // Carol verified hers: she sees hers, drops it once offered, and it is gone.
    verified[carol] = hers;
    say(inv, carol, {'dir': 'invites', 'h': hers});
    final list = last(carol)['list'] as List;
    expect(list, hasLength(1));
    final id = (list.single as Map)['i'] as String;
    // Nobody else drops hers.
    say(inv, bob, {'dir': 'invites-drop', 'h': hers, 'ids': [id]});
    expect(last(bob)['dir'], 'err');
    expect(inv.waiting, 2);
    say(inv, carol, {'dir': 'invites-drop', 'h': hers, 'ids': [id]});
    expect(last(carol), {'dir': 'invites-drop', 'left': 0});
    say(inv, carol, {'dir': 'invites', 'h': hers});
    expect(last(carol)['list'], isEmpty);
    expect(inv.waiting, 1);
  });

  test('kept across a restart as hashes and sealed blobs, and gone after thirty days', () async {
    say(inv, alice, {'dir': 'invite', 'list': [leave(hers, 'c2VhbGVk')]});
    inv.save();
    final file = File('${dir.path}/invites.json').readAsStringSync();
    expect(file, isNot(contains('5550100199')), reason: 'never the number');
    expect(file, isNot(contains(alice)), reason: 'never who left it');
    final again = make();
    verified[carol] = hers;
    say(again, carol, {'dir': 'invites', 'h': hers});
    expect(last(carol)['list'], hasLength(1));

    clock = clock.add(const Duration(days: 29));
    say(again, carol, {'dir': 'invites', 'h': hers});
    expect(last(carol)['list'], hasLength(1));
    clock = clock.add(const Duration(days: 2));
    say(again, carol, {'dir': 'invites', 'h': hers});
    expect(last(carol)['list'], isEmpty, reason: 'past thirty days it is not handed out');
    await again.sweep();
    expect(again.waiting, 0);
    expect(make().waiting, 0, reason: 'and the sweep saved it gone');
  });

  test('the same invite again replaces the one before; a full number refuses more and keeps what waits', () {
    final tag = 'f' * 64;
    say(inv, alice, {'dir': 'invite', 'list': [leave(hers, 'b25l', t: tag)]});
    say(inv, alice, {'dir': 'invite', 'list': [leave(hers, 'dHdv', t: tag)]});
    verified[carol] = hers;
    say(inv, carol, {'dir': 'invites', 'h': hers});
    expect([for (final e in last(carol)['list'] as List) (e as Map)['b']], ['dHdv']);

    // One sender has only so many of a number's places: Bob's junk stops at his share.
    for (var i = 0; i < Invites.maxForNumber + 5; i++) {
      say(inv, bob, {'dir': 'invite', 'list': [leave(hers, 'eA==')]});
    }
    expect(last(bob), {'dir': 'invite', 'left': 0});
    say(inv, carol, {'dir': 'invites', 'h': hers});
    expect(last(carol)['list'], hasLength(1 + Invites.maxFromOne));

    // Many senders fill it; then more are refused, and the first invite is still there.
    for (var i = 0; i < Invites.maxForNumber; i++) {
      final key = 'd${i.toString().padLeft(31, '0')}';
      someone[key] = 'phone|filler$i';
      say(inv, key, {'dir': 'invite', 'list': [leave(hers, 'eQ==')]});
    }
    say(inv, carol, {'dir': 'invites', 'h': hers});
    final list = last(carol)['list'] as List;
    expect(list, hasLength(Invites.maxForNumber));
    expect([for (final e in list) (e as Map)['b']], contains('dHdv'), reason: 'what waits is never pushed out');
    // Another number is not held up by hers being full.
    say(inv, alice, {'dir': 'invite', 'list': [leave(hers, 'eg=='), leave(his, 'eg==')]});
    expect(last(alice), {'dir': 'invite', 'left': 1});
  });

  test('only someone may leave invites, counted as one however many keys they use', () {
    const fresh = 'e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5';
    say(inv, fresh, {'dir': 'invite', 'list': [leave(hers, 'eA==')]});
    expect(last(fresh), containsPair('err', 'Verify your number in Settings first.'));
    expect(inv.waiting, 0);

    // A second key that proved Alice's number is Alice: her hour is spent across both.
    someone[fresh] = someone[alice]!;
    for (var i = 0; i < Invites.anHour; i++) {
      final hash = Handles.keyOf('phone', '+1555010${(1000 + i).toString()}');
      say(inv, i.isEven ? alice : fresh, {'dir': 'invite', 'list': [leave(hash, 'eA==')]});
      expect(last(i.isEven ? alice : fresh), containsPair('left', 1));
    }
    say(inv, fresh, {'dir': 'invite', 'list': [leave(his, 'eA==')]});
    expect(last(fresh), containsPair('dir', 'err'));
  });

  test('the store holds only so much in all', () {
    for (var i = 0; i < Invites.maxAll ~/ Invites.maxAtOnce; i++) {
      final key = 'f${i.toString().padLeft(31, '0')}';
      someone[key] = 'phone|bulk$i';
      say(inv, key, {
        'dir': 'invite',
        'list': [for (var j = 0; j < Invites.maxAtOnce; j++) leave(Handles.keyOf('phone', '+1555${(i * 100 + j).toString().padLeft(7, '0')}'), 'eA==')],
      });
    }
    expect(inv.waiting, Invites.maxAll);
    say(inv, alice, {'dir': 'invite', 'list': [leave(his, 'eA==')]});
    expect(last(alice), containsPair('err', 'No more invites can be kept right now. The text you sent still has the link.'));
  });

  test('what is not an invite, one too big, and too many are refused, and nothing of them is kept', () {
    for (final bad in [
      {'dir': 'invite'},
      {'dir': 'invite', 'list': []},
      {'dir': 'invite', 'list': [leave('nothex', 'eA==')]},
      {'dir': 'invite', 'list': [leave(hers, 'x' * (Invites.maxBlob + 1))]},
      {'dir': 'invite', 'list': [leave(hers, 'not base64!')]},
      {'dir': 'invite', 'list': [leave(hers, 'eA==', t: 'short')]},
      {'dir': 'invite', 'list': [leave(hers, 'eA=='), 'what']},
      {'dir': 'invite', 'list': [for (var i = 0; i <= Invites.maxAtOnce; i++) leave(hers, 'eA==')]},
    ]) {
      say(inv, alice, bad);
      expect(last(alice), containsPair('dir', 'err'), reason: '$bad');
      expect(last(alice), containsPair('about', 'invite'));
    }
    expect(inv.waiting, 0);
  });

  test('one sender leaves only so many an hour and a day', () {
    var n = 0;
    String another() => Handles.keyOf('phone', '+1555020${(1000 + n++).toString()}');
    for (var i = 0; i < Invites.anHour; i++) {
      say(inv, alice, {'dir': 'invite', 'list': [leave(another(), 'eA==')]});
    }
    say(inv, alice, {'dir': 'invite', 'list': [leave(his, 'eA==')]});
    expect(last(alice), containsPair('dir', 'err'));
    // Someone else is not held up by her.
    say(inv, bob, {'dir': 'invite', 'list': [leave(his, 'eA==')]});
    expect(last(bob), containsPair('left', 1));
    // An hour on she may again, up to the day's.
    var left = Invites.anHour;
    while (left < Invites.aDay) {
      clock = clock.add(const Duration(minutes: 61));
      for (var i = 0; i < Invites.anHour && left < Invites.aDay; i++, left++) {
        say(inv, alice, {'dir': 'invite', 'list': [leave(another(), 'eA==')]});
        expect(last(alice), containsPair('left', 1));
      }
    }
    clock = clock.add(const Duration(minutes: 61));
    say(inv, alice, {'dir': 'invite', 'list': [leave(another(), 'eA==')]});
    expect(last(alice), containsPair('dir', 'err'), reason: 'the day\'s are spent');
  });

  group('through the hub', () {
    late Relay relay;
    late String url;
    late Handles handles;

    setUp(() async {
      handles = Handles(dataDir: dir);
      inv = Invites(dataDir: dir, phoneKeyOf: handles.phoneKeyOf, whoOf: handles.whoOf);
      relay = Relay(hub: Hub(handles: handles, invites: inv));
      url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
    });
    tearDown(() async => relay.stop());

    test('the invite messages are answered by the invites, and the handles still answer theirs', () async {
      final a = await _Install.connect(url);
      a.ws.add(jsonEncode({'dir': 'invite', 'list': [leave(hers, 'c2VhbGVk')]}));
      expect(await a.next(), {'dir': 'err', 'about': 'invite', 'err': 'Verify your number in Settings first.'}, reason: 'a key that has proved nothing leaves nothing');
      a.ws.add(jsonEncode({'dir': 'invites', 'h': hers}));
      expect(await a.next(), containsPair('err', 'Verify this number first.'));
      a.ws.add(jsonEncode({'dir': 'hello'}));
      expect(await a.next(), containsPair('dir', 'hello'), reason: 'what a 0.9.2 app says is answered as before');
      await a.ws.close();
    });

    test('a hub with no invites says so, and nothing else changes', () async {
      await relay.stop();
      relay = Relay(hub: Hub(handles: handles));
      url = 'ws://127.0.0.1:${await relay.start(port: 0)}/hub';
      final a = await _Install.connect(url);
      a.ws.add(jsonEncode({'dir': 'invites', 'h': hers}));
      expect(await a.next(), {'dir': 'err', 'about': 'invites', 'err': 'This server keeps no invites.'});
      await a.ws.close();
    });
  });
}

final _rnd = Random(11);
List<int> _bytes(int n) => [for (var i = 0; i < n; i++) _rnd.nextInt(256)];
List<int> _unhex(String s) => [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// An install signed in to the hub with a key of its own, as the app's is.
class _Install {
  _Install._(this.ws, this._said);
  final WebSocket ws;
  final StreamIterator<Map> _said;

  static Future<_Install> connect(String url) async {
    final scalar = _bytes(32);
    final key = P256.publicOf(scalar);
    final ws = await WebSocket.connect(url);
    final said = StreamIterator(ws.where((d) => d is String).map((d) => jsonDecode(d as String) as Map));
    await said.moveNext();
    final nonce = _unhex(said.current['hello'] as String);
    final sig = P256.sign(scalar, [...utf8.encode(Hub.greeting), ...nonce], _bytes(32));
    ws.add(jsonEncode({'id': Hub.nameOf(key), 'key': base64Encode(key), 'sig': base64Encode(sig)}));
    await said.moveNext();
    expect(said.current['ok'], isTrue);
    return _Install._(ws, said);
  }

  Future<Map> next() async {
    expect(await _said.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    return _said.current;
  }
}
