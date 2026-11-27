import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../net/crypto.dart';
import 'file_kinds.dart';

/// One file in a Files space, as its description says (sealed in the space's log with the space's files key): what it
/// is called, how big, its type and the plain file's SHA-256, the key it is sealed with and the relay's name for its
/// blob, who added it and when, the folder it is in, and a small picture of it where it is a picture.
@immutable
class SpaceFile {
  const SpaceFile({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.sha,
    required this.key,
    required this.prefix,
    required this.by,
    required this.byName,
    required this.at,
    this.chunk = 256 * 1024,
    this.folder,
    this.thumb,
    this.width = 0,
    this.height = 0,
    this.verified = false,
  });

  /// Whether who added it is known from their own signature on the entry ([OpTrust.signed]), not only the relay's
  /// word: false for a file 0.9.2 added (Matt, 2026-11-17: "Finish the missing pieces that went unfinished").
  final bool verified;

  /// The blob's id on the relay (32 hex digits): also what each sealed chunk is bound to.
  final String id;
  final String name;

  /// The plain file's size in bytes.
  final int size;
  final String mime;

  /// The plain file's SHA-256 in hex: a download is checked against it.
  final String sha;

  /// The file's own key (32 bytes) and its chunks' nonce prefix (8 bytes).
  final Uint8List key;
  final Uint8List prefix;

  /// How many plain bytes each sealed chunk holds: a power of two from 4 KB to 4 MB, 256 KB unless the entry says.
  final int chunk;

  /// Who added it: their hub id (as the relay signed it, not as they said), and the name they gave.
  final String by;
  final String byName;

  /// When it was added, ms since 1970.
  final int at;

  /// The folder it is in, as its path from the space's top ("Trip/Day 2"); null for the top itself. A file from before
  /// folders nested (one level, a name with no slashes) is in a folder whose path is that one name.
  final String? folder;

  /// A small PNG of it, for a picture; null for anything else.
  final Uint8List? thumb;

  /// The picture's own size in pixels, where whoever added it knew; 0 where not.
  final int width, height;

  FileKind get kind => FileKind.of(name, mime);
  DateTime get when => DateTime.fromMillisecondsSinceEpoch(at);

  /// The same file under another name or in another folder ([clearFolder]: at the top).
  SpaceFile copyWith({String? name, String? folder, bool clearFolder = false}) => SpaceFile(
        id: id,
        name: name ?? this.name,
        size: size,
        mime: mime,
        sha: sha,
        key: key,
        prefix: prefix,
        by: by,
        byName: byName,
        at: at,
        chunk: chunk,
        folder: clearFolder ? null : (folder ?? this.folder),
        thumb: thumb,
        width: width,
        height: height,
        verified: verified,
      );

  /// The same file with no small picture: a message in a space's chat that would not go in one packet with it
  /// (HangoutRoom.fitted).
  SpaceFile withoutThumb() => SpaceFile(id: id, name: name, size: size, mime: mime, sha: sha, key: key, prefix: prefix, by: by, byName: byName, at: at, chunk: chunk, folder: folder, width: width, height: height, verified: verified);

  /// What the log's `add` carries (the [by] is the relay's, so it is not in here).
  Map<String, Object?> toJson() => {
        'id': id,
        'n': name,
        'z': size,
        'm': mime,
        'h': sha,
        'k': base64Encode(key),
        'p': base64Encode(prefix),
        if (chunk != 256 * 1024) 'c': chunk,
        'u': byName,
        'at': at,
        if (folder != null) 'd': folder,
        if (thumb != null) 'th': base64Encode(thumb!),
        if (width > 0) 'w': width,
        if (height > 0) 'ht': height,
      };

