/// What the system can say of what the app is spending, for the Performance plugin (lib/perf/app_usage.dart). Who
/// reads it is chosen for the build (lib/perf/cpu_source.dart): a browser's can't.
library;

abstract class CpuSource {
  /// The processor time the whole app has used since it started, every thread of it together; null where this
  /// platform can't say (a browser, and Windows for now).
  Duration? used();

  /// The same for each thread, by the thread's name (threads of one name together), and for each program the app
  /// started that still runs, as `helper <name>` (a network's helper: what it spends is not in [used]); null where it
  /// can't be read: only Android and Linux say (`/proc/self/task`). It reads a small file a thread, so it is asked
  /// for seldom.
  Map<String, Duration>? threads();

  /// How much memory the app holds, in bytes; null where unknown.
  int? memory();
}

/// A thread's name and the processor time it has used, from its line in `/proc/<pid>/task/<tid>/stat`: the name is
/// between the first `(` and the last `)` (it may hold spaces and brackets of its own), and the 12th and 13th
/// numbers after it are its time in its own code and in the system's, in hundredths of a second. Null where the line
/// is not one.
({String name, Duration used})? threadTime(String line) {
  final open = line.indexOf('('), close = line.lastIndexOf(')');
  if (open < 0 || close <= open) return null;
  final rest = line.substring(close + 1).trim().split(RegExp(r'\s+'));
  if (rest.length < 13) return null;
  final own = int.tryParse(rest[11]), system = int.tryParse(rest[12]);
  if (own == null || system == null) return null;
  return (name: line.substring(open + 1, close), used: Duration(milliseconds: (own + system) * 10));
}
