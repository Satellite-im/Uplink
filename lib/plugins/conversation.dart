/// What a conversation's screen asks the plugins for, ready to put in place: the buttons for its header, the buttons
/// for its composer's row, the lines for a message's menu, what goes under a message, and the facts a message's words
/// are shown by ([words]: the Translate plugin's). lib/ui/thread.dart asks for each, with
/// `late final _plugins = ConversationPlugins(thread: widget.thread, people: () => _people, write: …)`.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../local_ai.dart' show AiLine;
import '../sms.dart';
import '../ui/common.dart';
import 'list.dart' show PluginEffects, SmsEffects;
import 'plugin.dart';
import 'registry.dart';

/// What a plugin's widget in a conversation can do there: write into the composer, and open another conversation.
class PluginThread extends InheritedWidget {
  const PluginThread({super.key, required this.write, this.open, required super.child});
  final void Function(String text) write;
  final void Function(int thread)? open;

  static PluginThread? of(BuildContext context) => context.getInheritedWidgetOfExactType<PluginThread>();

  @override
  bool updateShouldNotify(PluginThread old) => false;
}

/// One conversation's side of the plugins, made by its screen: what the registry gives for this conversation, as
/// widgets and menu lines.
class ConversationPlugins {
  ConversationPlugins({required this.thread, required this.people, this.write, this.open, PluginRegistry? registry, this.effects = const SmsEffects()}) : registry = registry ?? PluginRegistry.instance;

  final int thread;

  /// The conversation's other people, as the screen holds them now.
  final List<Person> Function() people;

  /// Writes into the message being written; null where the screen has no composer.
  final void Function(String text)? write;

  /// Opens another conversation by its number; null where the screen cannot.
  final void Function(int thread)? open;
  final PluginRegistry registry;
  final PluginEffects effects;

  /// The facts the header's buttons are asked with: the whole conversation's people, and its newest message's words.
  MessageFacts _conversation(Message? newest) {
    final all = people();
    if (newest != null) {
      final facts = MessageFacts.message(newest, thread: thread, people: all);
      // The conversation's facts, with its newest message's words: everyone in it, not that message's sender alone.
      return MessageFacts(thread: thread, senders: [for (final p in all) p.address], text: facts.text, contact: all.any((p) => p.name != null && p.name!.isNotEmpty), group: all.length > 1, date: facts.date, outgoing: facts.outgoing, encrypted: newest.encrypted, contactByName: true);
    }
    // With no newest message whose words they are is not known (outgoing stays null), so no plugin from another
    // developer sees an empty conversation.
    return MessageFacts(thread: thread, senders: [for (final p in all) p.address], text: '', contact: all.any((p) => p.name != null && p.name!.isNotEmpty), group: all.length > 1, contactByName: true);
  }

  /// What the classifiers said of each message, by its key ('header:' and the newest's key for the header's facts),
  /// with the switches and the words they said it of: a build asks each bubble's menu and what goes under it, and
  /// without this every bubble was classified again on every build, sixteen packs' phrases each (A.10.9).
  final _tagged = <String, (String, TagSet)>{};
  static const _kept = 500;

  /// The tags of the message kept under [key], classified again only when its words or the plugins' switches change.
  TagSet _tagsOf(String key, MessageFacts facts, PluginStore store) {
    final mark = '${registry.switches(store)}\u0000${facts.text}';
    final had = _tagged[key];
    if (had != null && had.$1 == mark) return had.$2;
    final tags = registry.classify(facts, store);
    _tagged
      ..remove(key)
      ..[key] = (mark, tags);
    // The oldest go first.
    while (_tagged.length > _kept) {
      _tagged.remove(_tagged.keys.first);
    }
    return tags;
  }

  /// The plugins' buttons for the header, to go before Call. [newest] is the conversation's newest message, where
  /// there is one: its words are what the conversation is known by.
  List<Widget> header(BuildContext context, {Message? newest}) {
    final store = AppStore(AppState.of(context));
    final facts = _conversation(newest);
    final tags = _tagsOf('header:${newest?.key ?? ''}', facts, store);
    final place = ConversationPlace(facts, tags, section: registry.sectionOf(facts, tags, store)?.id);
    return [
      for (final b in registry.actions(Slots.conversationHeader, place, store))
        IconTap(icon: b.action.icon, label: b.action.label, onPressed: () => runPluginAction(registry, b.plugin, b.action, _Host(this, b.plugin, context, facts, tags))),
    ];
  }

  /// The plugins' buttons for the composer's row, sized as Stickers and the microphone are. [text] is what is
  /// written so far.
  List<Widget> composer(BuildContext context, {String text = ''}) {
    final t = context.tokens;
    final store = AppStore(AppState.of(context));
    final facts = _conversation(null);
    return [
      for (final b in registry.actions(Slots.composer, ComposerPlace(thread: thread, senders: facts.senders, text: text), store))
        IconTap(icon: b.action.icon, label: b.action.label, size: 19, box: t.lenOf('2.25rem'), color: t.color('app-ink-2'), onPressed: () => runPluginAction(registry, b.plugin, b.action, _Host(this, b.plugin, context, facts, TagSet.none))),
    ];
  }

