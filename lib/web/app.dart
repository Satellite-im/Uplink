import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../accent.dart';
import '../account/account.dart';
import '../app_state.dart';
import '../emoji_sets.dart';
import '../files/files_store.dart' show FilesStore;
import '../keys.dart';
import '../kit/settings_css.dart';
import '../looks.dart';
import '../ui/text_scale.dart';
import '../main.dart' show InkOverrides, ghostTypography;
import '../me/me.dart';
import '../net/carrier.dart' show CarrierState;
import '../net/hub_carrier.dart' show HubCarrier;
import '../net/net.dart';
import '../people.dart';
import '../plugins/pack/pack.dart' show InstalledPlugins;
import '../plugins/registry.dart' show PluginRegistry, logPluginError;
import '../sms.dart';
import '../standalone/standalone.dart';
import '../standalone/store.dart' show StoreLost;
import '../standalone/welcome.dart';
import '../ui/settings.dart' show SettingsSources;
import '../ui/shell.dart';
import '../voice/space_groups.dart';
import 'browser.dart';
import 'emoji.dart';
import 'settings.dart';
import 'store.dart';
import '../l10n/words.dart';

/// Uplink in a web page (Matt: "the full web client"; docs/OPEN_NETWORK.md, part 6): one more device of an
/// account, running as a computer with no phone linked does ([Sms.standalone], lib/standalone), on the same calls
/// ([StandaloneCalls]) with the browser's own store under them (store.dart).
///
/// Only what a browser can do is set up. A computer's start (lib/desktop/main.dart) also makes the link to a phone,
/// Google Messages' helper, Files spaces' store, the other networks' chats, plugins and the Marketplace, the local
/// API and the app's own updates: each of those needs a folder, a helper program or a socket a page hasn't got, so
/// none is made here, and the screens leave out what would lead to them. What is shared with a computer's start is
/// the standalone calls and [startPeople]: the routes, friends, groups, spaces and circles.
///
/// One tab at a time ([Browser.holdTab]): two tabs of one browser are the same device to the hub, and each would
/// take the other's place there for ever, and both would write the one store. A browser without the lock between tabs
/// that makes sure of it is told so, and nothing is started ([Browser.unfit]).
Future<void> webMain({Browser? browser}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final b = browser ?? Browser.instance;
  final unfit = b.unfit;
  if (unfit != null) return runApp(WebNotice(words: unfit));
  final hold = await b.holdTab(onAsked: letGo, onTaken: _taken);
  if (hold == null) {
    // Open in another tab already: said, with the way to have it here instead.
    return runApp(WebNotice(
      words: 'Uplink is open in another tab.',
      more: 'It runs in one tab at a time, so each message arrives once.',
      action: 'Use it here',
      onAction: () async {
        await b.takeTab(onAsked: letGo, onTaken: _taken);
        await _start(b);
      },
    ));
  }
  await _start(b);
}

/// Another tab is taking over. The routes first, so nothing more comes in or goes out here once the other is to have
/// them: a message heard by this tab after it had written its last would be lost with it. Then everything asked to be
/// kept is written, and nothing is written after, so this tab's last write can't cross the other's first.
@visibleForTesting
Future<void> letGo() async {
  try {
    await Net.instance.shutdown();
  } catch (_) {}
  await Sms.instance.prefsWritten();
  final calls = Sms.calls;
  if (calls is StandaloneCalls) {
    await calls.flushed();
    calls.close();
  }
}

/// The lock was taken from this tab without waiting for it (it said nothing in time): nothing more is written here,
/// as the page starts again.
void _taken() {
  final calls = Sms.calls;
  if (calls is StandaloneCalls) calls.close();
}

/// The hub this build was made for (`node tool/build-web.mjs --hub wss://gogho.st/hub`, `--dart-define=GHOST_WEB_HUB`):
/// the build for app.gogho.st names gogho.st's; a relay's own build names none.
const builtHub = String.fromEnvironment('GHOST_WEB_HUB');

/// Whether this build has Files spaces (Sms.browserFiles; docs/OPEN_NETWORK.md, part 6): on unless left out
/// (`node tool/build-web.mjs --no-files`, `--dart-define=GHOST_WEB_FILES=false`; GMFB-30, since 2026-11-25).
const webFiles = bool.fromEnvironment('GHOST_WEB_FILES', defaultValue: true);