  /// The file a log's `add` describes, added by [by] (the relay's word) and at [at] where it doesn't say; null where
  /// anything in it doesn't hold.
  static SpaceFile? fromJson(Object? j, {required String by, int? at, bool verified = false}) {
    if (j is! Map) return null;
    try {
      final id = j['id'] as String;
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) return null;
      final key = base64Decode(j['k'] as String);
      final prefix = base64Decode(j['p'] as String);
      if (key.length != 32 || prefix.length != 8) return null;
      final name = cleanName(j['n'] as String);
      if (name.isEmpty) return null;
      // What any member writes is checked before it is believed: a chunk size of 0, a negative one or one of gigabytes
      // (which would have the whole file held in memory before anything opens), a size past what the relay keeps, a
      // picture claiming to be 30000 px across. One that fails is no file.
      final size = (j['z'] as num).toInt();
      final chunk = (j['c'] as num?)?.toInt() ?? 256 * 1024;
      if (size < 0 || size > maxSize) return null;
      if (chunk < 4096 || chunk > 4 << 20 || chunk & (chunk - 1) != 0) return null;
      final sha = j['h'] is String ? j['h'] as String : '';
      if (sha.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) return null;
      final w = (j['w'] as num?)?.toInt() ?? 0, h = (j['ht'] as num?)?.toInt() ?? 0;
      final thumb = j['th'] is String ? base64Decode(j['th'] as String) : null;
      return SpaceFile(
        id: id,
        name: name,
        size: size,
        mime: j['m'] is String ? j['m'] as String : FileKind.mimeOf(name),
        sha: sha,
        key: key,
        prefix: prefix,
        chunk: chunk,
        by: by,
        byName: j['u'] is String ? j['u'] as String : '',
        at: (j['at'] as num?)?.toInt() ?? at ?? 0,
        folder: cleanFolder(j['d']),
        // A small picture only: one bigger than a thumbnail is is left out (the file still lists, with its mark).
        thumb: thumb != null && thumb.length <= maxThumb ? thumb : null,
        width: w >= 0 && w <= 16384 ? w : 0,
        height: h >= 0 && h <= 16384 ? h : 0,
        verified: verified,
      );
    } catch (_) {
      return null;
    }
  }

  /// The largest file a space's list believes, and the largest small picture. Above the relay's own limit (50 GB a
  /// file since 2026-11-17, relay/lib/files.dart `FilesConfig.maxFile`) with room to grow: at 4 GiB, left from when
  /// the relay kept about 2 GB, a 26 GB film went up whole and was listed, and every device then passed over its entry
  /// (Matt, 2026-11-21: "it shows that I uploaded the odyssey but I don't see the file in the movies folder").
  /// 2^40 (a tebibyte), written out: `1 << 40` is 0 in a browser, where a shift keeps 32 bits, and every file would be
  /// over it (test/source_guards_test.dart).
  static const maxSize = 0x10000000000;
  static const maxThumb = 18 * 1024;

  /// A name as a file may have it, on every system it may be saved to: no slashes, no characters Windows refuses
  /// (`: < > " | ? *`), no control characters and no invisible ones (direction marks that make "invoice\u202Efdp.exe"
  /// show as "invoiceexe.pdf", zero-width spaces), no trailing dots or spaces, not a name of only dots (which would
  /// be the folder itself or the one above it), not one of Windows' device names (CON, NUL, COM1...); at most 200
  /// characters. A name with nothing left is "file".
  static String cleanName(String name) {
    var n = name.replaceAll(RegExp(r'[\p{Cc}\p{Cf}]', unicode: true), '').replaceAll(RegExp(r'[/\\:<>"|?*]'), '_').trim();
    n = n.replaceAll(RegExp(r'[. ]+$'), '');
    if (n.isEmpty || RegExp(r'^\.+$').hasMatch(n)) return 'file';
    final base = (n.contains('.') ? n.substring(0, n.indexOf('.')) : n).toUpperCase();
    if (RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$').hasMatch(base)) n = '_$n';
    return n.length > 200 ? n.substring(0, 200) : n;
  }

  /// A folder's path, or null for the space's top: its names from the top down joined with slashes ("Trip/Day 2"),
  /// each one cleaned as a file's name is ([cleanName]) and cut to 80 characters, with no empty names and none of only
  /// dots (no "..", which would climb out of the space), and at most [maxDepth] of them (Matt, 2026-11-18: "allow root
  /// level folders in the file sharing tab and nested folders"). A one-level name from before is a path of one name,
  /// as it was; 0.9.6 and older, which took the slashes out ("Trip_Day 2"), list a nested folder's files in a folder
  /// of that name.
  static String? cleanFolder(Object? folder) {
    if (folder is! String) return null;
    final names = [
      for (final part in folder.split('/'))
        if (part.trim().isNotEmpty && !RegExp(r'^[. ]+$').hasMatch(part.trim())) cleanName(part),
    ];
    if (names.isEmpty) return null;
    return [for (final n in names.take(maxDepth)) n.length > 80 ? n.substring(0, 80) : n].join('/');
  }

  /// How deep folders go.
  static const maxDepth = 8;

  /// [path]'s names from the top down; none for the top.
  static List<String> folderNames(String? path) => path == null || path.isEmpty ? const [] : path.split('/');

  /// The folder [path] is in; null for one at the top.
  static String? folderParent(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? null : path.substring(0, i);
  }

  /// [path]'s own name, its last.
  static String folderName(String path) => path.substring(path.lastIndexOf('/') + 1);

  /// [path] with every folder it is in, from the top down: "a/b/c" is "a", "a/b" and "a/b/c".
  static List<String> folderLine(String path) {
    final names = folderNames(path);
    return [for (var i = 1; i <= names.length; i++) names.take(i).join('/')];
  }

  /// Whether [folder] is [path] or anywhere inside it.
  static bool inFolder(String? folder, String path) => folder != null && (folder == path || folder.startsWith('$path/'));

  /// The folder [name] (which may be a path itself) in [parent] (null for the top), cleaned.
  static String? joinFolder(String? parent, String name) => cleanFolder(parent == null ? name : '$parent/$name');
}

