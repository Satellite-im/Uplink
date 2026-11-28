import 'api/api.dart';
import 'api/methods.dart';
import 'api/remote.dart';
import 'api/server.dart';
import 'dart:async';
import 'dart:io' show File;
import 'platform_info.dart';
import 'dart:ui' show FramePhase, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import 'account/account.dart' show Account, AppAccountProfiles;
import 'circles/circles.dart';
import 'circles/pending_link.dart';
import 'circles/sms_space.dart';
import 'voice/voice.dart' show SpaceKind;
import 'friends/buddies.dart';
import 'friends/handover.dart';
import 'me/me.dart';
import 'accent.dart';
import 'app_lock/app_lock.dart';
import 'summaries.dart';
import 'app_state.dart';
import 'inbox/curl_sync.dart';
import 'kept_lists.dart';
import 'looks.dart';
import 'packs/resource_pack.dart';
import 'ui/launch_gate.dart';
import 'ui/text_scale.dart';
import 'backgrounds.dart';
import 'bubble.dart';
import 'desktop/links.dart' show DeskLinks;
import 'desktop/main.dart';
import 'desktop/store.dart' show DeskStore;
import 'standalone/overlay.dart';
import 'standalone/standalone.dart';
import 'standalone/unreadable.dart';
import 'standalone/wake.dart';
import 'standalone/welcome.dart';
import 'emoji_sets.dart';
import 'kit/settings_css.dart';
import 'net/net.dart';
import 'net/p2p/node_factory.dart';
import 'people.dart';
import 'plugins/notify_hush.dart' show NotifyHush;
import 'plugins/pack/pack.dart' show InstalledPlugins;
import 'plugins/plugin.dart' show MessageFacts;
import 'plugins/plugin_sync.dart' show PluginSync;
import 'voice/channels.dart';
import 'voice/mention_alerts.dart';
import 'voice/discord.dart';
import 'voice/space_groups.dart';
import 'snooze.dart';
import 'sounds.dart';
import 'keys.dart';
import 'gm/rcs_share.dart';
import 'sms.dart';
import 'ui/performance_row.dart';
import 'ui/circles/circle_invite_card.dart' show openCircleLink;
import 'ui/common.dart' show toast;
import 'ui/dialup/dialup.dart' show RetroSegment, isBevelChrome;
import 'ui/account_screens.dart' show RestartScreen;
import 'ui/add_me.dart' show askToAdd;
import 'ui/app_lock_ui.dart' show AppLockGate;
import 'ui/call_moved_note.dart';
import 'ui/call_pip.dart' show CallPip, CallPipFrame;
import 'relay_host/hosting.dart' show hostAwayIn;
import 'ui/relay_host_section.dart' show askToUseRelay;
import 'ui/computers.dart';
import 'ui/files_space/share_in.dart';
import 'onboarding/onboarding.dart';
import 'inbox/alerts.dart';
import 'keep_running.dart';
import 'plugins/human_check.dart' show startHumanCheck;
import 'files/files_store.dart';
import 'inbox/inbox.dart';
import 'inbox/telegram.dart';
import 'ui/inbox_ui.dart';
import 'ui/settings_panes.dart' show appVersion;
import 'ui/shell.dart';
import 'ui/update_banner.dart';
import 'l10n/words.dart';

/// What goes wrong on the screens' side goes in the app's own log (Settings › Developer; Matt, 2026-11-13: "a
/// developer setting with copying errors and reporting"): what it was and where, never what a message said.
void _logErrors() {
  String where(StackTrace? stack) {
    final all = (stack?.toString() ?? '').split('\n').where((l) => l.trim().isNotEmpty).toList();
    // The app's own lines where the error passed through any; else wherever it was thrown, so the report still
    // says where (Matt's report, 2026-11-14, held "Null check operator used on a null value" and nothing more).
    final ours = all.where((l) => l.contains('package:ghost_messaging')).take(2).toList();
    final lines = (ours.isNotEmpty ? ours : all.take(3)).map((l) => l.replaceAll(RegExp(r'^#\d+\s+'), '').replaceAll(RegExp(r'\s+'), ' ').trim());
    return lines.isEmpty ? '' : ' at ${lines.join(' < ')}';
  }

  final shown = FlutterError.onError;
  FlutterError.onError = (details) {
    Sms.instance.devLog('dart', '${details.exceptionAsString().split('\n').first}${where(details.stack)}');
    shown?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    Sms.instance.devLog('dart', '${error.runtimeType}: ${'$error'.split('\n').first}${where(stack)}');
    return false;
  };
}

