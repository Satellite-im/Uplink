import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/own_calls.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/me/me.dart' show MemoryMeStore;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_relay/accounts.dart';
import 'package:ghost_relay/handles.dart';

import 'account_flow_test.dart' show Device, FakeTexts;

/// One person, one identity, on every device (Matt, 2026-11-19: "when i join a server on my other logged in machines
/// it's joining as a new matt every time instead of reusing my existing keys and owner account, when I login on ghost i
/// should have the same identity across all devices").
///
/// Every computer paired with a phone was in each circle and space under a key made for it alone (`voice_key`), never
/// the identity it had taken on from the phone or signed in to, so each was another member called Matt and never the
/// owner. Now spaces and circles stand on the install's identity wherever it has one, which puts one identity on several
/// devices at once: a call moves to the device that came last, a space's chat does not count one's other device as
/// someone here, and what was made or seen under an old key is carried over to the identity.

/// The relay's rooms as they are kept since a person can be there from several devices (relay/lib/hub.dart): one place
/// for an id with every device of it; who is here is said leaving out one's own id; 'came' is said only for an id's
/// first device and 'went' only for its last; a packet goes to every other connection there, the sender's own other
/// devices included.
class _Hub {
  final Map<String, List<_Route>> rooms = {};
}

class _Route implements VoiceRoute {
  _Route(this.hub, this.me);
  final _Hub hub;
  @override
  final String me;
  final _events = StreamController<RoomEvent>.broadcast();
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  @override
  Future<List<String>> join(String room, String token) async {
    final r = hub.rooms[room] ??= [];
    final first = !r.any((o) => o.me == me);
    final others = {for (final o in r) if (o.me != me) o.me}.toList();
    if (!r.contains(this)) r.add(this);
    if (first) {
      for (final o in r) {
        if (o.me != me) scheduleMicrotask(() => o._events.add(RoomEvent(room, came: me)));
      }
    }
    return others;
  }

  @override
  void leave(String room) {
    final r = hub.rooms[room];
    if (r == null || !r.remove(this)) return;
    if (r.any((o) => o.me == me)) return;
    for (final o in r) {
      scheduleMicrotask(() => o._events.add(RoomEvent(room, went: me)));
    }
  }

  @override
  void send(String room, Uint8List bytes) {
    for (final o in [...?hub.rooms[room]]) {
      if (!identical(o, this)) scheduleMicrotask(() => o._packets.add((room: room, from: me, bytes: bytes)));
    }
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => _events.stream;
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => _looks.stream;
}

/// WebRTC stood in for: each connection says what it was asked to make and take.
class _Media implements VoiceMedia {
  _Media(this.name);
  final String name;
  @override
  final ValueNotifier<Map<String, double>> levels = ValueNotifier(const {});
  final log = <String>[];
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async => log.add('stopped');
  @override
  set muted(bool on) {}
  @override
  set deafened(bool on) {}
  @override
  Future<void> setVideo(bool on) async {}
  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => _Peer(this, id);
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

class _Peer implements VoicePeer {
  _Peer(this.media, this.id);
  final _Media media;
  final String id;
  static const _opus = 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n';
  @override
  Future<String> makeOffer() async {
    media.log.add('offer to $id');
    return _opus;
  }

  @override
  Future<String> takeOffer(String sdp) async {
    media.log.add('answer $id');
    return _opus;
  }

