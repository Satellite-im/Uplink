import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner, RoomEvent;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Replying to a message in a space's or a circle's chat (GMFB-13, @jerbo: "Please add a reply feature for messages
/// sent in group chats so I can specifically call out an individual for the crimes they have committed"): the answer
/// carries a quote of what it answers, which shows over it for everyone, and a build from before shows the words alone.
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Route implements VoiceRoute {
  _Route(this.me, this.key);
  @override
  final String me;
  final List<int> key;
  final said = <Map<String, dynamic>>[];
  final _packets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {
    final clear = NetCrypto.open(key, bytes);
    if (clear != null) said.add((jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
  }

  /// [what] said in the room by [from], as the relay hands it over.
  void hear(String room, String from, Map<String, Object?> what) => _packets.add((room: room, from: from, bytes: NetCrypto.seal(key, utf8.encode(jsonEncode(what)))));

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => _packets.stream;
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

({HangoutRoom room, _Route route}) _room({List<HangoutMessage> Function(String me)? messages}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.text, circle: 'c' * 64);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  final at = DateTime(2026, 11, 20, 9).millisecondsSinceEpoch;
  store.keepMessages(channel.chatRoom, messages?.call(keys.id) ??
      [
        HangoutMessage(id: 'm1', from: keys.id, name: 'Me', text: 'See you at 6', at: at),
        HangoutMessage(id: 'm2', from: _maya, name: 'Maya Chen', text: 'Great', at: at + 60000),
      ]);
  final route = _Route(keys.id, channel.key);
  return (room: HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store), route: route);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('a reply carries a quote of what it answers, over the wire and kept', () async {
    final (:room, :route) = _room();
    await room.open();
    final hers = room.messages.firstWhere((m) => m.id == 'm2');
    expect(room.send('You said that yesterday', reply: SpaceReply.of(hers)), isTrue);
    final said = route.said.lastWhere((m) => m['t'] == 'msg');
    expect(said['rp'], {'id': 'm2', 'f': _maya, 'n': 'Maya Chen', 'x': 'Great'});
    expect(said['x'], 'You said that yesterday', reason: 'a build from before shows the words alone');
    final back = HangoutMessage.fromJson(jsonDecode(jsonEncode(said)) as Map<String, dynamic>, room.me)!;
    expect((back.reply?.id, back.reply?.name, back.reply?.text), ('m2', 'Maya Chen', 'Great'));
    // Edited later: still the answer to the same message.
    expect(back.copyWith(text: 'edited').reply?.id, 'm2');
  });

  test('a quote is cut short, and one that is not a quote is left out', () {
    final long = HangoutMessage(id: 'x1', from: _maya, name: 'Maya Chen', text: 'a' * 400, at: 1);
    expect(SpaceReply.of(long).text.length, SpaceReply.most);
    expect(SpaceReply.fromJson({'id': '', 'x': 'hi'}), isNull);
    expect(SpaceReply.fromJson('nonsense'), isNull);
    final m = HangoutMessage.fromJson({'id': 'z', 'x': 'hey', 'at': 5, 'n': 'Sam', 'rp': 7}, 'b' * 32);
    expect(m?.reply, isNull, reason: 'a bad quote does not lose the message');
    expect(m?.text, 'hey');
  });

  testWidgets('Reply in a message\'s menu: the box says who is answered, and the answer shows the quote', (tester) async {
    final h = await SpaceHarness.load(tester);
    final (:room, route: _) = _room();
    await room.open();
    await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'space-reply');
    await tester.longPress(find.textContaining('Great'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Reply'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('space-replying')), findsOneWidget);
    expect(find.text('Replying to Maya Chen'), findsOneWidget);
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: 'Says you', selection: TextSelection.collapsed(offset: 8)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('composer-send')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('space-replying')), findsNothing, reason: 'the bar goes once sent');
    final sent = room.messages.lastWhere((m) => m.text == 'Says you');
    expect(sent.reply?.id, 'm2');
    expect(find.byKey(const ValueKey('space-quote-m2')), findsOneWidget, reason: 'the quote over the answer');
    await h.again(tester, 'space-reply');
    await tester.pump(const Duration(seconds: 1));
  });
}
