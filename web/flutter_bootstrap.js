// What starts Flutter's engine and then the app, for Uplink in a browser. `flutter build web` writes this
// file into the build with the two pieces in double braces filled in (its own loader, and what it built).
//
// Two things are said here that Flutter would otherwise decide for itself:
//
// - Fonts for letters the app's own fonts have no shape for (Chinese, Arabic, Devanagari, mathematics, …) are asked
//   of a folder beside the page, never of fonts.gstatic.com, which is where Flutter asks by default, so nothing is
//   told to anyone about who is reading what. tool/build-web.mjs puts Google's Noto pieces there, under the names the
//   engine asks for, where tool/web/fallback-fonts.mjs --fetch has brought them to the computer building it; a build
//   without them draws such letters as boxes. Emoji are the app's own fonts (lib/web/emoji.dart).
// - No service worker is set up. Flutter's is on its way out, and what is kept and what is asked for again is the
//   relay's to say (relay/lib/web_app.dart).
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'fallback-fonts/',
  },
});
