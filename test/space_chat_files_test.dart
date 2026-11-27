import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/files_api.dart' show FilesError;
import 'package:ghost_messaging/files/file_kinds.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/ui/common.dart' show IconTap;
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

/// A space's chat with files, stickers and voice messages (Matt, 2026-11-18: "I also want full support for uploading
/// attachements gifs stickers etc like we support in other chats"): the composer's buttons for someone who may write,
/// and what a message with files, a sticker or a voice message, and one on its way, look like.
void main() {
  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async => call.method == 'prefs' ? <String, String>{} : null);
  });

  IconTap button(WidgetTester tester, String key) => tester.widget<IconTap>(find.byKey(ValueKey(key)));

  testWidgets('a member who may write has Add an attachment, Stickers and the microphone; a role without writing has none', (tester) async {
    final sheet = await loadSheet(tester);
    final room = _room();
    await pumpScreen(tester, sheet, HangoutChat(room: room, uploads: _Uploads()), AppState());
    expect(button(tester, 'composer-plus').onPressed, isNotNull);
    expect(button(tester, 'composer-stickers').onPressed, isNotNull);
    expect(button(tester, 'composer-mic').onPressed, isNotNull, reason: 'the phone itself records voice messages');

    room.roster = room.roster.next(roles: [for (final r in room.roster.ranked) r.id == Role.member ? r.copyWith(perms: {...r.perms}..remove(Perm.chat)) : r]);
    room.updateChannel(room.channel);
    await settle(tester);
    expect(find.byKey(const ValueKey('composer-plus')), findsNothing);
    expect(find.text('Your role can\'t send messages here.'), findsOneWidget);
  });

  testWidgets('a picture pressed opens full screen over the chat; Escape or the cross takes it away', (tester) async {
    // Matt, 2026-11-19: "when clicking a picture in a chat, like in a circle make it a full screen overlay".
    final sheet = await loadSheet(tester);
    final room = _room();
    room.store.keepMessages(room.channel.chatRoom, [
      HangoutMessage(id: 'p', from: 'maya', name: 'Maya', text: '', at: DateTime(2026, 11, 19).millisecondsSinceEpoch, files: [_file('beach.jpg', 9000000)]),
    ]);
    final fresh = HangoutRoom(channel: room.channel, route: room.route, name: 'Me', signer: room.signer, store: room.store);
    await pumpScreen(tester, sheet, HangoutChat(room: fresh, uploads: _Uploads()), AppState());
    final picture = find.bySemanticsLabel(RegExp(r'^Picture beach\.jpg'));
    expect(picture, findsOneWidget);
    await tester.tap(picture);
    await settle(tester);
    expect(find.byKey(const ValueKey('picture-overlay')), findsOneWidget);
    expect(find.text('beach.jpg'), findsOneWidget, reason: 'its name over it');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey('picture-overlay')), findsNothing);
    await tester.tap(picture);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('picture-overlay-close')));
    await settle(tester);
    expect(find.byKey(const ValueKey('picture-overlay')), findsNothing);
  });

  testWidgets('a file, a voice message and a sticker are drawn in place of words; one on its way shows why it stopped, and Try again', (tester) async {
    final sheet = await loadSheet(tester);
    final room = _room();
    final up = _Uploads()..failing = true;
    final at = DateTime(2026, 11, 18, 10).millisecondsSinceEpoch;
    room.store.keepMessages(room.channel.chatRoom, [
      HangoutMessage(id: 'f', from: 'maya', name: 'Maya', text: 'The agenda', at: at, files: [_file('agenda.pdf', 120000)]),
      HangoutMessage(id: 'v', from: 'maya', name: 'Maya', text: '', at: at + 1000, files: [_file('voice.m4a', 30000)], voice: true),
      HangoutMessage(id: 's', from: 'maya', name: 'Maya', text: '', at: at + 2000, sticker: 'nopack-01'),
    ]);
    final fresh = HangoutRoom(channel: room.channel, route: room.route, name: 'Me', signer: room.signer, store: room.store);
    await pumpScreen(tester, sheet, HangoutChat(room: fresh, uploads: up), AppState());
    expect(find.text('agenda.pdf'), findsOneWidget);
    expect(find.text('The agenda'), findsOneWidget);
    expect(find.text('Voice message'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await settle(tester);
    expect(find.text('Sticker'), findsOneWidget, reason: 'a sticker this app doesn\'t carry says so');

    fresh.outgoing.add(OutgoingMessage(id: 'o', text: 'Here', at: at + 3000, files: [OutgoingFile(path: '/nowhere/plan.pdf', name: 'plan.pdf', size: 10, mime: 'application/pdf')..error = 'Can\'t reach the files server.']));
    fresh.updateChannel(fresh.channel);
    await settle(tester);
    expect(find.textContaining('Not sent: Can\'t reach the files server.'), findsOneWidget);
    up.failing = false;
    await tester.tap(find.byKey(const ValueKey('space-outgoing-retry')));
    await settle(tester);
    expect(up.asked, 1);
    expect(fresh.outgoing, isEmpty);
    expect(fresh.messages.last.files.single.name, 'plan.pdf');
    expect(fresh.messages.last.text, 'Here');
  });

  // GMFB-60 (Matt, Android, 0.12.25): ".heic files don't render an image preview". A HEIC was a file's chip on every
  // device; it is a picture where the device reads one (an Android phone, an iPhone, a Mac) and still a chip elsewhere.
  for (final reads in [true, false]) {
    testWidgets('a HEIC in a chat is ${reads ? 'a picture where the device reads one' : 'a file\'s chip where it reads none'}', (tester) async {
      final had = readsHeic;
      readsHeic = () => reads;
      addTearDown(() => readsHeic = had);
      final sheet = await loadSheet(tester);
      final room = _room();
      room.store.keepMessages(room.channel.chatRoom, [
        HangoutMessage(id: 'h', from: 'maya', name: 'Maya', text: '', at: DateTime(2026, 11, 25).millisecondsSinceEpoch, files: [_file('IMG_0042.HEIC', 9000000)]),
      ]);
      final fresh = HangoutRoom(channel: room.channel, route: room.route, name: 'Me', signer: room.signer, store: room.store);
      await pumpScreen(tester, sheet, HangoutChat(room: fresh, uploads: _Uploads()), AppState());
      expect(find.bySemanticsLabel(RegExp(r'^Picture IMG_0042\.HEIC')), reads ? findsOneWidget : findsNothing);
      expect(find.text('IMG_0042.HEIC'), reads ? findsNothing : findsOneWidget, reason: 'the chip names the file');
    });
  }
}

