/// A pack as a plugin: its rules compiled once into the classifier, sections, buttons, incoming rule and settings the
/// app already asks its own plugins for (plugin.dart), so the registry, the list and the screens take a pack as they
/// take a built-in. What it may see and do is bounded by format.dart's packSees and packMayAct and by its host
/// (gated_host.dart), never by what it says of itself; and a pack that slows the app down is paused.
library;

import 'dart:typed_data';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../sms.dart';
import '../plugin.dart';
import '../registry.dart';
import 'format.dart';
import 'gated_host.dart';
import 'manifest.dart';
import 'phrases.dart';
import 'review.dart';

/// One checked pack as the registry holds it. Everything it gives is worked out from the pack's rules; nothing of the
/// pack's runs as code.
class PackPlugin extends GhostPlugin {
  PackPlugin(this.pack, {required this.source, this.approval, void Function(PackPlugin plugin, Object error)? onError, this.onTrouble, Future<bool> Function(String url)? openLink, DateTime Function()? now, bool paused = false})
      : onError = onError ?? _toTheApp,
        _openLink = openLink,
        _now = now ?? DateTime.now,
        _paused = paused {
    // Every list is made here, once: the registry reads a plugin's lists when it takes it and matches plugins with
    // identical(), so each getter hands back these same instances.
    _settingsByKey = {for (final s in pack.settings) if (s.key != null) s.key!: s};
    _actionsById = {for (final a in pack.rules.actions) a.id: a};
    _ownTabs = {for (final s in pack.rules.sections) if (s.kind == 'tab') sectionIdOf(pack.id, s.key)};
    _tuned = List.unmodifiable(<TunedClassifier>[_classify]);
    _sections = List.unmodifiable([for (final s in pack.rules.sections) _section(s)]);
    final named = {for (final a in pack.rules.actions) ...a.slots};
    _slots = List.unmodifiable(<SlotFill>[
      if (named.contains('list.conversation.menu')) Slots.conversationMenu.fill((place, prefs) => _offered('list.conversation.menu', place.facts, place.tags, prefs, section: place.section, hasSection: true)),
      if (named.contains('conversation.header')) Slots.conversationHeader.fill((place, prefs) => _offered('conversation.header', place.facts, place.tags, prefs, section: place.section, hasSection: true)),
      if (named.contains('conversation.message.menu')) Slots.messageMenu.fill((place, prefs) => _offered('conversation.message.menu', place.facts, place.tags, prefs, hasSection: false)),
    ]);
    _incoming = List.unmodifiable(pack.rules.incoming.isEmpty ? const <IncomingRule>[] : <IncomingRule>[_incomingRule]);
    _settings = List.unmodifiable([for (final s in pack.settings) _setting(s)]);
    _adds = List.unmodifiable(packAdds(pack));
    _reaches = List.unmodifiable(packReaches(pack));
  }

  static void _toTheApp(PackPlugin plugin, Object error) => PluginRegistry.instance.failed(plugin, error);

  final PluginPack pack;
  @override
  final PluginSource source;                                   // reviewed or dev, never builtIn
  final PackApproval? approval;                                // non-null for a reviewed pack

  /// Where what it throws, and what its host refuses, is told: the registry it is in. InstalledPlugins and tryPack pass
  /// `(p, e) => registry.failed(p, e)`; PluginRegistry.instance.failed where none is given.
  final void Function(PackPlugin plugin, Object error) onError;

  /// What happened to it, told to its owner: 'paused' once, `'refused <verb>'` each time. InstalledPlugins keeps only
  /// the pause (a refusal reaches it as an error, through [onError]). Called synchronously from whatever is asking it,
  /// often a build, so its listener only records (B.9.2).
  final void Function(PackPlugin plugin, String what)? onTrouble;

  final Future<bool> Function(String url)? _openLink;
  final DateTime Function() _now;

  /// The clock its time is measured by, and its host's limits (gated_host.dart): the injected one in a test.
  DateTime Function() get clock => _now;

  late final Map<String, PackSetting> _settingsByKey;
  late final Map<String, PackAction> _actionsById;
  late final Set<String> _ownTabs;
  late final List<TunedClassifier> _tuned;
  late final List<ListSection> _sections;
  late final List<SlotFill> _slots;
  late final List<IncomingRule> _incoming;
  late final List<PluginSetting> _settings;
  late final List<String> _adds;
  late final List<PluginReach> _reaches;

