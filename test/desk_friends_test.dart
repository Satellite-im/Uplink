import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/link/session.dart' show PhoneError;
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/add_friend_drawer.dart';
import 'package:ghost_messaging/ui/contacts.dart';

import 'support/list_harness.dart';

/// Friends by username on a computer paired with a phone (Matt, 2026-11-18: "I don't see the ability to add friends on
/// desktop"): the button is there, and what is done is asked of the phone (Buddies.forComputer there), whose list is
/// what the computer shows.
class _Phone implements SmsCalls {
  final asked = <Map<String, Object?>>[];
  final list = <Map<String, Object?>>[
    {'u': 'riley', 'i': 'r1', 'k': 'k', 'n': 'Riley Fox', 'b': '', 's': 'invited', 'a': 0},
  ];

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    if (method != 'buddies') return null;
    final what = ((arguments as Map)['what'] as Map).cast<String, Object?>();
    asked.add(what);
    switch (what['op']) {
      case 'add':
        if (what['u'] == 'nobody') throw const PhoneError('Nobody has the username @nobody.');
        final b = {'u': '${what['u']}', 'i': 'x1', 'k': 'k', 'n': '', 'b': '', 's': 'asked', 'a': 1};
        list.add(b);
        return {'buddy': b, 'list': list} as T;
      case 'accept':
        list[0] = {...list[0], 's': 'yes'};
        return {'buddy': list[0], 'list': list} as T;
    }
    return {'list': list} as T;
  }
}

void main() {
  late _Phone phone;
  setUp(() {
    phone = _Phone();
    Sms.calls = phone;
    Buddies.instance = null;
  });
  tearDown(() => Buddies.instance = null);

  test('a paired computer asks the phone, and shows the phone\'s list', () async {
    expect(Sms.paired, isTrue, reason: 'calls that are not the phone\'s own channel are a computer\'s');
    final b = Buddies.instance;
    await b.start();
    expect(b.requests.single.username, 'riley');
    final jo = await b.add('jo');
    expect(jo.state, 'asked');
    expect(phone.asked.last, {'op': 'add', 'u': 'jo'});
    expect(b.asked.single.username, 'jo');
    await b.accept(b.requests.single);
    expect(b.friends.single.username, 'riley');
    // The phone's refusal reaches the person in its own words.
    await expectLater(b.add('nobody'), throwsA(isA<MeError>().having((e) => e.message, 'message', 'Nobody has the username @nobody.')));
    b.dispose();
  });

  testWidgets('the address book offers Add friend on a computer', (tester) async {
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, const ContactsScreen(), AppState(), size: const Size(1100, 740));
    expect(find.byType(AddFriendButton), findsOneWidget);
  });
}