/// Uplink: an SMS/MMS app drawn with Glacier and Ghost.md's stylesheets, as Ghost Keyboard's settings are.
/// The messages themselves are Android's (android/.../Store.kt); this is the screen over them.
///
/// Where the app starts on every platform. A computer goes off to lib/desktop; a phone reads what must be read
/// before the first frame (the stylesheets, the choices, the plugins) and draws [GhostMessagingApp]. What needs the
/// app to be usable (its network, friends, the inbox) starts later, in [_HomeState._check].
Future<void> main() async {
  // On a computer this is the companion to the phone's app (lib/desktop): the same screens, asking the phone.
  if (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux) return desktopMain();
  WidgetsFlutterBinding.ensureInitialized();
  // The direct network's core, where this platform's builds carry it (an Android phone's; an iPhone's carries none
  // yet): Direct is offered in Settings › Routes, and nothing of the core is opened until it is switched on.
  if (p2pCoreHere) Net.p2pNode = makeP2pNode;
  // Each frame's times in the log, for a performance pass on an emulator (built with --dart-define=GHOST_FRAME_LOG=true;
  // left out of every other build): how long the frame took to build, to draw, and in all, and when it was done (in
  // thousandths of a second on the engine's clock, to lay a stretch of frames out in time).
  if (const bool.fromEnvironment('GHOST_FRAME_LOG')) {
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final f in timings) {
        debugPrint('GFRAME build=${f.buildDuration.inMicroseconds} raster=${f.rasterDuration.inMicroseconds} total=${f.totalSpan.inMicroseconds} at=${f.timestampInMicroseconds(FramePhase.rasterFinish) ~/ 1000}');
      }
    });
  }
  // An iPhone has no texts for an app to read (Apple allows it only in the EU, to the default messaging app), so it is
  // Uplink of its own: friends by username, groups and calls over the internet (lib/standalone; Matt,
  // 2026-11-15: "roll a version of the app that works without sms"). One already paired with an Android phone as a
  // computer is (lib/desktop) stays that phone's companion.
  if (PlatformInfo.isIOS && File('${DeskStore.defaultDir().path}/pairing.json').existsSync()) return desktopMain();
  // The loading splash (lib/ui/launch_gate.dart; Matt, 2026-11-27: "on the phone add a loading splash screen using
  // the same logo"): the logo turning, up as the first frame and before anything below is read; the app goes under
  // it at the end of this, and the splash comes off it once the logo has been seen for a moment.
  final launch = LaunchGate.show();
  if (PlatformInfo.isIOS) {
    // What an iPhone deletes everything of the person's under, when it does (lib/account/account.dart): the folder its
    // store is in.
    AppAccountProfiles.appFolder = StandaloneCalls.defaultDir().path;
    try {
      await standaloneSetup();
    } catch (_) {
      // What it keeps couldn't be read: said, and nothing started, so nothing is written over it.
      return runApp(const StoreUnreadableNotice(device: 'iPhone'));
    }
  } else {
    // The phone's friends by username are kept in Dart, beside its texts (lib/standalone/overlay.dart): an iPhone
    // writes to them by username (Matt, 2026-11-15: "Yes, Android next").
    await overlaySetup();
  }
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final state = AppState();
  KeptLists.instance.app = state;
  CurlSync.instance.app = state;
  // The stylesheets, the person's choices and the wallpaper's colours (for a chat background and bubbles that follow
  // the phone) are asked for together: none waits on another.
  final loaded = await Future.wait<Object?>([
    AccentSheets.load(),
    state.load(),
    PhonePalette.load(),
  ]);
  // The language chosen, loaded before the first page is drawn (lib/l10n/words.dart, GMFB-32).
  await Words.instance.follow(state);
  final accents = loaded[0]! as AccentSheets;
  final sheet = accents.base;
  installSettingsStyles(sheet);
  // The resource pack the look Runestone draws with, where the person fetched one (lib/packs/resource_pack.dart):
  // read before the first page where that is the look, so it is never drawn flat first; else as the app goes on.
  if (state.look == Look.runestone) {
    await ResourcePacks.instance.start(state);
  } else {
    unawaited(ResourcePacks.instance.start(state));
  }
  // The app's lock (GMFB-46, lib/app_lock), read before the first page is drawn: with a PIN set the app opens locked.
  // An iPhone keeps the lock's record as a computer does (the Keychain, and a file that says it is set).
  await AppLock.start(state, folder: PlatformInfo.isIOS ? StandaloneCalls.defaultDir() : null, keychain: kReleaseMode);
  Sms.instance.listen();
  _logErrors();
  _watchFrames();
  Sms.instance.prefsChanged.stream.listen((_) => state.reload());
  // Plugins from the Marketplace and in development (lib/plugins/pack; Matt, 2026-11-20: "I would like users to be able
  // to develop and submit their own plugins to our plugin marketplace"): read from this phone's folder and each checked
  // again before any screen or the API asks the registry. At most three seconds; a slower disk finishes after.
  await InstalledPlugins.instance.load(state, appVersion: appVersion);
  // Which plugins are on, synced across the Uplink account's devices (GMFB-9: lib/plugins/plugin_sync.dart): the
  // person's switches heard from here on; the account's list is met once the relay is reached.
  PluginSync.instance.start(state);
  // What the phone's side needs to keep a hidden kind's texts from notifying with the app closed (GMFB-18, Matt, Android
  // 0.12.3: "If we dont have a specific kind of message enabled like political messages we shouldn't get notified via
  // sms for those messages"): written now, and again as the choices it comes from change.
  NotifyHush.start(state);
  // The app's API (lib/api), each way in started where Settings › API has it on (Matt, 2026-11-17: "build an entire API
  // that we can use to interact with every aspect of the app").
  Api.instance.registerAll(appMethods(state));
  unawaited(ApiServer.instance.apply(state));
  unawaited(ApiRemote.instance.apply(state));
  // Android's picture in picture for a call with a picture (GMFB-64, lib/ui/call_pip.dart): what there is to show is
  // told to MainActivity as it changes.
  if (PlatformInfo.isAndroid) CallPip.instance.follow();
  // An iPhone's links (ghostmsg:…: someone's add-me link, a circle's invite, a relay's; GMFB-34) come as a computer's
  // do, from its scene (ios/Runner/SceneDelegate.swift) on "ghost_desktop/links": held until the frame is up where
  // they come before it (lib/desktop/links.dart). Android's come with what the app was opened to show (OpenRequest).
  if (PlatformInfo.isIOS) unawaited(DeskLinks.start());
  launch.open(GhostMessagingApp(sheet: sheet, state: state, accents: accents));
  // How the start went, in the log beside each frame's times for a performance pass (GHOST_FRAME_LOG, above): how
  // long the reading took, when the logo was first seen and when the splash was gone, each from when it went up.
  if (const bool.fromEnvironment('GHOST_FRAME_LOG')) {
    unawaited(launch.left.then((_) => debugPrint('GLAUNCH read=${launch.took?.inMilliseconds} seen=${launch.seenAt?.inMilliseconds} left=${launch.leftAt?.inMilliseconds}')));
  }
}

