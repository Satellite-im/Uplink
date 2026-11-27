import '../../platform_info.dart';
import 'node.dart';
import 'node_ffi.dart';

/// This device's node on the direct network, not yet started; null where this build has no core (a browser, a
/// platform the library was not built for, a build that left it out), and then there is no direct route at all.
///
/// The one place a node is made. What it is made of (lib/net/p2p/node_ffi.dart: the Rust core through `dart:ffi`
/// wherever there is one) is nobody else's to know; a test hands the route a stand-in instead. Making one opens the
/// core's library: the app asks for it only once the person has switched Direct on (Net.p2pNode).
P2pNode? makeP2pNode() => IrohNode.make();

/// Lets go of a node [makeP2pNode] made, stopped already, when the routes it was made for are gone (sign-out): the
/// core frees it and all it kept (the port it had on each network among them), and nothing can be asked of it again.
/// A test's stand-in is left as it is.
void letP2pNodeGo(P2pNode node) {
  if (node is IrohNode) node.dispose();
}

/// Whether the app's builds for this platform carry the core, so that Direct is offered (Net.p2pNode, set where the app
/// starts): Android's (tool/release.mjs), the Mac's (tool/release-mac.mjs), Windows' and Linux's (their workflows,
/// .github/workflows/messaging-{windows,linux}.yml). Not an iPhone's, which carries none yet (ios/), nor a browser's.
/// Worked out from the platform alone: nothing of the core is looked for or opened to say so.
bool get p2pCoreHere => PlatformInfo.isAndroid || PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux;
