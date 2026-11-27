import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/circles.dart';
import 'package:ghost_messaging/files/file_kinds.dart';
import 'package:ghost_messaging/files/files_model.dart';
import 'package:ghost_messaging/files/files_store.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/ui/circles/new_circle.dart';
import 'package:ghost_messaging/voice/voice.dart' show SpaceKind;

/// A circle's members (Matt, 2026-11-18: "I still don't see memebers i added in the members list on mobile even though
/// they are posting files"): whoever added a file is one, and everyone once seen stays one after they have gone.
void main() {
  test('someone who only added a file is a member, and is still one when the file list is not at hand', () {
    final dir = Directory.systemTemp.createTempSync('ghost-circle-people');
    addTearDown(() => dir.deleteSync(recursive: true));
    final me = KeysSigner(NetKeys.generate());
    final had = FilesStore.instance;
    FilesStore.instance = FilesStore.forTest(base: null, signer: me, data: dir);
    addTearDown(() => FilesStore.instance = had);
    final c = Circle(
      seed: 'c' * 64,
      owner: '',
      manifest: CircleManifest(owner: '', version: 1, name: 'Night Owls', spaces: [CircleSpace(seed: 'd' * 64, name: 'Drop', kind: SpaceKind.files)]),
    );
    final drop = c.channels.single;
    FilesStore.instance.put(drop, [
      SpaceFile(id: '1' * 32, name: 'cat.heic', size: 10, mime: FileKind.mimeOf('cat.heic'), sha: '', key: Uint8List(32), prefix: Uint8List(8), by: 'kevin1', byName: 'Kevin', at: 1),
    ]);
    expect(circlePeople(c).map((p) => p.name), contains('Kevin'));
    // The list of files gone from this device (another start of the app, before it is read): Kevin is still a member.
    FilesStore.instance = FilesStore.forTest(base: null, signer: me, data: Directory('${dir.path}/other'));
    expect(circlePeople(c).map((p) => p.name), contains('Kevin'));
  });
}
