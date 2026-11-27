import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/net/switchboard.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/friend_calls.dart';
import 'package:ghost_messaging/voice/voice.dart';

// Calling one friend (lib/voice/friend_calls.dart; GMFB-28, from the Uplink gap review: "Ring one friend with a voice
// or video call, the way you would a phone, without making a space first"). Two devices, each with its own stand-in for
// the routes; what one sends reaches the other as Voice would pass it on.

const _me = 'aaaa0000aaaa0000aaaa0000aaaa0000', _maya = 'bbbb1111bbbb1111bbbb1111bbbb1111';

class _Kept implements BuddiesPort {
  _Kept(this.list);
  final List<Map<String, Object>> list;
  @override
  Future<({String id, String key})> me() async => (id: _me, key: 'k');
  @override
  String? get username => 'me';
  @override
  String get displayName => 'Me';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => jsonEncode(list);
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

class _Port implements FriendCallsPort {
  _Port(this.myId);
  @override
  final String myId;
  final sent = <({String to, Envelope envelope, bool urgent})>[];
  final mine = <Envelope>[];
  bool reachable = true;

  @override
  Peer? peerOf(String id) => reachable ? Peer(id: id, key: Uint8List(32)) : null;
  @override
  Future<bool> send(Peer peer, Envelope envelope, {bool urgent = false}) async {
    sent.add((to: peer.id, envelope: envelope, urgent: urgent));
    return true;
  }

  @override
  Future<void> sendMine(Envelope envelope) async => mine.add(envelope);
}

class _Notes implements CallNotes {
  final lines = <({String address, String words, bool out})>[];
  @override
  void note(String address, String words, {required bool out}) => lines.add((address: address, words: words, out: out));
}

Received _from(String id, Envelope e) => Received(Peer(id: id, key: Uint8List(32)), e, 'hub');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Port port;
  late _Notes notes;
  late FriendCalls calls;

  setUp(() async {
    Buddies.instance = Buddies(_Kept([
      {'u': 'maya', 'i': _maya, 'k': 'k', 'n': 'Maya Chen', 's': 'yes'},
    ]));
    await Buddies.instance.start();
    port = _Port(_me);
    notes = _Notes();
    calls = FriendCalls(port: port, notes: notes);
    FriendCalls.instance = calls;
  });

  tearDown(() {
    final r = Voice.instance.ringing;
    if (r != null) Voice.instance.clearRing(r);
    Buddies.instance = null;
    FriendCalls.instance = FriendCalls();
  });

  test('both sides work out the same call, and it is nobody\'s space', () {
    final a = FriendCalls.channelWith(_me, _maya, 'Maya'), b = FriendCalls.channelWith(_maya, _me, 'Me');
    expect(a.room, b.room);
    expect(a.key, b.key);
    expect(FriendCalls.isCall(a), isTrue);
    expect(a.hangout, isFalse, reason: 'no chat or roles of its own: the conversation is the chat');
    expect(FriendCalls.channelWith(_me, 'cccc', 'X').room, isNot(a.room));
  });

  test('calling: in the call, and the friend rung, urgently', () async {
    final maya = Buddies.instance.byId(_maya)!;
    VoiceChannel? joined;
    bool? withVideo;
    final rang = await calls.call(maya, video: true, join: (c, v) async {
      joined = c;
      withVideo = v;
    });
    expect(rang, isTrue);
    expect(joined!.room, FriendCalls.channelWith(_me, _maya, '').room);
    expect(withVideo, isTrue);
    final ring = port.sent.single;
    expect(ring.to, _maya);
    expect(ring.urgent, isTrue);
    expect(ring.envelope.body['t'], 'call');
    expect(ring.envelope.body['v'], true);
    expect(calls.ringingOut, ring.envelope.body['i']);

    // Maya came in: answered, no line kept.
    calls.joined(joined!);
    expect(calls.ringingOut, isNull);
    calls.left(joined!);
    expect(port.sent.length, 1, reason: 'an answered call is not called off');
    expect(notes.lines, isEmpty);
  });

