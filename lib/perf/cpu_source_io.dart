import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../platform_info.dart';
import 'cpu_reading.dart';

typedef _GetrusageC = Int32 Function(Int32 who, Pointer<Uint8> usage);
typedef _Getrusage = int Function(int who, Pointer<Uint8> usage);

/// On a Mac, an iPhone, Linux and Android: `getrusage` for the whole app, and on the last two `/proc/self/task` for
/// each thread. Windows has no `getrusage`, and nothing is asked of it yet.
class IoCpuSource implements CpuSource {
  IoCpuSource() {
    if (!(PlatformInfo.isMacOS || PlatformInfo.isIOS || PlatformInfo.isLinux || PlatformInfo.isAndroid)) return;
    try {
      _getrusage = DynamicLibrary.process().lookupFunction<_GetrusageC, _Getrusage>('getrusage');
      // A `struct rusage` is 144 bytes on each of these; room to spare.
      _usage = calloc<Uint8>(288);
    } catch (_) {
      _getrusage = null;
    }
  }

  _Getrusage? _getrusage;
  Pointer<Uint8>? _usage;

  @override
  Duration? used() {
    final ask = _getrusage, usage = _usage;
    if (ask == null || usage == null) return null;
    try {
      // RUSAGE_SELF is 0 everywhere. The structure begins with the time spent in the app's own code and the time the
      // system spent for it, each a count of seconds (64 bits) and of microseconds (the low 32 bits are read, which
      // hold it whether the system keeps it in 32 or 64).
      if (ask(0, usage) != 0) return null;
      final bytes = usage.asTypedList(32);
      final d = ByteData.sublistView(bytes);
      final micros = (d.getInt64(0, Endian.host) + d.getInt64(16, Endian.host)) * 1000000 + d.getInt32(8, Endian.host) + d.getInt32(24, Endian.host);
      return Duration(microseconds: micros);
    } catch (_) {
      return null;
    }
  }

  @override
  Map<String, Duration>? threads() {
    if (!(PlatformInfo.isAndroid || PlatformInfo.isLinux)) return null;
    try {
      final out = <String, Duration>{};
      for (final task in Directory('/proc/self/task').listSync(followLinks: false)) {
        final String line;
        try {
          line = File('${task.path}/stat').readAsStringSync();
        } catch (_) {
          // A thread that ended between the listing and the reading.
          continue;
        }
        final timed = threadTime(line);
        if (timed == null) continue;
        out[timed.name] = (out[timed.name] ?? Duration.zero) + timed.used;
        // The programs this thread started and that still run (a network's helper is a program of its own, and what it
        // spends is not in the app's own count): each as "helper <name>", where the system lists them.
        try {
          for (final pid in File('${task.path}/children').readAsStringSync().trim().split(RegExp(r'\s+'))) {
            if (pid.isEmpty) continue;
            final helper = threadTime(File('/proc/$pid/stat').readAsStringSync());
            if (helper != null) out['helper ${helper.name}'] = (out['helper ${helper.name}'] ?? Duration.zero) + helper.used;
          }
        } catch (_) {
          // This system does not list them, or one ended meanwhile.
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  @override
  int? memory() {
    try {
      return ProcessInfo.currentRss;
    } catch (_) {
      return null;
    }
  }
}

/// This device's own.
CpuSource makeCpuSource() => IoCpuSource();
