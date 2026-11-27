/// What the list of conversations (lib/ui/conversations.dart) keeps of the plugins, so that the screen has a few
/// lines of them and no more: the conversations' tags (tag_store.dart), which section each is in, the chips, a
/// section's rows, what fills the list's slots, and the rules run on a message that has just come.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide_more.dart';
import '../sms.dart';
import '../ui/common.dart';
import '../ui/dialup/bevel.dart' show isBevelChrome;
import 'codes.dart' show signInCode;
import 'pack/format.dart' show packMayHoldCode;
import 'plugin.dart';
import 'registry.dart';
import 'tag_store.dart';
import 'ui.dart';
import '../kit/semantic_colors.dart';

export 'plugin.dart' show ListPlace;
export 'ui.dart' show PluginRow;

/// What the plugins' side does to the phone's messages: asked of Android in the app, counted in a test.
abstract interface class PluginEffects {
  Future<void> markRead(int thread);
  Future<void> mute(int thread, bool muted);
  Future<void> deleteThread(int thread);

  /// Takes away the notification Android has shown for [thread], and nothing else: a plugin from another developer's
  /// mute, one text at a time, never the conversation's lasting one (lib/plugins/pack).
  Future<void> cancelNotification(int thread);

  /// Whether a text that came into [thread] and is still unread has a sign-in code in it: one under newer words, which
  /// the list's row doesn't show, is still in Android's one notification for the conversation.
  Future<bool> codeWaiting(int thread);

  /// The words of every text that came into [thread] and is still unread, newest first; null where there may be more
  /// than were read. Marking a conversation read marks all of them read, and its one notification lists them all, so a
  /// plugin from another developer marks read or silences only where each is one it would itself (review, 2026-11-20:
  /// a receipt marked a bank's fraud alert under it read).
  Future<List<String>?> unreadIncoming(int thread);
}

/// The app's own effects: each asked of the phone through [Sms].
class SmsEffects implements PluginEffects {
  const SmsEffects();

  /// Android's notification for a conversation lists its newest unread texts (Notifier.kt, eight at most): these are
  /// read newest first, which is more than it can hold.
  static const int _looked = 20;

  @override
  Future<bool> codeWaiting(int thread) async {
    final newest = await Sms.instance.messages(thread, limit: _looked);
    // The wider rule a pack is held to as well as Notifier's: "G-482913 is your Google verification code." waits too.
    return newest.any((m) => !m.outgoing && !m.read && (signInCode(m.body) != null || packMayHoldCode(m.body)));
  }

  @override
  Future<List<String>?> unreadIncoming(int thread) async {
    final newest = await Sms.instance.messages(thread, limit: _looked);
    // As many as were asked for, the oldest of them unread too: there may be more under them.
    if (newest.length >= _looked && !newest.last.outgoing && !newest.last.read) return null;
    return [for (final m in newest) if (!m.outgoing && !m.read) m.body];
  }

  @override
  Future<void> markRead(int thread) => Sms.instance.markRead(thread);

  @override
  Future<void> mute(int thread, bool muted) => Sms.instance.threadFlag('muted', thread, muted);

  @override
  Future<void> deleteThread(int thread) => Sms.instance.deleteThreads([thread]);

  @override
  Future<void> cancelNotification(int thread) => Sms.instance.cancelNotification(thread);
}

/// The conversations that are not archived, by section: which section each one is in, the sections that have any
/// (in the order they are asked), how many each has, and which have something unread.
@immutable
class Sorted {
  const Sorted(this.at, this.sections, this.counts, this.unread, {this.others = 0, this.unreadCounts = const {}});
  static const none = Sorted({}, [], {}, {});

  final Map<int, PluginSection> at;
  final List<PluginSection> sections;
  final Map<String, int> counts;
  final Set<String> unread;

  /// How many unread conversations each section has: what its tab counts (Matt, 2026-11-14: "remove ... the badge
  /// count for codes that are already read").
  final Map<String, int> unreadCounts;