  @override
  Future<void> takeAnswer(String sdp) async => media.log.add('took answer from $id');
  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {}
  @override
  Future<void> close() async => media.log.add('closed $id');
}

/// Waits until [ok] holds, or five seconds go by: never a fixed sleep, which a busy machine outruns.
Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A phone across a computer's link that answers nothing of its own.
class _Store implements LinkStore {
  @override
  Future<PairedPhone?> load() async => null;
  @override
  Future<void> save(PairedPhone phone) async {}
  @override
  Future<void> clear() async {}
}

class _Phone extends LinkCalls {
  _Phone(Directory dir) : super(PhoneLink(store: _Store(), name: 'Test Mac', app: '0.9.20'), DeskStore(dir, keychain: false));
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => null;
}

/// Choices kept a little after they are asked for, as a computer's file is written (lib/desktop/store.dart), and the
/// restart told what had been written by then.
class _SlowCalls implements SmsCalls {
  final written = <String, String>{};
  Map<String, String>? atRestart;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final a = (arguments as Map?) ?? const {};
    switch (method) {
      case 'setPref':
        await Future<void>.delayed(const Duration(milliseconds: 40));
        written['${a['key']}'] = '${a['value']}';
        return null;
      case 'restartApp':
        atRestart = {...written};
        return true as T;
    }
    return null;
  }
}

/// A device of an account that keeps circles too, as the app's own profile carrier does (AppAccountProfiles).
class _CircleDevice extends Device {
  _CircleDevice(super.relayAccounts, super.handles, {super.keys, super.hasFriends});
  List<Object?> circles = const [];
  @override
  AccountBackup fill(AccountBackup b) => super.fill(b).copyWith(circles: circles);
}

String _seed(String c) => c * 64;

void main() {
  final calls = Sms.calls;
  tearDown(() => Sms.calls = calls);

  group('which key a device is in circles and spaces as', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('ghost-one-identity'));
    tearDown(() => root.deleteSync(recursive: true));

    test('the phone and a computer on its own: their identity', () {
      expect(Sms.paired, isFalse);
      expect(Voice.separateKey, isFalse);
    });

    test('a paired computer that has taken on the phone\'s identity: that identity, not a key of its own', () async {
      final keys = NetKeys.generate();
      final dir = Directory('${root.path}/own');
      await DeskOwnCalls.adopt(dir, {'scalar': NetCrypto.hex(keys.scalar), 'buddies': '[]'}, keychain: false);
      final own = DeskOwnCalls(_Phone(root), dir, keychain: false);
      await own.load();
      Sms.calls = own;
      expect(Sms.paired, isTrue, reason: 'its texts are still the phone\'s');
      expect(Voice.separateKey, isFalse, reason: 'it was a separate member under voice_key in every circle and space');
      expect((await Sms.instance.netIdentity()).id, keys.id);
    });

    test('a paired computer that has not taken it on yet: a key of its own, having none to speak as', () {
      Sms.calls = _Phone(root);
      expect(Sms.followsPhone, isTrue);
      expect(Voice.separateKey, isTrue);
    });
  });

  group('a call with one identity on two devices', () {
    test('the device that comes in last takes the call over; the others let go of the first and connect to it', () async {
      final hub = _Hub();
      final matt = NetKeys.generate().id, maya = NetKeys.generate().id;
      final c = VoiceChannel.make('Lounge');
      final phoneMedia = _Media('phone'), macMedia = _Media('mac'), mayaMedia = _Media('maya');
      final phone = VoiceSession(channel: c, route: _Route(hub, matt), media: phoneMedia, name: 'Matt');
      final theirs = VoiceSession(channel: c, route: _Route(hub, maya), media: mayaMedia, name: 'Maya');
      var movedAway = 0;
      phone.onMovedAway = () async {
        movedAway++;
        await phone.leave();
      };
      await phone.join();
      await theirs.join();
      // Maya came in second, so she offered and the phone answered.
      await _until(() => phoneMedia.log.contains('answer $maya') && mayaMedia.log.contains('took answer from $matt'));
      expect(theirs.members.keys, [matt]);

      // Matt opens the same call on his computer: one identity, so the relay names nobody new.
      final mac = VoiceSession(channel: c, route: _Route(hub, matt), media: macMedia, name: 'Matt');
      await mac.join();
      await _until(() => !phone.joined && mayaMedia.log.contains('answer $matt') && macMedia.log.contains('took answer from $maya'));

      expect(movedAway, 1, reason: 'the phone left the call for the computer');
      expect(phone.joined, isFalse);
      expect(phoneMedia.log, contains('stopped'));
      expect(phoneMedia.log.where((l) => l.contains('answer')), ['answer $maya'], reason: 'the phone took nothing meant for the computer');
      // Maya let go of the phone's connection before taking the computer's offer, and still sees one Matt.
      final closed = mayaMedia.log.indexOf('closed $matt');
      expect(closed, greaterThan(-1));
      expect(mayaMedia.log.lastIndexOf('answer $matt'), greaterThan(closed));
      expect(theirs.members.keys, [matt]);
      expect(mac.members.keys, [maya], reason: 'the computer does not take itself for someone else in the call');
      expect(macMedia.log, isNot(contains('offer to $matt')));
      await mac.leave();
      await theirs.leave();
    });
  });

  group('a space\'s chat with one identity on two devices', () {
    test('the other device is not someone here, and those here greet it with their names', () async {
      final hub = _Hub();
      final matt = NetKeys.generate().id, maya = NetKeys.generate().id;
      final c = VoiceChannel.make('General', kind: SpaceKind.text);
      final phone = HangoutRoom(channel: c, route: _Route(hub, matt), name: 'Matt');
      final theirs = HangoutRoom(channel: c, route: _Route(hub, maya), name: 'Maya');
      await phone.open();
      await theirs.open();
      await _until(() => phone.present[maya]?.name == 'Maya' && theirs.present[matt]?.name == 'Matt');

      // The computer comes in: the relay tells nobody (it is not Matt's first device here).
      final mac = HangoutRoom(channel: c, route: _Route(hub, matt), name: 'Matt');
      await mac.open();
      await _until(() => mac.present[maya]?.name == 'Maya');
      await _settle();

      expect(mac.present[maya]?.name, 'Maya', reason: 'greeted although no one was told it came');
      expect(phone.present.keys, [maya], reason: 'the computer\'s hi is Matt\'s own, not someone else here');
      expect(mac.present.keys, [maya]);
      expect(theirs.present.keys, [matt], reason: 'one Matt, from both devices');
      await mac.close();
      await phone.close();
      await theirs.close();
    });
  });

  group('what an old key made and was, carried over', () {
    test('a circle a computer made under its own key: the identity is made its admin, and its old id folded into the identity\'s everywhere', () async {
      final hub = _Hub();
      final old = NetKeys.generate(), matt = NetKeys.generate(), maya = NetKeys.generate();
      // The computer, under the key it used to have: it made the circle.
      final before = Circles.forTest(signer: KeysSigner(old), route: _Route(hub, old.id));
      final made = (await before.make(name: 'Book club'))!;
      // Maya is in it, and has seen the computer there as Matt.
      final theirs = Circles.forTest(signer: KeysSigner(maya), route: _Route(hub, maya.id));
      theirs.join(Circle.fromJson(jsonDecode(jsonEncode(made.toJson())))!);
      await _until(() => theirs.bySeed(made.seed)!.manifest.isSigned);
      theirs.noteSeen(made, {old.id: 'Matt'});
      expect(theirs.bySeed(made.seed)!.manifest.canSign(matt.id), isFalse);

      // The same computer now, as Matt's identity, holding the same circle.
      final now = Circles.forTest(signer: KeysSigner(matt), route: _Route(hub, matt.id));
      now.join(Circle.fromJson(jsonDecode(jsonEncode(made.toJson())))!);
      expect(now.canEdit(now.bySeed(made.seed)!), isFalse, reason: 'until now its owner was the old key alone');
      expect(await now.carryOver(KeysSigner(old), matt.id), isTrue);
      await _until(() => theirs.bySeed(made.seed)!.manifest.canSign(matt.id) && theirs.sameAs(old.id) == matt.id);

      expect(now.canEdit(now.bySeed(made.seed)!), isTrue);
      expect(theirs.bySeed(made.seed)!.manifest.canSign(matt.id), isTrue, reason: 'the grant reached the others');
      expect(theirs.sameAs(old.id), matt.id, reason: 'on the old key\'s own word');
      expect(theirs.seenIn(made).containsKey(old.id), isFalse, reason: 'no second Matt kept from before');
      expect(now.sameAs(old.id), matt.id);
    });

    test('an id is folded into another only on its own key\'s word, for the one who says it', () async {
      final hub = _Hub();
      final owner = NetKeys.generate(), mallory = NetKeys.generate(), maya = NetKeys.generate(), victim = NetKeys.generate();
      final theirs = Circles.forTest(signer: KeysSigner(owner), route: _Route(hub, owner.id));
      final made = (await theirs.make(name: 'Book club'))!;
      final bad = Circles.forTest(signer: KeysSigner(mallory), route: _Route(hub, mallory.id));
      bad.join(Circle.fromJson(jsonDecode(jsonEncode(made.toJson())))!);
      await _until(() => bad.bySeed(made.seed)!.manifest.isSigned);
      // Mallory says the victim's id is hers, with a signature of her own key, and the victim's key's signature for
      // Maya's id: neither holds.
      await bad.carryOver(KeysSigner(mallory), victim.id);
      final forMaya = NetCrypto.sign(victim, CircleRoom.wasMessage(made.seed, maya.id));
      bad.roomOf(made)!.sayWas(victim.public, forMaya);
      await _settle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(theirs.sameAs(victim.id), victim.id);
      expect(theirs.sameAs(mallory.id), mallory.id, reason: 'her own word is about the id she says it from, not another');
    });

    test('an id carried over twice stands for the last identity', () async {
      final circles = Circles.forTest(signer: KeysSigner(NetKeys.generate()), route: null);
      final first = NetKeys.generate(), second = NetKeys.generate(), third = NetKeys.generate();
      await circles.carryOver(KeysSigner(first), second.id);
      await circles.carryOver(KeysSigner(second), third.id);
      expect(circles.sameAs(first.id), third.id);
      expect(circles.sameAs(second.id), third.id);
      expect(circles.sameAs(third.id), third.id);
    });

    test('never signed over a circle known only by its link', () async {
      final owner = NetKeys.generate();
      final made = Circle.fromLink((await Circles.forTest(signer: KeysSigner(owner), route: _Route(_Hub(), owner.id)).make(name: 'Book club'))!.link)!;
      final elsewhere = Circles.forTest(signer: KeysSigner(owner), route: null);
      elsewhere.join(made);
      expect(elsewhere.bySeed(made.seed)!.manifest.isSigned, isFalse);
      expect(await elsewhere.grantAdmin(made, NetKeys.generate().id), isFalse, reason: 'its spaces and roles would have been signed away');
    });
  });

  group('settings written before the app starts again', () {
    test('a restart waits for every choice asked for before it', () async {
      final slow = _SlowCalls();
      Sms.calls = slow;
      unawaited(Sms.instance.setPref('acct_address', '0xabc'));
      unawaited(Sms.instance.setPref('me_username', 'matt'));
      expect(await Sms.instance.restartApp(), isTrue);
      expect(slow.atRestart, {'acct_address': '0xabc', 'me_username': 'matt'}, reason: 'a computer used to come back signed out');
    });
  });

  group('a sign-in cut short, finished at the next start', () {
    late Handles handles;
    late Accounts accounts;
    setUp(() {
      handles = Handles(texts: FakeTexts())..load();
      accounts = Accounts(handles: handles);
    });

    Future<(Device, Device)> signedIn() async {
      final phone = Device(accounts, handles, hasFriends: true);
      await phone.claim('matt');
      await phone.account.create(phone.account.draft(), 'correct horse battery');
      final mac = Device(accounts, handles, keys: NetKeys.fromScalar(phone.keys.scalar));
      final restore = await mac.account.signInWithPassword('matt', 'correct horse battery');
      await mac.account.finish(restore);
      return (phone, mac);
    }

    test('its choices lost as the app closed, the account is taken up again from the words in the vault', () async {
      final (phone, mac) = await signedIn();
      final address = mac.account.address;
      // Started again with only what was written before the end: the device's number, not the account.
      final lost = MemoryMeStore()..set('acct_device', mac.store.choice('acct_device', ''));
      mac.account.store = lost;
      expect(mac.account.signedIn, isFalse);
      expect(await mac.account.resume(), isTrue);
      expect(mac.account.signedIn, isTrue);
      expect(mac.account.address, address);
      expect(await mac.account.revealWords('correct horse battery'), hasLength(12), reason: 'the password\'s copy is back too');
      expect(phone.account.signedIn, isTrue);
    });

    test('not where this install is someone else, nor where the relay no longer lists it', () async {
      final (_, mac) = await signedIn();
      final device = mac.store.choice('acct_device', '');
      mac.account.store = MemoryMeStore()..set('acct_device', device);
      final keys = mac.keys;
      mac.keys = NetKeys.generate();
      expect(await mac.account.resume(), isFalse, reason: 'another identity is not made the account\'s without asking');
      mac.keys = keys;
      mac.account.store = MemoryMeStore()..set('acct_device', NetCrypto.hex(NetCrypto.randomBytes(16)));
      expect(await mac.account.resume(), isFalse);
      expect(mac.account.signedIn, isFalse);
    });

    test('nothing at all on a device that was never signed in', () async {
      final fresh = Device(accounts, handles);
      expect(await fresh.account.resume(), isFalse);
      expect(fresh.store.choice('acct_device', ''), '', reason: 'no device number made for nothing');
    });

    test('signing in keeps the identity the install had before, for its circles to be carried over; signing out forgets it', () async {
      final phone = Device(accounts, handles, hasFriends: true);
      await phone.claim('matt');
      await phone.account.create(phone.account.draft(), 'correct horse battery');
      final laptop = Device(accounts, handles);
      final before = laptop.keys;
      await laptop.account.finish(await laptop.account.signInWithPassword('matt', 'correct horse battery'));
      expect(laptop.keys.id, phone.keys.id);
      expect(laptop.secrets[Voice.wasKey], NetCrypto.hex(before.scalar));
      await laptop.account.signOut();
      expect(laptop.secrets.containsKey(Voice.wasKey), isFalse);
    });

    test('a paired computer signing in to another identity keeps nothing of its phone\'s to fold into it', () async {
      final root = Directory.systemTemp.createTempSync('ghost-one-identity');
      addTearDown(() => root.deleteSync(recursive: true));
      final phoneKeys = NetKeys.generate();
      final dir = Directory('${root.path}/own');
      await DeskOwnCalls.adopt(dir, {'scalar': NetCrypto.hex(phoneKeys.scalar), 'buddies': '[]'}, keychain: false);
      final own = DeskOwnCalls(_Phone(root), dir, keychain: false);
      await own.load();
      Sms.calls = own;
      expect(Sms.paired, isTrue);
      final other = Device(accounts, handles, hasFriends: true);
      await other.claim('sam');
      await other.account.create(other.account.draft(), 'correct horse battery');
      // The computer, holding the phone's identity, signs in to Sam's account after the warning about a split.
      final mac = Device(accounts, handles, keys: NetKeys.fromScalar(phoneKeys.scalar));
      await mac.account.finish(await mac.account.signInWithPassword('sam', 'correct horse battery'));
      expect(mac.keys.id, other.keys.id);
      expect(mac.secrets.containsKey(Voice.wasKey), isFalse, reason: 'the phone is still that identity: it is never said to be Sam');
    });
  });

  group('the backup sealed again', () {
    test('what another device of the account put in it is kept: a device in fewer circles takes none out', () async {
      final handles = Handles(texts: FakeTexts())..load();
      final accounts = Accounts(handles: handles);
      final phone = _CircleDevice(accounts, handles, hasFriends: true)..circles = [{'s': _seed('a')}, {'s': _seed('b')}];
      await phone.claim('matt');
      await phone.account.create(phone.account.draft(), 'correct horse battery');
      final mac = _CircleDevice(accounts, handles, keys: NetKeys.fromScalar(phone.keys.scalar));
      await mac.account.finish(await mac.account.signInWithPassword('matt', 'correct horse battery'));
      mac.circles = [{'s': _seed('b'), 'mine': 1}, {'s': _seed('c')}];
      expect(await mac.account.refresh(force: true), isTrue);
      final next = Device(accounts, handles);
      final restore = await next.account.signInWithPassword('matt', 'correct horse battery');
      expect([for (final c in restore.backup.circles) (c as Map)['s']], [_seed('b'), _seed('c'), _seed('a')]);
      expect((restore.backup.circles.first as Map)['mine'], 1, reason: 'this device\'s own copy of one both have');
    });

    test('the start-of-day check waits for the hub, made a moment after the app starts', () async {
      HubCarrier? made;
      final relay = HubAccountRelay(hub: () => made);
      Timer(const Duration(milliseconds: 300), () => made = HubCarrier(url: 'ws://127.0.0.1:9', signer: KeysSigner(NetKeys.generate())));
      expect(await relay.hubMade(within: const Duration(seconds: 5)), isTrue);
      expect(await HubAccountRelay(hub: () => null).hubMade(within: const Duration(milliseconds: 300)), isFalse);
    });
  });
}
