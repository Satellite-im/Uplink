import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/circles/circle_keys.dart' show CircleKeys;
import 'package:ghost_messaging/files/files_store.dart' show FilesStore;
import 'package:ghost_messaging/inbox/inbox.dart' show InboxNetwork;
import 'package:ghost_messaging/me/me.dart' show Me, MemoryMeStore;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show ForwardSecrecy;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/net/net.dart' show Net;
import 'package:ghost_messaging/net/p2p/p2p.dart' show P2p;
import 'package:ghost_messaging/sms.dart' show Sms;
import 'package:ghost_relay/accounts.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/texts.dart';

/// Making an Uplink account and signing in to it on other devices, end to end against the relay's own accounts and
/// handles (relay/lib/accounts.dart, handles.dart) in this process (Matt, 2026-11-17: "We need to have a way to login to
/// existing accounts. We might need to add password based authentication as well as SMS verification for verified
/// numbers"; "i also want accounts to be generated based on ethereum type addresses with a recovery seed we can back
/// up"). Each device has its own identity, secure storage and preferences, as an install does.
class FakeTexts implements TextCodes {
  final sent = <String, String>{};
  var n = 0;
  @override
  Future<Texted> send(String number) async {
    sent[number] = '${700000 + ++n}';
    return Texted.sent;
  }

  @override
  Future<bool?> check(String number, String code) async => sent[number] == code ? (sent.remove(number) != null) : false;
}

/// One install: its identity (as the hub would know it), what it keeps securely, its preferences and its profile.
class Device implements AccountPort, AccountRelay, AccountProfiles {
  Device(this.relayAccounts, this.handles, {NetKeys? keys, this.username = '', this.hasFriends = false}) : keys = keys ?? NetKeys.generate() {
    _connect();
  }

  /// The relay it speaks to: another, where the person chose another (Settings › Routes).
  Accounts relayAccounts;
  Handles handles;
  NetKeys keys;
  String username;
  bool hasFriends;
  final secrets = <String, String>{};
  final store = MemoryMeStore();
  var restarts = 0;
  AccountBackup? applied;

  /// The hub's name for this device's connection, made as it connected: an identity taken on goes on speaking under the
  /// old name until the app starts again.
  late String connection;
  final heard = <Map<String, Object?>>[];

  void _connect() {
    connection = keys.id;
    handles.came(connection, heard.add, key: keys.public);
  }

  late final Account account = Account(relay: this, port: this, store: store, profiles: this);

  // AccountRelay: the relay's accounts, answered in this process.
  @override
  String get hubId => connection;
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    Map<String, Object?>? got;
    await relayAccounts.said(connection, what, (m) => got = m);
    if (got!['dir'] == 'err') throw AccountError(got!['err'] as String);
    return Map<String, dynamic>.from(got!);
  }

  // AccountPort
  @override
  Future<Uint8List> identityExport() async => keys.scalar;
  @override
  Future<void> identityImport(List<int> scalar, List<int> public) async {
    keys = NetKeys.fromScalar(scalar);
    expect(keys.public, public);
  }

  @override
  Future<void> secretKeep(String name, String value) async => value.isEmpty ? secrets.remove(name) : secrets[name] = value;
  @override
  Future<String?> secretRead(String name) async => secrets[name];
  @override
  Future<bool> restart() async {
    restarts++;
    // Started again: connected under the identity it has now.
    _connect();
    return true;
  }

  @override
  Future<bool> identityForget() async => false;

  /// Each time everything here was deleted ([Account] on a device of its own), with why.
  final wipes = <String>[];
  @override
  Future<void> wipeHere(String note) async {
    wipes.add(note);
    secrets.clear();
    store.kept.clear();
  }

  // AccountProfiles
  @override
  bool get fresh => username.isEmpty && !hasFriends;
  @override
  String get deviceName => 'Test ${keys.id.substring(0, 4)}';
  @override
  AccountBackup fill(AccountBackup b) => b.copyWith(username: username, displayName: 'Maya Chen', friends: hasFriends ? const [{'u': 'sam'}] : const []);
  @override
  Future<void> apply(AccountBackup b) async {
    applied = b;
    username = b.username;
  }

  @override
  Future<void> forget() async => username = '';
  var stops = 0, profileWipes = 0;
  @override
  Future<void> stopAll() async => stops++;
  @override
  Future<void> wipe() async => profileWipes++;

  Future<void> claim(String name) async {
    await handles.said(connection, {'dir': 'claim', 'name': name});
    expect(heard.last['ok'], isTrue);
    username = name;
  }
}

/// A device whose relay hands it [said] as its "removal" (a relay saying what isn't so, or one replaying old words).
class _Told extends Device {
  _Told(super.relayAccounts, super.handles);
  Map<String, Object?>? said;

  /// Whether the relay says it holds the account.
  bool held = true;
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    if (what['dir'] == 'acct-hello' && said != null) return {'dir': 'acct-hello', 'known': false, 'account': held, 'removed': said};
    return super.ask(what);
  }
}

/// A device whose relay is from before relays said whether they hold an account: its `acct-hello` has no `account`,
/// and once [gone] says the device is not known.
class _OldRelay extends Device {
  _OldRelay(super.relayAccounts, super.handles);
  bool gone = false;
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    if (what['dir'] == 'acct-hello' && gone) return {'dir': 'acct-hello', 'known': false};
    final m = await super.ask(what);
    return what['dir'] == 'acct-hello' ? ({...m}..remove('account')) : m;
  }
}

/// A device whose relay keeps no removals (one from before they were kept): `removed` never comes with acct-hello.
class _NoProofs extends Device {
  _NoProofs(super.relayAccounts, super.handles);
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    final m = await super.ask(what);
    return what['dir'] == 'acct-hello' ? ({...m}..remove('removed')) : m;
  }
}

