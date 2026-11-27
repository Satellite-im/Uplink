import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/feedback/feedback_api.dart' show feedbackUrlFor;
import 'package:ghost_messaging/files/files_api.dart' show FilesApi;
import 'package:ghost_messaging/market/market_api.dart' show marketUrlFor;

/// The app's build for a browser (lib/web/main.dart, web/; Matt: "the full web client"): what the page in web/ says,
/// what is copied into the build beside it, and what the app's address tells the browser at app.gogho.st
/// (tool/deploy-site.mjs) and at a relay's /app/ (relay/lib/web_app.dart, its own test). `node tool/build-web.mjs`
/// runs this before it builds, and stops where it fails; a phone's or a computer's release does not (its guards are
/// test/source_guards_test.dart). The app in a page, as far as it can be held without a browser, is
/// test/web_start_test.dart; in real engines, tool/web/e2e.mjs.
void main() {
  test('the page names the app\'s icons, and they are there', () {
    final page = File('web/index.html').readAsStringSync();
    // What `flutter build web` fills in and writes: without either the built page loads nothing.
    expect(page, contains(r'<base href="$FLUTTER_BASE_HREF">'));
    expect(page, contains('<script src="flutter_bootstrap.js" async></script>'));
    expect(page, contains('<title>Uplink</title>'));
    final named = RegExp(r'href="([^"$]+\.(?:png|json))"').allMatches(page).map((m) => m.group(1)!).toList();
    expect(named, containsAll(['favicon.png', 'manifest.json', 'icons/Icon-192.png']));
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync()) as Map;
    expect(manifest['name'], 'Uplink');
    final icons = [for (final i in manifest['icons'] as List) (i as Map)['src'] as String];
    expect(icons, hasLength(4));
    for (final file in [...named, ...icons]) {
      expect(File('web/$file').existsSync(), isTrue, reason: 'web/$file');
    }
    // The picture the page shows where it can't be the app (lib/web/app.dart: WebNotice) is one of its assets.
    expect(File('assets/art/ghost-mark.png').existsSync(), isTrue);
  });

  // Nothing is fetched from anyone else (Matt: "the full web client"; docs/OPEN_NETWORK.md, part 6): the page says so
  // to the browser, and what is written into the build beside the app names no other address. That the page as built
  // asks no other address is seen in real engines by tool/web/e2e.mjs.
  test('the page tells the browser it may speak to its own address alone', () {
    final page = File('web/index.html').readAsStringSync();
    final policy = RegExp(r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">').firstMatch(page)?.group(1);
    expect(policy, isNotNull, reason: 'web/index.html has no policy');
    final said = {for (final part in policy!.split(';')) part.trim().split(' ').first: part.trim().split(' ').skip(1).toList()};
    expect(said, {
      'default-src': ["'none'"],
      // Its own scripts, and Flutter's engine compiled from WebAssembly: no script written into the page, none made
      // from text (`flutter build web --csp`), none from anywhere else.
      'script-src': ["'self'", "'wasm-unsafe-eval'"],
      'worker-src': ["'self'"],
      // Flutter's engine writes its styles into the page.
      'style-src': ["'self'", "'unsafe-inline'"],
      'img-src': ["'self'", 'data:', 'blob:'],
      'font-src': ["'self'"],
      'media-src': ["'self'", 'data:', 'blob:'],
      // The relay it came from, which is its hub too: the one address it speaks to.
      'connect-src': ["'self'"],
      'manifest-src': ["'self'"],
      'base-uri': ["'self'"],
      'form-action': ["'none'"],
      'frame-src': ["'none'"],
      'object-src': ["'none'"],
    });
    expect(page, contains('<meta name="referrer" content="no-referrer">'));
    // No script in the page but the loader, and nothing written into it to run.
    expect(RegExp(r'<script\b').allMatches(page), hasLength(1));
    expect(page, isNot(contains(RegExp(r'\son[a-z]+\s*=', caseSensitive: false))));
    // No other address is named by anything that is copied into the build as it is, comments apart (the worker's
    // first lines say whose work it is and where that is from).
    final other = RegExp(r'(?:https?:)?//[A-Za-z0-9.-]+\.[A-Za-z]{2,}');
    for (final file in ['web/index.html', 'web/manifest.json', 'web/flutter_bootstrap.js', 'web/argon2id.js']) {
      final code = File(file).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('*') && !l.trimLeft().startsWith('/*')).join('\n');
      expect(other.allMatches(code).map((m) => m.group(0)), isEmpty, reason: file);
    }
  });

  test('the loader asks for missing letters\' fonts beside the page, and sets up no service worker', () {
    final loader = File('web/flutter_bootstrap.js').readAsStringSync();
    // Filled in by `flutter build web`: Flutter's own loader, and what it built.
    expect(loader, contains('{{flutter_js}}'));
    expect(loader, contains('{{flutter_build_config}}'));
    // Flutter asks fonts.gstatic.com for these unless told otherwise.
    expect(loader, contains("fontFallbackBaseUrl: 'fallback-fonts/'"));
    final code = loader.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(code, isNot(contains('serviceWorker')));
    expect(code, isNot(contains('gstatic')));
  });

  // Signing in stretches the password with Argon2id. In a browser that is web/argon2id.js, run as a worker
  // (lib/account/argon2_browser_web.dart): built by tool/web/build-argon2.mjs from the browser extension's own pinned
  // copy of @noble/hashes, held to test/vectors/argon2id.json as it is built, and committed. That it is what the
  // script builds is `node tool/web/build-argon2.mjs --check` (tool/build-web.mjs runs it); what is held here is that
  // the file says where it came from, and that it is still the extension's pin.
  test('the Argon2id the page carries is the extension\'s pinned one, and says so', () {
    final worker = File('web/argon2id.js').readAsStringSync();
    final pin = ((jsonDecode(File('extension/package.json').readAsStringSync()) as Map)['dependencies'] as Map)['@noble/hashes'] as String;
    final lock = ((jsonDecode(File('extension/package-lock.json').readAsStringSync()) as Map)['packages'] as Map)['node_modules/@noble/hashes'] as Map;
    expect(pin, matches(RegExp(r'^\d+\.\d+\.\d+$')), reason: 'one version, not a range');
    expect(lock['version'], pin);
    expect(worker, startsWith('/* Argon2id for Uplink in a browser'));
    expect(worker, contains('Written by tool/web/build-argon2.mjs'));
    expect(worker, contains('From @noble/hashes $pin (${lock['integrity']})'));
    expect(worker, contains('MIT licensed'));
    // One file, with nothing to fetch: no other file brought in, no address asked.
    expect(worker, isNot(contains('importScripts')));
    expect(worker, isNot(contains('fetch(')));
    expect(worker, isNot(contains('XMLHttpRequest')));
    expect(worker.length, lessThan(40000));
    // The page starts it by this name, beside itself.
    expect(File('lib/account/argon2_browser_web.dart').readAsStringSync(), contains("const _script = 'argon2id.js';"));
  });
  // app.gogho.st (tool/deploy-site.mjs, tool/lib/web_site.mjs): the app at an address of its own, every answer with the
  // headers both of its addresses are held to (tool/web/headers.json; the relay's are held to it in
  // relay/test/web_app_test.dart), and the page's own policy with gogho.st's hub as the header.
  test('app.gogho.st\'s block sends every header on the list, and the page\'s policy with gogho.st\'s hub', () {
    final script = File('tool/deploy-site.mjs').readAsStringSync();
    final list = jsonDecode(File('tool/web/headers.json').readAsStringSync()) as Map;
    final block = RegExp(r'const APP_BLOCK = `\n(\$\{APP_HOST\} \{\n[\s\S]*?\n\})\n`;').firstMatch(script)?.group(1);
    expect(block, isNotNull, reason: 'tool/deploy-site.mjs has no APP_BLOCK written as this reads it');
    expect(RegExp(r"export const APP_HOST = '([^']+)'").firstMatch(File('tool/lib/web_site.mjs').readAsStringSync())?.group(1), 'app.gogho.st');
    // The headers the whole block sends, written once at its top.
    final top = RegExp(r'\n\theader \{\n([\s\S]*?)\n\t\}').firstMatch(block!)?.group(1);
    expect(top, isNotNull);
    final sent = {for (final m in RegExp(r'^\t\t([A-Za-z-]+) "([^"]*)"$', multiLine: true).allMatches(top!)) m.group(1)!: m.group(2)!};
    final csp = RegExp(r'const APP_CSP = "([^"]+)";').firstMatch(script)?.group(1);
    expect(csp, isNotNull);
    expect(sent, {
      ...(list['every'] as Map).cast<String, String>(),
      ...(list['app'] as Map).cast<String, String>(),
      'Content-Security-Policy': r'${APP_CSP}',
    });
    // The policy is the page's own with gogho.st's hub beside its own address, and what the page sends to there over
    // plain HTTP (lib/web/http.dart: a report to the review, feedback; lib/files/files_http_web.dart: a Files space's
    // files, from a build with them), exactly those; and frame-ancestors, which the page's <meta> can't say.
    final page = RegExp(r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">').firstMatch(File('web/index.html').readAsStringSync())!.group(1)!;
    expect(page, contains("connect-src 'self';"));
    expect(csp, '${page.replaceFirst("connect-src 'self';", "connect-src 'self' wss://gogho.st/hub https://gogho.st/market/abuse https://gogho.st/feedback https://gogho.st/files/;")}; ${list['frameAncestors']}');
    // Where the app finds those two beside its hub, the same.
    expect(marketUrlFor('wss://gogho.st/hub', const ['abuse']).toString(), 'https://gogho.st/market/abuse');
    expect(feedbackUrlFor('wss://gogho.st/hub').toString(), 'https://gogho.st/feedback');
    expect(FilesApi.baseFor('wss://gogho.st/hub').toString(), 'https://gogho.st/files');
    // What the page asks for as it signs out or is removed (lib/web/browser_web.dart, the relay's own in
    // relay/lib/web_app.dart): the browser told to clear everything it keeps for the address. Answered before any file
    // is looked for, and checked on the box as a visitor gets it.
    // Only to the page itself (Sec-Fetch-Site: same-origin): from anywhere else it is a file that isn't there, or a link
    // to it from another site would sign the person out (third review, A2).
    expect(block, contains('\t@clear {\n\t\tpath /clear-site-data\n\t\theader Sec-Fetch-Site same-origin\n\t}\n\thandle @clear {\n\t\t' r'header Clear-Site-Data "\\"storage\\""' '\n\t\theader Cache-Control "no-store"\n\t\trespond 204\n\t}'));
    expect(File('relay/lib/web_app.dart').readAsStringSync(), contains("static const clearAsker = 'same-origin';"));
    // The box checks both: the page's own asking clears, another site's doesn't.
    expect(script, contains("-H 'Sec-Fetch-Site: same-origin' --resolve"));
    expect(script, contains("for from in '' 'Sec-Fetch-Site: cross-site'; do"));
    expect(block.indexOf('handle @clear'), lessThan(block.indexOf('handle @hashed')));
    expect(File('lib/web/browser_web.dart').readAsStringSync(), contains("fetch('clear-site-data'.toJS"));
    expect(File('relay/lib/web_app.dart').readAsStringSync(), contains("static const clearPath = 'clear-site-data';"));
    expect(script, contains("const CLEAR_PATH = 'clear-site-data';"));
    expect(script, contains('const CLEAR_WANTED = \'Clear-Site-Data: "storage"\';'));
    // Kept a year only where the name says what is in it; asked for again everywhere else. Sent packed where the build
    // packed it; no name starting with a dot.
    expect(block, contains('handle @hashed {\n\t\theader Cache-Control "${(list['cache'] as Map)['hashed']}"'));
    expect(block, contains('\thandle {\n\t\theader Cache-Control "${(list['cache'] as Map)['plain']}"'));
    expect(RegExp(r'precompressed br gzip').allMatches(block), hasLength(2));
    expect(RegExp(r'hide \.\*').allMatches(block), hasLength(2));
    // Its files only: nothing passed on to the relay, nothing of the site's.
    expect(block, isNot(contains('reverse_proxy')));
    expect(block, contains(r'root * ${APP_DIR}'));
    // gogho.st serves it under /app/ too (Matt, 2026-11-23: "Deploy the website version as a open in browser option on
    // the website", gogho.st/app chosen over waiting for app.gogho.st): from the same folder, with the same headers as
    // app.gogho.st's block, and never passed to the relay.
    final site = RegExp(r'const BLOCK = `\n\$\{DOMAIN\} \{\n([\s\S]*?)\n\}\n').firstMatch(script)!.group(1)!;
    final under = RegExp(r'\thandle_path /app/\* \{\n([\s\S]*?)\n\t\}\n').firstMatch(site)?.group(1);
    expect(under, isNotNull, reason: 'gogho.st\'s block serves the app under /app/');
    expect(under, contains(r'root * ${APP_DIR}'));
    expect(under, isNot(contains('reverse_proxy')));
    final underTop = RegExp(r'\t\theader \{\n([\s\S]*?)\n\t\t\}').firstMatch(under!)!.group(1)!;
    final underSent = {for (final m in RegExp(r'^\t\t\t([A-Za-z-]+) "([^"]*)"$', multiLine: true).allMatches(underTop)) m.group(1)!: m.group(2)!};
    expect(underSent, {...sent}..remove('Strict-Transport-Security'));
    expect(RegExp(r'precompressed br gzip').allMatches(under), hasLength(2));
    expect(RegExp(r'hide \.\*').allMatches(under), hasLength(2));
    expect(site, contains('path /app/clear-site-data\n\t\theader Sec-Fetch-Site same-origin'));
    // And written with the site's blocks, taken out and written again as theirs are: once app.gogho.st's DNS record
    // points at the box, as gogho.st's does (before that Caddy's retries for its certificate back off for hours).
    expect(script, contains(r'''printf '%s\\n' '${BLOCK.replace('''));
    expect(script, contains(r'''[ "$WITH_APP" = 0 ] || printf '%s\\n' '${APP_BLOCK.replace('''));
    // And its block is taken out only where a new one goes in: with the DNS not checked, the one it has stays. The
    // two names that are always written again are gogho.st's and ghost-sms.com's.
    expect(script, contains(r"NAMES='${domCore}'"));
    expect(script, contains(r'''[ "$WITH_APP" = 0 ] || NAMES="$NAMES|${escaped(APP_HOST)}"'''));
    expect(script, contains(r'''START="^(www[.])?($NAMES)[ ,{]"'''));
    expect(script, contains(r'''$SUDO awk -v start="$START" '$0 ~ start { skip = 1; next }'''));
    final domCore = RegExp(r'const domCore = ([^;]+);').firstMatch(script)?.group(1);
    expect(domCore, isNotNull);
    expect(domCore, isNot(contains('APP_HOST')));
    expect(domCore, isNot(contains('ALSO')));
    expect(script, contains(r'''if [ -n "$APP_IP" ] && [ "$APP_IP" = "$SITE_IP" ]; then WITH_APP=1;'''));
    expect(script, contains('[DOMAIN, OLD, ...ALSO, APP_HOST].map(escaped)'));
    // The site's other names serve it themselves (Matt, 2026-11-27: "update the box so satellite.im and
    // deepspaceshipping.co don't redirect simply serve the uplink page"): a block each, the site's folder at its root,
    // the release's files, and nothing sent on but what is gogho.st's alone. Each only once its DNS points at the box,
    // and its old block taken out only then.
    expect(script, contains("const ALSO = ['satellite.im', 'deepspaceshipping.co'];"));
    final also = RegExp(r'const alsoBlock = \(name\) => `\n(\$\{name\} \{\n[\s\S]*?\n\})\n`;').firstMatch(script)?.group(1);
    expect(also, isNotNull, reason: 'tool/deploy-site.mjs has no alsoBlock written as this reads it');
    expect(also, contains('\thandle {\n\t\troot * \${SITE}\n'));
    expect(also, contains('\t@release path \${RELEASED}\n'));
    expect(also, isNot(contains('reverse_proxy')));
    expect(RegExp(r'\bredir ').allMatches(also!), hasLength(1), reason: 'only what is gogho.st\'s alone is sent there');
    expect(also, contains(r'redir https://${DOMAIN}{uri}'));
    expect(script, contains(r'''if points "$n"; then ALSO_IN="$ALSO_IN $n";'''));
    expect(script, contains(r'''for n in $ALSO_IN; do NAMES="$NAMES|$(printf '%s' "$n" | sed 's/[.]/[.]/g')"; done'''));
  });

  // Matt: "the full web client". What the page says of itself, to whoever adds it to a home screen: nothing it can't do.
  test('the page\'s words promise nothing a browser hasn\'t got', () {
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync()) as Map;
    final page = File('web/index.html').readAsStringSync();
    final description = RegExp(r'<meta name="description" content="([^"]+)">').firstMatch(page)!.group(1)!;
    expect(manifest['description'], description);
    for (final words in [manifest['description'] as String, description]) {
      expect(words.toLowerCase(), isNot(anyOf(contains('voice'), contains('video'), contains('call'))));
    }
  });
}
