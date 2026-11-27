/// Trying a pack without real texts (Matt, 2026-11-20: "a developer setting for users to be able to manually upload
/// plugins for development testing"): one text run through it as the app would run it, the lints a developer and the
/// reviewer read, and the sample texts every pack is tried on.
library;

import '../plugin.dart';
import '../registry.dart';
import 'format.dart';
import 'manifest.dart';
import 'pack_plugin.dart';

/// What [tryPack] found for one text.
class PackTrial {
  const PackTrial({required this.seen, this.tags = const {}, this.section, this.row, this.actions = const {}, this.incoming = const [], this.shadowedBy, required this.took});
  final bool seen;                          // packSees held for these facts
  final Map<String, String?> tags;          // the pack's own tag names (no x<id>. prefix) → detail
  final String? section;                    // an own section key, or null
  final RowLook? row;
  final Map<String, List<String>> actions;  // slot name → labels offered there ('row' for end, word, tap)
  final List<String> incoming;              // 'markread' and/or 'mute' that would be asked for

  /// Where a built-in that is on in [tryPack]'s `beside` takes these facts first (A.8.3), as
  /// `<plugin name> › <section label>` ('Kinds of text › Payment reminders'); null where none does, or where no `store`
  /// was given.
  final String? shadowedBy;
  final Duration took;
}

/// [pack] run on one text as the app would run it: a fresh PackPlugin in a registry of its own, switched on, with
/// [prefs] over the settings' defaults (every toggle on where [switchesOn]); the facts are thread 1, from [from], not a
/// contact, not a group, not encrypted, `outgoing: false`, one sender, unread, the text as given (so A.9 holds).
/// [beside] (default PluginRegistry.instance) with the person's choices in [store] says what would take it first.
PackTrial tryPack(PluginPack pack, {required String text, String from = '72975', Map<String, String> prefs = const {}, bool switchesOn = false, PluginRegistry? beside, PluginStore? store}) {
  late final PluginRegistry registry;
  // Its own registry hears what it throws, and its clock is the real one: one text, classified once, is never paused.
  final plugin = PackPlugin(pack, source: PluginSource.dev, onError: (p, e) => registry.failed(p, e));
  registry = PluginRegistry([plugin]);
  final own = 'plugin_${plugin.id}_';
  final choices = MemoryStore({
    PluginRegistry.switchKey(plugin): 'on',
    if (switchesOn)
      for (final s in pack.settings)
        if (s.type == 'toggle' && s.key != null) '$own${s.key}': 'on',
    for (final e in prefs.entries) '$own${e.key}': e.value,
  });
  final facts = MessageFacts(thread: 1, senders: [from], text: text, contact: false, outgoing: false, unread: true);
  final watch = Stopwatch()..start();
  final tags = registry.classify(facts, choices);
  watch.stop();
  final prefix = tagNameOf(pack.id, '');
  final placed = registry.sectionOf(facts, tags, choices);
  final row = placed == null ? null : registry.look(placed, facts, tags, choices);
  List<String> labels<P>(ActionSlot<P> slot, P place) => [for (final b in registry.actions(slot, place, choices)) b.action.label];
  final place = ConversationPlace(facts, tags, section: placed?.id);
  final actions = <String, List<String>>{
    'row': [for (final a in [row?.end, row?.word, row?.tap]) if (a != null) a.label],
    'list.conversation.menu': labels(Slots.conversationMenu, place),
    'conversation.header': labels(Slots.conversationHeader, place),
    'conversation.message.menu': labels(Slots.messageMenu, MessagePlace(facts, tags)),
  }..removeWhere((_, v) => v.isEmpty);
  final asked = registry.incoming(facts, tags, choices);
  return PackTrial(
    seen: packSees(facts),
    tags: {for (final n in tags.names) if (n.startsWith(prefix)) n.substring(prefix.length): tags.detail(n)},
    section: placed?.id.substring(sectionIdOf(pack.id, '').length),
    row: row,
    actions: actions,
    incoming: [
      for (final b in asked)
        switch (b.action) {
          MarkRead() => 'markread',
          MuteNotification() => 'mute',
          MoveToSection() => 'move',
        },
    ],
    shadowedBy: placed == null || store == null ? null : _shadowedBy(facts, beside ?? PluginRegistry.instance, store),
    took: watch.elapsed,
  );
}

/// The first of the app's own sections that is on in [beside] and takes [facts], as `<plugin> › <section>`: the
/// built-ins are asked before any pack (A.8.3). Only they are asked here, in a registry of their own, so trying a pack
/// never runs another pack, nor the same one's installed copy.
String? _shadowedBy(MessageFacts facts, PluginRegistry beside, PluginStore store) {
  try {
    final builtIns = PluginRegistry([for (final p in beside.plugins) if (p.source == PluginSource.builtIn) p]);
    final tags = builtIns.classify(facts, store);
    for (final s in builtIns.sections(store)) {
      if (s.section.takes(facts, tags, builtIns.prefsOf(s.plugin, store))) return '${s.plugin.name} › ${s.section.label}';
    }
  } catch (_) {
    // A built-in that throws takes nothing here, as the registry would leave it out.
  }
  return null;
}

