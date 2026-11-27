/// A relay hosted from the app (docs/OPEN_NETWORK.md, section 5): the same hub gogho.st runs, in the app, on the Mac,
/// Windows, Linux and Android (relay_host_io.dart, which brings in the relay itself: relay/, dart:io and dart:ffi); in
/// a browser none (relay_host_web.dart), and an iPhone's half makes none either. Whoever wants one asks
/// [makeRelayHost]; what the screens read of it is lib/relay_host/hosting.dart.
library;

export 'relay_host_io.dart' if (dart.library.js_interop) 'relay_host_web.dart' show makeRelayHost;