  test('hanging up before an answer calls it off: the friend is told, and a line kept', () async {
    final maya = Buddies.instance.byId(_maya)!;
    late VoiceChannel c;
    await calls.call(maya, join: (ch, _) async => c = ch);
    final id = port.sent.single.envelope.body['i'];
    calls.left(c);
    expect(port.sent.last.envelope.body, {'t': 'cancel', 'i': id});
    expect(notes.lines.single, (address: '@maya', words: 'Cancelled call', out: true));
  });

  test('a friend that can\'t be reached is not rung', () async {
    port.reachable = false;
    expect(await calls.call(Buddies.instance.byId(_maya)!, join: (_, _) async {}), isFalse);
    expect(port.sent, isEmpty);
  });

  test('rung by a friend: it rings here; declined, the caller and this account\'s other devices are told', () {
    final v = Voice.instance;
    expect(calls.received(_from(_maya, Envelope(kind: 'voice', body: {'t': 'call', 'i': 'c1', 'v': false, 'n': 'Maya'})), mine: false), isTrue);
    final ring = v.ringing!;
    expect(ring.call, 'c1');
    expect(ring.caller, _maya);
    expect(ring.from, 'Maya Chen', reason: 'the name kept for the friend here');
    expect(ring.channel.room, FriendCalls.channelWith(_me, _maya, '').room);

    v.dismissRing();
    expect(v.ringing, isNull);
    expect(port.sent.single.to, _maya);
    expect(port.sent.single.envelope.body, {'t': 'decline', 'i': 'c1'});
    expect(port.mine.single.body, {'t': 'answered', 'i': 'c1'});
    expect(notes.lines, isEmpty, reason: 'declined here is not missed');
  });

  test('called off by the friend before an answer: a missed call', () {
    final v = Voice.instance;
    calls.received(_from(_maya, Envelope(kind: 'voice', body: {'t': 'call', 'i': 'c2', 'v': true})), mine: false);
    calls.received(_from(_maya, Envelope(kind: 'voice', body: {'t': 'cancel', 'i': 'c2'})), mine: false);
    expect(v.ringing, isNull);
    expect(notes.lines.single, (address: '@maya', words: 'Missed video call', out: false));
  });

  test('answered on another device of this account: it stops ringing here, with nothing missed', () {
    final v = Voice.instance;
    calls.received(_from(_maya, Envelope(kind: 'voice', body: {'t': 'call', 'i': 'c3'})), mine: false);
    // Only this account's own devices may say so.
    calls.received(_from(_maya, Envelope(kind: 'voice', body: {'t': 'answered', 'i': 'c3'})), mine: false);
    expect(v.ringing?.call, 'c3');
    calls.received(_from(_me, Envelope(kind: 'voice', body: {'t': 'answered', 'i': 'c3'})), mine: true);
    expect(v.ringing, isNull);
    expect(notes.lines, isEmpty);
  });

  test('declined by the friend: the caller\'s call ends, and a line kept', () async {
    final maya = Buddies.instance.byId(_maya)!;
    await calls.call(maya, join: (_, _) async {});
    final id = port.sent.single.envelope.body['i'];
    // Someone else can't decline it.
    calls.received(_from('cccc2222cccc2222cccc2222cccc2222', Envelope(kind: 'voice', body: {'t': 'decline', 'i': id})), mine: false);
    expect(calls.ringingOut, id);
    calls.received(_from(_maya, Envelope(kind: 'voice', body: {'t': 'decline', 'i': id})), mine: false);
    expect(calls.ringingOut, isNull);
    expect(calls.ended.value, 'Maya Chen declined');
    expect(notes.lines.single, (address: '@maya', words: 'Declined · call', out: true));
  });

  test('a call from someone who is not a friend does not ring', () {
    calls.received(_from('dddd3333dddd3333dddd3333dddd3333', Envelope(kind: 'voice', body: {'t': 'call', 'i': 'c4'})), mine: false);
    expect(Voice.instance.ringing, isNull);
  });
}
