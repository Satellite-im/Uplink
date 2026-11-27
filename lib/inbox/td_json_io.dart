import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import '../platform_info.dart';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'td_json.dart' show TdTransport;

/// TDLib's JSON client (libtdjson, built by tool/build-tdlib.sh), through its four C functions.
///
/// `td_receive` blocks, and TDLib aborts the whole process if it is ever called from two threads at once, so it is
/// called from ONE isolate for the life of the app ([_Receiver]), whatever clients come and go: each client takes
/// from it what carries its own "@client_id".
class TdJson implements TdTransport {
  TdJson._(this._lib, this._id, Stream<Map<String, Object?>> all) {
    _sub = all.listen((j) {
      if (j['@client_id'] == _id) _out.add(j);
    });
  }

  // The library, this client's number in it, and what TDLib says for this client alone.
  final DynamicLibrary _lib;
  final int _id;
  late final StreamSubscription<Map<String, Object?>> _sub;
  final _out = StreamController<Map<String, Object?>>.broadcast();
  late final _send = _lib.lookupFunction<Void Function(Int32, Pointer<Utf8>), void Function(int, Pointer<Utf8>)>('td_send');

  // The library once opened, and where it was found: the receiving isolate opens it again by that path.
  static String? _path;
  static DynamicLibrary? _opened;

  /// Where the library is: inside the app on a Mac (Contents/Frameworks), by name on Android (the APK's lib folder).
  static DynamicLibrary? open() {
    if (_opened != null) return _opened;
    final tries = <String>[
      if (PlatformInfo.isAndroid) 'libtdjson.so',
      if (PlatformInfo.isMacOS) ...[
        '${File(PlatformInfo.resolvedExecutable).parent.parent.path}/Frameworks/libtdjson.dylib',
        // A build run from the checkout (flutter run, flutter test), before the release puts it in the app.
        '${Directory.current.path}/build/tdlib/mac/libtdjson.dylib',
      ],
    ];
    for (final path in tries) {
      try {
        _opened = DynamicLibrary.open(path);
        _path = path;
        return _opened;
      } catch (_) {}
    }
    return null;
  }

  /// A new TDLib client, or null where the library is not in this build.
  static Future<TdJson?> start() async {
    final lib = open();
    if (lib == null) return null;
    final all = await _Receiver.start(lib, _path!);
    final create = lib.lookupFunction<Int32 Function(), int Function()>('td_create_client_id');
    return TdJson._(lib, create(), all);
  }

  @override
  Stream<Map<String, Object?>> get received => _out.stream;

  @override
  void send(Map<String, Object?> request) {
    final s = jsonEncode(request).toNativeUtf8();
    _send(_id, s);
    malloc.free(s);
  }

  @override
  void close() {
    send({'@type': 'close'});
    // What it says while closing (to authorizationStateClosed) is still let through a while.
    Future<void>.delayed(const Duration(seconds: 5), () {
      _sub.cancel();
      _out.close();
    });
  }
}

/// The one isolate that calls `td_receive`, a second at a time, for as long as the app runs.
class _Receiver {
  static Future<Stream<Map<String, Object?>>>? _started;

  /// Everything TDLib says, for every client: the isolate is started at the first asking and the same stream handed
  /// back after.
  static Future<Stream<Map<String, Object?>>> start(DynamicLibrary lib, String path) => _started ??= () async {
        final execute = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>('td_execute');
        // TDLib's own log, kept to errors: it writes to stderr otherwise.
        final quiet = jsonEncode({'@type': 'setLogVerbosityLevel', 'new_verbosity_level': 1}).toNativeUtf8();
        execute(quiet);
        malloc.free(quiet);
        final port = ReceivePort();
        final out = StreamController<Map<String, Object?>>.broadcast();
        // What TDLib says is read (JSON) in the receiving isolate, not here: thousands of updates as it starts were
        // each parsed on the thread that draws (docs/performance-audit.md, finding 2). A map comes across as it is.
        port.listen((m) {
          if (m is Map<String, Object?>) out.add(m);
        });
        await Isolate.spawn(_loop, (port.sendPort, path), debugName: 'tdlib');
        return out.stream;
      }();

  /// The isolate's body: waits up to a second for the next thing TDLib says, reads it and sends it across, for ever.
  static void _loop((SendPort, String) args) {
    final (out, path) = args;
    final lib = DynamicLibrary.open(path);
    final receive = lib.lookupFunction<Pointer<Utf8> Function(Double), Pointer<Utf8> Function(double)>('td_receive');
    while (true) {
      final r = receive(1.0);
      if (r == nullptr) continue;
      try {
        final j = jsonDecode(r.toDartString());
        if (j is Map<String, Object?>) out.send(j);
      } catch (_) {}
    }
  }
}