  /// The section ids of its own tabs: the only sections its `move` may file a conversation in (gated_host.dart).
  Set<String> get ownTabs => _ownTabs;

  // --- pausing (A.10.9) -------------------------------------------------------------------------------------------

  bool _paused;
  var _compiled = false;
  final _strikes = <DateTime>[];
  DateTime? _second;
  var _inSecond = Duration.zero;
  var _runsInSecond = 0;
  var _secondStruck = false;

  /// It was slowing the app down: it gives nothing until [unpause].
  bool get paused => _paused;

  /// Lets it run again, its strikes forgotten. Its owner keeps the pause itself (InstalledPlugins.unpause).
  void unpause() {
    _paused = false;
    _strikes.clear();
    _second = null;
    _inSecond = Duration.zero;
    _runsInSecond = 0;
    _secondStruck = false;
  }

  // Every run's time goes into the second it is in; a second whose runs pass the budget, and took the pack
  // [PackLimits.slowOnAverage] or more each on average, is a strike, once. The list asks every pack about every
  // conversation it holds at once whenever a switch, a setting or the plugins themselves change (TagStore.bind), so a
  // pack that takes some 40 µs a text was charged 120 ms for 3,000 conversations in one second, a strike at each change
  // and a pause after five; its pause and its Turn it back on were changes too, a strike to every other heavy pack
  // (review, 2026-11-20). A pack that is slow on each text is caught as before. And a second it spent more than half
  // of classifying ([PackLimits.slowInASecondAlways]) is a strike whatever the average, so a pack just under a
  // millisecond a text can't hold the app for seconds at every change and never be paused (review, 2026-11-20: 0.9 ms
  // a text over 3,000 conversations was 2.7 s at each, and no strike ever).
  void _count(DateTime start, Duration took) {
    final second = _second;
    if (second == null || start.difference(second) >= const Duration(seconds: 1)) {
      _second = start;
      _inSecond = Duration.zero;
      _runsInSecond = 0;
      _secondStruck = false;
    }
    _inSecond += took;
    _runsInSecond++;
    if (!_secondStruck && _inSecond > PackLimits.slowInASecond && (_inSecond >= PackLimits.slowOnAverage * _runsInSecond || _inSecond > PackLimits.slowInASecondAlways)) {
      _secondStruck = true;
      _strike(start);
    }
  }

  // A strike at [at]: [PackLimits.strikes] of them within [PackLimits.strikeWindow] pause it, and its owner is told
  // once.
  void _strike(DateTime at) {
    _strikes
      ..add(at)
      ..removeWhere((s) => at.difference(s) >= PackLimits.strikeWindow);
    if (_strikes.length >= PackLimits.strikes && !_paused) {
      _paused = true;
      onTrouble?.call(this, 'paused');
    }
  }

  // --- what it is -------------------------------------------------------------------------------------------------

  @override
  String get id => pack.registryId;
  @override
  String get name => pack.name;
  @override
  String get description => pack.description;
  @override
  LucideIcon get icon => Lucide.all[pack.symbol] ?? Lucide.puzzle;

  /// Nothing from outside is on until it is added.
  @override
  bool get onByDefault => false;
  @override
  List<TunedClassifier> get tuned => _tuned;                   // one classifier: A.8.2
  @override
  List<ListSection> get sections => _sections;                 // A.8.3, A.8.4
  @override
  List<SlotFill> get slots => _slots;                          // A.8.5: Slots.conversationMenu, conversationHeader, messageMenu
  @override
  List<IncomingRule> get incoming => _incoming;                // A.8.6: one rule
  @override
  List<PluginSetting> get settings => _settings;               // A.7
  @override
  String get hue => pack.hue;
  @override
  PluginShelf get shelf => PluginShelf.values.byName(pack.shelf);
  @override
  String get tagline => pack.tagline;
  @override
  List<String> get adds => _adds;
  @override
  List<PluginReach> get reaches => _reaches;
  @override
  Set<PluginScope> get scopes => const {PluginScope.device};
  @override
  String? get developer => pack.developer;
  @override
  String? get version => pack.version;
  @override
  Uint8List? get iconPng => pack.icon;
  @override
  List<String> get labels => pack.labels;

  @override
  String toString() => 'PackPlugin($id ${pack.version}, ${source.name})';

  // --- conditions (A.8.1) -----------------------------------------------------------------------------------------