/// Whether this build joins calls (Sms.browserCalls): on unless left out (`node tool/build-web.mjs --no-calls`,
/// `--dart-define=GHOST_WEB_CALLS=false`; GMFB-30, since 2026-11-25).
const webCalls = bool.fromEnvironment('GHOST_WEB_CALLS', defaultValue: true);

/// Where the hub is for a page at [address]: the one the build names ([built], [builtHub]: app.gogho.st's is on
/// gogho.st, an address of its own, so no page of the site's can read what the app keeps); or, for a build that names
/// none, beside the app's own folder, `/hub` where the page is `/app/`, as a relay that serves the app itself has it
/// (relay/lib/web_app.dart). Either way the page's policy lets it speak to that one address and its own
/// (web/index.html).
String hubFor(Uri address, {String built = builtHub}) {
  if (built.isNotEmpty) return built;
  final path = address.path;
  final at = path.lastIndexOf('/app/');
  final before = at >= 0 ? path.substring(0, at) : (path.endsWith('/app') ? path.substring(0, path.length - 4) : '');
  return Uri(scheme: address.scheme == 'https' ? 'wss' : 'ws', host: address.host, port: address.hasPort ? address.port : null, path: '$before/hub').toString();
}

bool _losing = false;

/// What this browser kept can't be opened (a sealed record under another key, or changed): it is all deleted, and the
/// page starts again saying so, for the person to sign in again. A store that can't be trusted is never quietly made
/// someone new.
Future<void> _lost(Browser b, BrowserStore kept) async {
  // Once: every record after the first that won't open says the same.
  if (_losing) return;
  _losing = true;
  final calls = Sms.calls;
  if (calls is StandaloneCalls) calls.close();
  try {
    await Net.instance.shutdown();
  } catch (_) {}
  await kept.wipe();
  b.reload(note: 'lost');
}

