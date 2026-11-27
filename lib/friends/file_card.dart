/// Pictures and files to a friend (Matt, 2026-11-25: "also allow sending pictures and attachements to ghost users").
/// Words to a friend go sealed by the app's routes (lib/friends/friends.dart), a packet of about 60 KB at most, so a
/// file cannot ride in one. It goes as a file in a space's chat does (FilesStore.uploadForChat): sealed on this device
/// under a key of its own, kept on the relay, and what is sent to the friend is a card, as souls are sent
/// (lib/souls/souls_send.dart): words that say where the file is and carry its key. Being words, the card is kept
/// with the conversation, copied to one's own other devices and sent again after a lost connection exactly as any
/// message is, and an app from before this shows its first line: "📎 photo.jpg (1.2 MB)".
///
/// Where the files are kept: one space of files an account, "sent to friends", its seed made from the key the
/// account's devices share (as its drive's is, lib/files/drive.dart), so each of them finds the same one. The card
/// carries that seed, since the relay gives a file only to whoever has its space's token and the file's own id. The
/// relay lists a space's files to no one (a chat's files are in no list: relay/lib/files.dart), so a friend sent one
/// file learns nothing of the others; with the seed they could put files of their own into the space, against its
/// room. Each file is sealed under its own key, which only its own card carries.
library;

import 'dart:convert';

import '../files/file_kinds.dart';
import '../files/files_model.dart';
import '../net/crypto.dart';
import '../voice/voice.dart';

class FileCard {
  const FileCard({required this.seed, required this.files});

  /// The seed of the space the files are kept in, 64 hex digits.
  final String seed;
  final List<SpaceFile> files;

  /// The most files one card carries, and the most their small pictures may weigh together: the card must fit one
  /// packet, and a part of a conversation's history (40 KB).
  static const mostFiles = 5;
  static const thumbsMost = 18 * 1024;

  /// How much one file's small picture may weigh where [n] go together.
  static int thumbMost(int n) => (thumbsMost ~/ (n < 1 ? 1 : n)).clamp(2 * 1024, 8 * 1024);

  static const _mark = 'Ghost file: ';

  /// The seed of the space an account's files to friends are kept in, from the key its devices share.
  static String seedOf(List<int> mineKey) => NetCrypto.hex(NetCrypto.derive(mineKey, 'friend files seed'));

  /// The space of [seed], as the files' store asks for one: no owner, so whoever puts a file up signs as themselves
  /// (never a key made from the seed, which everyone sent a card could make too).
  static VoiceChannel channelOf(String seed) => VoiceChannel(seed: seed, name: 'Sent to friends', kind: SpaceKind.files);

  /// What is read in a list and by an app from before cards: "📎 photo.jpg (1.2 MB)", "📎 3 files".
  String get line => files.length == 1 ? '📎 ${files.single.name} (${fileSize(files.single.size)})' : '📎 ${files.length} files';

  /// The card as the words sent: its line, then where the files are and their keys, on one line.
  String get words => '$line\n$_mark${jsonEncode({
        's': seed,
        'a': [for (final f in files) f.toJson()..remove('u')..remove('at')],
      })}';

  static final _seed = RegExp(r'^[0-9a-f]{64}$');

  /// The card [body] is, sent by [by] at [at]; null for any other words.
  static FileCard? of(String body, {String by = '', int? at}) {
    final text = body.trim();
    if (!text.startsWith('📎 ')) return null;
    final cut = text.indexOf('\n$_mark');
    if (cut < 0 || text.indexOf('\n') != cut) return null;
    final Object? j;
    try {
      j = jsonDecode(text.substring(cut + 1 + _mark.length));
    } catch (_) {
      return null;
    }
    if (j is! Map) return null;
    final seed = j['s'], list = j['a'];
    if (seed is! String || !_seed.hasMatch(seed) || list is! List || list.isEmpty || list.length > mostFiles) return null;
    final files = <SpaceFile>[];
    for (final x in list) {
      final f = SpaceFile.fromJson(x, by: by, at: at);
      if (f == null) return null;
      files.add(f);
    }
    return FileCard(seed: seed, files: files);
  }

  /// [body] as a list shows it: a card's own line, any other words as they are.
  static String preview(String body) {
    final text = body.trimLeft();
    if (!text.startsWith('📎 ')) return body;
    final cut = text.indexOf('\n$_mark');
    return cut < 0 ? body : text.substring(0, cut);
  }
}
