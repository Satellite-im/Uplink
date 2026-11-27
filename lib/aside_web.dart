import 'dart:async';

/// [work] done here (lib/aside.dart): a browser has no isolates. As with `Isolate.run`, the answer comes later and
/// never at once, and what [work] throws is the returned future's error, never this call's. It is begun before this
/// returns, so it reads what it was handed as it stood when asked, as an isolate reads its copy.
Future<R> runAside<R>(FutureOr<R> Function() work) async => await work();
