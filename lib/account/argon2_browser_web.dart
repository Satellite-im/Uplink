import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Argon2id (version 0x13) of [password] under [salt], worked out by web/argon2id.js on a worker of its own
/// (lib/account/argon2_browser.dart): the page goes on drawing. The worker is made for the one password and ended
/// with it, its 64 MiB with it. Fails where the worker can't be started or says it couldn't; whoever asked then does
/// it the slow way.
Future<Uint8List>? browserArgon2id(Uint8List password, Uint8List salt, {required int memoryKiB, required int passes, required int lanes, int length = 32}) => _stretch(password, salt, memoryKiB, passes, lanes, length);

/// Beside the page, wherever the page is served from.
const _script = 'argon2id.js';

/// Starts the worker, hands it the one job and waits for its answer: the key's bytes, or an error where it says it
/// couldn't or could not be started.
Future<Uint8List> _stretch(Uint8List password, Uint8List salt, int memoryKiB, int passes, int lanes, int length) async {
  final worker = web.Worker(_script.toJS);
  final done = Completer<Uint8List>();
  worker.onmessage = ((web.MessageEvent said) {
    if (done.isCompleted) return;
    final data = said.data;
    final key = data.isA<JSObject>() ? (data as JSObject)['key'] : null;
    if (key != null && key.isA<JSUint8Array>()) {
      done.complete(Uint8List.fromList((key as JSUint8Array).toDart));
    } else {
      done.completeError(StateError('the password could not be stretched'));
    }
  }).toJS;
  worker.onerror = ((web.Event _) {
    if (!done.isCompleted) done.completeError(StateError('$_script could not be started'));
  }).toJS;
  final asked = JSObject()
    ..['password'] = Uint8List.fromList(password).toJS
    ..['salt'] = Uint8List.fromList(salt).toJS
    ..['memoryKiB'] = memoryKiB.toJS
    ..['passes'] = passes.toJS
    ..['lanes'] = lanes.toJS
    ..['length'] = length.toJS;
  try {
    worker.postMessage(asked);
    return await done.future.timeout(const Duration(minutes: 2));
  } finally {
    worker.terminate();
  }
}
