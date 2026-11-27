import 'blocking.dart';
import '../friends/file_card.dart';
import '../snooze.dart';
import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../keys.dart';
import '../message_format.dart';
import '../app_state.dart';
import '../conversation_feed.dart';
import '../art/app_icon.dart';
import '../art/pixel_emoji.dart';
import '../art/ghost_icons.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart' show lookCorner, lookRim;
import '../kit/fold.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../inbox/scams.dart';
import '../plugins/codes.dart' show CodesPlugin;
import '../plugins/spam.dart' show SpamPlugin;
import '../plugins/list.dart';
import '../plugins/plugin.dart' show MessageFacts, PluginAction, PluginHost, PluginSource, RowLook;
import '../art/lucide_more.dart';
import '../plugins/registry.dart' show AppStore, PluginSection;
import '../plugins/ui.dart' show FilterButton, MarkAllRead, PluginRow;
import '../reactions.dart';
import '../sms.dart';
import '../summaries.dart';
import 'account_screens.dart' show ShowWordsScreen, wordsLater;
import 'common.dart';
import 'voice_screen.dart';
import 'hangout_screen.dart';
import '../circles/circles.dart';
import 'circles/circle_face.dart';
import 'circles/circle_invite_card.dart' show circleInviteRows;
import 'circles/circle_screen.dart';
import 'circles/new_circle.dart';
import 'space_designs/space_design.dart';
import '../voice/voice.dart';
import '../voice/channels.dart';
import 'update_banner.dart';
import 'compose.dart';
import 'dialup/dialup.dart';
import 'settings.dart';
import 'shell.dart';
import 'skeleton.dart';
import 'swipe_actions.dart';
import 'inbox_ui.dart';
import 'list_order.dart';
import '../inbox/inbox.dart';
import '../friends/groups.dart';
import 'thread.dart';
import 'feedback_screen.dart' show FeedbackButton;
import 'files_space/my_files.dart' show openMyFiles;
import '../account/account.dart' show Account;
import '../files/drive.dart' show Drive;
import '../souls/souls_send.dart' show SoulsCard;
import 'souls.dart' show SoulsChip;
import 'window_chrome.dart' show MacChrome;
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

/// Home: every conversation, the newest first, with a search over names, numbers and the last message.
///
/// While Android's store is being read it says so: an arc and "Loading your conversations…" the first time, and a
/// thin bar under the search when a later read takes a moment (Matt, 2026-11-13: "Show a loading indicator when
/// messages are syncing"). A read that fails is said, with a way to try again, never shown as an empty list.
///
/// Several conversations can be chosen at once and deleted or archived together (Matt, the same day: "allow selecting
/// multiple convos to delete them"): a conversation's long press has Select, then a tap adds or takes away, and the
/// bar at the top counts them.
///
/// It is the list of the app's frame (lib/ui/shell.dart), on a phone and on a computer. The way to a new chat, the
/// contacts, the archive and Settings is the frame's pill at the list's foot, as the Mac's sidebar has it (Matt,
/// 2026-11-14: "the mobile app should gain the nav from desktop"); what a row opens goes to the frame's pane, and
/// the conversation open there is marked. Shown with no frame round it (a test of this screen alone) it has New
/// message and Settings in its header and Archived as a row at its foot, and opens pages over itself.
class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key, this.archived = false, this.selectAll = false});

  /// The Archived page: the same list, of the conversations put away.
  final bool archived;

  /// The Archived page opens with every conversation in it chosen, for the bar at the top to take them back out or
  /// delete them: asked for from the Archive ring's menu (lib/ui/shell.dart).
  final bool selectAll;

  /// The tab the main list is showing (null for Messages): the wide window's empty pane reads it, so it can say
  /// "Choose a circle" while the Circles tab is up (lib/ui/shell.dart).
  static final shownTab = ValueNotifier<String?>(null);

  /// The Circles tab's id among the tabs.
  static const circlesTab = '*circles';

  /// A tab asked for from outside the list (a circle's invite banner pressed, or a circle's link opened from outside the
  /// app: lib/ui/circles/circle_invite_card.dart): the list shows it, and sets this back to null.
  static final wantTab = ValueNotifier<String?>(null);

  /// The main list on the screen, for the keyboard's commands to ask of (GMFB-41, lib/keys.dart): its conversations
  /// in the order shown, all of them, opening one, and Mark all as read. Null while there is none; never the
  /// Archived page.
  static ConversationList? live;

  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

/// What the keyboard's commands ask of the main list (ConversationsScreen.live): the texts and Uplink's own
/// conversations, which have a thread; another network's chats are not among them.
abstract class ConversationList {
  /// The tab shown, in the order it is drawn, whatever is typed in its search.
  List<Conversation> get order;

  /// Every conversation not archived, of every tab.
  List<Conversation> get every;

  void openConversation(Conversation c);

  /// Every unread conversation in the tab shown marked read.
  Future<void> markShownRead();
}

/// A row brought up in the list: a conversation with something unread that is not muted, a space with unread messages.
bool isUnreadRow(Object row) => switch (row) {
      Conversation c => c.unread && !c.muted,
      InboxChat c => c.unread > 0 && !c.muted,
      VoiceChannel v => Voice.instance.unreadIn(v) > 0,
      _ => false,
    };

/// [row] as the list's order sees it (lib/ui/list_order.dart): its own name, when its newest message was written
/// ([at], for a space, whose time is its newest message's or its call's), and whether it is brought up.
ListEntry listEntry(Object row, {bool pinned = false, DateTime? at}) => switch (row) {
      Conversation c => ListEntry(row: c, key: ListEntry.textKey(c.id), at: at ?? c.date, unread: isUnreadRow(c), pinned: pinned),
      InboxChat c => ListEntry(row: c, key: ListEntry.chatKey(c.network, c.id), at: at ?? c.date, unread: isUnreadRow(c), pinned: pinned),
      VoiceChannel v => ListEntry(row: v, key: ListEntry.spaceKey(v.room), at: at ?? DateTime.fromMillisecondsSinceEpoch(0), unread: isUnreadRow(v), pinned: pinned),
      _ => throw ArgumentError('not a row of the list: $row'),
    };

class _ConversationsScreenState extends State<ConversationsScreen> with WidgetsBindingObserver implements ConversationList {
  /// The conversations of texts in the order they are drawn: what the keys that step through them go by.
  @override
  List<Conversation> get order => _drawn.isEmpty ? _shown : [for (final r in _drawn) if (r is Conversation) r];

  @override
  List<Conversation> get every => [for (final c in _all ?? const <Conversation>[]) if (!c.archived) c];

  @override
  void openConversation(Conversation c) => unawaited(_open(c));

  @override
  Future<void> markShownRead() => _markAllRead(_section);

  /// The conversations and how the reading of them stands (lib/conversation_feed.dart): read there, drawn here.
  late final ConversationFeed _feed = ConversationFeed(archived: widget.archived, onRead: (lot) => _plugins.take(lot))..addListener(_fed);
  List<Conversation>? get _all => _feed.items;
  String _query = '';
  StreamSubscription<int>? _changes;
  StreamSubscription<int>? _readHere;

  /// Why the last read failed, in Android's words; null when it did not.
  String? get _error => _feed.error;

  /// A read has been going for long enough to say so.
  bool get _slow => _feed.slow;

  /// Older conversations are still being read behind the ones shown.
  bool get _more => _feed.more;

  /// How many conversations are archived, for the row that leads to them.
  int _archived = 0;
  int _counted = 0;

  /// The whole readings acted on, and when the last one was asked for.
  int _wholeSeen = 0;
  DateTime _loadedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The rows held where they are though they have been read (lib/ui/list_order.dart), the view they were held in
  /// (the tab, and whether a search is on), and the rows as last drawn.
  final ListHold _hold = ListHold();
  String? _view;
  List<Object> _drawn = const [];

  /// The conversation open in the frame's pane as the list last knew: its row is read again as it gives way.
  int? _openWas;

  /// The conversations chosen, while several are being chosen. Empty: not choosing.
  final Set<int> _selected = {};

  /// The Archived page that opens with everything chosen has chosen it.
  bool _choseAll = false;

  /// What can be seen of the texting app this one replaced (android/.../Arriving.kt), for the note about RCS.
  Arriving _arriving = const Arriving();

  /// Beside Google Messages (SmsStatus.beside): RCS stays on there on purpose, so the notice about it is not shown.
  bool _beside = false;

  bool get _selecting => _selected.isNotEmpty;

  /// The frame this list is in (lib/ui/shell.dart), which opens what the list asks for in its pane; null where the
  /// list is shown alone.
  AppShellState? _shell;

  // --- plugins (lib/plugins) -----------------------------------------------------------------------------------------
  // What the plugins that are switched on add to this list: sections with chips under the search field, how a
  // section's rows look, and what fills the list's slots. All of it is asked of [_plugins]; none of it is decided here.
  late final ListPlugins _plugins = ListPlugins(
    changed: () {
      if (mounted) setState(() {});
    },
    open: (thread) {
      final c = _all?.where((c) => c.id == thread).firstOrNull;
      if (c != null) _open(c);
    },
    refresh: _load,
  );

  /// The section whose chip is chosen; null is the main list.
  String? _section;

  /// Back at the list from what was open, or something else opened in its place: the row of the conversation that
  /// was open is read again (it was read, written in, muted, archived or deleted there), with the newest ones and the
  /// archive's count. Everything was read again here, lot after lot, at each conversation opened.
  void _back() {
    _look();
    final was = _openWas;
    _openWas = _shell?.thread;
    _countArchived();
    _feed.changed(was ?? -1);
  }

  /// The reading moved on (lib/conversation_feed.dart): drawn, and what a whole reading says is acted on once.
  void _fed() {
    if (!mounted) return;
    final items = _feed.items ?? const <Conversation>[];
    final whole = _feed.whole != _wholeSeen;
    _wholeSeen = _feed.whole;
    setState(() {
      if (!whole) return;
      // A conversation that has gone is no longer chosen.
      _selected.removeWhere((id) => !items.any((c) => c.id == id));
      // Opened to choose them all: once, as they first arrive.
      if (widget.archived && widget.selectAll && !_choseAll) {
        _choseAll = true;
        _selected.addAll(items.map((c) => c.id));
      }
    });
    // The Archive ring's menu says how many are here; its number, how many of them are unread (GMFB-14).
    if (whole && widget.archived) {
      _shell?.archived.value = items.length;
      _shell?.archivedUnread.value = items.where((c) => c.unread).length;
    }
  }