  /// What the plugins put under [m]'s bubble: a link's card, things to do with what it says.
  List<Widget> under(BuildContext context, Message m) {
    final store = AppStore(AppState.of(context));
    final facts = MessageFacts.message(m, thread: thread, people: people());
    final tags = _tagsOf(m.key, facts, store);
    return registry.widgets(Slots.underMessage, context, MessagePlace(facts, tags), store);
  }

  /// The facts the plugins' text rules are asked about [m] by ([TextRule]: a translation; Matt, 2026-11-17: "add a
  /// translate plugin which can automatically translate texts when detected from another language"), with [text], its
  /// words as its bubble shows them (without "(sent with Slam)"). Null where its words are not anyone's to change:
  /// the person's own, one still going or drawn before the phone has it, a notice, one that could not be opened.
  MessageFacts? words(Message m, String text) {
    if (m.outgoing || m.notice != null || m.kind == 'pending' || m.state == 'sending' || m.state == 'waiting' || text.trim().isEmpty) return null;
    return MessageFacts.message(m, thread: thread, people: people()).withText(text);
  }

  /// What the plugins put over the composer. [lastIn] is the newest message where it is from them (no reply yet).
  List<Widget> aboveComposer(BuildContext context, {String text = '', String? lastIn, String? lastOut, String title = '', int count = 0, Iterable<Message> newestFirst = const []}) {
    final store = AppStore(AppState.of(context));
    final all = people();
    final place = ComposerPlace(
      thread: thread,
      senders: [for (final p in all) p.address],
      text: text,
      lastIn: lastIn,
      lastOut: lastOut,
      title: title,
      contact: all.any((p) => p.name != null && p.name!.isNotEmpty),
      group: all.length > 1,
      count: count,
      recent: recentLines(newestFirst, all),
    );
    return registry.widgets(Slots.aboveComposer, context, place, store);
  }

  /// The plugins' lines for the menu a message's long press brings up.
  List<Choice> message(BuildContext context, Message m) {
    final store = AppStore(AppState.of(context));
    final facts = MessageFacts.message(m, thread: thread, people: people());
    final tags = _tagsOf(m.key, facts, store);
    return [
      for (final b in registry.actions(Slots.messageMenu, MessagePlace(facts, tags), store))
        Choice(b.action.label, b.action.icon, () => runPluginAction(registry, b.plugin, b.action, _Host(this, b.plugin, context, facts, tags)), danger: b.action.danger),
    ];
  }
}

/// The newest dozen of [newestFirst] that have words, oldest first, as the device's model reads them: whose each is
/// by [people]'s names.
List<AiLine> recentLines(Iterable<Message> newestFirst, List<Person> people) {
  String who(String address) {
    for (final p in people) {
      if (p.address == address && (p.name ?? '').trim().isNotEmpty) return p.name!.trim();
    }
    return people.length == 1 && (people.first.name ?? '').trim().isNotEmpty ? people.first.name!.trim() : address;
  }

  final out = <AiLine>[];
  for (final m in newestFirst) {
    if (out.length == 12) break;
    if (m.notice != null || m.body.trim().isEmpty) continue;
    out.add((mine: m.outgoing, who: m.outgoing ? '' : who(m.address), text: m.body.trim(), at: m.date.millisecondsSinceEpoch));
  }
  return out.reversed.toList();
}

/// A conversation's side of the contract, for one plugin's action.
class _Host implements PluginHost {
  _Host(this.owner, this.plugin, this.context, this.facts, this.tags);
  final ConversationPlugins owner;
  final GhostPlugin plugin;
  final BuildContext context;
  final MessageFacts facts;
  final TagSet tags;

  PluginStore get _store => AppStore(AppState.of(context));

  @override
  PluginPrefs get prefs => owner.registry.prefsOf(plugin, _store);

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
  void open(int thread) => owner.open?.call(thread);

  @override
  Future<void> markRead(int thread) => owner.effects.markRead(thread);

  /// Files this conversation; another's is the list's to file, which has its facts.
  @override
  void move(int thread, String? section) {
    if (thread == facts.thread && context.mounted) owner.registry.move(facts, tags, section, _store);
  }

  @override
  void write(String text) => owner.write?.call(text);

  /// A conversation shows no plugin pages, deletes nothing for a plugin, and is read again as it goes.
  @override
  void present(WidgetBuilder page) {}

  @override
  Future<void> deleteThread(int thread) async {}

  @override
  Future<void> reload() async {}
}
