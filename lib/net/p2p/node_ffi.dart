/// The direct network's core itself, where there is one: a Rust library on iroh (native/p2p, libghost_p2p), reached
/// through `dart:ffi` (node_ffi_io.dart). [IrohNode] is the [P2pNode] it makes. A browser has no `dart:ffi`, and a
/// build for one can't so much as name it, so there [IrohNode] is the half that finds no library (node_ffi_web.dart),
/// as a build of the app that left the core out finds none.
///
/// Nothing but node_factory.dart needs this: whoever wants a node asks `makeP2pNode()`.
library;

export 'node_ffi_io.dart' if (dart.library.js_interop) 'node_ffi_web.dart';
