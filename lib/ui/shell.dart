import '../circles/circles.dart';
import '../circles/pending_link.dart';
import '../desktop/links.dart' show DeskLinks;
import 'add_me.dart' show askToAdd;
import '../circles/invite_word.dart';
import '../invites/invite_relay.dart' show InviteRelayError;
import 'whats_new.dart' show showWhatsNewIfUpdated;
import 'circles/circle_invite_card.dart' show CircleInviteBanner, circleLinkElsewhere;
import 'circles/circle_dock.dart';
import 'circles/circle_screen.dart';
import 'circles/members_drawer.dart' show showCircleMembers;
import 'circles/new_circle.dart';
import 'split_handle.dart';
import 'window_chrome.dart';
import 'dart:async';
import '../platform_info.dart';

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyDownEvent, KeyEvent, KeyRepeatEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../me/me.dart';
import '../app_lock/app_lock.dart';
import '../app_state.dart';
import '../market/market_state.dart';
import '../plugins/pack/pack.dart' show InstalledPlugins, PackNotice, registryIdOf;
import 'market/marketplace_screen.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../friends/buddies.dart';
import '../net/name_watch.dart';
import 'name_watch_words.dart';
import '../sms.dart';
import 'common.dart';
import 'new_group.dart';
import '../art/lucide_more.dart';
import 'call_float.dart' show CallFloatLayer;
import 'call_mini.dart' show toggleCallMini;
import '../desktop/mini_window.dart' show CallMini;
import 'voice_screen.dart';
import 'space_designs/space_design.dart';
import 'space_groups_ui.dart';
import '../voice/channels.dart';
import '../voice/friend_calls.dart';
import '../voice/open_space.dart' show OpenSpaces;
import '../voice/voice.dart' show VoiceChannel;
import 'compose.dart';
import 'dialup/dialup.dart';
import 'contacts.dart';
import 'conversations.dart';
import 'nav_bar.dart';
import 'nav_rail.dart';
import 'profile.dart' show ProfileScreen;
import 'nav_style.dart';
import 'settings.dart';
import 'settings_shortcuts.dart' show KeyRecorder;
import 'settings_panes.dart' show settingsGroupLabel, settingsSections;
import 'thread.dart';
import '../keys.dart';
import '../inbox/inbox.dart';
import '../l10n/words.dart';

/// The app's one frame, on the phone and on a computer alike (Matt, 2026-11-14: "Unify the UI experience to match on
/// desktop and mac as well the desktop app should get all featues its missing from mobile and thr mobile app should
/// gain the nav from desktop").
///
/// The list of conversations (lib/ui/conversations.dart) and, beside it, a pane for what is opened from it: a
/// conversation, a new message, Settings. In a window [wideAt] wide or wider (a computer's, a tablet's, a folding
/// phone opened out) both are on the screen, the list down the side as the Mac's first had it; the conversation
/// open is marked in the list and draws no way back, since there is nowhere to go back to. In a narrower one (a
/// phone, a folding phone's cover) the list is the screen and what is opened slides over it, with its way back.
///
/// It is the same list and the same pane either way, each kept where it is as the window changes: a conversation
/// open on a folding phone's cover, a message half written in it, is still open and half written when the phone is
/// opened out, with the list now beside it.
///
/// Both are navigators. What a page in the pane opens (a contact's page, a picture, a sheet) opens over it in the
/// pane; the Archived list opens over the list in the list's place. Android's back closes what is in the pane
/// first, then goes back in the list, then leaves the app.
///
/// The way round is the pill floating at the list's foot (lib/ui/nav_bar.dart), the one the Mac's sidebar has: a
/// new chat, the messages, the contacts, the archive with how many are in it, the Marketplace, Settings. A new chat
/// and the contacts open in the pane; Messages, Archive, the Marketplace and Settings are the list's place itself: the
/// conversations, the archived ones, or the Marketplace's or Settings' sections, with the page of the section chosen in
/// the pane.
///
/// On a wide phone (a folding phone opened out, a tablet) the pill is not at the list's foot: it stands up at the
/// foot of a strip of its own down the window's right, as Ghost.md's dock does there (Matt, 2026-11-14: "on wider
/// phones like my fold 8 make the navbar render vertically condensed on the right of the screen like we do in ghost
/// markdown"). Ghost.md's floats over its page; here it is given the strip, [NavPill.railWidth] wide, and the pane
/// ends where the strip begins, because a conversation's Send button and its newest messages are in the very corner
/// a floating one would cover. A computer keeps the pill along its sidebar's foot, as Matt asked for there.
class AppShell extends StatefulWidget {
  const AppShell({super.key, this.status, this.nothing, this.paneObservers = const []});

  /// Kept under the list's search field: on a computer, how the phone is connected.
  final Widget? status;

  /// What the pane says while nothing is open in it and the window is wide. "Choose a conversation" where not given.
  final WidgetBuilder? nothing;

  /// Told of the pages that open in the pane: the look for a newer version (lib/ui/update_banner.dart).
  final List<NavigatorObserver> paneObservers;

  /// How wide a window is, in logical pixels, before the list and the pane stand side by side. A phone held
  /// upright is 360 to 430; a folding phone opened out is 700 or more.
  static const wideAt = 640.0;

  /// How much of a wide window the list takes: as the Mac's has it, less where the window is only just wide.
  /// At least wide enough for the list's toggle and its filter side by side (Matt, 2026-11-14: "the sidebar needs to
  /// be at least wide enough to show the segmented toggles and the filter").
  static double sideWidth(double width) => (width * 0.4).clamp(320.0, 380.0);

  /// The list's width where the person has dragged it (lib/ui/split_handle.dart; Matt, 2026-11-17: "add a handle to
  /// resize the sidebar and the main chat page ... like claude has"): from 260, so a narrow list is still a list, to
  /// what leaves the pane 360, so a conversation is still readable beside it.
  static double sideWidthAt(double width, double? dragged) {
    if (dragged == null) return sideWidth(width);
    final most = (width - 360.0).clamp(260.0, double.infinity);
    return dragged.clamp(260.0, most);
  }

  /// The list, or the pane, as a part of the accessibility tree of its own, in a browser. Every page in either has a
  /// barrier under it that takes out of that tree whatever was drawn before it, and with nothing between them the
  /// pane's reached the list and the list's reached the rail: neither could be found by a screen reader, or by a
  /// script driving the page (tool/web/e2e.mjs). On the other platforms the tree is left as it has been.
  static Widget _apart(Widget pages) => PlatformInfo.isWeb ? Semantics(container: true, child: pages) : pages;

  /// The shell this page is in, to open things with; null on a page shown with none (a test of one screen).
  static AppShellState? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<_ShellScope>()?.shell;

  /// Whether the list and the pane are side by side. The page asking is built again when that changes.
  static bool wideOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ShellScope>()?.wide ?? false;

  /// Whether the pill stands up at the window's right, not along the list's foot: a wide phone's window, tall
  /// enough for it. The page asking is built again when that changes.
  static bool railOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ShellScope>()?.rail ?? false;

  /// How much of its end a list in the list's place leaves clear for the pill: the pill's own height and room
  /// where it floats there, a step where it stands at the window's right instead.
  static double pillRoom(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_ShellScope>();
    final t = context.tokens;
    // Dial-Up's taskbar stands under the list rather than floating over it: the list's own well ends above it. With
    // the rail there is no taskbar, and the well runs to the window's foot as the pane beside it does.
    if (isBevelChrome(t)) return (scope?.rail ?? false) ? 0 : NavPill.taskbarHeight;
    if (scope?.rail ?? false) return t.space(4);
    // Stood up in the list's corner: the list's last rows scroll clear of the whole column, as Ghost.md's pages
    // keep room for its dock.
    if (scope?.docked ?? false) return NavPill.railHeight(t, scope!.rings);
    return NavPill.clearance(t);
  }

  /// Whether the pill stands up in the corner of a phone's narrow screen (a folding phone folded), floating over
  /// the list's end as Ghost.md's dock floats over its page. The page asking is built again when that changes.
  static bool dockedOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ShellScope>()?.docked ?? false;

  /// The conversation open in the pane, or null. The page asking is built again when that changes.
  static int? threadOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ShellScope>()?.thread;

  /// What else is open in the pane by its name (a Signal or Telegram chat: `inbox:<network>:<chat>`), or null. The
  /// page asking is built again when that changes.
  static String? showingOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ShellScope>()?.showing;

  /// What is kept under the list's search field ([status]), or null.
  static Widget? statusOf(BuildContext context) => context.getInheritedWidgetOfExactType<_ShellScope>()?.shell.widget.status;

  @override
  State<AppShell> createState() => AppShellState();
}

/// How large the pill is once the list under it is scrolled down, of its own size: Ghost.md's dock's
/// (lib/shell/page_dock.dart `dockScrolledScale` there), and within this many pixels of the top is the top.
const double pillScrolledScale = 0.8;
const double pillTopSlack = 4;

/// The frame's state, public so pages can reach it ([AppShell.maybeOf], [live]): what is open in the pane and in the
/// list's place, and the ways to open and close them.
class AppShellState extends State<AppShell> with SingleTickerProviderStateMixin {
  /// The frame on the screen, for what has no context of its own to find it by (the API, lib/api/methods.dart).
  static AppShellState? live;

  /// The list's width as dragged, kept between runs (PaneWidth 'list'); null for the width it is made with.
  double? _dragged;