  /// Whether [w] holds for [facts]: [has] says which of its own tags are there (the tags so far, in a tag rule);
  /// [hasSection] and [section] are the place's, for a button's condition.
  bool _holds(PackWhen? w, MessageFacts facts, PluginPrefs prefs, bool Function(String own) has, {String? section, bool hasSection = false}) {
    if (w == null) return true;
    // A sender with nothing to compare is no one's: neither the '' an entry of "(-)" compares as, nor any other.
    if (w.from.isNotEmpty && !facts.senders.any((s) => packSenderOf(s).isNotEmpty && w.from.contains(packSenderOf(s)))) return false;
    for (final t in w.tagged) {
      if (!has(t)) return false;
    }
    for (final t in w.untagged) {
      if (has(t)) return false;
    }
    final setting = w.setting;
    if (setting != null && !_settingHolds(setting, w.settingIs, prefs)) return false;
    final where = w.section;
    if (where != null) {
      // A message's menu is in no section.
      if (!hasSection) return false;
      if (section != (where == 'main' ? null : sectionIdOf(pack.id, where))) return false;
    }
    return true;
  }

  /// A switch named alone must be on; with [value], a switch must be that ('on' or 'off') and a choice must be that
  /// option. A setting never chosen counts as the pack's default.
  bool _settingHolds(String key, String? value, PluginPrefs prefs) {
    final s = _settingsByKey[key];
    if (s == null) return false;
    if (s.type == 'toggle') {
      final on = prefs.flag(key, fallback: s.fallback);
      return value == null ? on : (value == 'on') == on;
    }
    return (prefs.get(key) ?? s.choice) == value;
  }

  /// Whether one of its own tags, by the name the pack gives it, is among [tags], where it is kept under the pack's
  /// id.
  bool Function(String own) _in(TagSet tags) => (own) => tags.has(tagNameOf(pack.id, own));

  // --- tags (A.8.2) -----------------------------------------------------------------------------------------------

  /// Its one classifier: the tags its rules give [facts], and the time that took, counted toward a pause.
  List<Tag> _classify(MessageFacts facts, PluginPrefs prefs) {
    if (_paused || !packSees(facts)) return const [];
    final text = PreparedText(facts.text);
    final t0 = _now();
    final got = _tag(text, facts, prefs);
    final took = _now().difference(t0);
    // The first run compiles its phrases (a RegExp compiles when first used), so it is never held against it.
    if (_compiled) {
      _count(t0, took);
      if (took >= PackLimits.slow && !_paused) {
        // Slow once may be a garbage collection or a busy phone; slow again at once, on the same words, is the pack.
        final t1 = _now();
        _tag(text, facts, prefs);
        final again = _now().difference(t1);
        _count(t1, again);
        if (again >= PackLimits.slow) _strike(t0);
      }
    }
    _compiled = true;
    if (_paused) return const [];
    return [for (final e in got.entries) Tag(tagNameOf(pack.id, e.key), e.value)];
  }

  /// The tag rules in order, each seeing the tags of those before it: its own tag names to their details. A phrase is
  /// looked for once at most, and no further once `atLeast` is reached. A tag given twice keeps its first detail.
  Map<String, String?> _tag(PreparedText text, MessageFacts facts, PluginPrefs prefs) {
    final got = <String, String?>{};
    for (final rule in pack.rules.tags) {
      if (!_holds(rule.when, facts, prefs, got.containsKey)) continue;
      final words = rule.wordsFrom == null ? const <Phrase>[] : _wordsOf(rule.wordsFrom!, prefs);
      final a = words.isEmpty ? rule.any : [...rule.any, ...words];
      final hits = List<PhraseHit?>.filled(a.length, null);
      final tried = List<bool>.filled(a.length, false);
      PhraseHit? hit(int i) {
        if (!tried[i]) {
          tried[i] = true;
          hits[i] = a[i].find(text);
        }
        return hits[i];
      }

      if (rule.anyGiven || rule.wordsFrom != null) {
        var n = 0;
        for (var i = 0; i < a.length && n < rule.atLeast; i++) {
          if (hit(i) != null) n++;
        }
        if (n < rule.atLeast) continue;
      }
      if (rule.all.any((p) => !p.matches(text))) continue;
      if (rule.none.any((p) => p.matches(text))) continue;
      String? detail = rule.detail;
      if (rule.detailFrom == 'token') {
        for (var i = 0; i < a.length; i++) {
          if (!a[i].hasToken) continue;
          final h = hit(i);
          if (h != null) {
            detail = h.token;
            break;
          }
        }
      } else if (rule.detailFrom == 'match') {
        for (var i = 0; i < a.length; i++) {
          final h = hit(i);
          if (h != null) {
            detail = h.match;
            break;
          }
        }
      }
      detail = _tidy(detail);
      if (!got.containsKey(rule.tag)) {
        got[rule.tag] = detail;
      } else if (got[rule.tag] == null && detail != null) {
        got[rule.tag] = detail;
      }
    }
    return got;
  }