  /// The app or its window was left, or come back to. Left: the rows held where they were go to their own places
  /// while nobody is looking (lib/ui/list_order.dart). Come back to after a while: everything is read again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final watching = state == AppLifecycleState.resumed;
    if (watching == _hold.watching) return;
    _hold.watching = watching;
    if (!watching) {
      if (_hold.settle() && mounted) setState(() {});
    } else if (DateTime.now().difference(_loadedAt) > const Duration(minutes: 1)) {
      _load();
    }
  }

  @override
  void initState() {
    super.initState();
    if (!widget.archived) ConversationsScreen.live = this;
    // What was open in the pane has closed, or given way to something else: read again, as on coming back to the
    // list from a page.
    _shell = AppShell.maybeOf(context)?..closed.addListener(_back);
    // A summary made comes into its row; who is in a voice channel comes into its.
    Summaries.instance.addListener(_summed);
    Voice.instance.addListener(_summed);
    Snoozed.instance.addListener(_summed);
    // A snooze that ends is said here where the device has no notification for it (GMFB-36).
    if (!widget.archived) Snoozed.back = _snoozeBack;
    Circles.instance.addListener(_summed);
    ConversationsScreen.wantTab.addListener(_wanted);
    _wanted();
    // Telegram's and Bluesky's chats (lib/inbox): each signed-in network is a tab, and its chats come into it.
    _inbox.addListener(_summed);
    WidgetsBinding.instance.addObserver(this);
    _hold.watching = (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;
    _openWas = _shell?.thread;
    _load();
    _look();
    // A text came or went: it is among the newest, so those are read again, and its conversation by itself where it
    // is not among them.
    _changes = Sms.instance.changes.stream.listen(_feed.changed);
    // A conversation was marked read from here: its row alone.
    _readHere = Sms.instance.reads.stream.listen(_feed.refresh);
  }

  final Listenable _inbox = Inbox.instance.changes;

  void _summed() {
    if (mounted) setState(() {});
  }

  void _snoozeBack(String title) {
    if (mounted) toast(context, '$title is back from snooze');
  }

  /// The Circles tab's rows: circles offered and not yet joined, then each circle. Only circles (Matt, 2026-11-17:
  /// "there are spaces listed under the circles tab it shouldn't be circles and spaces it should only be circles"):
  /// spaces of one's own are in Messages among the conversations, a group of friends' in its conversation.
  List<Object> _circlesTabRows() {
    final rest = <Object>[...Circles.instance.all];
    return [if (_query.isEmpty) ...circleInviteRows(context, Circles.instance.invites, circlesFollow: rest.isNotEmpty), ...rest];
  }

  /// A tab asked for from outside ([ConversationsScreen.wantTab]); not on the Archived page.
  void _wanted() {
    final want = ConversationsScreen.wantTab.value;
    if (want == null || widget.archived) return;
    ConversationsScreen.wantTab.value = null;
    if (mounted) setState(() => _section = want);
  }

  @override
  void dispose() {
    if (identical(ConversationsScreen.live, this)) ConversationsScreen.live = null;
    Summaries.instance.removeListener(_summed);
    Voice.instance.removeListener(_summed);
    Snoozed.instance.removeListener(_summed);
    if (Snoozed.back == _snoozeBack) Snoozed.back = null;
    Circles.instance.removeListener(_summed);
    ConversationsScreen.wantTab.removeListener(_wanted);
    _inbox.removeListener(_summed);
    _shell?.closed.removeListener(_back);
    WidgetsBinding.instance.removeObserver(this);
    _plugins.dispose();
    _changes?.cancel();
    _readHere?.cancel();
    _feed
      ..removeListener(_fed)
      ..dispose();
    super.dispose();
  }

  /// Reads what the notices over the list go by: the texting app this one replaced, and (on the phone itself) whether
  /// it stands beside Google Messages.
  Future<void> _look() async {
    try {
      final a = await Sms.instance.arriving();
      if (mounted) setState(() => _arriving = a);
    } catch (_) {}
    if (Sms.remote) return;
    try {
      final s = await Sms.instance.status();
      if (mounted) setState(() => _beside = s.beside);
    } catch (_) {}
  }

  /// Reads the conversations again, all of them (lib/conversation_feed.dart: the first lot at once, the rest behind
  /// it), and how many are archived.
  Future<void> _load() {
    _loadedAt = DateTime.now();
    _countArchived();
    return _feed.load();
  }

  /// How many are archived, for the row and the ring that lead to them: asked of the phone, which knows before every
  /// conversation has been read.
  void _countArchived() {
    if (widget.archived) return;
    final asked = ++_counted;
    Sms.instance.archivedCount().then((n) {
      if (!mounted || asked != _counted) return;
      setState(() => _archived = n);
      _shell?.archived.value = n;
    }).catchError((_) {});
    unawaited(_shell?.countArchivedUnread());
  }

  /// The list's rows in their order: the texts with Telegram's and Bluesky's chats and the spaces among them (Matt,
  /// 2026-11-15: "Id like the telegram chats to be mixed into the normal text messages (same with bluesky) just add a
  /// telegram icon in thr corner of the bubble"), every kind ordered by the one rule (lib/ui/list_order.dart): the
  /// pinned first, what is unread before what is not, the newest first, and a row that has been read held where it
  /// was. While older texts are still being read, a read chat older than the texts held so far waits for them, so the
  /// list does not jump.
  List<Object> _mixed(List<Conversation> shown) {
    // Codes: a Telegram sign-in code is there among the texted ones (Matt, 2026-11-15: "proxy telegram codes through to
    // the codes tab as well"); any other section is the texts' own.
    final codes = !widget.archived && _codesHost != null;
    // Spam: a chat that looks like a scam is in Spam with spam texts, while the spam filter is on (lib/inbox/scams.dart;
    // Matt, 2026-11-15: "i also want spam filters on them to work and cut out fake romance scams and other telegram
    // scams").
    final spam = !widget.archived && _spamHost != null;
    String? spamOf(InboxChat c) => spam && !(Inbox.instance.named(c.network)?.localList('notspam').contains(c.id) ?? false) ? scamOf(c) : null;
    final q = _query.toLowerCase();
    // Every other kind the filters sort, as a text is (ListPlugins.sort's chats; Matt, 2026-11-16: "Filters should
    // apply to all chats including telegram and signal").
    bool sorted(InboxChat c) => widget.archived || _plugins.showsChat('${c.network}:${c.id}', _section, searching: q.isNotEmpty);
    // In the archive, the networks' archived chats among the archived texts.
    final chats = [
      for (final n in Inbox.instance.ready)
        for (final c in widget.archived ? n.archivedChats : n.shownChats)
          if ((q.isEmpty || c.title.toLowerCase().contains(q) || c.snippet.toLowerCase().contains(q)) &&
              switch (_section) {
                CodesPlugin.section => (codes && inboxCode(c) != null) || sorted(c),
                SpamPlugin.section => spamOf(c) != null || sorted(c),
                _ => !(codes && inboxCode(c) != null) && spamOf(c) == null && sorted(c),
              })
            c,
    ];
    // Spaces: in Messages among the conversations, by their newest message (or now, while anyone is in the call), each
    // with a preview of it (Matt, 2026-11-17: "I'd also like spaces to show up in the main chats list with a preview
    // of the last message sent in the space"). A group's own is not one of them: its conversation stands for it.
    // An archived one is in Archive instead (Voice.archive). A circle's spaces are in their circle (the Circles tab).
    final spaces = _section != null ? const <(DateTime, Object)>[] : [
      for (final v in Voice.instance.channels)
        if (v.hangout && v.circle == null && Voice.instance.archived(v) == widget.archived && (q.isEmpty || v.name.toLowerCase().contains(q) || (Voice.instance.lastMessage(v)?.summary.toLowerCase().contains(q) ?? false))) (_spaceDate(v), v as Object),
    ];
    // In a section its own conversations stand newest first whether pinned or not; in the main list the pinned ones
    // head it, a network's among the texts'.
    final main = _section == null;
    bool pinnedChat(InboxChat c) => main && (Inbox.instance.named(c.network)?.isPinned(c) ?? false);
    // The date everything newer than which is held, while older texts are still being read.
    final floor = main ? _feed.floor : null;
    bool here(ListEntry e) => floor == null || e.pinned || e.unread || !e.at.isBefore(floor);
    final entries = <ListEntry>[
      for (final c in shown) listEntry(c, pinned: main && c.pinned),
      for (final e in [for (final c in chats) listEntry(c, pinned: pinnedChat(c)), for (final v in spaces) listEntry(v.$2, at: v.$1)])
        if (here(e)) e,
    ];
    return [for (final e in arranged(entries, held: _hold.follow(entries))) e.row];
  }

  /// Snoozed conversations out of the list until their time, and those back from a snooze at its top until opened
  /// (GMFB-36). A search finds a snoozed one, and the archive is as it was.
  List<Object> _snoozing(List<Object> rows) {
    final z = Snoozed.instance;
    // A space's chat in Messages is snoozed as a conversation is.
    String? keyOf(Object r) => r is Conversation ? Snoozed.text(r.id) : r is VoiceChannel ? Snoozed.space(r.room) : null;
    if (widget.archived || (z.count == 0 && !rows.any((r) => keyOf(r) != null && z.woken(keyOf(r)!)))) return rows;
    final searching = _query.isNotEmpty;
    final woken = <Object>[], rest = <Object>[];
    for (final r in rows) {
      final key = keyOf(r);
      if (key != null && z.hides(key) && !searching) continue;
      (key != null && z.woken(key) ? woken : rest).add(r);
    }
    return [...woken, ...rest];
  }

  /// When the snoozed conversation kept under [key] comes back, in words; null where it isn't snoozed.
  String? _snoozedUntil(String key) {
    final u = Snoozed.instance.until(key);
    return u == null ? null : 'Until ${dayHeading(u)} ${clock(u)}';
  }

  /// The menu's line that snoozes the conversation or the space's chat kept under [key], called [title], or brings it
  /// back (GMFB-36).
  Choice _snoozeChoice(String key, String title) =>
      Choice(Snoozed.instance.hides(key) ? 'Unsnooze' : 'Snooze…', Lucide.clock, () => unawaited(_snooze(key, title)), hint: _snoozedUntil(key));

  /// Snoozes the one kept under [key] until a time chosen from a few; one hidden by a snooze already is brought
  /// straight back instead.
  Future<void> _snooze(String key, String title) async {
    if (Snoozed.instance.hides(key)) {
      Snoozed.instance.unsnooze(key);
      toast(context, 'Back in Messages');
      return;
    }
    await showChoices(context, title: 'Snooze $title: it leaves Messages and comes back at the top${Snoozed.notifies ? ', with a notification' : ''}.', choices: [
      for (final o in Snoozed.choices(DateTime.now()))
        Choice(o.label, Lucide.clock, () {
          Snoozed.instance.snooze(key, o.at, title: title);
          toast(context, 'Snoozed until ${dayHeading(o.at)} ${clock(o.at)}', action: GlacierToastAction(label: 'Undo', onPress: () => Snoozed.instance.unsnooze(key)));
        }),
    ]);
  }

  /// When [v] last had anything happen: now while anyone is in its call, else its newest message or its call's last.
  DateTime _spaceDate(VoiceChannel v) {
    final voice = Voice.instance;
    if (voice.live(v)) return DateTime.now();
    final said = voice.lastMessage(v)?.at ?? 0;
    final active = voice.lastActive(v)?.millisecondsSinceEpoch ?? 0;
    return DateTime.fromMillisecondsSinceEpoch(said > active ? said : active);
  }

  /// How many are in [v]'s call now, this device among them.
  static int _inCall(VoiceChannel v) {
    final voice = Voice.instance;
    final here = voice.session?.channel.room == v.room;
    return here ? 1 + voice.session!.members.length : voice.inChannel(v).length;
  }

  /// How many are in the call of the group of friends whose conversation [c] is; null where it is not one.
  static int? _groupInCall(Conversation c) {
    final g = Groups.instance.ofThread(c.id);
    if (g == null || g.gone) return null;
    return _inCall(VoiceChannel.ofGroup(g.id, g.name));
  }

  /// A space in Messages, drawn as a conversation is: its name, a preview of its newest message, its unread mark, and
  /// how many are in its call in the time's place. Pressed, it opens as a conversation does (HangoutScreen).
  Widget _spaceRow(VoiceChannel v, {required bool selected}) {
    final voice = Voice.instance;
    final last = voice.lastMessage(v);
    final inCall = _inCall(v);
    final me = voice.hangoutFor(v)?.me;
    final String snippet;
    if (last != null) {
      final who = last.from == me ? 'You' : (last.name.isNotEmpty ? last.name : voice.nameOf(last.from));
      snippet = '$who: ${last.summary}';
    } else if (inCall > 0) {
      snippet = '$inCall in voice · Join any time';
    } else {
      snippet = 'No messages yet';
    }
    final unread = voice.unreadIn(v);
    final c = Conversation(
      id: -(v.seed.hashCode & 0x3fffffff) - 1,
      date: _spaceDate(v),
      people: [Person(address: 'space:${v.seed}', name: v.name)],
      snippet: snippet,
      unread: unread > 0,
      error: false,
      archived: false,
    );
    final t = context.tokens;
    return ConversationRow(
      key: ValueKey('space-row-${v.room}'),
      conversation: c,
      unreadCount: unread,
      mentioned: voice.mentionsIn(v) > 0,
      selected: selected,
      live: inCall,
      // Its kind's mark: headphones, a speech bubble for texting, a folder for files (lib/ui/circles/circle_face.dart).
      badge: AppIcon(spaceKindIcon(v.kind), size: 12, strokeWidth: 2.4, wash: false, color: t.color(inCall > 0 ? 'app-ink' : 'app-ink-2')),
      onPress: () => _openVoice(v),
      // Snoozed from its menu as a conversation is (GMFB-36).
      onLongPress: () => showHangoutMenu(context, v, onOpen: () => _openVoice(v), more: [if (!widget.archived) _snoozeChoice(Snoozed.space(v.room), v.name)]),
    );
  }

  /// What each signed-in network's chat says of itself, for the filters to sort it with the texts: its newest message,
  /// whether whoever wrote is a contact, a group, unread, muted, and whether the newest message is this account's.
  List<({String key, MessageFacts facts})> _chatFacts() => [
        for (final n in Inbox.instance.ready)
          for (final c in n.shownChats)
            (
              key: '${c.network}:${c.id}',
              facts: MessageFacts(
                thread: ListPlugins.chatThread('${c.network}:${c.id}'),
                senders: [c.title],
                text: c.snippet,
                contact: !c.stranger && !c.service,
                group: c.group,
                date: c.date,
                unread: c.unread > 0,
                muted: c.muted,
                outgoing: c.lastFromMe,
              ),
            ),
      ];

  /// The spam filter's host while it is on: chats that look like scams go to Spam.
  PluginHost? get _spamHost => widget.archived ? null : _plugins.hostFor(context, SpamPlugin.section);

  /// A chat in Spam: why it is there, and Not spam to put it back for good.
  Widget _inboxSpamRow(InboxChat chat, InboxNetwork network, String why, PluginHost host) {
    final c = Conversation(
      id: -(chat.id.hashCode & 0x3fffffff) - 1,
      date: chat.date,
      people: [Person(address: '${chat.network}:${chat.id}', name: chat.title, photo: chat.avatar)],
      snippet: chat.snippet,
      unread: chat.unread > 0,
      error: false,
      archived: false,
    );
    final back = PluginAction(label: 'Not spam', icon: Lucide.check, run: (host) {
      network.setLocal('notspam', chat.id, true);
      host.say('Moved to Messages');
    });
    return PluginRow(conversation: c, look: RowLook(caption: why, word: back), host: host, onPress: () => openInboxChat(context, network, chat), onLongPress: () => openInboxChat(context, network, chat));
  }

  /// The Codes plugin's host while it is on: Telegram's codes go to its tab, and are copied by it.
  PluginHost? get _codesHost => widget.archived ? null : _plugins.hostFor(context, CodesPlugin.section);

  /// A Telegram chat in Codes, drawn as a texted code is: the code large, a tap or the button copies it.
  Widget _inboxCodeRow(InboxChat chat, InboxNetwork network, String code, PluginHost host) {
    final copy = PluginAction(
      label: 'Copy $code',
      icon: Lucide.copy,
      run: (host) async {
        host.copy(code, say: 'Copied $code');
        await network.markRead(chat.id);
      },
    );
    final c = Conversation(
      id: -(chat.id.hashCode & 0x3fffffff) - 1,
      date: chat.date,
      people: [Person(address: '${chat.network}:${chat.id}', name: chat.title, photo: chat.avatar)],
      snippet: chat.snippet,
      unread: chat.unread > 0,
      error: false,
      archived: false,
    );
    return PluginRow(conversation: c, look: RowLook(value: code, end: copy, tap: copy, title: network.name), host: host, onPress: () => openInboxChat(context, network, chat), onLongPress: () => openInboxChat(context, network, chat));
  }

  /// The conversations the list shows now: this page's (archived or not), the chosen section's, pinned ones first,
  /// and narrowed by the search.
  List<Conversation> get _shown {
    // Pinned conversations first, each group newest first (the order they arrive in).
    final held = (_all ?? const <Conversation>[]).where((c) => c.archived == widget.archived).toList();
    // Plugins: a section's own conversations, the newest first whether pinned or not; else the main list without
    // the ones a section has taken out of it.
    final all = widget.archived ? held : _plugins.pick(held, _section, searching: _query.trim().isNotEmpty);
    final list = _section != null ? all : [...all.where((c) => c.pinned), ...all.where((c) => !c.pinned)];
    if (_query.trim().isEmpty) return list;
    final q = fold(_query.trim());
    final digits = q.replaceAll(_notDigit, '');
    // Each conversation's words and numbers are folded once for as long as it is held, not at every key pressed
    // (docs/performance-audit.md, finding 8): a search of thousands is then a look through strings made already.
    return list.where((c) {
      final (words, numbers) = _searched[c] ??= (
        [fold(c.snippet), if (c.draft != null) fold(c.draft!), for (final p in c.people) fold(p.label)].join('\u001f'),
        [for (final p in c.people) p.address.replaceAll(_notDigit, '')].join('\u001f'),
      );
      return words.contains(q) || (digits.length >= 3 && numbers.contains(digits));
    }).toList();
  }

  static final RegExp _notDigit = RegExp(r'[^0-9]');
  static final Expando<(String, String)> _searched = Expando();

  // --- the tabs --------------------------------------------------------------------------------------------------------

  /// The Circles tab, where the Spaces tab was (Matt, 2026-11-17: "Let's do a circle for now ... with it's own sidebar
  /// full of spaces"): each circle, which opens in the list's place (AppShell.openCircle), and nothing else (Matt,
  /// 2026-11-17: "it should only be circles").
  static const circlesTab = ConversationsScreen.circlesTab;

  /// Hops into [c] and shows it.
  Future<void> _openVoice(VoiceChannel c) async {
    Snoozed.instance.opened(Snoozed.space(c.room));
    // A group of friends' space is its conversation (Matt, 2026-11-17: "each group should come with a space"; he chose
    // one chat for both): it opens there, where its call is joined from the top.
    final group = c.group == null ? null : Groups.instance.of(c.group!);
    if (group != null && !group.gone && group.thread >= 0 && Voice.instance.session?.channel.room != c.room) {
      final held = (_all ?? const <Conversation>[]).where((x) => x.id == group.thread).firstOrNull;
      await _open(held ?? Conversation(id: group.thread, date: DateTime.now(), people: [for (final m in group.others) m.person], snippet: '', unread: false, error: false, archived: false));
      return;
    }
    // In its call already, where no shell draws it: its page (lib/ui/space_designs).
    if (Voice.instance.session?.channel.room == c.room && openSpaceCall(context)) return;
    // A hangout opens its page: its chat, who is in it, and a way into voice (lib/ui/hangout_screen.dart).
    // In the conversation's place (Matt, 2026-11-15: "clicking on a voice chat should show me the chat in the normal
    // spot and connected participants with a "join" button").
    // A Files space opens its files (lib/ui/files_space/), in the conversation's place.
    if (c.kind == SpaceKind.files) {
      final shell = AppShell.maybeOf(context);
      final page = circleSpacePage(c, key: ValueKey('files-space-${c.seed}'));
      shell != null ? shell.show(page, showing: 'files:${c.seed}') : push<void>(context, (_) => page);
      return;
    }
    if (c.hangout && Voice.instance.session?.channel.room != c.room) {
      final shell = AppShell.maybeOf(context);
      if (shell != null) {
        Voice.instance.view(c);
        shell.go('voice');
      } else {
        push(context, (_) => HangoutScreen(channel: c));
      }
      return;
    }
    try {
      await Voice.instance.join(c);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t join: $e', tone: GlacierToastTone.danger);
      return;
    }
    if (!mounted) return;
    // Left while it was connecting (the call's banner has Leave from the first moment): there is no call to show.
    if (Voice.instance.session?.channel.room != c.room) return;
    final shell = AppShell.maybeOf(context);
    if (shell != null) {
      shell.go('voice');
    } else {
      push(context, (_) => const VoiceScreen());
    }
  }

  /// One tab's conversations (null: the main list's), whatever is typed in the search: not the archived ones.
  List<Conversation> _of(String? section) {
    // Asked several times a build (the tabs' counts, Mark all read): worked out once for each list held.
    if (!identical(_ofFor, _all)) {
      _ofFor = _all;
      _ofMemo.clear();
    }
    return _ofMemo[section] ??= () {
      final held = (_all ?? const <Conversation>[]).where((c) => !c.archived).toList();
      return _plugins.pick(held, section, searching: false);
    }();
  }

  List<Conversation>? _ofFor;
  final Map<String?, List<Conversation>> _ofMemo = {};

  /// The row under the search field: the tabs as a segmented toggle (Matt, 2026-11-14: "change the messages and
  /// codes to a segmented toggle") and, at its end, the filter. With neither there is no row. Mark all read is at the
  /// end of the title row.
  /// An empty list's words under [lead] (the rows and the toggle that scroll with the list), in [padding].
  Widget _withLead(Widget? lead, EdgeInsets padding, List<Widget> children) => ListView(
        padding: EdgeInsets.zero,
        children: [?lead, Padding(padding: padding, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children))],
      );

  /// The rows under the search: Mark all read for the tab shown (quiet with nothing unread), and Share feedback (on the
  /// Mac it is in the window's title strip instead).
  Widget _quickRows(Tokens t, int unread) => Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(2), 0, t.space(2), t.space(2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // A plugin's (the cleaner's Clean up, while there is something to clean; Matt, 2026-11-20: "also the clean
          // button is still in the header we should remove that"). Dial-Up keeps them in its title bar.
          if (!isBevelChrome(t))
            for (final a in _plugins.headerActions(context, ListPlace(section: _section, groups: _plugins.groups(_all ?? const []))))
              QuickRow(key: ValueKey('quick-${a.label}'), icon: a.icon, label: a.label, onPress: a.press),
          QuickRow(
            key: const ValueKey('quick-mark-read'),
            icon: Lucide.checkCheck,
            label: 'Mark all read',
            count: unread,
            onPress: unread > 0 ? () => _markAllRead(_section) : null,
          ),
          // My files: the account's own drive (GMFB-37, @matt: "A private file drive for each account, not tied to any
          // space"). Here, under the search, where a phone's list and a computer's sidebar both have it. Only with an
          // account signed in to (the drive is made from its key), and not in a browser whose build has no Files.
          if (!widget.archived && Sms.filesHere)
            ListenableBuilder(
              listenable: Account.instance,
              builder: (context, _) => Account.instance.signedIn ? QuickRow(key: const ValueKey('my-files'), icon: Lucide.hardDrive, label: Drive.name, onPress: () => openMyFiles(context)) : const SizedBox.shrink(),
            ),
          // In a browser too, words alone (it can't choose a picture yet), sent by the page's own fetch.
          if (!MacChrome.stripEnabled)
            QuickRow(key: const ValueKey('share-feedback'), icon: LucideMore.messageSquareWarning, label: 'Share feedback', onPress: () => FeedbackButton.open(context)),
          // An unreviewed pack's rows look like any other's, so the list says while one runs (Matt, 2026-11-20: "a
          // developer setting for users to be able to manually upload plugins for development testing").
          if (_devPluginOn())
            QuickRow(key: const ValueKey('dev-plugins-on'), icon: Lucide.flaskConical, label: 'A plugin in development is on · Settings › Developer', onPress: () => _shell?.settings('developer', 'Plugins in development')),
        ]),
      );

  /// Whether a plugin in development (lib/plugins/pack) is switched on in the list's registry.
  bool _devPluginOn() {
    final store = AppStore(AppState.of(context));
    return _plugins.registry.plugins.any((p) => p.source == PluginSource.dev && _plugins.registry.isOn(p, store));
  }

  /// The row under the search field: the sections' toggle and the plugins' kinds; null where there is neither.
  Widget? _tabsRow(Tokens t) {
    // Messages, codes and voice channels as the toggle's three icons (Matt, 2026-11-15: "use the segmented toggle with
    // the three icons instead of intertwining them remove the other options for now"). Voice is there always: it is
    // where calls are.
    final tabs = _plugins.tabs(_section, (section) => setState(() => _section = section), onMenu: _tabMenu, extra: [
      // Counted by how many circles have anyone in voice now, and the invites not yet answered or put off. Not under
      // the rail, which shows the circles itself (Matt, 2026-11-20: "remove the circles icon from the segmented toggle
      // on the messages view since circles are now shown in the sidebar"); their invites are then atop Messages.
      if (!AppShell.railOf(context)) (id: circlesTab, icon: Lucide.circleDot, label: 'Circles', count: Circles.instance.all.where((c) => Circles.instance.liveSpaces(c).isNotEmpty).length + Circles.instance.invites.where((i) => !i.later).length),
    ]);
    final kinds = _plugins.kinds;
    if (tabs == null && kinds.isEmpty) return null;
    final only = _section != null && (_section == ListPlugins.hiddenView || kinds.any((k) => k.id == _section));
    return Padding(
      // From the search field's edge, which is the cards' edge too.
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), 0, t.space(2), t.space(2)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // As tall as the toggle, which is as tall as the round buttons beside it.
        SizedBox(
          height: MarkAllRead.size(t),
          child: Row(children: [
            Expanded(child: tabs ?? const SizedBox.shrink()),
            if (kinds.isNotEmpty) ...[
              if (tabs != null) SizedBox(width: t.space(2)) else const Spacer(),
              FilterButton(hidden: _plugins.hiddenCount, only: only, rows: (context) => _filterRows(kinds)),
            ],
          ]),
        ),
        // One kind shown alone: which, and the way back to everything.
        if (only)
          Padding(
            padding: EdgeInsetsDirectional.only(top: t.space(2), start: t.space(2)),
            child: Row(children: [
              Expanded(
                child: Text(_section == ListPlugins.hiddenView ? 'Hidden by the filter' : 'Only ${_plugins.tabName(_section)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink-2'))),
              ),
              GlacierPressable(
                onPressed: () => setState(() => _section = null),
                builder: (context, state) => Padding(
                  padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1)),
                  child: Text('Show all', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color(state.pressed ? 'app-ink-3' : 'app-ink'))),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  /// The filter's menu (Matt, 2026-11-14: "a filter dropdown where showing spam, political messages, and debt
  /// collectors are filtered out by default"; then "Remove the show only toggle and just habe all at the top and each
  /// of these filters get ticked on or off With the icons"): All at the top, and under it each kind of text with its
  /// icon, how many there are, and a tick while it is shown in Messages. A press ticks or unticks it; All ticks every
  /// kind, or, with all ticked, unticks them.
  List<Widget> _filterRows(List<PluginSection> kinds) {
    final app = AppState.of(context);
    final t = context.tokens;
    bool on(PluginSection k) => ListPlugins.kindShown(app, k);
    final others = ListPlugins.othersShownFor(app);
    final all = others && kinds.every(on);
    Widget tick(bool shown) => shown ? AppIcon(Lucide.check, size: 16, color: t.color('app-ink')) : const SizedBox(width: 16, height: 16);
    Widget row(String label, int n, bool shown) => Opacity(
          opacity: shown ? 1 : 0.5,
          child: Row(children: [
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (n > 0) ...[SizedBox(width: t.space(3)), Opacity(opacity: 0.6, child: Text('$n')), SizedBox(width: t.space(2))],
          ]),
        );
    return [
      GlacierMenuItem(
        icon: const AppIcon(Lucide.listFilter, size: 16),
        shortcut: tick(all),
        closes: false,
        ariaLabel: all ? 'All, shown' : 'All',
        onSelect: () {
          for (final k in kinds) {
            app.setFlag('filter_${k.id}', !all);
          }
          app.setFlag(ListPlugins.othersKey, !all);
        },
        child: row('All', 0, true),
      ),
      const GlacierMenuSeparator(),
      // Everything no kind has: personal texts above all (Matt, 2026-11-14: "when only selecting political messages I
      // still see personal messages").
      GlacierMenuItem(
        icon: const AppIcon(LucideMore.messageCircle, size: 16),
        shortcut: tick(others),
        closes: false,
        ariaLabel: 'Personal & other, ${others ? 'shown' : 'hidden'}',
        onSelect: () => app.setFlag(ListPlugins.othersKey, !others),
        child: row('Personal & other', _plugins.othersCount, others),
      ),
      for (final k in kinds)
        GlacierMenuItem(
          icon: AppIcon(k.section.icon, size: 16),
          shortcut: tick(on(k)),
          closes: false,
          ariaLabel: '${k.section.label}, ${on(k) ? 'shown' : 'hidden'}',
          onSelect: () => app.setFlag('filter_${k.id}', !on(k)),
          child: row(k.section.label, _plugins.countOf(k.id), on(k)),
        ),
    ];
  }

  /// The texts of a tab that are unread: none in a network's own tab, which holds that network's chats alone.
  List<Conversation> _unreadTexts(String? section) => inboxOfTab(section) != null || section == circlesTab ? const [] : _of(section).where((c) => c.unread).toList();

  /// Marks every unread conversation of a tab as read, texts and chats alike: from the button at the title row's
  /// end, or a tab's own menu.
  Future<void> _markAllRead(String? section) async {
    final unread = _unreadTexts(section);
    // A space's chat is one of the list's chats here: counted and read with them.
    final spaces = _unreadSpaces(section);
    final chats = [..._unreadChats(section), ...spaces];
    for (final c in chats) {
      if (c is InboxChat) unawaited(Inbox.instance.named(c.network)?.markRead(c.id));
    }
    for (final v in spaces) {
      Voice.instance.markRead(v);
    }
    if (unread.isEmpty && chats.isNotEmpty) {
      toast(context, '${chats.length} marked as read');
      return;
    }
    if (unread.isEmpty) {
      toast(context, 'Nothing is unread in ${inboxOfTab(section)?.name ?? _plugins.tabName(section)}');
      return;
    }
    // Shown at once: the dots go as the button is let go, not as the phone gets round to each.
    final ids = {for (final c in unread) c.id};
    _feed.patchAll(ids, (c) => c.copyWith(unread: false));
    var failed = 0;
    for (final c in unread) {
      try {
        await Sms.instance.markRead(c.id);
      } catch (_) {
        failed++;
      }
    }
    _load();
    if (!mounted) return;
    toast(
      context,
      failed == 0 ? '${_count(unread.length + chats.length)} marked as read' : '${unread.length + chats.length - failed} marked as read; $failed could not be',
      tone: failed == 0 ? GlacierToastTone.neutral : GlacierToastTone.danger,
    );
  }

  /// Every unread chat of Signal's, Telegram's and the rest that [section] holds, whether or not it is drawn yet (Matt,
  /// 2026-11-16: "I still can't mark telegram and signal messages as read with the read all even though they're marked
  /// as unread"): it once took only the rows the list had drawn, which left out a chat older than the oldest text
  /// read so far, one a filter hid, and every chat where the tab was a network's own. Messages is all of them.
  /// The spaces with unread messages that [section] holds: the main list's.
  List<VoiceChannel> _unreadSpaces(String? section) =>
      section != null || widget.archived ? const [] : [for (final v in Voice.instance.channels) if (v.hangout && v.circle == null && !Voice.instance.archived(v) && Voice.instance.unreadIn(v) > 0) v];

  /// The other networks' chats with unread messages that [section] holds; the archived ones on the Archived page.
  List<InboxChat> _unreadChats(String? section) {
    if (widget.archived) return [for (final n in Inbox.instance.ready) for (final c in n.archivedChats) if (c.unread > 0) c];
    if (section == circlesTab) return const [];
    final net = inboxOfTab(section);
    if (net != null) return net.state == InboxState.ready ? [for (final c in net.shownChats) if (c.unread > 0) c] : const [];
    return [
      for (final n in Inbox.instance.ready)
        for (final c in n.shownChats)
          if (c.unread > 0 &&
              switch (section) {
                null => true,
                CodesPlugin.section => inboxCode(c) != null || _plugins.sectionOfChat('${c.network}:${c.id}')?.id == section,
                SpamPlugin.section => scamOf(c) != null || _plugins.sectionOfChat('${c.network}:${c.id}')?.id == section,
                _ => _plugins.showsChat('${c.network}:${c.id}', section, searching: false),
              })
            c,
    ];
  }

  /// A tab's menu (Matt, 2026-11-14: "add a right click menu for the codes and messages tabs"): a press with the
  /// other button on it, or a long press where there is no other button.
  void _tabMenu(String? section) {
    if (section == circlesTab) return;
    final network = inboxOfTab(section);
    if (network != null) {
      final unread = _unreadChats(section).length;
      showChoices(context, title: '${network.name} · ${unread == 0 ? 'nothing unread' : '$unread unread'}', choices: [
        Choice('Mark all as read', Lucide.checkCheck, () => _markAllRead(section)),
      ]);
      return;
    }
    final all = _of(section);
    final unread = all.where((c) => c.unread).length + _unreadChats(section).length + _unreadSpaces(section).length;
    final name = _plugins.tabName(section);
    // The plugin a tab is from, so a puzzling new tab leads back to it: its page, settings, Report and Remove (Matt,
    // 2026-11-20: "Move plugins out of settings into a marketplace button on the navigation rail").
    final from = section == null ? null : _plugins.registry.sections(AppStore(AppState.of(context))).where((s) => s.id == section).firstOrNull?.plugin;
    showChoices(context, title: '$name · ${unread == 0 ? 'nothing unread' : '$unread unread'}', choices: [
      Choice('Mark all as read', Lucide.checkCheck, () => _markAllRead(section)),
      // Every conversation of the tab chosen at once, for the bar at the top to archive or delete.
      if (all.isNotEmpty)
        Choice('Select all', Lucide.listChecks, () {
          setState(() {
            _section = section;
            _selected
              ..clear()
              ..addAll(all.map((c) => c.id));
          });
        }),
      if (from != null && _shell != null) Choice('About ${from.name}', Lucide.store, () => _shell?.marketplace(plugin: from.id)),
    ]);
  }

  /// Opens a conversation: in the frame's pane, or as a page over the list, which is read again on coming back.
  Future<void> _open(Conversation c) async {
    Snoozed.instance.opened(Snoozed.text(c.id));
    final shell = _shell;
    if (shell != null) {
      shell.openThread(c.id, c.people);
      return;
    }
    await push<void>(context, (_) => ThreadScreen(thread: c.id, people: c.people));
    // Back from it: its row as it stands now, and the newest ones.
    _countArchived();
    _feed.changed(c.id);
  }

  Future<void> _compose() async {
    final shell = _shell;
    if (shell != null) return shell.compose();
    await push<void>(context, (_) => const ComposeScreen());
    _load();
  }

  void _toggle(Conversation c) => setState(() => _selected.contains(c.id) ? _selected.remove(c.id) : _selected.add(c.id));

  /// A long press on a conversation: its menu.
  void _menu(Conversation c) {
    showChoices(context, title: c.title, choices: [
      // Plugins: where a tap on the row is a section's own (a code's tap copies it), opening it is offered here.
      if (_section != null && _plugins.look(context, c)?.$1.tap != null) Choice('Open conversation', Lucide.messageSquare, () => _open(c)),
      Choice('Select', Lucide.circleCheck, () => _toggle(c)),
      if (c.unread) Choice('Mark as read', Lucide.checkCheck, () async { await Sms.instance.markRead(c.id); _load(); }),
      // Plugins: their own lines for this conversation ("Not spam").
      if (!widget.archived) ..._plugins.menu(context, c),
      Choice(c.pinned ? 'Unpin' : 'Pin to top', c.pinned ? Lucide.pinOff : Lucide.pin, () => _pin(c)),
      // Snooze (GMFB-36): out of Messages until a time, then back at the top.
      if (!widget.archived) _snoozeChoice(Snoozed.text(c.id), c.title),
      Choice(c.muted ? 'Unmute' : 'Mute notifications', c.muted ? Lucide.bell : GhostIcons.bellOff, () async {
        await Sms.instance.threadFlag('muted', c.id, !c.muted);
        await _load();
        if (mounted) toast(context, c.muted ? 'Notifications on' : 'Muted. Messages still arrive, quietly.');
      }),
      Choice(c.archived ? 'Unarchive' : 'Archive', c.archived ? Lucide.archiveRestore : Lucide.archive, () => _archive(c)),
      // On a computer, blocking and deleting are offered when the phone it is paired with does them for one.
      if (!c.group && c.people.isNotEmpty && Sms.can('setBlocked'))
        blockChoice(context, BlockTarget.number(c.people.first.address, c.title, thread: c.id), blocked: c.blocked, done: _load),
      if (Sms.can('deleteThreads')) Choice('Delete conversation', Lucide.trash2, () => _confirmDelete(c), danger: true),
    ]);
  }

  /// What the list holds of one conversation is changed at once, before Android has answered: the row moves as the
  /// finger lets go, not when the read that follows comes back.
  void _patch(int id, Conversation Function(Conversation) change) => _feed.patch(id, change);

  /// Archives [c], or takes it back out: from its menu, or by dragging its row to the left.
  Future<void> _archive(Conversation c) async {
    _patch(c.id, (x) => x.copyWith(archived: !c.archived));
    try {
      await Sms.instance.archive(c.id, !c.archived);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t ${c.archived ? 'unarchive' : 'archive'}: $e', tone: GlacierToastTone.danger);
    }
    _load();
    if (!mounted) return;
    toast(context, c.archived ? 'Moved back to Messages' : 'Archived',
        action: GlacierToastAction(label: 'Undo', onPress: () async {
          _patch(c.id, (x) => x.copyWith(archived: c.archived));
          await Sms.instance.archive(c.id, c.archived);
          _load();
        }));
  }

  /// Pins [c] to the top, or lets it go: from its menu, or by dragging its row to the right.
  Future<void> _pin(Conversation c) async {
    _patch(c.id, (x) => x.copyWith(pinned: !c.pinned));
    try {
      await Sms.instance.threadFlag('pinned', c.id, !c.pinned);
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t ${c.pinned ? 'unpin' : 'pin'}: $e', tone: GlacierToastTone.danger);
    }
    _load();
  }

  /// Asks before deleting [c], unless it was [slid] and "Don't ask again" was chosen once (deleteAskOff).
  void _confirmDelete(Conversation c, {bool slid = false}) {
    // A swipe can ask for this where the menu would not offer it: a computer paired with a phone that is behind.
    if (!Sms.can('deleteThreads')) {
      toast(context, 'Update Uplink on your phone to delete from here.');
      return;
    }
    Future<void> delete() async {
      try {
        await Sms.instance.deleteThread(c.id);
        // Gone from the list at once, where it used to stay until every conversation had been read again.
        _feed.remove([c.id]);
        if (mounted) toast(context, 'Conversation deleted');
      } catch (e) {
        if (mounted) toast(context, 'Couldn\'t delete: ${e is PlatformException ? (e.message ?? e.code) : e}', tone: GlacierToastTone.danger);
      }
      _load();
    }

    final app = AppState.of(context);
    if (slid && deleteAskOff(app)) {
      delete();
      return;
    }
    showChoices(context, title: 'Delete every message with ${c.title}? This can\'t be undone.', choices: [
      Choice('Delete', Lucide.trash2, delete, danger: true),
      if (slid) dontAskAgainChoice(app, delete),
    ]);
  }

  // --- several at once ------------------------------------------------------------------------------------------------

  String _count(int n) => '$n ${n == 1 ? 'conversation' : 'conversations'}';

  /// Asked first, with how many: a deleted conversation is gone from the phone, for every app.
  void _confirmDeleteSelected() {
    final ids = _selected.toList();
    showChoices(
      context,
      title: 'Delete ${_count(ids.length)}? Every message in ${ids.length == 1 ? 'it' : 'them'} is deleted from this phone, for every app. This can\'t be undone.',
      choices: [
        Choice('Delete ${_count(ids.length)}', Lucide.trash2, () async {
          try {
            await Sms.instance.deleteThreads(ids);
            if (mounted) {
              setState(_selected.clear);
              _feed.remove(ids);
            }
            await _load();
            if (mounted) toast(context, '${_count(ids.length)} deleted');
          } catch (e) {
            if (mounted) toast(context, 'Couldn\'t delete: $e', tone: GlacierToastTone.danger);
          }
        }, danger: true),
      ],
    );
  }

  /// Archives the selected conversations (or, on the Archived page, moves them back), with an Undo in the toast.
  Future<void> _archiveSelected() async {
    final ids = _selected.toList();
    final to = !widget.archived;
    for (final id in ids) {
      await Sms.instance.archive(id, to);
    }
    if (mounted) setState(_selected.clear);
    await _load();
    if (!mounted) return;
    toast(context, to ? '${_count(ids.length)} archived' : '${_count(ids.length)} moved back to Messages', action: GlacierToastAction(label: 'Undo', onPress: () async {
      for (final id in ids) {
        await Sms.instance.archive(id, !to);
      }
      _load();
    }));
  }

  void _settings([String? section]) async {
    final shell = _shell;
    if (shell != null) return shell.settings(section);
    await push<void>(context, (_) => section == null ? const SettingsScreen() : SettingsSectionScreen(section));
    _look();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.of(context);
    // What a tab holds is worked out again for each build (the filters may have changed), once ([_of]).
    _ofMemo.clear();
    // Plugins: given the person's choices, then asked which section each conversation is in. A section that has
    // emptied gives way to the main list.
    if (!widget.archived) {
      _plugins.bind(app);
      // The filter: which kinds of text Messages shows, as the person chose or as each kind starts.
      _plugins.shown = (k) => ListPlugins.kindShown(app, k);
      _plugins.othersShown = () => ListPlugins.othersShownFor(app);
    }
    final sorted = _plugins.sort(widget.archived ? null : _all, chats: widget.archived ? const [] : _chatFacts());
    final inbox = widget.archived ? null : inboxOfTab(_section);
    // Under the rail there is no Circles tab: what was on it is the rail's, and its invites are atop Messages.
    final railed = AppShell.railOf(context);
    if (!sorted.has(_section) && !(_section == ListPlugins.hiddenView && _plugins.hiddenCount > 0) && !(_section == circlesTab && !widget.archived && !railed) && inbox?.state != InboxState.ready) _section = null;
    if (!widget.archived && ConversationsScreen.shownTab.value != _section) {
      final now = _section;
      WidgetsBinding.instance.addPostFrameCallback((_) => ConversationsScreen.shownTab.value = now);
    }
    final shown = _shown;
    // Another tab, or a search begun or ended: the rows held where they were are let go, each to its own place.
    final view = '$_section\u001f${_query.trim().isEmpty}';
    if (view != _view) {
      _view = view;
      _hold.settle();
    }
    _drawn = const [];
    // What the list holds: conversations, the voice channels in their tab, or a network's chats in its.
    final List<Object> rows = inbox != null && inbox.state == InboxState.ready
        // A network's own tab leaves out what the filters hide from Messages, as Messages does (Matt, 2026-11-16: "Fix
        // the filtering a bit more this message got through"); a search finds it.
        ? [
            for (final c in inbox.chats)
              // Held by the Human check (lib/inbox/human_check.dart, GMFB-23): in its "held" row, not here.
              if (!inbox.heldIds.contains(c.id) &&
                  (_query.isEmpty || c.title.toLowerCase().contains(_query.toLowerCase()) || c.snippet.toLowerCase().contains(_query.toLowerCase())) &&
                  !_plugins.hidesChat('${c.network}:${c.id}', searching: _query.isNotEmpty) &&
                  (_spamHost == null || _query.isNotEmpty || (Inbox.instance.named(c.network)?.localList('notspam').contains(c.id) ?? false) || scamOf(c) == null))
                c,
          ]
        : _section == circlesTab
            // Circles offered and not yet joined at the top (lib/ui/circles/circle_invite_card.dart), then each circle.
            ? _circlesTabRows()
            : [
                // Circle invites waiting, at the top of Messages where the rail has taken the Circles tab's place.
                if (railed && _section == null && _query.isEmpty && !widget.archived && !_selecting) ...circleInviteRows(context, Circles.instance.invites),
                ..._snoozing(_drawn = _mixed(shown)),
              ];
    // Android's own count, where it has answered: the ones held are not all of them until the read ends.
    final archivedCount = widget.archived ? 0 : (_more ? _archived : (_all ?? const <Conversation>[]).where((c) => c.archived).length) + Inbox.instance.ready.fold<int>(0, (n, net) => n + net.archivedChats.length);
    // Older conversations still arriving: said at the foot of the list, and in place of "Nothing found".
    final more = _more && !widget.archived;
    // Another network still starting (signed in, its chats not listed yet: Telegram takes seconds as the app opens):
    // its chats are coming, and the list says so with a few rows in bones at its foot, as it does for older texts.
    // They used to arrive into a list that looked complete.
    bool starting(InboxNetwork n) => !n.soon && n.state == InboxState.signingIn && n.step == InboxStep.none;
    final netsComing = !widget.archived && _query.isEmpty && !_selecting && (inbox != null ? starting(inbox) : (_section == null && Inbox.instance.networks.any(starting)));
    final coming = more || netsComing;
    final gutter = t.space(4);
    // Texts from people who use RCS may still be going to the app this one replaced: said until it is dismissed.
    final notice = !widget.archived && _query.isEmpty && !_selecting && _section == null && _arriving.rcsLikely && !_beside && app.flag('rcs_notice');
    // The recovery words put off at sign-up (GMFB-3): a reminder until they are seen in Settings › Me.
    final wordsDue = !widget.archived && _query.isEmpty && !_selecting && _section == null && app.flag(wordsLater, fallback: false);
    // The conversations another device handed over were cut short (Friends.historyKind's `e: 2`): said once, here.
    final partDue = !widget.archived && _query.isEmpty && !_selecting && _section == null && app.flag('history_partial', fallback: false);
    // The conversation open in the pane, and whether that is beside the list: its row is marked for it there.
    final open = AppShell.threadOf(context);
    // Noted for when it gives way (_back): one opened into an empty pane closes nothing, so nothing else says it.
    if (open != null) _openWas = open;
    final beside = AppShell.wideOf(context) ? open : null;
    // A Signal or Telegram chat open beside the list is marked as a conversation of texts is (Matt, 2026-11-17:
    // "clicking on a telegram or signal chat does not highlight it as selected in the sidebar").
    final besideChat = AppShell.wideOf(context) ? AppShell.showingOf(context) : null;
    final status = AppShell.statusOf(context);
    final framed = _shell != null;
    // Dial-Up: the list is a window called Chat List (the era's own name for it is another company's mark), its rows flat in a white well (lib/ui/dialup/), still newest
    // first (the design's critique: "ship v1 as a pure re-skin of the recency list ... and add groups later").
    final dialup = isBevelChrome(t);
    // The cards' shape, as ConversationRow and PluginRow draw it: the actions show inside it. Dial-Up's rows are
    // flat across the well, so its actions are too.
    final card = dialup ? (inset: EdgeInsets.zero, radius: 0.0) : (inset: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')), radius: t.lenOf('1rem'));

    final unreadHere = _unreadTexts(_section).length + _unreadChats(_section).length + _unreadSpaces(_section).length;
    // The Messages ring's number (GMFB-17): what is unread in Messages itself, whichever tab is open here.
    if (!widget.archived && _all != null) {
      final inMessages = _unreadTexts(null).length + _unreadChats(null).length + _unreadSpaces(null).length;
      final shell = _shell;
      if (shell != null && shell.messagesUnread.value != inMessages) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) shell.messagesUnread.value = inMessages;
        });
      }
    }
    // Mark all read, Share feedback and the tabs' toggle scroll away with the list, the search staying (Matt, 2026-11-20:
    // "scroll the share feedback mark all as read and the segmented toggle when scrolling down"): the list's first row.
    // Dial-Up's list is a well sunk into the window, so there they stay over it.
    final lead = widget.archived || _selecting || dialup
        ? null
        : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [_quickRows(t, unreadHere), ?_tabsRow(t)]);

    Widget body;
    if (_all == null) {
      // The list in bones while it is read (lib/ui/skeleton.dart), where an arc turned in the middle of an empty page.
      const bones = SkeletonCards(label: 'Loading your conversations…');
      body = lead == null ? bones : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [lead, const Expanded(child: bones)]);
    } else if (_error != null && rows.isEmpty) {
      body = _withLead(lead, EdgeInsets.fromLTRB(gutter, t.space(10), gutter, 0), [
        SettingsEmpty(
          icon: AppIcon(Lucide.circleAlert, size: 28, color: t.danger),
          title: 'Couldn\'t read your messages',
          body: Text('Android didn\'t hand them over: $_error\nNothing has been deleted. They are still in Android\'s store.'),
          action: SettingsEmptyAction('Try again', _load),
        ),
      ]);
    } else if (rows.isEmpty && inbox != null && netsComing) {
      // The network's own tab while it starts: its chats in bones, not "Not signed in".
      body = _withLead(lead, EdgeInsets.zero, [SkeletonCards(label: 'Loading ${inbox.name} chats…', most: 8, shrink: true)]);
    } else if (rows.isEmpty && inbox != null) {
      body = _withLead(lead, EdgeInsets.fromLTRB(gutter, t.space(10), gutter, 0), [inboxEmpty(context, inbox)]);
    } else if (rows.isEmpty && _section == circlesTab) {
      body = _withLead(lead, EdgeInsets.fromLTRB(gutter, t.space(10), gutter, 0), [
        SettingsEmpty(
          icon: AppIcon(Lucide.circleDot, size: 28, color: t.color('app-ink-3')),
          title: 'No circles yet',
          body: const Tr('A circle keeps a few people and their spaces together: for chat and voice, for texting, or for files.'),
          action: SettingsEmptyAction('New circle', () => _shell != null ? _shell!.show(const NewCircleScreen(key: ValueKey('new-circle')), showing: 'new') : push(context, (_) => const NewCircleScreen())),
        ),
      ]);
    } else if (rows.isEmpty && _section == CodesPlugin.section && _query.isEmpty) {
      // Its tab is there before any code is (Matt, 2026-11-19: "always show the codes tab even if we don't have any
      // codes yet"), so it says what will be here.
      body = _withLead(lead, EdgeInsets.fromLTRB(gutter, t.space(10), gutter, 0), [
        SettingsEmpty(
          icon: AppIcon(Lucide.keyRound, size: 28, color: t.color('app-ink-3')),
          title: 'No codes yet',
          body: const Tr('Sign-in codes sent to you wait here, the newest first. A tap copies one.'),
        ),
      ]);
    } else if (rows.isEmpty) {
      final rcs = _query.isEmpty && !widget.archived && _arriving.rcsLikely;
      body = _withLead(lead, EdgeInsets.fromLTRB(gutter, t.space(10), gutter, 0), [
        SettingsEmpty(
          // The app's own mark, as it is on the home screen (Matt, 2026-11-14: "I also want the ghost image used
          // when there are no messages to use the logo"), where a drawn outline of a ghost stood.
          icon: const GhostLogo(),
          title: _query.isNotEmpty ? (more ? 'Nothing found yet' : 'Nothing found') : (widget.archived ? 'Nothing archived' : 'No conversations yet'),
          body: Text(_query.isNotEmpty
              ? (more ? 'Older conversations are still being read. Nothing so far matches "$_query".' : 'No name, number or message matches "$_query".')
              : widget.archived
                  ? 'Conversations you archive wait here.'
                  : rcs
                      ? 'There are no texts in Android\'s store. Chats that were RCS in ${_arriving.app} stay in that app, where no other app can read them: they are not deleted.'
                      // Texts passed by in the walkthrough: the list is friends' chats alone until they are turned on.
                      : Sms.textsOff && !Sms.remote && !Sms.standalone
                          ? 'Your texts are off, so chats with friends on Uplink show here. Turn texts on to see your texts too.'
                          : framed
                          ? 'Start one with New chat, the first button below.'
                          : 'Start one with the new message button at the top.'),
          action: rcs
              ? SettingsEmptyAction('What to do', () => _settings('android'))
              : _query.isEmpty && !widget.archived && Sms.textsOff && !Sms.remote && !Sms.standalone
                  ? SettingsEmptyAction('Turn on texts', () => _settings('texts'))
                  : null,
        ),
      ]);
    } else {
      final extras = (lead != null ? 1 : 0) + (notice ? 1 : 0) + (wordsDue ? 1 : 0) + (partDue ? 1 : 0);
      // In the frame the way to the archive is the pill's ring, with its number.
      final tail = !framed && !widget.archived && archivedCount > 0 && _query.isEmpty && !_selecting && _section == null;
      // What the filter hides, said at the list's foot with the way to see it: nothing is lost quietly.
      final hiddenNow = !widget.archived && _query.isEmpty && !_selecting && _section == null ? _plugins.hiddenCount : 0;
      final foot = hiddenNow > 0;
      body = RefreshableList(
        // Pulled down to read it again: put straight too (lib/ui/list_order.dart).
        onRefresh: () {
          _hold.settle();
          return _load();
        },
        itemCount: extras + rows.length + (foot ? 1 : 0) + (tail ? 1 : 0) + (coming ? 1 : 0) + 1,
        itemBuilder: (context, i) {
          if (lead != null && i == 0) return lead;
          if (notice && i == (lead != null ? 1 : 0)) {
            return _RcsNotice(app: _arriving.app, onFix: () => _settings('android'), onDismiss: () => app.setFlag('rcs_notice', false));
          }
          if (wordsDue && i == (lead != null ? 1 : 0) + (notice ? 1 : 0)) {
            return _WordsNotice(onShow: () => push(context, (_) => const ShowWordsScreen()), onDismiss: () => app.setFlag(wordsLater, false));
          }
          if (partDue && i == (lead != null ? 1 : 0) + (notice ? 1 : 0) + (wordsDue ? 1 : 0)) {
            return HistoryPartNotice(onDismiss: () => app.setFlag('history_partial', false));
          }
          final at = i - extras;
          if (at < rows.length && rows[at] is InboxChat) {
            final chat = rows[at] as InboxChat;
            final network = inbox ?? Inbox.instance.named(chat.network);
            if (network == null) return const SizedBox.shrink();
            final code = _section == CodesPlugin.section ? inboxCode(chat) : null;
            final codesHost = code == null ? null : _codesHost;
            final why = _section == SpamPlugin.section ? scamOf(chat) : null;
            final spamHost = why == null ? null : _spamHost;
            final pinned = network.isPinned(chat);
            // Slid as a conversation of texts is (Matt, 2026-11-15: "Don't use a press and hold menu on telegram chats
            // use the same slide solution normal messages use"): left archives, further deletes (asked first), right
            // pins, each on the network itself where it can.
            return SwipeActions(
              key: ValueKey('swipe-inbox-${chat.network}-${chat.id}'),
              enabled: !_selecting,
              archiveLabel: widget.archived ? 'Unarchive' : 'Archive',
              archiveIcon: widget.archived ? Lucide.archiveRestore : Lucide.archive,
              pinLabel: pinned ? 'Unpin' : 'Pin',
              pinIcon: pinned ? Lucide.pinOff : Lucide.pin,
              onArchive: () => network.archive(chat.id, !widget.archived),
              onDelete: () => confirmInboxDelete(context, network, chat, slid: true),
              onPin: () => network.pin(chat.id, !pinned),
              card: card,
              child: code != null && codesHost != null
                  ? _inboxCodeRow(chat, network, code, codesHost)
                  : why != null && spamHost != null
                  ? _inboxSpamRow(chat, network, why, spamHost)
                  : InboxChatRow(
                      key: ValueKey('inbox-${chat.network}-${chat.id}'),
                      chat: chat,
                      selected: besideChat == 'inbox:${chat.network}:${chat.id}',
                      onPress: () => openInboxChat(context, network, chat),
                    ),
            );
          }
          // A circle's invite, or the heading over those put off: drawn already.
          if (at < rows.length && rows[at] is Widget) return rows[at] as Widget;
          if (at < rows.length && rows[at] is Circle) {
            final c = rows[at] as Circle;
            return CircleRow(key: ValueKey('circle-row-${c.seed}'), circle: c);
          }
          if (at < rows.length && rows[at] is VoiceChannel) {
            final v = rows[at] as VoiceChannel;
            final archived = Voice.instance.archived(v);
            // Slid as a conversation is (Matt, 2026-11-17: "can be swiped to leave a space or delete / archive"): left
            // archives, further deletes (asked first), right leaves (asked first).
            return SwipeActions(
              key: ValueKey('swipe-space-${v.room}'),
              enabled: !_selecting,
              archiveLabel: archived ? 'Unarchive' : 'Archive',
              archiveIcon: archived ? Lucide.archiveRestore : Lucide.archive,
              pinLabel: 'Leave',
              pinIcon: Lucide.logOut,
              onArchive: () => setState(() => Voice.instance.archive(v, !archived)),
              onDelete: () => confirmDeleteHangout(context, v),
              onPin: () => confirmLeaveHangout(context, v),
              card: card,
              // Selected only while the pane beside the list shows it: a space opened before and left for another chat
              // stays Voice's viewing one, and was drawn as open with that chat beside it (Matt, 2026-11-17: "the only
              // ghosts chat is always highlighted even when it's not active in the front").
              child: _spaceRow(v, selected: besideChat == 'voice' && (Voice.instance.viewing ?? Voice.instance.session?.channel)?.seed == v.seed),
            );
          }
          if (at < rows.length) {
            // The one that is open is being read: its row does not say unread, however it came to be opened (a
            // tap here, a notification, another app's "text this number").
            final held = rows[at] as Conversation;
            final c = held.id == open && held.unread ? held.copyWith(unread: false) : held;
            // Plugins: in a section, the row is drawn as the section's plugin describes it (a code large, with Copy).
            final look = _section == null ? null : _plugins.look(this.context, c);
            final selected = _selecting ? _selected.contains(c.id) : c.id == beside;
            // Dragged left it archives, further it deletes (asked first), right it pins: lib/ui/swipe_actions.dart.
            return SwipeActions(
              key: ValueKey('swipe-${c.id}'),
              enabled: !_selecting,
              archiveLabel: c.archived ? 'Unarchive' : 'Archive',
              archiveIcon: c.archived ? Lucide.archiveRestore : Lucide.archive,
              pinLabel: c.pinned ? 'Unpin' : 'Pin',
              pinIcon: c.pinned ? Lucide.pinOff : Lucide.pin,
              onArchive: () => _archive(c),
              onDelete: () => _confirmDelete(c, slid: true),
              onPin: () => _pin(c),
              card: card,
              child: look != null
                  ? PluginRow(conversation: c, look: look.$1, host: look.$2, selecting: _selecting, selected: selected, onPress: () => _selecting ? _toggle(c) : _open(c), onLongPress: () => _selecting ? _toggle(c) : _menu(c))
                  : ConversationRow(
                      conversation: c,
                      // A group of friends' call, while anyone is in it: its space is its conversation's.
                      live: _groupInCall(c),
                      // Unread texts summed up by the phone's own model, made as the row is first shown.
                      summary: widget.archived ? null : (Summaries.instance..want(c)).of(c),
                      selecting: _selecting,
                      selected: selected,
                      onPress: () => _selecting ? _toggle(c) : _open(c),
                      onLongPress: () => _selecting ? _toggle(c) : _menu(c),
                    ),
            );
          }
          if (foot && at == rows.length) {
            return GlacierPressable(
              onPressed: () => setState(() => _section = ListPlugins.hiddenView),
              semanticLabel: '$hiddenNow hidden by the filter. Show them.',
              builder: (context, state) => Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter, vertical: t.space(4)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  AppIcon(LucideMore.funnel, size: 15, color: t.color(state.pressed ? 'app-ink-4' : 'app-ink-3')),
                  SizedBox(width: t.space(2)),
                  Text('$hiddenNow hidden · Show', style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color(state.pressed ? 'app-ink-4' : 'app-ink-3'))),
                ]),
              ),
            );
          }
          if (tail && at == rows.length + (foot ? 1 : 0)) {
            return GlacierPressable(
              onPressed: () async {
                await push<void>(context, (_) => const ConversationsScreen(archived: true));
                _load();
              },
              builder: (context, state) => Padding(
                padding: EdgeInsets.symmetric(horizontal: gutter, vertical: t.space(4)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  AppIcon(Lucide.archive, size: 16, color: t.color(state.pressed ? 'app-ink-4' : 'app-ink-3')),
                  SizedBox(width: t.space(2)),
                  Text('Archived ($archivedCount)', style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color(state.pressed ? 'app-ink-4' : 'app-ink-3'))),
                ]),
              ),
            );
          }
          if (coming && at == rows.length + (foot ? 1 : 0) + (tail ? 1 : 0)) {
            // The next few in bones while they are read (lib/ui/skeleton.dart).
            return SkeletonCards(label: more ? 'Loading older conversations…' : 'Loading chats…', most: 3, shrink: true);
          }
          // Clear of the bar at the foot of the phone's screen, and of the frame's pill floating over the list's end.
          // Dial-Up's well already ends above both.
          if (dialup) return SizedBox(height: t.space(1));
          return SizedBox(height: MediaQuery.paddingOf(context).bottom + (framed ? AppShell.pillRoom(context) : t.space(4)));
        },
      );
    }

    // The header's buttons: a plugin's (the cleaner), and Mark all read while anything is unread. With neither, and
    // nothing else there, the page has no bar (Matt, 2026-11-19: "if there is no mark as read or cleaner icons rendered
    // at the top remove the extra space above the searchbar too").
    // A plugin's buttons (the cleaner's Clean up) are rows under the search now (_quickRows), but in Dial-Up's title bar.
    final headerButtons = widget.archived || _selecting || !dialup ? const <Widget>[] : _plugins.header(context, ListPlace(section: _section, shown: shown.length, groups: _plugins.groups(_all ?? const [])));
    final page = GhostPage(
      // Mark all read and Share feedback are rows under the search now (_quickRows): the bar holds a plugin's buttons alone.
      noBar: !dialup && !widget.archived && !_selecting && framed && headerButtons.isEmpty,
      title: widget.archived ? 'Archived' : (dialup ? 'Chat List' : 'Messages'),
      back: widget.archived && !_selecting,
      // A newer version waiting: above the title and the search (Matt, 2026-11-14: "move the update banner on desktop
      // and mobile to show at the top of the sidebar above where it says messages and has the search bar").
      top: widget.archived ? null : const UpdateCard(),
      // While several are being chosen the bar counts them, and holds what can be done with them. Dial-Up's bar draws
      // its own words, so there the count is the title and the way out its first button.
      subtitle: dialup && _selecting ? '${_selected.length} selected' : null,
      // No "Messages" over the list (Matt, 2026-11-17: "Remove the word messages from the top of the page its
      // redundant"): the row keeps its buttons. The archive keeps its name, and Dial-Up its title bar's.
      titleWidget: !_selecting
          ? (widget.archived || dialup ? null : const SizedBox.shrink())
          : Row(children: [
              if (!widget.archived) const SizedBox(width: 0) else SizedBox(width: t.space(3)),
              IconTap(icon: Lucide.x, label: 'Stop selecting', onPressed: () => setState(_selected.clear)),
              SizedBox(width: t.space(1)),
              Expanded(child: Text('${_selected.length} selected', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink')))),
            ]),
      actions: [
        if (_selecting) ...[
          if (dialup) IconTap(icon: Lucide.x, label: 'Stop selecting', onPressed: () => setState(_selected.clear)),
          IconTap(icon: Lucide.checkCheck, label: 'Select all', onPressed: () => setState(() => _selected.addAll(shown.map((c) => c.id)))),
          IconTap(icon: widget.archived ? Lucide.archiveRestore : Lucide.archive, label: widget.archived ? 'Unarchive' : 'Archive', onPressed: _archiveSelected),
          if (Sms.can('deleteThreads')) IconTap(icon: Lucide.trash2, label: 'Delete', color: t.danger, onPressed: _confirmDeleteSelected),
        ] else if (!widget.archived) ...[
          // Plugins: their buttons for the list's header, in the frame and out of it.
          ...headerButtons,
          // Shown alone, with no frame and so no pill: the two it would hold.
          // The same plain plus as the pill's, that says New (Matt, 2026-11-17).
          if (!framed) IconTap(icon: Lucide.plus, label: 'New', onPressed: _compose),
          if (!framed) IconTap(icon: Lucide.settings, label: 'Settings', onPressed: _settings),
        ],
      ],
      body: Stack(
        children: [
          if (dialup) Positioned.fill(child: ColoredBox(color: DialupColors.of(t).chrome)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // As wide as the cards under it, edge to edge with them.
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(t.space(2), dialup ? t.space(2) : 0, t.space(2), t.space(2)),
                child: Builder(builder: (context) {
                  final field = GlacierSearchField(
                    // Where the Search command puts the cursor (lib/keys.dart): the conversations' own, not the archive's.
                    focusNode: widget.archived ? null : Keys.searchFocus,
                    placeholder: widget.archived ? 'Search archived' : 'Search messages',
                    size: GlacierFieldSize.md,
                    onValueChange: (v) => setState(() => _query = v),
                  );
                  final search = dialup ? DialupWell(child: field) : field;
                  // On the Mac it is in the window's title strip instead (lib/desktop/ui/desk_title_bar.dart).
                  if (widget.archived || MacChrome.stripEnabled) return search;
                  // Share feedback is a row under the search now (_quickRows).
                  // Share feedback beside the search, at the top of the list on a phone and beside a pane, there
                  // whether or not the page has a bar over it (Matt, 2026-11-19: "add a "share feedback" button
                  // hovering in the topbar of the app"; the bar goes when it has nothing in it: "remove the extra space
                  // above the searchbar too").
                  return Row(children: [
                    Expanded(child: search),
                    // Souls, with their flame, beside Share feedback (lib/ui/souls.dart; Matt, 2026-11-19: "display the
                    // points in the top bar next to the feedback button with a flame icon next to them").
                    Padding(padding: EdgeInsetsDirectional.only(start: t.space(2)), child: const SoulsChip()),
                  ]);
                }),
              ),
              // Mark all read and Share feedback, as a list of rows with their marks under the search, as Discord lists
              // its places (Matt, 2026-11-20: "layout the mark all read and the share feedback buttons to a icon list
              // like shown in the screenshot under the searchbar").
              // In the list's first row (lead above), but in Dial-Up's window, where they stay.
              if (dialup && !widget.archived && !_selecting) _quickRows(t, unreadHere),
              // What the frame keeps under the search: on a computer, how the phone is connected.
              if (status != null) Padding(padding: EdgeInsetsDirectional.fromSTEB(gutter, 0, gutter, t.space(2)), child: status),
              // The tabs: "Messages" and each section that has conversations in it, as one toggle, and beside them
              // the button that marks the tab shown as read (_tabsRow).
              if (dialup && !widget.archived && !_selecting) ?_tabsRow(t),
              // The search is this page's header too.
              const HeaderEnd(),
              // A read of Android's store that is taking a moment: a thin bar, where the list already shows.
              SizedBox(
                height: 3,
                child: _slow && _all != null ? const GlacierProgressBar(indeterminate: true, ariaLabel: 'Loading your conversations') : null,
              ),
              // Plugins: what they put between the search field and the list.
              if (!widget.archived)
                ..._plugins.above(
                  context,
                  ListPlace(section: _section, shown: shown.length, counts: _plugins.counts, unread: _plugins.unreadSections, show: (section) => setState(() => _section = section)),
                ),
              Expanded(
                child: !dialup
                    ? body
                    // The rows in a white well sunk into the window, which ends above the taskbar (or the screen's
                    // foot where there is none).
                    : Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(t.space(1), 0, t.space(1), t.space(1) + (framed ? AppShell.pillRoom(context) + MediaQuery.paddingOf(context).bottom : MediaQuery.paddingOf(context).bottom)),
                        child: Sunken(child: body),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
    // Android's back leaves choosing before it leaves the page.
    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting) setState(_selected.clear);
      },
      child: page,
    );
  }
}

/// A list that refreshes when pulled past its top. Its rows are built as they come into view, so a phone with
/// thousands of conversations opens as fast as one with ten.
class RefreshableList extends StatefulWidget {
  const RefreshableList({super.key, required this.itemCount, required this.itemBuilder, required this.onRefresh});
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Future<void> Function() onRefresh;

  @override
  State<RefreshableList> createState() => _RefreshableListState();
}

class _RefreshableListState extends State<RefreshableList> {
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is OverscrollNotification && n.overscroll < 0 && n.metrics.pixels <= 0) _armed = true;
        if (n is ScrollUpdateNotification && n.metrics.pixels < -60) _armed = true;
        if (n is ScrollEndNotification && _armed) {
          _armed = false;
          widget.onRefresh();
        }
        return false;
      },
      child: ListView.builder(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.zero,
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      ),
    );
  }
}