/// Starts the app in the page: opens what the browser keeps, sets up the app's parts as a browser has them, and
/// shows the first screen; a notice in their place where this browser won't serve.
Future<void> _start(Browser b) async {
  // Why the page was loaded again with nothing (signed out, removed, a store lost), said on the welcome.
  final note = b.takeNote();
  final BrowserStore kept;
  try {
    kept = await b.openStore();
  } catch (_) {
    return runApp(const WebNotice(
      words: 'This browser won\'t keep anything for this page.',
      more: 'Uplink keeps who you are and your conversations in the browser. A private window, or a browser set to keep nothing, has nowhere for them.',
    ));
  }
  // Kept through a browser running short of space, where it agrees to (each browser decides; a site visited often, or
  // added to the home screen, mostly is).
  unawaited(b.keep());
  final calls = StandaloneCalls.on(WebStandaloneStore(kept));
  // Starting again is the page loaded again, once what was asked to be kept is written (with why, where everything
  // here was just deleted); a link opens beside the page.
  calls.restart = () async {
    await calls.flushed();
    b.reload(note: calls.endNote);
    return true;
  };
  calls.openLink = (url) async => b.openTab(url);
  try {
    await calls.loadAgain();
  } on StoreLost {
    return _lost(b, kept);
  } catch (_) {
    // Couldn't be read just now (the browser's store busy, or full): said, with a way to try again, and nothing written,
    // so nothing is put over what is there.
    kept.close();
    return runApp(WebNotice(
      words: 'Uplink couldn\'t read what this browser keeps for it just now.',
      more: 'Nothing was changed. Try again in a moment; if it keeps happening, the browser may be short of space.',
      action: 'Try again',
      onAction: () async => b.reload(),
    ));
  }
  // Found while the app runs: the same.
  kept.onLost = (_) => unawaited(_lost(b, kept));
  if (note != null) await calls.invokeMethod('setPref', {'key': StandaloneCalls.noteKey, 'value': note});
  Sms.calls = calls;
  Sms.standalone = true;
  Sms.browser = true;
  Sms.browserName = b.name;
  // Calls, unless this build left them out (tool/build-web.mjs --no-calls): the page's own WebRTC, the app's own call code.
  Sms.browserCalls = webCalls;
  // Files spaces, unless this build left them out (tool/build-web.mjs --no-files): the app's own files store, keeping nothing
  // in the browser (FilesStore.browser).
  Sms.browserFiles = webFiles;
  Net.homeHub = hubFor(b.address);
  // What a page can't run is never made. Plugins: none of the app's own (they sort texts, draw cards for links
  // fetched from other sites, and add to calls: nothing a page has), and none from the Marketplace, which need a
  // folder to keep them in. The other networks' chats need helper programs, and are none in a browser
  // (lib/inbox/inbox.dart).
  PluginRegistry.instance = PluginRegistry(const [], onError: logPluginError);
  InstalledPlugins.instance = InstalledPlugins(storeAllowed: false, devAllowed: false);

  final state = AppState();
  final loaded = await Future.wait<Object?>([AccentSheets.load(), state.load()]);
  // The language chosen, loaded before the first page is drawn (lib/l10n/words.dart, GMFB-32).
  await Words.instance.follow(state);
  final accents = loaded[0]! as AccentSheets;
  installSettingsStyles(accents.base);
  // The emoji set in use is fetched now, and another when it is chosen (emoji.dart). Waited for a moment, so a
  // connection that is quick enough never shows a face as an empty box; a slow one starts the app without it.
  ensureEmojiFont = loadEmojiFont;
  String? family() => emojiFamilyOf(state.emoji);
  await loadEmojiFont(family()!).timeout(const Duration(seconds: 3), onTimeout: () {});
  state.addListener(() => loadEmojiFont(family()!));
  // The keyboard's commands (lib/keys.dart), and the app's own network: the routes, friends, groups, spaces and
  // circles, as a computer of its own runs them (lib/people.dart).
  Keys.instance.start(state);
  // Settings › About, the page's own (settings.dart): a phone's and a computer's are theirs.
  SettingsSources.add(browserSettings);
  startPeople(state);
  // Files spaces, where the build has them: the store follows the relay as it comes, as a computer's does.
  if (webFiles) unawaited(FilesStore.instance.start());
  SpaceGroups.instance.start(state);
  watchForRemoval(b);
  runApp(WebApp(state: state, accents: accents));
}

/// How often a page left open asks whether its browser is still on the account's list.
@visibleForTesting
Duration removalCheckEvery = const Duration(minutes: 3);

/// A browser removed from the account while its tab stays open (a library's computer) stops being the account within
/// a few minutes, as soon as the page is looked at again, or as the hub's connection comes back, not only when it is
/// next loaded: Account.check, which deletes only on the account's own signed removal. Asked no more than every half
/// minute however often the tab is brought back.
@visibleForTesting
void Function() watchForRemoval(Browser b, {DateTime Function()? now}) {
  final clock = now ?? DateTime.now;
  DateTime? last;
  void ask() {
    final at = clock();
    if (last != null && at.difference(last!) < const Duration(seconds: 30)) return;
    last = at;
    unawaited(Account.instance.check());
  }

  final every = Timer.periodic(removalCheckEvery, (_) => ask());
  b.onVisible(ask);
  // The hub's connection back up after it went down (not its first: the page asked as it started).
  HubCarrier? hub;
  var wasUp = false, everUp = false;
  void stateChanged() {
    final up = hub?.state.value == CarrierState.up;
    if (up && !wasUp && everUp) ask();
    if (up) everUp = true;
    wasUp = up;
  }

  // The routes were set up anew: the hub's route listened to is the one there is now.
  void netChanged() {
    final now = Net.instance.hub;
    if (identical(now, hub)) return;
    hub?.state.removeListener(stateChanged);
    hub = now;
    wasUp = false;
    now?.state.addListener(stateChanged);
    stateChanged();
  }

  Net.instance.addListener(netChanged);
  netChanged();
  // For a test: stopped.
  return () {
    every.cancel();
    Net.instance.removeListener(netChanged);
    hub?.state.removeListener(stateChanged);
  };
}

