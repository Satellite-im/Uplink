import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/own_calls.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/me/me.dart' show MemoryMeStore;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsSectionScreen;
import 'package:ghost_relay/accounts.dart';
import 'package:ghost_relay/handles.dart';
import 'package:glacier/glacier.dart';

import 'account_flow_test.dart' show Device, FakeTexts;
import 'themes_test.dart' show ThemeScreen, shootLook;

/// An Uplink account on a computer paired with a phone, whose friends and circles run under the phone's identity taken
/// on here (lib/desktop/own_calls.dart). Matt, 2026-11-18: "On my fold vs on my desktop, both with the same number
/// linked but it seems i'm not logged in on desktop, there doesn't seem to be a way to login on desktop just to claim a
/// username, i would like to be able to link a session to a new account".
///
/// What matters most: an account's calls (a new identity, the words kept, a restart) are this computer's, and never
/// reach the phone across the link, where a sign-in would have changed the phone's identity.
class _Store implements LinkStore {
  @override
  Future<PairedPhone?> load() async => null;
  @override
  Future<void> save(PairedPhone phone) async {}
  @override
  Future<void> clear() async {}
}

/// The phone across the link: every method it was asked, and a text sent through it.
class _Phone extends LinkCalls {
  _Phone(Directory dir) : super(PhoneLink(store: _Store(), name: 'Test Mac', app: '0.9.11'), DeskStore(dir, keychain: false));
  final asked = <String>[];

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    asked.add(method);
    final Object? answer = switch (method) {
      'send' => 99,
      'e2eList' || 'conversations' => const [],
      'conversationsPage' => {'items': const [], 'next': null},
      'prefs' => <String, String>{},
      _ => null,
    };
    return answer as T?;
  }
}

