// My files (GMFB-37, @matt: "A private file drive for each account, not tied to any space"): the drive every device of
// one Uplink account makes from the account's own key, against the relay's files service as it is, on this machine.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/files/drive.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/file_seal.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/relay.dart';

Future<void> until(bool Function() test, {String? reason, Duration most = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(most);
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('waited too long${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Uint8List bytesOf(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  // Two accounts' words, as a device has them after signing in.
  final words = AccountCrypto.newWords(), others = AccountCrypto.newWords();

  group('the drive an account\'s key makes', () {
    test('every device of the account makes the same drive from its words; another account makes another', () {
      final phone = Drive.channelOf(Me.mineKeyOf(words)), desk = Drive.channelOf(Me.mineKeyOf(List.of(words)));
      expect(desk.seed, phone.seed);
      expect(desk.owner, phone.owner);
      expect(FileSeal.filesRoom(desk.seed), FileSeal.filesRoom(phone.seed));
      expect(FileSeal.filesToken(desk.seed), FileSeal.filesToken(phone.seed));
      expect(FileSeal.filesKey(desk.seed), FileSeal.filesKey(phone.seed));
      expect(phone.kind, SpaceKind.files);
      expect(phone.name, 'My files');
      final other = Drive.channelOf(Me.mineKeyOf(others));
      expect(other.seed, isNot(phone.seed));
      expect(other.owner, isNot(phone.owner));
    });

    test('its seed is not the key it came from, and its signer is a key pair of its own made from the seed', () {
      final key = Me.mineKeyOf(words);
      final c = Drive.channelOf(key);
      expect(c.seed, hasLength(64));
      expect(c.seed, isNot(NetCrypto.hex(key)));
      final signer = Drive.signerOf(c)!;
      expect(NetCrypto.hex(signer.publicKey), c.owner);
      expect(signer.id, NetCrypto.idOf(NetCrypto.unhex(c.owner)));
      expect(Drive.signerOf(Drive.channelOf(key))!.id, signer.id);
    });

    test('a drive is known by its owner, and still is from what an upload queue keeps of it; no other space is one', () {
      final c = Drive.channelOf(Me.mineKeyOf(words));
      expect(Drive.isDrive(c), isTrue);
      final kept = VoiceChannel.fromJson({...c.toJson(), 'k': c.kind.wire})!;
      expect(Drive.isDrive(VoiceChannel(seed: kept.seed, name: kept.name, owner: kept.owner, kind: SpaceKind.files)), isTrue);
      final maya = NetKeys.generate();
      expect(Drive.isDrive(VoiceChannel(seed: NetCrypto.hex(NetCrypto.randomBytes(32)), name: 'Drop box', kind: SpaceKind.files, owner: NetCrypto.hex(maya.public))), isFalse);
      expect(Drive.isDrive(VoiceChannel(seed: c.seed, name: 'Drop box', kind: SpaceKind.files)), isFalse, reason: 'no owner');
      expect(Drive.isDrive(VoiceChannel(seed: c.seed, name: 'Lounge', kind: SpaceKind.text, owner: c.owner)), isFalse, reason: 'a chat, not files');
      expect(Drive.isDrive(VoiceChannel(seed: c.seed, name: 'Files', kind: SpaceKind.files, owner: c.owner, circle: 'c' * 64)), isFalse, reason: 'a circle\'s space');
    });
  });

  group('two devices of one account and the relay', () {
    late Directory dir;
    late Relay relay;
    late Uri base;
    // Each device with a hub key of its own (a phone, and a computer that hasn't taken on the phone's identity).
    final phoneKey = KeysSigner(NetKeys.generate()), deskKey = KeysSigner(NetKeys.generate());
    final stores = <FilesStore>[];

    FilesStore device(KeysSigner who, String name, {List<String>? said}) {
      final s = FilesStore.forTest(base: base, signer: who, data: Directory('${dir.path}/$name'), name: name, piece: 2, announce: said == null ? null : (c, w) => said.add(w));
      stores.add(s);
      return s;
    }

    File fileOf(String name, Uint8List bytes) => File('${dir.path}/in/$name')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ghost-my-files');
      relay = Relay(files: Files(dir: Directory('${dir.path}/relay')));
      base = Uri.parse('http://127.0.0.1:${await relay.start(port: 0)}/files');
    });

    tearDown(() async {
      for (final s in stores) {
        await s.clear();
      }
      stores.clear();
      await relay.stop();
      await dir.delete(recursive: true);
    });

    test('what the phone puts in the drive the computer lists, reads, renames and removes, and the relay frees its room', () async {
      final said = <String>[];
      final phone = device(phoneKey, 'Matt', said: said), desk = device(deskKey, 'Matt');
      // Each makes the drive for itself, from the account's words.
      final onPhone = Drive.channelOf(Me.mineKeyOf(words)), onDesk = Drive.channelOf(Me.mineKeyOf(List.of(words)));
      await phone.start();
      expect(phone.canUpload(onPhone), isTrue);
      final data = bytesOf(700 * 1000, 11);
      phone.upload(onPhone, [fileOf('passport.pdf', data).path], folder: 'Papers');
      await until(() => phone.transfers.isEmpty || phone.transfers.first.state == TransferState.done, reason: '${phone.transfers.firstOrNull?.error}');
      expect(said, isEmpty, reason: 'a drive has no chat to say it in');

      // The computer opens it: the same list, written by the drive's own key, not the phone's.
      await desk.open(onDesk);
      expect(desk.of(onDesk).error, isNull);
      final f = desk.of(onDesk).files.values.single;
      expect(f.name, 'passport.pdf');
      expect(f.folder, 'Papers');
      expect(f.by, Drive.signerOf(onDesk)!.id);
      expect(f.by, isNot(phoneKey.id));
      expect(await File(await desk.fetch(onDesk, f)).readAsBytes(), data);

      // The relay holds the drive as its own key's: every device of the account is its owner.
      final info = desk.of(onDesk).info!;
      expect(info.owner, onDesk.owner);
      expect(info.quota, const FilesConfig().spaceQuota, reason: 'one drive an account, so a space\'s room is the account\'s');
      expect(info.used, greaterThanOrEqualTo(FileSeal.sealedSize(data.length)));

      // The file is the phone's, and the computer may change and remove it all the same.
      expect(desk.canChange(onDesk, f), isTrue);
      expect(await desk.rename(onDesk, f, 'passport scan.pdf'), isTrue);
      await phone.of(onPhone).refresh();
      expect(phone.of(onPhone).files.values.single.name, 'passport scan.pdf');
      expect(await desk.delete(onDesk, desk.of(onDesk).files.values.single), isTrue);
      await phone.of(onPhone).refresh();
      expect(phone.of(onPhone).files, isEmpty);
      // Its blob went with it (the relay lets only a blob's writer or the owner remove it): only the list is left.
      expect(phone.of(onPhone).info!.files, 0);
      expect(phone.of(onPhone).info!.used, lessThan(8192));
      desk.close(onDesk);
    });

    test('another account\'s device finds nothing of it: its own drive is another room', () async {
      final mine = device(phoneKey, 'Matt'), theirs = device(deskKey, 'Sam');
      final drive = Drive.channelOf(Me.mineKeyOf(words)), other = Drive.channelOf(Me.mineKeyOf(others));
      await mine.start();
      mine.upload(drive, [fileOf('notes.txt', bytesOf(5000, 2)).path]);
      await until(() => mine.transfers.isEmpty || mine.transfers.first.state == TransferState.done, reason: '${mine.transfers.firstOrNull?.error}');
      await theirs.open(other);
      expect(theirs.of(other).error, isNull);
      expect(theirs.of(other).files, isEmpty);
      theirs.close(other);
    });

    test('looking at the drive keeps it from the relay\'s sweep, and says so only where the relay has it', () async {
      final phone = device(phoneKey, 'Matt');
      final drive = Drive.channelOf(Me.mineKeyOf(words));
      expect(await phone.touch(drive), isFalse, reason: 'never made: nothing to keep, and none is made by looking');
      expect(relay.files!.spaces, 0);
      await phone.open(drive);
      phone.close(drive);
      expect(await phone.touch(drive), isTrue);
      expect(relay.files!.spaces, 1);
    });
  });
}
