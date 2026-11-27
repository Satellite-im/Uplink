import 'cpu_reading.dart';

/// A browser says nothing of what a page spends.
class _None implements CpuSource {
  @override
  Duration? used() => null;
  @override
  Map<String, Duration>? threads() => null;
  @override
  int? memory() => null;
}

CpuSource makeCpuSource() => _None();