void main() {
  late Directory root;
  late Handles handles;
  late Accounts accounts;
  setUp(() {
    root = Directory.systemTemp.createTempSync('ghost-desk-account');
    handles = Handles(texts: FakeTexts())..load();
    accounts = Accounts(handles: handles);
  });
  tearDown(() {
    Sms.calls = _Phone(root);
    root.deleteSync(recursive: true);
  });

  /// A computer that has taken on [phoneKeys], over a phone that answers [_Phone].
  Future<(DeskOwnCalls, _Phone, Directory)> adopted(NetKeys phoneKeys, {Map<String, Object?>? account}) async {
    final dir = Directory('${root.path}/own');
    await DeskOwnCalls.adopt(dir, {'scalar': NetCrypto.hex(phoneKeys.scalar), 'buddies': '[]', 'account': ?account}, keychain: false);
    final phone = _Phone(root);
    final own = DeskOwnCalls(phone, dir, keychain: false);
    var restarts = 0;
    own.restart = () async {
      restarts++;
      return restarts > 0;
    };
    await own.load();
    Sms.calls = own;
    return (own, phone, dir);
  }

  /// The account as this computer has it: the app's own port ([SmsAccountPort], through [Sms.calls]) and a relay
  /// connection of its own.
  Account deskAccount() {
    final connection = Device(accounts, handles);
    return Account(relay: connection, port: SmsAccountPort(), store: MemoryMeStore(), profiles: connection);
  }

  void expectPhoneUntouched(_Phone phone) {
    for (final m in DeskOwnCalls.accountCalls) {
      expect(phone.asked, isNot(contains(m)), reason: '$m must never reach the phone');
    }
  }

  test('a paired computer with its own network shows the account section, and is never fresh', () async {
    final (_, _, _) = await adopted(NetKeys.generate());
    expect(Sms.paired, isTrue);
    expect(Sms.ownNetwork, isTrue, reason: 'Settings › Me shows the account section on Sms.ownNetwork');
    expect(Sms.followsPhone, isFalse);
    // Its identity is the phone's: an account made here keeps it (bound) rather than taking the words' own.
    expect(AppAccountProfiles().fresh, isFalse);
  });

  test('an account\'s calls are answered on the computer, never passed to the phone', () async {
    final phoneKeys = NetKeys.generate();
    final (own, phone, dir) = await adopted(phoneKeys);
    expect(NetKeys.fromScalar(await Sms.instance.identityExport()).id, phoneKeys.id);
    final next = NetKeys.generate();
    await Sms.instance.identityImport(next.scalar, next.public);
    expect(own.keys!.id, next.id);
    expect(File('${dir.path}/identity.key').readAsStringSync(), NetCrypto.hex(next.scalar), reason: 'the file fallback of a build without the Keychain');
    await Sms.instance.secretKeep('account_words', 'one two three');
    expect(await Sms.instance.secretRead('account_words'), 'one two three');
    await Sms.instance.secretKeep('account_words', '');
    expect(await Sms.instance.secretRead('account_words'), isNull);
    expect(await Sms.instance.restartApp(), isTrue);
    expect(await Sms.instance.identityForget(), isTrue);
    expect(DeskOwnCalls.adoptedIn(dir), isFalse, reason: 'the phone\'s identity is taken on again at the next start');
    expectPhoneUntouched(phone);
  });

  test('signing in to the phone\'s own account keeps the computer the same you; the link to the phone is intact', () async {
    // The phone made its account with friends, so it is bound to the phone's identity.
    final fold = Device(accounts, handles, hasFriends: true);
    await fold.claim('matt');
    await fold.account.create(fold.account.draft(), 'correct horse battery');
    final (own, phone, dir) = await adopted(fold.keys, account: {'a': fold.account.address, 'u': 'matt'});
    expect(own.phoneAccount?.username, 'matt');

    final account = deskAccount();
    final restore = await account.signInWithPassword('matt', 'correct horse battery');
    expect(await account.wouldChangeIdentity(restore), isFalse, reason: 'the account is the phone\'s identity');
    expect(await account.finish(restore), isTrue, reason: 'the computer opens again');
    expect(own.keys!.id, fold.keys.id);
    expect(account.address, fold.account.address);
    expect(File('${dir.path}/secret-account_words.key').existsSync(), isTrue, reason: 'the words kept on this computer');
    expect((await account.devices()).length, 2, reason: 'the phone and this computer, under one account');
    expectPhoneUntouched(phone);

    // Texts still go through the phone.
    expect(await own.invokeMethod<int>('send', {'addresses': ['+15550001'], 'body': 'hi'}), 99);
    expect(phone.asked, contains('send'));
  });

  test('signing in to another account is known to split the computer from the phone, and stays on the computer', () async {
    final other = Device(accounts, handles, hasFriends: true);
    await other.claim('someone');
    await other.account.create(other.account.draft(), 'another long password');
    final phoneKeys = NetKeys.generate();
    final (own, phone, _) = await adopted(phoneKeys);

    final account = deskAccount();
    final restore = await account.signInWithPassword('someone', 'another long password');
    expect(await account.wouldChangeIdentity(restore), isTrue, reason: 'Settings asks before this');
    await account.finish(restore);
    expect(own.keys!.id, other.keys.id);
    expectPhoneUntouched(phone);
  });

  test('making an account here binds the computer\'s identity, the phone\'s, to it', () async {
    final phoneKeys = NetKeys.generate();
    final (own, phone, _) = await adopted(phoneKeys);
    final connection = Device(accounts, handles, hasFriends: true);
    final account = Account(relay: connection, port: SmsAccountPort(), store: MemoryMeStore(), profiles: connection);
    expect(await account.create(account.draft(), 'correct horse battery'), isFalse, reason: 'kept its identity: no restart');
    expect(account.mode, 'bound');
    expect(own.keys!.id, phoneKeys.id);
    expect(accounts.accountOf(phoneKeys.id), account.address!.toLowerCase());
    expectPhoneUntouched(phone);
  });

  test('signing out goes back to the phone\'s identity rather than someone new', () async {
    final fold = Device(accounts, handles, hasFriends: true);
    await fold.claim('matt');
    await fold.account.create(fold.account.draft(), 'correct horse battery');
    final (_, phone, dir) = await adopted(fold.keys);
    final account = deskAccount();
    await account.finish(await account.signInWithPassword('matt', 'correct horse battery'));
    await account.signOut();
    expect(account.signedIn, isFalse);
    expect(DeskOwnCalls.adoptedIn(dir), isFalse, reason: 'the handover takes the phone\'s identity on again');
    expect(File('${dir.path}/identity.key').existsSync(), isFalse);
    expectPhoneUntouched(phone);
  });

  test('a computer still asking the phone for everything makes no account', () async {
    Sms.calls = _Phone(root);
    expect(Sms.followsPhone, isTrue);
    await expectLater(SmsAccountPort().identityExport(), throwsA(isA<AccountError>()));
    expect(await Sms.instance.identityForget(), isFalse);
    expect((Sms.calls as _Phone).asked, isEmpty);
  });

  testWidgets('Settings › Me on a paired computer, in Uplink light', (tester) async {
    Future<void> family(String name, String file) async {
      final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
      await loader.load();
    }

    await tester.runAsync(() async {
      await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
      await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
    });
    final (_, _, _) = (await tester.runAsync(() => adopted(NetKeys.generate(), account: {'a': '0x9858EfFD232B4033E47d90003D41EC34EcaEda94', 'u': 'matt'})))!;
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    await shootLook(tester, sheet, Look.ghost, 'light', ThemeScreen('desk-account-me', () => const SettingsSectionScreen('me'), size: const Size(412, 1100)), write: false);
    expect(find.text('Sign in to your Uplink account'), findsOneWidget);
    expect(find.text('@matt, the account your phone is in'), findsOneWidget);
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('Sign in to another account'), findsOneWidget);
    final element = find.byType(WidgetsApp).evaluate().single;
    await tester.runAsync(() async {
      final image = await captureImage(element);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File('build/themes/ghost-light-desk-account-me.png')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(png!.buffer.asUint8List());
    });
  });
}