  // A detail as a tag keeps it: trimmed, none where empty, and no longer than the format lets it be.
  static String? _tidy(String? detail) {
    if (detail == null) return null;
    final t = detail.trim();
    if (t.isEmpty) return null;
    return t.length > PackLimits.detail ? _cut(t, PackLimits.detail) : t;
  }

  /// The person's own words for [key], each a literal phrase (A.10.10), kept while the setting's words stay.
  final _words = <String, (String, List<Phrase>)>{};

  /// The phrases of the words setting [key], compiled again only when its words change.
  List<Phrase> _wordsOf(String key, PluginPrefs prefs) {
    final raw = prefs.get(key) ?? '';
    final had = _words[key];
    if (had != null && had.$1 == raw) return had.$2;
    final out = <Phrase>[];
    for (final w in wordsOf(prefs, key).take(PackLimits.personWords)) {
      try {
        out.add(Phrase.literal(_cut(w, PackLimits.personWord).trim()));
      } on PhraseError {
        // One letter, a character a phrase can't hold: left out, as the docs say, with nothing to tell.
      }
    }
    _words[key] = (raw, List.unmodifiable(out));
    return _words[key]!.$2;
  }

  // --- sections and rows (A.8.3, A.8.4) ----------------------------------------------------------------------------

  /// A pack's section as the list's: it takes nothing while the pack is paused, nor a conversation a pack may not act
  /// on.
  ListSection _section(PackSection s) {
    final id = sectionIdOf(pack.id, s.key);
    return ListSection(
      id: id,
      label: s.label,
      // The icon's name was checked against Lucide.all when the pack was.
      icon: Lucide.all[s.icon]!,
      takes: (facts, tags, prefs) => packMayAct(facts) && !_paused && _holds(s.takes, facts, prefs, _in(tags)),
      leavesMain: s.leavesMain,
      filter: s.kind == 'filter',
      hidden: false,
      row: s.row == null ? null : (facts, tags, prefs) => _row(s.row!, id, facts, tags, prefs),
    );
  }

  /// How a conversation's row looks in [section]; null, and the list draws its own, where the pack gives nothing.
  RowLook? _row(PackRow r, String section, MessageFacts facts, TagSet tags, PluginPrefs prefs) {
    if (_paused || !packMayAct(facts)) return null;
    final value = r.value == null ? null : _expand(r.value!, tags, 24, ellipsis: true);
    final caption = r.caption == null ? null : _expand(r.caption!, tags, 60, ellipsis: true);
    final face = r.faceName == null || r.faceColor == null ? null : RowFace(name: r.faceName!, color: r.faceColor!);
    PluginAction? button(String? id) {
      final a = id == null ? null : _actionsById[id];
      return a == null ? null : _action(a, facts, tags, prefs, section: section, hasSection: true);
    }

    final end = button(r.end), word = button(r.word), tap = button(r.tap);
    if (value == null && caption == null && face == null && end == null && word == null && tap == null) return null;
    return RowLook(value: value, caption: caption, face: face, end: end, word: word, tap: tap);
  }

  /// [template] with each `{tag:<name>}` its tag's detail (A.8.7); null where one has none, and the field is left out.
  String? _expand(String template, TagSet tags, int limit, {bool ellipsis = false}) {
    final out = StringBuffer();
    var i = 0;
    while (i < template.length) {
      final c = template[i];
      if ((c == '{' || c == '}') && i + 1 < template.length && template[i + 1] == c) {
        out.write(c);
        i += 2;
        continue;
      }
      if (c == '{') {
        final end = template.indexOf('}', i + 1);
        final detail = tags.detail(tagNameOf(pack.id, template.substring(i + 1 + 'tag:'.length, end)));
        if (detail == null) return null;
        out.write(detail);
        i = end + 1;
        continue;
      }
      out.write(c);
      i++;
    }
    final s = out.toString();
    if (s.length <= limit) return s;
    return ellipsis ? '${_cut(s, limit - 1)}…' : _cut(s, limit);
  }