/// An account key's signed `devices` body removing [device] from [address], at [at] (ms): what a relay keeps.
Map<String, Object?> removalBy(List<String> words, String address, String device, {int? at}) {
  final key = AccountCrypto.derive(AccountCrypto.seedOf(words), AccountCrypto.ethPath);
  final body = jsonEncode({'op': 'devices', 'a': address, 'by': 'someone', 'at': at ?? DateTime.now().millisecondsSinceEpoch, 'remove': device});
  return {'body': body, 'sig': NetCrypto.hex(AccountCrypto.sign(key, utf8.encode(body)))};
}

/// Another network, as the inbox has them: signed out by a wipe.
class _Network implements InboxNetwork {
  var signedOut = 0;
  @override
  Future<void> signOut() async => signedOut++;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// The relay's accounts, with every ask whose body holds [drop] lost on its way ([times] of them, or every one).
class _Dropping implements Accounts {
  _Dropping(this.real, {required this.drop, this.times});
  final Accounts real;
  final String drop;
  int? times;
  @override
  Future<void> said(String id, Map said, void Function(Map<String, Object?>) tell) async {
    final body = said['body'];
    if (body is String && body.contains(drop) && (times == null || times! > 0)) {
      if (times != null) times = times! - 1;
      return tell({'dir': 'err', 'about': said['dir'], 'err': 'The relay server did not answer.'});
    }
    return real.said(id, said, tell);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// An iPhone: it can't start itself again.
class _Stuck extends Device {
  _Stuck(super.relayAccounts, super.handles);
  @override
  Future<bool> restart() async {
    restarts++;
    return false;
  }
}

void main() {
  late FakeTexts texts;
  late Handles handles;
  late Accounts accounts;

  setUp(() {
    texts = FakeTexts();
    handles = Handles(texts: texts)..load();
    accounts = Accounts(handles: handles);
  });

  Future<(Device, AccountDraft)> made({String password = 'correct horse battery', String name = 'maya'}) async {
    final phone = Device(accounts, handles, hasFriends: true);
    await phone.claim(name);
    final draft = phone.account.draft();
    expect(await phone.account.create(draft, password), isFalse, reason: 'an install people know keeps its own key');
    return (phone, draft);
  }

  /// Another account, beside [made]'s.
  Future<(Device, AccountDraft)> made2() => made(name: 'nell');

  test('an install with friends makes an account: its own key kept, the words in secure storage, nothing in the clear', () async {
    final before = NetKeys.generate();
    final phone = Device(accounts, handles, keys: before, hasFriends: true);
    await phone.claim('maya');
    final draft = phone.account.draft();
    expect(draft.words.length, 12);
    expect(AccountCrypto.goodAddress(draft.address), isTrue);
    expect(await phone.account.create(draft, 'correct horse battery'), isFalse);
    expect(phone.keys.id, before.id, reason: 'bound: the identity friends know stays');
    expect(phone.account.address, draft.address);
    expect(phone.account.mode, 'bound');
    expect(phone.secrets['account_words'], draft.words.join(' '));
    // The preferences hold the address, the device and a sealed blob: no word, no key.
    final prefs = phone.store.kept.values.join(' ');
    for (final w in draft.words.toSet()) {
      expect(RegExp('\\b$w\\b').hasMatch(prefs), isFalse, reason: 'a recovery word in the preferences');
    }
    expect(prefs.contains(NetCrypto.hex(before.scalar)), isFalse);
    expect(accounts.accountOf(before.id), draft.address.toLowerCase());
    expect((await phone.account.devices()).single.here, isTrue);
  });

  test('signed in on a new device by username and password: the same identity, profile and friends, and a clean start', () async {
    final (phone, draft) = await made();
    final fresh = Device(accounts, handles);
    expect((await fresh.account.findByName('@Maya')).phone, isFalse);
    await expectLater(fresh.account.signInWithPassword('maya', 'wrong password'), throwsA(isA<AccountError>().having((e) => e.message, 'message', 'That password isn\'t right.')));
    final restore = await fresh.account.signInWithPassword('maya', 'correct horse battery');
    expect(restore.address, draft.address);
    expect(await fresh.account.finish(restore), isTrue);
    expect(fresh.keys.id, phone.keys.id, reason: 'the account\'s Uplink identity, in place of the fresh one');
    expect(fresh.restarts, 1);
    expect(fresh.applied!.username, 'maya');
    expect(fresh.applied!.friends, isNotEmpty);
    expect(fresh.account.address, draft.address);
    final list = await fresh.account.devices();
    expect(list.length, 2);
    expect(list.where((d) => d.here).length, 1);
    await expectLater(Device(accounts, handles).account.findByName('nobody'), throwsA(isA<AccountError>()));
  });

  test('a verified number: a code texted to it is needed, to that number only', () async {
    final (phone, _) = await made();
    await handles.said(phone.connection, {'dir': 'text', 'p': 'phone', 'handle': '+14155550100'});
    await handles.said(phone.connection, {'dir': 'code', 'p': 'phone', 'handle': '+14155550100', 'code': texts.sent['+14155550100']});
    final fresh = Device(accounts, handles);
    expect((await fresh.account.findByName('maya')).phone, isTrue);
    await expectLater(fresh.account.signInWithPassword('maya', 'correct horse battery'), throwsA(isA<AccountNeedsCode>()));
    await expectLater(fresh.account.textCode('maya', '+1 415 555 0199'), throwsA(isA<AccountError>()));
    await fresh.account.textCode('maya', '(415) 555-0100');
    await expectLater(fresh.account.signInWithPassword('maya', 'correct horse battery', number: '+14155550100', code: '123456'), throwsA(isA<AccountError>()));
    final restore = await fresh.account.signInWithPassword('maya', 'correct horse battery', number: '+14155550100', code: texts.sent['+14155550100']);
    await fresh.account.finish(restore);
    expect(fresh.keys.id, phone.keys.id);
  });

  test('signed in with the recovery words alone: no password, no text', () async {
    final (phone, draft) = await made();
    await handles.said(phone.connection, {'dir': 'text', 'p': 'phone', 'handle': '+14155550100'});
    await handles.said(phone.connection, {'dir': 'code', 'p': 'phone', 'handle': '+14155550100', 'code': texts.sent['+14155550100']});
    final fresh = Device(accounts, handles);
    await expectLater(fresh.account.signInWithWords([...draft.words.sublist(0, 11), draft.words[0] == 'zoo' ? 'abandon' : 'zoo']), throwsA(isA<AccountError>()));
    final restore = await fresh.account.signInWithWords(draft.words);
    expect(restore.backedUp, isTrue);
    await fresh.account.finish(restore);
    expect(fresh.keys.id, phone.keys.id);
    // The password's copy came with it: the words can be shown here again for the password.
    expect(await fresh.account.revealWords('correct horse battery'), draft.words);
  });

  test('a fresh install\'s account is the words\' own identity: restored from the words even with no backup left', () async {
    final first = Device(accounts, handles);
    final draft = first.account.draft();
    expect(await first.account.create(draft, 'pw for a fresh one'), isTrue, reason: 'it takes on the words\' identity and starts again');
    final seedIdentity = AccountCrypto.identityOf(AccountCrypto.seedOf(draft.words));
    expect(first.keys.id, seedIdentity.id);
    expect(first.account.mode, 'seed');
    // The relay loses everything (or the account is deleted): the words still make the same identity.
    final empty = Accounts(handles: handles);
    final elsewhere = Device(empty, handles);
    final restore = await elsewhere.account.signInWithWords(draft.words);
    expect(restore.backedUp, isFalse);
    await expectLater(elsewhere.account.finish(restore), throwsA(isA<AccountError>()), reason: 'a new password is needed to back it up again');
    await elsewhere.account.finish(restore, password: 'a new one');
    expect(elsewhere.keys.id, seedIdentity.id);
    expect(empty.accountOf(seedIdentity.id), draft.address.toLowerCase());
  });

  test('a new password: the old one opens nothing, the new one does; the words shown only for the password', () async {
    final (phone, draft) = await made();
    await expectLater(phone.account.revealWords('nope'), throwsA(isA<AccountError>()));
    expect(await phone.account.revealWords('correct horse battery'), draft.words);
    await expectLater(phone.account.changePassword('nope', 'next one'), throwsA(isA<AccountError>()));
    await phone.account.changePassword('correct horse battery', 'next one');
    final fresh = Device(accounts, handles);
    await expectLater(fresh.account.signInWithPassword('maya', 'correct horse battery'), throwsA(isA<AccountError>()));
    expect((await fresh.account.signInWithPassword('maya', 'next one')).address, draft.address);
    expect(await phone.account.revealWords('next one'), draft.words);
  });

  test('a device removed from another forgets the account when it next asks; signing out leaves it someone new', () async {
    final (phone, _) = await made();
    final laptop = Device(accounts, handles);
    await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
    final listed = await phone.account.devices();
    final theirs = listed.firstWhere((d) => !d.here);
    expect((await phone.account.removeDevice(theirs.id)).length, 1);
    await laptop.account.check();
    expect(laptop.account.signedIn, isFalse);
    expect(laptop.account.removedHere, isTrue);
    expect(laptop.secrets, isEmpty);
    // Signing out the phone itself: off the list, the words gone, a new identity of its own.
    final was = phone.keys.id;
    await phone.account.signOut();
    expect(phone.account.signedIn, isFalse);
    expect(phone.keys.id, isNot(was));
    expect(phone.username, isEmpty);
  });

  // docs/OPEN_NETWORK.md, section 1: the node key is the device's, and a device that leaves an account takes nothing of
  // it along: not the key its node id is made from, nor the cards of the account's friends, nor what it told whom.
  test('signing out deletes the device\'s place on the direct network: the node key, its card, the cards held and what was told', () async {
    final (phone, _) = await made();
    phone.secrets[P2p.keyName] = 'ab' * 32;
    for (final name in P2p.keptNames) {
      phone.store.set(name, '{"kept":"while signed in"}');
    }
    phone.store.set(P2p.helpersOnlyName, 'on');
    await phone.account.signOut();
    expect(phone.secrets.keys, isNot(contains(P2p.keyName)));
    for (final name in P2p.keptNames) {
      expect(phone.store.choice(name, 'unset'), isEmpty, reason: name);
    }
    expect(P2p.keptNames, containsAll(['p2p_id', 'p2p_card', 'p2p_cards', 'p2p_told']));
    expect(phone.store.choice(P2p.helpersOnlyName, ''), 'on', reason: 'the person\'s choice stays');
    // And on a device another device removed, when it next asks.
    final (other, _) = await made2();
    final laptop = Device(accounts, handles);
    await laptop.account.finish(await laptop.account.signInWithPassword('nell', 'correct horse battery'));
    laptop.secrets[P2p.keyName] = 'cd' * 32;
    laptop.store.set(P2p.cardsName, '{"x":[]}');
    final theirs = (await other.account.devices()).firstWhere((d) => !d.here);
    await other.account.removeDevice(theirs.id);
    await laptop.account.check();
    expect(laptop.account.signedIn, isFalse);
    expect(laptop.secrets, isEmpty);
    expect(laptop.store.choice(P2p.cardsName, 'unset'), isEmpty);
  });

  test('the backup is brought up to date from the device, with the password\'s key kept beside the words', () async {
    final (phone, draft) = await made();
    expect(phone.secrets.containsKey('account_pwkey'), isTrue);
    phone.hasFriends = false;
    expect(await phone.account.refresh(), isTrue);
    expect(await phone.account.refresh(), isFalse, reason: 'once a day');
    final fresh = Device(accounts, handles);
    final restore = await fresh.account.signInWithPassword('maya', 'correct horse battery');
    expect(restore.backup.friends, isEmpty, reason: 'friends as they are now');
    // Signed in by the words: no password typed here, so nothing to seal with until it is.
    final byWords = Device(accounts, handles);
    await byWords.account.finish(await byWords.account.signInWithWords(draft.words));
    expect(await byWords.account.refresh(force: true), isFalse);
    await byWords.account.revealWords('correct horse battery');
    expect(await byWords.account.refresh(force: true), isTrue);
  });

  // A page in a browser keeps no recovery words and no password key (Account.keepsWords): anything running in the page
  // could open what it keeps. The password opens them from the sealed copy each time they are wanted.
  group('in a browser', () {
    setUp(() {
      Sms.browser = true;
      Sms.standalone = true;
    });
    tearDown(() {
      Sms.browser = false;
      Sms.standalone = false;
    });

    test('making an account, or signing in, keeps no words and no password key: only the key copies are sealed with', () async {
      final page = Device(accounts, handles, hasFriends: true);
      await page.claim('maya');
      final draft = page.account.draft();
      await page.account.create(draft, 'correct horse battery');
      expect(page.secrets.keys, [Me.mineSecret]);
      expect(page.secrets[Me.mineSecret], NetCrypto.hex(Me.mineKeyOf(draft.words)));
      // Nothing of the words anywhere it keeps.
      final kept = [...page.secrets.values, ...page.store.kept.values].join(' ');
      for (final w in draft.words.toSet()) {
        expect(RegExp('\\b$w\\b').hasMatch(kept), isFalse, reason: 'a recovery word kept in a browser');
      }
      // Shown, and a new password: for the password, and still nothing kept of it.
      expect(await page.account.revealWords('correct horse battery'), draft.words);
      await page.account.changePassword('correct horse battery', 'a new one here');
      expect(page.secrets.keys, [Me.mineSecret]);
      // Signed in on another browser: the same.
      final other = Device(accounts, handles);
      await other.account.finish(await other.account.signInWithPassword('maya', 'a new one here'));
      expect(other.secrets.keys, [Me.mineSecret]);
      expect(other.secrets[Me.mineSecret], page.secrets[Me.mineSecret]);
      // And by the words: nothing of them kept either, nor the identity it had before.
      final third = Device(accounts, handles);
      await third.account.finish(await third.account.signInWithWords(draft.words));
      expect(third.secrets.keys, [Me.mineSecret]);
    });

    // Third review, A1: a browser removed while it was closed, then the backup brought up to date by another of the
    // account's devices (which dropped the removal kept), stayed the account when opened again. With the removal kept it
    // deletes everything; and where the relay holds the account and doesn't list it, it does so even with nothing signed.
    test('removed, then a backup brought up to date: a browser deletes everything as it next asks, signed or not', () async {
      Sms.browser = false;
      Sms.standalone = false;
      final (phone, _) = await made();
      Sms.browser = true;
      Sms.standalone = true;
      final page = Device(accounts, handles);
      await page.account.finish(await page.account.signInWithPassword('maya', 'correct horse battery'));
      final unsigned = _NoProofs(accounts, handles);
      await unsigned.account.finish(await unsigned.account.signInWithPassword('maya', 'correct horse battery'));
      Sms.browser = false;
      Sms.standalone = false;
      await phone.account.removeDevice(page.account.device);
      await phone.account.removeDevice(unsigned.account.device);
      expect(await phone.account.refresh(force: true), isTrue);
      Sms.browser = true;
      Sms.standalone = true;
      await page.account.check();
      expect(page.wipes, ['removed']);
      await unsigned.account.check();
      expect(unsigned.wipes, ['removed'], reason: 'the relay holds the account and doesn\'t list it: a browser\'s is a copy');
      // A relay that doesn't hold the account at all (it lost it): nothing deleted, and said.
      final lost = _Told(accounts, handles);
      await lost.account.finish(await lost.account.signInWithPassword('maya', 'correct horse battery'));
      lost
        ..held = false
        ..said = const {'what': 'nothing'};
      await lost.account.check();
      expect(lost.wipes, isEmpty);
      expect(lost.account.unknownHere, isTrue);
    });

    test('the devices, a removal and the backup brought up to date are opened with the password each time', () async {
      final page = Device(accounts, handles, hasFriends: true);
      await page.claim('maya');
      final draft = page.account.draft();
      await page.account.create(draft, 'correct horse battery');
      // Nothing it keeps can sign for the account.
      await expectLater(page.account.devices(), throwsA(isA<AccountError>().having((e) => e.message, 'says', contains('password'))));
      await expectLater(page.account.keysWith('not it'), throwsA(isA<AccountError>()));
      final keys = await page.account.keysWith('correct horse battery');
      final other = Device(accounts, handles);
      await other.account.finish(await other.account.signInWithPassword('maya', 'correct horse battery'));
      final list = await page.account.devices(keys: keys);
      expect(list, hasLength(2));
      expect((await page.account.removeDevice(list.firstWhere((d) => !d.here).id, keys: keys)), hasLength(1));
      // Once a day by itself is not for a browser: only when asked, with the password.
      expect(await page.account.refresh(force: true), isFalse);
      page.hasFriends = false;
      await expectLater(page.account.refreshWith('not it'), throwsA(isA<AccountError>()));
      expect(await page.account.refreshWith('correct horse battery'), isTrue);
      final fresh = Device(accounts, handles);
      expect((await fresh.account.signInWithPassword('maya', 'correct horse battery')).backup.username, 'maya');
      expect(page.secrets.keys, [Me.mineSecret]);
    });

    test('a store from before, with the words in it: the key made from them kept in their place, the words gone', () async {
      final page = Device(accounts, handles);
      final words = page.account.draft().words;
      page.secrets['account_words'] = words.join(' ');
      page.secrets['account_pwkey'] = '{"v":1}';
      page.account.start(page.store);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(page.secrets, {Me.mineSecret: NetCrypto.hex(Me.mineKeyOf(words))});
    });

    // The phone beside the page is a phone: what it does is done as one.
    Future<T> asPhone<T>(Future<T> Function() what) async {
      Sms.browser = false;
      Sms.standalone = false;
      try {
        return await what();
      } finally {
        Sms.browser = true;
        Sms.standalone = true;
      }
    }

    test('signing out takes it off the list by its own number, and deletes everything here', () async {
      final (phone, _) = await asPhone(made);
      final page = Device(accounts, handles);
      await page.account.finish(await page.account.signInWithPassword('maya', 'correct horse battery'));
      expect(await asPhone(phone.account.devices), hasLength(2));
      final restarts = page.restarts;
      expect(await page.account.signOut(), isTrue);
      expect(page.wipes, ['signed-out']);
      expect(page.stops, greaterThan(0), reason: 'the routes stopped before anything was deleted');
      expect(page.restarts, restarts + 1);
      expect(page.secrets, isEmpty);
      // Off the account's list, though it keeps no key to sign that with.
      expect(await asPhone(phone.account.devices), hasLength(1));
      expect(phone.account.signedIn, isTrue);
    });

    test('removed from another device: everything here deleted the next time it asks', () async {
      final (phone, _) = await asPhone(made);
      final page = Device(accounts, handles);
      await page.account.finish(await page.account.signInWithPassword('maya', 'correct horse battery'));
      final theirs = (await asPhone(phone.account.devices)).firstWhere((d) => !d.here);
      await asPhone(() => phone.account.removeDevice(theirs.id));
      await page.account.check();
      expect(page.account.removedHere, isTrue);
      expect(page.wipes, ['removed']);
      expect(page.secrets, isEmpty);
      expect(page.store.kept, isEmpty);
    });
  });

  // An iPhone, or a computer with no phone (Sms.standalone): removed, it stops being the account altogether; signing out
  // offers to delete everything here too, and says what stays where it doesn't (lib/ui/account_screens.dart).
  group('on a device of its own', () {
    setUp(() => Sms.standalone = true);
    tearDown(() => Sms.standalone = false);

    test('removed from another device: everything of the account here deleted, its keys first, the routes stopped', () async {
      final (phone, _) = await made();
      final laptop = Device(accounts, handles);
      await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
      laptop.secrets[ForwardSecrecy.secretsName] = 'prekeys';
      laptop.secrets[CircleKeys.secretsName] = 'circle keys';
      final theirs = (await phone.account.devices()).firstWhere((d) => !d.here);
      await phone.account.removeDevice(theirs.id);
      final restarts = laptop.restarts;
      await laptop.account.check();
      expect(laptop.account.removedHere, isTrue);
      expect(laptop.wipes, ['removed']);
      expect(laptop.stops, greaterThan(0));
      expect(laptop.profileWipes, 1, reason: 'its Files spaces\' files too');
      expect(laptop.secrets, isEmpty);
      expect(laptop.restarts, restarts + 1);
      expect(laptop.account.ended, isFalse, reason: 'it started again by itself');
    });

    test('signing out keeps the conversations unless everything is to go; either way off the list', () async {
      final (phone, _) = await made();
      final laptop = Device(accounts, handles);
      await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
      await laptop.account.signOut();
      expect(laptop.wipes, isEmpty, reason: 'signed out as before: someone new, the rest stays');
      expect(laptop.account.signedIn, isFalse);
      expect(await phone.account.devices(), hasLength(1));
      final mac = Device(accounts, handles);
      await mac.account.finish(await mac.account.signInWithPassword('maya', 'correct horse battery'));
      mac.secrets[ForwardSecrecy.secretsName] = 'prekeys';
      expect(await mac.account.signOut(everything: true), isTrue);
      expect(mac.wipes, ['signed-out']);
      expect(mac.secrets, isEmpty);
      expect(await phone.account.devices(), hasLength(1));
    });

    test('a device that can\'t start again by itself shows only that it is to be opened again', () async {
      final (phone, _) = await made();
      final iphone = _Stuck(accounts, handles);
      await iphone.account.finish(await iphone.account.signInWithPassword('maya', 'correct horse battery'));
      await phone.account.removeDevice((await phone.account.devices()).firstWhere((d) => !d.here).id);
      var told = 0;
      iphone.account.addListener(() => told++);
      await iphone.account.check();
      expect(iphone.account.ended, isTrue);
      expect(told, greaterThan(0));
    });
  });

  // GMFB-25 ("The app works fully against a self-hosted hub"): an Android phone moved to a relay of its keeper's own
  // forgot the account's words and keys the first time it asked, since that relay had never heard of the account, and
  // was never offered "List this device again", which every other device was. Only a relay that holds the account and
  // doesn't list the phone (it was removed), or one from before relays said which, makes a phone forget.
  group('an Android phone and a relay that doesn\'t hold its account', () {
    setUp(() => Account.addAgainAfter = Duration.zero);

    test('moved to another relay: nothing forgotten, it says the relay doesn\'t know the account, and listing it again puts the account there', () async {
      expect(Sms.standalone, isFalse);
      final phone = Device(accounts, handles, hasFriends: true);
      await phone.claim('maya');
      final draft = phone.account.draft();
      await phone.account.create(draft, 'correct horse battery');
      await phone.account.check();
      expect([phone.account.unknownHere, phone.account.removedHere], [false, false]);
      final kept = {...phone.secrets};
      // A relay of its own, with no such account.
      final otherHandles = Handles(texts: FakeTexts())..load();
      final otherAccounts = Accounts(handles: otherHandles);
      phone.relayAccounts = otherAccounts;
      phone.handles = otherHandles;
      otherHandles.came(phone.connection, (_) {}, key: phone.keys.public);
      var told = 0;
      phone.account.addListener(() => told++);
      await phone.account.check();
      expect([phone.account.unknownHere, phone.account.removedHere, phone.account.signedIn], [true, false, true]);
      expect(phone.secrets, kept, reason: 'the words and the password\'s key are still here');
      expect(told, 1);
      expect(await phone.account.revealWords('correct horse battery'), draft.words);
      // Put there from the phone, with what the phone has: known from then on.
      await phone.account.listHereAgain();
      expect(phone.account.unknownHere, isFalse);
      await phone.account.check();
      expect([phone.account.unknownHere, phone.account.removedHere, phone.account.signedIn], [false, false, true]);
      expect(phone.secrets, kept);
      // Another device signs in to it on that relay by the words.
      final laptop = Device(otherAccounts, otherHandles);
      await laptop.account.finish(await laptop.account.signInWithWords(draft.words));
      expect(laptop.account.address, phone.account.address);
    });

    test('a relay that holds the account and doesn\'t list the phone, or one from before relays said which, makes it forget as ever', () async {
      for (final from in ['holds it', 'says nothing of it']) {
        final phone = from == 'holds it' ? (_Told(accounts, handles)..held = true) : _OldRelay(accounts, handles);
        await phone.claim('maya${from.length}');
        await phone.account.create(phone.account.draft(), 'correct horse battery');
        await phone.account.check();
        expect(phone.account.signedIn, isTrue, reason: from);
        if (phone is _Told) phone.said = const {'what': 'nothing'};
        if (phone is _OldRelay) phone.gone = true;
        await phone.account.check();
        expect([phone.account.removedHere, phone.account.unknownHere, phone.account.signedIn], [true, false, false], reason: from);
        expect(phone.secrets.keys.where((k) => k.startsWith('account')), isEmpty, reason: from);
      }
    });
  });

  // The second review: the relay says `known: false` for anything it doesn't know, not only for a device the account
  // removed. On a device of its own only the account's own signed removal deletes anything (Account.removalProven).
  group('on a device of its own, the relay\'s word alone deletes nothing', () {
    setUp(() {
      Sms.standalone = true;
      Account.addAgainAfter = Duration.zero;
    });
    tearDown(() => Sms.standalone = false);

    test('moved to another relay (Settings › Routes): nothing deleted or forgotten, and it says the relay doesn\'t know it', () async {
      final iphone = Device(accounts, handles, hasFriends: true);
      await iphone.claim('maya');
      await iphone.account.create(iphone.account.draft(), 'correct horse battery');
      await iphone.account.check();
      expect(iphone.account.unknownHere, isFalse);
      final kept = {...iphone.secrets}, prefs = {...iphone.store.kept};
      // Another relay, with no such account.
      final otherHandles = Handles(texts: FakeTexts())..load();
      iphone.relayAccounts = Accounts(handles: otherHandles);
      iphone.handles = otherHandles;
      otherHandles.came(iphone.connection, (_) {}, key: iphone.keys.public);
      await iphone.account.check();
      expect(iphone.wipes, isEmpty);
      expect(iphone.account.removedHere, isFalse);
      expect(iphone.account.unknownHere, isTrue);
      expect(iphone.account.signedIn, isTrue);
      expect(iphone.secrets, kept, reason: 'nothing forgotten');
      expect(iphone.store.kept, prefs);
      // Back on its own relay: known again, and said so.
      iphone.relayAccounts = accounts;
      iphone.handles = handles;
      await iphone.account.check();
      expect(iphone.account.unknownHere, isFalse);
      expect(iphone.wipes, isEmpty);
    });

    test('a relay that lost what it kept (its accounts file unreadable): nothing deleted', () async {
      final dir = Directory.systemTemp.createTempSync('accounts-lost');
      addTearDown(() => dir.deleteSync(recursive: true));
      final relay = Accounts(dataDir: dir, handles: handles);
      final mac = Device(relay, handles, hasFriends: true);
      await mac.claim('maya');
      await mac.account.create(mac.account.draft(), 'correct horse battery');
      relay.save();
      File('${dir.path}/accounts.json').writeAsStringSync('{"v":1,"accounts":{"0x');
      mac.relayAccounts = Accounts(dataDir: dir, handles: handles)..load();
      await mac.account.check();
      expect(mac.wipes, isEmpty);
      expect(mac.account.signedIn, isTrue);
      expect(mac.secrets, isNotEmpty);
    });

    test('a sign-up whose listing never arrived: nothing kept as signed in, and nothing deleted after', () async {
      final mac = _Told(accounts, handles);
      await mac.claim('nell');
      // Every "add" lost on its way, twice.
      final real = mac.relayAccounts;
      mac.relayAccounts = _Dropping(real, drop: '"add"');
      await expectLater(mac.account.create(mac.account.draft(), 'correct horse battery'), throwsA(isA<AccountError>().having((e) => e.message, 'says', contains('Sign in to it'))));
      expect(mac.account.signedIn, isFalse, reason: 'not the account\'s here until it is on its list');
      expect(mac.secrets, isEmpty);
      mac.relayAccounts = real;
      await mac.account.check();
      expect(mac.wipes, isEmpty);
      // And it is signed in to as any account is: the backup was kept.
      final restore = await mac.account.signInWithPassword('nell', 'correct horse battery');
      await mac.account.finish(restore);
      expect(mac.account.signedIn, isTrue);
      expect((await mac.account.devices()).single.here, isTrue);
    });

    test('a listing lost once is asked again, and the sign-up goes on', () async {
      final mac = Device(accounts, handles);
      await mac.claim('nell');
      mac.relayAccounts = _Dropping(accounts, drop: '"add"', times: 1);
      await mac.account.create(mac.account.draft(), 'correct horse battery');
      mac.relayAccounts = accounts;
      expect(mac.account.signedIn, isTrue);
      expect((await mac.account.devices()).single.here, isTrue);
    });

    test('a removal the account didn\'t sign, or of another device, or from before it was added deletes nothing; where the relay holds the account, the words and keys are forgotten as before', () async {
      final (phone, draft) = await made();
      final otherWords = phone.account.draft().words;
      Future<_Told> signedIn() async {
        final iphone = _Told(accounts, handles);
        await iphone.account.finish(await iphone.account.signInWithPassword('maya', 'correct horse battery'));
        return iphone;
      }

      // A relay that doesn't hold the account at all (another relay, one that lost it): nothing forgotten either. One
      // device for every case (signing in is limited a few an hour an account), since it stays signed in.
      final other = await signedIn();
      other.held = false;
      for (final (why, made) in <(String, Map<String, Object?> Function(String address, String device, int joined))>[
        ('signed by another key', (a, d, _) => removalBy(otherWords, a, d)),
        ('of another device', (a, d, _) => removalBy(draft.words, a, 'f' * 32)),
        ('for another account', (a, d, _) => removalBy(draft.words, '0x${'1' * 40}', d)),
        ('from before this device was added', (a, d, joined) => removalBy(draft.words, a, d, at: joined - 3600000)),
        ('not signed at all', (a, d, _) => {'body': removalBy(draft.words, a, d)['body'], 'sig': '00' * 65}),
        ('not words at all', (a, d, _) => {'what': 'removed'}),
      ]) {
        // The relay holds the account and doesn't list this device: not believed as a removal, so nothing deleted; but
        // the words and keys forgotten, as every device did before removals were kept.
        final iphone = await signedIn();
        iphone.store.set('conversations', 'kept');
        iphone.said = made(iphone.account.address!, iphone.account.device, iphone.account.joinedAt);
        await iphone.account.check();
        expect(iphone.wipes, isEmpty, reason: why);
        expect(iphone.account.signedIn, isFalse, reason: why);
        expect(iphone.secrets.containsKey('account_words'), isFalse, reason: why);
        expect(iphone.store.choice('conversations', ''), 'kept', reason: '$why: what it keeps stays');
        other.said = made(other.account.address!, other.account.device, other.account.joinedAt);
        await other.account.check();
        expect(other.wipes, isEmpty, reason: why);
        expect(other.account.signedIn, isTrue, reason: why);
        expect(other.account.unknownHere, isTrue, reason: why);
      }
      // The account's own, for this device, now: it is believed.
      final iphone = await signedIn();
      final address = iphone.account.address!, device = iphone.account.device;
      iphone.said = removalBy(draft.words, address, device);
      await iphone.account.check();
      expect(iphone.wipes, ['removed']);
      expect(Account.removalProven(removalBy(draft.words, address, device), address: address.toLowerCase(), device: device), isTrue, reason: 'the address as the relay writes it');
    });

    // Third review, M1: every signed-in phone or computer brings the backup up to date once a day (acct-put), which
    // dropped the removals kept, so a removed device asking after it was handed nothing to check and stayed the account.
    test('removed, then another device brings the backup up to date: the removed one still deletes everything as it asks', () async {
      final (phone, _) = await made();
      final laptop = Device(accounts, handles);
      await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
      Sms.standalone = false;
      await phone.account.removeDevice(laptop.account.device);
      expect(await phone.account.refresh(force: true), isTrue);
      Sms.standalone = true;
      await laptop.account.check();
      expect(laptop.wipes, ['removed']);
    });

    // Under a relay that keeps no removals (one from before, or a removal made before it was deployed): what the release
    // before did, as an Android phone still does. Nothing deleted, the words and keys forgotten.
    test('removed under a relay that keeps no removals: the words and keys forgotten, nothing deleted', () async {
      final (phone, _) = await made();
      final laptop = _NoProofs(accounts, handles);
      await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
      laptop.store.set('conversations', 'kept');
      Sms.standalone = false;
      await phone.account.removeDevice(laptop.account.device);
      Sms.standalone = true;
      await laptop.account.check();
      expect(laptop.wipes, isEmpty);
      expect(laptop.account.signedIn, isFalse);
      expect(laptop.account.removedHere, isTrue);
      expect(laptop.secrets.containsKey('account_words'), isFalse);
      expect(laptop.store.choice('conversations', ''), 'kept');
    });

    // Third review, F: a relay that caught a removal as it went by, held it back, and hands it out after the device has
    // signed in again. A device gets a new number at each sign-in, so no removal signed before can name it.
    test('a removal caught before the device signed in again is never taken: each sign-in is a new number', () async {
      final (phone, draft) = await made();
      final laptop = _Told(accounts, handles);
      await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
      final first = laptop.account.device;
      final caught = removalBy(draft.words, laptop.account.address!, first);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await laptop.account.finish(await laptop.account.signInWithPassword('maya', 'correct horse battery'));
      expect(laptop.account.device, isNot(first));
      laptop.said = caught;
      await laptop.account.check();
      expect(laptop.wipes, isEmpty);
      // An install signed in before devices kept when they joined: from its first check on, a removal signed before it
      // is an old one, even one naming its number.
      final old = _Told(accounts, handles);
      await old.account.finish(await old.account.signInWithPassword('maya', 'correct horse battery'));
      old.store.set('acct_joined', '');
      final replayed = removalBy(draft.words, old.account.address!, old.account.device, at: DateTime.now().millisecondsSinceEpoch - 3600000);
      await old.account.check();
      expect(old.account.joinedAt, greaterThan(DateTime.now().millisecondsSinceEpoch - 60000));
      old.said = replayed;
      await old.account.check();
      expect(old.wipes, isEmpty);
      expect(phone.wipes, isEmpty);
    });

    // Signing in again put the backup's friends and circles in place of this device's (Account.finish → apply), losing
    // whatever came since the backup was last sealed (third review). Listing it again keeps them.
    test('a relay that doesn\'t hold the account: listing this device again puts it there from here, and keeps what is here', () async {
      final iphone = Device(accounts, handles, hasFriends: true);
      await iphone.claim('maya');
      await iphone.account.create(iphone.account.draft(), 'correct horse battery');
      final otherHandles = Handles(texts: FakeTexts())..load();
      final other = Accounts(handles: otherHandles);
      iphone
        ..relayAccounts = other
        ..handles = otherHandles;
      otherHandles.came(iphone.connection, (_) {}, key: iphone.keys.public);
      await iphone.account.check();
      expect(iphone.account.unknownHere, isTrue);
      iphone.applied = null;
      await iphone.account.listHereAgain();
      expect(iphone.account.unknownHere, isFalse);
      expect(iphone.applied, isNull, reason: 'nothing of the backup put in place of what is here');
      await iphone.account.check();
      expect(iphone.account.unknownHere, isFalse);
      expect((await iphone.account.devices()).single.here, isTrue);
      expect(iphone.wipes, isEmpty);
    });
  });

  // What else of the person's a device of its own keeps, deleted with its store when everything goes: Files spaces'
  // files, call recordings, the voice changer's key, and every other network's sign-in. Never the computer's own: the
  // test's folder stands in for the app's.
  test('everything else of the person\'s on an iPhone or a computer goes too: recordings, the voice changer, the relay it hosted, other networks', () async {
    final home = Directory.systemTemp.createTempSync('ghost-home');
    addTearDown(() => home.deleteSync(recursive: true));
    for (final name in ['recordings', 'voicechanger', 'relay', 'tdlib', 'signal', 'whatsapp', 'matrix', 'gmessages', 'space-files', 'unrelated']) {
      Directory('${home.path}/$name').createSync();
      File('${home.path}/$name/kept').writeAsStringSync(name);
    }
    final network = _Network();
    final files = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: Directory('${home.path}/space-files'));
    Sms.standalone = true;
    addTearDown(() => Sms.standalone = false);
    await AppAccountProfiles(home: home.path, files: files, networks: [network]).wipe();
    expect(network.signedOut, 1);
    final left = [for (final e in home.listSync()) e.uri.pathSegments.where((p) => p.isNotEmpty).last];
    expect(left, ['unrelated'], reason: 'only what the app keeps of the person goes');
  });

  // A copy of the app started with a folder of its own (GHOST_DESK_DIR: a developer's beside the installed one, which on
  // Windows share %APPDATA%) deleted the installed copy's sessions as it wiped (third review): only the folder this copy
  // keeps everything in is deleted under, and where it was never said, nothing.
  test('a wipe deletes folders only under this copy\'s own folder, never the installed default\'s', () async {
    final was = AppAccountProfiles.appFolder;
    addTearDown(() => AppAccountProfiles.appFolder = was);
    AppAccountProfiles.appFolder = null;
    expect(AppAccountProfiles().wipeFolder, isNull);
    final mine = Directory.systemTemp.createTempSync('ghost-dev-copy');
    addTearDown(() => mine.deleteSync(recursive: true));
    Directory('${mine.path}/recordings').createSync();
    AppAccountProfiles.appFolder = mine.path;
    expect(AppAccountProfiles().wipeFolder, mine.path);
    expect(AppAccountProfiles(home: '/elsewhere').wipeFolder, '/elsewhere');
    Sms.standalone = true;
    addTearDown(() => Sms.standalone = false);
    final files = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: Directory('${mine.path}/space-files'));
    await AppAccountProfiles(files: files, networks: const []).wipe();
    expect(Directory('${mine.path}/recordings').existsSync(), isFalse);
    // Nowhere in the account's code is the default folder used for it any more.
    expect(File('lib/account/account.dart').readAsStringSync(), isNot(contains('DeskStore.defaultDir().path')));
  });