  /// How many conversations no section has: personal texts and everything else the filter's kinds leave alone.
  final int others;

  /// Whether [section] is one to show: it has a conversation, or its tab is there always.
  bool has(String? section) => section != null && (counts.containsKey(section) || sections.any((s) => s.id == section && s.section.alwaysNow));
}

/// The list's side of the plugins, one for the list's screen: it keeps each conversation's tags ([TagStore]), sorts
/// the conversations into sections, and does what the plugins' incoming rules ask as texts come.
class ListPlugins {
  ListPlugins({required this.changed, required this.open, required this.refresh, PluginRegistry? registry, this.effects = const SmsEffects()}) : registry = registry ?? PluginRegistry.instance {
    tags = TagStore(this.registry, onTagged: _arrived)..addListener(changed);
    this.registry.onError ??= logPluginError;
  }

  /// TagSet worked out between frames have changed which section some conversation is in: the list is drawn again.
  final VoidCallback changed;

  /// Opens a conversation of the list by its number.
  final void Function(int thread) open;

  /// Reads the list again: something was marked as read or muted.
  final Future<void> Function() refresh;
  final PluginRegistry registry;
  final PluginEffects effects;
  late final TagStore tags;

  PluginStore? _store;
  bool _gone = false;

  /// The person's choices, given each time the list is built.
  void bind(AppState app) {
    if (registry.isEmpty) return;
    final store = AppStore(app);
    _store = store;
    tags.bind(store);
  }

  /// Conversations that have just been read, the newest first, before they are drawn.
  void take(Iterable<Conversation> fresh) {
    // A computer can't ask its phone whether it may read its contacts: a name on any conversation from it says so
    // (MessageFacts.contactsReadable). Until then a plugin from another developer sees nothing here.
    if (Sms.remote && !MessageFacts.contactsReadable && fresh.any((c) => c.people.any((p) => (p.name ?? '').isNotEmpty))) MessageFacts.contactsReadable = true;
    if (!registry.isEmpty) tags.take(fresh);
  }

  /// The unread conversations with a sign-in code waiting under newer words, as the phone said when they came
  /// ([PluginEffects.codeWaiting]): a code, then "Never share this code" a moment later, whose one notification still
  /// holds the code. A plugin from another developer neither sorts nor draws them, nor marks them read nor takes that
  /// notification away, until they are read (review, 2026-11-20).
  final _codeWaiting = <int>{};
  int _codeVersion = 0;

  /// What each conversation was when the phone was last asked about it (its date and words): it is asked again only
  /// once something new has come, not every time the plugins' switches have everything classified again.
  final _codeLooked = <int, (int, String)>{};

  /// The conversations the phone is being asked about now, by what they were then: until it answers, a plugin from
  /// another developer judges each as if a code waited in it, so none is sorted into its tab and back out a moment
  /// later, the code in it the while (review, 2026-11-20).
  final _codeAsking = <int, (int, String)>{};

  /// [c]'s facts as the plugins judge it: [facts] with a waiting code marked where there is one, or might be.
  MessageFacts _judged(Conversation c, MessageFacts facts) => c.unread && (_codeWaiting.contains(c.id) || _codeAsking.containsKey(c.id)) ? facts.withCodeWaiting() : facts;

  void dispose() {
    _gone = true;
    tags.dispose();
  }

  // --- which section each conversation is in ------------------------------------------------------------------------

  List<Conversation>? _sortedOf;
  int _sortedTags = -1;
  int _sortedStamp = -1;
  int _sortedChats = 0;
  int _sortedCodes = -1;
  Sorted _sorted = Sorted.none;

  /// Each chat on another network sorted with the texts (Signal's, Telegram's), by its key (`network:chat`): the
  /// section it is in, null for none.
  Map<String, PluginSection?> _chatAt = const {};
  final _chatTags = <String, (String, TagSet)>{};