/// The app in the page: the one frame every device has (lib/ui/shell.dart), which puts the list and what is open side
/// by side in a wide window and one over the other in a narrow one. A wide window is read at a computer's sizes and a
/// narrow one at a phone's ([Sms.browserWide]).
class WebApp extends StatelessWidget {
  const WebApp({super.key, required this.state, required this.accents});
  final AppState state;
  final AccentSheets accents;

  @override
  Widget build(BuildContext context) => AppScope(
        state: state,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) => WidgetsApp(
            title: 'Uplink',
            color: const Color(0xFF4F5BD5),
            debugShowCheckedModeBanner: false,
            pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
            builder: (context, child) {
              final wide = MediaQuery.sizeOf(context).width >= AppShell.wideAt;
              Sms.browserWide = wide;
              return Directionality(textDirection: Words.instance.direction, child: GlacierTheme(
                sheet: accents.of(state),
                attrs: ghostAttrs(state, wide ? 'desktop' : 'mobile'),
                typography: ghostTypography(state.emoji),
                // The text size chosen in Settings, over every page, sheet and toast (GMFB-41, lib/ui/text_scale.dart).
                child: AppTextScale(child: InkOverrides(child: GlacierToastProvider(child: child!))),
              ));
            },
            home: const WebHome(),
            // Whatever the address says after its # (a link, a bookmark), the app opens on its first page: no page of
            // the app is reached from the address, so nothing hidden here is (the Marketplace, calls) and no address
            // leads anywhere unexpected.
            onGenerateInitialRoutes: (_) => [PageRouteBuilder<void>(settings: const RouteSettings(name: '/'), pageBuilder: (context, _, _) => const WebHome())],
          ),
        ),
      );
}

/// What the page opens on: a username and a password first (lib/standalone/welcome.dart), then the conversations.
class WebHome extends StatefulWidget {
  const WebHome({super.key});

  @override
  State<WebHome> createState() => _WebHomeState();
}

class _WebHomeState extends State<WebHome> {
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([Me.instance, Account.instance]),
        builder: (context, _) {
          // The username is how anyone reaches someone here.
          if (Me.instance.username == null) return StandaloneWelcome(onDone: () => setState(() {}));
          return const AppShell(key: ValueKey('browser'));
        },
      );
}

/// A page that says one thing in place of the app: that it is open in another tab, or can't run here. Drawn with no
/// stylesheet, since it stands before anything is loaded.
class WebNotice extends StatefulWidget {
  const WebNotice({super.key, required this.words, this.more, this.action, this.onAction});
  final String words;
  final String? more;

  /// A button under the words, and what it does; while that runs the button says so and can't be pressed again.
  final String? action;
  final Future<void> Function()? onAction;

  @override
  State<WebNotice> createState() => _WebNoticeState();
}

class _WebNoticeState extends State<WebNotice> {
  bool _busy = false;

  /// Runs the button's action, once at a time.
  Future<void> _go() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onAction!();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFFFFFFFF), soft = Color(0xFFB8B8B8);
    const face = TextStyle(fontFamily: 'Inter Variable', decoration: TextDecoration.none, color: ink);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Image(image: AssetImage('assets/art/ghost-mark.png'), width: 72, height: 72, excludeFromSemantics: true),
                  const SizedBox(height: 24),
                  Text(widget.words, textAlign: TextAlign.center, style: face.copyWith(fontSize: 20, height: 1.35, fontWeight: FontWeight.w600)),
                  if (widget.more != null) ...[
                    const SizedBox(height: 10),
                    Text(widget.more!, textAlign: TextAlign.center, style: face.copyWith(fontSize: 15, height: 1.45, color: soft)),
                  ],
                  if (widget.action != null) ...[
                    const SizedBox(height: 28),
                    Semantics(
                      button: true,
                      enabled: !_busy,
                      label: widget.action,
                      excludeSemantics: true,
                      child: GestureDetector(
                        key: const ValueKey('web-notice-action'),
                        behavior: HitTestBehavior.opaque,
                        onTap: _busy ? null : _go,
                        child: MouseRegion(
                          cursor: _busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: _busy ? const Color(0xFF3A3A3A) : ink, borderRadius: BorderRadius.circular(999)),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                              child: Text(_busy ? 'Opening…' : widget.action!, style: face.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: _busy ? soft : const Color(0xFF000000))),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
