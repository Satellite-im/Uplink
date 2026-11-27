import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/identity.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/ui/identity_ui.dart';
import 'package:ghost_messaging/ui/profile_card.dart';

import 'support/list_harness.dart';

/// The account key's screens (GMFB-33; lib/ui/identity_ui.dart): the did:key on the profile with Copy and Share, a
/// statement signed and checked, and a friend's key on their card.
class _Port implements BuddiesPort {
  _Port(this.list);
  final String list;
  @override
  Future<({String id, String key})> me() async => (id: 'a' * 32, key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => list;
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

void main() {
  final mine = NetKeys.generate(), maya = NetKeys.generate();
  final copied = <String>[];

  setUp(() {
    copied.clear();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  Future<Buddies> friendsWithMaya() async {
    final b = Buddies(_Port(jsonEncode([Buddy(username: 'maya', id: maya.id, key: base64Encode(maya.public), name: 'Maya Chen').toJson()])));
    await b.start();
    return b;
  }

  testWidgets('Profile › Your account key: the did:key, copied whole; the address; sign and check are offered', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(
        tester,
        sheet,
        ListView(children: [AccountKeySection(identity: () async => (id: mine.id, key: mine.public), sign: (m) async => NetCrypto.sign(mine, m), address: '0xAbCd1234567890aBCDef1234567890abcDEF1234')]),
        AppState());
    final did = Did.ofKey(mine.public);
    expect(find.text(Did.short(did)), findsOneWidget);
    expect(find.text(didWords), findsOneWidget);
    expect(find.text('0xAbCd12…EF1234'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('did-copy')));
    await settle(tester);
    expect(copied, [did], reason: 'the whole DID, not the shortened one shown');
    expect(find.text('Sign a statement'), findsOneWidget);
    expect(find.text('Check a statement'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a statement is signed on screen, copied, and checks out as this account\'s', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, SignStatementScreen(publicKey: mine.public, sign: (m) async => NetCrypto.sign(mine, m)), AppState(), size: const Size(412, 1600));
    await tester.enterText(find.byKey(const ValueKey('proof-words')), 'I am @matt on Uplink, and @matt_codes elsewhere');
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('proof-make')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('proof-copy')));
    await settle(tester);
    final c = Proof.check(copied.single);
    expect([c.good, c.statement, c.did], [true, 'I am @matt on Uplink, and @matt_codes elsewhere', Did.ofKey(mine.public)]);

    // Too long: said, and not signed.
    await tester.enterText(find.byKey(const ValueKey('proof-words')), 'x' * 281);
    await settle(tester);
    expect(find.text('1 too many'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Check a statement says whose it is: yours, a friend\'s, someone else\'s, or that it doesn\'t check out', (tester) async {
    final sheet = await loadSheet(tester);
    final buddies = (await tester.runAsync(friendsWithMaya))!;
    Future<String> signed(NetKeys k, String words) async => (await tester.runAsync(() => Proof.make(words, publicKey: k.public, sign: (m) async => NetCrypto.sign(k, m))))!;
    final ofMaya = await signed(maya, 'I am @maya on Uplink');
    final ofMine = await signed(mine, 'I am @matt on Uplink');
    final stranger = NetKeys.generate();
    final ofStranger = await signed(stranger, 'I am @maya on Uplink');
    await pumpScreen(tester, sheet, CheckStatementScreen(mine: Uint8List.fromList(mine.public), buddies: buddies), AppState(), size: const Size(412, 1400));

    Future<String> check(String pasted) async {
      await tester.enterText(find.byKey(const ValueKey('check-words')), pasted);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('check-go')));
      await settle(tester);
      final row = find.descendant(of: find.byKey(const ValueKey('check-result')), matching: find.byType(Text));
      return tester.widget<Text>(row.first).data!;
    }

    expect(await check(ofMaya), 'Signed by Maya Chen (@maya), your friend.');
    expect(find.text('IT CHECKS OUT'), findsOneWidget);
    expect(await check(ofMine), 'Signed by you.');
    expect(await check(ofStranger), startsWith('Signed by an account you don\'t have as a friend: ${Did.short(Did.ofKey(stranger.public))}'),
        reason: 'it says @maya, and isn\'t the key held for her');
    expect(await check(ofMaya.replaceFirst('@maya', '@mayа')), contains('signature doesn\'t match'));
    expect(find.text('IT DOESN\'T CHECK OUT'), findsOneWidget);
    buddies.dispose();
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a friend\'s card shows their account key, and Copy copies it whole', (tester) async {
    final sheet = await loadSheet(tester);
    final buddies = (await tester.runAsync(friendsWithMaya))!;
    Buddies.instance = buddies;
    addTearDown(() => Buddies.instance = null);
    await pumpScreen(tester, sheet, Builder(builder: (context) => GestureDetector(onTap: () => showProfile(context, ProfileSubject.ghost(id: maya.id)), child: const Text('open'))), AppState());
    await tester.tap(find.text('open'));
    await settle(tester);
    final did = Did.ofKey(maya.public);
    expect(find.byKey(const ValueKey('profile-did')), findsOneWidget);
    expect(find.text(Did.short(did)), findsOneWidget);
    expect(find.text(theirDidWords('Maya Chen')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-did-copy')));
    await settle(tester);
    expect(copied, [did]);
    await tester.pump(const Duration(seconds: 5));
  });
}
