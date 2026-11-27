import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show MemoryFsStore;
import 'package:ghost_messaging/net/kept_files.dart';
import 'package:ghost_messaging/net/net.dart';

/// Where the ledger is kept (lib/net/kept_files.dart; the review, 2026-11-23, D6): files of its own, out of any backup,
/// and never the app's choices, which Android's backup copies. After the second review (N5): the build's own folder,
/// Android's and the Apple platforms' as they give it, and written one write after another.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the folder is one no backup takes, on each kind of device, and the build\'s own', () {
    // As the platform gives it: Android's no-backup folder (getNoBackupFilesDir), an iPhone's Caches in its container,
    // a Mac's Caches under the build's bundle id.
    expect(keptPathFor('ledger', os: 'android', base: '/data/user/0/app/no_backup'), '/data/user/0/app/no_backup/ledger');
    expect(keptPathFor('ledger', os: 'ios', base: '/var/mobile/Containers/Data/Application/A/Library/Caches'), '/var/mobile/Containers/Data/Application/A/Library/Caches/ledger');
    expect(keptPathFor('ledger', os: 'macos', base: '/Users/maya/Library/Caches/com.infamousvague.ghostmessaging.mac', env: {'HOME': '/Users/maya'}), '/Users/maya/Library/Caches/com.infamousvague.ghostmessaging.mac/ledger');
    expect(keptPathFor('ledger', os: 'windows', env: {'LOCALAPPDATA': r'C:\Users\maya\AppData\Local'}), r'C:\Users\maya\AppData\Local\Ghost Messaging\ledger');
    expect(keptPathFor('ledger', os: 'linux', env: {'HOME': '/home/maya'}), '/home/maya/.cache/ghost-messaging/ledger');
    expect(keptPathFor('ledger', os: 'linux', env: {'XDG_CACHE_HOME': '/tmp/c', 'HOME': '/home/maya'}), '/tmp/c/ghost-messaging/ledger');
    // A computer's flutter run, or a profile build, beside the release: a folder of its own. A phone runs one build.
    expect(keptPathFor('ledger', os: 'macos', base: '/Users/maya/Library/Caches/com.infamousvague.ghostmessaging.mac', mode: 'debug'), '/Users/maya/Library/Caches/com.infamousvague.ghostmessaging.mac/ledger-debug');
    expect(keptPathFor('ledger', os: 'windows', env: {'LOCALAPPDATA': r'C:\L'}, mode: 'profile'), r'C:\L\Ghost Messaging\ledger-profile');
    expect(keptPathFor('ledger', os: 'linux', env: {'HOME': '/home/maya'}, mode: 'debug'), '/home/maya/.cache/ghost-messaging/ledger-debug');
    expect([keptPathFor('ledger', os: 'android', base: '/n', mode: 'debug'), keptPathFor('ledger', os: 'ios', base: '/c', mode: 'debug')], ['/n/ledger', '/c/ledger']);
    // Nowhere the platform or the environment names: none, never a folder worked out some other way.
    expect([keptPathFor('ledger', os: 'android'), keptPathFor('ledger', os: 'macos', env: {'HOME': '/Users/maya'}), keptPathFor('ledger', os: 'windows'), keptPathFor('ledger', os: 'fuchsia', base: '/x')], [isNull, isNull, isNull, isNull]);
  });

  test('a file for each name, written whole (one cut short leaves the one before), gone when written empty', () async {
    final folder = Directory.systemTemp.createTempSync('kept');
    addTearDown(() => folder.deleteSync(recursive: true));
    final store = FilesFsStore(Directory('${folder.path}/ledger'));
    expect(await store.read('ldg'), isNull);
    await store.write('ldg', '{"d":"x"}');
    await store.write('ldg.0123', 'a book');
    await store.write('ldg.0123', 'the book again');
    expect([await store.read('ldg'), await store.read('ldg.0123')], ['{"d":"x"}', 'the book again']);
    expect(Directory('${folder.path}/ledger').listSync().map((f) => f.uri.pathSegments.last).toSet(), {'ldg', 'ldg.0123'}, reason: 'nothing half written left beside them');
    await store.write('../escape', 'x');
    expect(File('${folder.path}/escape').existsSync(), isFalse, reason: 'a name is never a path out of the folder');
    await store.write('ldg.0123', '');
    expect([await store.read('ldg.0123'), File('${folder.path}/ledger/ldg.0123').existsSync()], [null, false]);
  });

  test('writes go one after another, and a read waits for those asked before it: two at once never write the same file together (N5)', () async {
    final folder = Directory.systemTemp.createTempSync('kept');
    addTearDown(() => folder.deleteSync(recursive: true));
    final store = FilesFsStore(Directory('${folder.path}/ledger'));
    // The flush twenty seconds on and the flush as the app is put away, at once, many times over.
    final both = [for (var i = 0; i < 40; i++) store.write('ldg', 'version $i')];
    expect(await store.read('ldg'), 'version 39');
    await Future.wait(both);
    expect(Directory('${folder.path}/ledger').listSync().map((f) => f.uri.pathSegments.last).toSet(), {'ldg'});
    // Two stores on one folder (the account's own sign-out forgets with a store of its own): each write's file beside
    // its own is its own.
    final other = FilesFsStore(Directory('${folder.path}/ledger'));
    await Future.wait([store.write('ldg', 'one'), other.write('ldg', 'two'), store.write('ldg.1', 'a'), other.write('ldg.1', '')]);
    expect(await store.read('ldg'), anyOf('one', 'two'));
    expect(Directory('${folder.path}/ledger').listSync().where((f) => f.path.endsWith('.next')), isEmpty);
  });

  test('the app keeps its ledger there, in the folder the platform gives this build; under a test, in memory, so nothing is written where this computer\'s own app keeps its files', () async {
    expect(Net.defaultLedgerStore(), isA<MemoryFsStore>());
    final asked = <String>[];
    for (final channel in ['ghost_messaging/sms', 'ghost_desktop/system']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        asked.add('$channel ${call.method}');
        return call.method == 'keptDir' ? '/Users/maya/Library/Caches/com.infamousvague.ghostmessaging.mac' : null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), null));
    }
    final store = ledgerFiles();
    expect(store, isA<FilesFsStore>());
    final dir = await (store! as FilesFsStore).dir;
    if (Platform.isMacOS) {
      expect(asked, ['ghost_desktop/system keptDir']);
      // A test is no release: a flutter run's folder, beside the release's.
      expect(dir!.path, '/Users/maya/Library/Caches/com.infamousvague.ghostmessaging.mac/ledger-debug');
    } else {
      expect(dir?.path, anyOf(isNull, endsWith('ledger-debug')));
    }
    // Where the platform names no folder, nothing is read or kept.
    final none = FilesFsStore.later(Future.value(null));
    await none.write('ldg', 'x');
    expect(await none.read('ldg'), isNull);
  });
}