  /// What each chat on another network said of itself when last sorted, by its number ([chatThread]): so "Move to
  /// Spam" and "Not spam" file a chat as they file a conversation of texts.
  final _chatFacts = <int, MessageFacts>{};

  /// A number for a chat on another network as the plugins know a conversation: never one of Android's (which are
  /// above nothing) nor the bridge's own (just below).
  static int chatThread(String key) => -(0x10000000000) - (key.hashCode & 0x3fffffff);

  /// Sorts [all] into sections, and [chats] (Signal's and Telegram's, each its key, what it says of itself, whether it
  /// is unread) with them (Matt, 2026-11-16: "Filters should apply to all chats including telegram and signal make
  /// sure the filters are processing all chats"). Worked out again only when the list, the chats, some conversation's
  /// tags or a plugin's choices have changed.
  Sorted sort(List<Conversation>? all, {List<({String key, MessageFacts facts})> chats = const []}) {
    final store = _store;
    if (store == null || all == null) {
      _chatAt = const {};
      return _sorted = Sorted.none;
    }
    final chatsSeen = Object.hashAll([for (final c in chats) Object.hash(c.key, c.facts.text, c.facts.unread, c.facts.contact, c.facts.outgoing)]);
    if (identical(all, _sortedOf) && _sortedTags == tags.version && _sortedStamp == store.stamp && _sortedChats == chatsSeen && _sortedCodes == _codeVersion) return _sorted;
    _sortedOf = all;
    _sortedTags = tags.version;
    _sortedStamp = store.stamp;
    _sortedChats = chatsSeen;
    _sortedCodes = _codeVersion;
    final sections = registry.sections(store);
    // With no section there is nothing to sort, unless a plugin that is now off left conversations muted.
    if (sections.isEmpty && store.read(mutedKey) == null) return _sorted = Sorted.none;
    final at = <int, PluginSection>{};
    final counts = <String, int>{};
    final unread = <String>{};
    final unreadCounts = <String, int>{};
    final listed = <int>{};
    for (final c in all) {
      if (c.archived) continue;
      final facts = tags.facts(c.id);
      if (facts == null) continue;
      listed.add(c.id);
      // Read since a code was waiting in it: what the plugins may do to it is as its words say again.
      if (!c.unread) _codeWaiting.remove(c.id);
      final s = registry.sectionOf(_judged(c, facts), tags.of(c.id), store, among: sections);
      if (s == null) continue;
      at[c.id] = s;
      counts[s.id] = (counts[s.id] ?? 0) + 1;
      if (c.unread) {
        unread.add(s.id);
        unreadCounts[s.id] = (unreadCounts[s.id] ?? 0) + 1;
      }
    }
    _settle(at, listed);
    var others = all.where((c) => !c.archived && at[c.id] == null).length;
    // The other networks' chats, by what their newest message says, as a text is by its.
    final chatAt = <String, PluginSection?>{};
    // What a chat was tagged holds while its words and the plugins' choices do.
    final switches = registry.switches(store);
    _chatFacts.clear();
    for (final c in chats) {
      _chatFacts[c.facts.thread] = c.facts;
      final seen = '$switches\u0000${c.facts.text}';
      final had = _chatTags[c.key];
      final tagged = had != null && had.$1 == seen ? had.$2 : registry.classify(c.facts, store);
      _chatTags[c.key] = (seen, tagged);
      final s = registry.sectionOf(c.facts, tagged, store, among: sections);
      chatAt[c.key] = s;
      if (s == null) {
        others++;
        continue;
      }
      counts[s.id] = (counts[s.id] ?? 0) + 1;
      if (c.facts.unread) {
        unread.add(s.id);
        unreadCounts[s.id] = (unreadCounts[s.id] ?? 0) + 1;
      }
    }
    _chatAt = chatAt;
    return _sorted = Sorted(at, [for (final s in sections) if (counts.containsKey(s.id) || s.section.alwaysNow) s], counts, unread, others: others, unreadCounts: unreadCounts);
  }

