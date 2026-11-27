/// gzip for the account's backup (lib/account/account_crypto.dart's AccountBackup.pack and unpack): `dart:io`'s own
/// wherever there is one (gzip_io.dart). A browser has no `dart:io`, and its `gzip` throws there at the first byte, on
/// the way to signing in; there it is package:archive's, in plain Dart (gzip_web.dart). Either opens what the other
/// packed (test/account_gzip_test.dart).
library;

export 'gzip_io.dart' if (dart.library.js_interop) 'gzip_web.dart';
