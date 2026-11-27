import 'dart:async';
import 'dart:isolate';

/// [work] on an isolate of its own (lib/aside.dart): `Isolate.run`, and nothing more.
Future<R> runAside<R>(FutureOr<R> Function() work) => Isolate.run<R>(work);