/// How far an entry of the log is believed ([FileOp.check]).
///
/// - [signed]: its author signed it (over the space, the entry they had read last, the roster revision they held and
///   what it says), the relay's word on who wrote it is that signature's key, and it sits right after the entry its
///   author had read: who wrote it and where are known, not taken from the relay.
/// - [unsigned]: written by 0.9.2, or before entries were signed: who wrote it is the relay's word, as it always was.
/// - [moved]: signed, but later in the log than its author put it (a relay from before `?after=`, two written at once):
///   believed as far as an unsigned one.
/// - [bad]: says it was signed and isn't, or names another space, another author, or a place before its author's own.
/// - [unchecked]: kept on this device by 0.9.2, which kept entries without checking them: checked as it is loaded.
enum OpTrust {
  unsigned('u'),
  signed('s'),
  moved('m'),
  bad('x'),
  unchecked('?');

  const OpTrust(this.wire);

  /// Its letter in the log kept on disk; a letter this build doesn't know reads as [unchecked].
  final String wire;
  static OpTrust of(Object? wire) => values.where((t) => t.wire == wire).firstOrNull ?? unchecked;
}

/// One entry of a space's log as the relay keeps it: its number, who wrote it, when, and what it says once opened with
/// the files key ([FileOp.open]); a sealed entry that does not open is kept as null and skipped. [by] is the relay's
/// word, from the request's signature, and for a [OpTrust.signed] entry the entry's own signature's key besides.
@immutable
class LoggedOp {
  const LoggedOp({required this.seq, required this.by, required this.at, required this.op, this.trust = OpTrust.unsigned, this.rv, this.relayRv, this.sh, this.cas = false});
  final int seq;
  final String by;
  final int at;
  final Map<String, Object?>? op;

  /// How far it is believed, and the roster revision its author signed it under (signed entries only).
  final OpTrust trust;
  final int? rv;

  /// The newest roster revision the relay had believed for the space when the entry came (relay/lib/files.dart): the
  /// entry is judged by one no older.
  final int? relayRv;

  /// The first 16 bytes of the SHA-256 of the entry as the relay keeps it, sealed ([FileOp.sealedHash]), in hex: the
  /// next signed entry names it (`g.ph`), so what came before an entry can't be swapped or forked under it. Null for
  /// one kept by 0.9.2, which kept only what it said.
  final String? sh;

  /// Whether the relay that wrote it says it was one that takes `?after=` (the line's `c`): then a signed entry out of
  /// its place was moved by the relay, not by two writing at once, and is not believed ([FilesList.read]).
  final bool cas;

  /// This entry, checked: its signature, author and place ([FileOp.check]) for the space the relay calls [space].
  LoggedOp checked(String space) {
    final o = op;
    if (o == null) return LoggedOp(seq: seq, by: by, at: at, op: null, relayRv: relayRv, sh: sh, cas: cas);
    final c = FileOp.check(o, space: space, seq: seq, by: by);
    return LoggedOp(seq: seq, by: by, at: at, op: o, trust: c.trust, rv: c.rv, relayRv: relayRv, sh: sh, cas: cas);
  }

