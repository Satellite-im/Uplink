import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// Something keyed, kept on disk as a log of what changed: a line for each change, appended as changes are put
/// together ([flush]), so the whole is never written on the event loop; now and then written whole again (compacted),
/// in an isolate, off the event loop (found in the second review, 2026-11-23: `hub-v2.json` was rewritten whole within
/// two seconds of any change, 7 MB and 47 ms of the event loop at 200,000 keys, and `homes.json` could reach 22 MB).
///
/// Each line is JSON: `{"s": key, "x": value}` sets a key, last of all; `{"d": key}` takes it away. Read back, the last
/// line for each key stands, in the order last set. A file of the kind written before (one JSON object, written whole)
/// is read by [load]'s `whole`, and written as a log from the next [flush].
class KeptLog {
  KeptLog(this.file, {this.compactPast = 10000});

  /// The log; `<file>.tmp` beside it is what a whole rewrite is written to before it takes the log's place.
  final File file;

  /// How many lines past those that stand before the log is compacted (and never while one is under way).
  final int compactPast;

  /// The lines not written yet; how many lines the file has and how many keys stand; whether the file must be written
  /// anew (it couldn't be read, or is of the old kind); the compaction under way; and the last write, which every
  /// write waits behind so they reach the file in order.
  final List<String> _pending = [];
  int _lines = 0, _standing = 0;
  bool _rewrite = false;
  Future<void>? _compacting;
  Future<void> _writing = Future.value();

  /// Whether changes wait to be written.
  bool get dirty => _pending.isNotEmpty || _rewrite;

  /// Reads what is kept, in order; [whole] reads a file of the kind written before (one JSON object), where there is
  /// one. A file that can't be read is started again from nothing (and written anew from the next [flush]).
  LinkedHashMap<String, Object?> load({Iterable<MapEntry<String, Object?>> Function(Map whole)? whole}) {
    final out = LinkedHashMap<String, Object?>();
    _lines = 0;
    if (!file.existsSync()) return out;
    String text;
    try {
      text = file.readAsStringSync();
    } catch (_) {
      _rewrite = true;
      return out;
    }
    // One JSON object and no second line, with neither of a log line's keys: a file of the kind written before.
    final trimmed = text.trimLeft();
    if (whole != null && trimmed.startsWith('{') && !trimmed.contains('\n{')) {
      try {
        final all = jsonDecode(trimmed);
        if (all is Map && !all.containsKey('s') && !all.containsKey('d')) {
          out.addEntries(whole(all));
          _rewrite = true;
          _standing = out.length;
          return out;
        }
      } catch (_) {}
    }
    replay(text, out);
    _lines = '\n'.allMatches(text).length;
    _standing = out.length;
    return out;
  }

  /// Plays the lines of [text] into [into]; a line that isn't one is passed over.
  static void replay(String text, Map<String, Object?> into) {
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) continue;
      try {
        final m = jsonDecode(line);
        if (m is! Map) continue;
        final s = m['s'], d = m['d'];
        if (s is String) {
          into.remove(s);
          into[s] = m['x'];
        } else if (d is String) {
          into.remove(d);
        }
      } catch (_) {}
    }
  }

  /// [key] is now [value], last of all.
  void set(String key, Object? value) {
    _pending.add(jsonEncode({'s': key, 'x': value}));
  }

  /// [key] is kept no more.
  void remove(String key) {
    _pending.add(jsonEncode({'d': key}));
  }

  /// Writes what changed since: appended, off the event loop (the write is the platform's; what is said is a line a
  /// change). [standing] is how many keys there are now, so the log can be compacted once it has grown far past
  /// them; [all] gives them, for a file that must be written anew (one that couldn't be read, or of the old kind).
  Future<void> flush({required int standing, Map<String, Object?> Function()? all}) {
    _standing = standing;
    if (_compacting != null) return _compacting!;
    if (_rewrite && all != null) {
      _rewrite = false;
      _pending.clear();
      final lines = [for (final e in all().entries) jsonEncode({'s': e.key, 'x': e.value})];
      return _writing = _writing.then((_) => _writeWhole(lines));
    }
    if (_pending.isEmpty) return _writing;
    final text = '${_pending.join('\n')}\n';
    _lines += _pending.length;
    _pending.clear();
    _writing = _writing.then((_) async {
      try {
        file.parent.createSync(recursive: true);
        await file.writeAsString(text, mode: FileMode.append, flush: true);
      } catch (e) {
        stderr.writeln('relay: ${file.path} could not be written (${'$e'.split('\n').first})');
      }
    });
    if (_lines > _standing + compactPast) _compacting = _writing.then((_) => _compact());
    return _compacting ?? _writing;
  }

  /// Writes what waits now, on this thread: for stopping, when nothing comes after.
  void flushNow({required int standing, Map<String, Object?> Function()? all}) {
    try {
      file.parent.createSync(recursive: true);
      if (_rewrite && all != null) {
        _rewrite = false;
        _pending.clear();
        final tmp = File('${file.path}.tmp')..writeAsStringSync([for (final e in all().entries) '${jsonEncode({'s': e.key, 'x': e.value})}\n'].join());
        tmp.renameSync(file.path);
        _lines = standing;
        return;
      }
      if (_pending.isEmpty) return;
      file.writeAsStringSync('${_pending.join('\n')}\n', mode: FileMode.append, flush: true);
      _lines += _pending.length;
      _pending.clear();
    } catch (e) {
      stderr.writeln('relay: ${file.path} could not be written (${'$e'.split('\n').first})');
    }
  }

  /// Writes the file anew as [lines], in an isolate: to `<file>.tmp`, which then takes the file's place.
  Future<void> _writeWhole(List<String> lines) async {
    final path = file.path;
    try {
      await Isolate.run(() {
        File(path).parent.createSync(recursive: true);
        final tmp = File('$path.tmp')..writeAsStringSync(lines.isEmpty ? '' : '${lines.join('\n')}\n');
        tmp.renameSync(path);
      });
      _lines = lines.length;
    } catch (e) {
      stderr.writeln('relay: $path could not be written (${'$e'.split('\n').first})');
    }
  }

  /// Writes the log again with a line for each key that stands, in an isolate: what changes meanwhile waits, and is
  /// appended after.
  Future<void> _compact() async {
    final path = file.path;
    try {
      final standing = await Isolate.run(() {
        final f = File(path);
        if (!f.existsSync()) return 0;
        final bytes = f.readAsBytesSync();
        final kept = LinkedHashMap<String, Object?>();
        replay(utf8.decode(bytes, allowMalformed: true), kept);
        final tmp = File('$path.tmp')..writeAsStringSync([for (final e in kept.entries) '${jsonEncode({'s': e.key, 'x': e.value})}\n'].join());
        // Anything appended meanwhile (written as the relay stopped) goes after, not lost.
        final now = f.lengthSync();
        if (now > bytes.length) {
          final raf = f.openSync()..setPositionSync(bytes.length);
          tmp.writeAsBytesSync(raf.readSync(now - bytes.length), mode: FileMode.append);
          raf.closeSync();
        }
        tmp.renameSync(path);
        return kept.length;
      });
      _lines = standing;
    } catch (e) {
      stderr.writeln('relay: $path could not be compacted (${'$e'.split('\n').first})');
    } finally {
      _compacting = null;
    }
    if (_pending.isNotEmpty) await flush(standing: _standing);
  }

  /// Lines in the file now, for a test.
  int get lines => _lines;
}