  /// The section a chat on another network was sorted into ([sort]); null for none.
  PluginSection? sectionOfChat(String key) => _chatAt[key];

  /// Whether the chat [key] is shown in [section] as [pick] shows a conversation: a section's own, the hidden kinds'
  /// view, or the main list without what is taken out of it or hidden by the filter.
  bool showsChat(String key, String? section, {required bool searching}) {
    final s = _chatAt[key];
    if (section == hiddenView) return _hidden(s);
    if (section != null) return s?.id == section;
    if (searching) return true;
    return s == null ? othersShown() : !_leaves(s);
  }

  /// Whether the chat [key] is kept out of its network's own tab: a kind the filter hides, Spam, or a section that
  /// takes what it has out of the main list (Matt, 2026-11-16: "Fix the filtering a bit more this message got
  /// through"). A search finds it all the same.
  bool hidesChat(String key, {required bool searching}) {
    if (searching) return false;
    final s = _chatAt[key];
    return s != null && _leaves(s);
  }

  /// What the list shows in place of a section: every conversation of a kind the filter hides ("N hidden · Show").
  static const hiddenView = '*hidden';

  /// The filter: which kinds Messages shows. Set by the list from the person's choices ([kindShown]).
  bool Function(PluginSection kind) shown = (k) => !k.section.hidden;

  /// Whether the person shows [kind] in Messages: their choice, else the kind's own default.
  static bool kindShown(AppState app, PluginSection kind) => app.flag('filter_${kind.id}', fallback: !kind.section.hidden);

  /// Whether Messages shows the conversations no kind has (personal texts and the rest): the filter's "Personal &
  /// other" row (Matt, 2026-11-14: "when only selecting political messages I still see personal messages").
  bool Function() othersShown = () => true;

  /// The person's choice for [othersShown]: shown until they untick it.
  static bool othersShownFor(AppState app) => app.flag(othersKey, fallback: true);
  static const othersKey = 'filter_other';

  int get othersCount => _sorted.others;

  bool _hidden(PluginSection? s) => s == null ? !othersShown() : s.section.filter && !shown(s);

  bool _leaves(PluginSection s) => s.section.filter ? !shown(s) : s.section.leavesMain;

  /// The conversations of [all] that the chosen tab shows: a section's own, the conversations of hidden kinds
  /// ([hiddenView]), or the main list without the ones a section has taken out of it and the kinds the filter hides.
  /// A search from the main list looks through all of them.
  List<Conversation> pick(List<Conversation> all, String? section, {required bool searching}) {
    final at = _sorted.at;
    if (at.isEmpty && kinds.isEmpty) return section == null ? all : const [];
    if (section == hiddenView) return [for (final c in all) if (_hidden(at[c.id])) c];
    if (section != null) return [for (final c in all) if (at[c.id]?.id == section) c];
    if (searching) return all;
    return [for (final c in all) if (at[c.id] == null ? othersShown() : !_leaves(at[c.id]!)) c];
  }

  /// The kinds the filter can show or hide (each plugin's [ListSection.filter] sections that are on), and how many
  /// conversations each has.
  List<PluginSection> get kinds {
    final store = _store;
    if (store == null) return const [];
    // Those hidden as the app ships first (Spam with them), then those shown, each in its plugin's order.
    final all = [for (final s in registry.sections(store)) if (s.section.filter) s];
    return [...all.where((s) => s.section.hidden), ...all.where((s) => !s.section.hidden)];
  }

  int countOf(String kind) => _sorted.counts[kind] ?? 0;