  /// As kept on this device between runs, with how far it was believed.
  Map<String, Object?> toJson() => {'s': seq, 'by': by, 'at': at, 'op': op, 'tr': trust.wire, 'rv': ?rv, 'rr': ?relayRv, 'sh': ?sh, if (cas) 'c': 1};
  static LoggedOp? fromJson(Object? j) {
    if (j is! Map || j['s'] is! int || j['by'] is! String) return null;
    final op = (j['op'] as Map?)?.cast<String, Object?>();
    // Kept by 0.9.2 (no 'tr'): an entry with no signature is what it was then; one with a signature is checked.
    final trust = j['tr'] == null ? (op != null && (op.containsKey('gs') || op.containsKey('g')) ? OpTrust.unchecked : OpTrust.unsigned) : OpTrust.of(j['tr']);
    return LoggedOp(
      seq: j['s'] as int,
      by: j['by'] as String,
      at: (j['at'] as num?)?.toInt() ?? 0,
      op: op,
      trust: trust,
      rv: (j['rv'] as num?)?.toInt(),
      relayRv: (j['rr'] as num?)?.toInt(),
      sh: j['sh'] is String ? j['sh'] as String : null,
      cas: j['c'] == 1,
    );
  }
}

/// [log]'s entries checked ([LoggedOp.checked]) for [space]: run on another isolate for a page of them, since each
/// signature takes a few milliseconds.
List<LoggedOp> checkAll(List<LoggedOp> log, String space) => [for (final e in log) e.checked(space)];

/// The operations a space's log holds, each sealed with the files key: a file added (`add`), renamed (`ren`), moved to
/// a folder (`mv`), removed (`del`), and a folder made (`dir`), let go (`rmdir`) or renamed or moved with all it holds
/// (`mvdir`). An older build reading a newer kind skips it.
///
/// **Nested folders** (Matt, 2026-11-18: "allow root level folders in the file sharing tab and nested folders"). A
/// folder is a path ([SpaceFile.cleanFolder]) wherever one was a name: a file's `d`, a `mv`'s, a `dir`'s, a `rmdir`'s.
/// A folder is kept from its `dir` (empty or not) until a `rmdir` lets it go, and a `rmdir` lets go of everything in it
/// when it holds no file. `mvdir` (`d` to `to`; no `to` empties it into the folder it is in) is one entry, so a folder
/// of many files moves at once, and it is let through only whole: by someone who may make folders and may move every
/// file in it, and only where nothing would end up deeper than [SpaceFile.maxDepth]. 0.9.6 and older skip `mvdir`, and
/// show a moved folder's files where they were.
///
/// **Signed** (Matt, 2026-11-17: "Finish the missing pieces that went unfinished" (of Circles and Files spaces,
/// released in 0.9.2)). Who wrote an entry was the relay's word, and nothing in the sealed entry tied it to its
/// space or its place, so a relay could have put a moderator's name on a `del`, played an old entry again or moved one.
/// Now each carries, beside what it says and in the same sealed body, `g`: the space's relay name (`sp`), the number of
/// the last entry its author had read (`pr`), the roster revision they held (`rv`) and their public key (`k`); and
/// `gs`, their signature over all of it ([sign], [check]). 0.9.2 reads such an entry as it reads any (it ignores the
/// two fields), and its own entries, unsigned, are still read, as [OpTrust.unsigned].
///
/// **A roster** (`roster`): the space's roster as its owner or an admin signed it (lib/voice/roles.dart), put in the
/// log by the first device to write under a newer one, so every device judges each entry by the roster its author
/// wrote under, from the log itself ([FilesList.read]).
class FileOp {
  FileOp._();

  // What each kind of entry says, before it is signed ([sign]) and sealed ([seal]).
  static Map<String, Object?> add(SpaceFile f) => {'t': 'add', 'f': f.toJson()};
  static Map<String, Object?> rename(String id, String name) => {'t': 'ren', 'id': id, 'n': name};
  static Map<String, Object?> move(String id, String? folder) => {'t': 'mv', 'id': id, 'd': folder};
  static Map<String, Object?> delete(String id) => {'t': 'del', 'id': id};
  static Map<String, Object?> folder(String name) => {'t': 'dir', 'd': name};
  static Map<String, Object?> unfolder(String name) => {'t': 'rmdir', 'd': name};
  static Map<String, Object?> moveFolder(String from, String? to) => {'t': 'mvdir', 'd': from, 'to': to};
  static Map<String, Object?> roster(Map<String, Object?> signedRoster) => {'t': 'roster', 'r': signedRoster};