/// Over the list until it is dismissed, where the app this one replaced keeps RCS chats: why some people's texts may
/// not be arriving, and the way to what to do about it (Settings › Android).
/// Your other device handed over your newest conversations and not all of them (GMFB-53: an answer is at most
/// Friends.historyParts parts): said over the list, until put away.
class HistoryPartNotice extends StatelessWidget {
  const HistoryPartNotice({super.key, required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      key: const ValueKey('history-part-notice'),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)),
      child: Container(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(1), t.space(3)),
        decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AppIcon(Lucide.history, size: 18, color: t.color('app-ink-2'))),
          SizedBox(width: t.space(3)),
          Expanded(child: Text('Your newest conversations came from your other device. Older conversations stay on your other device.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4))),
          IconTap(icon: Lucide.x, label: 'Dismiss', size: 16, box: t.lenOf('2.25rem'), onPressed: onDismiss),
        ]),
      ),
    );
  }
}

/// The recovery words, put off at sign-up, still to be written down (GMFB-3): the way to them, or put away.
class _WordsNotice extends StatelessWidget {
  const _WordsNotice({required this.onShow, required this.onDismiss});
  final VoidCallback onShow;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      key: const ValueKey('words-notice'),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)),
      child: Container(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(1), t.space(3)),
        decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AppIcon(Lucide.keyRound, size: 18, color: t.color('app-ink-2'))),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Write down your recovery words', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
              SizedBox(height: t.lenOf('0.15rem')),
              Text('Your username and password sign you in on another device. The 12 words are for when the password is lost.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
              SizedBox(height: t.space(2)),
              GlacierPressable(
                onPressed: onShow,
                semanticLabel: 'Show my recovery words',
                builder: (context, state) => Text('Show them', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color(state.pressed ? 'app-ink-3' : 'app-ink')).copyWith(decoration: TextDecoration.underline)),
              ),
            ]),
          ),
          IconTap(icon: Lucide.x, label: 'Dismiss', size: 16, box: t.lenOf('2.25rem'), onPressed: onDismiss),
        ]),
      ),
    );
  }
}

