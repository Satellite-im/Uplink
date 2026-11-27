import 'app.dart';

/// Uplink in a browser (Matt: "the full web client"): what `node tool/build-web.mjs` builds
/// (`flutter build web -t lib/web/main.dart`), with the page in web/. The page starts the app (app.dart).
Future<void> main() => webMain();