  /// What an entry's signature covers starts with these words.
  static const signedWords = 'ghost-files op v2|';

  /// [op] signed by the holder of [publicKey] (with [sign]): for the space the relay calls [space], written after
  /// entry [prev], whose sealed bytes hash to [prevHash] ([sealedHash]; empty where this device doesn't know it), under
  /// roster revision [rv].
  ///
  /// `pr` alone is a number the relay hands out, so a relay could have shown different devices different entries
  /// before it, or put one in ahead of it and numbered the rest again; `ph` ties the entry to the very bytes before it
  /// (Matt, 2026-11-17: "Finish the missing pieces that went unfinished").
  static Future<Map<String, Object?>> sign(Map<String, Object?> op, {required String space, required int prev, String prevHash = '', required int rv, required Uint8List publicKey, required Future<Uint8List> Function(List<int>) sign}) async {
    final unsigned = {...op, 'g': {'sp': space, 'pr': prev, 'rv': rv, 'k': NetCrypto.hex(publicKey), 'ph': prevHash}}..remove('gs');
    final sig = await sign(utf8.encode('$signedWords${canonical(unsigned)}'));
    return {...unsigned, 'gs': base64Encode(sig)};
  }

  /// How far [op], at [seq] in the log of the space the relay calls [space] and written by [by] as the relay says, is
  /// believed, and the roster revision it says it was written under.
  static ({OpTrust trust, int? rv}) check(Map<String, Object?> op, {required String space, required int seq, required String by}) {
    final g = op['g'], gs = op['gs'];
    if (g == null && gs == null) return (trust: OpTrust.unsigned, rv: null);
    if (g is! Map || gs is! String) return (trust: OpTrust.bad, rv: null);
    final k = g['k'], sp = g['sp'], pr = g['pr'], rv = g['rv'], ph = g['ph'];
    if (k is! String || !RegExp(r'^0[23][0-9a-f]{64}$').hasMatch(k) || sp != space || pr is! int || rv is! int || pr < 0 || rv < 0) return (trust: OpTrust.bad, rv: null);
    if (ph != null && (ph is! String || !(ph.isEmpty || RegExp(r'^[0-9a-f]{32}$').hasMatch(ph)))) return (trust: OpTrust.bad, rv: null);
    final key = NetCrypto.unhex(k);
    // The relay's word on who wrote it must be the key that signed it: a relay can't put another name on it.
    if (NetCrypto.idOf(key) != by) return (trust: OpTrust.bad, rv: null);
    Uint8List sig;
    try {
      sig = base64Decode(gs);
    } catch (_) {
      return (trust: OpTrust.bad, rv: null);
    }
    // Only the one way of writing it: base64Decode takes the URL-safe letters too, so the same signature written
    // another way would have looked like another entry to a reader looking for one played again.
    if (sig.length != 64 || base64Encode(sig) != gs) return (trust: OpTrust.bad, rv: null);
    final unsigned = {...op}..remove('gs');
    if (!NetCrypto.verify(key, utf8.encode('$signedWords${canonical(unsigned)}'), sig)) return (trust: OpTrust.bad, rv: null);
    // Its place: right after what its author read. Later is a relay from before `?after=` (or one that moved it):
    // believed no further than an unsigned entry. Earlier than its author could have written it, never.
    if (seq == pr + 1) return (trust: OpTrust.signed, rv: rv);
    return (trust: seq > pr + 1 ? OpTrust.moved : OpTrust.bad, rv: rv);
  }

  /// What names a sealed entry for the one after it (`g.ph`): the first 16 bytes of its SHA-256, in hex.
  static String sealedHash(List<int> sealed) => NetCrypto.hex(NetCrypto.sha256(sealed).sublist(0, 16));

  /// [value] as JSON with every map's keys in order, so the bytes signed are the bytes checked whatever order a map
  /// was read back in.
  static String canonical(Object? value) {
    if (value is Map) {
      final keys = [for (final k in value.keys) '$k']..sort();
      return '{${[for (final k in keys) '${jsonEncode(k)}:${canonical(value[k])}'].join(',')}}';
    }
    if (value is List) return '[${[for (final v in value) canonical(v)].join(',')}]';
    return jsonEncode(value);
  }