  /// The conversations of [all] that are not archived, by what they were sorted as: each section that has any, then
  /// those no section has (Personal & other). For the header's buttons (the Cleaner).
  List<ListGroup> groups(List<Conversation> all) {
    final at = _sorted.at;
    final by = <String, List<int>>{};
    final others = <int>[];
    for (final c in all) {
      if (c.archived) continue;
      final s = at[c.id];
      if (s == null) {
        others.add(c.id);
      } else {
        (by[s.id] ??= []).add(c.id);
      }
    }
    return [
      for (final s in _sorted.sections)
        if (by[s.id] != null) ListGroup(id: s.id, label: s.section.label, icon: s.section.icon, threads: by[s.id]!),
      if (others.isNotEmpty) ListGroup(id: ListGroup.othersId, label: 'Personal & other', icon: LucideMore.messageCircle, threads: others),
    ];
  }

  /// How many conversations each section has, and which have something unread: for what the plugins put over the
  /// list.
  Map<String, int> get counts => _sorted.counts;
  Set<String> get unreadSections => _sorted.unread;

  /// How many conversations the filter is hiding from Messages now.
  int get hiddenCount => [for (final s in _sorted.sections) if (s.section.filter && !shown(s)) countOf(s.id)].fold(0, (a, b) => a + b) + (othersShown() ? 0 : _sorted.others);

  // --- what the screen draws ----------------------------------------------------------------------------------------

  /// The tabs under the search field, or null while no section has a conversation in it and none is there always. [onMenu] is asked for a
  /// tab's menu (a press with the other button, or a long one).
  Widget? tabs(String? chosen, ValueChanged<String?> onPick, {ValueChanged<String?>? onMenu, List<({String id, LucideIcon icon, String label, int count})> extra = const []}) {
    // The kinds are the filter's, not tabs.
    final s = _sorted;
    // A tab that is there always (Codes) is there from the first frame, before the list has been sorted: it came a
    // moment after, between Messages and Circles, and the toggle changed shape as the app opened (Matt, 2026-11-19:
    // "when I load the app on my phone for a split second the circles don't show up in the segmented toggle").
    final store = _store;
    final tabs = store == null
        ? [for (final t in s.sections) if (!t.section.filter) t]
        : [for (final t in registry.sections(store)) if (!t.section.filter && (t.section.alwaysNow || s.sections.any((x) => x.id == t.id))) t];
    if (tabs.isEmpty && extra.isEmpty) return null;
    return SectionTabs(sections: tabs, counts: s.unreadCounts, unread: s.unread, chosen: chosen, onPick: onPick, onMenu: onMenu, extra: extra);
  }

  /// What a tab is called: "Messages" for the main list, else its section's own name.
  String tabName(String? section) {
    if (section == null) return 'Messages';
    if (section == hiddenView) return 'Hidden';
    for (final s in _sorted.sections) {
      if (s.id == section) return s.section.label;
    }
    return 'Messages';
  }

  ConversationPlace _place(Conversation c) => ConversationPlace(MessageFacts.conversation(c), tags.of(c.id), section: _sorted.at[c.id]?.id);

  /// How [c]'s section draws it, with the host its actions are run with; null where it is drawn as the main list
  /// draws it.
  (RowLook, PluginHost)? look(BuildContext context, Conversation c) {
    final store = _store;
    final s = _sorted.at[c.id];
    if (store == null || s == null) return null;
    final look = registry.look(s, _judged(c, MessageFacts.conversation(c)), tags.of(c.id), store);
    return look == null ? null : (look, _Host(this, s.plugin, context));
  }

  /// The plugin [id]'s host, to run its actions with from a row that is not a conversation of texts (a Telegram chat
  /// in Codes); null where it is not on.
  PluginHost? hostFor(BuildContext context, String id) {
    final store = _store;
    if (store == null) return null;
    final plugin = registry.plugins.where((p) => p.id == id).firstOrNull;
    if (plugin == null || !registry.isOn(plugin, store)) return null;
    return _Host(this, plugin, context);
  }

  /// The lines the plugins add to the menu a conversation's long press brings up.
  List<Choice> menu(BuildContext context, Conversation c) {
    final store = _store;
    if (store == null) return const [];
    return [
      for (final b in registry.actions(Slots.conversationMenu, _place(c), store))
        Choice(b.action.label, b.action.icon, () => runPluginAction(registry, b.plugin, b.action, _Host(this, b.plugin, context)), danger: b.action.danger),
    ];
  }

