/// A folder on a computer kept in step with My files, or with a Files space (GMFB-38: "Sync a folder on your computer
/// with a drive"; done looks like "Pick a local folder on desktop to keep in two-way sync with a Files space or the
/// personal drive"). One folder for My files and one for each Files space this device may add files to, each with a
/// choice and a state file of its own, and no folder in, around or the same as another's: what is in My files would
/// else go up into a space for everyone in it.
///
/// What a pass does, and what it never does. This touches people's own folders, so the rules are few and one-way safe:
///
/// - **Adds, changes and removals.** A file new or changed in the folder goes up to the drive under the same path; a
///   file new or changed in the drive comes down into the folder. Which side changed is told from a small state file
///   kept in the app's own folder ([SyncState]): for each path, the local size and modified time and the drive's file
///   id, SHA-256 and time when the two were last in step.
/// - **A changed file replaces the older one** (GMFB-38, "the files log has no replace"): the newer goes up, and then
///   the drive's file the sync last had at that path is removed with the log's own `del` entry, which every build
///   reads. So a build from before sees the newer file alone, or both for the moment between the two entries; never a
///   broken list, and the relay is not changed. Where the older one can't be removed (someone else's, in a space), both
///   stay. A copy of the same path older than the one the sync last had (left by a build from before) is never brought
///   down over what is newer.
/// - **A removal is followed only for a file the sync itself had in step** (it has a record of it): removed from the
///   folder, its file in the drive is removed, where the drive's is still the one recorded; removed from the drive, the
///   local file is moved into the hidden folder ".ghost-deleted" inside the synced folder (never deleted), where its
///   size, time and SHA-256 are still the ones recorded. A file on one side the sync never had in step is never
///   removed, and one changed meanwhile goes the other way instead. More than [FolderSyncEngine.holdOver] files gone
///   at once, or more than half of those in step, wait for the person to say ([SyncReport.heldHere], a drive unplugged
///   or a folder moved), and nothing is done to them meanwhile.
/// - **A local file is replaced only where its content is one the sync itself recorded**: its size and time are as
///   recorded AND its SHA-256 is the recorded one. Anything else (both sides changed, or no record) keeps both: the
///   drive's is written beside it as "name (from My files).ext" and the local one goes up.
/// - **What comes down is written under a temporary name in the same folder** (".ghost-sync-….part") and renamed when
///   whole and checked, so a half-written file never has the real name.
/// - **Left out**: hidden files and folders (a dot first, desktop.ini, Thumbs.db), links (never followed), files
///   changed in the last few seconds (still being written), files over the drive's limit or its room, and names
///   another system can't hold. A pass never walks or writes outside the folder: a path from the drive is refused
///   where it has a name of dots, a slash, or goes through a link.
/// - **Never synced**: the home folder itself or anything above it, a disk's top, and the app's own folders.
///
/// The folder chosen is this computer's alone: a file in the app's folder, never the account's synced preferences.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../desktop/store.dart' show DeskStore;
import '../net/file_seal.dart';
import '../platform_info.dart';
import '../voice/channels.dart' show Voice;
import '../voice/voice.dart' show SpaceKind, VoiceChannel;
import 'drive.dart';
import 'files_store.dart';

/// A file in the drive, as a pass sees it: its path from the drive's top ("Papers/lease.pdf").
class DriveFile {
  const DriveFile({required this.id, required this.path, required this.size, required this.sha, required this.at});
  final String id, path, sha;
  final int size, at;
}

/// One file can't go this pass, for a reason said in a few words ("too big"); the rest carry on.
class SyncSkip implements Exception {
  const SyncSkip(this.why);
  final String why;
}

/// The pass can't go on (the drive is out of reach); said in the state line, tried again next time.
class SyncStop implements Exception {
  const SyncStop(this.why);
  final String why;
}

/// The drive, as much of it as a pass needs. [StoreDrive] is the app's; a test gives its own.
abstract class SyncDrive {
  /// Which drive this is, for the state file's name (never its seed).
  String get id;

  /// Every file in the drive; null where it can't be reached now.
  Future<List<DriveFile>?> list();

  /// The most one file may be, and the room left; 0 and null where not known.
  int get maxFile;
  int? get free;

  /// Adds the file at [local] as [name] in [folder] (null for the top): the drive's file, or null where it went up but
  /// can't be told which it is. Throws [SyncSkip] or [SyncStop].
  Future<DriveFile?> upload(String local, String? folder, String name);

  /// [f] whole and checked, at a path on this device the pass copies from. Throws [SyncSkip] or [SyncStop].
  Future<String> fetch(DriveFile f);

  /// Removes [f] from the drive: true where it is gone (or already was), false where this device may not remove it.
  /// Throws [SyncSkip] or [SyncStop].
  Future<bool> delete(DriveFile f);
}

/// What one path was when the folder and the drive were last in step.
class SyncEntry {
  SyncEntry({this.size = -1, this.modified = -1, this.id = '', this.sha = '', this.kept, this.at = -1});

  /// The local file's size and modified time (ms), and the drive's file id and SHA-256 of that content.
  int size, modified;
  String id, sha;

  /// When the drive's file was added ([DriveFile.at]); -1 where not known. An entry with no [id] and a time is a path
  /// removed by the sync: a copy of it in the drive no newer is one left from before, never brought down.
  int at;

  /// A drive file already written beside this path as a second copy, so it is not written again.
  String? kept;

  Map<String, Object?> toJson() => {'z': size, 'm': modified, 'id': id, 'h': sha, 'k': ?kept, if (at >= 0) 'a': at};
  static SyncEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    return SyncEntry(size: (j['z'] as num?)?.toInt() ?? -1, modified: (j['m'] as num?)?.toInt() ?? -1, id: '${j['id'] ?? ''}', sha: '${j['h'] ?? ''}', kept: j['k'] as String?, at: (j['a'] as num?)?.toInt() ?? -1);
  }
}

/// The state file of one synced folder, in the app's own folder (never inside the synced one).
class SyncState {
  SyncState(this.file);
  final File file;
  final Map<String, SyncEntry> entries = {};

