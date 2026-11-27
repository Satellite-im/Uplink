import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_seen.dart';
import 'package:ghost_messaging/desk_stamp.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

// Matt, 2026-11-24, with Android's battery page saying "High CPU usage" under the app: "please see what you can do
// about the high CPU usage on the app" (docs/performance-audit.md, "Calls and a paired computer").
void main() {
  group('the mark a phone gives its answer to a paired computer', () {
    test('is the same for the same answer, and another for any change in it', () {
      Map<String, Object?> answer({String name = 'Maya', String body = 'x'}) => {
            'channels': [
              {'s': 'aa', 'n': 'Plaza', 'm': 1},
            ],
            'circles': [
              {'s': 'bb', 'o': 'cc', 'm': {'b': body, 'by': null, 's': 'sig'}},
            ],
            'gone': <String>[],
            'name': name,
          };
      expect(deskStamp(answer()), deskStamp(answer()));
      expect(deskStamp(answer()), hasLength(8));
      expect(deskStamp(answer(name: 'Sam')), isNot(deskStamp(answer())));
      expect(deskStamp(answer(body: 'y')), isNot(deskStamp(answer())), reason: 'a circle\'s own words count, not only its name');
    });

    test('tells where one string ends and the next begins', () {
      expect(deskStamp(['ab', 'c']), isNot(deskStamp(['a', 'bc'])));
      expect(deskStamp({'a': 'b'}), isNot(deskStamp(['a', 'b'])));
      expect(deskStamp(['1']), isNot(deskStamp([1])));
    });

    test('a big answer is marked in a few milliseconds', () {
      // Five circles at their largest: what a phone would otherwise seal and send every eight seconds.
      final big = {
        'circles': [for (var i = 0; i < 5; i++) {'s': '$i', 'm': {'b': 'x' * 60000}}],
      };
      final w = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        deskStamp(big);
      }
      expect(w.elapsedMilliseconds, lessThan(1000), reason: '${w.elapsedMilliseconds} ms for ten');
    });

    test('a computer that has the answer is told so in a word; one that has another, or none, gets it whole', () {
      final answer = <String, Object?>{'list': ['a', 'b'], 'name': 'Maya'};
      final whole = stampedFor(null, answer);
      expect(whole['list'], ['a', 'b']);
      final stamp = whole['stamp'] as String;
      expect(stampedFor(stamp, answer), {'same': 1, 'stamp': stamp});
      expect(stampedFor('00000000', answer)['list'], ['a', 'b']);
      // What a computer reads back is the answer itself: nothing of it was changed to mark it.
      expect(jsonDecode(jsonEncode(whole)), {...answer, 'stamp': stamp});
    });
  });

  group('what is only looked at stops while the app can\'t be seen', () {
    test('seen in front and beside another window; not hidden, paused or closed', () {
      expect(AppSeen.seenIn(null), isTrue, reason: 'nothing said yet: as if seen');
      expect(AppSeen.seenIn(AppLifecycleState.resumed), isTrue);
      expect(AppSeen.seenIn(AppLifecycleState.inactive), isTrue, reason: 'a window behind another is still on the screen');
      expect(AppSeen.seenIn(AppLifecycleState.hidden), isFalse);
      expect(AppSeen.seenIn(AppLifecycleState.paused), isFalse);
      expect(AppSeen.seenIn(AppLifecycleState.detached), isFalse);
    });

    testWidgets('follows the app as it is put away and brought back', (tester) async {
      AppSeen.follow();
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(AppSeen.now.value, isTrue);
      final heard = <bool>[];
      void listen() => heard.add(AppSeen.now.value);
      AppSeen.now.addListener(listen);
      addTearDown(() => AppSeen.now.removeListener(listen));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(heard, isEmpty, reason: 'still on the screen');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(heard, [false], reason: 'told once');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(heard, [false, true]);
    });
  });

  group('what a space is known by is worked out once', () {
    test('and is what it always was: derived from the seed under each label', () {
      final c = VoiceChannel.make('Plaza');
      final seed = NetCrypto.unhex(c.seed);
      expect(c.room, NetCrypto.hex(NetCrypto.derive(seed, 'voice room').sublist(0, 16)));
      expect(c.token, NetCrypto.hex(NetCrypto.derive(seed, 'voice token')));
      expect(c.key, NetCrypto.derive(seed, 'voice key'));
      expect(c.chatRoom, NetCrypto.hex(NetCrypto.derive(seed, 'hangout room').sublist(0, 16)));
      expect(c.chatToken, NetCrypto.hex(NetCrypto.derive(seed, 'hangout token')));
      // Another space's are its own.
      final d = VoiceChannel.make('Yard');
      expect(d.room, isNot(c.room));
      expect(d.key, isNot(c.key));
    });

    test('a key handed out can be changed without changing the next one handed out', () {
      final c = VoiceChannel.make('Plaza');
      final first = c.key;
      final copy = Uint8List.fromList(first);
      first.fillRange(0, first.length, 0);
      expect(c.key, copy);
    });

    test('asking again costs next to nothing', () {
      final c = VoiceChannel.make('Plaza');
      c.room;
      final w = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        c.room;
        c.chatRoom;
      }
      // Derived afresh, each was a hash in pure Dart: forty thousand took seconds.
      expect(w.elapsedMilliseconds, lessThan(400), reason: '${w.elapsedMilliseconds} ms');
    });

    test('a roster\'s owner is known by the same id as ever', () {
      final keys = NetKeys.generate();
      final owner = NetCrypto.hex(keys.public);
      final r = Roster.first(owner);
      expect(r.ownerId, NetCrypto.idOf(keys.public));
      expect(r.ownerId, r.ownerId);
      expect(Roster.first('').ownerId, '');
      expect(r.isOwner(NetCrypto.idOf(keys.public)), isTrue);
    });
  });
}