  // --- buttons (A.8.5) ---------------------------------------------------------------------------------------------

  /// Its buttons for [slot] that are offered for [facts], in the pack's order.
  List<PluginAction> _offered(String slot, MessageFacts facts, TagSet tags, PluginPrefs prefs, {String? section, required bool hasSection}) {
    if (_paused || !packSees(facts)) return const [];
    return [
      for (final a in pack.rules.actions)
        if (a.slots.contains(slot)) ?_action(a, facts, tags, prefs, section: section, hasSection: hasSection),
    ];
  }

  /// [a] as a button where it is offered for [facts], else null: its condition holds, and a copy's words fill.
  PluginAction? _action(PackAction a, MessageFacts facts, TagSet tags, PluginPrefs prefs, {String? section, required bool hasSection}) {
    if (!_holds(a.when, facts, prefs, _in(tags), section: section, hasSection: hasSection)) return null;
    String? copied;
    if (a.verb == 'copy') {
      copied = _expand(a.text!, tags, 200);
      if (copied == null) return null;
    }
    final thread = facts.thread;
    return PluginAction(label: a.label, icon: Lucide.all[a.icon]!, run: (host) => _run(a, host, thread, copied));
  }

  /// A button pressed: its one verb, asked of the host through [GatedHost], which holds it to what the pack may do.
  /// What that throws or refuses goes to [onError].
  Future<void> _run(PackAction a, PluginHost host, int thread, String? copied) async {
    try {
      final gated = GatedHost(host, plugin: this, thread: thread, openLink: _openLink);
      switch (a.verb) {
        case 'say':
          gated.say(a.text!);
        case 'copy':
          gated.copy(copied!, say: a.say ?? 'Copied');
        case 'write':
          gated.write(a.text!);
        case 'markread':
          await gated.markRead(thread);
        case 'move':
          gated.move(thread, a.to == 'main' ? null : sectionIdOf(pack.id, a.to!));
        case 'link':
          await gated.openLink(a.url!);
      }
    } catch (e) {
      onError(this, e);
    }
  }

  // --- texts as they come (A.8.6) ----------------------------------------------------------------------------------

  /// Its one incoming rule: what to do with a text that landed in [section], from every rule of the pack's for that
  /// section whose switch is on and whose condition holds.
  List<IncomingAction> _incomingRule(MessageFacts facts, TagSet tags, String? section, PluginPrefs prefs) {
    if (_paused || !packMayAct(facts)) return const [];
    var read = false, mute = false;
    for (final r in pack.rules.incoming) {
      if (section != sectionIdOf(pack.id, r.section)) continue;
      // Off until the person switches it on, whatever the pack said its switch starts as.
      if (!prefs.flag(r.setting, fallback: false)) continue;
      if (!_holds(r.when, facts, prefs, _in(tags))) continue;
      read = read || r.verbs.contains('markread');
      mute = mute || r.verbs.contains('mute');
    }
    return [if (read) const MarkRead(), if (mute) const MuteNotification()];
  }

  // --- its settings (A.7) ------------------------------------------------------------------------------------------

  PluginSetting _setting(PackSetting s) {
    final icon = s.icon == null ? null : Lucide.all[s.icon];
    switch (s.type) {
      case 'toggle':
        var hint = s.hint;
        // A computer or a paired iPhone never runs a pack's incoming rules (ListPlugins._arrived): its switch says so.
        if (Sms.remote && pack.rules.incoming.any((r) => r.setting == s.key)) hint = [?hint, 'Switch it on in Uplink on your phone: it does nothing here.'].join(' ');
        return PluginSetting.toggle(key: s.key!, label: s.label, hint: hint, fallback: s.fallback, icon: icon);
      case 'choice':
        return PluginSetting.choice(key: s.key!, label: s.label, hint: s.hint, icon: icon, options: s.options, choice: s.choice!);
      case 'words':
        return PluginSetting.words(key: s.key!, label: s.label, hint: s.hint, icon: icon, placeholder: s.placeholder);
      case 'heading':
        return PluginSetting.heading(label: s.label, hint: s.hint);
      default:
        return PluginSetting.note(label: s.label, hint: s.hint, icon: icon);
    }
  }
}

/// [s] cut to [n] code units, never through a character.
String _cut(String s, int n) {
  if (s.length <= n) return s;
  final last = s.codeUnitAt(n - 1);
  return s.substring(0, last >= 0xD800 && last <= 0xDBFF ? n - 1 : n);
}
