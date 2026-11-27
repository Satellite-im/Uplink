// GMFB-53 (@kevin): "Upon logging in on web, none of my messages appear in the sidebar and only my circles appear."
// The account's backup carries friends and circles, never conversations, and the copies an account's devices pass
// each other (Friends.copyKind) carry only what is said from then on: so any device signed in on (a browser, an iPhone
// or a computer of its own) had its friends and an empty list. Now a device asks its account's other devices for the
// conversations they hold until one answers to the end, and keeps them in place (Friends.historyAsk, historyKind,
// historyGot; UsernameChats history and keepHistory). With what the independent review of it found (H1-H6).
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/me/me.dart' show AppMeStore;
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/standalone/chats.dart';

import 'support/fake_friends.dart';

Future<void> until(bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A friend by username, as Buddies keeps one.
Buddy friend(String username) => Buddy.fromJson({'u': username, 'i': 'id-$username', 'k': base64Encode(List.filled(65, 4)), 's': 'yes'})!;

class _Relay implements AccountRelay {
  @override
  String get hubId => '';
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async => {'known': false};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    Friends.historyPace = Duration.zero;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
  });

  /// Kevin's phone, holding [held], and a browser of his signed in after: the two devices of one account.
  Future<({FakePort phone, FakePort browser, Friends onPhone, Friends onBrowser})> pair(Map<String, List<PastRow>> held, {AppState? phoneApp, AppState? browserApp, bool startBrowser = true}) async {
    final phone = FakePort('@kevin'), browser = FakePort('@kevin'), ben = FakePort('@ben');
    for (final p in [phone, browser]) {
      p.other = ben;
      p.stand('@ben', friend: 'yes');
    }
    ben.other = phone;
    phone.pastHeld.addAll(held);
    phone.twin = browser;
    browser.twin = phone;
    final onPhone = Friends(phone), onBrowser = Friends(browser);
    addTearDown(onPhone.shutdown);
    addTearDown(onBrowser.shutdown);
    await onPhone.start(phoneApp);
    if (startBrowser) await onBrowser.start(browserApp);
    return (phone: phone, browser: browser, onPhone: onPhone, onBrowser: onBrowser);
  }

  test('a device signed in on asks, another answers it to the end, and it keeps what it was given and asks no more', () async {
    final app = AppState();
    final held = {
      '@ben': <PastRow>[(t: 'Dinner at 8?', at: 1000, o: true), (t: 'Sure!', at: 2000, o: false)],
      // Too long for one part: in parts, the newest [historyMost] of it.
      '@amy': [for (var i = 0; i < 400; i++) (t: 'line $i ${'x' * 400}', at: 10000 + i, o: i.isEven)],
    };
    final w = await pair(held, browserApp: app);
    await until(() => app.flag('history_done', fallback: false));
    expect(w.browser.pastKept['@ben'], held['@ben']);
    expect(w.browser.pastKept['@amy'], held['@amy']!.sublist(400 - Friends.historyMost));
    expect(w.phone.mineSent.where((e) => e.kind == Friends.historyKind).length, greaterThan(3), reason: 'Amy\'s in parts, then the end');
    // It said it had it all.
    await until(() => w.browser.mineSent.any((e) => e.kind == Friends.historyGot));
    expect(w.phone.pastKept, isEmpty, reason: 'the phone kept nothing of its own answer');
    // Started again: done, so not asked again.
    final asked = w.browser.mineSent.where((e) => e.kind == Friends.historyAsk).length;
    await w.onBrowser.shutdown();
    final again = Friends(w.browser);
    addTearDown(again.shutdown);
    await again.start(app);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(w.browser.mineSent.where((e) => e.kind == Friends.historyAsk).length, asked);
  });

  // H2 (P1, P2): every part goes by the real route, whose packets are 60 KB at most; FakePort refuses a longer one.
  test('every part fits a route: words full of quotes and long lines are counted as the JSON that goes, and one message too long is cut', () async {
    final held = {
      '@ben': [for (var i = 0; i < 300; i++) (t: '"' * 200, at: 1000 + i, o: true)],
      '@amy': [for (var i = 0; i < 300; i++) (t: 'y\n' * 115, at: 5000 + i, o: false)],
      '@cat': <PastRow>[(t: 'z' * 100000, at: 9000, o: true), (t: 'after it', at: 9001, o: false)],
    };
    final app = AppState();
    final w = await pair(held, browserApp: app);
    await until(() => app.flag('history_done', fallback: false));
    for (final e in w.phone.mineSent) {
      expect(e.encode().length, lessThanOrEqualTo(HubCarrier.maxPacket - 64));
    }
    expect(w.browser.pastKept['@ben']!.length, 300);
    expect(w.browser.pastKept['@amy']!.length, 300);
    expect(w.browser.pastKept['@cat']!.map((r) => r.t.length).toList(), [lessThan(100000), 'after it'.length]);
    expect(w.browser.pastKept['@cat']!.first.t, allOf(startsWith('zzzz'), endsWith(Friends.cutNote)));
  });

  // D1: cut on a letter's edge, never between the two halves of one written as two code units.
  test('a message cut to fit is cut between letters and says so', () async {
    final app = AppState();
    final w = await pair({'@ben': <PastRow>[(t: '😀' * 40000, at: 1, o: true)]}, browserApp: app);
    await until(() => app.flag('history_done', fallback: false));
    final t = w.browser.pastKept['@ben']!.single.t;
    expect(t, endsWith(Friends.cutNote));
    expect(utf8.decode(utf8.encode(t)), t, reason: 'no half of a letter left over');
    expect(t.replaceAll(Friends.cutNote, '').runes.every((r) => r == 0x1F600), isTrue);
  });

  test('a part no route takes is not passed over: the answer stops, and the device is answered when it asks again', () async {
    final app = AppState(), phoneApp = AppState();
    final w = await pair({'@ben': <PastRow>[(t: 'hi', at: 1, o: true)]}, browserApp: app, phoneApp: phoneApp, startBrowser: false);
    // The account's mailbox full for whatever the phone sends.
    w.phone.mineRefused = true;
    await w.onBrowser.start(app);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(app.flag('history_done', fallback: false), isFalse);
    expect(phoneApp.choice('history_answered', '{}'), '{}', reason: 'nothing recorded as answered');
    // The mailbox has room again; the browser's next start asks again (made due here), and is answered.
    w.phone.mineRefused = false;
    app.set('history_last', '1');
    await w.onBrowser.shutdown();
    final again = Friends(w.browser);
    addTearDown(again.shutdown);
    await again.start(app);
    await until(() => app.flag('history_done', fallback: false));
    expect(w.browser.pastKept['@ben'], [(t: 'hi', at: 1, o: true)]);
  });

  // H4: the answer can be taken by another device (an old build) or never come; the device keeps asking, further apart.
  test('no answer: asked again at a later start once due, further apart each time; a device holding nothing says so', () async {
    final app = AppState();
    final lone = FakePort('@kevin'); // its asking reaches a device that never answers (an old build)
    lone.twin = FakePort('@kevin');
    final f = Friends(lone);
    addTearDown(f.shutdown);
    await f.start(app);
    await until(() => lone.mineSent.any((e) => e.kind == Friends.historyAsk));
    expect(app.choice('history_tries', ''), '1');
    // Started again at once: not due yet.
    await f.shutdown();
    await f.start(app);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(lone.mineSent.where((e) => e.kind == Friends.historyAsk).length, 1);
    expect(Friends.historyBackoff(0), const Duration(seconds: 30));
    expect(Friends.historyBackoff(3), const Duration(minutes: 4));
    expect(Friends.historyBackoff(40), const Duration(hours: 12));
    // Once due, asked again.
    app.set('history_last', '1');
    await f.shutdown();
    await f.start(app);
    await until(() => lone.mineSent.where((e) => e.kind == Friends.historyAsk).length == 2);
    expect(app.choice('history_tries', ''), '2');
  });

  // C1: a fresh device that had the asking first (another browser) answers with nothing; that ends nothing.
  test('an answer with nothing ends no asking, until every other listed device has said so; one with something ends it', () async {
    final app = AppState();
    final w = await pair(const {}, browserApp: app);
    await until(() => w.phone.mineSent.any((e) => e.kind == Friends.historyKind));
    final end = w.phone.mineSent.where((e) => e.kind == Friends.historyKind).single.body;
    expect(end, allOf(containsPair('e', 1), containsPair('c', 0), containsPair('d', w.phone.device)));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(app.flag('history_done', fallback: false), isFalse);
    expect(app.choice('history_empty', ''), w.phone.device);
    // Where this device can read the account's list and every other device on it has said nothing: done.
    final app2 = AppState();
    final v = await pair(const {}, browserApp: app2, startBrowser: false);
    v.browser.listing = [v.browser.device, v.phone.device];
    await v.onBrowser.start(app2);
    await until(() => app2.flag('history_done', fallback: false));
    expect(app2.flag('history_done', fallback: false), isTrue);
    // And an answer that carried something ends it however many others there are.
    final app3 = AppState();
    final x = await pair({'@ben': <PastRow>[(t: 'hi', at: 1, o: true)]}, browserApp: app3, startBrowser: false);
    x.browser.listing = [x.browser.device, x.phone.device, 'a-mac-that-never-answers'];
    await x.onBrowser.start(app3);
    await until(() => app3.flag('history_done', fallback: false));
    expect(app3.flag('history_done', fallback: false), isTrue);
  });

  // B1: the device an asking names must be the one the hub says sent it, and listed with that hub name.
  test('an asking naming a listed device it didn\'t come from is not answered; askings go by the hub alone', () async {
    final w = await pair({'@ben': <PastRow>[(t: 'hi', at: 1, o: false)]});
    await until(() => w.browser.pastKept.isNotEmpty);
    expect(w.browser.mineSent.where((e) => e.kind == Friends.historyAsk).every((e) => w.browser.hubOnly.contains(e.id)), isTrue);
    w.phone.onList = {'device-real-mac'};
    final before = w.phone.mineSent.length;
    // Someone holding the account's key names the Mac: from no device the hub vouches for (the direct route, a relay
    // from before), or from their own.
    for (final from in [null, 'hub-a-thief', 'hub-${w.browser.device}']) {
      w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyAsk, body: {'n': 'thief-${from ?? 'none'}', 'd': 'device-real-mac'}), device: from);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.phone.mineSent.skip(before).where((e) => e.kind == Friends.historyKind), isEmpty);
    // The Mac itself, through the hub: answered.
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyAsk, body: {'n': 'mac', 'd': 'device-real-mac'}), device: 'hub-device-real-mac');
    await until(() => w.phone.mineSent.skip(before).any((e) => e.kind == Friends.historyKind && e.body['n'] == 'mac'));
    expect(w.phone.mineSent.skip(before).where((e) => e.kind == Friends.historyKind && e.body['n'] == 'mac'), isNotEmpty);
  });

  // B2: "had it all" ends the answering of a device only for the asking it was answered, said by that device.
  test('a forged "had it" changes nothing; the real one, kept with the choices, stops answers to that device for good', () async {
    final phoneApp = AppState();
    final w = await pair(const {}, phoneApp: phoneApp, startBrowser: false);
    w.phone.pastHeld['@ben'] = [(t: 'hi', at: 1, o: false)];
    Map entry(String d) => ((jsonDecode(phoneApp.choice('history_answered', '{}')) as Map)[d] as Map?) ?? const {};
    // Before any answer: taken from nobody.
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyGot, body: {'n': 'whatever', 'd': 'device-mac'}), device: 'hub-device-mac');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(phoneApp.choice('history_answered', '{}'), '{}');
    // The Mac asks and is answered; a "had it" for another asking, or from another device, is passed over.
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyAsk, body: {'n': 'mac-n', 'd': 'device-mac'}), device: 'hub-device-mac');
    await until(() => entry('device-mac')['n'] == 'mac-n');
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyGot, body: {'n': 'other-n', 'd': 'device-mac'}), device: 'hub-device-mac');
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyGot, body: {'n': 'mac-n', 'd': 'device-mac'}), device: 'hub-a-thief');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(entry('device-mac')['got'], isNot(true));
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyGot, body: {'n': 'mac-n', 'd': 'device-mac'}), device: 'hub-device-mac');
    await until(() => entry('device-mac')['got'] == true);
    // The phone started again, a day on: the Mac asking again is not answered.
    await w.onPhone.shutdown();
    final again = Friends(w.phone);
    addTearDown(again.shutdown);
    phoneApp.set('history_answered', jsonEncode({'device-mac': {...entry('device-mac'), 'at': 1}}));
    await again.start(phoneApp);
    final before = w.phone.mineSent.length;
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyAsk, body: {'n': 'mac-n2', 'd': 'device-mac'}), device: 'hub-device-mac');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.phone.mineSent.skip(before).where((e) => e.kind == Friends.historyKind), isEmpty);
    // One that never said it had it is answered again a day on.
    phoneApp.set('history_answered', jsonEncode({'device-mac': {'n': 'mac-n', 'h': 'hub-device-mac', 'at': 1}}));
    w.phone.arriveFrom('mine', '', Envelope(kind: Friends.historyAsk, body: {'n': 'mac-n3', 'd': 'device-mac'}), device: 'hub-device-mac');
    await until(() => w.phone.mineSent.skip(before).any((e) => e.kind == Friends.historyKind));
    expect(w.phone.mineSent.skip(before).where((e) => e.kind == Friends.historyKind), isNotEmpty);
  });

  test('an answer cut at its most parts says so, and the list says older conversations stay on the other device', () async {
    final app = AppState();
    final held = {for (var c = 0; c < Friends.historyParts + 3; c++) '@f$c': <PastRow>[(t: 'hi $c', at: 1000 + c, o: true)]};
    final w = await pair(held, browserApp: app);
    await until(() => app.flag('history_done', fallback: false));
    expect(w.phone.mineSent.where((e) => e.kind == Friends.historyKind).last.body, allOf(containsPair('e', 2), containsPair('c', Friends.historyParts)));
    expect(app.flag('history_partial', fallback: false), isTrue);
    // The newest conversations are the ones that came.
    expect(w.browser.pastKept.keys, contains('@f${Friends.historyParts + 2}'));
    expect(w.browser.pastKept.keys, isNot(contains('@f0')));
  });

  // H5: a stolen account key can't pull the past on demand.
  test('only a device on the account\'s list is answered, once (kept), and the person is told where it went', () async {
    final phoneApp = AppState();
    final w = await pair({'@ben': <PastRow>[(t: 'hi', at: 1, o: true)]}, phoneApp: phoneApp, startBrowser: false);
    w.phone.onList = {}; // the asker isn't on the list: removed, or someone with the key who never signed in
    final app = AppState();
    await w.onBrowser.start(app);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.phone.mineSent.where((e) => e.kind == Friends.historyKind), isEmpty);
    expect(w.browser.pastKept, isEmpty);
    // Listed: answered, and said in Settings › Devices.
    w.phone.onList = {w.browser.device};
    app.set('history_last', '1');
    await w.onBrowser.shutdown();
    final again = Friends(w.browser);
    addTearDown(again.shutdown);
    await again.start(app);
    await until(() => app.flag('history_done', fallback: false));
    expect(phoneApp.choice('history_note', ''), startsWith('History sent to Device ${w.browser.device} on '));
    Map entry() => ((jsonDecode(phoneApp.choice('history_answered', '{}')) as Map)[w.browser.device] as Map?) ?? const {};
    await until(() => entry()['got'] == true);
    expect(entry(), allOf(containsPair('got', true), containsPair('h', w.browser.hubDevice)));
    // The same device asking again (its choices lost) is not answered a second time, by a phone started again too.
    await w.onPhone.shutdown();
    final phoneAgain = Friends(w.phone);
    addTearDown(phoneAgain.shutdown);
    await phoneAgain.start(phoneApp);
    await again.shutdown();
    final before = w.phone.mineSent.length;
    final third = Friends(w.browser);
    addTearDown(third.shutdown);
    await third.start(AppState());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(w.phone.mineSent.length, before);
  });

  // H3 (P3): the row is stamped with the envelope's time, so every device holds a message at one moment.
  test('a message sent is kept at the moment its envelope says, which is what its copy carries', () async {
    final phone = FakePort('@kevin'), ben = FakePort('@ben');
    phone.other = ben;
    ben.other = phone;
    phone.stand('@ben', friend: 'yes');
    ben.stand('@kevin', friend: 'yes');
    phone.twin = FakePort('@kevin');
    final f = Friends(phone), b = Friends(ben);
    addTearDown(f.shutdown);
    addTearDown(b.shutdown);
    await f.start();
    await b.start();
    expect(await f.sendText('@ben', 'see you at 8'), isTrue);
    await until(() => phone.mineSent.any((e) => e.kind == Friends.copyKind));
    final copy = phone.mineSent.firstWhere((e) => e.kind == Friends.copyKind);
    expect(phone.keptAt.values.single, copy.body['at']);
  });

  group('kept by UsernameChats', () {
    final friends = [friend('ben'), friend('amy')];
    UsernameChats chats() => UsernameChats(save: () {}, buddies: () => friends);

    test('in place by when each was written, once each, as past messages: nothing unread', () {
      final c = chats();
      c.textIn('@ben', 'live, after sign-in', 5000);
      final t = c.threadWith('@ben')..unread = false;
      final past = <PastRow>[(t: 'first', at: 1000, o: true), (t: 'second', at: 2000, o: false), (t: 'live, after sign-in', at: 5000, o: false)];
      expect(c.keepHistory('@ben', past), 2);
      expect([for (final r in t.rows) r.body], ['first', 'second', 'live, after sign-in']);
      expect(t.rows.first.state, 'sent');
      expect(t.unread, isFalse);
      expect(c.keepHistory('@ben', past), 0);
      expect(UsernameChats.pastRows([['a', 1, 1], ['b', 2, 0], 'junk', [3, 4, 5]]), [(t: 'a', at: 1, o: true), (t: 'b', at: 2, o: false)]);
    });

    // P3: two devices hold one message a few milliseconds apart (one from before the stamping fix).
    test('the same words the same way a moment apart are one message; the same words much later are another', () {
      final c = chats();
      expect(c.keepHistory('@ben', [(t: 'see you at 8', at: 1700000000000, o: true)]), 1);
      expect(c.keepHistory('@ben', [(t: 'see you at 8', at: 1700000000004, o: true)]), 0);
      expect(c.keepHistory('@ben', [(t: 'see you at 8', at: 1700000000004, o: false)]), 1, reason: 'theirs, not ours');
      expect(c.keepHistory('@ben', [(t: 'see you at 8', at: 1700000600000, o: true)]), 1, reason: 'ten minutes on');
    });

    // P4, H6: nothing kept for anyone who isn't a friend, and no more than [historyMost] at once.
    test('no conversation made for anyone who isn\'t a friend; at most 300 at once; quick with a long conversation', () {
      final c = chats();
      for (var i = 0; i < 50; i++) {
        expect(c.keepHistory('@nobody$i', [(t: 'x', at: 1, o: false)]), 0);
      }
      expect(c.threads, isEmpty);
      expect(c.keepHistory('@amy', [for (var i = 0; i < 400; i++) (t: 'x$i', at: 10000 + i, o: false)]), 300);
      final clock = Stopwatch()..start();
      for (var k = 0; k < 20; k++) {
        c.keepHistory('@amy', [for (var i = 0; i < 300; i++) (t: 'y$k $i', at: 50000 + k * 1000 + i, o: true)]);
      }
      expect(c.threadWith('@amy').rows.length, 300 + 20 * 300);
      expect(clock.elapsedMilliseconds, lessThan(3000));
    });

    // H1 (P5): another account's conversations, kept at a plain sign-out, go to nobody.
    test('only conversations with a friend of the account signed in now are handed over', () {
      final c = chats();
      c.textIn('@alice_of_account_a', 'my bank pin is 1234', 1000);
      c.textIn('@ben', 'hello', 2000);
      expect([for (final h in c.history()) h.address], ['@ben']);
    });
  });

  // H6: what one asking takes in is bounded per address, however many parts come.
  test('one asking takes at most 300 messages of a conversation, however many parts arrive', () async {
    final app = AppState();
    final w = await pair(const {}, browserApp: app, startBrowser: false);
    await w.onBrowser.start(app);
    await until(() => w.browser.mineSent.any((e) => e.kind == Friends.historyAsk));
    final n = w.browser.mineSent.firstWhere((e) => e.kind == Friends.historyAsk).body['n'];
    for (var k = 0; k < 10; k++) {
      w.browser.arriveFrom('mine', '', Envelope0.part(n as String, '@ben', [for (var i = 0; i < 100; i++) ['m$k $i', k * 1000 + i, 0]]));
    }
    await until(() => (w.browser.pastKept['@ben']?.length ?? 0) >= 300);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(w.browser.pastKept['@ben']!.length, 300);
  });

  // H1: the asking and the answers are the account's, let go at sign-out with the rest.
  test('signing out lets go of the history\'s asking, answers and note, so the next account asks for its own', () async {
    final app = AppState();
    for (final k in ['history_n', 'history_tries', 'history_last', 'history_answered', 'history_note']) {
      app.set(k, 'x');
    }
    app.setFlag('history_done', true);
    final was = Account.instance;
    Account.instance = Account(relay: _Relay(), port: SmsAccountPort(), store: AppMeStore(app), profiles: AppAccountProfiles());
    addTearDown(() => Account.instance = was);
    await AppAccountProfiles().forget();
    for (final k in ['history_n', 'history_tries', 'history_last', 'history_answered', 'history_note']) {
      expect(app.choice(k, ''), '', reason: k);
    }
    expect(app.flag('history_done', fallback: false), isFalse);
  });
}

/// A part of an answer, as a device of the account sends it.
class Envelope0 {
  static Envelope part(String n, String address, List<List<Object>> rows) => Envelope(kind: Friends.historyKind, body: {'n': n, 'a': address, 'r': rows});
}
