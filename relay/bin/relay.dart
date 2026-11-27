import 'dart:async';
import 'dart:io';

import 'package:ghost_relay/accounts.dart';
import 'package:ghost_relay/bounty.dart';
import 'package:ghost_relay/federation.dart';
import 'package:ghost_relay/feedback.dart';
import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/pushes.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/invites.dart';
import 'package:ghost_relay/invite_words.dart';
import 'package:ghost_relay/market.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/souls_send.dart';
import 'package:ghost_relay/turn.dart';
import 'package:ghost_relay/web_app.dart';
import 'package:ghost_relay/ws_door.dart';

/// `dart run bin/relay.dart [--host 127.0.0.1] [--port 8787] [--data relay-data] [--web <folder>] [--verbose]`
///
/// Listens on this machine alone unless told otherwise: on a server it sits behind the web server that holds the
/// certificate (README.md). An error nothing else caught is a line on stderr, never the end of the relay: one request's
/// mistake once ended it, and every hub connection with it (review, 2026-11-20). Each module still guards its own.
void main(List<String> args) {
  var started = false;
  runZonedGuarded(() async {
    await _main(args);
    started = true;
  }, (e, stack) {
    stderr.writeln('relay: unhandled ${'$e'.split('\n').first} at ${'$stack'.split('\n').first}');
    // Before it listens, a mistake in how it was started (a port in use, a bad --port) still ends it, as ever.
    if (!started) exit(1);
  });
}

