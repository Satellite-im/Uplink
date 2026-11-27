import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'link/crypto.dart';

/// What a conversation's kept messages are: the messages, newest first; how many were asked of the phone to get
/// them (so a conversation asked for more than that is fetched, not answered short); and whether that was all the
/// phone had (so one asked for more is not fetched for nothing).
typedef KeptMessages = ({List<dynamic> items, int limit, bool ended});

/// The conversations and messages this computer has read from the phone, kept on its disk (Matt, 2026-11-14: "cache
/// messages on the desktop app so that we don't need to fetch them all from the phone every time, just fetching
/// updates in the background"). The app opens with them on the screen, the phone there or not, and asks the phone
/// only for what is new (lib/desktop/remote.dart).
///
/// **Sealed.** Each file is AES-256-GCM under a key made from the pairing's key (DeskCrypto.derive, "cache"), which
/// is in the Keychain and nowhere on the disk: the files are noise to anything that reads the folder without it. A
/// pairing that ends takes its key with it, and [clear] deletes the files besides.
///
/// **What is kept:** the list of conversations (`list`), and each conversation's messages as the phone last gave
/// them (`t<id>`), up to as many as were asked for. Not pictures, voice messages or videos: those are still fetched
/// from the phone as they are shown.
class DeskCache {
  DeskCache(this.dir, this._key);

  final Directory dir;

  /// The key the files are sealed with; null while no phone is paired, and then nothing is read or written.
  final Uint8List? Function() _key;

  Future<void> _last = Future.value();
  int _writes = 0;

  File _file(String name) => File('${dir.path}/$name.bin');

  /// What is kept under [name], opened and read as JSON; null where there is none, or it does not open under the
  /// key (another pairing's, or damaged).
  Future<Object?> _read(String name) async {
    final key = _key();
    if (key == null) return null;
    try {
      final file = _file(name);
      if (!await file.exists()) return null;
      final clear = DeskCrypto.openAtRest(key, await file.readAsBytes());
      return clear == null ? null : jsonDecode(utf8.decode(clear));
    } catch (_) {
      return null;
    }
  }

  /// Written whole beside the file and moved into place, one write after another.
  Future<void> _write(String name, Object value) {
    final key = _key();
    if (key == null) return Future.value();
    final sealed = DeskCrypto.sealAtRest(key, utf8.encode(jsonEncode(value)));
    return _last = _last.catchError((_) {}).then((_) async {
      try {
        await dir.create(recursive: true);
        final tmp = File('${_file(name).path}.${_writes++}.tmp');
        await tmp.writeAsBytes(sealed, flush: true);
        await tmp.rename(_file(name).path);
      } catch (_) {}
    });
  }

  /// The conversations as they were last read, newest first; null where none are kept.
  Future<List<dynamic>?> conversations() async {
    final o = await _read('list');
    return o is Map && o['items'] is List ? o['items'] as List : null;
  }

  Future<void> saveConversations(List<dynamic> items) => _write('list', {'v': 1, 'items': items});

  /// A conversation's messages as they were last read; null where none are kept.
  Future<KeptMessages?> messages(int thread) async {
    final o = await _read('t$thread');
    if (o is! Map || o['items'] is! List) return null;
    return (items: o['items'] as List, limit: (o['limit'] as num?)?.toInt() ?? (o['items'] as List).length, ended: o['ended'] == true);
  }

  /// Keeps a conversation's messages, with how many were asked for ([limit]) and whether the phone has none older
  /// ([ended]).
  Future<void> saveMessages(int thread, List<dynamic> items, int limit, {bool ended = false}) => _write('t$thread', {'v': 1, 'limit': limit, 'ended': ended, 'items': items});

  /// A conversation that is gone from the phone is gone from here.
  Future<void> forget(int thread) => _last = _last.catchError((_) {}).then((_) async {
        try {
          final file = _file('t$thread');
          if (await file.exists()) await file.delete();
        } catch (_) {}
      });

  /// Everything kept is deleted: the pairing ended, or the person asked.
  Future<void> clear() => _last = _last.catchError((_) {}).then((_) async {
        try {
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      });

  /// How much is kept, for Settings: how many conversations' messages, and how many bytes in all.
  Future<({int conversations, int bytes})> size() async {
    var count = 0, bytes = 0;
    try {
      if (await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is! File || !f.path.endsWith('.bin')) continue;
          bytes += await f.length();
          if (f.uri.pathSegments.last.startsWith('t')) count++;
        }
      }
    } catch (_) {}
    return (conversations: count, bytes: bytes);
  }

  /// Waits for what is being written: before the app closes, and in a test.
  Future<void> settled() => _last.catchError((_) {});
}
