import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/pictures.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/profile_card.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';

/// Profiles (Matt, 2026-11-19: "build a profile section in the app that allows us to set profile pictures and status
/// messages, when clicking on a @mention anywhere including signal and telegram chats show this profile popup"): a
/// picture and a status go to friends with the name and line, a space hears the status and a mark of the picture and
/// asks for the picture itself, and an "@username" written in a conversation can be pressed.

/// A friends' port that only receives (what is sent to it is put in by hand, as another install would send it).
class _Port implements BuddiesPort {
  final keys = NetKeys.generate();
  String list = '[]';
  final _in = StreamController<({String from, Envelope envelope})>.broadcast();
  final _hellos = StreamController<({String from, Envelope envelope})>.broadcast();
  @override
  Future<({String id, String key})> me() async => (id: keys.id, key: base64Encode(keys.public));
  @override
  String? get username => 'sam';
  @override
  String get displayName => 'Sam';
  @override
  String get bio => '';
  /// The relay's directory: usernames to installs. A friend request is kept only where it says the username is the
  /// sender's (Buddies._greeting).
  final directory = <String, ({String id, String key})>{};
  @override
  Future<({String id, String key})?> whois(String username) async => directory[username];
  @override
  Future<void> keep(String json) async => list = json;
  @override
  Future<String> kept() async => list;
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => _in.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => _hellos.stream;
}

/// Rooms on a hub stood in for: a packet to everyone else in the room.
class _Hub {
  final Map<String, List<_Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final packetsIn = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= [];
    final others = [for (final o in r) o.me];
    r.add(this);
    for (final o in r) {
      if (o != this) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
    }
    return others;
  }

  @override
  void leave(String room) => hub.rooms[room]?.remove(this);
  @override
  void send(String room, Uint8List bytes) {
    for (final o in [...?hub.rooms[room]]) {
      if (o != this) scheduleMicrotask(() => o.packetsIn.add((room: room, from: me, bytes: bytes)));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => _events.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => packetsIn.stream;
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _picture = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

void main() {
  test('an "@username" written in words is found, but not inside an email address or a longer word', () {
    const words = 'ask @Maya_C or @sam.r. about it, not me@example.com, @ab, or @@double';
    final found = handleMentions(words);
    expect([for (final m in found) words.substring(m.start, m.end)], ['@Maya_C', '@sam.r']);
    expect([for (final m in found) m.id], ['u:maya_c', 'u:sam.r']);
    expect(handleMentions('no mentions here'), isEmpty);
  });

  test('a mention\'s id is made the right subject: a username, an Uplink id, a network\'s person', () {
    expect(subjectOfMention('u:maya').username, 'maya');
    expect(subjectOfMention('0123456789abcdef0123456789abcdef').id, '0123456789abcdef0123456789abcdef');
  });

  test('a friend keeps their picture and status, round their record and from what they send', () async {
    final b = Buddy(username: 'maya', id: 'm1', key: 'k', name: 'Maya', picture: _picture, status: 'Out climbing');
    final back = Buddy.fromJson(b.toJson())!;
    expect(back.picture, _picture);
    expect(back.status, 'Out climbing');
    expect(Buddy.fromJson({'u': 'maya', 'i': 'm1', 'k': 'k'})!.picture, '', reason: 'a record from before has none');

    final port = _Port();
    final buddies = Buddies(port);
    await buddies.start();
    final maya = NetKeys.generate();
    port.directory['maya'] = (id: maya.id, key: base64Encode(maya.public));
    port._hellos.add((from: maya.id, envelope: Envelope(kind: 'hello', body: {'buddy': 'ask', 'u': 'maya', 'k': base64Encode(maya.public), 'n': 'Maya', 'b': '', 'p': _picture, 'st': 'Out climbing'})));
    await _until(() => buddies.requests.isNotEmpty);
    expect(buddies.requests.single.picture, _picture);
    expect(buddies.requests.single.status, 'Out climbing');

    await buddies.accept(buddies.requests.single);
    // A build from before says no status and no picture: what was known stays.
    port._in.add((from: maya.id, envelope: Envelope(kind: 'buddy', body: {'s': 'me', 'u': 'maya', 'n': 'Maya C', 'b': ''})));
    await _until(() => buddies.friends.single.name == 'Maya C');
    expect(buddies.friends.single.picture, _picture);
    expect(buddies.friends.single.status, 'Out climbing');
    // One from now that says a status and no picture has taken its picture away.
    port._in.add((from: maya.id, envelope: Envelope(kind: 'buddy', body: {'s': 'me', 'u': 'maya', 'n': 'Maya C', 'b': '', 'st': 'Home'})));
    await _until(() => buddies.friends.single.status == 'Home');
    expect(buddies.friends.single.picture, '');
  });

  test('a space hears a status and a picture\'s mark, and the picture is asked of its owner when wanted', () async {
    final hub = _Hub();
    final c = VoiceChannel.make('General', kind: SpaceKind.text);
    final mine = HangoutRoom(channel: c, route: _Route(hub, 'me-id'), name: 'Sam');
    await mine.open();
    // Maya's device, by hand: says hi with a status and her picture's mark, and answers the ask for it.
    final maya = _Route(hub, 'maya-id');
    await maya.join(c.chatRoom, c.chatToken);
    void say(Map<String, Object?> what) => maya.send(c.chatRoom, NetCrypto.seal(c.key, utf8.encode(jsonEncode(what))));
    var asked = 0;
    maya.packetsIn.stream.listen((p) {
      final m = jsonDecode(utf8.decode(NetCrypto.open(c.key, p.bytes)!)) as Map;
      if (m['t'] == 'pic?' && m['to'] == 'maya-id') {
        asked++;
        say({'t': 'pic', 'to': p.from, 'p': _picture});
      }
    });
    say({'t': 'hi', 'n': 'Maya', 'st': 'Out climbing', 'ph': ProfilePictures.hashOf(_picture)});
    await _until(() => mine.present['maya-id']?.status == 'Out climbing');
    expect(mine.present['maya-id']!.pictureHash, ProfilePictures.hashOf(_picture));
    expect(await mine.pictureOf('maya-id'), _picture);
    expect(await mine.pictureOf('maya-id'), _picture, reason: 'kept: not asked again');
    expect(asked, 1);
    // Someone with no picture is not asked.
    say({'t': 'hi', 'n': 'Maya'});
    await _until(() => mine.present['maya-id']?.status == '');
    expect(await mine.pictureOf('maya-id'), isNull);
    expect(asked, 1);
    await mine.close();
  });
}
