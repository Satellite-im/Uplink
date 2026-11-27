// What the app's Dart spends its time on, read from a profile build over the VM service.
//
//     flutter build apk --profile --target-platform android-arm64 && adb install -r build/app/outputs/flutter-apk/app-profile.apk
//     adb logcat -d | grep "Dart VM service"        # http://127.0.0.1:<port>/<token>=/
//     adb forward tcp:<port> tcp:<port>
//     dart run tool/perf/cpu_profile.dart ws://127.0.0.1:<port>/<token>=/ws 30 [how many lines]
//
// It clears the samples, waits the seconds given while the app does whatever is being measured, then says where the
// samples fell: by the function running (self), by every function on the stack (with what it called), and by the
// app's outermost function on the stack (which timer, stream or frame began the work). A sample is taken only while a
// thread of the VM is running, so the count times the period is the time spent, not the time waited.
// vm_service is not one of the app's own packages: it comes with flutter_test, which is all a tool run by hand needs.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

String _name(ProfileFunction f) {
  final fn = f.function;
  if (fn is FuncRef) {
    final owner = fn.owner;
    final where = owner is ClassRef ? '${owner.name}.' : '';
    final url = f.resolvedUrl ?? '';
    final at = url.indexOf('/messaging/lib/');
    final short = url.startsWith('package:') ? url.substring(8) : at >= 0 ? url.substring(at + 15) : url.split('/').last;
    return '$where${fn.name}  ($short)';
  }
  if (fn is NativeFunction) return '[native] ${fn.name}';
  return '$fn';
}

/// Whether [f] is the app's own code (or its kit's), wherever the build says its file is: a profile build names files
/// by their path on the machine that built it, not by package.
bool _ours(ProfileFunction f) {
  final url = f.resolvedUrl ?? '';
  if (url.startsWith('package:ghost_messaging/') || url.startsWith('package:glacier/')) return true;
  return (url.contains('/messaging/lib/') || url.contains('/packages/glacier/lib/')) && !url.contains('/.pub-cache/');
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/perf/cpu_profile.dart ws://127.0.0.1:<port>/<token>=/ws <seconds> [lines]');
    exit(64);
  }
  final seconds = int.parse(args[1]);
  final lines = args.length > 2 ? int.parse(args[2]) : 25;
  final service = await vmServiceConnectUri(args[0]);
  final vm = await service.getVM();
  final isolates = vm.isolates ?? const <IsolateRef>[];
  // The profiler is off in a profile build until it is asked for (as DevTools asks when its CPU page is opened).
  try {
    await service.setFlag('profiler', 'true');
  } catch (_) {}
  for (final i in isolates) {
    try {
      await service.clearCpuSamples(i.id!);
    } catch (_) {}
  }
  final from = (await service.getVMTimelineMicros()).timestamp!;
  await Future<void>.delayed(Duration(seconds: seconds));
  final to = (await service.getVMTimelineMicros()).timestamp!;
  for (final i in isolates) {
    CpuSamples got;
    try {
      got = await service.getCpuSamples(i.id!, from, to - from);
    } catch (e) {
      stdout.writeln('isolate ${i.name}: no samples ($e)');
      continue;
    }
    final fns = got.functions ?? const <ProfileFunction>[];
    final samples = got.samples ?? const <CpuSample>[];
    final period = got.samplePeriod ?? 1000;
    final ms = samples.length * period / 1000;
    stdout.writeln('\n=== isolate ${i.name}: ${samples.length} samples of $period us = ${ms.toStringAsFixed(0)} ms in ${seconds}s = ${(ms / 10 / seconds).toStringAsFixed(2)}% of one core');
    if (samples.isEmpty) continue;
    final self = <int, int>{};
    final total = <int, int>{};
    final began = <int, int>{};
    final tags = <String, int>{};
    for (final s in samples) {
      final stack = s.stack ?? const <int>[];
      if (stack.isEmpty) continue;
      self[stack.first] = (self[stack.first] ?? 0) + 1;
      for (final f in stack.toSet()) {
        total[f] = (total[f] ?? 0) + 1;
      }
      // The stack is the leaf first: the app's outermost function is the last of ours.
      final outer = stack.lastWhere((f) => _ours(fns[f]), orElse: () => -1);
      began[outer] = (began[outer] ?? 0) + 1;
      final tag = '${s.vmTag ?? ''}${s.userTag == null || s.userTag == 'Default' ? '' : ' / ${s.userTag}'}';
      tags[tag] = (tags[tag] ?? 0) + 1;
    }
    void table(String title, Map<int, int> m, {bool Function(int)? keep}) {
      stdout.writeln('\n--- $title');
      final sorted = m.entries.where((e) => keep == null || keep(e.key)).toList()..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted.take(lines)) {
        final name = e.key < 0 ? '(none of the app\'s on the stack)' : _name(fns[e.key]);
        stdout.writeln('${(e.value * period / 1000).toStringAsFixed(0).padLeft(7)} ms ${(100 * e.value / samples.length).toStringAsFixed(1).padLeft(5)}%  $name');
      }
    }

    stdout.writeln('\n--- by what the VM was doing');
    for (final e in (tags.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(8)) {
      stdout.writeln('${(e.value * period / 1000).toStringAsFixed(0).padLeft(7)} ms ${(100 * e.value / samples.length).toStringAsFixed(1).padLeft(5)}%  ${e.key}');
    }
    table('began by (the app\'s outermost function on the stack)', began);
    table('the app\'s functions, with what they call', total, keep: (f) => _ours(fns[f]));
    table('self time, every function', self);
    // For the few heaviest functions by self time, the commonest stacks under them (leaf first), so that who asked is
    // seen even where none of the app's functions is on the stack.
    final heavy = (self.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(4).map((e) => e.key).toSet();
    final stacks = <String, int>{};
    for (final s in samples) {
      final stack = s.stack ?? const <int>[];
      if (stack.isEmpty || !heavy.contains(stack.first)) continue;
      final key = stack.take(14).map((f) => _name(fns[f]).split('  (').first).join(' < ');
      stacks[key] = (stacks[key] ?? 0) + 1;
    }
    stdout.writeln('\n--- commonest stacks under the heaviest functions (leaf first)');
    for (final e in (stacks.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(6)) {
      stdout.writeln('${(e.value * period / 1000).toStringAsFixed(0).padLeft(7)} ms  ${e.key}');
    }
  }
  await service.dispose();
  exit(0);
}