  /// [op] sealed with the space's files key, as the relay keeps it; and one opened again, null where the key is not
  /// the one or what is inside isn't an entry.
  static Uint8List seal(Uint8List filesKey, Map<String, Object?> op) => NetCrypto.seal(filesKey, utf8.encode(jsonEncode(op)));

  static Map<String, Object?>? open(Uint8List filesKey, List<int> sealed) {
    final clear = NetCrypto.open(filesKey, sealed);
    if (clear == null) return null;
    try {
      return (jsonDecode(utf8.decode(clear)) as Map).cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }
}

/// Who may do what to a space's files, as its roles say (lib/voice/roles.dart), asked of each entry as the log is read:
/// every device reads the same log under the same roster and arrives at the same list.
abstract class FilesRules {
  /// Whether [by] may add files.
  bool mayAdd(String by);

  /// Whether [by] may rename, move or remove [file]: their own, or anyone's with Manage files and a higher role, or
  /// the owner.
  bool mayChange(String by, SpaceFile file);

  /// Whether [by] may make or remove folders.
  bool mayFolder(String by);
}

/// Everyone may add and change their own; the owner may change anything (a space whose roster has not come yet).
class OwnerRules implements FilesRules {
  const OwnerRules(this.ownerId);
  final String? ownerId;
  @override
  bool mayAdd(String by) => true;
  @override
  bool mayChange(String by, SpaceFile file) => by == file.by || (ownerId != null && by == ownerId);
  @override
  bool mayFolder(String by) => true;
}

/// A roster believed from a log's `roster` entry: its revision, its rules, and the roster itself, which the next one
/// in the log is judged against.
typedef BelievedRoster = ({int version, FilesRules rules, Object? held});

/// The roster a log's `roster` entry carries, where it is one to believe for the space after [previous] (the last one
/// believed from the log; null for the first): its revision and its rules.
typedef LoggedRoster = BelievedRoster? Function(Object? roster, BelievedRoster? previous);

/// Both [a] and [b]: an entry signed under a roster revision no one had shown yet is let do only what the newest roster
/// shown and today's both allow.
class _Both implements FilesRules {
  const _Both(this.a, this.b);
  final FilesRules a, b;
  @override
  bool mayAdd(String by) => a.mayAdd(by) && b.mayAdd(by);
  @override
  bool mayChange(String by, SpaceFile file) => a.mayChange(by, file) && b.mayChange(by, file);
  @override
  bool mayFolder(String by) => a.mayFolder(by) && b.mayFolder(by);
}

/// A space's files as its log says, read in order under [rules].
class FilesList {
  FilesList._(this.files, this.folders, this.rosterVersion);

  /// By id, in the order they were added.
  final Map<String, SpaceFile> files;

  /// Folders, by path: those made, with those files are in and every folder those are in besides.
  final Set<String> folders;

  /// The folders right inside [parent] (null for the top), by path, in order of their names.
  List<String> subfolders(String? parent) =>
      [for (final f in folders) if (SpaceFile.folderParent(f) == parent) f]..sort((a, b) => SpaceFile.folderName(a).toLowerCase().compareTo(SpaceFile.folderName(b).toLowerCase()));

  /// The files right in [folder] (null for the top); and those anywhere inside [path].
  Iterable<SpaceFile> filesIn(String? folder) => files.values.where((f) => f.folder == folder);
  Iterable<SpaceFile> filesUnder(String path) => files.values.where((f) => SpaceFile.inFolder(f.folder, path));

  /// The folders inside [path], at any depth (not [path] itself).
  Iterable<String> foldersUnder(String path) => folders.where((f) => f != path && SpaceFile.inFolder(f, path));

  /// [path] and every folder it is in, kept in [folders].
  static void _keep(Set<String> folders, String? path) {
    if (path != null) folders.addAll(SpaceFile.folderLine(path));
  }

  /// The newest roster revision the log holds (0 for none): a device writing under a newer one puts it in first.
  final int rosterVersion;