  /// The pill, sized as Ghost.md's dock is (Matt, 2026-11-15: "Make the dock slightly larger when scrolled to the top
  /// of the page and make it get smaller when we scroll down just like ghost markdown does match the sizes"): its
  /// whole size at the list's top, four fifths once the person scrolls it down, and whole again only when the list is
  /// back at its top, whoever took it there. A scroll the app makes (a jump back to where it was) leaves it as it is;
  /// so does one across the page or inside something in it. Shrinks in the kit's fast duration, grows in its normal
  /// one, both easing out; at once under reduced motion. On a computer, as Ghost.md's desktop dock, it rests at the
  /// smaller size. 0 whole, 1 small.
  late final AnimationController _small = AnimationController(vsync: this, value: Sms.computer ? 1 : 0);
  late final Animation<double> _pillScale = _small.drive(Tween<double>(begin: 1, end: pillScrolledScale));
  double _smallGoal = Sms.computer ? 1 : 0;

  /// Every scroll under the frame: the page's own list back at its top makes the pill whole, the person scrolling it
  /// down makes it small. Never claims the notification.
  bool _pillHeard(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final m = n.metrics;
    if (!m.hasPixels || m.pixels <= m.minScrollExtent + pillTopSlack) {
      _pillGo(0);
      return false;
    }
    final theirs = switch (n) {
      UserScrollNotification(:final direction) => direction != ScrollDirection.idle,
      ScrollStartNotification(:final dragDetails) => dragDetails != null,
      ScrollUpdateNotification(:final dragDetails) => dragDetails != null,
      _ => false,
    };
    if (theirs) _pillGo(1);
    return false;
  }

  /// Moves the pill towards whole (0) or small (1); always small on a computer.
  void _pillGo(double goal) {
    if (Sms.computer) goal = 1;
    if (_smallGoal == goal || !mounted) return;
    _smallGoal = goal;
    final t = context.tokens;
    if (t.reducedMotion) {
      _small.value = goal;
      return;
    }
    _small.animateTo(goal, duration: t.duration(goal == 1 ? 'glacier-duration-fast' : 'glacier-duration-normal'), curve: t.curve('glacier-ease-out'));
  }

  /// The frame's two navigators: the pane's pages, and what stands in the list's place.
  final _pane = GlobalKey<NavigatorState>();
  final _side = GlobalKey<NavigatorState>();

  /// The page open in the pane, and the conversation it is where it is one. Null: nothing is open.
  PageRouteBuilder<void>? _open;
  int? _thread;

  /// Which of the pill's rings the pane's page is, where it is one: 'new', 'contacts' or 'settings'.
  String? _showing;

  /// The Archived list, while it is open in the list's place.
  Route<void>? _archive;
  bool get _archivedOpen => _archive != null;

  /// Settings' list of sections, while it is open in the list's place (Matt, 2026-11-14: "when the settings is open
  /// on desktop replace the normal sidebar so it's only a two pane layout not a three pane"): the page of the
  /// section chosen is the pane's, beside it in a wide window and over it on a phone.
  Route<void>? _settings;

  /// Whether Settings is open in the list's place.
  bool get settingsOpen => _settings != null;

  /// The Marketplace's list of sections, while it is open in the list's place (Matt, 2026-11-20: "Move plugins out of
  /// settings into a marketplace button on the navigation rail with a marketplace icon"): the page of the section chosen
  /// is the pane's, beside it in a wide window and over it on a phone, as Settings' are.
  Route<void>? _market;
  bool get marketOpen => _market != null;

  /// The section whose page is in the pane, or null: the row the Marketplace's list marks.
  final marketSection = ValueNotifier<String?>(null);

  /// A circle, while it is open in the list's place, with a way back at its top (Matt, 2026-11-17: "make a new design
  /// for [circles] ... with it's own sidebar full of spaces"); its spaces open in the pane.
  Route<void>? _circle;
  bool get circleOpen => _circle != null;

  /// The seed of the circle open in the list's place, or null.
  String? get openCircleSeed => _circleSeed;
  String? _circleSeed;

  /// The section of Settings whose page is in the pane, or null: the row Settings' list marks.
  final settingsSection = ValueNotifier<String?>(null);

  /// How many conversations are archived, as the list last counted them: said in the Archive ring's menu.
  final archived = ValueNotifier<int>(0);

  /// How many archived texts are unread, as the list last counted them ([countArchivedUnread]). The number on the
  /// Archive ring is these and the networks' archived chats that are unread ([_archiveBadge]): the count of what is
  /// in the archive never fell when it was read (GMFB-14, @kevin: "I have notifications showing on my archive but I
  /// have read all of the messages in the archive to try to clear it and nothing happens").
  final archivedUnread = ValueNotifier<int>(0);

  /// How many conversations in Messages are unread, as the list last counted them: the number on the Messages ring
  /// (GMFB-17, Matt, Android 0.12.3: "When messages have unreads the message bubble icon in the sidebar should show the
  /// count in a unread badge same with circles"). Texts, network chats and spaces' chats alike, as the list's own Mark
  /// all as read counts them, and only those Messages shows (a hidden kind's are not counted).
  final messagesUnread = ValueNotifier<int>(0);

  /// Counts the archived texts that are unread again; the list does as it loads, and so does marking them read.
  Future<void> countArchivedUnread() async {
    try {
      final page = await Sms.instance.conversationsPage(archived: true);
      archivedUnread.value = page.items.where((c) => c.unread).length;
    } catch (_) {}
  }

  /// The number on the Archive ring: archived conversations with something unread, texts and networks' alike.
  int get _archiveBadge => archivedUnread.value + Inbox.instance.ready.fold<int>(0, (n, net) => n + net.archivedChats.where((c) => c.unread > 0).length);

  bool _wide = false;

  /// Whether Android's back has something to close in the pane, and something to go back from in the list.
  bool _paneBack = false;
  bool _sideBack = false;

  /// Told each time the pane's page closes or gives way to another: the list reads its conversations again, as it
  /// did on a phone whenever a conversation was come back from.
  final closed = ValueNotifier<int>(0);

  /// The conversation open in the pane, or null.
  int? get thread => _thread;

  /// Whether the list and the pane are side by side.
  bool get wide => _wide;

  /// The hangout whose call this device is in, as last drawn: the list's place and the pill's change with it.
  String? _inHangout;

  /// The pane shows the space whose call this device is in (a circle's space opened beside its list).
  bool get _paneShowsCall {
    final s = Voice.instance.session;
    return s != null && s.channel.hangout && _showing == 'circle' && openCircleSpaceSeed.value == s.channel.seed;
  }

  /// Draws the frame again when this device comes into or leaves a hangout's call, and for nothing else of a call's.
  void _voiceChanged() {
    final s = Voice.instance.session;
    final now = s != null && s.channel.hangout ? s.channel.room : null;
    if (now != _inHangout && mounted) setState(() => _inHangout = now);
  }