/// Reads the options, makes each part of the relay over one data folder, starts listening, and stops cleanly on
/// Ctrl-C or a service's stop.
Future<void> _main(List<String> args) async {
  // The word after `--name`, or [fallback] where it was not given.
  String option(String name, String fallback) {
    final at = args.indexOf('--$name');
    return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
  }

  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln('Uplink relay\n  --host <address>  where to listen (127.0.0.1)\n  --port <number>   (8787, or \$PORT)\n  --data <folder>   where channels.json is kept (relay-data)\n  --web <folder>    the app built for a browser, served under /app/ (\$GHOST_WEB_DIR; none)\n  --verbose         say when an end joins or leaves (never an address)');
    return;
  }
  final host = option('host', '127.0.0.1');
  final port = int.parse(option('port', Platform.environment['PORT'] ?? '8787'));
  final verbose = args.contains('--verbose');
  // The pairings' relay at /relay/<channel>, and the hub people's apps find each other through at /hub.
  // The handles people linked are kept beside the pairings; the networks' sign-ins come from the environment
  // (GHOST_DISCORD_ID and the rest: handles.dart, docs/me.md in the app), and one that is not set is off.
  final data = Directory(option('data', 'relay-data'));
  final handles = Handles(dataDir: data, config: HandlesConfig.fromEnvironment(Platform.environment), verbose: verbose);
  // Waking a closed iPhone (pushes.dart): Apple's key from the environment (GHOST_APNS_KEY_FILE and the rest);
  // without it tokens are kept and nothing is sent.
  final pushes = Pushes(dataDir: data, config: ApnsConfig.fromEnvironment(Platform.environment));
  // Files spaces' sealed files, under the data folder; their limits from the environment (GHOST_FILES_MAX_FILE and the
  // rest: files.dart), each with a default where it is not set.
  final files = Files(dir: Directory('${data.path}/files'), config: FilesConfig.fromEnvironment(Platform.environment), verbose: verbose);
  // Invites waiting for someone not on the app yet, kept by a hash of their number and taken only by the install that
  // verified it (invites.dart; Matt, 2026-11-17: "a link that eventually follows through after they setup their account").
  final invites = Invites(dataDir: data, phoneKeyOf: handles.phoneKeyOf, whoOf: handles.whoOf, verbose: verbose);
  // Uplink accounts' sealed backups, by address (accounts.dart; Matt, 2026-11-17: "We need to have a way to login to
  // existing accounts"): usernames and the texted code for a verified number are handles'.
  final accounts = Accounts(dataDir: data, handles: handles, verbose: verbose);
  // The account each identity belongs to, on the admin page (handles.dart, accountOf).
  handles.accountOf = accounts.accountOf;
  // The app's Share feedback, filed in a Notion board (feedback.dart): the integration's secret and the board from the
  // environment (GHOST_NOTION_TOKEN, GHOST_NOTION_FEEDBACK); without them it says it isn't set up.
  final feedback = Feedback(config: FeedbackConfig.fromEnvironment(Platform.environment), ownsName: handles.ownsName, accountOf: accounts.accountOf, verbose: verbose);
  // Circles' invite words (invite_words.dart): gogho.st/c/<word>.
  final words = InviteWords(dataDir: data);
  // The Marketplace (market.dart; Matt, 2026-11-20: "I would like users to be able to develop and submit their own
  // plugins to our plugin marketplace and I'd like to be able to verify them for the store through a review process"):
  // what it keeps under the data folder, its limits from the environment (GHOST_MARKET_*), and who is who from the
  // handles: a username's owner and when it was claimed, the number or account behind a key, and the admin's sign-in.
  final market = Market(dir: Directory('${data.path}/market'), config: MarketConfig.fromEnvironment(Platform.environment), ownsName: handles.ownsName, whoOf: handles.whoOf, adminSignedIn: handles.adminSignedIn, claimedOn: handles.claimedOn, usernameOf: handles.usernameOf, verbose: verbose);
  // The media relay calls fall back on where two devices can't reach each other (turn.dart): coturn's shared secret
  // and where it is (GHOST_TURN_SECRET, GHOST_TURN_URLS); without them calls are direct only.
  final turn = TurnConfig.fromEnvironment(Platform.environment);
  // The link helpers the apps' direct links use (hub.dart, helpers): https addresses, commas between
  // (GHOST_LINK_HELPERS); without them devices link only where they are on one network.
  final helpers = (Platform.environment['GHOST_LINK_HELPERS'] ?? '').split(',');
  // What every connection may hold together, and when one is ended for it (ws_door.dart, WireBudget): every door's.
  final wireProblems = <String>[];
  WireBudget.shared = WireBudget.fromEnvironment(Platform.environment, problems: wireProblems);
  for (final p in wireProblems) {
    stderr.writeln('relay: $p');
  }
  // Relays that talk to each other (federation.dart; Matt, 2026-11-22: "I'd like the relays to be able to talk to each
  // other"): this relay's own key (relay-key.json, made the first time) and the home records its people give it
  // (homes.json), both in the data folder. Whether it links with other relays is GHOST_FED: off, unless it is set to
  // open or list; off there is no federation at all (no key made, no record kept, the hub exactly as before).
  final fedConfig = FedConfig.fromEnvironment(Platform.environment);
  final federation = fedConfig.mode == FedMode.off ? null : Federation(dataDir: data, config: fedConfig, verbose: verbose);
  if (federation == null) {
    for (final p in fedConfig.problems) {
      stderr.writeln('relay: $p');
    }
  }
  // The hosts the hub is reached at (GHOST_HUB_NAMES, commas between): with them it takes a sign-in bound to the host
  // the app dialled (hub.dart, greetingV2), and from a key that has signed in so, no other; without them, as before.
  final names = (Platform.environment['GHOST_HUB_NAMES'] ?? '').split(',');
  // What is held for people away, and what rooms keep, kept on disk as well (hub.dart, keepHeld; held_store.dart):
  // GHOST_HUB_KEEP_HELD=1, under the data folder's held/. Off unless set: it puts sealed packets, and who each is for
  // and from, on this machine's disk for up to a week (README.md, "What it keeps").
  final keepHeld = Platform.environment['GHOST_HUB_KEEP_HELD'] == '1';
  final hub = Hub(verbose: verbose, handles: handles, pushes: pushes, invites: invites, accounts: accounts, words: words, turn: turn, helpers: helpers, federation: federation, names: names, dataDir: data, keepHeld: keepHeld);
  // The app in a browser (web_app.dart): the folder `flutter build web` made, where one is named (--web, or
  // GHOST_WEB_DIR); without it there is no /app/. The page and the hub are then one address, as a browser needs.
  final webDir = option('web', Platform.environment['GHOST_WEB_DIR'] ?? '');
  final web = webDir.isEmpty ? null : WebApp(Directory(webDir));
  // The app in a browser at an address of its own (GHOST_APP_ORIGIN; gogho.st's is app.gogho.st): its page may read the
  // answers to the reports and the feedback it sends here, and nothing else.
  final appOrigin = Relay.appOriginFrom(Platform.environment);
  final relay = Relay(dataDir: data, verbose: verbose, hub: hub, files: files, feedback: feedback, market: market, bounty: Bounty(key: Bounty.keyFrom(Platform.environment), give: handles.giveBounty), souls: SoulsSend(send: handles.sendSouls, receiptOf: handles.soulsReceipt, soulsOf: handles.soulsOf), web: web, appOrigin: appOrigin);
  final got = await relay.start(host: host, port: port);
  stdout.writeln('Uplink relay listening on ws://$host:$got (${relay.channelCount} pairings kept; ${handles.linked} handles linked; ${files.spaces} Files spaces; ${market.listed} plugins listed; call relay: ${turn.on ? turn.urls.join(' ') : 'off'}; link helpers: ${hub.helpers.isEmpty ? 'none' : hub.helpers.join(' ')}; connections hold at most ${WireBudget.shared.most >> 20} MB together; the app in a browser: ${web == null ? 'off' : (web.there ? '/app/' : 'no index.html in $webDir')}${appOrigin == null ? '' : ', and at $appOrigin'}; sign-ins bound to: ${hub.names.isEmpty ? 'none' : hub.names.join(' ')}; held for people away: ${keepHeld ? 'kept on disk too' : 'in memory'}; other relays: ${federation == null ? 'off' : '${fedConfig.mode.name}, this one is ${federation.id}'}; sign-ins: ${handles.ways.entries.where((e) => e.value == 'signin').map((e) => e.key).join(', ').padRight(1, '-')})');
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    signal.watch().listen((_) async {
      await relay.stop();
      exit(0);
    });
  }
}
