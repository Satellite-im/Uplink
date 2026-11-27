import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/node_ffi.dart';
import 'package:integration_test/integration_test.dart';

/// The direct network's core on Android, in the app itself (lib/net/p2p/node_ffi.dart, P2pCore.kt, native/p2p): the
/// app starts with nothing of the core loaded; making a node opens the library and runs nothing of it; starting it has
/// Kotlin load the library and hand it the app's context, which the copy Dart opened then has; and the node reaches
/// our link helper (https://gogho.st:7843) by the phone's own DNS, and links through it to a node on another machine.
///
/// Run on an emulator (never a phone in use), with the core built for it (`sh tool/build-p2p.sh android`):
///
///     flutter test integration_test/p2p_core_test.dart -d emulator-5584 --dart-define=P2P_PARTNER=<node id>
///
/// where the partner is a node up on the same link helper that lets this one in: on the Mac,
/// `cargo test --release android_partner -- --ignored --nocapture` in native/p2p prints its node id and waits. Without
/// a partner the link is not tried. What it sees is said in the log (`P2PCORE …`): counts and kinds, never an address
/// or a node id of this device's.
const _helper = 'https://gogho.st:7843';
const _partner = String.fromEnvironment('P2P_PARTNER');

/// The key this test's node is started with: the one the partner lets in.
final _key = Uint8List.fromList(List.filled(32, 0xa6));

/// Whether the core is loaded in this process: in its map of files (the app's libraries are unpacked into its lib
/// folder: useLegacyPackaging), or by name to the system's linker with RTLD_NOLOAD, which answers only for a library
/// already loaded and loads nothing.
bool _coreLoaded() => _inMaps() || _linkerHasIt();

bool _inMaps() => File('/proc/self/maps').readAsLinesSync().any((line) => line.endsWith('libghost_p2p.so'));

bool _linkerHasIt() {
  final dlopen = DynamicLibrary.process().lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Int32), Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
  const rtldNow = 2, rtldNoload = 4;
  final name = 'libghost_p2p.so'.toNativeUtf8();
  try {
    return dlopen(name, rtldNow | rtldNoload) != nullptr;
  } finally {
    malloc.free(name);
  }
}

void _say(String what) => debugPrint('P2PCORE $what');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('nothing of the core at the start; made and started on demand, it is handed the context and reaches our link helper', (tester) async {
    // The app has started (its screen, its engine, every channel): nothing of the core is in the process.
    final atStart = _coreLoaded();
    _say('at the start, the core is loaded: $atStart (in the map of files: ${_inMaps()}, to the linker: ${_linkerHasIt()})');
    expect(atStart, isFalse, reason: 'the core was loaded as the app started');

    // Made: the library is opened by name and its functions looked up; nothing of it runs.
    final node = IrohNode.make();
    expect(node, isNotNull, reason: 'this build has no core: sh tool/build-p2p.sh android');
    _say('made: the library is loaded: ${_coreLoaded()} (in the map of files: ${_inMaps()}, to the linker: ${_linkerHasIt()})');

    // Started: Kotlin loads the library through Java (the same copy, by its name) and hands it the app's context;
    // the node is made only once this copy has it.
    final began = DateTime.now();
    await node!.start(P2pConfig(secret: _key, helpers: const [_helper]));
    _say('started: ${node.state.value.name}, problem ${node.problem}, in ${DateTime.now().difference(began).inMilliseconds} ms');
    expect(node.state.value, P2pState.up, reason: node.problem);

    // On our link helper, by its name looked up through the phone's DNS (the context is what lets the core read it).
    Whereabouts? where;
    for (var i = 0; i < 300 && where?.helper == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      where = node.whereabouts.value;
    }
    _say('whereabouts: on the helper ${where?.helper == _helper}, ${where?.addresses.length ?? 0} addresses of its own');
    expect(where?.helper, _helper, reason: 'the node never reached the link helper');

    if (_partner.isNotEmpty) {
      // A node on another machine, on the same helper, which lets this one in: found by the helper alone.
      node.allow(_partner, {P2pChannel.packets});
      final stream = await node.open(_partner, P2pChannel.packets, hint: const Whereabouts(helper: _helper), timeout: const Duration(seconds: 20));
      final heard = <Uint8List>[];
      final sub = stream.frames.listen(heard.add);
      await stream.add(Uint8List.fromList('hello from the emulator'.codeUnits));
      for (var i = 0; i < 200 && heard.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _say('linked to the partner: the path is ${node.pathTo(_partner)?.kind.name}, it answered: ${heard.isNotEmpty ? String.fromCharCodes(heard.first) : '(nothing)'}');
      expect(heard, isNotEmpty, reason: 'the partner never answered');
      await sub.cancel();
      await stream.close();
    }

    await node.stop();
    _say('stopped: ${node.state.value.name}');
    node.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