class _RcsNotice extends StatelessWidget {
  const _RcsNotice({required this.app, required this.onFix, required this.onDismiss});
  final String app;
  final VoidCallback onFix;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)),
      child: Container(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(1), t.space(3)),
        decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AppIcon(Lucide.triangleAlert, size: 18, color: t.warn)),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Texts from some people not arriving?', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
              SizedBox(height: t.lenOf('0.15rem')),
              Text('If RCS chats were on in $app, people who use RCS are still sending you chats there, not texts. Your old RCS chats are kept there too.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
              SizedBox(height: t.space(2)),
              GlacierPressable(
                onPressed: onFix,
                semanticLabel: 'What to do',
                builder: (context, state) => Text('What to do', style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color(state.pressed ? 'app-ink-3' : 'app-ink')).copyWith(decoration: TextDecoration.underline)),
              ),
            ]),
          ),
          IconTap(icon: Lucide.x, label: 'Dismiss', size: 16, box: t.lenOf('2.25rem'), onPressed: onDismiss),
        ]),
      ),
    );
  }
}

/// One conversation in the list: its face, its name, its last words and when. The Mac's list (lib/desktop) draws its
/// rows with it too.
class ConversationRow extends StatelessWidget {
  const ConversationRow({super.key, required this.conversation, required this.onPress, required this.onLongPress, this.selecting = false, this.selected = false, this.summary, this.badge, this.unreadCount, this.live, this.face, this.timed = true, this.mentioned = false});
  final Conversation conversation;

