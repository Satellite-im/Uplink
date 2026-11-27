import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// What CoreAudio says of the Mac's sound devices, for a test to see which ones are in use: whether a device (by its
/// CoreAudio UID, as WebRTC lists it) is running in any process. Reads only; nothing in the system changes.
class CoreAudioFixture {
  CoreAudioFixture._();

  static final _cf = DynamicLibrary.open('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation');
  static final _ca = DynamicLibrary.open('/System/Library/Frameworks/CoreAudio.framework/CoreAudio');

  static final _str = _cf.lookupFunction<Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Uint32), Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, int)>('CFStringCreateWithCString');
  static final _release = _cf.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CFRelease');
  static final _get = _ca.lookupFunction<Int32 Function(Uint32, Pointer<Uint32>, Uint32, Pointer<Void>, Pointer<Uint32>, Pointer<Void>), int Function(int, Pointer<Uint32>, int, Pointer<Void>, Pointer<Uint32>, Pointer<Void>)>('AudioObjectGetPropertyData');

  static int _fourCC(String s) => s.codeUnits.fold(0, (a, c) => (a << 8) | c);

  /// One UInt32 property of [object] (global scope, main element), with an optional CFString [qualifier]; null where
  /// CoreAudio refuses.
  static int? _uint(int object, String selector, {String? qualifier}) => using((a) {
        final addr = a<Uint32>(3);
        addr[0] = _fourCC(selector);
        addr[1] = _fourCC('glob');
        addr[2] = 0;
        final size = a<Uint32>()..value = 4;
        final out = a<Uint32>();
        Pointer<Pointer<Void>>? q;
        if (qualifier != null) q = a<Pointer<Void>>()..value = _str(nullptr, qualifier.toNativeUtf8(allocator: a), 0x08000100);
        final err = _get(object, addr, q == null ? 0 : sizeOf<Pointer<Void>>(), q?.cast() ?? nullptr, size, out.cast());
        if (q != null) _release(q.value);
        return err == 0 ? out.value : null;
      });

  /// The device whose CoreAudio UID is [uid] (kAudioHardwarePropertyTranslateUIDToDevice), 0 where there is none.
  /// Looked up each time: CoreAudio numbers its devices afresh as WebRTC starts and stops its sound.
  static int byUid(String uid) => _uint(1, 'uidd', qualifier: uid) ?? 0;

  /// Whether the device [uid] is running in any process (kAudioDevicePropertyDeviceIsRunningSomewhere).
  static bool running(String uid) {
    final id = byUid(uid);
    return id != 0 && _uint(id, 'gone') == 1;
  }
}