  // An iPhone's push token, given to the relay so it can wake the app (relay/lib/pushes.dart), is taken back before the
  // routes stop on a wipe or a sign-out: a wiped iPhone isn't woken with "New message" for who it was. Net passes it to
  // the hub route, which says {"push": null} at once (test/push_wake_test.dart); the relay keeps a token per device, so
  // a sibling iPhone of the account keeps its own (relay/test/pushes_test.dart).
  test('stopping the routes takes an iPhone\'s push token back first', () async {
    Net.instance.setPush({'apns': 'ab' * 80, 'sandbox': true});
    addTearDown(() => Net.instance.setPush(null));
    await AppAccountProfiles().stopAll();
    expect(Net.instance.push, isNull);
  });

  // An Android phone (or a computer paired with one): removed, it forgets the account's words and keys, as before.
  test('elsewhere, a removed device forgets the account and deletes nothing else', () async {
    final (phone, _) = await made();
    final android = Device(accounts, handles);
    await android.account.finish(await android.account.signInWithPassword('maya', 'correct horse battery'));
    await phone.account.removeDevice((await phone.account.devices()).firstWhere((d) => !d.here).id);
    await android.account.check();
    expect(android.wipes, isEmpty);
    expect(android.account.signedIn, isFalse);
    expect(android.secrets, isEmpty);
  });