/// A conversation's bubble on the side of the screen (android BubbleActivity.kt; GMFB-8): an engine of its own, started
/// here with the conversation's thread, showing that conversation and nothing around it (lib/bubble.dart).
@pragma('vm:entry-point')
Future<void> bubbleMain(List<String> args) => runBubble(args);

final _navigator = GlobalKey<NavigatorState>();

/// With `adb shell setprop log.tag.GhostPerf VERBOSE` set before the app starts, how long frames take is written to
/// Android's log every two seconds there are any: how many, and the slowest and the middle one's build and raster
/// times in milliseconds. Nothing is measured otherwise. (The Android side logs each of its calls the same way.)
Future<void> _watchFrames() async {
  try {
    if (!await Sms.instance.perfOn()) return;
  } catch (_) {
    return;
  }
  final build = <int>[];
  final raster = <int>[];
  Timer.periodic(const Duration(seconds: 2), (_) {
    if (build.isEmpty) return;
    build.sort();
    raster.sort();
    double ms(int micros) => micros / 1000;
    final slow = build.where((b) => b > 16000).length;
    // ignore: avoid_print
    print('GhostPerf frames=${build.length} build mid=${ms(build[build.length ~/ 2]).toStringAsFixed(1)} max=${ms(build.last).toStringAsFixed(1)} over16ms=$slow raster mid=${ms(raster[raster.length ~/ 2]).toStringAsFixed(1)} max=${ms(raster.last).toStringAsFixed(1)}');
    build.clear();
    raster.clear();
  });
  WidgetsBinding.instance.addTimingsCallback((timings) {
    for (final t in timings) {
      build.add(t.buildDuration.inMicroseconds);
      raster.add(t.rasterDuration.inMicroseconds);
    }
  });
}

