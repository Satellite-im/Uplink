// My files on the screen (GMFB-37, @matt: "A private file drive for each account, not tied to any space"): its row
// under the search for an account signed in to, the drive shown by the Files space's own page with no chat, invite or
// roles, what is said where there is no account to make it from, and a file of it sent into a space's chat.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/files/drive.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/friends/file_card.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/ui/files_space/files_screen.dart';
import 'package:ghost_messaging/ui/files_space/my_files.dart';
import 'package:ghost_messaging/ui/files_space/send_to_chat.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/voice/voice.dart';

import 'support/list_harness.dart';

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final drive = Drive.channelOf(Me.mineKeyOf(AccountCrypto.newWords()));

  group('the drive\'s page', () {
    late Directory dir;
    late FilesStore store;
    SpaceFile file(int n, String name, int size) =>
        SpaceFile(id: n.toRadixString(16).padLeft(32, '0'), name: name, size: size, mime: FileKind.mimeOf(name), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: Drive.signerOf(drive)!.id, byName: 'Matt', at: n);

    setUp(() {
      ListPhone([]).install();
      dir = Directory.systemTemp.createTempSync('ghost-my-files-screen');
      // The device's own hub key is not the drive's: what it may do there is the drive's key's to say.
      store = FilesStore.forTest(base: null, signer: KeysSigner(NetKeys.generate()), data: dir);
    });
    tearDown(() async {
      await store.clear();
      dir.deleteSync(recursive: true);
    });

    testWidgets('shows the account\'s files under My files, with room used, and no chat, invite or roles', (tester) async {
      store.put(drive, [file(1, 'passport.pdf', 900), file(2, 'lease.pdf', 300)], info: const FilesInfo(used: 1200, quota: 1 << 30));
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, MyFilesScreen(drive: () async => drive, store: store), AppState());
      expect(find.text('My files'), findsWidgets);
      expect([for (final e in find.byType(FileRow).evaluate()) (e.widget as FileRow).file.name], ['lease.pdf', 'passport.pdf']);
      expect(_key('files-quota'), findsOneWidget);
      expect(_key('files-upload'), findsOneWidget);
      expect(_key('files-chat'), findsNothing);
      expect(find.bySemanticsLabel('Invite people'), findsNothing);
      expect(find.bySemanticsLabel('Space settings'), findsNothing);
      // A file's menu: it may be changed from any device of the account, and sent into a chat.
      await tester.longPress(_key('file-${file(1, '', 0).id}'));
      await settle(tester);
      expect(find.text('Send to a chat'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await settle(tester);
      expect(find.textContaining('It goes from every device of your account.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty drive says whose devices see what is put in it', (tester) async {
      store.put(drive, const []);
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, MyFilesScreen(drive: () async => drive, store: store), AppState());
      expect(find.text('No files yet'), findsWidgets);
      expect(find.textContaining('every device signed in to your account'), findsOneWidget);
      expect(find.textContaining('Everyone in the space'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a device with no account to make it from says so, and shows no files page', (tester) async {
      final sheet = await loadSheet(tester);
      await pumpScreen(tester, sheet, MyFilesScreen(drive: () async => null, store: store), AppState());
      expect(_key('my-files-says'), findsOneWidget);
      expect(find.textContaining('Sign in to your account on this device'), findsOneWidget);
      expect(find.byType(FilesSpaceScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('the row under the search', () {
    setUp(() => ListPhone([ListPhone.conversation(1, '+15551230001', 'See you at eight', name: 'Maya Lindqvist')]).install());

    Account account({String address = ''}) => Account(relay: HubAccountRelay(), port: SmsAccountPort(), store: MemoryMeStore()..kept['acct_address'] = address, profiles: AppAccountProfiles());

    for (final (size, at) in [('phone', const Size(412, 892)), ('wide', const Size(1000, 760))]) {
      testWidgets('on a $size: there with an account signed in to, and it opens My files; not there without one', (tester) async {
        final was = Account.instance;
        addTearDown(() => Account.instance = was);
        Account.instance = account();
        final sheet = await loadSheet(tester);
        await pumpScreen(tester, sheet, const AppShell(), AppState(), size: at);
        await settle(tester);
        expect(_key('quick-mark-read'), findsOneWidget);
        expect(_key('my-files'), findsNothing);

        Account.instance = account(address: '0x52908400098527886E0F7030069857D2E4169EE7');
        await pumpScreen(tester, sheet, const AppShell(key: ValueKey('again')), AppState(), size: at);
        await settle(tester);
        expect(_key('my-files'), findsOneWidget);
        expect(tester.getTopLeft(_key('my-files')).dy, greaterThan(tester.getTopLeft(_key('quick-mark-read')).dy));
        await tester.tap(_key('my-files'));
        await settle(tester);
        // This test's device keeps no recovery words, so the page says why there is no drive here.
        expect(find.byType(MyFilesScreen), findsOneWidget);
        expect(_key('my-files-says'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('a file sent into a space\'s chat', () {
    test('only spaces with a chat are offered, this device\'s own before a circle\'s', () {
      const lounge = VoiceChannel(seed: '1111111111111111111111111111111111111111111111111111111111111111', name: 'Lounge', kind: SpaceKind.text);
      const box = VoiceChannel(seed: '2222222222222222222222222222222222222222222222222222222222222222', name: 'Drop box', kind: SpaceKind.files);
      final call = VoiceChannel.ofGroup('g1', 'Family');
      expect([for (final c in chatsForFiles(from: [call, lounge, box])) c.name], ['Lounge', 'Drop box']);
    });

    test('it goes up through the space\'s own storage and the message is sent; one that stops says where it waits', () async {
      final room = _room();
      final up = _Uploads();
      final f = File('${Directory.systemTemp.createTempSync('ghost-send').path}/passport.pdf')..writeAsBytesSync(List.filled(4000, 7));
      addTearDown(() => f.parent.deleteSync(recursive: true));
      expect(await sendPathToRoom(room, f.path, up), isNull);
      expect(up.asked, 1);
      expect(up.into, room.channel.seed, reason: 'sealed again under the space it goes to, not the drive');
      expect(room.outgoing, isEmpty);
      expect(room.messages.last.files.single.name, 'passport.pdf');

      up.failing = true;
      final why = await sendPathToRoom(room, f.path, up);
      expect(why, contains('Can\'t reach the files server.'));
      expect(why, contains('It waits in Lounge\'s chat, with Try again.'));
      expect(room.outgoing, hasLength(1));
    });
  });

  // GMFB-37, "Send a file from the drive into any chat": a friend's chat carries files too.
  group('a file sent to a friend', () {
    Buddy friend(String username, {String name = '', String state = 'yes', int at = 0}) => Buddy(username: username, id: 'id-$username-$at', key: '', name: name, state: state, at: at);

    test('friends on this relay are offered, one of each, by the name shown; none where the phone does the sending', () {
      final all = [friend('zed'), friend('maya', name: 'Maya'), friend('away'), friend('asked', state: 'asked'), friend('maya', name: 'Maya', at: 5)];
      bool elsewhere(Buddy b) => b.username == 'away';
      expect([for (final b in friendsForFiles(from: all, elsewhere: elsewhere, ownNetwork: true)) b.shown], ['Maya', 'zed']);
      expect(friendsForFiles(from: all, elsewhere: elsewhere, ownNetwork: false), isEmpty);
    });

    test('it goes up into the account\'s "sent to friends" space and the friend is sent its card; a stop says why', () async {
      final up = _Uploads();
      final f = File('${Directory.systemTemp.createTempSync('ghost-send-friend').path}/lease.pdf')..writeAsBytesSync(List.filled(3000, 7));
      addTearDown(() => f.parent.deleteSync(recursive: true));
      final mineKey = Me.mineKeyOf(AccountCrypto.newWords());
      final sent = <(String, String)>[];
      var taken = true;
      Future<String?> go() => sendPathToFriend(friend('maya'), f.path, up, byName: 'matt', mineKey: () async => mineKey, send: (to, words) async {
            if (taken) sent.add((to, words));
            return taken;
          }, refusal: () => null);

      expect(await go(), isNull);
      expect(up.into, FileCard.seedOf(mineKey), reason: 'sealed again for the friend, never the drive\'s own seed');
      expect(up.into, isNot(drive.seed));
      expect(sent.single.$1, '@maya');
      final card = FileCard.of(sent.single.$2)!;
      expect(card.seed, FileCard.seedOf(mineKey));
      expect(card.files.single.name, 'lease.pdf');
      expect(card.files.single.size, 3000);
      expect(card.line, startsWith('📎 lease.pdf'));

      taken = false;
      expect(await go(), contains('No connection'));
      up.failing = true;
      expect(await go(), 'Can\'t reach the files server.');
      expect(await sendPathToFriend(friend('maya'), f.path, up, mineKey: () async => null, send: (_, _) async => true, byName: 'matt'), contains('need an Uplink account'));
      expect(sent, hasLength(1));
    });
  });
}

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
  String? into;

  @override
  Future<SpaceFile> uploadForChat(VoiceChannel c, OutgoingFile f, {required String byName, required int thumbMost, required void Function() moved}) async {
    asked++;
    into = c.seed;
    if (failing) throw FilesError(0, 'Can\'t reach the files server.');
    return SpaceFile(id: NetCrypto.hex(NetCrypto.randomBytes(16)), name: f.name, size: f.size, mime: f.mime, sha: '', key: NetCrypto.randomBytes(32), prefix: NetCrypto.randomBytes(8), by: 'me', byName: byName, at: 0);
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