  /// The buttons the plugins add to the list's header.
  List<Widget> header(BuildContext context, ListPlace place) {
    final store = _store;
    if (store == null) return const [];
    return [
      for (final b in registry.actions(Slots.listHeader, place, store))
        IconTap(
          icon: b.action.icon,
          label: b.action.label,
          size: b.action.quiet ? 17 : 20,
          // Quiet in the page's faint ink, except on Dial-Up's title bar, where that grey read 2.5:1 on navy and
          // looked disabled: there the bar's own ink, which the button reads inside the band.
          color: b.action.quiet && !isBevelChrome(context.tokens) ? context.tokens.color('app-ink-4') : null,
          onPressed: () => runPluginAction(registry, b.plugin, b.action, _Host(this, b.plugin, context)),
        ),
    ];
  }

  /// The plugins' actions for the list's header as (icon, label, press), for the rows under the search (Matt, 2026-11-20:
  /// "also the clean button is still in the header we should remove that"): the cleaner's Clean up among them.
  List<({LucideIcon icon, String label, VoidCallback press})> headerActions(BuildContext context, ListPlace place) {
    final store = _store;
    if (store == null) return const [];
    return [
      for (final b in registry.actions(Slots.listHeader, place, store)) (icon: b.action.icon, label: b.action.label, press: () => b.action.run(_Host(this, b.plugin, context))),
    ];
  }

  /// What the plugins put between the search field and the list.
  List<Widget> above(BuildContext context, ListPlace place) {
    final store = _store;
    return store == null ? const [] : registry.widgets(Slots.aboveList, context, place, store);
  }

  // --- a message that has just come ---------------------------------------------------------------------------------

  /// The conversations a plugin's rule has muted, kept in one choice as `thread:plugin:section`: a mute a plugin
  /// asked for lasts while the plugin is on and the conversation is in the section it was muted in.
  static const mutedKey = 'plugins_muted';

  Future<void> _queue = Future<void>.value();

  /// A conversation has been classified. Where it is unread, its newest message has just come (or came while the app
  /// was closed): the plugins' rules are asked what to do with it. On a computer the phone runs them; it is still asked
  /// whether a code waits there before a plugin from another developer sorts the conversation (review, 2026-11-20: a
  /// computer sorted a code's conversation into a pack's tab by the words that came after it, the phone not).
  void _arrived(MessageFacts facts, TagSet tags) {
    final store = _store;
    if (!facts.unread || store == null) return;
    final remote = Sms.remote;
    final asked = remote ? const <BoundIncoming>[] : registry.incoming(facts, tags, store);
    // Where a plugin from another developer would sort it or act on it, the phone is asked first whether a code waits
    // unread under these words, which they never show it.
    final section = registry.sectionOf(facts, tags, store);
    final others = asked.any((b) => b.plugin.source != PluginSource.builtIn) || (section != null && section.plugin.source != PluginSource.builtIn);
    if (asked.isEmpty && !others) return;
    if (others) {
      final seen = (facts.date?.millisecondsSinceEpoch ?? 0, facts.text);
      if (_codeLooked[facts.thread] != seen && _codeAsking[facts.thread] != seen) {
        _codeAsking[facts.thread] = seen;
        _codeVersion++;
      }
    }
    // After the frame that is being built, one conversation at a time.
    _queue = _queue.then((_) async {
      if (others) await _lookForCode(facts);
      if (!remote) await _apply(facts, tags, asked, store);
    }).catchError((_) {});
  }

