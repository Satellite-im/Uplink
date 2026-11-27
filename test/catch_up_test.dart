// Matt, 2026-11-25: "messages are still not kept in sync across all devices, all my devices have different sidebars".
// The copies an account's devices pass each other (Friends.copyKind) reach the devices connected as a message goes,
// and the relay keeps one for the rest only while none of the account's devices is connected: with a phone always
// connected, a computer that was closed never heard of what was said meanwhile, and a device's history is asked for
// once in its life (test/history_handover_test.dart). Now a device asks each time it comes back for what was said
// since it was last in step (Friends.sinceAsk), and takes in the friends and circles its account's other devices have
// made since it signed in (Account.takeIn; Buddies.takeFromAccount, Circles.fromAccount).
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/fake_friends.dart';

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    Friends.historyPace = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
  });

  final now = DateTime.now().millisecondsSinceEpoch;
  const hour = 60 * 60 * 1000;

  /// The phone, holding [held], and the Mac of the same account, coming back.
  Future<({FakePort phone, FakePort mac, Friends onPhone, Friends onMac})> pair(Map<String, List<PastRow>> held, {AppState? macApp}) async {
    final phone = FakePort('@matt'), mac = FakePort('@matt'), ben = FakePort('@ben');
    for (final p in [phone, mac]) {
      p.other = ben;
      p.stand('@ben', friend: 'yes');
    }
    ben.other = phone;
    phone.pastHeld.addAll(held);
    phone.twin = mac;
    mac.twin = phone;
    final onPhone = Friends(phone), onMac = Friends(mac);
    addTearDown(onPhone.shutdown);
    addTearDown(onMac.shutdown);
    await onPhone.start(null);
    // It has had its history long ago: only the catching up is in question.
    macApp?.setFlag('history_done', true);
    await onMac.start(macApp);
    return (phone: phone, mac: mac, onPhone: onPhone, onMac: onMac);
  }

  test('a device coming back is given what was said since, and not what is older than its catching up goes', () async {
    final w = await pair({
      '@ben': <PastRow>[(t: 'from last month', at: now - 30 * 24 * hour, o: false), (t: 'while you were closed', at: now - hour, o: false), (t: 'and my answer from the phone', at: now - hour + 5000, o: true)],
    }, macApp: AppState());
    await until(() => (w.mac.pastKept['@ben']?.length ?? 0) >= 2);
    expect(w.mac.pastKept['@ben']!.map((r) => r.t), ['while you were closed', 'and my answer from the phone']);
    final ask = w.mac.mineSent.where((e) => e.kind == Friends.sinceAsk).single;
    expect(w.mac.hubOnly.contains(ask.id), isTrue, reason: 'by the hub alone, which says which device asked');
    expect(ask.body['s'], closeTo(now - Friends.sinceBack.inMilliseconds, 5000), reason: 'a first catching up goes two weeks back');
    expect(w.phone.mineSent.where((e) => e.kind == Friends.historyKind && e.body['n'] == ask.body['n']).every((e) => e.body['e'] == null), isTrue, reason: 'parts, with no end said');
    expect(w.phone.pastKept, isEmpty, reason: 'the phone keeps nothing of its own answer');
  });

  test('the next time, it asks from when it was last in step', () async {
    final app = AppState();
    final w = await pair({'@ben': <PastRow>[(t: 'hi', at: now - hour, o: false)]}, macApp: app);
    await until(() => w.mac.pastKept.isNotEmpty);
    final last = int.parse(app.choice('since_last', ''));
    expect(last, closeTo(now, 10000));
    await w.onMac.shutdown();
    final again = Friends(w.mac);
    addTearDown(again.shutdown);
    await again.start(app);
    await until(() => w.mac.mineSent.where((e) => e.kind == Friends.sinceAsk).length >= 2);
    final second = w.mac.mineSent.where((e) => e.kind == Friends.sinceAsk).last;
    expect(second.body['s'], last - Friends.sinceMargin.inMilliseconds);
    // Friends taken in from the account since: from the start again.
    again.catchUpAgain();
    await until(() => w.mac.mineSent.where((e) => e.kind == Friends.sinceAsk).length >= 3);
    expect(w.mac.mineSent.where((e) => e.kind == Friends.sinceAsk).last.body['s'], closeTo(DateTime.now().millisecondsSinceEpoch - Friends.sinceBack.inMilliseconds, 10000));
  });

  test('only a listed device the hub vouches for is answered, and one device not again at once', () async {
    final w = await pair({'@ben': <PastRow>[(t: 'hi', at: now - hour, o: false)]}, macApp: AppState());
    await until(() => w.mac.pastKept.isNotEmpty);
    w.phone.onList = {'device-real-pc'};
    final before = w.phone.mineSent.length;
    for (final from in [null, 'hub-a-thief', 'hub-${w.mac.device}']) {
      w.phone.arriveFrom('mine', '', Envelope(kind: Friends.sinceAsk, body: {'n': 'thief-${from ?? 'none'}', 'd': 'device-real-pc', 's': 0}), device: from);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.phone.mineSent.skip(before).where((e) => e.kind == Friends.historyKind), isEmpty);
    // The PC itself, through the hub: answered; asked again straight away, not.
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.sinceAsk, body: {'n': 'pc', 'd': 'device-real-pc', 's': 0}), device: 'hub-device-real-pc');
    await until(() => w.phone.mineSent.skip(before).any((e) => e.kind == Friends.historyKind && e.body['n'] == 'pc'));
    final answered = w.phone.mineSent.length;
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.sinceAsk, body: {'n': 'pc-again', 'd': 'device-real-pc', 's': 0}), device: 'hub-device-real-pc');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.phone.mineSent.length, answered);
  });

  test('parts for an asking that is not this device\'s are passed over', () async {
    final w = await pair({}, macApp: AppState());
    await until(() => w.mac.mineSent.any((e) => e.kind == Friends.sinceAsk));
    w.mac.arriveFrom('mine', '', Envelope(kind: Friends.historyKind, body: {'n': 'someone-else', 'a': '@ben', 'r': [['planted', now, 0]]}), device: 'hub-x');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(w.mac.pastKept, isEmpty);
  });

  group('circles another device of the account is in', () {
    tearDown(() async {
      await Circles.instance.clear();
    });

    Circle circle(String d, {int version = 1, String name = 'OnlyGhosts'}) => Circle(
          seed: d * 64,
          owner: '',
          manifest: CircleManifest(owner: '', version: version, name: name, hue: 'indigo', icon: 'sparkles', spaces: [CircleSpace(seed: '${d}a' * 32, name: 'General', kind: SpaceKind.text)]),
        );

    test('are taken in, once, with nobody said to have joined; one held here is left as it is', () {
      Circles.instance.join(circle('1'));
      final both = jsonDecode(jsonEncode([circle('1').toJson(), circle('2', name: 'Book club').toJson()])) as List;
      expect(Circles.instance.fromAccount(both), 1);
      expect(Circles.instance.all.map((c) => c.name).toSet(), {'OnlyGhosts', 'Book club'});
      expect(Circles.instance.fromAccount(both), 0, reason: 'nothing new the second time');
      expect(Circles.instance.all, hasLength(2));
      expect(Circles.instance.fromAccount(['not a circle', 7, null]), 0);
    });
  });
}
