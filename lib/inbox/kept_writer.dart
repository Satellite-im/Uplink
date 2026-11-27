import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../aside.dart';

/// Keeps a network's chats in its file without holding up the screen (docs/performance-audit.md, finding 4).
///
/// Signal, WhatsApp and Matrix each keep every chat and every message in one file, and each used to write the whole
/// of it, as JSON, on the thread that draws, 400 ms after every message, receipt, reaction or name: a pause that
/// grew with the history, several times a second while chatting. Here what is to be kept is handed to another
/// isolate, which makes the JSON and writes the file; a run of changes is one write, [wait] after the last (and no
/// longer than [most] after the first, so a steady stream still reaches the file).
///
/// The file is written beside itself and moved into place, so it is whole or the one before. [flush] writes at once
/// on the calling thread, for the app going and for a test.
class KeptWriter {
  KeptWriter({required this.file, required this.snapshot, this.wait = const Duration(seconds: 2), this.most = const Duration(seconds: 10)});

  /// Where it is kept.
  final File Function() file;

  /// What is to be kept, as it stands when asked: maps, lists, strings, numbers, booleans and nulls only (JSON's, and
  /// what one isolate may hand another).
  final Object? Function() snapshot;

  /// How long after the last change it is written, and the longest a first change waits while more keep coming.
  final Duration wait;
  final Duration most;

  // The write to come, when the first change it holds was made, and the last write begun.
  Timer? _timer;
  DateTime? _since;
  Future<void> _last = Future<void>.value();

  /// Something changed: written soon.
  void save() {
    final now = DateTime.now();
    _since ??= now;
    _timer?.cancel();
    final left = most - now.difference(_since!);
    _timer = Timer(left < wait ? (left.isNegative ? Duration.zero : left) : wait, _go);
  }

  /// The wait is over: what is to be kept is taken as it stands now, and written on another isolate.
  void _go() {
    _timer = null;
    _since = null;
    final path = file().path;
    final Object? data;
    try {
      data = snapshot();
    } catch (_) {
      return;
    }
    // One write after another: a later one never lands before an earlier.
    _last = _last.then((_) => _elsewhere(path, data)).catchError((_) {
      // The other isolate could not be had (or the data not handed over): written here, as it always was.
      try {
        _put(path, data);
      } catch (_) {}
    });
  }

  // A function of its own, so what is handed to the other isolate is the path and the data and nothing of this object.
  static Future<void> _elsewhere(String path, Object? data) => runAside(() => _put(path, data));

  /// Writes [data] as JSON beside [path] and moves it into place.
  static void _put(String path, Object? data) {
    final at = File(path);
    at.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(jsonEncode(data));
    tmp.renameSync(path);
  }

  /// Whether a change waits to be written.
  bool get waiting => _timer?.isActive ?? false;

  /// Writes what waits now, here (the app going, a test's end). Nothing where nothing waits.
  void flush() {
    if (!waiting) return;
    _timer!.cancel();
    _timer = null;
    _since = null;
    try {
      _put(file().path, snapshot());
    } catch (_) {}
  }

  /// Once every write begun has ended (a test that reads the file after).
  Future<void> get settled => _last;

  /// Lets go of a change that waits, unwritten.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _since = null;
  }
}