  void load() {
    entries.clear();
    try {
      if (!file.existsSync()) return;
      final j = jsonDecode(file.readAsStringSync());
      final files = j is Map ? j['files'] : null;
      if (files is! Map) return;
      for (final e in files.entries) {
        final v = SyncEntry.fromJson(e.value);
        if (v != null) entries['${e.key}'] = v;
      }
    } catch (_) {
      // Unreadable: as a folder never synced, where nothing is replaced and what differs is kept twice.
      entries.clear();
    }
  }

  void save(String root) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode({'v': 1, 'root': root, 'files': {for (final e in entries.entries) e.key: e.value.toJson()}}), flush: true);
    tmp.renameSync(file.path);
  }
}

/// What a pass came to.
class SyncReport {
  int up = 0, down = 0, both = 0;

  /// Files removed from the drive because they were removed from the folder, and moved aside here because they were
  /// removed from the drive.
  int deletedThere = 0, removedHere = 0;

  /// Paths gone from the folder whose removal from the drive waits for the person to say, and paths gone from the drive
  /// whose removal here waits: too many at once ([FolderSyncEngine.holdOver]).
  final List<String> heldHere = [], heldThere = [];

  /// Why files were left out, and how many of each.
  final Map<String, int> skipped = {};

  /// More to move than one pass takes, or more files than one pass walks.
  bool capped = false;

  /// Why the pass did not finish; null where it did.
  String? stopped;

  int get moved => up + down + deletedThere + removedHere;
  void skip(String why) => skipped[why] = (skipped[why] ?? 0) + 1;

  /// The state line once a pass is done.
  String get line {
    if (stopped != null) return 'Stopped: $stopped';
    final held = heldHere.length + heldThere.length;
    if (held > 0) return 'Waiting for you: $held ${held == 1 ? 'file is' : 'files are'} gone.';
    final left = [for (final e in skipped.entries) '${e.value} ${e.key}'].join(', ');
    final more = capped ? ' More next time.' : '';
    if (left.isEmpty) return 'In step.$more';
    final n = skipped.values.fold(0, (a, b) => a + b);
    return 'In step, but for $n left out ($left).$more';
  }
}

/// One pass over one folder ([run]); and what may be synced at all ([whyNot]).
class FolderSyncEngine {
  FolderSyncEngine({required this.root, required this.drive, required this.state, DateTime Function()? now, this.most = 2000, this.walkMost = 20000, this.quiet = const Duration(seconds: 5), this.stopped, this.progress, this.driveName = Drive.name, this.allow = const {}, this.forget = const {}, this.holdOver = 20}) : now = now ?? DateTime.now;

  /// Paths whose removal the person said yes to: followed however many there are.
  final Set<String> allow;

  /// Paths whose record is dropped before the pass (the person said keep them): they go up, or come down, again.
  final Set<String> forget;

  /// More removals than this in one pass (or more than half the files in step, past three) wait for the person.
  final int holdOver;

  /// The hidden folder, inside the synced one, where a file removed from the drive is moved: never deleted.
  static const binName = '.ghost-deleted';

  /// What the drive is called in what a pass says, and in a second copy's name: My files, or a Files space's name.
  final String driveName;

  /// The folder, as [resolve] gave it.
  final String root;
  final SyncDrive drive;
  final SyncState state;
  final DateTime Function() now;

  /// The most files one pass moves, and the most it looks at.
  final int most, walkMost;

  /// A file changed more recently than this is taken to be still being written.
  final Duration quiet;

  /// Asked between files: true stops the pass (Stop syncing, signed out).
  final bool Function()? stopped;

  /// Told as it goes: how many files are still to move.
  final void Function(int left)? progress;

  static final String _sep = PlatformInfo.pathSeparator;

  /// What a second copy's name is given, for My files; [mark] is any drive's.
  static const fromDrive = ' (from My files)';

  /// What a second copy's name is given: " (from My files)", " (from Team files)"; " (from the space)" where the
  /// space's name is one a file's name can't hold, or is long.
  String get mark => driveName == Drive.name ? fromDrive : ' (from ${holdable(driveName) && driveName.length <= 40 ? driveName : 'the space'})';

  /// The start of a temporary file's name: hidden, so no pass takes one for a file.
  static const partStart = '.ghost-sync-';

  static const _hiddenNames = {'desktop.ini', 'thumbs.db', 'ehthumbs.db', r'$recycle.bin', 'system volume information', 'icon\r'};

  /// Whether a file or folder of this name is left out as hidden.
  static bool hidden(String name) => name.startsWith('.') || name.startsWith('~\$') || _hiddenNames.contains(name.toLowerCase());

  /// Whether every system can hold this name as it is, and the drive keeps it unchanged.
  static bool holdable(String name) => name.isNotEmpty && SpaceFile.cleanName(name) == name && name.length <= 200;

  /// Whether the drive keeps this folder path unchanged (no more than its depth, each name holdable and short).
  static bool holdableFolder(String? folder) => folder == null || SpaceFile.cleanFolder(folder) == folder;