  /// Asks the phone whether a sign-in code waits unread in [facts]' conversation, once for each state of it (its
  /// date and words), and keeps the answer in [_codeWaiting].
  Future<void> _lookForCode(MessageFacts facts) async {
    final thread = facts.thread;
    final seen = (facts.date?.millisecondsSinceEpoch ?? 0, facts.text);
    if (_gone) return;
    if (_codeLooked[thread] == seen) return _answered(thread, seen, changed: false);
    _codeLooked[thread] = seen;
    bool waiting;
    try {
      waiting = await effects.codeWaiting(thread);
    } catch (_) {
      // Not known is taken as waiting: a plugin from another developer leaves it alone until it is read, or until the
      // phone is asked again and answers (a computer's link to it was down).
      waiting = true;
      if (_codeLooked[thread] == seen) _codeLooked.remove(thread);
    }
    _answered(thread, seen, changed: waiting ? _codeWaiting.add(thread) : _codeWaiting.remove(thread));
  }

  /// The phone has answered for [thread] as it was ([seen]): no longer being asked, and drawn again where the answer
  /// changed how the plugins judge it.
  void _answered(int thread, (int, String) seen, {required bool changed}) {
    final asking = _codeAsking[thread] == seen && _codeAsking.remove(thread) != null;
    if (!changed && !asking) return;
    _codeVersion++;
    if (!_gone) this.changed();
  }

  /// Does what the incoming rules [asked] of a text that just came: marks read, mutes, moves. A plugin from another
  /// developer is held to more than a built-in is, as said at each step.
  Future<void> _apply(MessageFacts facts, TagSet tags, List<BoundIncoming> asked, PluginStore store) async {
    if (_gone) return;
    var reread = false;
    // The conversation's unread texts, asked of the phone once, and only for a plugin from another developer's mark
    // read or silence; null where they couldn't be read, or there may be more.
    List<String>? unread;
    var unreadAsked = false;
    for (final b in asked) {
      if (b.plugin.source != PluginSource.builtIn && (b.action is MarkRead || b.action is MuteNotification)) {
        // A plugin from another developer never marks read, nor silences, a conversation with a code waiting unread in it.
        if (_codeWaiting.contains(facts.thread)) continue;
        // Nor one with any other text unread in it that isn't one it would mark read or silence itself: Android marks
        // the whole conversation read and takes away its one notification, which lists them all, so a receipt it
        // was agreed to mark read took a bank's fraud alert under it with it (review, 2026-11-20).
        if (!unreadAsked) {
          unreadAsked = true;
          try {
            unread = await effects.unreadIncoming(facts.thread);
          } catch (_) {
            unread = null;
          }
          if (_gone) return;
        }
        if (unread == null || !_allItsOwn(facts, unread, b, store)) continue;
      }
      switch (b.action) {
        case MarkRead():
          await effects.markRead(facts.thread);
          reread = true;
        case MuteNotification():
          // A plugin from another developer silences one text at a time: the notification Android has shown for it is
          // taken away, and nothing else. Never the conversation's lasting mute, which Android obeys while the app is
          // closed, nor a plugins_muted entry, so the next text notifies unless it too is one the pack silences.
          if (b.plugin.source != PluginSource.builtIn) {
            await effects.cancelNotification(facts.thread);
            break;
          }
          if (facts.muted || _muted(store).any((m) => m.$1 == facts.thread)) break;
          await effects.mute(facts.thread, true);
          final section = registry.sectionOf(facts, tags, store)?.id ?? Filing.main;
          _setMuted(store, [..._muted(store), (facts.thread, b.plugin.id, section)]);
          reread = true;
        case MoveToSection(:final section):
          registry.move(facts, tags, section, store);
      }
    }
    if (reread && !_gone) await refresh();
  }

  /// Whether [b]'s plugin would ask [b]'s action for each of [unread] as it came, each judged as [facts]' newest words
  /// were: then marking the conversation read, or taking its notification away, does to each text what it was agreed
  /// to do as that text came ("Can mark Receipts texts as read as they come"), and to nothing else.
  bool _allItsOwn(MessageFacts facts, List<String> unread, BoundIncoming b, PluginStore store) {
    for (final words in unread) {
      final each = facts.withText(words);
      final asked = registry.incoming(each, registry.classify(each, store), store);
      if (!asked.any((x) => identical(x.plugin, b.plugin) && (b.action is MarkRead ? x.action is MarkRead : x.action is MuteNotification))) return false;
    }
    return true;
  }