/// The page's faces, with the emoji set chosen first among their fallbacks: Inter draws no emoji, so every one is
/// the set's. The phone's own set adds no fallback, and Android's emoji font is what is left.
/// The same object for the same emoji set: the theme is keyed on it (GlacierTheme), and a new one each build made new
/// tokens, and so the whole app rebuilt, on every change of any choice (docs/performance-audit.md).
final Map<String, GlacierTypography> _typographies = {};

GlacierTypography ghostTypography(String emoji) => _typographies[emoji] ??= _typography(emoji);

GlacierTypography _typography(String emoji) {
  final family = emojiFamilyOf(emoji);
  return GlacierTypography(
    features: const [FontFeature('cv11'), FontFeature('ss01')],
    fallbacks: family == null ? const {} : {'Inter Variable': [family], 'JetBrains Mono Variable': [family], 'Arimo': [family], 'Runestone': [family], 'Atkinson Hyperlegible Next Variable': [family]},
  );
}

/// The phone's app: the choices over everything ([AppScope]), then the theme made from them (stylesheet, look,
/// emoji set), then [_Home]. Built again whenever a choice changes.
class GhostMessagingApp extends StatelessWidget {
  const GhostMessagingApp({super.key, required this.sheet, required this.state, this.accents, this.home});
  final TokenSheet sheet;
  final AppState state;

  /// What the app shows: the walkthrough, then the conversations ([_Home]), where not given. A conversation's bubble
  /// gives its one conversation (lib/bubble.dart), in the same look and choices.
  final Widget? home;

  /// The stylesheets with the bubble colour chosen everywhere as the accent (lib/accent.dart); [sheet] alone where
  /// not given.
  final AccentSheets? accents;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: ListenableBuilder(
        listenable: state,
        builder: (context, _) => WidgetsApp(
          title: 'Uplink',
          navigatorKey: _navigator,
          // Each page that opens asks for a look for a newer version (lib/ui/update_banner.dart).
          navigatorObservers: [UpdateWatch()],
          color: const Color(0xFF4F5BD5),
          debugShowCheckedModeBanner: false,
          pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
              PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
          builder: (context, child) => Directionality(textDirection: Words.instance.direction, child: GlacierTheme(
            sheet: accents?.of(state) ?? sheet,
            attrs: ghostAttrs(state, 'mobile'),
            typography: ghostTypography(state.emoji),
            child: HapticsProvider(
              enabled: true,
              // A call being recorded shows in its banner over the call, whose Mixer opens the tracks full screen
              // (lib/ui/recording_float.dart); nothing floats over the pages but the note that a call moved to
              // another of the person's devices (lib/ui/call_moved_note.dart, GMFB-50). Over all of it, toasts too, the
              // lock screen while the app is locked (lib/ui/app_lock_ui.dart, GMFB-46). In Android's picture in picture, the
              // call's picture alone (lib/ui/call_pip.dart, GMFB-64).
              // Under the status bar, the Performance plugin's row while it is on (lib/ui/performance_row.dart).
              // The text size chosen in Settings, over every page, sheet and toast (GMFB-41, lib/ui/text_scale.dart).
              child: AppTextScale(child: InkOverrides(child: _SystemBars(child: AppLockGate(child: GlacierToastProvider(child: PerformanceUnder(navigator: _navigator, statusBar: true, child: CallMovedNote(child: CallPipFrame(child: child!)))))))),
            ),
          )),
          home: home ?? const _Home(),
        ),
      ),
    );
  }
}

