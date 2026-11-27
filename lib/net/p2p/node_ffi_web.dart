import 'node.dart';

/// The direct network's core in a browser (lib/net/p2p/node_ffi.dart): there is none, so [make] makes nothing and the
/// direct route is simply not there (docs/OPEN_NETWORK.md, section 2: the core as WASM would reach others only
/// through a link helper; later). Nothing makes one of these.
abstract final class IrohNode implements P2pNode {
  /// The number of the C interface the other half was written against.
  static const abi = 2;

  /// Whether the library can be opened: never, here.
  static bool get available => false;

  /// A node, or null where the library is not in this build: always null here.
  static IrohNode? make() => null;

  /// Lets go of it: there is never one to let go of here.
  void dispose();
}