  /// [path] with links and dots worked out; null where it is no folder.
  static String? resolve(String path) {
    try {
      final d = Directory(path);
      if (!d.existsSync()) return null;
      var p = d.resolveSymbolicLinksSync();
      while (p.length > 1 && (p.endsWith('/') || p.endsWith(r'\')) && !RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(p)) {
        p = p.substring(0, p.length - 1);
      }
      return p;
    } catch (_) {
      return null;
    }
  }

  static String _fold(String p) => (PlatformInfo.isWindows || PlatformInfo.isMacOS ? p.toLowerCase() : p).replaceAll(r'\', '/');
  static bool _within(String inner, String outer) {
    final a = _fold(inner), b = _fold(outer);
    return a == b || a.startsWith(b.endsWith('/') ? b : '$b/');
  }

  /// Why the folder at [path] (as [resolve] gave it) can't be synced, in words; null where it can. [home] is the
  /// person's home folder and [own] the app's own folders.
  static String? whyNot(String path, {String? home, List<String> own = const []}) {
    final parent = Directory(path).parent.path;
    if (parent == path || RegExp(r'^[A-Za-z]:[\\/]?$').hasMatch(path) || path == '/' || RegExp(r'^[\\/]{2}[^\\/]+[\\/][^\\/]+[\\/]?$').hasMatch(path)) {
      return 'A whole disk can\'t be synced. Choose a folder in it.';
    }
    // A Mac's other disks, and Linux's: /Volumes/Name, /media/me/Name, /mnt/name.
    if (RegExp(r'^/(Volumes|mnt|media)(/[^/]+)?$').hasMatch(path) || RegExp(r'^/media/[^/]+/[^/]+$').hasMatch(path)) {
      return 'A whole disk can\'t be synced. Choose a folder in it.';
    }
    final h = home == null ? null : (resolve(home) ?? home);
    if (h != null && _within(h, path)) return 'Your home folder can\'t be synced. Choose a folder in it.';
    for (final o in own) {
      final r = resolve(o) ?? o;
      if (_within(path, r) || _within(r, path)) return 'That is where Uplink keeps its own files. Choose another folder.';
    }
    if (hidden(path.split(RegExp(r'[\\/]')).last)) return 'A hidden folder can\'t be synced.';
    return null;
  }

  /// The local files, by path with forward slashes: size and modified time.
  Map<String, ({int size, int modified})> _walk(SyncReport r) {
    final out = <String, ({int size, int modified})>{};
    final soon = now().subtract(quiet).millisecondsSinceEpoch;
    void into(Directory d, String? rel, int depth) {
      List<FileSystemEntity> list;
      try {
        list = d.listSync(followLinks: false);
      } catch (_) {
        r.skip('can\'t be read');
        return;
      }
      list.sort((a, b) => a.path.compareTo(b.path));
      for (final e in list) {
        if (out.length >= walkMost) {
          r.capped = true;
          return;
        }
        final name = e.path.substring(e.path.lastIndexOf(_sep) + 1);
        if (hidden(name)) continue;
        // What it is, itself: a link is never followed, whatever it points at.
        final type = FileSystemEntity.typeSync(e.path, followLinks: false);
        if (type == FileSystemEntityType.link) {
          r.skip('a link');
          continue;
        }
        final path = rel == null ? name : '$rel/$name';
        if (type == FileSystemEntityType.directory) {
          if (!holdable(name) || name.length > 80 || depth >= SpaceFile.maxDepth) {
            r.skip(depth >= SpaceFile.maxDepth ? 'too deep in folders' : 'with a name $driveName can\'t hold');
            continue;
          }
          into(Directory(e.path), path, depth + 1);
        } else if (type == FileSystemEntityType.file) {
          if (!holdable(name)) {
            r.skip('with a name $driveName can\'t hold');
            continue;
          }
          try {
            final s = File(e.path).statSync();
            final m = s.modified.millisecondsSinceEpoch;
            if (m > soon) {
              r.skip('still being written');
              continue;
            }
            out[path] = (size: s.size, modified: m);
          } catch (_) {
            r.skip('can\'t be read');
          }
        }
      }
    }

    into(Directory(root), null, 0);
    return out;
  }

  String _local(String path) => '$root$_sep${path.replaceAll('/', _sep)}';

  /// Whether [path] from the drive may be written in the folder: every name holdable and not hidden, none of dots.
  static bool _safe(String path) {
    final names = path.split('/');
    if (names.isEmpty || names.length > SpaceFile.maxDepth + 1) return false;
    for (final n in names) {
      if (n.isEmpty || n == '.' || n == '..' || n.contains(r'\') || !holdable(n) || hidden(n)) return false;
    }
    return true;
  }

  /// Makes the folders [path] lies in, refusing where one of them is a link or a file: never written through a link.
  bool _makeParents(String path) {
    final names = path.split('/')..removeLast();
    var at = root;
    for (final n in names) {
      at = '$at$_sep$n';
      final type = FileSystemEntity.typeSync(at, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        Directory(at).createSync();
      } else if (type != FileSystemEntityType.directory) {
        return false;
      }
    }
    return true;
  }

  static Future<String> shaOf(String path) async => (await crypto.sha256.bind(File(path).openRead()).first).toString();

  ({int size, int modified})? _stat(String path) {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return null;
      final s = File(path).statSync();
      return (size: s.size, modified: s.modified.millisecondsSinceEpoch);
    } catch (_) {
      return null;
    }
  }

  int _n = 0;

  /// Brings [f] down to [to] (a full local path): copied to a temporary name beside it, checked, then renamed. Where
  /// [replacing] is given, the file there must still be exactly that, or nothing is written. Where it is null, there
  /// must be no file there.
  Future<({int size, int modified})> _bring(DriveFile f, String to, {({int size, int modified})? replacing}) async {
    final from = await drive.fetch(f);
    final part = File('${File(to).parent.path}$_sep$partStart${now().microsecondsSinceEpoch}-${_n++}.part');
    try {
      await File(from).copy(part.path);
      if (part.lengthSync() != f.size) throw const SyncSkip('didn\'t come down whole');
      if (f.sha.isNotEmpty && (await shaOf(part.path)) != f.sha.toLowerCase()) throw const SyncSkip('didn\'t come down whole');
      final there = _stat(to);
      final type = FileSystemEntity.typeSync(to, followLinks: false);
      if (replacing == null ? type != FileSystemEntityType.notFound : (there == null || there.size != replacing.size || there.modified != replacing.modified)) {
        throw const SyncSkip('changed while syncing');
      }
      try {
        part.renameSync(to);
      } on FileSystemException {
        throw const SyncSkip('in use');
      }
      return _stat(to)!;
    } finally {
      // Only ever the pass's own temporary file.
      try {
        if (part.existsSync()) part.deleteSync();
      } catch (_) {}
    }
  }

  /// A name beside [path] not taken: "lease (from My files).pdf", then "(from My files 2)".
  String? _beside(String path) {
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1), name = path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name, end = dot > 0 ? name.substring(dot) : '';
    for (var n = 1; n <= 50; n++) {
      final mark = n == 1 ? this.mark : '${this.mark.substring(0, this.mark.length - 1)} $n)';
      final p = '$dir$stem$mark$end';
      if (holdable('$stem$mark$end') && FileSystemEntity.typeSync(_local(p), followLinks: false) == FileSystemEntityType.notFound) return p;
    }
    return null;
  }

  /// A path in [binName] for [path] not taken: "Trip/plan.md", then "Trip/plan (2).md".
  String? _binPath(String path) {
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1), name = path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name, end = dot > 0 ? name.substring(dot) : '';
    for (var n = 1; n <= 100; n++) {
      final p = '$binName/$dir$stem${n == 1 ? '' : ' ($n)'}$end';
      if (FileSystemEntity.typeSync(_local(p), followLinks: false) == FileSystemEntityType.notFound) return p;
    }
    return null;
  }

  /// Moves the local file at [path] into [binName], where it is still exactly [l]. Never deletes it.
  void _setAside(String path, ({int size, int modified}) l) {
    final there = _stat(_local(path));
    if (there == null || there.size != l.size || there.modified != l.modified) throw const SyncSkip('changed while syncing');
    final to = _binPath(path);
    if (to == null) throw const SyncSkip('with too many removed copies kept');
    if (!_makeParents(to)) throw const SyncSkip('under a link');
    try {
      File(_local(path)).renameSync(_local(to));
    } on FileSystemException {
      throw const SyncSkip('in use');
    }
  }

  /// One pass. Never throws.
  Future<SyncReport> run() async {
    final r = SyncReport();
    try {
      await _run(r);
    } on SyncStop catch (e) {
      r.stopped = e.why;
    } catch (e) {
      r.stopped = 'something went wrong ($e)';
    }
    return r;
  }

  Future<void> _run(SyncReport r) async {
    if (FileSystemEntity.typeSync(root, followLinks: false) != FileSystemEntityType.directory) throw const SyncStop('the folder isn\'t there any more.');
    final listed = await drive.list();
    if (listed == null) throw SyncStop('$driveName can\'t be reached right now.');
    state.load();
    // Kept, as the person said: as never synced, so each goes up or comes down again.
    for (final p in forget) {
      state.entries.remove(p);
    }
    final local = _walk(r);
    // A folder in it that couldn't be read: its files look gone, so nothing is removed from the drive this pass.
    final unread = r.skipped.containsKey('can\'t be read');
    final lower = {for (final p in local.keys) p.toLowerCase(): p};

    // Each record learns when its drive file was added, where it was kept by a build from before that time was kept.
    final byId = {for (final f in listed) f.id: f};
    for (final e in state.entries.entries) {
      final f = byId[e.value.id];
      if (f != null && f.path == e.key) e.value.at = f.at;
    }

    // The drive's newest file of each path; a path the folder can't hold, or that differs from another only by
    // capitals, is left out. So is a copy no newer than the one the sync last had at the path, and not it: one an
    // older build sent beside it, or one left when the newer was removed ([stale]).
    final remote = <String, DriveFile>{};
    final refused = <String>{};
    final stale = <String>{};
    for (final f in listed) {
      if (!_safe(f.path)) {
        if (refused.add(f.path)) r.skip('with a name this computer can\'t hold');
        continue;
      }
      final s = state.entries[f.path];
      if (s != null && s.at >= 0 && f.id != s.id && f.at <= s.at) {
        stale.add(f.path);
        continue;
      }
      final had = remote[f.path];
      if (had == null || f.at > had.at || (f.at == had.at && f.id.compareTo(had.id) > 0)) remote[f.path] = f;
    }
    final clash = <String>{};
    final seen = <String, String>{};
    for (final p in remote.keys.toList()..sort()) {
      final l = p.toLowerCase();
      final same = lower[l] ?? seen[l];
      if (same != null && same != p) {
        clash.add(p);
        r.skip('with a name that differs only by capitals');
      } else {
        seen[l] = p;
      }
    }

    // What to do with each path, before anything moves.
    final paths = {...local.keys, ...remote.keys}.toList()..sort();
    final todo = <(String, String)>[];
    // Removed from the folder, with the drive's still the one recorded; and removed from the drive, with the local one
    // as recorded (its content is checked when it is moved).
    final goneHere = <String>[], goneThere = <String>[];
    for (final p in paths) {
      if (clash.contains(p)) continue;
      final l = local[p], d = remote[p], s = state.entries[p];
      if (l != null && d == null && remote.keys.any((k) => k != p && k.toLowerCase() == p.toLowerCase())) continue;
      final synced = s != null && s.id.isNotEmpty;
      final localChanged = l != null && (s == null || s.size != l.size || s.modified != l.modified);
      final driveChanged = d != null && (s == null || s.id != d.id);
      if (l != null && d == null) {
        // Gone from the drive and unchanged here: moved aside here. New here, or changed since: it goes up.
        if (synced && !localChanged) {
          goneThere.add(p);
        } else {
          todo.add((p, 'up'));
        }
      } else if (l == null && d != null) {
        // Something there the walk left out (still being written, a folder, a link) is left alone.
        if (FileSystemEntity.typeSync(_local(p), followLinks: false) != FileSystemEntityType.notFound) continue;
        if (synced && !driveChanged) {
          // Gone from here and unchanged in the drive: removed there too; never where part of the folder couldn't be
          // read.
          if (!unread) goneHere.add(p);
        } else {
          // New in the drive, or changed there since it went from here: it comes down. Never onto a folder of the name.
          todo.add((p, 'down'));
        }
      } else if (l != null && d != null) {
        if (!localChanged && !driveChanged) continue;
        if (localChanged && !driveChanged) {
          todo.add((p, 'up'));
        } else if (!localChanged && driveChanged && s != null && s.sha.isNotEmpty) {
          todo.add((p, 'replace'));
        } else {
          todo.add((p, 'both'));
        }
      }
    }
    // Too many gone at once (a drive unplugged, a folder moved or emptied): held, and nothing done to them, until the
    // person says. Those they said yes to go whatever the count.
    final inStep = state.entries.values.where((e) => e.id.isNotEmpty).length;
    bool tooMany(int n) => n > holdOver || (n > 3 && n * 2 > inStep);
    for (final (gone, held) in [(goneHere, r.heldHere), (goneThere, r.heldThere)]) {
      final asked = [for (final p in gone) if (!allow.contains(p)) p];
      if (tooMany(asked.length)) {
        held.addAll(asked);
        gone.removeWhere((p) => !allow.contains(p));
      }
    }
    todo.addAll([for (final p in goneHere) (p, 'delete there'), for (final p in goneThere) (p, 'remove here')]);
    // Paths gone from both sides are forgotten; but a record that keeps an older copy in the drive from coming down
    // stays while that copy is there.
    state.entries.removeWhere((p, _) => !local.containsKey(p) && !remote.containsKey(p) && !stale.contains(p) && FileSystemEntity.typeSync(_local(p), followLinks: false) == FileSystemEntityType.notFound);

    var free = drive.free;
    var left = todo.length;
    progress?.call(left);
    var moved = 0;

    // The drive's [old] removed now that the newer of its path is up; where it can't be, both stay and the pass goes on.
    Future<void> replaced(DriveFile old) async {
      try {
        if (!await drive.delete(old)) r.skip('whose older copy in $driveName isn\'t yours to remove');
      } on SyncSkip catch (e) {
        r.skip(e.why);
      } on SyncStop {
        r.skip('whose older copy in $driveName couldn\'t be removed yet');
      }
    }

    // The drive's file the sync last had at [p] ([oldId]), where a newer one of the path has taken its place and it is
    // still there (sent beside it by a build from before the replace): removed too, as the sync had it in step.
    Future<void> retire(String p, String? oldId, String newId) async {
      final old = oldId == null || oldId.isEmpty || oldId == newId ? null : byId[oldId];
      if (old != null && old.path == p) await replaced(old);
    }

    Future<void> up(String p, ({int size, int modified}) l, {String? kept, DriveFile? replaces}) async {
      if (drive.maxFile > 0 && l.size > drive.maxFile) throw SyncSkip('too big (over ${fileSize(drive.maxFile)})');
      if (free != null && l.size > free!) throw SyncSkip('with no room left in $driveName');
      final slash = p.lastIndexOf('/');
      final folder = slash < 0 ? null : p.substring(0, slash);
      if (!holdableFolder(folder)) throw SyncSkip('with a name $driveName can\'t hold');
      final f = await drive.upload(_local(p), folder, p.substring(slash + 1));
      // The same file as when it was looked at, or it is not recorded and the next pass looks again.
      final after = _stat(_local(p));
      if (after == null || after.size != l.size || after.modified != l.modified) throw const SyncSkip('changed while syncing');
      if (free != null) free = free! - l.size;
      state.entries[p] = SyncEntry(size: l.size, modified: l.modified, id: f?.id ?? '', sha: (f != null && f.sha.isNotEmpty) ? f.sha.toLowerCase() : await shaOf(_local(p)), kept: kept, at: f?.at ?? -1);
      r.up++;
      // Only once the newer is known to be there.
      if (replaces != null && f != null && f.id != replaces.id) {
        state.save(root);
        await replaced(replaces);
      }
    }

    for (final (p, what) in todo) {
      if (stopped?.call() ?? false) throw const SyncStop('stopped.');
      if (moved >= most) {
        r.capped = true;
        break;
      }
      final l = local[p], d = remote[p], s = state.entries[p];
      try {
        switch (what) {
          case 'up':
            // Its time changed but not what is in it: in step, with nothing sent.
            if (d != null && s != null && s.id == d.id && s.sha.isNotEmpty && l!.size == s.size && (await shaOf(_local(p))) == s.sha) {
              state.entries[p] = SyncEntry(size: l.size, modified: l.modified, id: s.id, sha: s.sha, kept: s.kept, at: d.at);
              break;
            }
            // Changed here, with the drive's the one recorded: the newer replaces it.
            await up(p, l!, replaces: d != null && s != null && s.id == d.id ? d : null);
            moved++;
          case 'down':
            if (!_makeParents(p)) throw const SyncSkip('under a link');
            final got = await _bring(d!, _local(p));
            state.entries[p] = SyncEntry(size: got.size, modified: got.modified, id: d.id, sha: d.sha.isNotEmpty ? d.sha.toLowerCase() : await shaOf(_local(p)), at: d.at);
            r.down++;
            moved++;
            await retire(p, s?.id, d.id);
          case 'replace':
            // The local file is replaced only where its content is the one recorded; else both are kept.
            if ((await shaOf(_local(p))) != s!.sha) continue both;
            final got = await _bring(d!, _local(p), replacing: l);
            state.entries[p] = SyncEntry(size: got.size, modified: got.modified, id: d.id, sha: d.sha.isNotEmpty ? d.sha.toLowerCase() : await shaOf(_local(p)), at: d.at);
            r.down++;
            moved++;
            await retire(p, s.id, d.id);
          both:
          case 'both':
            // The same content on both sides is in step, with nothing moved.
            if (l!.size == d!.size && d.sha.isNotEmpty && (await shaOf(_local(p))) == d.sha.toLowerCase()) {
              state.entries[p] = SyncEntry(size: l.size, modified: l.modified, id: d.id, sha: d.sha.toLowerCase(), at: d.at);
              break;
            }
            // Both are kept: the drive's beside the local one (once), and the local one goes up as the newest.
            final wasSynced = s != null && s.id.isNotEmpty, oldId = s?.id;
            if (s?.kept != d.id) {
              final beside = _beside(p);
              if (beside == null) throw const SyncSkip('with too many copies beside it');
              await _bring(d, _local(beside));
              state.entries[p] = (s ?? SyncEntry())..kept = d.id;
              state.save(root);
              r.both++;
              r.down++;
            }
            // Where the path was in step before, the drive's (kept beside here, and up from there next pass) is
            // replaced; one the sync never had is left in the drive.
            await up(p, l, kept: d.id, replaces: wasSynced ? d : null);
            moved++;
            if (wasSynced) await retire(p, oldId, d.id);
          case 'delete there':
            if (await drive.delete(d!)) {
              // Remembered as removed, so an older copy of it in the drive never comes down.
              state.entries[p] = SyncEntry(at: math.max(d.at, s?.at ?? -1));
              r.deletedThere++;
            } else {
              // Not this device's to remove (someone else's, in a space): as never synced, so it comes down again.
              state.entries.remove(p);
              r.skip('that aren\'t yours to remove from $driveName, so they come back');
            }
            moved++;
          case 'remove here':
            // Its content is checked first: changed without its size or time showing it, it goes up instead.
            if (s!.sha.isEmpty || (await shaOf(_local(p))) != s.sha) {
              await up(p, l!);
              moved++;
              break;
            }
            _setAside(p, l!);
            state.entries[p] = SyncEntry(at: s.at);
            r.removedHere++;
            moved++;
        }
        state.save(root);
      } on SyncSkip catch (e) {
        r.skip(e.why);
      } on FileSystemException {
        r.skip('can\'t be read or written');
      }
      progress?.call(--left);
    }
    state.save(root);
  }
}

/// The app's drive behind [SyncDrive]: My files in the files store, or a Files space in it ([name] says which).
class StoreDrive implements SyncDrive {
  StoreDrive(this.store, this.channel, {this.tick = const Duration(milliseconds: 250), this.name = Drive.name});
  final FilesStore store;
  final VoiceChannel channel;
  final String name;
  final Duration tick;
  final Map<String, SpaceFile> _files = {};

  @override
  String get id => FileSeal.filesRoom(channel.seed);

  static String _pathOf(SpaceFile f) => f.folder == null ? f.name : '${f.folder}/${f.name}';
  DriveFile _of(SpaceFile f) {
    _files[f.id] = f;
    return DriveFile(id: f.id, path: _pathOf(f), size: f.size, sha: f.sha.toLowerCase(), at: f.at);
  }

  @override
  Future<List<DriveFile>?> list() async {
    final s = store.of(channel);
    try {
      await s.refresh();
    } catch (_) {
      return null;
    }
    if (s.error != null) return null;
    return [for (final f in s.files.values) _of(f)];
  }

  @override
  int get maxFile {
    final i = store.of(channel).info;
    // What is sealed is a little more than the file: a margin for it.
    return i == null || i.maxFile <= 0 ? 0 : math.max(0, i.maxFile - (i.maxFile >> 10) - 4096);
  }

  @override
  int? get free {
    final i = store.of(channel).info;
    if (i == null || i.quota <= 0) return null;
    return math.max(0, i.quota - i.used - ((i.quota - i.used) >> 10) - 4096);
  }

  @override
  Future<DriveFile?> upload(String local, String? folder, String name) async {
    // One already going up from before (the store keeps its queue over a restart) is waited for, not sent twice.
    var t = store.transfers.where((t) => t.up && !t.chat && t.path == local && t.space.seed == channel.seed && (t.state == TransferState.queued || t.state == TransferState.running)).firstOrNull;
    if (t == null) {
      final before = store.transfers.length;
      store.upload(channel, [local], folder: folder);
      if (store.transfers.length == before) throw const SyncSkip('can\'t be read or written');
      t = store.transfers.last;
    }
    while (t.state == TransferState.queued || t.state == TransferState.running) {
      await Future<void>.delayed(tick);
    }
    if (t.state != TransferState.done) {
      final why = t.error ?? '';
      final waiting = t.state == TransferState.waiting;
      // Not left in the page's list as a failure to try again by hand: the next pass tries it.
      await store.cancel(t);
      if (waiting) throw SyncStop('$name can\'t be reached right now.');
      if (why.startsWith('Too big')) throw const SyncSkip('too big');
      if (why.startsWith('Not enough room')) throw SyncSkip('with no room left in $name');
      throw const SyncSkip('that didn\'t go up');
    }
    SpaceFile? find() {
      final same = [for (final f in store.of(channel).files.values) if (f.name == name && f.folder == folder && (t!.sha == null || f.sha.isEmpty || f.sha == t.sha)) f]..sort((a, b) => b.at.compareTo(a.at));
      return same.firstOrNull;
    }

    var f = find();
    if (f == null) {
      try {
        await store.of(channel).refresh();
      } catch (_) {}
      f = find();
    }
    return f == null ? null : _of(f);
  }

  @override
  Future<String> fetch(DriveFile f) async {
    final file = _files[f.id];
    if (file == null) throw const SyncSkip('that didn\'t come down');
    try {
      return await store.fetch(channel, file);
    } catch (_) {
      throw const SyncSkip('that didn\'t come down');
    }
  }

  /// With the log's own `del` entry (FilesStore.delete), which every build reads, and the blob let go.
  @override
  Future<bool> delete(DriveFile f) async {
    final file = store.of(channel).files[f.id] ?? _files[f.id];
    // Gone already (removed elsewhere meanwhile): what was wanted.
    if (file == null || !store.of(channel).files.containsKey(f.id)) return true;
    if (!store.canChange(channel, file)) return false;
    if (await store.delete(channel, file)) return true;
    throw SyncSkip('that couldn\'t be removed from $name right now');
  }
}

/// Watches a drive for files added or removed from somewhere else, telling [changed] each time, until what it answers
/// is called; null where there is nothing to watch yet (no account, a space not on this computer).
typedef DriveWatch = Future<void Function()?> Function(void Function() changed);

/// One of this computer's synced folders, My files' or a Files space's: which it is, what its state line says, and
/// when a pass runs (on choosing, when its page is opened, every few minutes while the app is open, and as soon as the
/// drive's files change elsewhere: GMFB-74, @kevin, "When a file is added to the server, for it to sync with the folder
/// on my desktop I have to open the folder in the server to nudge the app to sync it").
class FolderSync extends ChangeNotifier {
  FolderSync({Directory Function()? data, Future<SyncDrive?> Function()? drive, String? Function()? home, List<String> Function()? own, DriveWatch? watch, this.every = const Duration(minutes: 4), this.quiet = const Duration(seconds: 5), this.settle = const Duration(seconds: 1), this.space, this.driveName = Drive.name})
      : assert(space == null || RegExp(r'^[0-9A-Za-z_-]{1,128}$').hasMatch(space)),
        _data = data ?? (() => Directory('${DeskStore.defaultDir().path}${PlatformInfo.pathSeparator}folder-sync')),
        // The app's own drives are watched in the app's own store; a drive given (a test's) only where a watch is too.
        _watch = watch ?? (drive != null ? null : (changed) => _storeWatch(space == null ? Drive.mine : () async => _spaceChannel(space), changed)),
        _drive = drive ?? (space == null ? _appDrive : () => _spaceDrive(space)),
        _home = home ?? (() => PlatformInfo.environment['USERPROFILE'] ?? PlatformInfo.environment['HOME']),
        _own = own;

  /// Off hides the entry and runs nothing (GMFB-38 shipped without a device test: one switch to take it out).
  static const enabled = true;

  /// Whether folders are synced here at all: a computer's app, never a phone or a browser.
  static bool get here => enabled && !kIsWeb && (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux);

  /// My files' own.
  static final FolderSync instance = FolderSync();

  /// Which Files space this is the folder of, as the relay names its files' room (never its seed: this is a file's
  /// name, [_choice]); null for My files, whose choice stays where it was before spaces had folders.
  final String? space;

  /// What the drive is called in the words: My files, or the space's name.
  final String driveName;

  static final Map<String, FolderSync> _spaces = {};

  /// The folder of the Files space [c] (GMFB-38: "a Files space or the personal drive"): one for each space, kept
  /// apart from My files' and from every other space's.
  static FolderSync forSpace(VoiceChannel c) => _spaces.putIfAbsent(FileSeal.filesRoom(c.seed), () => FolderSync(space: FileSeal.filesRoom(c.seed), driveName: c.name));

  static Future<SyncDrive?> _appDrive() async {
    final c = await Drive.mine();
    return c == null ? null : StoreDrive(FilesStore.instance, c);
  }

  /// The Files space the relay calls [space], where this device still has it; and only while it may add files there,
  /// since a pass sends up what is new in the folder.
  static Future<SyncDrive?> _spaceDrive(String space) async {
    final c = _spaceChannel(space);
    if (c == null) return null;
    if (!FilesStore.instance.canUpload(c)) throw const SyncStop('your role in this space can\'t add files.');
    return StoreDrive(FilesStore.instance, c, name: c.name);
  }

  /// The Files space the relay calls [space], where this device has it.
  static VoiceChannel? _spaceChannel(String space) => Voice.instance.channels.where((c) => c.kind == SpaceKind.files && FileSeal.filesRoom(c.seed) == space).firstOrNull;

  /// Watches the app's own store for [channel]'s list growing: the space is held open there, so it hears others say
  /// its log has grown and reads it again now and then (FilesStore.open), as its page does while it is shown.
  static Future<void Function()?> _storeWatch(Future<VoiceChannel?> Function() channel, void Function() changed) async {
    final c = await channel();
    if (c == null) return null;
    final store = FilesStore.instance;
    var seen = store.of(c).seq;
    void heard() {
      final now = store.of(c).seq;
      if (now == seen) return;
      seen = now;
      changed();
    }

    store.addListener(heard);
    unawaited(store.open(c).catchError((_) {}));
    return () {
      store.removeListener(heard);
      store.close(c);
    };
  }

  /// Every space's folder chosen on this computer before this run, from the choices kept ([_choice]).
  void _loadSpaces() {
    try {
      final dir = _data();
      if (!dir.existsSync()) return;
      for (final e in dir.listSync(followLinks: false)) {
        final m = RegExp(r'^space-([0-9A-Za-z_-]{1,128})\.json$').firstMatch(e.path.substring(e.path.lastIndexOf(PlatformInfo.pathSeparator) + 1));
        if (m == null || e is! File) continue;
        String name = 'the space';
        try {
          final j = jsonDecode(e.readAsStringSync());
          if (j is Map && j['name'] is String && (j['name'] as String).isNotEmpty) name = j['name'] as String;
        } catch (_) {}
        _spaces.putIfAbsent(m.group(1)!, () => FolderSync(space: m.group(1), driveName: name)).load();
      }
    } catch (_) {}
  }

  final Directory Function() _data;
  final Future<SyncDrive?> Function() _drive;
  final String? Function() _home;
  final List<String> Function()? _own;
  final DriveWatch? _watch;
  final Duration every, quiet;

  /// How long after the drive changes elsewhere a pass begins: several changes close together are one pass.
  final Duration settle;

  /// The app's own folders: where it keeps things, and where it keeps what came down.
  List<String> _ownFolders() {
    final own = _own;
    if (own != null) return own();
    final home = PlatformInfo.environment['HOME'];
    return [DeskStore.defaultDir().path, _data().path, if (PlatformInfo.isMacOS && home != null) '$home/Library/Caches/Ghost Messaging'];
  }

  File get _choice => File('${_data().path}${PlatformInfo.pathSeparator}${space == null ? 'choice' : 'space-$space'}.json');

  /// The folders the other drives are synced with on this computer (My files' and each space's), from their choices.
  List<String> _others() {
    final out = <String>[];
    try {
      final dir = _data();
      if (!dir.existsSync()) return out;
      final mine = _choice.path;
      for (final e in dir.listSync(followLinks: false)) {
        final name = e.path.substring(e.path.lastIndexOf(PlatformInfo.pathSeparator) + 1);
        if (e is! File || e.path == mine || !(name == 'choice.json' || (name.startsWith('space-') && name.endsWith('.json')))) continue;
        try {
          final j = jsonDecode(e.readAsStringSync());
          if (j is Map && j['root'] is String && (j['root'] as String).isNotEmpty) out.add(j['root'] as String);
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Why the folder at [at] can't be this drive's because of another's; null where it can.
  String? _taken(String at) {
    for (final o in _others()) {
      if (FolderSyncEngine._within(at, o) || FolderSyncEngine._within(o, at)) return 'That folder, or one in or around it, is already synced with My files or another space. Choose another folder.';
    }
    return null;
  }

  /// The folder synced; null where none is.
  String? get root => _root;
  String? _root;

  /// The state line: "In step.", "Syncing 3 files", "Stopped: why".
  String get line => _line;
  String _line = '';

  bool get running => _running;
  bool _running = false;
  bool _loaded = false;
  Timer? _timer;
  int _gen = 0;

  /// What ends the watching of the drive, while it is watched; whether a watch is being set up; the pass a change
  /// waits for; and whether the drive changed while a pass ran, which then runs again.
  void Function()? _unwatch;
  bool _watching = false, _again = false;
  Timer? _soon;

  /// Watches the drive while a folder is chosen. Tried again at each pass until there is something to watch (the
  /// account signed in, the space come to this computer).
  Future<void> _ensureWatch() async {
    final watch = _watch;
    if (watch == null || _root == null || _unwatch != null || _watching) return;
    _watching = true;
    void Function()? end;
    try {
      end = await watch(_driveChanged);
    } catch (_) {
    } finally {
      _watching = false;
    }
    // Stopped, or watched already, while it was being set up.
    if (_root == null || _unwatch != null) return end?.call();
    _unwatch = end;
  }

  void _stopWatch() {
    _soon?.cancel();
    _soon = null;
    _again = false;
    _unwatch?.call();
    _unwatch = null;
  }

  /// The drive's files changed somewhere else: a pass soon, or after the one running (which may have listed the drive
  /// before the change).
  void _driveChanged() {
    if (_root == null) return;
    if (_running) {
      _again = true;
      return;
    }
    _soon?.cancel();
    _soon = Timer(settle, () => unawaited(pass()));
  }

  /// The last pass's report, for a test.
  SyncReport? last;

  /// Files gone from the folder whose removal from the drive waits for the person, and files gone from the drive whose
  /// removal here waits ([FolderSyncEngine.holdOver]): asked in the entry, answered with [removeHeld] or [keepHeld].
  List<String> get heldHere => _heldHere;
  List<String> get heldThere => _heldThere;
  List<String> _heldHere = const [], _heldThere = const [];

  /// What the person said, for the next pass: paths to remove however many, and paths to keep (sent or brought again).
  final Set<String> _allow = {}, _forget = {};

  void _clearHeld() {
    _heldHere = const [];
    _heldThere = const [];
    _allow.clear();
    _forget.clear();
  }

  /// Yes to the removals held: each is removed on the other side too (a local file into the hidden ".ghost-deleted").
  Future<void> removeHeld() {
    _allow.addAll([..._heldHere, ..._heldThere]);
    _heldHere = const [];
    _heldThere = const [];
    notifyListeners();
    return pass();
  }

  /// No to the removals held: each is put back from the other side, as if never synced.
  Future<void> keepHeld() {
    _forget.addAll([..._heldHere, ..._heldThere]);
    _heldHere = const [];
    _heldThere = const [];
    notifyListeners();
    return pass();
  }

  void load() {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = jsonDecode(_choice.readAsStringSync());
      if (j is Map && j['root'] is String && (j['root'] as String).isNotEmpty) _root = j['root'] as String;
    } catch (_) {}
  }

  void _save() {
    try {
      _choice.parent.createSync(recursive: true);
      _choice.writeAsStringSync(jsonEncode({'root': _root ?? '', if (space != null) 'name': driveName}), flush: true);
    } catch (_) {}
  }

  /// Reads the choice and runs a pass every few minutes while the app is open. Asked of My files' own, it does the
  /// same for every space's folder, one after another.
  void start() {
    if (!here) return;
    load();
    if (identical(this, instance)) _loadSpaces();
    // Watched from the start, so what changed while the app was closed, and what changes from now, is a pass at once.
    unawaited(_ensureWatch());
    if (identical(this, instance)) {
      for (final s in _spaces.values.toList()) {
        unawaited(s._ensureWatch());
      }
    }
    _timer ??= Timer.periodic(every, (_) => unawaited(() async {
          await pass();
          if (!identical(this, instance)) return;
          for (final s in _spaces.values.toList()) {
            await s.pass();
          }
        }()));
  }

  /// Syncs the folder at [path] from now on: why not, in words, or null where it is taken (and a pass begins).
  String? choose(String path) {
    load();
    final at = FolderSyncEngine.resolve(path);
    if (at == null) return 'That folder isn\'t there.';
    final why = FolderSyncEngine.whyNot(at, home: _home(), own: _ownFolders());
    if (why != null) return why;
    final taken = _taken(at);
    if (taken != null) return taken;
    _gen++;
    _root = at;
    _line = '';
    _clearHeld();
    _save();
    notifyListeners();
    unawaited(pass());
    return null;
  }

  /// Stops syncing. Nothing is removed from the folder or from the drive.
  void stop() {
    _gen++;
    _stopWatch();
    _root = null;
    _line = '';
    _clearHeld();
    _save();
    notifyListeners();
  }

  void _say(String line) {
    if (_line == line) return;
    _line = line;
    notifyListeners();
  }

  /// One pass, where a folder is chosen and none is running. Quiet where no account is signed in.
  Future<void> pass() async {
    load();
    final root = _root;
    if (root == null || _running) return;
    final gen = _gen;
    _running = true;
    _soon?.cancel();
    notifyListeners();
    unawaited(_ensureWatch());
    try {
      // Looked at again each pass: what was fine to sync when chosen may have been moved or become the home folder.
      if (FolderSyncEngine.resolve(root) != root) return _say('Stopped: the folder isn\'t there any more.');
      if (FolderSyncEngine.whyNot(root, home: _home(), own: _ownFolders()) != null) return _say('Stopped: this folder can\'t be synced.');
      // Two drives never share a folder, however the choices came to be (a file put there by hand).
      if (_taken(root) != null) return _say('Stopped: this folder is synced with My files or another space too.');
      final SyncDrive? drive;
      try {
        drive = await _drive();
      } on SyncStop catch (e) {
        return _say('Stopped: ${e.why}');
      } catch (_) {
        return _say('Stopped: $driveName can\'t be reached right now.');
      }
      if (drive == null) return _say(space == null ? 'Stopped: sign in to your Uplink account on this computer.' : 'Stopped: this space isn\'t on this computer any more.');
      final key = crypto.sha256.convert(utf8.encode('${drive.id}\n$root')).toString().substring(0, 32);
      // What the person said is for this pass alone; anything gone since is asked again.
      final allow = {..._allow}, forget = {..._forget};
      final engine = FolderSyncEngine(
        root: root,
        drive: drive,
        state: SyncState(File('${_data().path}${PlatformInfo.pathSeparator}$key.json')),
        quiet: quiet,
        driveName: driveName,
        allow: allow,
        forget: forget,
        stopped: () => _gen != gen,
        progress: (left) {
          if (_gen == gen && left > 0) _say('Syncing $left ${left == 1 ? 'file' : 'files'}');
        },
      );
      final r = await engine.run();
      last = r;
      if (_gen == gen) {
        _allow.removeAll(allow);
        _forget.removeAll(forget);
        if (r.stopped == null) {
          _heldHere = List.unmodifiable(r.heldHere);
          _heldThere = List.unmodifiable(r.heldThere);
        }
        _say(r.line);
      }
    } finally {
      _running = false;
      notifyListeners();
      if (_again) {
        _again = false;
        _driveChanged();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stopWatch();
    super.dispose();
  }
}