/// Setup until Uplink is the default SMS app, then the conversations. A notification or another app's "text this
/// number" opens what it asks for over them.
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with WidgetsBindingObserver {
  /// The frame (the list and the pane beside it), for opening what a notification asks for in it.
  final _shell = GlobalKey<AppShellState>();

  /// Each page that opens in the pane asks for a look for a newer version, as each page of the app does.
  final _paneWatch = <NavigatorObserver>[UpdateWatch()];
  /// The walkthrough is open (it opened because Uplink could not send texts), until it is finished.
  bool _walking = false;

  /// Joins in circles, notified (once for the app's life).
  static StreamSubscription<CircleJoin>? _circleJoins;

  /// The default SMS app, or beside Google Messages (SmsStatus.usable); null until asked.
  bool? _isDefault;
  StreamSubscription<OpenRequest>? _opens;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check(first: true);
    _opens = Sms.instance.opens.stream.listen(_open);
    // An iPhone of its own that deleted everything of its account (signed out with everything, or removed from another
    // device) and can't start again by itself: only that it is to be opened again.
    if (Sms.standalone) Account.instance.addListener(_accountChanged);
  }

  /// The account changed: drawn again only where it has ended on this device.
  void _accountChanged() {
    if (mounted && Account.instance.ended) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Account.instance.removeListener(_accountChanged);
    _opens?.cancel();
    super.dispose();
  }

  /// When the app last left the screen: how long it was away decides whether the relay connection is trusted.
  DateTime? _left;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _left ??= DateTime.now();
    // Friends watching on our own system see the app put away, or back in use (lib/presence.dart).
    Net.instance.setAway(state != AppLifecycleState.resumed, hostAway: hostAwayIn(state));
    if (state != AppLifecycleState.resumed) return;
    // Back on the screen: a relay connection that died while away is made again now (lib/net/hub_carrier.dart).
    Net.instance.resume(_left == null ? Duration.zero : DateTime.now().difference(_left!));
    _left = null;
    _check();
    // A sign-in the browser extension synced while the app was away (Matt, 2026-11-21: "i hit sync but im not signed
    // into discord on my phone"): read on the relay's hello alone, a connection that stayed up never saw it.
    unawaited(CurlSync.instance.pull());
    // The wallpaper may have changed while the app was away: what is drawn from its palette is drawn again.
    PhonePalette.load().then((changed) {
      if (changed && mounted) AppState.of(context).changed();
    });
  }

  /// Asks whether the app can run (the texting app, beside Google Messages, or texts passed by), as it opens and
  /// each time it comes back to the screen. With [first], and where it can, everything that runs behind the screens
  /// is started, once: sounds, keys, the app's network and friends, files, the inbox, alerts, a paired computer's
  /// answers; and what the app was opened to show is opened.
  Future<void> _check({bool first = false}) async {
    final s = await Sms.instance.status();
    // Whether the phone's contacts can be read, before the list is drawn: without them plugins from other developers
    // see nothing, since a contact can't be told from a stranger (lib/plugins/pack/format.dart packSees).
    MessageFacts.heardStatus(s);
    if (!mounted) return;
    // Texts may be passed by in the walkthrough (Matt, 2026-11-20: "rework the onboarding on mobile so that SMS is not
    // required and you can 'skip this step'"): the app opens without them, and asks Android for none (Sms.textsOff).
    final skipped = AppState.of(context).flag(textsSkippedKey, fallback: false);
    Sms.textsOff = !s.usable;
    final allowed = s.usable || skipped;
    setState(() => _isDefault = allowed);
    if (first && allowed) {
      // The app's own updates: a look at most twice a day, as it opens.
      Sms.instance.updateBackground();
      // The app's routes to other phones with it (lib/net/net.dart): set up once, as the app opens.
      // And friends, who are reached by them (lib/friends/friends.dart).
      final app = AppState.of(context);
      // The interface sounds (lib/sounds.dart) read the person's choices from here.
      Sounds.instance.start(app);
      // The keyboard's commands and push to talk (lib/keys.dart).
      Keys.instance.start(app);
      // The app's own network, friends, groups, voice and circles, and friends by username (lib/people.dart).
      startPeople(app);
      // Files spaces' files (lib/files/files_store.dart): what was going up when the app closed goes on, and files
      // shared in from other apps are offered to a Files space (lib/ui/files_space/share_in.dart).
      unawaited(FilesStore.instance.start());
      FilesShareIn.attach(_navigator);
      // Spaces' groups, and Discord servers linked into Spaces (lib/voice/space_groups.dart, lib/voice/discord.dart).
      SpaceGroups.instance.start(app);
      DiscordServers.instance.start(app);
      // Telegram's and Bluesky's chats (lib/inbox), each started where it was signed in before, and their Settings.
      addInboxSettings();
      // Once the networks are up, the account's sign-ins brought into step at once (lib/inbox/curl_sync.dart): at the
      // relay's hello the helpers were still starting, and what this phone holds would wait for the timer.
      unawaited(Inbox.instance.start(app).then((_) => CurlSync.instance.pull()));
      // Their new messages notified, and the phone kept connected to them while Uplink is out of sight
      // (lib/inbox/alerts.dart).
      // Why Android keeps the app running after its screen is closed: networks signed in, and a friend's call to ring
      // where the person chose that (lib/keep_running.dart, GMFB-28).
      final running = KeepRunning.instance ??= (KeepRunning(keep: (names, {required calls}) => unawaited(Sms.instance.keepNetworks(names, calls: calls)))..follow(app));
      InboxAlerts.instance ??= InboxAlerts(
        notify: (a) => Sms.instance.notifyInbox(a.key, network: a.network, title: a.title, body: a.body, group: a.group),
        cancel: Sms.instance.cancelInbox,
        keepAlive: running.networks,
        inFront: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      )..watch(Inbox.instance);
      // First messages from someone new on the networks the Human check guards, held until they answer its question
      // (lib/inbox/human_check.dart; GMFB-23, Matt, Mac 0.12.6: "have new messages from that platform stay hidden from
      // notificatoins and my messages until they solve a small challenge").
      startHumanCheck(app);
      // Mentions of this device in spaces' chats, notified (lib/voice/mention_alerts.dart).
      MentionAlerts.instance ??= MentionAlerts(
        notify: (a) => Sms.instance.notifyInbox(a.key, network: a.where, title: a.title, body: a.body, group: true),
        cancel: Sms.instance.cancelInbox,
        inFront: () => WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
        on: () => app.flag('notif_mentions'),
      );
      // Someone new in one of this phone's circles, notified while Uplink is in the background (in front, the list says
      // it: lib/ui/shell.dart). Matt, 2026-11-19: "add join notifications for memebers in circles".
      _circleJoins ??= Circles.instance.joined.listen((j) {
        if (!app.flag('notif_joins') || WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
        final firstChat = j.circle.channels.where((c) => c.kind != SpaceKind.files).firstOrNull;
        unawaited(Sms.instance.notifyInbox(
          'circle:${j.circle.seed}',
          network: j.circle.name,
          title: j.line,
          body: firstChat != null ? 'Say hello in #${firstChat.name}' : 'Say hello',
          group: true,
        ));
      });
      // Summaries of unread conversations by the phone's own model (lib/summaries.dart): where it stands, and asked
      // for where it can be had.
      Summaries.instance.start(app);
      // SMS spaces this phone texts for (lib/circles/sms_space.dart): their messages out by text, and the replies in.
      SmsSpaces.instance.start(app);
      // And the number's verification, done here for a paired computer that asks (Sms.me on the computer).
      Sms.answer('me', Me.instance.forComputer);
      // And friends by username, added and answered from a paired computer (lib/friends/buddies.dart).
      Sms.answer('buddies', Buddies.instance.forComputer);
      // And what a paired computer is handed to have friends and circles of its own (lib/friends/handover.dart).
      Sms.answer('handover', answerHandover);
      // A paired computer's voice channels are the phone's (lib/voice/channels.dart).
      Sms.answer('voice', Voice.instance.answerDesk);
      // And how RCS stands here, for a paired computer to say so (lib/gm/rcs_share.dart, GMFB-11).
      Sms.answer('rcs', (_) => RcsShare.answer(app));
      // And the networks' sign-ins, for a paired computer that can't read the account's itself (lib/inbox/curl_sync.dart).
      Sms.answer('signins', CurlSync.instance.forComputer);
      // And its Telegram approves a paired computer's sign-in (lib/inbox/telegram.dart).
      Sms.answer('telegram', (args) async {
        final tg = Inbox.instance.named('telegram');
        if (tg is! Telegram) throw StateError('Telegram isn\'t in this build of the app.');
        return tg.answerComputer(args);
      });
      if (!s.contacts || !s.notifications) await Sms.instance.requestPermissions();
      final req = await Sms.instance.openRequest();
      if (req != null) _open(req);
    }
  }

  /// Opens what was asked for from outside the app, in the frame: a circle, a space, a network's chat, a pairing,
  /// a conversation by its thread or its people, or a new message.
  Future<void> _open(OpenRequest req) async {
    // Somewhere to go: the loading splash, if it is still up, doesn't wait for its logo to have been seen.
    LaunchGate.hurry();
    // A circle's link opened before the app is set up: held, and the circle opened once it is (lib/circles/pending_link.dart).
    if (req.circle != null && (_isDefault != true || _walking || (Sms.standalone && Me.instance.username == null))) {
      if (!await PendingCircleLink.hold(req.circle!) && mounted) toast(context, 'That circle link isn\'t complete. Ask for it again.');
      return;
    }
    final nav = _navigator.currentState;
    if (nav == null || _isDefault != true) return;
    nav.popUntil((r) => r.isFirst);
    // What is asked for opens in the frame's pane (lib/ui/shell.dart): over the list on a narrow screen, beside it
    // on a wide one. The frame is on the screen a frame after the app is found to be the default.
    if (_shell.currentState == null) await WidgetsBinding.instance.endOfFrame;
    final shell = _shell.currentState;
    if (shell == null) return;
    shell.home();
    if (req.inbox != null && req.inbox!.startsWith('circle:')) {
      // Someone joined a circle (above): the circle.
      final c = Circles.instance.bySeed(req.inbox!.substring('circle:'.length));
      if (c != null) shell.openCircle(c);
    } else if (req.inbox != null && req.inbox!.startsWith('snooze:')) {
      // A snooze's notification (lib/snooze.dart, GMFB-36): its conversation, or its space's chat, and a message's
      // shown in it as it opens.
      final key = req.inbox!.substring('snooze:'.length);
      final chat = Snoozed.chatOf(key);
      if (key != chat) Snoozed.instance.showOnOpen(chat, key.substring(chat.length + 1));
      if (chat.startsWith('text:')) {
        final thread = int.tryParse(chat.substring('text:'.length));
        if (thread != null) {
          unawaited(Sms.instance.people(thread).then((people) {
            if (shell.mounted) shell.openThread(thread, people);
          }));
        }
      } else if (chat.startsWith('space:')) {
        final room = chat.substring('space:'.length);
        final c = Voice.instance.channels.where((x) => x.room == room).firstOrNull;
        if (c != null) shell.openSpace(c);
      }
    } else if (req.inbox != null && req.inbox!.startsWith('space:')) {
      // A mention's notification (lib/voice/mention_alerts.dart): the space it was in, where it is listed.
      final seed = req.inbox!.substring('space:'.length);
      final c = Voice.instance.channels.where((x) => x.seed == seed).firstOrNull;
      if (c != null) shell.openSpace(c);
    } else if (req.inbox != null) {
      // A Signal or Telegram message's notification: its chat.
      final at = req.inbox!.indexOf(':');
      final network = at < 0 ? null : Inbox.instance.named(req.inbox!.substring(0, at));
      if (network != null) {
        final id = req.inbox!.substring(at + 1);
        final chat = network.chats.where((c) => c.id == id).firstOrNull;
        shell.show(InboxChatScreen(network: network, chatId: id, fallback: chat), showing: 'inbox:${network.id}:$id');
      }
    } else if (req.circle != null) {
      // A circle's invite link opened from outside the app: the circle where it is held, else its invite to answer.
      // A link cut short or bent says so, rather than opening a new message with the link in it (Matt, 2026-11-17:
      // "Finish the missing pieces that went unfinished").
      if (!openCircleLink(shell, req.circle!) && shell.mounted) toast(shell.context, 'That circle link isn\'t complete. Ask for it again.');
    } else if (req.add != null) {
      // Someone's add-me link (GMFB-34): asked first, then the friend request (lib/friends/add_link.dart).
      askToAdd(shell.context, req.add!);
    } else if (req.relay != null) {
      // A relay's link, from the QR code of one hosted from someone's app (lib/relay_host): asked first, then used.
      if (shell.mounted) unawaited(askToUseRelay(shell.context, req.relay!));
    } else if (req.pairing != null) {
      // A computer's pairing link, opened by the camera: the pairing page, which asks first.
      shell.show(PairComputerScreen(offered: req.pairing));
    } else if (req.computers) {
      // The "Paired with …" notification.
      shell.settings('computers');
    } else if (req.thread != null) {
      final people = await Sms.instance.people(req.thread!);
      shell.openThread(req.thread!, people);
    } else if (req.addresses.isNotEmpty) {
      final thread = await Sms.instance.threadFor(req.addresses);
      final people = <Person>[for (final a in req.addresses) await Sms.instance.contact(a)];
      shell.openThread(thread, people, draft: req.body);
    } else {
      shell.compose(body: req.body);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isDefault == null) return ColoredBox(color: context.tokens.color('glacier-bg'));
    // The walkthrough (lib/onboarding): from first launch, while Uplink cannot send texts, and on until it is
    // finished, though the texts page makes it able to part way through.
    if (!_isDefault! || _walking) {
      _walking = true;
      return Onboarding(onDone: () {
        // Texts skipped a moment ago: the app opens now, not after _check has looked again (until then _isDefault is
        // still false, and the walkthrough would be drawn again over the account's first page).
        final skipped = AppState.of(context).flag(textsSkippedKey, fallback: false);
        setState(() {
          _walking = false;
          if (skipped) _isDefault = true;
        });
        _check(first: true);
      });
    }
    // An iPhone of its own starts with a username (lib/standalone/welcome.dart); it is never asked to be the
    // default for texts, so the walkthrough above is not shown on one.
    if (Sms.standalone && Account.instance.ended) return const RestartScreen();
    if (Sms.standalone && Me.instance.username == null) return StandaloneWelcome(onDone: () => setState(() {}));
    // A new Android install, past the texts step: the username and password next (Matt, 2026-11-20: "Yes, replace
    // it"). After the texts step, since the relay server is dialled only once the app has started (_check).
    final app = AppState.of(context);
    if (app.flag(accountDueKey, fallback: false) && Me.instance.username == null) {
      return StandaloneWelcome(onDone: () {
        app.setFlag(accountDueKey, false);
        setState(() {});
      });
    }
    // Past the welcome: an iPhone may be woken while closed (lib/standalone/wake.dart).
    if (Sms.standalone) IosWake.start();
    // The list, and what is opened from it beside it where the screen is wide enough (a folding phone opened out).
    return AppShell(key: _shell, paneObservers: _paneWatch);
  }
}

