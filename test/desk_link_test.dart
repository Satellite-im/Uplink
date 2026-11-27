import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/link/crypto.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/link/session.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_relay/relay.dart';

import 'support/fake_phone.dart';

/// The Mac's link to the phone, start to end, in one process: a stand-in phone (test/support/fake_phone.dart) on a
/// port of this machine as it would be on the local network, and the real relay (relay/) on another. Real sockets,
/// real sealing; only the phone is made up.
class MemoryStore implements LinkStore {
  PairedPhone? kept;
  @override
  Future<PairedPhone?> load() async => kept;
  @override
  Future<void> save(PairedPhone phone) async => kept = phone;
  @override
  Future<void> clear() async => kept = null;
}

/// Waits for [test] to hold. The limit is long because the Mac may be busy (another build, an emulator): it is a
/// limit on waiting for something to happen, not a pause, so a quiet machine never spends it.
Future<void> until(bool Function() test, {String? what, int ms = 30000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!test() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(test(), isTrue, reason: what ?? 'never happened');
}

void main() {
  late Relay relay;
  late String relayUrl;
  late FakePhone phone;
  final links = <PhoneLink>[];

  setUpAll(() {
    // The phone is looked for often, so a test does not wait as a person would.
    PhoneLink.lookEvery = const Duration(milliseconds: 80);
    PhoneLink.upgradeEvery = const Duration(milliseconds: 150);
    PhoneLink.connectTimeout = const Duration(milliseconds: 400);
    PhoneLink.helloTimeout = const Duration(seconds: 2);
  });

  setUp(() async {
    relay = Relay();
    relayUrl = 'ws://127.0.0.1:${await relay.start(port: 0)}/relay';
    phone = FakePhone();
    await phone.listen();
  });

  tearDown(() async {
    for (final l in links) {
      l.dispose();
    }
    links.clear();
    await phone.stop();
    await relay.stop();
  });

  PhoneLink mac(LinkStore store, {bool local = true}) {
    final link = PhoneLink(store: store, name: "Matt's MacBook", app: '0.7.0', given: local ? [phone.peer] : const []);
    links.add(link);
    return link;
  }

  /// Pairs [link] with the phone by [mode], as the two wizards would: the code shown, scanned, the digits compared
  /// and "They match" on both.
  Future<void> pair(PhoneLink link, String mode, {String? phoneMode}) async {
    await link.start();
    final attempt = link.beginPairing(mode: mode, relay: relayUrl);
    expect(attempt.phase, 'showing');
    phone.scan(attempt.offer.text, mode: phoneMode);
    if (mode != 'local') await phone.joinPairingRelay();
    await until(() => attempt.phase == 'code', what: 'the two never met');
    expect(attempt.code, phone.code);
    expect(attempt.code, hasLength(6));
    expect(attempt.phoneName, 'Fold');
    // Nothing is paired until both say so.
    expect(link.phone, isNull);
    link.confirmPairing();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(link.phone, isNull);
    expect(phone.keys, isEmpty);
    phone.confirm();
    await until(() => attempt.phase == 'done' && link.phone != null, what: 'never paired');
    link.pairingShown();
    expect(phone.keys.keys.single, link.phone!.id);
    // The phone lets go of the channel made for pairing, and joins the pairing's own (android DeskService.apply).
    await phone.leaveRelay();
    if (link.phone!.mode != 'local') await phone.joinPairedRelay(link.phone!.id, relayUrl);
    await until(() => link.online, what: 'never connected after pairing');
  }

  test('pairs over the local network, lists conversations, hears a new text, sends one', () async {
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'local');
    expect(link.via, 'local');
    expect(link.phone!.mode, 'local');
    expect(store.kept!.host, '127.0.0.1');
    expect(store.kept!.port, phone.port);
    // The relay was never dialed.
    expect(relay.channelCount, 0);

    final list = (await link.request('conversations')) as List;
    expect(list.map((c) => (c as Map)['snippet']), ['See you at 7', 'Call me']);

    final heard = <int>[];
    link.events.stream.listen((e) => heard.add(e.args['thread'] as int));
    phone.arrive(7, 'Running late');
    await until(() => heard.contains(7), what: 'the new text was never said');
    final messages = (await link.request('messages', {'thread': 7})) as List;
    expect((messages.first as Map)['body'], 'Running late');

    final sent = (await link.request('send', {'key': 'k1', 'addresses': ['+15550100'], 'body': 'No rush'})) as Map;
    expect(sent['thread'], 7);
    expect(phone.sent.single.body, 'No rush');
    // What the phone will not do for a computer comes back as its words.
    await expectLater(link.request('e2eReset', {'thread': 7}), throwsA(isA<PhoneError>()));
  });

  test('pairs through the relay, and the same works there', () async {
    final link = mac(MemoryStore(), local: false);
    await pair(link, 'relay');
    expect(link.via, 'relay');
    expect(phone.via, 'relay');
    // The pairing's own channel is all the relay holds: the ten-minute one is gone with the pairing's connection.
    await until(() => relay.channelCount == 1);
    expect((await link.request('conversations') as List).length, 2);
    final heard = <int>[];
    link.events.stream.listen((e) => heard.add(e.args['thread'] as int));
    phone.arrive(7, 'Through the relay');
    await until(() => heard.contains(7));
    await link.request('send', {'key': 'k2', 'addresses': ['+15550100'], 'body': 'Got it'});
    expect(phone.sent.single.body, 'Got it');
    // A picture, in pieces, each smaller than a frame.
    final bridge = LinkCalls(link, DeskStore(Directory.systemTemp.createTempSync('ghost-desk-test'), keychain: false));
    final picture = await bridge.invokeMethod<Object>('part', {'id': 5});
    expect(picture, phone.picture);
  });

  test('with both, the local network is used first, the relay when it goes, and the local network again when it is back', () async {
    final link = mac(MemoryStore());
    await pair(link, 'both');
    // Both were there to use: local was taken, and the phone was not asked through the relay once paired.
    expect(link.via, 'local');
    expect(phone.hellos.last, 'local');
    final relayHellosBefore = phone.hellos.where((v) => v == 'relay').length;

    await phone.leaveLocal();
    await until(() => link.via == 'relay', what: 'never fell back to the relay');
    expect((await link.request('conversations') as List).length, 2);
    expect(phone.hellos.where((v) => v == 'relay').length, relayHellosBefore + 1);

    await phone.rejoinLocal();
    await until(() => link.via == 'local', what: 'never came back to the local network');
    await until(() => phone.via == 'local');
    // The Mac said it was leaving the relay's connection.
    expect(phone.heard, contains('bye'));
    expect((await link.request('conversations') as List).length, 2);
  });

  test('the phone\'s choice of how to connect is the pairing\'s, and a change later reaches the other', () async {
    final store = MemoryStore();
    final link = mac(store);
    // The Mac offered both; on the phone, local only was chosen before "They match".
    await pair(link, 'both', phoneMode: 'local');
    expect(link.phone!.mode, 'local');
    expect(link.via, 'local');
    final id = link.phone!.id;

    await link.setMode('both');
    await until(() => phone.modes[id] == 'both', what: 'the phone never heard the change');
    phone.setMode(id, 'relay');
    await until(() => link.phone!.mode == 'relay' && store.kept!.mode == 'relay', what: 'the Mac never heard the change');
  });

  test('a sticker, pictures and what the phone\'s screens do go through the phone, in pieces where they are large', () async {
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'local');
    final dir = Directory.systemTemp.createTempSync('ghost-desk-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bridge = LinkCalls(link, DeskStore(dir, keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    // The phone says what it does for a computer, and the screens offer that.
    await until(() => bridge.caps.isNotEmpty, what: 'the phone was never asked what it does');
    expect(Sms.can('sendPictures') && Sms.can('sendVoice') && Sms.can('sendSticker') && Sms.can('deleteMessage') && Sms.can('editMessage'), isTrue);
    expect(Sms.can('e2eReset'), isFalse);

    // A sticker larger than a frame carries: handed over in pieces, sent once, whole.
    final sticker = Uint8List.fromList(List.generate(900 * 1024, (i) => i % 251));
    expect(await Sms.instance.sendSticker(['+15550100'], sticker, 'ghost-sticker-mischief-04.png'), 7);
    expect(phone.handed.single.what, 'sticker');
    expect(phone.handed.single.name, 'ghost-sticker-mischief-04.png');
    expect(phone.handed.single.bytes.single, sticker);
    expect(phone.uploads, isEmpty);

    // Two pictures chosen on the Mac, with words: read from where they are, handed over, sent by the phone.
    final one = File('${dir.path}/IMG 0001.JPG')..writeAsBytesSync(List.generate(500 * 1024, (i) => i % 7));
    final two = File('${dir.path}/shot.png')..writeAsBytesSync(List.generate(70 * 1024, (i) => i % 11));
    expect(await Sms.instance.send(['+15550100'], 'look', attachments: [one.path, two.path]), 7);
    final pictures = phone.handed.last;
    expect(pictures.what, 'pictures');
    expect(pictures.name, 'IMG 0001.JPG,shot.png');
    expect(pictures.body, 'look');
    expect(pictures.bytes[0], one.readAsBytesSync());
    expect(pictures.bytes[1], two.readAsBytesSync());
    // What is not a picture is not sent, and says so; nor is a file that is not there.
    final notes = File('${dir.path}/notes.pdf')..writeAsBytesSync([1, 2, 3]);
    await expectLater(Sms.instance.send(['+15550100'], '', attachments: [notes.path]), throwsA(isA<PhoneError>()));
    await expectLater(Sms.instance.send(['+15550100'], '', attachments: ['${dir.path}/gone.jpg']), throwsA(isA<PhoneError>()));
    expect(phone.handed, hasLength(2));
    expect(LinkCalls.pictureType('a.HEIC'), 'image/heic');
    expect(LinkCalls.pictureType('a.tiff'), isNull);

    // What the phone's screens do to what is kept: asked of the phone, and what was read is read again.
    final changes = <int>[];
    final sub = Sms.instance.changes.stream.listen(changes.add);
    addTearDown(sub.cancel);
    final first = (await Sms.instance.messages(7)).first;
    await Sms.instance.deleteMessage(first);
    await Sms.instance.e2eOff('+15550100');
    await Sms.instance.deleteThreads([9]);
    expect(phone.did, ['deleteMessage ${first.id}', 'e2eOff +15550100', 'deleteThreads [9]']);
    await until(() => changes.where((c) => c == -1).length >= 3, what: 'the screens were never told to read again');
    expect((await Sms.instance.conversations()).map((c) => c.id), [7]);
    // How long a voice message may run is asked of the phone, whose carrier decides.
    expect(((await link.request('voiceLimit')) as Map)['seconds'], 91);
  });

  test('the number is the phone\'s, and is verified through the phone', () async {
    final link = mac(MemoryStore());
    await pair(link, 'local');
    final dir = Directory.systemTemp.createTempSync('ghost-desk-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bridge = LinkCalls(link, DeskStore(dir, keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    await until(() => bridge.caps.contains('me'), what: 'the phone was never asked what it does');
    // Matt, 2026-11-14: "on desktop the phone number reads as unknown and is not proxying the verification process".
    expect(await Sms.instance.ownNumber(), '+14436537451');

    var linked = <String, String>{};
    phone.me = (what) => switch (what['dir']) {
          'state' => {'ready': true, 'ways': {'phone': 'text'}, 'links': linked},
          'text' => {'dir': 'text', 'p': 'phone', 'handle': what['handle']},
          'code' when what['code'] == '240021' => {'dir': 'linked', 'p': 'phone', 'handle': (linked = {'phone': '${what['handle']}'})['phone']},
          _ => throw 'That is not the code. Look at the text again, or ask for a new one.',
        };
    final me = Me.forTest();
    await me.followPhone(Sms.instance.me);
    expect(me.ready, isTrue);
    expect(me.texts, isTrue);
    expect(me.number, isNull);
    expect(await me.textCode('(443) 653-7451'), '+14436537451');
    await expectLater(me.tryCode('+14436537451', '000000'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('not the code'))));
    await me.tryCode('+14436537451', '240021');
    expect(me.number, '+14436537451');
    expect(phone.meAsked.map((w) => w['dir']), ['state', 'text', 'code', 'code']);

    // A phone whose app is not open says so, in words.
    phone.me = null;
    final later = Me.forTest();
    await later.followPhone(Sms.instance.me);
    expect(later.ready, isFalse);
    expect(later.phoneSaid, contains('Open Uplink on your phone'));
  });

  test('a phone whose app is older does none of the newer things, and the screens offer none', () async {
    phone.old = true;
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'local');
    final dir = Directory.systemTemp.createTempSync('ghost-desk-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bridge = LinkCalls(link, DeskStore(dir, keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(bridge.caps, isEmpty);
    expect(Sms.can('sendPictures') || Sms.can('deleteMessage') || Sms.can('sendSticker'), isFalse);
    // Asked anyway, the phone's own words come back, and nothing is left half handed over.
    await expectLater(Sms.instance.sendSticker(['+15550100'], Uint8List.fromList([1, 2, 3]), 'ghost-sticker-ghost-01.png'), throwsA(isA<PhoneError>()));
    expect(await Sms.instance.e2eList(), isEmpty);
    // Its number is not known here, and the Me page says the phone needs the newer app to verify it.
    expect(await Sms.instance.ownNumber(), isNull);
    final me = Me.forTest();
    await me.followPhone(Sms.instance.me);
    expect(me.phoneSaid, contains('Update Uplink on your phone'));
    // What it always did, it still does.
    expect(await Sms.instance.send(['+15550100'], 'still texts'), 7);
  });

  test('what is typed while the phone is away waits, is shown as waiting, and is sent once when it is back', () async {
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'local');
    final bridge = LinkCalls(link, DeskStore(Directory.systemTemp.createTempSync('ghost-desk-test'), keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    final changes = <int>[];
    final sub = Sms.instance.changes.stream.listen(changes.add);
    addTearDown(sub.cancel);

    final before = await Sms.instance.conversations();
    expect(before.first.title, 'Maya');
    expect((await Sms.instance.messages(7)).single.body, 'See you at 7');

    await phone.leaveLocal();
    await until(() => !link.online);
    // Still shown from what was read last.
    expect((await Sms.instance.conversations()).length, 2);
    final thread = await Sms.instance.send(['+15550100'], 'Typed while you were away');
    expect(thread, 7);
    expect(bridge.waiting, 1);
    final shown = await Sms.instance.messages(7);
    expect(shown.first.body, 'Typed while you were away');
    expect(shown.first.state, 'waiting');
    expect(shown.first.outgoing, isTrue);
    expect(shown.last.body, 'See you at 7');
    expect(phone.sent, isEmpty);
    // A conversation the Mac has never seen cannot be started without the phone.
    await expectLater(Sms.instance.send(['+15559999'], 'Hello'), throwsA(isA<LinkDown>()));

    await phone.rejoinLocal();
    await until(() => phone.sent.isNotEmpty, what: 'the waiting text never went');
    await until(() => bridge.waiting == 0);
    expect(phone.sent.single.body, 'Typed while you were away');
    final after = await Sms.instance.messages(7);
    expect(after.first.body, 'Typed while you were away');
    expect(after.first.state, 'sent');
    expect(after.where((m) => m.body == 'Typed while you were away').length, 1);
    expect(changes, contains(-1));
  });

  test('a phone with a great many conversations hands them over a lot at a time, and what was read stays while it is away', () async {
    final link = mac(MemoryStore());
    await pair(link, 'local');
    phone.conversations = [
      for (var i = 0; i < 1200; i++)
        {'id': 1000 + i, 'date': 1700000000000 - i * 60000, 'people': [{'address': '+1555${(100000 + i)}', 'name': 'Person $i', 'photo': null}], 'snippet': 'Text $i', 'unread': false, 'error': false, 'archived': i == 700},
    ];
    final bridge = LinkCalls(link, DeskStore(Directory.systemTemp.createTempSync('ghost-desk-test'), keychain: false));
    await bridge.init();
    Sms.calls = bridge;

    // The first lot is what the list shows at once.
    final first = await Sms.instance.conversationsPage(limit: 40, pinned: true);
    expect(first.items.length, 40);
    expect(first.items.first.title, 'Person 0');
    expect(first.next, 40);
    // All of them, for whoever asks: never more than 250 at once, however many there are. (They are read behind
    // the first lot, to be kept: asking for all of them waits for that reading, and asks the phone nothing more.)
    final all = await Sms.instance.conversations();
    expect(all.length, 1200);
    expect(phone.asked.where((a) => a.limit == 250).length, 5);
    expect(phone.asked.every((a) => a.limit <= 250), isTrue);
    // Kept whole from here on: the list is answered at once with all of it, and the phone is not asked again
    // while it has said nothing changed.
    phone.asked.clear();
    final kept = await Sms.instance.conversationsPage(limit: 40, pinned: true);
    expect(kept.items.length, 1200);
    expect(kept.next, isNull);
    expect(phone.asked, isEmpty);
    expect(await Sms.instance.archivedCount(), 1);
    expect((await Sms.instance.conversationsPage(archived: true)).items.single.title, 'Person 700');
    expect((await Sms.instance.conversation(1005))!.title, 'Person 5');

    // The phone goes: what was read is still there to show.
    await phone.leaveLocal();
    await until(() => !link.online);
    final away = await Sms.instance.conversationsPage(limit: 40, pinned: true);
    expect(away.items.length, 1200);
    expect(away.next, isNull);
    expect((await Sms.instance.conversation(1005))!.title, 'Person 5');
    expect(await Sms.instance.archivedCount(), 1);
  });

  test('a conversation the first lot has newer words for is not put back by a later lot\'s older copy of it', () async {
    // A phone on a build before every lot was whole (android Store.conversationsPage): its first lot carries the
    // conversation as Google Messages' bridge has it, the newest RCS message, and a later lot carries it again as
    // Android has it, its last SMS. The list said the SMS (Matt, 2026-11-26: "they don't always show the last message").
    final link = mac(MemoryStore());
    await pair(link, 'local');
    phone.conversations = [
      for (var i = 0; i < 300; i++)
        {'id': 1000 + i, 'date': 1700000000000 - i * 60000, 'people': [{'address': '+1555${(100000 + i)}', 'name': 'Person $i', 'photo': null}], 'snippet': 'Text $i', 'unread': false, 'error': false, 'archived': false},
    ];
    phone.firstToo = [
      {'id': 1280, 'date': 1700000300000, 'people': [{'address': '+1555100280', 'name': 'Person 280', 'photo': null}], 'snippet': 'The RCS message, just now', 'unread': true, 'error': false, 'archived': false, 'bridged': true},
    ];
    final bridge = LinkCalls(link, DeskStore(Directory.systemTemp.createTempSync('ghost-desk-test'), keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    final all = await Sms.instance.conversations();
    expect(all.length, 300);
    expect([all.first.id, all.first.snippet, all.first.unread], [1280, 'The RCS message, just now', true]);
    expect(all.where((c) => c.id == 1280), hasLength(1));
    // And the list's own reading of what the computer keeps: the same.
    final page = await Sms.instance.conversationsPage(limit: 40, pinned: true);
    expect([page.items.first.id, page.items.first.snippet], [1280, 'The RCS message, just now']);
  });

  // --- what was read is kept (lib/desktop/cache.dart; Matt, 2026-11-14: "cache messages on the desktop app so that
  // we don't need to fetch them all from the phone every time, just fetching updates in the background") ------------

  /// A conversation of [count] texts on the phone, the newest first.
  void fill(int thread, int count) {
    phone.messages[thread] = [
      for (var i = count; i >= 1; i--)
        {'id': i, 'kind': 'sms', 'address': '+15550100', 'body': 'Text $i', 'date': 1700000000000 + i * 60000, 'outgoing': false, 'state': 'received', 'parts': const []},
    ];
  }

  test('a conversation read once is answered from what is kept, and only its newest are asked for when it changes', () async {
    final link = mac(MemoryStore());
    await pair(link, 'local');
    fill(7, 200);
    final bridge = LinkCalls(link, DeskStore(Directory.systemTemp.createTempSync('ghost-desk-test'), keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    // The first time there is nothing kept: the phone is asked, and waited for.
    final first = await Sms.instance.messages(7, limit: 120);
    expect(first.length, 120);
    expect(first.first.body, 'Text 200');
    expect(phone.askedMessages, [(thread: 7, limit: 120)]);
    // Again, and nothing has changed: answered from what is kept, the phone not asked.
    expect((await Sms.instance.messages(7, limit: 120)).length, 120);
    expect(phone.askedMessages.length, 1);
    // A text comes. The Mac asks for the conversation's newest few, joins them to what it keeps, and then tells
    // the screens, which read what is kept.
    final told = <int>[];
    final sub = Sms.instance.changes.stream.listen(told.add);
    phone.messages[7]!.insert(0, {'id': 201, 'kind': 'sms', 'address': '+15550100', 'body': 'Text 201', 'date': 1700000000000 + 201 * 60000, 'outgoing': false, 'state': 'received', 'parts': const []});
    phone.changed(7);
    await until(() => told.contains(7), what: 'the screens were never told');
    expect(phone.askedMessages.last, (thread: 7, limit: LinkCalls.window));
    final asked = phone.askedMessages.length;
    final after = await Sms.instance.messages(7, limit: 120);
    expect(phone.askedMessages.length, asked, reason: 'what was just read is not asked for again');
    expect(after.first.body, 'Text 201');
    expect(after.length, 120);
    expect(after.last.body, 'Text 82', reason: 'the older ones are the ones kept, with the oldest let go');
    // One deleted on the phone, among the newest: gone from what is kept too.
    phone.messages[7]!.removeWhere((m) => m['id'] == 199);
    phone.changed(7);
    await until(() => told.where((t) => t == 7).length >= 2);
    expect((await Sms.instance.messages(7, limit: 120)).map((m) => m.body), isNot(contains('Text 199')));
    // Reading back asks the phone for more than is kept, and waits for it.
    final more = await Sms.instance.messages(7, limit: 420);
    expect(more.length, 200);
    expect(phone.askedMessages.last, (thread: 7, limit: 420));
    // That was all the phone had: asked for still more, it is not asked again.
    final asks = phone.askedMessages.length;
    expect((await Sms.instance.messages(7, limit: 720)).length, 200);
    expect(phone.askedMessages.length, asks);
    await sub.cancel();
  });

  test('what is kept is sealed on the disk, is there when the app opens with the phone away, and goes with the pairing', () async {
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'local');
    fill(7, 60);
    final dir = Directory.systemTemp.createTempSync('ghost-desk-test');
    final bridge = LinkCalls(link, DeskStore(dir, keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    expect((await Sms.instance.conversations()).length, 2);
    expect((await Sms.instance.messages(7, limit: 120)).first.body, 'Text 60');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await bridge.cache.settled();
    // On the disk, and not to be read there: no word of a text, a name or a number is in the files.
    final files = Directory('${dir.path}/cache').listSync().whereType<File>().toList();
    // (The other conversation's messages were read behind the list, as those at its top are, so it opens at once.)
    expect(files.map((f) => f.uri.pathSegments.last).toSet(), {'list.bin', 't7.bin', 't9.bin'});
    expect(phone.askedMessages.where((a) => a.thread == 9).single.limit, LinkCalls.opening);
    for (final f in files) {
      final bytes = latin1.decode(f.readAsBytesSync());
      for (final word in ['Text 60', 'Maya', '+15550100', 'See you', '"items"']) {
        expect(bytes.contains(word), isFalse, reason: '$word is readable in ${f.path}');
      }
    }
    expect(DeskCrypto.openAtRest(DeskCrypto.derive(List.filled(32, 9), 'cache'), files.first.readAsBytesSync()), isNull, reason: 'another key does not open it');

    // The app is closed, the phone goes, and the app is opened again: the list and the conversation are there.
    bridge.dispose();
    links.removeLast().dispose();
    await phone.leaveLocal();
    final again = mac(store, local: false);
    await again.start();
    expect(again.online, isFalse);
    final second = LinkCalls(again, DeskStore(dir, keychain: false));
    await second.init();
    Sms.calls = second;
    final list = await Sms.instance.conversations();
    expect(list.map((c) => c.title), ['Maya', 'Dad']);
    final kept = await Sms.instance.messages(7, limit: 120);
    expect(kept.length, 60);
    expect(kept.first.body, 'Text 60');
    expect((await second.cache.size()).conversations, 2);

    // The pairing ends: nothing of it stays on the disk.
    second.forget();
    await second.cache.settled();
    expect(Directory('${dir.path}/cache').existsSync(), isFalse);
    second.dispose();
  });

  // Matt, 2026-11-23: "messages are being un marked from read when relaunching the app". The phone tells a computer
  // nothing back about what the computer itself did (android Bus.changedOnPhone), so the list on the disk was never
  // written again after a conversation was read here, and the app opened with it unread.
  test('a conversation read on the computer is still read when the app opens again with the phone away', () async {
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'local');
    final dir = Directory.systemTemp.createTempSync('ghost-desk-test');
    final bridge = LinkCalls(link, DeskStore(dir, keychain: false));
    await bridge.init();
    Sms.calls = bridge;
    expect((await Sms.instance.conversations()).firstWhere((c) => c.id == 7).unread, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await bridge.cache.settled();
    await Sms.instance.markRead(7);
    expect((await Sms.instance.conversations()).firstWhere((c) => c.id == 7).unread, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await bridge.cache.settled();

    bridge.dispose();
    links.removeLast().dispose();
    await phone.leaveLocal();
    final again = mac(store, local: false);
    await again.start();
    expect(again.online, isFalse);
    final second = LinkCalls(again, DeskStore(dir, keychain: false));
    await second.init();
    Sms.calls = second;
    expect((await Sms.instance.conversations()).firstWhere((c) => c.id == 7).unread, isFalse, reason: 'read before the app closed');
    second.dispose();
  });

  test('a conversation\'s newest are joined to what is kept', () {
    Map<String, dynamic> m(int id) => {'id': id, 'kind': 'sms', 'date': 1000 + id};
    List<int> ids(List<dynamic>? l) => [for (final x in l!) (x as Map)['id'] as int];
    final had = [for (var i = 50; i >= 1; i--) m(i)];
    // Two new ones, and the window reaches back into what is kept.
    expect(ids(LinkCalls.merged(had, [for (var i = 52; i >= 43; i--) m(i)], window: 10)), [for (var i = 52; i >= 1; i--) i]);
    // One of the newest was deleted on the phone: it is gone, and the window holds one more of the older.
    expect(ids(LinkCalls.merged(had, [m(50), m(49), m(47), m(46)], window: 10)), [50, 49, 47, for (var i = 46; i >= 1; i--) i]);
    // More came than the window holds, so none of them is among what is kept: read whole.
    expect(LinkCalls.merged(had, [for (var i = 80; i >= 71; i--) m(i)], window: 10), isNull);
    // A conversation emptied on the phone is empty here; one never kept takes what came.
    expect(LinkCalls.merged(had, const [], window: 10), isEmpty);
    expect(ids(LinkCalls.merged(const [], [m(3), m(2)], window: 10)), [3, 2]);
    // A picture message and a text with the same number are two messages.
    expect(LinkCalls.merged([{'id': 5, 'kind': 'mms', 'date': 1005}, m(4)], [m(5), {'id': 5, 'kind': 'mms', 'date': 1005}], window: 10)!.length, 3);
  });

  test('a text whose answer was lost is asked for again under the same name, and sent once', () async {
    final link = mac(MemoryStore());
    await pair(link, 'local');
    await link.request('send', {'key': 'same', 'addresses': ['+15550100'], 'body': 'Once'});
    final again = (await link.request('send', {'key': 'same', 'addresses': ['+15550100'], 'body': 'Once'})) as Map;
    expect(again['again'], isTrue);
    expect(phone.sent.length, 1);
  });

  test('the pairing is kept: a Mac started again finds the phone without pairing', () async {
    final store = MemoryStore();
    await pair(mac(store), 'both');
    links.removeLast().dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final again = mac(store, local: false); // no address given: the one remembered is tried
    await again.start();
    await until(() => again.online, what: 'never reconnected from what was kept');
    expect(again.via, 'local');
    expect(again.phone!.name, 'Fold');
    expect((await again.request('conversations') as List).length, 2);
  });

  test('a pressed link that is not a web address is not handed to the computer to open', () async {
    // What the Mac does with `openLink` (lib/desktop/remote.dart): only an http or https address with a host goes
    // to `open`. Each of these is refused before anything is run, so nothing opens on the machine the test is on.
    // One that would open is not tried here for the same reason.
    final bridge = LinkCalls(mac(MemoryStore()), DeskStore(Directory.systemTemp.createTempSync('ghost-desk-test'), keychain: false));
    for (final url in [
      'file:///etc/passwd',
      'javascript:alert(1)',
      'tel:+15551230001',
      'ghost://anything',
      '-a Calculator',
      ' https://example.com',
      'https://',
      'example.com/tickets',
      '',
    ]) {
      expect(await bridge.invokeMethod('openLink', {'url': url}), isFalse, reason: url);
    }
    expect(await bridge.invokeMethod('openLink', const <String, dynamic>{}), isFalse);
  });

  test('unpairing from the Mac tells the phone and the relay; unpairing from the phone tells the Mac', () async {
    final store = MemoryStore();
    final link = mac(store);
    await pair(link, 'both');
    await until(() => relay.channelCount == 1);
    await link.unpair();
    expect(link.phone, isNull);
    expect(store.kept, isNull);
    await until(() => phone.keys.isEmpty, what: 'the phone was never told');
    await until(() => relay.channelCount == 0, what: 'the relay still holds the channel');

    await phone.leaveRelay();
    final second = mac(MemoryStore());
    await pair(second, 'local');
    phone.unpair(second.phone!.id);
    await until(() => second.phone == null, what: 'the Mac was never told');
    expect(second.online, isFalse);
  });

  test('a phone that no longer has the pairing says so through the relay, and the Mac says it was refused', () async {
    final store = MemoryStore();
    final link = mac(store, local: false);
    await pair(link, 'relay');
    final id = link.phone!.id;
    links.removeLast().dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    // Unpaired on the phone while the Mac was closed. The phone is still on the channel (as if it had not yet let go).
    final key = phone.keys[id]!;
    phone.keys.remove(id);
    store.kept = PairedPhone(id: id, name: 'Fold', key: key, mode: 'relay', relay: relayUrl, since: DateTime.now());

    final again = mac(store, local: false);
    await again.start();
    await until(() => again.refused, what: 'never noticed it was unpaired');
    expect(again.online, isFalse);
  });

  test('a phone that scanned another code, or none, is not paired with', () async {
    final link = mac(MemoryStore());
    await link.start();
    final attempt = link.beginPairing(mode: 'local', relay: relayUrl);
    // The phone is listening and has scanned nothing: it knows no such pairing.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(attempt.phase, 'showing');
    expect(phone.hellos, isNotEmpty);
    // Another Mac's code.
    final other = PhoneLink(store: MemoryStore(), name: 'Another Mac');
    links.add(other);
    phone.scan(other.beginPairing(mode: 'local', relay: '').offer.text);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(attempt.phase, 'showing');
    expect(link.phone, isNull);
    // Cancelled on the Mac: the code is gone.
    await link.cancelPairing();
    expect(link.attempt, isNull);
  });

  test('the phone saying the digits differ ends the pairing on the Mac', () async {
    final link = mac(MemoryStore());
    await link.start();
    final attempt = link.beginPairing(mode: 'local', relay: relayUrl);
    phone.scan(attempt.offer.text);
    await until(() => attempt.phase == 'code');
    link.confirmPairing();
    // "They don't match" on the phone: its connection is dropped. The Mac goes back to showing the code, with
    // nothing confirmed.
    await phone.leaveLocal();
    await until(() => attempt.phase == 'showing');
    expect(attempt.mine, isFalse);
    expect(link.phone, isNull);
  });
}