  /// Reads [log] in order. [rules] are the space's roles as this device has them now, revision [rulesVersion].
  ///
  /// Each signed entry ([OpTrust.signed]) is judged by the roles at the newest revision shown before it: the newest
  /// roster put in the log before it ([rosters] reads those), or the one the relay had believed when the entry came
  /// ([LoggedOp.relayRv]), whichever is newer. So a ban or a demotion later doesn't undo what someone could do then, a
  /// demoted moderator signing under the roster from before can't get by on it once the newer one is shown, and a
  /// promotion doesn't make good what they couldn't (Matt, 2026-11-17: "Finish the missing pieces that went
  /// unfinished"). The revision its author says they held is a claim, not a fact: one newer than any shown (a revision
  /// that doesn't exist yet, which a promotion later would make good) is let do only what both the newest shown and
  /// today's rules allow. Where a revision isn't known here, today's rules.
  ///
  /// Unsigned entries (0.9.2's) are judged as they always were, by today's rules; but an unsigned one in the name of
  /// someone who had already read past it when they signed an entry is not theirs (a newer app never writes one), and
  /// is skipped. A signed entry seen a second time (played again) is skipped, as is a [OpTrust.bad] one, one whose
  /// `ph` doesn't name the bytes before it, and a [OpTrust.moved] one where the relay says it takes `?after=`
  /// ([LoggedOp.cas]) or after [strictAfter] (where this device first heard the relay say so): an honest relay of that
  /// kind never moves an entry.
  static FilesList read(Iterable<LoggedOp> log, FilesRules rules, {LoggedRoster? rosters, int? rulesVersion, int? strictAfter}) {
    final files = <String, SpaceFile>{};
    final folders = <String>{};
    // Every id ever added: a file is added once. A deleted one can't be posted again (by anyone, with its key copied
    // from the first add) to bring back what was taken out.
    final seen = <String>{};
    final byVersion = <int, FilesRules>{?rulesVersion: rules};
    var floor = 0;
    BelievedRoster? last;
    // Where each signer had read to when they first signed: an unsigned entry in their name after that is not theirs.
    // Gathered first, so it holds however the relay ordered things.
    final readTo = <String, int>{};
    for (final e in log) {
      final g = e.op?['g'];
      if ((e.trust == OpTrust.signed || e.trust == OpTrust.moved) && g is Map && g['pr'] is int) {
        final pr = g['pr'] as int;
        if (pr < (readTo[e.by] ?? pr + 1)) readTo[e.by] = pr;
      }
    }
    final hashes = <int, String>{};
    // Signatures seen, by key and the signature's r: r comes from the signer's one-time number, so the same signed
    // entry however its signature is written (its twin s, the other base64 letters) is one, and two entries never share
    // one.
    final signatures = <String>{};
    for (final e in log) {
      if (e.sh != null) hashes[e.seq] = e.sh!;
      final op = e.op;
      if (op == null) continue;
      var judge = rules;
      switch (e.trust) {
        case OpTrust.bad:
          continue;
        case OpTrust.unsigned:
        case OpTrust.unchecked:
          final to = readTo[e.by];
          if (to != null && e.seq > to) continue;
        case OpTrust.moved:
          if (e.cas || (strictAfter != null && e.seq > strictAfter)) continue;
          if (!_firstSeen(op, signatures, hashes)) continue;
        case OpTrust.signed:
          if (!_firstSeen(op, signatures, hashes)) continue;
          final shown = math.max(floor, e.relayRv ?? 0);
          final at = byVersion[shown] ?? rules;
          judge = (e.rv ?? 0) > shown ? _Both(at, rules) : at;
      }
      switch (op['t']) {
        case 'roster':
          // Its revision first, before any signature is checked: one no newer than what is believed already is passed
          // over, so a log flooded with copies of a roster costs nothing to read.
          final r0 = op['r'];
          final v0 = r0 is Map ? r0['v'] : null;
          if (v0 is! int || v0 <= floor) break;
          final r = rosters?.call(r0, last);
          if (r != null && r.version > floor) {
            floor = r.version;
            // The first roster believed at a revision stands (this device's own, where it holds that one).
            byVersion.putIfAbsent(r.version, () => r.rules);
            last = r;
          }
        case 'add':
          final f = SpaceFile.fromJson(op['f'], by: e.by, at: e.at, verified: e.trust == OpTrust.signed);
          if (f != null && seen.add(f.id) && judge.mayAdd(e.by)) {
            files[f.id] = f;
            _keep(folders, f.folder);
          }
        case 'ren':
          final f = files[op['id']];
          final name = op['n'] is String ? SpaceFile.cleanName(op['n'] as String) : '';
          if (f != null && name.isNotEmpty && judge.mayChange(e.by, f)) files[f.id] = f.copyWith(name: name);
        case 'mv':
          final f = files[op['id']];
          if (f != null && judge.mayChange(e.by, f)) {
            final d = SpaceFile.cleanFolder(op['d']);
            files[f.id] = f.copyWith(folder: d, clearFolder: d == null);
            _keep(folders, d);
          }
        case 'del':
          final f = files[op['id']];
          if (f != null && judge.mayChange(e.by, f)) files.remove(f.id);
        case 'dir':
          final d = SpaceFile.cleanFolder(op['d']);
          if (d != null && judge.mayFolder(e.by)) _keep(folders, d);
        case 'rmdir':
          final d = SpaceFile.cleanFolder(op['d']);
          // Only a folder with no file in it (at any depth) goes, with the empty folders inside it: a file never leaves
          // the list because its folder went.
          if (d != null && judge.mayFolder(e.by) && !files.values.any((f) => SpaceFile.inFolder(f.folder, d))) folders.removeWhere((x) => SpaceFile.inFolder(x, d));
        case 'mvdir':
          final from = SpaceFile.cleanFolder(op['d']);
          final to = SpaceFile.cleanFolder(op['to']);
          // A `to` that cleans to nothing is no place; none at all empties the folder into the one it is in.
          if (from == null || (op['to'] != null && to == null) || (to != null && SpaceFile.inFolder(to, from)) || !judge.mayFolder(e.by)) break;
          final inside = [for (final f in files.values) if (SpaceFile.inFolder(f.folder, from)) f];
          final subs = [for (final x in folders) if (SpaceFile.inFolder(x, from)) x];
          if (subs.isEmpty || inside.any((f) => !judge.mayChange(e.by, f))) break;
          final parent = SpaceFile.folderParent(from);
          // Where a path inside it goes: under `to` in its place, or (no `to`) into the folder it was in.
          String? moved(String p) {
            final rest = p == from ? '' : p.substring(from.length + 1);
            final base = to ?? parent;
            if (rest.isEmpty) return base;
            return base == null ? rest : '$base/$rest';
          }

          if (subs.any((p) => SpaceFile.folderNames(moved(p)).length > SpaceFile.maxDepth)) break;
          for (final f in inside) {
            final d = moved(f.folder!);
            files[f.id] = f.copyWith(folder: d, clearFolder: d == null);
          }
          folders.removeAll(subs);
          for (final p in subs) {
            _keep(folders, moved(p));
          }
      }
    }
    return FilesList._(files, folders, floor);
  }