  test('signing in by password sends only the proof, never weaker than an account is made with', () async {
    await made();
    // A relay offering cheaper Argon2id settings than an account is made with gets no proof at all.
    final fresh = _Tampering(accounts, handles);
    await expectLater(fresh.account.signInWithPassword('maya', 'correct horse battery'), throwsA(isA<AccountError>()));
    expect(fresh.said.where((m) => m['dir'] == 'acct-get'), isEmpty);
    // Honest: the password itself never leaves, only the proof, which is not the key that seals the copy.
    fresh.weaken = false;
    final restore = await fresh.account.signInWithPassword('maya', 'correct horse battery');
    final get = fresh.said.singleWhere((m) => m['dir'] == 'acct-get');
    expect(get.toString().contains('correct horse battery'), isFalse);
    final pk = restore.passwordKey!;
    expect(get['auth'], NetCrypto.hex(pk.auth));
    expect(NetCrypto.hex(pk.auth), isNot(NetCrypto.hex(pk.key)));
    expect(pk.verifier, NetCrypto.hex(NetCrypto.sha256(pk.auth)));
  });
}

/// A device whose relay, where [weaken], offers Argon2id settings cheaper than an account is made with.
class _Tampering extends Device {
  _Tampering(super.relayAccounts, super.handles);
  var weaken = true;
  final said = <Map<String, Object?>>[];
  @override
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    said.add(what);
    final m = await super.ask(what);
    if (weaken && m['kdf'] is Map) m['kdf'] = {...(m['kdf'] as Map), 'm': 8 * 1024, 't': 1};
    return m;
  }
}
