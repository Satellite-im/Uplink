import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/own_calls.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/standalone/overlay.dart';

/// A computer paired with a phone, with friends and circles of its own (Matt, 2026-11-18: "I want desktop to be able to
/// run standalone for internal friends and circles please fix that even if the desktop is linked";
/// lib/desktop/own_calls.dart): the phone's identity taken on here, friends by username kept and written to here, texts
/// still the phone's.
class _Store implements LinkStore {
  @override
  Future<PairedPhone?> load() async => null;
  @override
  Future<void> save(PairedPhone phone) async {}
  @override
  Future<void> clear() async {}
}

/// The phone, across the link: what it was asked, and a texts' conversation of its own.
class _Phone extends LinkCalls {
  _Phone(Directory dir) : super(PhoneLink(store: _Store(), name: 'Test Mac', app: '0.9.7'), DeskStore(dir, keychain: false));
  final asked = <String>[];

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    asked.add(method);
    final Object? answer = switch (method) {
      'conversationsPage' => {
          'items': [
            {'id': 7, 'date': 1, 'people': [{'address': '+15550001', 'name': 'Mom'}], 'snippet': 'hi', 'unread': false, 'error': false, 'archived': false},
          ],
          'next': null,
        },
      'e2eList' => const [],
      'send' => 99,
      _ => null,
    };
    return answer as T?;
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('ghost-desk-own'));
  tearDown(() {
    Sms.calls = _Phone(root);
    root.deleteSync(recursive: true);
  });

  test('the phone\'s identity, friends and conversations are taken on; friends are this computer\'s, texts the phone\'s', () async {
    final keys = NetKeys.generate();
    final dir = Directory('${root.path}/own');
    expect(DeskOwnCalls.adoptedIn(dir), isFalse);
    await DeskOwnCalls.adopt(
      dir,
      {
        'scalar': NetCrypto.hex(keys.scalar),
        'buddies': jsonEncode([
          {'u': 'kevin', 'i': 'k1', 'k': base64Encode(NetKeys.generate().public), 'n': 'Kevin', 'b': '', 's': 'yes', 'a': 0},
        ]),
      },
      keychain: false,
    );
    expect(DeskOwnCalls.adoptedIn(dir), isTrue);
    final phone = _Phone(root);
    final own = DeskOwnCalls(phone, dir, keychain: false);
    await own.load();
    Sms.calls = own;
    expect(Sms.paired, isTrue, reason: 'texts are still the phone\'s');
    expect(Sms.ownNetwork, isTrue);
    expect(Sms.followsPhone, isFalse);

    // Who this computer is on the routes: the phone's identity.
    final me = (await own.invokeMethod<Map>('netIdentity'))!;
    expect(me['id'], keys.id);
    expect(own.buddyList.single.username, 'kevin');
    expect(phone.asked, isNot(contains('netIdentity')));

    // Kevin's conversation is kept here, beside the phone's texts.
    final thread = (await own.invokeMethod<int>('threadFor', {'addresses': ['@kevin']}))!;
    expect(thread, greaterThanOrEqualTo(UsernameOverlay.base));
    await own.invokeMethod('netTextIn', {'address': '@kevin', 'body': 'You there?', 'at': 5});
    final page = (await own.invokeMethod<Map>('conversationsPage', {'offset': 0, 'limit': 50}))!;
    final items = page['items'] as List;
    expect(items.length, 2, reason: 'the phone\'s conversation, and Kevin\'s kept here');
    expect(phone.asked, isNot(contains('netTextIn')));
    // A text to a number is the phone's.
    expect(await own.invokeMethod<int>('send', {'addresses': ['+15550001'], 'body': 'hi'}), 99);
    expect(phone.asked, contains('send'));
  });

  test('each side\'s friends are taken in by the other, the further along kept', () {
    String list(List<(String, String)> b) => jsonEncode([for (final (u, s) in b) {'u': u, 'i': u, 'k': 'k', 'n': '', 'b': '', 's': s, 'a': 0}]);
    final merged = jsonDecode(DeskOwnCalls.mergeBuddies(list([('kevin', 'asked'), ('jo', 'yes')]), list([('kevin', 'yes'), ('sam', 'invited')]))) as List;
    final states = {for (final b in merged) (b as Map)['u']: b['s']};
    expect(states, {'kevin': 'yes', 'jo': 'yes', 'sam': 'invited'});
  });
}