  /// Whether signed [op] is seen here for the first time and names the bytes before it truly (where they are known).
  static bool _firstSeen(Map<String, Object?> op, Set<String> signatures, Map<int, String> hashes) {
    final g = op['g'] as Map;
    final ph = g['ph'];
    if (ph is String && ph.isNotEmpty) {
      final before = hashes[g['pr']];
      if (before != null && before != ph) return false;
    }
    try {
      final sig = base64Decode(op['gs'] as String);
      return signatures.add('${g['k']}:${NetCrypto.hex(sig.sublist(0, 32))}');
    } catch (_) {
      return false;
    }
  }

  /// The plain size of every file listed, in bytes.
  int get bytes => files.values.fold(0, (n, f) => n + f.size);
}

/// How a space's files are listed.
enum FilesSort {
  newest('Newest'),
  oldest('Oldest'),
  name('Name'),
  size('Size'),
  type('Type');

  const FilesSort(this.label);
  final String label;

  /// The sort called [name], as a choice is kept; newest for none or one unknown.
  static FilesSort of(String? name) => values.where((s) => s.name == name).firstOrNull ?? newest;

  /// [files] in this order: size is biggest first, type is by kind, and names settle a tie in either.
  List<SpaceFile> apply(Iterable<SpaceFile> files) {
    final list = files.toList();
    int byName(SpaceFile a, SpaceFile b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    switch (this) {
      case newest:
        list.sort((a, b) => b.at.compareTo(a.at));
      case oldest:
        list.sort((a, b) => a.at.compareTo(b.at));
      case name:
        list.sort(byName);
      case size:
        list.sort((a, b) => b.size != a.size ? b.size.compareTo(a.size) : byName(a, b));
      case type:
        list.sort((a, b) => a.kind.index != b.kind.index ? a.kind.index.compareTo(b.kind.index) : byName(a, b));
    }
    return list;
  }
}
