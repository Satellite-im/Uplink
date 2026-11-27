import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/me/me.dart' show Me;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/packet.dart';

import 'support/direct_world.dart' show PlainCarrier;
import 'support/fake_friends.dart';

/// The copies an account's devices pass each other of what is said with friends by username (GMFB-21;
/// lib/friends/friends.dart, copyKind), as a device that has only just opened takes them: Matt, 2026-11-23, "messages
/// are not in sync across mobile and desktop". The phone under it is a stand-in channel, as test/p2p_net_test.dart's.

/// Waits for [ok], however long the machine takes (five seconds at most), not for a length of time.
Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = NetKeys.generate(), sam = NetKeys.generate();
  final samKey = NetCrypto.netKey(NetCrypto.conversationKey(me, sam.public)!);
  late Map<String, String> secrets;

  /// What the phone was asked to keep with the conversations: (method, address, words).
  late List<(String, String, String)> kept;

  setUp(() {
    HttpOverrides.global = null;
    secrets = {};
    kept = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final a = call.arguments is Map ? call.arguments as Map : const {};
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (a['message'] as List).cast<int>());
        case 'netPeers':
          return [
            {'id': sam.id, 'address': '@sam', 'key': samKey},
          ];
        case 'e2eList':
          return [
            {'address': '@sam', 'state': 'on', 'friend': 'yes', 'id': sam.id},
          ];
        case 'buddiesKept':
          return jsonEncode([
            {'u': 'sam', 'i': sam.id, 'k': base64Encode(sam.public), 's': 'yes'},
          ]);
        case 'netSmsDrain':
          return const <Object>[];
        case 'secretKeep':
          final value = '${a['value'] ?? ''}';
          value.isEmpty ? secrets.remove('${a['name']}') : secrets['${a['name']}'] = value;
          return null;
        case 'secretRead':
          return secrets['${a['name']}'];
        case 'netTextOut' || 'netTextIn':
          kept.add((call.method, '${a['address']}', '${a['body']}'));
          return kept.length;
      }
      return null;
    });
  });
  tearDown(() async {
    await Friends.instance.shutdown();
    Friends.instance = null;
    await Net.instance.shutdown();
  });

  /// A copy as the account's other device sends it: to the account's own name, sealed with the account's key.
  Uint8List copyOf(Uint8List mineKey, {required String id, required String words, required bool out}) {
    final e = Envelope(kind: Friends.copyKind, body: {'a': '@sam', 't': words, 'i': id, 'at': 1700000000000, 'o': out});
    return Packet.wrap(from: me.id, sealed: true, payload: NetCrypto.seal(mineKey, e.encode()));
  }

  test('a device that has just opened, and has sent nothing yet, keeps the copies its other device sent while it was closed', () async {
    final words = AccountCrypto.newWords();
    secrets['account_words'] = words.join(' ');
    final mineKey = Me.mineKeyOf(words);
    final hub = PlainCarrier('hub');
    // Direct as it starts, off: nothing else reads the account's key.
    final app = AppState();
    await Net.instance.start(app, carriers: [hub]);
    await Friends.instance.start(app);

    // What the relay kept for this device, handed over as it signs in: what the phone wrote to Sam, and his answer.
    hub.take(copyOf(mineKey, id: 'a' * 32, words: 'on my way', out: true), from: me.id);
    hub.take(copyOf(mineKey, id: 'b' * 32, words: 'see you at 7', out: false), from: me.id);
    await _until(() => kept.length == 2, 'both copies are kept with the conversation');
    expect(kept, [('netTextOut', '@sam', 'on my way'), ('netTextIn', '@sam', 'see you at 7')]);
  });

  test('the account\'s key goes with the routes: the next account signed in here does not open copies with the last one\'s', () async {
    final first = AccountCrypto.newWords(), second = AccountCrypto.newWords();
    secrets['account_words'] = first.join(' ');
    await Net.instance.start(AppState(), carriers: [PlainCarrier('hub')]);
    expect((await Net.instance.mine())!.key, Me.mineKeyOf(first));
    await Net.instance.shutdown();
    secrets['account_words'] = second.join(' ');
    await Net.instance.start(AppState(), carriers: [PlainCarrier('hub')]);
    expect((await Net.instance.mine())!.key, Me.mineKeyOf(second));
  });

  // The other device passes a copy on once, so the one that wrote the message is handed its own back: at once where it
  // is connected, when it next opens where it had closed (a phone, a moment after sending).
  test('what this device sent is known as its own after a restart: the copy its other device passes back is not kept again', () async {
    final phone = FakePort('@ann'), mac = FakePort('@ann'), friend = FakePort('@ben');
    phone.other = friend;
    friend.other = phone;
    mac.twin = phone;
    phone.stand('@ben', friend: 'yes');
    friend.stand('@ann', friend: 'yes');
    final app = AppState();
    final first = Friends(phone);
    await first.start(app);
    expect(await first.sendText('@ben', 'Dinner at 8?'), isTrue);
    // (Beside it, the device's one asking for its account's history, GMFB-53.)
    await _until(() => phone.mineSent.any((e) => e.kind == Friends.copyKind), 'the copy went to the account\'s other devices');
    final copy = phone.mineSent.where((e) => e.kind == Friends.copyKind).single;
    await first.shutdown();

    // The app opened again, with the choices it kept; the relay hands over what the Mac passed on meanwhile.
    final again = Friends(phone);
    addTearDown(again.shutdown);
    await again.start(app);
    await mac.sendMine(copy);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(phone.rows.length, 1, reason: 'the message is in the conversation once');
  });
}