SpaceFile _file(String name, int size) => SpaceFile(id: NetCrypto.hex(NetCrypto.randomBytes(16)), name: name, size: size, mime: '', sha: '', key: NetCrypto.randomBytes(32), prefix: NetCrypto.randomBytes(8), by: 'maya', byName: 'Maya', at: 0);

/// A space someone else owns, this device a member in it.
HangoutRoom _room() {
  final keys = NetKeys.generate(), owner = NetKeys.generate();
  final channel = VoiceChannel.make('Lounge', owner: NetCrypto.hex(owner.public));
  final store = MemoryHangoutStore();
  store.keepRoster(channel.chatRoom, Roster.first(channel.owner));
  return HangoutRoom(channel: channel, route: _NoRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
}

class _Uploads implements ChatUploads {
  bool failing = false;
  int asked = 0;

  @override
  Future<SpaceFile> uploadForChat(VoiceChannel c, OutgoingFile f, {required String byName, required int thumbMost, required void Function() moved}) async {
    asked++;
    if (failing) throw FilesError(0, 'Can\'t reach the files server.');
    return _file(f.name, f.size);
  }

  @override
  void drop(OutgoingFile f) {}
}

class _NoRoute implements VoiceRoute {
  _NoRoute(this.me);
  @override
  final String me;
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
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
