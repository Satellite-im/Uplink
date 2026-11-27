/// One request over HTTP from the page itself, for the two things the app sends from a browser: a report to Uplink's
/// review (lib/market/market_api.dart) and feedback (lib/feedback/feedback_api.dart). Everywhere else they
/// go with dart:io's HttpClient, which a browser hasn't got (it throws as it is made). The page's own way is in
/// http_web.dart; anywhere else there is none (http_none.dart).
///
/// Across addresses, as from app.gogho.st to gogho.st, the page's policy must name the address (tool/lib/web_site.mjs)
/// and the relay must let that page read the answer (relay/lib/relay.dart, GHOST_APP_ORIGIN): a browser enforces both.
library;

export 'http_none.dart' if (dart.library.js_interop) 'http_web.dart';
