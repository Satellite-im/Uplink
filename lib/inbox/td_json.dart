/// TDLib itself, where there is one: a C library, reached through `dart:ffi` (td_json_io.dart). A browser has no
/// `dart:ffi`, and a build for one can't so much as name it, so there [TdJson] is the half that finds no library
/// (td_json_web.dart), as a build of the app that left TDLib out finds none.
library;

export 'td_json_io.dart' if (dart.library.js_interop) 'td_json_web.dart';

/// How lib/inbox/telegram.dart speaks to TDLib: JSON objects each way. [TdJson] is TDLib itself; tests stand in a fake.
abstract class TdTransport {
  /// Everything TDLib says: answers (with the "@extra" they were asked with) and updates.
  Stream<Map<String, Object?>> get received;
  void send(Map<String, Object?> request);
  void close();
}