/// Ghost.md's ink.css on the kit's parts no token reaches (as Ghost Keyboard's main.dart does).
class InkOverrides extends StatelessWidget {
  const InkOverrides({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlacierOverrides(
        switchThumbColor: _paper,
        segmentedSelectedLabelColor: _onAccent,
        segmentedThumbShadow: _none,
        // Under Dial-Up every segmented toggle is a row of push buttons, the chosen one held in (RetroSegment); every
        // other look keeps the kit's track and sliding thumb.
        segmentedSegment: isBevelChrome(context.tokens) ? _retroSegment : null,
        child: child,
      );

  static Widget _retroSegment(BuildContext context, GlacierSegmentLook look) => RetroSegment(look: look);

  static Color _paper(Tokens t) => t.color('app-paper');

  /// The words on a toggle's chosen tab, which wears the accent (lib/accent.dart).
  static Color _onAccent(Tokens t) => t.color('app-on-accent');
  static List<BoxShadow> _none(Tokens t) => const [];
}

/// The status and navigation bars' icons, dark on the light theme and light on the dark.
class _SystemBars extends StatelessWidget {
  const _SystemBars({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = context.tokens.isDark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
        statusBarColor: const Color(0x00000000),
        systemNavigationBarColor: const Color(0x00000000),
      ),
      child: child,
    );
  }
}
