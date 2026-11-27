/// The network the local network route stands on (lan_wire.dart): sockets where there is dart:io (a phone, a computer,
/// the tests), none in a browser, which then has no such route.
library;

export 'lan_ground_io.dart' if (dart.library.js_interop) 'lan_ground_web.dart';