  /// The conversations a plugin muted, each with the plugin's id and the section it was in then; kept in one choice
  /// as `thread:plugin:section`, commas between.
  List<(int, String, String)> _muted(PluginStore store) {
    final raw = store.read(mutedKey);
    if (raw == null) return const [];
    final out = <(int, String, String)>[];
    for (final part in raw.split(',')) {
      final bits = part.split(':');
      final thread = int.tryParse(bits.first);
      if (thread != null && bits.length == 3) out.add((thread, bits[1], bits[2]));
    }
    return out;
  }

  void _setMuted(PluginStore store, List<(int, String, String)> muted) => store.write(mutedKey, [for (final m in muted) '${m.$1}:${m.$2}:${m.$3}'].join(','));

  /// A conversation a plugin muted is given its notifications back once that plugin is off or the conversation has
  /// left the section it was muted in ("Not spam"). [listed] are the conversations the list holds that are not
  /// archived: one that is archived, or not read yet (an older one, on a phone with thousands), is left as it is.
  void _settle(Map<int, PluginSection> at, Set<int> listed) {
    final store = _store;
    if (store == null || Sms.remote) return;
    final muted = _muted(store);
    if (muted.isEmpty) return;
    final on = {for (final p in registry.plugins) if (registry.isOn(p, store)) p.id};
    final undo = [
      for (final m in muted)
        if (listed.contains(m.$1) && (!on.contains(m.$2) || (at[m.$1]?.id ?? Filing.main) != m.$3)) m,
    ];
    if (undo.isEmpty) return;
    _queue = _queue.then((_) async {
      if (_gone) return;
      _setMuted(store, [for (final m in _muted(store)) if (!undo.contains(m)) m]);
      for (final m in undo) {
        await effects.mute(m.$1, false);
      }
      if (!_gone) await refresh();
    }).catchError((_) {});
  }
}

/// The list's side of the contract, for one plugin's action.
class _Host implements PluginHost {
  _Host(this.list, this.plugin, this.context);
  final ListPlugins list;
  final GhostPlugin plugin;
  final BuildContext context;

  @override
  PluginPrefs get prefs => list.registry.prefsOf(plugin, list._store!);

  @override
  void say(String words) {
    if (context.mounted) toast(context, words);
  }

  @override
  void copy(String text, {String? say}) {
    Clipboard.setData(ClipboardData(text: text));
    if (say != null) this.say(say);
  }

  @override
  void open(int thread) => list.open(thread);

  @override
  Future<void> markRead(int thread) async {
    await list.effects.markRead(thread);
    if (!list._gone) await list.refresh();
  }

  @override
  void move(int thread, String? section) {
    final facts = list.tags.facts(thread);
    if (facts != null) {
      list.registry.move(facts, list.tags.of(thread), section, list._store!);
      return;
    }
    // A chat on another network.
    final chat = list._chatFacts[thread];
    if (chat == null) return;
    final key = list._chatAt.keys.firstWhere((k) => ListPlugins.chatThread(k) == thread, orElse: () => '');
    final tags = list._chatTags[key]?.$2 ?? TagSet.none;
    list.registry.move(chat, tags, section, list._store!);
  }

  /// The list has nothing being written.
  @override
  void write(String text) {}

  @override
  void present(WidgetBuilder page) {
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: context.tokens.sheetScrim,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (context, _, _) => page(context),
      transitionsBuilder: (context, a, _, child) => SlideTransition(
        position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ));
  }

  @override
  Future<void> deleteThread(int thread) => list.effects.deleteThread(thread);

  @override
  Future<void> reload() async {
    if (!list._gone) await list.refresh();
  }
}