/// One of the texts every pack is tried on ("Try the samples").
class PackSample {
  const PackSample(this.id, this.text, {this.from = '72975'});
  final String id, text, from;
}

/// A.15's corpus, exactly: bills, receipts and parcels, and texts no such pack should touch (a sign-in code, a friend's
/// question, an appointment, a prize scam, a political text).
const List<PackSample> packSamples = [
  PackSample('s01', 'Your bill is ready. Amount due: \$45.20 by 3 Dec. Pay at example.com/pay'),
  PackSample('s02', 'EnergyCo: your statement is ready to view online.'),
  PackSample('s03', 'Thank you for your payment of £30.00. It may take 2 days to show.'),
  PackSample('s04', 'Payment of €12,50 received. Ref 88213.'),
  PackSample('s05', 'Reminder: minimum payment due on your card.'),
  PackSample('s06', 'Your council tax is due next week.'),
  PackSample('s07', 'Your parcel has shipped! Tracking number: 1Z999AA10123456784'),
  PackSample('s08', 'Your order is out for delivery today.'),
  PackSample('s09', 'We tried to deliver your parcel. Missed delivery, rebook at example.com'),
  PackSample('s10', 'Good news, your order has been dispatched.'),
  PackSample('s11', 'Your new blue parcel has shipped. Tracking no. JD014600006295117'),
  PackSample('s12', 'Your code is 482913. Don’t share it with anyone.'),
  PackSample('s13', 'Are we still on for dinner on Friday?'),
  PackSample('s14', 'Your appointment is on March 5th at 3pm. Reply C to cancel.'),
  PackSample('s15', 'Congratulations! You have won a \$500 gift card. Claim now: http://prize.example/win'),
  PackSample('s16', 'Vote YES on Measure 12 this Tuesday. Paid for by Friends of the Park.'),
];

// Words that are in nearly every text: a phrase of one of these alone tags almost everything.
const Set<String> _commonWords = {'the', 'you', 'your', 'and', 'for', 'are', 'our', 'this', 'that', 'with', 'have', 'will', 'from', 'now', 'get', 'new', 'can', 'any', 'all', 'one', 'out', 'day', 'see', 'use', 'hi', 'hello', 'thanks', 'ok', 'yes', 'no'};
final RegExp _run = RegExp(r'[\p{L}\p{N}]+', unicode: true);

/// What a developer and the reviewer should look at again: warnings only (broad_phrase, description_link, unused_tag,
/// opens_links).
List<PackIssue> lintPack(PluginPack pack) {
  final out = <PackIssue>[];
  void warn(String code, String path, String words) => out.add(PackIssue(code, path, '$path: $words', severity: PackSeverity.warning));
  final rules = pack.rules;
  for (var i = 0; i < rules.tags.length; i++) {
    final rule = rules.tags[i];
    for (final (key, phrases) in [('any', rule.any), ('all', rule.all)]) {
      for (var j = 0; j < phrases.length; j++) {
        final p = phrases[j];
        if (p.hasToken) continue;
        final runs = [for (final m in _run.allMatches(p.source)) m[0]!];
        if (runs.length == 1 && (runs.single.length <= 4 || _commonWords.contains(runs.single.toLowerCase()))) {
          warn('broad_phrase', 'rules.tags[$i].$key[$j]', '"${p.source}" is one short or common word: it will match a great many texts.');
        }
      }
    }
  }
  final description = pack.description.toLowerCase();
  if (description.contains('http://') || description.contains('https://') || description.contains('www.')) {
    warn('description_link', 'description', 'holds a web address: put your page in "support", and a page a button opens in "links".');
  }
  final used = <String>{};
  // A tag nothing asks for: [used] gathers every tag a condition or a template names, and each tag rule's is held
  // against it.
  void uses(PackWhen? w) {
    if (w == null) return;
    used
      ..addAll(w.tagged)
      ..addAll(w.untagged);
  }

  void inTemplate(String? t) {
    if (t == null) return;
    for (final m in RegExp(r'\{tag:([a-z][a-z0-9]{0,15})\}').allMatches(t)) {
      used.add(m[1]!);
    }
  }

  for (final r in rules.tags) {
    uses(r.when);
  }
  for (final s in rules.sections) {
    uses(s.takes);
    inTemplate(s.row?.value);
    inTemplate(s.row?.caption);
  }
  for (final a in rules.actions) {
    uses(a.when);
    if (a.verb == 'copy') inTemplate(a.text);
  }
  for (final r in rules.incoming) {
    uses(r.when);
  }
  final told = <String>{};
  for (var i = 0; i < rules.tags.length; i++) {
    final tag = rules.tags[i].tag;
    if (used.contains(tag) || !told.add(tag)) continue;
    warn('unused_tag', 'rules.tags[$i].tag', '"$tag" is given, and nothing asks for it: no section takes it, no row shows it, and no button or rule asks about it.');
  }
  if (pack.links.isNotEmpty && rules.actions.any((a) => a.verb == 'link')) {
    warn('opens_links', 'links[0]', 'Opens ${pack.links.first} when pressed: check it is the developer\'s own page.');
  }
  return out;
}