  @override
  void initState() {
    super.initState();
    live = this;
    // The keyboard's commands and push to talk, heard on every page (lib/keys.dart).
    HardwareKeyboard.instance.addHandler(_key);
    Voice.instance.addListener(_voiceChanged);
    FriendCalls.instance.ended.addListener(_callEnded);
    _ringActions = Sms.instance.ringAction.stream.listen(_ringAction);
    Circles.instance.removedFrom.addListener(_removed);
    _joins = Circles.instance.joined.listen(_someoneJoined);
    Circles.instance.addListener(_landIfReady);
    // A circle's link held while the app was being set up, or copied by the invite page before the app was got
    // (lib/circles/pending_link.dart): the circle joined and opened, now there is a list to open it in.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_takeHeldLink()));
    // And someone's add-me link that started the app on a computer or an iPhone before the frame was up (GMFB-34,
    // lib/desktop/links.dart): asked about now.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final add = DeskLinks.takeHeldAdd();
      if (add != null && mounted) askToAdd(context, add);
    });
    // What's new, once after an update (Matt, 2026-11-19: "Implement a changelog that pops up ever time a new update is
    // released with release notes"): a moment after the frame is up, over it.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) unawaited(showWhatsNewIfUpdated(context));
    });
    // The circles' invite words this device may change, claimed again so the relay keeps them (it lets one go a year
    // after it was last set; lib/circles/invite_word.dart): once the hub is likely reached.
    _renewWords = Timer(const Duration(seconds: 30), () {
      if (mounted) unawaited(Circles.instance.renewInviteWords());
    });
    // The Marketplace's catalog, withdrawals and a developer's own submissions, read a little after starting and every
    // few hours (lib/market/market_state.dart): never under a test, never on an iPhone, which has no store packs.
    if (!PlatformInfo.environment.containsKey('FLUTTER_TEST') && InstalledPlugins.instance.storeAllowed) unawaited(MarketState.instance.start());
    // What the packs and the Marketplace have to say as it happens: a pack withdrawn (with the way to its page), paused,
    // loaded from the API, and a developer's decisions.
    _notices = [InstalledPlugins.instance.notices.listen(_notice), MarketState.instance.notices.listen(_notice)];
    // The name watch's word on this person's own username, the moment it comes (lib/net/name_watch.dart): the relay gave
    // it to another key, by its own answer or as a friend's app saw.
    _names = NameWatch.notices.listen(_nameNotice);
  }

  StreamSubscription<NameChange>? _names;

  void _nameNotice(NameChange c) {
    if (!mounted) return;
    final by = c.by;
    // Said once, calmly: the usual reasons are ordinary ones, and the words name them.
    toast(context, nameNoticeWords(c, who: by == null ? null : (Buddies.instance.byId(by)?.shown ?? 'A friend')));
  }

  List<StreamSubscription<PackNotice>> _notices = const [];

  /// The key push to talk is held on, while it is: its letting go turns the microphone off again.
  LogicalKeyboardKey? _talking;

  /// A key pressed anywhere in the app: a command of lib/keys.dart, or push to talk. True where it was one, so the
  /// page under it does not also take it. Not while Settings is waiting for keys to put a command on.
  bool _key(KeyEvent e) {
    // The quick switcher open: its field and its list have the keys.
    if (!mounted || KeyRecorder.listening || _switcher) return false;
    final keys = Keys.instance;
    final session = Voice.instance.session;
    // Letting go of push to talk: off again.
    if (e is KeyUpEvent && _talking != null && e.logicalKey == _talking) {
      _talking = null;
      if (session != null && keys.pushToTalk) session.setMuted(true, quiet: true);
      return true;
    }
    // The app locked (lib/app_lock, GMFB-46): no command starts behind the lock screen, whose number pad has the keys.
    // (Push to talk let go of, above, still turns the microphone off.)
    if (AppLock.instance.locked) return false;
    if (e is! KeyDownEvent) return e is KeyRepeatEvent && _talking != null && e.logicalKey == _talking;
    final command = keys.commandFor(e, typing: Keys.typing);
    if (command == null) return false;
    switch (command) {
      case KeyCommand.pushToTalk:
        // Only in a call, with push to talk on: otherwise the key is the key.
        if (session == null || !keys.pushToTalk || session.locked) return false;
        _talking = e.logicalKey;
        session.setMuted(false, quiet: true);
      case KeyCommand.toggleMute:
        if (session == null) return false;
        session.setMuted(!session.muted);
      case KeyCommand.toggleDeafen:
        if (session == null) return false;
        session.setDeafened(!session.deafened);
      case KeyCommand.leaveCall:
        if (session == null) return false;
        unawaited(Voice.instance.leave());
      case KeyCommand.miniWindow:
        // In a call (or back out of the mini window, the call still on): lib/ui/call_mini.dart.
        if (session == null || !CallMini.here) return false;
        unawaited(toggleCallMini(context));
      case KeyCommand.newChat:
        go('new');
      case KeyCommand.search:
        go('messages');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (Keys.searchFocus.context != null) Keys.searchFocus.requestFocus();
        });
      case KeyCommand.messages:
        go('messages');
      case KeyCommand.contacts:
        go('contacts');
      case KeyCommand.archive:
        go('archive');
      case KeyCommand.voice:
        go('voice');
      case KeyCommand.settings:
        settings();
      case KeyCommand.marketplace:
        go('marketplace');
      case KeyCommand.closePage:
        if (settingsOpen) {
          closeSettings();
        } else if (marketOpen) {
          closeMarketplace();
        } else {
          close();
        }
      case KeyCommand.shortcuts:
        settings('shortcuts');
      case KeyCommand.toggleSidebar:
        // Only where the list stands beside the pane: on a phone the list is the page.
        if (!_wide || _open == null) return false;
        setState(() => _sideHidden = !_sideHidden);
      case KeyCommand.quickSwitch:
        quickSwitch();
      case KeyCommand.nextChat:
        return stepConversation(1);
      case KeyCommand.previousChat:
        return stepConversation(-1);
      case KeyCommand.markRead:
        final list = ConversationsScreen.live;
        if (list == null) return false;
        unawaited(list.markShownRead());
      case KeyCommand.bold:
      case KeyCommand.italic:
      case KeyCommand.code:
      case KeyCommand.strike:
      case KeyCommand.spoiler:
      case KeyCommand.quote:
        return Keys.format(command);
    }
    return true;
  }

  /// The list put away beside a conversation (KeyCommand.toggleSidebar), the pane the whole window; back with the same
  /// keys. Only on a wide window.
  bool _sideHidden = false;

  /// The quick switcher is up (KeyCommand.quickSwitch).
  bool _switcher = false;

  /// Opens the quick switcher: every conversation by name, and the app's places (GMFB-41).
  void quickSwitch() => setState(() => _switcher = true);

  /// Opens the conversation [by] rows below the one open (above, where negative) in the list as it is shown: the first
  /// or the last where none of the list's is open. False where there is no list or nothing in it.
  bool stepConversation(int by) {
    final list = ConversationsScreen.live;
    final order = list?.order ?? const <Conversation>[];
    if (list == null || order.isEmpty) return false;
    final at = order.indexWhere((c) => c.id == thread);
    final next = Keys.stepTo(order.length, at, by);
    if (next == at) return true;
    list.openConversation(order[next]);
    return true;
  }

  /// The places the quick switcher offers beside the conversations, with the keys each is on.
  static const _places = [
    ('new', 'Start something new', KeyCommand.newChat),
    ('messages', 'Messages', KeyCommand.messages),
    ('contacts', 'Contacts', KeyCommand.contacts),
    ('archive', 'Archive', KeyCommand.archive),
    ('voice', 'Spaces', KeyCommand.voice),
    ('settings', 'Settings', KeyCommand.settings),
    ('marketplace', 'Marketplace', KeyCommand.marketplace),
    ('shortcuts', 'Keyboard shortcuts', KeyCommand.shortcuts),
  ];

  /// The most conversations the switcher lists: the newest, which are the ones jumped to.
  static const _switchMost = 400;

  /// What the quick switcher lists: the newest conversations ('c:<id>'), then the places to go to ('go:<place>').
  List<CommandDescriptor> _switchCommands() {
    final every = ConversationsScreen.live?.every ?? const <Conversation>[];
    return [
      for (final c in every.take(_switchMost))
        CommandDescriptor(
          id: 'c:${c.id}',
          label: c.title,
          group: 'Conversations',
          keywords: [for (final p in c.people) p.address].join(' '),
          detail: c.unread ? 'Unread' : null,
        ),
      // Only the places this device has (Keys.offered): no Marketplace in a browser.
      for (final (id, label, command) in _places)
        if (Keys.offered(command)) CommandDescriptor(id: 'go:$id', label: label, group: 'Go to', shortcut: Keys.instance.of(command)?.label),
    ];
  }

  /// Opens what was chosen in the switcher, by the id [_switchCommands] gave it.
  void _runSwitch(String id) {
    if (id.startsWith('c:')) {
      final want = int.tryParse(id.substring(2));
      final list = ConversationsScreen.live;
      final c = list?.every.where((c) => c.id == want).firstOrNull;
      if (list != null && c != null) list.openConversation(c);
      return;
    }
    switch (id.substring(3)) {
      case 'settings':
        settings();
      case 'shortcuts':
        settings('shortcuts');
      case final place:
        go(place);
    }
  }

  void _notice(PackNotice n) {
    if (!mounted) return;
    if (n.kind == 'withdrawn') {
      toast(context, n.words, action: GlacierToastAction(label: 'See it', onPress: () => marketplace(plugin: registryIdOf(n.packId))));
      return;
    }
    toast(context, n.words);
  }

  /// Put out of a circle by its owner or an admin (Circles.removeMember): said, since the circle just goes.
  void _removed() {
    final name = Circles.instance.removedFrom.value;
    if (name == null || !mounted) return;
    Circles.instance.removedFrom.value = null;
    toast(context, 'You were removed from $name');
  }

  StreamSubscription<CircleJoin>? _joins;

  /// The circles' invite words claimed again a little after starting (initState).
  Timer? _renewWords;

  /// Someone new in one of this device's circles, while the app is in front: said, with the way to the circle (Matt,
  /// 2026-11-19: "add join notifications for memebers in circles"). A phone in the background notifies instead
  /// (lib/main.dart). Not while that circle is the one open, whose members list has them already.
  void _someoneJoined(CircleJoin j) {
    if (!mounted || !AppState.of(context).flag('notif_joins')) return;
    if (WidgetsBinding.instance.lifecycleState case final s? when s != AppLifecycleState.resumed) return;
    if (openCircleSeed == j.circle.seed) {
      toast(context, j.line);
      return;
    }
    toast(context, j.line, action: GlacierToastAction(label: 'Open', onPress: () {
      final c = Circles.instance.bySeed(j.circle.seed);
      if (c != null && mounted) openCircle(c);
    }));
  }

  /// Joins and opens the circle whose link was held from before the frame was up (lib/circles/pending_link.dart).
  Future<void> _takeHeldLink() async {
    final link = await PendingCircleLink.take(fresh: Circles.instance.all.isEmpty);
    if (link == null || !mounted) return;
    // On another relay than this app's: said, not joined (GMFB-25).
    final away = circleLinkElsewhere(link);
    if (away != null) return toast(context, away, tone: GlacierToastTone.danger);
    final c = Circles.instance.joinLink(link);
    if (c == null || !mounted) return;
    openCircle(c, land: true);
    toast(context, 'You joined ${c.name}');
  }

  StreamSubscription<String>? _ringActions;

  /// Answer or Decline on a friend's call's notification (android IncomingCall.kt, GMFB-28).
  Future<void> _ringAction(String what) async {
    final v = Voice.instance;
    final r = v.ringing;
    if (r == null || r.call == null) return;
    if (what == 'decline') return v.dismissRing();
    try {
      await v.join(r.channel, video: r.video);
      if (mounted) go('voice');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t answer: $e', tone: GlacierToastTone.danger);
    }
  }

  /// A call to a friend that ended unanswered (GMFB-28): said, as a phone says it.
  void _callEnded() {
    final why = FriendCalls.instance.ended.value;
    if (why == null || !mounted) return;
    FriendCalls.instance.ended.value = null;
    toast(context, why);
  }

  @override
  void dispose() {
    FriendCalls.instance.ended.removeListener(_callEnded);
    _ringActions?.cancel();
    unawaited(_names?.cancel());
    HardwareKeyboard.instance.removeHandler(_key);
    if (identical(live, this)) live = null;
    Voice.instance.removeListener(_voiceChanged);
    Circles.instance.removedFrom.removeListener(_removed);
    Circles.instance.removeListener(_landIfReady);
    unawaited(_joins?.cancel());
    for (final sub in _notices) {
      unawaited(sub.cancel());
    }
    _renewWords?.cancel();
    _small.dispose();
    closed.dispose();
    archived.dispose();
    archivedUnread.dispose();
    messagesUnread.dispose();
    settingsSection.dispose();
    marketSection.dispose();
    super.dispose();
  }

  /// The pane's route for [page], arriving as [_arrive] says.
  PageRouteBuilder<void> _route(Widget page) => PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => _PanePage(child: page),
        transitionsBuilder: _arrive,
      );

  /// How a page arrives. Beside the list a page takes the place of the last one, so it fades in; over the list it
  /// slides across it, as a phone's pages do.
  static Widget _arrive(BuildContext context, Animation<double> a, Animation<double> _, Widget child) => AppShell.wideOf(context)
      ? FadeTransition(opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.55)), child: child)
      : SlideTransition(
          position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
          child: child,
        );

  /// Opens [page] in the pane, in place of whatever was there. [thread] is the conversation it is, for the list to
  /// mark; [showing] is the pill's ring it is ('new', 'contacts', 'settings'), for the pill to fill; [section] is
  /// the section of Settings it is, for Settings' list to mark.
  void show(Widget page, {int? thread, String? showing, String? section}) {
    final nav = _pane.currentState;
    if (nav == null) {
      // Asked for before the first frame (a notification that opened the app): once there is a pane.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pane.currentState != null) show(page, thread: thread, showing: showing, section: section);
      });
      return;
    }
    final route = _route(page);
    final had = _open != null;
    setState(() {
      _open = route;
      _thread = thread;
      _showing = showing;
    });
    settingsSection.value = showing == 'settings' ? section : null;
    marketSection.value = showing == 'marketplace' ? section : null;
    // Anything but a page of Settings puts Settings' list away: a conversation, a new chat and the contacts are
    // kept with the conversations. The Marketplace's likewise, gone at once: its popped future comes too late for
    // whatever is asked next.
    if (showing != 'settings' && settingsOpen) home();
    if (showing != 'marketplace' && marketOpen) {
      home();
      setState(() => _market = null);
    }
    nav.pushAndRemoveUntil(route, (r) => r.isFirst);
    // The list under a page that covers it is not drawn, and is drawn again as the page starts to leave.
    route.animation?.addStatusListener((_) {
      if (mounted && _open == route) setState(() {});
    });
    route.popped.then((_) {
      if (!mounted || _open != route) return;
      setState(() {
        _open = null;
        _thread = null;
        _showing = null;
        _sideHidden = false;
      });
      settingsSection.value = null;
      marketSection.value = null;
      closed.value++;
    });
    if (had) closed.value++;
  }

  /// Opens a conversation. One already open is left as it is, with whatever is half written in it.
  void openThread(int thread, List<Person> people, {String? draft}) {
    if (_thread == thread && _open != null && _open!.isCurrent && draft == null) return;
    show(ThreadScreen(key: ValueKey('thread-$thread-${draft == null ? '' : draft.hashCode}'), thread: thread, people: people, draft: draft), thread: thread);
  }

  /// Opens the new-message page, [body] already written where another app sent some words to text.
  void compose({String? body}) => show(ComposeScreen(key: UniqueKey(), body: body), showing: 'new');

  /// Takes Settings away, back to whatever it was opened over (the conversations, or a circle), its page going with it
  /// (Matt, 2026-11-18: "add a back arrow to the settings page"; Settings' back arrow beside its page).
  void closeSettings() {
    final route = _settings;
    if (route == null) return;
    final side = _side.currentState;
    if (side != null && route.isActive) side.removeRoute(route);
    // removeRoute does not complete [route.popped] the way a pop does: Settings' page is put away here instead.
    if (_settings == route) setState(() => _settings = null);
    if (_showing == 'settings') close();
  }

  /// Opens Settings, or the one [section] of it ([seek]: a setting on that section's page to scroll to). Settings'
  /// list of sections takes the list's place, and the section's page is the pane's: beside the list in a wide
  /// window, where the first section is opened if none is named, and over it on a phone.
  void settings([String? section, String? seek]) {
    // Plugins left Settings for the Marketplace (Matt, 2026-11-20): `ui.openSettings('plugin-spam')` and any old link
    // to Settings › Plugins open Discover there, at the plugin.
    if (section == 'plugins' || (section?.startsWith('plugin-') ?? false)) return marketplace(section: 'discover', plugin: section == 'plugins' ? null : section!.substring('plugin-'.length), seek: seek);
    if (marketOpen) closeMarketplace();
    final side = _side.currentState;
    if (side == null) {
      // Asked for before the first frame: once there is a list.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _side.currentState != null) settings(section, seek);
      });
      return;
    }
    if (!settingsOpen) {
      final route = PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => const SettingsScreen(key: ValueKey('settings')),
        transitionsBuilder: _arrive,
      );
      setState(() => _settings = route);
      side.push(route);
      route.popped.then((_) {
        if (!mounted || _settings != route) return;
        setState(() => _settings = null);
        // Its page goes with it.
        if (_showing == 'settings') close();
      });
    }
    // Beside the list there is always a section's page: the first listed, where none is named and none is open (the
    // unlisted Plugins section, a plugin's own, would open with no row marked).
    if (section == null && _wide && settingsSection.value == null) section = settingsSections.where((s) => s.listed && s.when == null).firstOrNull?.id;
    if (section != null) {
      show(SettingsSectionScreen(section, key: ValueKey('settings-$section-${seek ?? ''}'), seek: seek), showing: 'settings', section: section);
    } else if (!_wide && _showing == 'settings') {
      // On a phone, Settings asked for from one of its pages is its list.
      close();
    }
  }

  /// Opens [circle] in the list's place, with a way back at its top (lib/ui/circles/circle_screen.dart); beside it in
  /// a wide window its first space is opened, as Settings opens its first section. Its spaces open in the pane
  /// (`showing: 'circle'`), and go with it when it is left.
  /// Opens [c]'s chat where it is listed: a circle's space in its circle, a space of one's own in the Voice page (a
  /// mention's notification; Matt, 2026-11-19: "Add mentions support to spaces and circles with the @user prefix").
  void openSpace(VoiceChannel c) {
    final circle = Circles.instance.circleOf(c);
    if (circle != null) {
      openCircleSpaceSeed.value = c.seed;
      if (_circleSeed != circle.seed) openCircle(circle);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _side.currentContext;
        if (mounted && ctx != null) openCircleSpace(ctx, c);
      });
      return;
    }
    Voice.instance.view(c);
    go('voice');
  }

  ///
  /// [land]: just joined, so it opens on its welcome space (Matt, 2026-11-20: "allow setting a "welcome" channel";
  /// lib/circles/welcome.dart), on a phone as well, as soon as its manifest says which that is (a link's circle has only
  /// its name until then).
  void openCircle(Circle circle, {bool land = false}) {
    final side = _side.currentState;
    if (side == null) {
      // Asked for before the first frame: once there is a list.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _side.currentState != null) openCircle(circle, land: land);
      });
      return;
    }
    _landing = land ? (seed: circle.seed, until: DateTime.now().add(const Duration(minutes: 2))) : null;
    if (_showing != null) close();
    // From one circle to another, and beside the pane on a computer, its list is there at once (Matt, 2026-11-25:
    // "show the sidebar immediately as it animates in from the right and briefly shows the main chat sidebar when
    // switching between spaces"): the circle left slid away as the next slid in, with the conversations seen between
    // them. A phone coming from its conversations keeps the slide, as its other pages have.
    final atOnce = _wide || _circle != null;
    side.popUntil((r) => r.isFirst);
    final route = PageRouteBuilder<void>(
      transitionDuration: atOnce ? Duration.zero : const Duration(milliseconds: 200),
      reverseTransitionDuration: _wide ? Duration.zero : const Duration(milliseconds: 160),
      pageBuilder: (context, _, _) => CircleScreen(key: ValueKey('circle-${circle.seed}'), seed: circle.seed),
      transitionsBuilder: (context, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
        child: child,
      ),
    );
    setState(() {
      _circle = route;
      _circleSeed = circle.seed;
    });
    side.push(route);
    route.popped.then((_) {
      if (!mounted || _circle != route) return;
      setState(() {
        _circle = null;
        _circleSeed = null;
      });
      // Its spaces go with it, and its settings or a new space of it open in the pane.
      if (_circlePage) close();
    });
    if (land && _landIfReady()) return;
    if (_wide) {
      // Its welcome space where it has one, else its first.
      final first = Circles.instance.landingOf(Circles.instance.bySeed(circle.seed) ?? circle) ?? circle.channels.firstOrNull;
      if (first != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _side.currentContext;
          if (mounted && _circle == route && ctx != null) openCircleSpace(ctx, first);
        });
      }
    }
  }

  /// A circle just joined, to be opened on its welcome space once its manifest names one, for a little while.
  ({String seed, DateTime until})? _landing;

  /// Opens the circle just joined on its welcome space, where its manifest names one now; true where it did.
  bool _landIfReady() {
    final l = _landing;
    if (l == null || !mounted) return false;
    final c = Circles.instance.bySeed(l.seed);
    if (c == null || _circleSeed != l.seed || DateTime.now().isAfter(l.until)) {
      _landing = null;
      return false;
    }
    final to = Circles.instance.landingOf(c);
    if (to == null) return false;
    _landing = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _side.currentContext;
      if (mounted && _circleSeed == c.seed && ctx != null) openCircleSpace(ctx, to);
    });
    return true;
  }

  /// What is open in the pane is the circle's own: one of its spaces, its settings, or a new space of it.
  bool get _circlePage => _showing == 'circle' || _showing == CircleDock.settings || _showing == CircleDock.newSpace;

  /// A space is open in the pane on its own, not as a circle's: the Voice page, which a space from the list opens in,
  /// or a Files space's files.
  bool get _loosePage => _showing == 'voice' || (_showing?.startsWith('files:') ?? false);

  /// Back to the main layout: the circle in the list's place is closed, with whatever of it is open in the pane, and
  /// the list is the conversations again (Home on the circle's dock).
  void leaveCircle() {
    if (_circlePage) close();
    home();
  }

  /// A ring of the app's own dock. From inside a circle, or with a space open on its own, the circle and the space are
  /// put away first, so every place the dock goes to is the main layout's (Matt, 2026-11-17: "when we're inside a
  /// space navigating to archive, contacts, settings, new, chat should take us back to the main home layout"). Only
  /// the dock's presses: a press inside a circle's space that asks for the call ([go] 'voice') leaves the circle
  /// where it is.
  void _dockGo(String id) {
    if (circleOpen || _circlePage) leaveCircle();
    if (_loosePage) close();
    go(id);
  }

  /// A ring of the circle's dock ([CircleDock.items]), for the circle open in the list's place.
  void _circleGo(String id) {
    final c = _circleSeed == null ? null : Circles.instance.bySeed(_circleSeed!);
    final side = _side.currentState;
    if (id == CircleDock.home || c == null || side == null) return leaveCircle();
    // Opened from inside the frame, so what opens finds the shell (a text's invite goes to a new chat here).
    final inside = _side.currentContext ?? context;
    switch (id) {
      case CircleDock.spaces:
        // The circle's list, with anything opened over it in the list's place taken away. Beside it the pane shows
        // a space again, the one last open there (else its first); on a phone the list is the screen.
        side.popUntil((r) => r == _circle || r.isFirst);
        if (_showing == 'circle') return;
        if (!_wide) {
          if (_open != null) close();
          return;
        }
        final last = c.channels.where((ch) => ch.seed == openCircleSpaceSeed.value).firstOrNull ?? c.channels.firstOrNull;
        if (last != null) {
          openCircleSpace(inside, last);
        } else if (_open != null) {
          close();
        }
      case CircleDock.members:
        unawaited(showCircleMembers(inside, c));
      case CircleDock.invite:
        // As the circle's roles say (lib/circles: CirclePerm.invite).
        if (!Circles.instance.can(c, CirclePerm.invite)) {
          toast(inside, 'Your role in ${c.name} can\'t invite people.');
        } else {
          unawaited(showCircleInvite(inside, c));
        }
      case CircleDock.newSpace:
        openCircleNewSpace(inside, c);
      case CircleDock.settings:
        // The app's own Settings, as the dock's cog is everywhere else (Matt, 2026-11-18: "make the settings button in
        // circles dock open the global app settings"); a circle's are under its name at the top of the sidebar.
        settings();
    }
  }

  /// The section in the pane is no longer one of Settings' (a plugin's page, and the plugin was switched off): the
  /// page goes, and beside the list the first section takes its place (Settings' list sees to that).
  void settingsGone() {
    if (_showing == 'settings') close();
  }

  /// Opens the Marketplace, or one [section] of it. [plugin] (a registry id, 'xbills', or a built-in's, 'codes') opens
  /// Discover at that plugin's page; [seek] is a setting on that page to light (a Settings search found it); [arg] is
  /// the section's own: a dev pack's id for `submit` (the form starts with that pack), a submission's sid for `mine`
  /// (marked and scrolled to).
  void marketplace({String? section, String? plugin, String? seek, String? arg}) {
    // None in a browser, however it is asked for (a key, a link, an old way into Settings › Plugins): it has nowhere to
    // keep a plugin (lib/web/app.dart).
    if (Sms.browser) return;
    final side = _side.currentState;
    if (side == null) {
      // Asked for before the first frame (`ui.openSettings('plugins')`, a link): once there is a list.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _side.currentState != null) marketplace(section: section, plugin: plugin, seek: seek, arg: arg);
      });
      return;
    }
    if (settingsOpen) closeSettings();
    if (!marketOpen) {
      final route = PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => const MarketplaceScreen(key: ValueKey('marketplace')),
        transitionsBuilder: _arrive,
      );
      setState(() => _market = route);
      side.push(route);
      route.popped.then((_) {
        if (!mounted || _market != route) return;
        setState(() => _market = null);
        // Its page goes with it.
        if (_showing == 'marketplace') close();
      });
    }
    // Which section: the one named; Discover for a plugin or a setting; beside the list, Discover where nothing is in
    // the pane yet; and Discover for one not offered now (developer mode off, an admin signed out).
    var id = section;
    if (id == null && (plugin != null || seek != null)) id = 'discover';
    if (id == null && _wide && marketSection.value == null) id = 'discover';
    if (id != null && !marketOffered(id, AppState.of(context), current: marketSection.value)) id = 'discover';
    if (id != null) {
      show(MarketSectionScreen(id, plugin: plugin, seek: seek, arg: arg, key: ValueKey('market-$id-${plugin ?? ''}-${seek ?? ''}-${arg ?? ''}')), showing: 'marketplace', section: id);
    } else if (!_wide && _showing == 'marketplace') {
      // On a phone, the Marketplace asked for from one of its pages is its list.
      close();
    }
  }

  /// Takes the Marketplace away, back to what it was opened over, its page going with it: at once, as a pop's future
  /// would come too late for the next call.
  void closeMarketplace() {
    final route = _market;
    if (route == null) return;
    final side = _side.currentState;
    if (side != null && route.isActive) side.removeRoute(route);
    if (_market == route) setState(() => _market = null);
    if (_showing == 'marketplace') close();
  }

  /// The section in the pane is no longer offered (developer mode went off, the admin signed out): the page goes, and
  /// beside the list Discover takes its place (the Marketplace's list sees to that).
  void marketGone() {
    if (_showing == 'marketplace') close();
  }

  /// Opens the address book: a press on someone in it opens the conversation with them.
  void contacts() => show(const ContactsScreen(key: ValueKey('contacts')), showing: 'contacts');

  /// Opens the call this device is in: its bar's press, and Back to the call on its floating picture (GMFB-64). A
  /// developer design draws the call as a page of its own on a phone; beside the list a circle's space opens in its
  /// circle, the call over its chat (SpaceSplit); else the Voice page.
  void openCall() {
    if (!_wide && openSpaceCall(context)) return;
    final s = Voice.instance.session;
    if (_wide && s != null && s.channel.hangout && Circles.instance.circleOf(s.channel) != null) return openSpace(s.channel);
    go('voice');
  }

  /// One of the pill's rings is pressed. A new chat and the contacts open in the pane; Settings takes the list's
  /// place with its page in the pane; Messages and Archive are the list itself, and put away whatever was open.
  void go(String id, {bool selectAll = false}) {
    switch (id) {
      case 'new':
        // A new chat, a group, or a voice call (Matt, 2026-11-15: "The new button should also ask for new chat, group
        // or voice call").
        showChoices(context, title: 'Start something new', choices: [
          Choice('New chat', Lucide.messageSquarePlus, () => compose()),
          Choice('New group', Lucide.users, () => show(const NewGroupScreen(key: ValueKey('new-group')), showing: 'new')),
          Choice('New space', LucideMore.headphones, () => show(const NewChannelScreen(key: ValueKey('new-voice')), showing: 'new')),
          // A circle: people and a sidebar of their own spaces (lib/ui/circles).
          Choice('New circle', Lucide.circle, () => show(const NewCircleScreen(key: ValueKey('new-circle')), showing: 'new')),
          // Its invite link pasted: in at once, its spaces in the list's place.
          Choice('Join a circle by link', Lucide.link2, _joinByLink),
          // A Discord server's voice channels as a group of spaces (lib/ui/space_groups_ui.dart): voice, so not in a
          // browser, which has no calls yet (Sms.callsHere).
          if (Sms.callsHere) Choice('Add a Discord server', Lucide.link, () => show(const AddDiscordScreen(key: ValueKey('add-discord')), showing: 'new')),
        ]);
      case 'contacts':
        contacts();
      case 'voice':
        // Voice channels, and the call you're in (lib/ui/voice_screen.dart).
        show(const VoiceScreen(key: ValueKey('voice')), showing: 'voice');
      case 'settings':
        settings();
      case 'marketplace':
        marketplace();
      default:
        // The Marketplace is over whatever is in the list's place (Archive): put away first, at once, so what is under
        // it is seen by the checks below (Archive, then the Marketplace, then Archive again left the Marketplace up).
        if (marketOpen) closeMarketplace();
        if (_showing != null) close();
        final side = _side.currentState;
        if (side == null) return;
        // The Archived list as it stands, unless Settings is over it or it is asked for with everything chosen.
        if (id == 'archive' && _archivedOpen && !settingsOpen && !selectAll) return;
        side.popUntil((r) => r.isFirst);
        if (id != 'archive') return;
        final route = PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 200),
          reverseTransitionDuration: const Duration(milliseconds: 160),
          pageBuilder: (context, _, _) => ConversationsScreen(archived: true, selectAll: selectAll),
          // Slid in, not faded: a fading page is drawn apart and laid over the list under it on every frame (an
          // emulator's pass over every page, 2026-11-17: 11 to 17 ms a frame opening an empty Archive, where every
          // other page drew in 2 to 3).
          transitionsBuilder: (context, a, _, child) => SlideTransition(
            position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic)),
            child: child,
          ),
        );
        setState(() => _archive = route);
        side.push(route);
        route.popped.then((_) {
          if (mounted && _archive == route) setState(() => _archive = null);
        });
    }
  }

  /// Asks for a circle's invite link and joins it: in at once, its spaces in the list's place.
  void _joinByLink() => askCircleWords(context, title: 'Join a circle', hint: 'Paste the invite link someone sent you, or its invite word.', then: (text) async {
        var link = Circles.linkIn(text) ?? text;
        // An invite word, as gogho.st/c/bookclub or the word alone (lib/circles/invite_word.dart): the relay is asked
        // for the circle's link it is.
        final word = Circles.linkIn(text) == null ? (inviteWordIn(text) ?? (text.contains('/') ? null : tidyInviteWord(text))) : null;
        if (word != null) {
          try {
            final got = await InviteWords().resolve(word);
            if (!mounted) return;
            if (got == null) return toast(context, 'No circle has the invite word "$word".', tone: GlacierToastTone.danger);
            link = got;
          } catch (e) {
            if (mounted) toast(context, 'Couldn\'t look up "$word": ${e is InviteRelayError ? e.message : e}', tone: GlacierToastTone.danger);
            return;
          }
        }
        // On another relay than this app's (the link says which, GMFB-25): said, in place of joining rooms nobody is in.
        final away = circleLinkElsewhere(link);
        if (away != null) return toast(context, away, tone: GlacierToastTone.danger);
        final c = Circles.instance.joinLink(link);
        if (c == null) {
          toast(context, 'That isn\'t a circle\'s invite link.', tone: GlacierToastTone.danger);
          return;
        }
        openCircle(c, land: true);
      });

  /// The rail's plus under the circles: a new circle, or one joined by its link.
  void _addCircle() => showChoices(context, title: 'Add a circle', choices: [
        Choice('New circle', Lucide.circle, () {
          if (circleOpen) leaveCircle();
          show(const NewCircleScreen(key: ValueKey('new-circle')), showing: 'new');
        }),
        Choice('Join a circle by link', Lucide.link2, _joinByLink),
      ]);

  /// A circle pressed in the rail: opened in the list's place, or, already open, back to its spaces.
  void _railCircle(Circle c) {
    if (_circleSeed == c.seed && circleOpen) return _circleGo(CircleDock.spaces);
    if (_loosePage) close();
    openCircle(c);
  }

  /// How the app is got round, as chosen in Settings › Developer (lib/ui/nav_style.dart).
  NavStyle get _style => NavStyle.of(AppState.of(context));

  /// The rings the app's own navigation has, in the pill's order: New, Messages, Contacts, Archive, Marketplace and
  /// Settings.
  List<NavItem> _appRings(int archivedCount) => [
        // A plain plus that says New: it starts a chat, a group or a space (Matt, 2026-11-17: "change the new chat
        // button to be a generic plus button and change the tooltip to simply say \"new\"").
        const NavItem(id: 'new', icon: Lucide.plus, label: 'New'),
        NavItem(id: 'messages', icon: Lucide.messageSquare, label: 'Messages', count: messagesUnread.value),
        // Contacts with how many friend requests wait for an answer there (lib/ui/username_friends.dart).
        NavItem(id: 'contacts', icon: Lucide.contactRound, label: 'Contacts', count: Sms.paired ? 0 : Buddies.instance.requests.length),
        NavItem(id: 'archive', icon: Lucide.archive, label: 'Archive', count: archivedCount, menu: _archiveRows),
        // The Marketplace, with how many updates wait (Matt, 2026-11-20: "Move plugins out of settings into a marketplace
        // button on the navigation rail with a marketplace icon"): "Market" on Dial-Up's taskbar, where six words share it.
        // Not in a browser, which has nowhere to keep a plugin and no texts for one to sort (Sms.browser).
        if (!Sms.browser) NavItem(id: 'marketplace', icon: Lucide.store, label: 'Marketplace', short: 'Market', count: MarketState.instance.updates.length, menu: _marketRows),
        NavItem(id: 'settings', icon: Lucide.settings, label: 'Settings', count: Me.instance.unseen, menu: _settingsRows),
      ];

  /// The ring that is the page shown: none while a circle is open, whose face the rail marks instead.
  String get _activeRing => _showing ?? (settingsOpen ? 'settings' : (marketOpen ? 'marketplace' : (_archivedOpen ? 'archive' : (circleOpen ? 'circle' : 'messages'))));

  /// The rail (NavStyle.rail): Home, the circles, the app's places at its foot.
  Widget _rail() => ValueListenableBuilder<int>(
        valueListenable: archivedUnread,
        builder: (context, _, _) => ListenableBuilder(
          listenable: Listenable.merge([Me.instance, Voice.instance, Buddies.instance, Circles.instance, MarketState.instance, InstalledPlugins.instance, Inbox.instance.changes, messagesUnread]),
          builder: (context, _) {
            final rings = _appRings(_archiveBadge);
            return NavRail(
              circles: Circles.instance.all,
              openCircle: circleOpen ? _circleSeed : null,
              home: rings.firstWhere((r) => r.id == 'messages'),
              items: [for (final r in rings) if (r.id != 'messages') r],
              active: _activeRing,
              onSelect: _dockGo,
              onCircle: _railCircle,
              onCircleMenu: (c) => showCircleMenu(context, c),
              onAddCircle: _addCircle,
              // Share feedback above Settings: on a phone, where it was beside the search (lib/ui/conversations.dart).
              // Share feedback is a row under the search now (lib/ui/conversations.dart, QuickRow; Matt, 2026-11-20).
              onFeedback: null,
              // The whole profile, from the bubble's card: in the pane, or over the list on a phone.
              onProfile: Sms.followsPhone ? null : () => show(const ProfileScreen(), showing: 'profile'),
            );
          },
        ),
      );

  // The rings' own menus (Matt, 2026-11-14: "add a right click context menu to archive as well and settings to
  // quick jump to settings sections"): a press with the other button on a ring, or a long press where there is no
  // other button, hangs a small list over it (lib/ui/nav_bar.dart `NavItem.menu`). They were a sheet across the
  // window's foot, as the list's tabs' menus are, which for Settings' many sections Matt found "too large and way
  // too wide".

  /// The Archive ring's menu: the tabs' own two choices, for the conversations put away.
  List<Widget> _archiveRows(BuildContext context) {
    final n = archived.value;
    return [
      GlacierMenuLabel(child: Text(n == 0 ? 'Archive · nothing archived' : 'Archive · $n ${n == 1 ? 'conversation' : 'conversations'}')),
      GlacierMenuItem(icon: const AppIcon(Lucide.checkCheck, size: 16), onSelect: _archiveRead, child: const Tr('Mark all as read')),
      // Every archived conversation chosen at once, for the bar at the top to take back out or delete.
      if (n > 0) GlacierMenuItem(icon: const AppIcon(Lucide.listChecks, size: 16), onSelect: () => go('archive', selectAll: true), child: const Tr('Select all')),
    ];
  }

  /// The Settings ring's menu: Settings' sections by name, in their groups, each opening Settings there. They are
  /// the sections as they stand for this device and these choices (a plugin's own, while it is on). A group of
  /// several is under its name; one section alone needs none.
  List<Widget> _settingsRows(BuildContext context) {
    final model = SettingsModel(AppState.of(this.context));
    final groups = <String, List<SettingsSection>>{};
    for (final s in settingsSections) {
      if (s.listed && (s.when?.call(model) ?? true)) groups.putIfAbsent(s.group, () => []).add(s);
    }
    model.dispose();
    final rows = <Widget>[];
    for (final group in groups.entries) {
      if (rows.isNotEmpty) rows.add(const GlacierMenuSeparator());
      if (group.value.length > 1) rows.add(GlacierMenuLabel(child: Text(settingsGroupLabel(group.key))));
      for (final s in group.value) {
        final icon = s.icon;
        rows.add(GlacierMenuItem(icon: icon is AppIcon ? AppIcon(icon.icon, size: 16) : icon, onSelect: () => settings(s.id), child: Text(s.label)));
      }
    }
    return rows;
  }

  /// The Marketplace ring's menu: its sections offered now, each opening the Marketplace there.
  List<Widget> _marketRows(BuildContext context) {
    final app = AppState.of(this.context);
    return [
      const GlacierMenuLabel(child: Tr('Marketplace')),
      for (final s in marketSectionsNow(app, current: marketSection.value)) GlacierMenuItem(icon: AppIcon(s.icon, size: 16), onSelect: () => marketplace(section: s.id), child: Text(s.label)),
    ];
  }

  /// Marks every archived conversation that is unread as read, from the Archive ring's menu: where they are, with
  /// the archive left closed.
  Future<void> _archiveRead() async {
    final List<Conversation> unread;
    try {
      unread = (await Sms.instance.conversationsPage(archived: true)).items.where((c) => c.unread).toList();
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t read the archive: $e', tone: GlacierToastTone.danger);
      return;
    }
    if (!mounted) return;
    // Signal's, Telegram's and the rest archived, read on their networks too.
    final chats = [for (final n in Inbox.instance.ready) for (final c in n.archivedChats) if (c.unread > 0) (n, c)];
    for (final (n, c) in chats) {
      unawaited(n.markRead(c.id));
    }
    if (unread.isEmpty && chats.isEmpty) return toast(context, 'Nothing is unread in the archive');
    var failed = 0;
    for (final c in unread) {
      try {
        await Sms.instance.markRead(c.id);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    // The lists read their conversations again, and the Archive ring counts what is still unread.
    closed.value++;
    unawaited(countArchivedUnread());
    final n = unread.length + chats.length - failed;
    toast(
      context,
      failed == 0 ? '$n ${n == 1 ? 'conversation' : 'conversations'} marked as read' : '$n marked as read; $failed could not be',
      tone: failed == 0 ? GlacierToastTone.neutral : GlacierToastTone.danger,
    );
  }

  /// Closes what is open in the pane.
  void close() => _pane.currentState?.popUntil((r) => r.isFirst);

  /// Takes the list back to the conversations, from Archived or from Settings.
  void home() => _side.currentState?.popUntil((r) => r.isFirst);

  /// Says that [child] stands in a column of the window [width] wide, where it does: the list beside a pane.
  /// Always there, so the list keeps its place in the tree as the window changes: a width without end says the
  /// list is the whole window.
  Widget _column(bool beside, double width, Widget child) => HeaderColumn(left: 0, width: beside ? width : double.infinity, child: child);

  /// The way round: a new chat, the messages, the contacts, the archive with how many are in it, Settings with how
  /// many watched for have joined (Settings › Friends joining).
  Widget _pill({required bool upright}) => ValueListenableBuilder<int>(
        valueListenable: archivedUnread,
        builder: (context, _, _) => ListenableBuilder(
          listenable: Listenable.merge([Me.instance, Voice.instance, Buddies.instance, Circles.instance, MarketState.instance, InstalledPlugins.instance, Inbox.instance.changes, messagesUnread]),
          builder: (context, _) {
            // A circle in the list's place: its own dock, Home first (lib/ui/circles/circle_dock.dart).
            // Not where every page has the same navigation (NavStyle.unified): the app's own rings stay.
            final circle = circleOpen && _circleSeed != null && !_style.unified ? Circles.instance.bySeed(_circleSeed!) : null;
            if (circle != null) {
              return NavPill(
                key: const ValueKey('circle-dock'),
                upright: upright,
                hue: circle.hue,
                active: _showing == CircleDock.settings || _showing == CircleDock.newSpace ? _showing! : CircleDock.spaces,
                onSelect: _circleGo,
                items: CircleDock.items(circle, canEdit: Circles.instance.can(circle, CirclePerm.spaces)),
              );
            }
            return NavPill(
            upright: upright,
            active: _activeRing,
            onSelect: _dockGo,
            items: _appRings(_archiveBadge),
          );
          },
        ),
      );

  /// How many rings the pill has: what a window must be tall enough for, to have it stood up. The most any dock has:
  /// a circle's, its face and five rings, and the app's own six; a list leaves room for the one it has.
  static const _rings = 6;

  /// The rings on the pill now: a circle's face and its rings while one is open, else the app's six.
  int get _dockRings {
    final c = circleOpen && _circleSeed != null && !_style.unified ? Circles.instance.bySeed(_circleSeed!) : null;
    return c == null ? _appRings(0).length : CircleDock.items(c, canEdit: Circles.instance.can(c, CirclePerm.spaces)).length;
  }

  static Widget _lightsIf(bool on, Widget child) => on ? TopBarLights(child: child) : child;

  /// [child] told its own box is the screen's size, so the list and the pane each lay out for their share.
  Widget _sized(Widget child) => LayoutBuilder(
        // The screens measure themselves against the screen they are on: here that is their share of the window.
        builder: (context, box) => MediaQuery(data: MediaQuery.of(context).copyWith(size: Size(box.maxWidth, box.maxHeight)), child: child),
      );

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= AppShell.wideAt;
      _wide = wide;
      _dragged ??= PaneWidth.of(AppState.of(context), 'list');
      // The navigation chosen (Settings › Developer): the rail is a column of its own at the window's left, the list
      // and the pane to its right; on a phone a page opened over the list covers it too.
      final style = _style;
      final railed = style == NavStyle.rail;
      final railW = railed ? NavRail.width(t) + MediaQuery.paddingOf(context).left : 0.0;
      final room = box.maxWidth - railW;
      // The list put away (KeyCommand.toggleSidebar): the pane takes its room. With nothing open the list comes back,
      // so the window is never empty.
      final hidden = wide && _sideHidden && _open != null;
      final side = hidden ? 0.0 : wide ? AppShell.sideWidthAt(room, _dragged) : room;
      // A wide phone has the pill stood up at its right, where the window is tall enough for it (not a small phone
      // on its side). The strip is as wide as the pill and its room, and clear of anything cut into the screen's edge.
      final edges = MediaQuery.paddingOf(context);
      // No longer: beside a pane the pill floats over the list's foot, as on the Mac (Matt, 2026-11-14: "there is a
      // reserved spot for the navbar instead of the nav floating over the left sidebar"). It had a strip of its own
      // at the window's right.
      // The rail chosen in Settings › Developer: the lists leave only a step at their end, there being no pill.
      final rail = railed;
      // Folded, it stands up too (Matt, 2026-11-14: "Folded: make it vertical"), floating in the list's bottom right
      // corner, with no strip: on a narrow screen every bit of width is the list's.
      // Dial-Up's taskbar is always a strip along the foot (NavPill), never stood up in a corner.
      final dialup = isBevelChrome(t);
      final docked = !railed && !dialup && !wide && !Sms.computer && box.maxHeight - edges.vertical >= NavPill.railHeight(t, _rings) + t.lenOf('8rem');
      // A page that has finished sliding over the list covers all of it.
      final covered = !wide && _open != null && _open!.animation?.status == AnimationStatus.completed;
      return _ShellScope(
        shell: this,
        wide: wide,
        rail: rail,
        docked: docked,
        thread: _open == null ? null : _thread,
        showing: _open == null ? null : _showing,
        rings: _dockRings,
        child: PopScope(
          canPop: !(_paneBack || _sideBack),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            // Beside Settings' list its page is all there is to go back from: back leaves Settings whole.
            if (wide && settingsOpen && _showing == 'settings' && (_open?.isCurrent ?? false)) return go('messages');
            // The Marketplace beside its page likewise.
            if (wide && marketOpen && _showing == 'marketplace' && (_open?.isCurrent ?? false)) return go('messages');
            // What is open closes first; then the list goes back from Archived or Settings, or stops choosing.
            (_paneBack ? _pane : _side).currentState?.maybePop();
          },
          child: ColoredBox(
            color: t.color('glacier-bg'),
            child: Stack(children: [
              if (railed)
                PositionedDirectional(
                  key: const ValueKey('shell-rail'),
                  start: 0,
                  top: 0,
                  bottom: 0,
                  width: railW,
                  child: Offstage(offstage: covered, child: TickerMode(enabled: !covered, child: _rail())),
                ),
              if (railed) PositionedDirectional(key: const ValueKey('shell-rail-rule'), start: railW, top: 0, bottom: 0, width: 1, child: Offstage(offstage: covered, child: ColoredBox(color: t.color('app-rule')))),
              PositionedDirectional(
                key: const ValueKey('shell-side'),
                start: railW + (railed ? 1 : 0),
                top: 0,
                bottom: 0,
                width: hidden ? 0 : side - (railed ? 1 : 0),
                child: Offstage(
                  offstage: covered || hidden,
                  child: TickerMode(
                    enabled: !covered,
                    // The list is at the window's left: on the Mac its header leaves the window's three buttons room.
                    child: TopBarLights(child: HeaderCover(
                      covered: !wide && _open != null,
                      // Beside a pane the list is a column of the window: what hangs under its header (the update
                      // banner) is as wide as the list, not laid across list and pane both.
                      // Dial-Up beside a pane: the whole list in the era's raised window border, as its other windows
                      // are (_SideFrame).
                      // Not where the look's windows have no border of their own (`--app-chrome-frames: none`,
                      // Runestone): the list and the pane beside it are then two panels of one frame, their headings
                      // on one line (Matt, 2026-11-27: "two panels next to each other don't line up").
                      child: _column(wide, side, _SideFrame(on: dialup && wide && t.raw('app-chrome-frames')?.trim() != 'none', child: _sized(Stack(children: [
                        Positioned.fill(
                          child: NotificationListener<NavigationNotification>(
                            onNotification: (n) {
                              if (n.canHandlePop != _sideBack) setState(() => _sideBack = n.canHandlePop);
                              return false;
                            },
                            child: NotificationListener<ScrollNotification>(
                              onNotification: _pillHeard,
                              child: AppShell._apart(Navigator(
                              key: _side,
                              onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (context, _, _) => const ConversationsScreen()),
                            )),
                            ),
                          ),
                        ),
                        // In a space's call beside the pane the list stays as it is: the call is the top of the space's
                        // page in the pane, its chat under it (SpaceSplit; Matt, 2026-11-23: "leaving the sidebar
                        // unchanged so you can still quickly navigate the circle").
                        // The way round floats over the list's end, clear of the bar at the foot of a phone's
                        // screen; the list leaves it room (AppShell.pillRoom). Not on a wide phone, where it
                        // stands at the window's right.
                        // On a phone Settings is a page over the list, with its own way back and no bar under it.
                        PositionedDirectional(
                            start: docked ? null : 0,
                            end: docked ? edges.right : 0,
                            // Dial-Up's taskbar is silver down to the screen's edge, under the bar at its foot.
                            bottom: dialup ? 0 : edges.bottom,
                            child: IgnorePointer(
                              ignoring: !wide && (settingsOpen || marketOpen) && !style.unified,
                              child: AnimatedOpacity(
                                opacity: !wide && (settingsOpen || marketOpen) && !style.unified ? 0 : 1,
                                duration: const Duration(milliseconds: 160),
                                // Held to its corner as it shrinks: the foot's middle, or the corner it stands in.
                                // The rail is the navigation: nothing at the list's foot.
                                child: railed
                                        ? const SizedBox.shrink()
                                    : dialup
                                        ? ColoredBox(
                                            key: const ValueKey('taskbar'),
                                            color: DialupColors.of(t).chrome,
                                            child: Padding(padding: EdgeInsets.only(bottom: edges.bottom), child: _pill(upright: false)),
                                          )
                                    : docked
                                        ? ScaleTransition(
                                            key: const ValueKey('pill-scale'),
                                            scale: _pillScale,
                                            alignment: Alignment.bottomRight,
                                            child: _pill(upright: true),
                                          )
                                        // Laid along the list's foot it keeps the list's width as it grows smaller:
                                        // laid out wider by as much as it is scaled down, so the room round it stays
                                        // the same on its sides as under it (Matt, 2026-11-16: "make the navbar width
                                        // fit the full sidebar ... make the space on the left and right even to the
                                        // space on the bottom").
                                        : LayoutBuilder(
                                            key: const ValueKey('pill-scale'),
                                            builder: (context, box) => AnimatedBuilder(
                                              animation: _pillScale,
                                              child: _pill(upright: false),
                                              builder: (context, pill) {
                                                final k = _pillScale.value;
                                                final tall = NavPill.clearance(t) - NavPill.inset(t);
                                                return SizedBox(
                                                  width: box.maxWidth,
                                                  height: tall * k,
                                                  child: OverflowBox(
                                                    minWidth: box.maxWidth / k,
                                                    maxWidth: box.maxWidth / k,
                                                    minHeight: tall,
                                                    maxHeight: tall,
                                                    alignment: Alignment.bottomCenter,
                                                    child: Transform.scale(scale: k, alignment: Alignment.bottomCenter, child: pill),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                              ),
                            ),
                          ),
                        // The call you're in: a banner just above the dock (Matt, 2026-11-15: "switch the active
                        // call to be a banner again in the sidebar just above the navigation bar"); not while the call
                        // itself is open, nor under a page on a phone. Beside a dock stood up, it keeps clear of it.
                        // Beside the call's own space in the pane (SpaceSplit) the call is there to see: the banner is for
                        // looking at another space.
                        if (_showing != 'voice' && !(!wide && (settingsOpen || marketOpen || _open != null)) && !(wide && (_paneShowsCall || OpenSpaces.isCall(Voice.instance.session))))
                          PositionedDirectional(
                            start: t.space(3),
                            end: docked ? edges.right + NavPill.railWidth(t) : t.space(3),
                            bottom: edges.bottom + (railed ? t.space(3) : dialup ? NavPill.taskbarHeight + t.space(2) : docked ? NavPill.inset(t) : (NavPill.clearance(t) - NavPill.inset(t)) * (Sms.computer ? pillScrolledScale : 1) + t.space(2)),
                            child: CallBanner(onOpen: openCall),
                          ),
                      ])))),
                    )),
                  ),
                ),
              ),
              // The line between the list and the pane. Not under Dial-Up, where the list's own raised border ends it
              // (_SideFrame): the strip of teal desktop that stood there is gone (Matt, 2026-11-17: "remove the teal
              // divider line that we have on the dial up theme to the right of the sidebar, instead we should just use
              // the normal border here wrapping the whole sidebar in the standard border like we do for the rest of
              // elements").
              if (wide && !dialup && !hidden) PositionedDirectional(key: const ValueKey('shell-rule'), start: railW + side, top: 0, bottom: 0, width: 1, child: ColoredBox(color: t.color('app-rule'))),
              PositionedDirectional(
                key: const ValueKey('shell-pane'),
                start: wide ? railW + side + (dialup || hidden ? 0 : 1) : 0,
                top: 0,
                bottom: 0,
                end: 0,
                // With nothing open on a narrow screen the pane is empty air over the list: touches go through.
                // Over all of a narrow window, a page is at the window's left too.
                // With the list put away the pane is at the window's left, and leaves the Mac's three buttons room.
                child: _lightsIf(!wide || (hidden && !railed), IgnorePointer(
                  ignoring: !wide && _open == null,
                  child: _sized(NotificationListener<NavigationNotification>(
                    onNotification: (n) {
                      if (n.canHandlePop != _paneBack) setState(() => _paneBack = n.canHandlePop);
                      return false;
                    },
                    child: AppShell._apart(Navigator(
                      key: _pane,
                      observers: widget.paneObservers,
                      onGenerateRoute: (_) => PageRouteBuilder<void>(opaque: false, pageBuilder: (context, _, _) => const _Base()),
                    )),
                  )),
                )),
              ),
              // The line between the list and the pane, dragged to make the list wider or narrower; double clicked,
              // as it was made. Over both, so the pointer finds it on either side of the line.
              if (wide && !hidden)
                PositionedDirectional(
                  key: const ValueKey('shell-split'),
                  start: railW + side + (dialup ? 0 : 0.5) - SplitHandle.widthOf(context) / 2,
                  top: 0,
                  bottom: 0,
                  width: SplitHandle.widthOf(context),
                  child: SplitHandle(
                    label: 'Resize the list',
                    onDrag: (dx) => setState(() => _dragged = AppShell.sideWidthAt(room, AppShell.sideWidthAt(room, _dragged) + dx)),
                    onDone: () => PaneWidth.keep(AppState.of(context), 'list', _dragged),
                    onReset: () {
                      setState(() => _dragged = null);
                      PaneWidth.keep(AppState.of(context), 'list', null);
                    },
                  ),
                ),
              // The call's picture while its page is not on the screen (GMFB-64, lib/ui/call_float.dart): over the list
              // and the pane, under a call ringing.
              Positioned.fill(child: CallFloatLayer(onOpen: openCall)),
              // A group calling (lib/voice): over everything, until joined or put away.
              const PositionedDirectional(start: 0, end: 0, top: 0, child: RingCard()),
              // A friend's invite into a circle, or a circle's link opened from outside the app: said over everything
              // as it comes, with Join and Not now (lib/ui/circles/circle_invite_card.dart); it gives way to a call.
              const PositionedDirectional(start: 0, end: 0, top: 0, child: CircleInviteBanner()),
              // The quick switcher (KeyCommand.quickSwitch): it takes no room here and draws over everything while up.
              PositionedDirectional(
                start: 0,
                top: 0,
                width: 0,
                height: 0,
                child: GlacierCommandPalette(
                  key: const ValueKey('quick-switcher'),
                  open: _switcher,
                  onOpenChange: (v) => setState(() => _switcher = v),
                  // Its keys are Settings' to change (lib/keys.dart), not the kit's own Cmd+K.
                  shortcut: false,
                  placeholder: 'Jump to a conversation or a place…'.t,
                  emptyLabel: const Tr('Nothing by that name'),
                  commands: _switcher ? _switchCommands() : const [],
                  onRun: _runSwitch,
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

/// What the frame tells the pages under it, and tells again only when one of these changes: found by [AppShell]'s
/// static lookups.
class _ShellScope extends InheritedWidget {
  const _ShellScope({required this.shell, required this.wide, required this.rail, required this.docked, required this.thread, this.showing, this.rings = 5, required super.child});

  /// How many rings the pill stood up has, its circle's face among them: what a list leaves room for under it.
  final int rings;

  /// What else is open in the pane, by its name ([AppShell.show]'s `showing`): a Signal or Telegram chat is
  /// `inbox:<network>:<chat>`.
  final String? showing;
  final AppShellState shell;
  final bool wide;
  final bool rail;
  final bool docked;
  final int? thread;

  @override
  bool updateShouldNotify(_ShellScope old) => old.wide != wide || old.rail != rail || old.docked != docked || old.thread != thread || old.showing != showing || old.rings != rings;
}

/// A page open in the pane: it draws its way back only while the list is not beside it.
class _PanePage extends StatelessWidget {
  const _PanePage({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => PaneRoot(isBeside: AppShell.wideOf(context), child: child);
}

/// Under every page in the pane. Beside the list it is what the pane says with nothing open; over the list it is
/// nothing at all, and the list is seen through it.
class _Base extends StatelessWidget {
  const _Base();

  @override
  Widget build(BuildContext context) {
    if (!AppShell.wideOf(context)) return const SizedBox.expand();
    final own = AppShell.maybeOf(context)?.widget.nothing;
    return own != null ? own(context) : const _Nothing();
  }
}

/// The pane before a conversation is chosen.
class _Nothing extends StatelessWidget {
  const _Nothing();

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Dial-Up: with no window open there, the pane is the window's own silver and its words the window's ink; it was
    // the era's teal desktop, which Matt took out with the strip of it beside the list (2026-11-17: "use the normal
    // window colour").
    final dialup = isBevelChrome(t);
    final ink = dialup ? DialupColors.of(t).onChrome : null;
    return ColoredBox(
      color: dialup ? DialupColors.of(t).chrome : t.color('glacier-bg'),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(t.space(6)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            GhostLogo(size: t.lenOf('3.5rem')),
            SizedBox(height: t.space(4)),
            // The Circles tab lists circles, not conversations: it says so.
            ValueListenableBuilder(
              valueListenable: ConversationsScreen.shownTab,
              builder: (context, tab, _) {
                final circles = tab == ConversationsScreen.circlesTab;
                return Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(circles ? 'Choose a circle' : 'Choose a conversation', textAlign: TextAlign.center, style: pageText(t, t.fontSize('lg'), weight: dialup ? 'bold' : 'semibold', color: ink ?? t.color('app-ink-2'))),
                  SizedBox(height: t.space(1)),
                  Text(circles ? 'Or start one with + under the list.' : 'Or start a new chat from the bar under the list.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: ink ?? t.color('app-ink-3'))),
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

/// Dial-Up's list beside a pane in the era's raised window border, two rings of light and shade round all of it, the
/// shade down its right where the pane begins (Bevel's own painter). Always in the tree, drawing nothing where [on] is
/// false (every other look, a phone's narrow screen), so the list keeps its place, and what is open in it, as the
/// window changes.
class _SideFrame extends StatelessWidget {
  const _SideFrame({required this.on, required this.child});
  final bool on;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final edge = on ? Bevel.edgeOf(context) : 0.0;
    return CustomPaint(
      painter: on ? BevelPainter(colors: DialupColors.of(context.tokens), style: BevelStyle.raised, face: DialupColors.of(context.tokens).chrome, ring: Bevel.ringOf(context)) : null,
      child: Padding(padding: EdgeInsets.all(edge), child: child),
    );
  }
}