  /// Its face at a size, in place of the people's: a circle's own (the Circles tab draws its circles as conversations,
  /// so they get the same card, line, time and unread dot, Dial-Up's transcript line among them).
  final Widget Function(double size)? face;

  /// The time is shown at its end; off where there is none to show (a circle nobody has written in yet).
  final bool timed;

  /// How many are in its call now, where it has one (a space, a group of friends): said in green in the time's place.
  final int? live;

  /// How many are unread, where that is known (a chat on Telegram or Signal): Dial-Up's row says it after the name,
  /// "Maya (3)". A conversation of texts knows only that some are, and says "(new)".
  final int? unreadCount;

  /// Something unread in it mentions the person (a space's, a circle's): an "@" on its mark.
  final bool mentioned;

  /// A mark on the face's corner: the network a chat from Telegram or Bluesky is on (lib/ui/inbox_ui.dart).
  final Widget? badge;

  /// What its unread texts come to, in a line, by the phone's own model (lib/summaries.dart): shown in place of the
  /// last words, marked as a summary.
  final String? summary;
  final VoidCallback onPress;
  final VoidCallback onLongPress;

  /// Several conversations are being chosen: the face gives way to a tick, and a tap chooses.
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = conversation;
    final unread = c.unread;
    if (isBevelChrome(t)) return _dialup(context, t);
    final face = t.lenOf('3rem');
    return GestureDetector(
      onLongPress: onLongPress,
      // A press with the other button, as a computer's lists have it, where a phone has a long press.
      onSecondaryTap: onLongPress,
      child: GlacierPressable(
        onPressed: onPress,
        semanticLabel: selecting ? '${c.title}, ${selected ? 'selected' : 'not selected'}' : null,
        // Each conversation is a card, and the one chosen (the one open on a computer, the ones ticked on a phone)
        // wears a line round it in the page's ink, white on the dark page (Matt, 2026-11-14: "I don't like the style
        // of selected messages having the light blue background, instead make each in cards so the card can have a
        // 2px white outline for selected chats with rounded borders"). The line's room is always kept, so choosing
        // one moves nothing.
        builder: (context, state) => Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
          child: Container(
            decoration: BoxDecoration(
              color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
              // Its corners under the look's radius scale (square in Dial-Up), and in a look that rules its shapes
              // (Sharp) a line round the card where Uplink keeps the room for one clear.
              borderRadius: BorderRadius.circular(lookCorner(t, '1rem')),
              border: Border.all(color: selected ? t.color('app-ink') : (lookRim(t) == null ? const Color(0x00000000) : t.color('glacier-border-subtle')), width: 2),
            ),
            padding: EdgeInsets.symmetric(horizontal: t.space(3) - 2, vertical: t.space(3) - 2),
            child: Row(
              children: [
                if (selecting)
                  Container(
                    width: face,
                    height: face,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? t.chosen : const Color(0x00000000),
                      border: Border.all(color: selected ? t.chosen : t.color('app-ink-4'), width: 2),
                    ),
                    alignment: Alignment.center,
                    child: selected ? const AppIcon(Lucide.check, size: 22, strokeWidth: 2.6, wash: false, color: Color(0xFFFFFFFF)) : null,
                  )
                else if (this.face != null)
                  this.face!(face)
                else if (badge != null)
                  SizedBox.square(
                    dimension: face,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Avatar(people: c.people, size: face),
                      PositionedDirectional(
                        end: -3,
                        bottom: -3,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2')),
                          child: badge,
                        ),
                      ),
                    ]),
                  )
                else
                  Avatar(people: c.people, size: face),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Row(children: [
                            Flexible(child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: unread ? 'bold' : 'semibold', color: t.color('app-ink')))),
                            // Texts with this person go sealed (Uplink's own encryption).
                            if (c.encrypted) ...[
                              SizedBox(width: t.space(1)),
                              Semantics(label: 'Encrypted', child: AppIcon(Lucide.lock, size: 12, strokeWidth: 2.4, wash: false, color: t.color('app-ink-3'))),
                            ],
                          ]),
                        ),
                        if (c.pinned) ...[SizedBox(width: t.space(1)), AppIcon(Lucide.pin, size: 13, color: t.color('app-ink-3'))],
                        if (c.muted) ...[SizedBox(width: t.space(1)), AppIcon(GhostIcons.bellOff, size: 13, color: t.color('app-ink-3'))],
                        if (c.blocked) ...[SizedBox(width: t.space(1)), AppIcon(Lucide.ban, size: 13, color: t.danger)],
                        SizedBox(width: t.space(2)),
                        if ((live ?? 0) > 0)
                          Semantics(
                            label: '$live in voice',
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: t.online)),
                              SizedBox(width: t.space(1)),
                              AppIcon(LucideMore.headphones, size: 12, strokeWidth: 2.4, wash: false, color: t.online),
                              SizedBox(width: 3),
                              Text('$live', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.online)),
                            ]),
                          )
                        else if (timed)
                          Text(listWhen(c.date), style: pageText(t, t.fontSize('xs'), weight: unread ? 'semibold' : 'regular', color: t.color(unread ? 'app-ink' : 'app-ink-3'))),
                      ]),
                      SizedBox(height: t.lenOf('0.15rem')),
                      Row(children: [
                        if (c.error) ...[AppIcon(Lucide.circleAlert, size: 14, color: t.danger), SizedBox(width: t.space(1))],
                        Expanded(
                          child: Text.rich(
                            c.draft != null && c.draft!.trim().isNotEmpty
                                ? TextSpan(children: [
                                    TextSpan(text: 'Draft: ', style: TextStyle(color: t.danger, fontWeight: t.weight('medium'))),
                                    TextSpan(text: c.draft!.replaceAll('\n', ' ')),
                                  ])
                                : summary != null && !c.error
                                    // A summary, as Apple marks one: the model's mark, then its line.
                                    ? TextSpan(children: [
                                        WidgetSpan(
                                          alignment: PlaceholderAlignment.middle,
                                          child: Padding(
                                            padding: EdgeInsetsDirectional.only(end: t.space(1)),
                                            child: Semantics(label: 'Summary', child: AppIcon(Lucide.sparkles, size: 13, strokeWidth: 2.2, wash: false, color: t.color('app-ink-2'))),
                                          ),
                                        ),
                                        TextSpan(text: summary),
                                      ])
                                    : TextSpan(text: c.error ? 'Not sent' : ownWords((reactionSnippet(c.snippet) ?? MessageFormat.plain(FileCard.preview(SoulsCard.preview(c.snippet)))).replaceAll('\n', ' '))),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: pageText(t, t.fontSize('sm'), weight: unread ? 'medium' : 'regular', color: t.color(unread ? 'app-ink' : 'app-ink-2'), height: 1.35),
                          ),
                        ),
                        if (unread) ...[
                          SizedBox(width: t.space(2)),
                          // The count where it is known (a network's chat), else a dot, both large enough to see.
                          UnreadBadge(count: unreadCount, mentioned: mentioned, color: t.unread),
                        ],
                      ]),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Dial-Up's row, as a buddy list had them: flat across the well with a line under it, a small square face in a
  /// sunken frame, the name (bold with how many are unread after it, "Maya (3)", where a dot was), the time at the
  /// end, and the last words on one line under the name. The one chosen is the era's navy with white words; a press
  /// shows the well's grey. The network's mark, too small for the corner of so small a face, follows the name.
  Widget _dialup(BuildContext context, Tokens t) {
    final c = conversation;
    final unread = c.unread;
    final d = DialupColors.of(t);
    return GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: GlacierPressable(
        onPressed: onPress,
        semanticLabel: selecting ? '${c.title}, ${selected ? 'selected' : 'not selected'}' : null,
        builder: (context, state) {
          final ink = selected ? d.onHighlight : d.ink;
          final soft = selected ? d.onHighlight : d.inkSoft;
          final count = unread ? (unreadCount != null && unreadCount! > 0 ? ' (${mentioned ? '@' : ''}$unreadCount)' : (mentioned ? ' (@)' : ' (new)')) : '';
          final words = c.draft != null && c.draft!.trim().isNotEmpty
              ? TextSpan(children: [
                  TextSpan(text: 'Draft: ', style: TextStyle(color: selected ? d.onHighlight : t.danger)),
                  TextSpan(text: c.draft!.replaceAll('\n', ' ')),
                ])
              : summary != null && !c.error
                  // A summary, marked as the design has it: a soft italic line after a » .
                  ? TextSpan(text: '» $summary', style: const TextStyle(fontStyle: FontStyle.italic))
                  : c.error
                      ? TextSpan(text: 'Not sent', style: TextStyle(color: selected ? d.onHighlight : t.danger))
                      : TextSpan(text: (reactionSnippet(c.snippet) ?? MessageFormat.plain(FileCard.preview(SoulsCard.preview(c.snippet)))).replaceAll('\n', ' '));
          return DecoratedBox(
            decoration: BoxDecoration(
              color: selected ? d.highlight : (state.pressed ? t.color('app-paper-3') : const Color(0x00000000)),
              border: Border(bottom: BorderSide(color: t.color('app-rule'), width: 1)),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 8, 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: selecting ? Padding(padding: const EdgeInsets.all(2), child: DialupCheck(checked: selected)) : (face?.call(24) ?? Avatar(people: c.people, size: 24)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Row(children: [
                          Flexible(
                            child: Text.rich(
                              TextSpan(children: [TextSpan(text: c.title), if (count.isNotEmpty) TextSpan(text: count)]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: pageText(t, 16, weight: unread ? 'bold' : 'regular', color: ink),
                            ),
                          ),
                          if (badge != null) ...[const SizedBox(width: 4), SizedBox.square(dimension: 14, child: FittedBox(child: badge))],
                          if (c.encrypted) ...[const SizedBox(width: 4), Semantics(label: 'Encrypted', child: AppIcon(Lucide.lock, size: 12, strokeWidth: 2.4, wash: false, color: soft))],
                        ]),
                      ),
                      if (c.pinned) ...[const SizedBox(width: 4), AppIcon(Lucide.pin, size: 13, color: soft)],
                      if (c.muted) ...[const SizedBox(width: 4), AppIcon(GhostIcons.bellOff, size: 13, color: soft)],
                      if (c.blocked) ...[const SizedBox(width: 4), AppIcon(Lucide.ban, size: 13, color: selected ? d.onHighlight : t.danger)],
                      if ((live ?? 0) > 0) ...[
                        const SizedBox(width: 6),
                        AppIcon(LucideMore.headphones, size: 12, strokeWidth: 2.4, wash: false, color: selected ? d.onHighlight : t.online),
                        const SizedBox(width: 2),
                        Text('$live', style: pageText(t, 12, weight: 'bold', color: selected ? d.onHighlight : t.online)),
                      ] else if (timed) ...[
                        const SizedBox(width: 6),
                        Text(listWhen(c.date), style: pageText(t, 12, color: soft)),
                      ],
                    ]),
                    // Its emoji in square pixels where the look draws them so (lib/art/pixel_emoji.dart).
                    Text.rich(
                      pixelEmojiOn(t) ? TextSpan(children: pixelEmojiSpans([words], pageText(t, 15, color: soft, height: 1.3))) : words,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: pageText(t, 15, color: soft, height: 1.3),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// A row under the search (Matt, 2026-11-20, of Discord's list of places under its search: "layout the mark all read and
/// the share feedback buttons to a icon list like shown in the screenshot under the searchbar"): its mark and its name
/// in the page's quieter ink, a wash under the pointer, and a count at its end where it has one. Quiet where it has
/// nothing to do.
class QuickRow extends StatelessWidget {
  const QuickRow({super.key, required this.icon, required this.label, this.onPress, this.count = 0});
  final LucideIcon icon;
  final String label;
  final VoidCallback? onPress;
  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final on = onPress != null;
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: count > 0 ? '$label, $count unread' : label,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: t.radius('md'),
        child: AnimatedContainer(
          duration: t.duration('glacier-duration-fast'),
          height: t.lenOf('2.75rem'),
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          decoration: BoxDecoration(
            color: on && (state.hovered || state.pressed) ? t.color('app-paper-2') : null,
            borderRadius: BorderRadius.circular(t.radius('md')),
          ),
          child: Opacity(
            opacity: on ? 1 : 0.5,
            child: Row(children: [
              AppIcon(icon, size: 20, color: t.color(state.hovered && on ? 'app-ink' : 'app-ink-2'), wash: false),
              SizedBox(width: t.space(3)),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color(state.hovered && on ? 'app-ink' : 'app-ink-2')))),
              if (count > 0)
                // A small circle, a short pill for 10 and up (Matt, 2026-11-20: "make the mark all read pill a small circle
                // it's tall and ugly right now"): its height is its own, where centring its number had stretched it to
                // the row's.
                Container(
                  key: const ValueKey('quick-row-count'),
                  height: 20,
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: t.danger, borderRadius: BorderRadius.circular(10)),
                  child: Text(count > 99 ? '99+' : '$count', style: t.textAt(11, weight: 'bold', height: 1.1, color: const Color(0xFFFFFFFF))),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
