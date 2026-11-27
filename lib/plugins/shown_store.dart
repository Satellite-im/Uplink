/// What the plugins' text rules said of the messages on the screen ([TextRule], [ShownText]), kept while the app is
/// open so a bubble scrolled past and back is not asked about again (Matt, 2026-11-17: "add a translate plugin which
/// can automatically translate texts when detected from another language and show the original text dimmed in a card
/// with the translated text for the actual message bubble").
///
/// A rule is a future (a translation takes the phone a moment), and a bubble is drawn now: [of] answers at once with
/// what is held, starts asking where nothing is, and says ([notifyListeners]) when an answer lands. A message is held by
/// its id; its words, which plugins are on and the plugins' choices are what the answer was worked out from, and a
/// change in any of them asks again, the old answer standing until the new one comes so nothing flickers. Which way
/// round the person has swapped a message (the words as they came in the bubble) is held here too, for the session.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'plugin.dart';
import 'registry.dart';

/// Keeps each message's answer from the text rules, which are asked off the build: a bubble reads what is held and is
/// drawn again, through this notifier, when the answer comes or changes.
class ShownStore extends ChangeNotifier {
  ShownStore({PluginRegistry? registry, this.most = 600}) : _registry = registry;

  /// The app's own, for every conversation's bubbles. A test puts its own here.
  static ShownStore instance = ShownStore();

  final PluginRegistry? _registry;
  PluginRegistry get registry => _registry ?? PluginRegistry.instance;

  /// The most messages held: past it, the one looked at longest ago goes.
  final int most;

  final _held = <String, _Shown>{};
  final Set<String> _flipped = {};

  /// Goes up whenever some message's answer changes.
  int version = 0;

  /// What a message is held under: its id, or its conversation and words where it has none.
  static String keyOf(MessageFacts facts) => facts.id ?? '${facts.thread}|${facts.text}';

  /// What the plugins that are on show in place of [facts]' words, as far as they have said; null for the words as
  /// they are. Asks them where they have not been asked about these words with these choices.
  ShownText? of(MessageFacts facts, PluginStore store) {
    if (facts.outgoing != false || facts.text.trim().isEmpty) return null;
    final key = keyOf(facts);
    final mark = registry.textMark(store);
    final had = _held.remove(key);
    if (had != null) _held[key] = had;
    if (had != null && had.text == facts.text && (had.mark == mark || had.asking) && !had.stale) return had.shown;
    // Nothing on: nothing to ask, and nothing held is worth showing.
    final rules = registry.textRules(store);
    if (rules.isEmpty) {
      if (had != null) _held.remove(key);
      return null;
    }
    final keep = had != null && had.text == facts.text ? had.shown : null;
    final next = _Shown(text: facts.text, mark: mark, shown: keep)..asking = true;
    _held[key] = next;
    while (_held.length > most) {
      final gone = _held.keys.first;
      _held.remove(gone)?.timer?.cancel();
      _flipped.remove(gone);
    }
    had?.timer?.cancel();
    unawaited(_ask(key, next, facts, rules));
    return keep;
  }

  /// What is held for the message [id], as last said: for a plugin's menu ("Copy translation").
  ShownText? held(String id) => _held[id]?.shown;

  /// Whether the message [id] is to be asked about again ([ShownText.again] has passed, or [again] was called).
  bool due(String id) => _held[id]?.stale ?? false;

  /// Asks [rules] in order and keeps the first answer; one that says "later" is passed over and asked again when its
  /// wait is up.
  Future<void> _ask(String key, _Shown entry, MessageFacts facts, List<BoundText> rules) async {
    ShownText? answer;
    // The soonest a plugin that answered "later" ([ShownText.later]) wants to be asked again.
    Duration? later;
    for (final r in rules) {
      try {
        answer = await r.rule(facts, r.prefs, PluginRegistry.textHost);
      } catch (error) {
        registry.failed(r.plugin, error);
        answer = null;
      }
      if (answer != null && answer.later) {
        final wait = answer.again!;
        later = later == null || wait < later ? wait : later;
        answer = null;
      }
      if (answer != null) break;
    }
    // Asked again meanwhile (the words or the choices changed): this answer is for what no longer stands.
    if (!identical(_held[key], entry)) return;
    entry.asking = false;
    final changed = !(answer?.same(entry.shown) ?? entry.shown == null);
    entry.shown = answer;
    final again = answer?.again ?? later;
    if (again != null) {
      entry.timer = Timer(again, () {
        if (!identical(_held[key], entry)) return;
        entry.stale = true;
        version++;
        notifyListeners();
      });
    }
    if (changed) {
      version++;
      notifyListeners();
    }
  }

  /// Asks about the message [id] again the next time it is drawn: a plugin's own action changed what it would say
  /// ("Translate" chosen from its menu).
  void again(String id) {
    final had = _held[id];
    if (had == null) {
      version++;
      notifyListeners();
      return;
    }
    had.timer?.cancel();
    had.stale = true;
    had.asking = false;
    version++;
    notifyListeners();
  }

  /// Asks about every message again the next time each is drawn, what is held standing meanwhile: what the device can
  /// do changed (a computer heard what its phone can do, lib/desktop/remote.dart).
  void askAll() {
    for (final e in _held.values) {
      e.timer?.cancel();
      e.stale = true;
      e.asking = false;
    }
    version++;
    notifyListeners();
  }

  /// Whether the person has swapped the message [id]: the words as they came in the bubble, the plugin's in the card.
  bool flipped(String id) => _flipped.contains(id);

  /// Swaps the message [id], or swaps it back.
  void flip(String id) {
    if (!_flipped.remove(id)) _flipped.add(id);
    version++;
    notifyListeners();
  }

  /// Forgets everything held (a test).
  void forget() {
    for (final e in _held.values) {
      e.timer?.cancel();
    }
    _held.clear();
    _flipped.clear();
    version++;
  }

  @override
  void dispose() {
    for (final e in _held.values) {
      e.timer?.cancel();
    }
    super.dispose();
  }
}

/// What is held of one message: the answer, and what it was an answer to.
class _Shown {
  _Shown({required this.text, required this.mark, this.shown});

  /// The words the answer is for.
  final String text;

  /// Which plugins were on, and their choices' stamp, when it was asked.
  final String mark;
  ShownText? shown;
  bool asking = false;

  /// Past its [ShownText.again]: asked again the next time it is drawn.
  bool stale = false;
  Timer? timer;
}
