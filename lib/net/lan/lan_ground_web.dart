import 'lan_wire.dart';

/// A page in a browser can neither say anything to a whole network nor be connected to: no local network route there.
LanGround? makeLanGround() => null;

/// Why this build has no local network route, in words for Settings › Routes; null where it has one.
String? lanGroundMissing() => 'A browser can\'t reach other devices on the network by itself.';
