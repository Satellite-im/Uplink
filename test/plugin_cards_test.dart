import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/plugins/plugin.dart';
import 'package:ghost_messaging/plugins/record_call.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/plugin_note_card.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/space_call_harness.dart';

/// Plugins' notes in a space's chat drawn as cards (Matt, 2026-11-19: "use icons for starting and stopping recording and
/// allow plugins to render messages like these as cards with iconography and details").
const _maya = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _Route implements VoiceRoute {
  _Route(this.me, this.key);
  @override
  final String me;
  final List<int> key;
  final said = <Map<String, dynamic>>[];
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {
    final clear = NetCrypto.open(key, bytes);
    if (clear != null) said.add((jsonDecode(utf8.decode(clear)) as Map).cast<String, dynamic>());
  }

  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

({HangoutRoom room, _Route route}) _room({bool circle = true, List<HangoutMessage> Function(String me)? messages}) {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'general', owner: NetCrypto.hex(owner.public), kind: SpaceKind.voice, circle: circle ? 'c' * 64 : null);
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  store.keepMessages(channel.chatRoom, messages?.call(keys.id) ?? const []);
  final route = _Route(keys.id, channel.key);
  return (room: HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store), route: route);
}

List<HangoutMessage> _recording(String me) {
  final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
  return [
    HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: 'Ready when you are', at: at),
    HangoutMessage(id: '2', from: _maya, name: 'Maya Chen', text: '🔴 Maya Chen started recording this call.', at: at + 60000, note: const PluginChatNote('recordcall', 'started', {'by': 'Maya Chen'})),
    HangoutMessage(
      id: '3',
      from: _maya,
      name: 'Maya Chen',
      text: '⏹ Maya Chen stopped recording.',
      at: at + 900000,
      note: const PluginChatNote('recordcall', 'stopped', {'by': 'Maya Chen', 'seconds': '754', 'voices': '3', 'savedTo': 'Saving to Shared › Recordings'}),
    ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('a note travels with its words, which a build from before reads alone; only as much as a card holds', () {
    const note = PluginChatNote('recordcall', 'stopped', {'by': 'Maya', 'seconds': '60'});
    final m = HangoutMessage(id: 'x', from: _maya, name: 'Maya', text: '⏹ Maya stopped recording.', at: 1, note: note);
    final j = m.toJson();
    expect(j['x'], '⏹ Maya stopped recording.', reason: 'what a build from before shows');
    expect(HangoutMessage.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>, _maya)!.note, note);
    expect(PluginChatNote.fromJson({'p': 'Record Call', 'k': 'x'}), isNull, reason: 'a plugin\'s id is lower case');
    final big = PluginChatNote.fromJson({'p': 'a', 'k': 'b', 'd': {for (var i = 0; i < 20; i++) 'k$i': 'v' * 500}})!;
    expect(big.details.length, PluginChatNote.mostDetails);
    expect(big.details.values.first.length, PluginChatNote.detailMost);
  });

  test('sent with words, a note goes out with them', () async {
    final (:room, :route) = _room();
    await room.open();
    expect(room.sendWith(text: '🔴 Me started recording', note: const PluginChatNote('recordcall', 'started', {'by': 'Me'})), isTrue);
    expect(route.said.last['pn'], {'p': 'recordcall', 'k': 'started', 'd': {'by': 'Me'}});
    expect(room.messages.last.note?.kind, 'started');
  });

  test('Record call\'s cards: started on red; stopped with how long, how many voices and where', () {
    const plugin = RecordCallPlugin();
    final started = plugin.card(const PluginChatNote('recordcall', 'started', {'by': 'Maya'}), mine: false)!;
    expect((started.title, started.alert, started.icon), ('Maya started recording', true, Lucide.circleDot));
    expect(plugin.card(const PluginChatNote('recordcall', 'started', {'by': 'Me'}), mine: true)!.title, 'You started recording');
    final stopped = plugin.card(const PluginChatNote('recordcall', 'stopped', {'by': 'Maya', 'seconds': '3900', 'voices': '2', 'savedTo': 'Saving to Shared › Recordings'}), mine: false)!;
    expect((stopped.title, stopped.detail, stopped.icon), ('Maya stopped recording', 'Saving to Shared › Recordings', Lucide.circleStop));
    expect([for (final f in stopped.facts) f.$2], ['1 h 5 min', '2 voices', 'MP4, a track each']);
    expect(plugin.card(const PluginChatNote('recordcall', 'nonsense'), mine: false), isNull, reason: 'an unknown kind shows its words');
    final m = HangoutMessage(id: 'x', from: _maya, name: 'M', text: 'hi', at: 1, note: const PluginChatNote('nobody', 'thing'));
    expect(pluginCardOf(m, mine: false), isNull, reason: 'no plugin here draws it');
  });

  for (final circle in [true, false]) {
    testWidgets('drawn as cards in the chat (${circle ? 'a circle\'s channel' : 'bubbles'})', (tester) async {
      final h = await SpaceHarness.load(tester);
      final (:room, route: _) = _room(circle: circle, messages: _recording);
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'plugin-cards-${circle ? 'circle' : 'bubbles'}');
      expect(find.byKey(const ValueKey('plugin-card-recordcall')), findsNWidgets(2));
      expect(find.text('Maya Chen started recording'), findsOneWidget);
      expect(find.text('13 min'), findsOneWidget);
      expect(find.text('3 voices'), findsOneWidget);
      expect(find.textContaining('🔴'), findsNothing, reason: 'the words are under the card, not beside it');
      await tester.pump(const Duration(seconds: 1));
    });
  }
  // GMFB-43: "use the icons ... for starting and stopping recording in the messages sent to chat instead of emoji".
  test('Record call\'s line is known by its words, and no other is', () {
    final started = PluginChatNote.recordingLine('🔴 Maya started recording this call. Only the voices of people who say yes are in it.')!;
    expect(started.started, isTrue);
    expect(started.words, startsWith('Maya started recording this call.'));
    expect(PluginChatNote.recordingLine('⏹ Maya stopped recording.'), (started: false, words: 'Maya stopped recording.'));
    expect(PluginChatNote.recordingLine('⏹️ Maya stopped recording.')!.words, 'Maya stopped recording.');
    expect(PluginChatNote.recordingLine('🔴 the light is red'), isNull);
    expect(PluginChatNote.recordingLine('Maya started recording'), isNull);
    expect(recordingWordsOf('🔴 M started recording this call.')!.icon, Lucide.circleDot);
    expect(recordingWordsOf('⏹ M stopped recording.')!.icon, Lucide.circleStop);
    const m = HangoutMessage(id: 'p', from: _maya, name: 'M', text: '🔴 M started recording this call.', at: 1);
    expect(m.summary, 'M started recording this call.', reason: 'a list\'s preview has no emoji');
    expect(m.toJson()['x'], '🔴 M started recording this call.', reason: 'what travels is unchanged: a build from before shows the emoji');
  });

  test('a shipped plugin draws its card where the registry has none (the browser\'s page)', () {
    final had = PluginRegistry.instance;
    PluginRegistry.instance = PluginRegistry(const []);
    addTearDown(() => PluginRegistry.instance = had);
    const m = HangoutMessage(id: 'x', from: _maya, name: 'M', text: '🔴 M started recording this call.', at: 1, note: PluginChatNote('recordcall', 'started', {'by': 'M'}));
    expect(pluginCardOf(m, mine: false)?.card.icon, Lucide.circleDot);
  });

  for (final circle in [true, false]) {
    testWidgets('icons, not emoji, where the words are shown: a quote, and a line with no note (${circle ? 'a circle\'s channel' : 'bubbles'})', (tester) async {
      final h = await SpaceHarness.load(tester);
      final at = DateTime(2026, 11, 19, 9).millisecondsSinceEpoch;
      final (:room, route: _) = _room(
        circle: circle,
        messages: (me) => [
          // From a build before the notes: the words alone.
          HangoutMessage(id: '1', from: _maya, name: 'Maya Chen', text: '🔴 Maya Chen started recording this call.', at: at),
          HangoutMessage(id: '2', from: _maya, name: 'Maya Chen', text: '⏹ Maya Chen stopped recording.', at: at + 60000),
          HangoutMessage(id: '3', from: _maya, name: 'Maya Chen', text: 'Got it all', at: at + 120000, reply: const SpaceReply(id: '2', from: _maya, name: 'Maya Chen', text: '⏹ Maya Chen stopped recording.')),
        ],
      );
      await room.open();
      await h.shoot(tester, GhostPage(title: '# general', body: HangoutChat(room: room)), 'recording-words-${circle ? 'circle' : 'bubbles'}');
      expect(find.textContaining('🔴', findRichText: true), findsNothing);
      expect(find.textContaining('⏹', findRichText: true), findsNothing);
      expect(find.byKey(const ValueKey('note-icon-started')), findsOneWidget);
      expect(find.byKey(const ValueKey('note-icon-stopped')), findsNWidgets(2), reason: 'the line and its quote');
      expect(find.textContaining('Maya Chen stopped recording.', findRichText: true), findsNWidgets(2));
      await tester.pump(const Duration(seconds: 1));
    });
  }
}
