import 'dart:async';

import 'package:flutter/foundation.dart';

import '../sms.dart';
import 'plugin.dart';
import 'registry.dart';

/// The tags of the conversations the list holds, worked out once for each and kept until its last words change.
///
/// The list must open as fast with thousands of conversations as it does without plugins, so the classifiers are
/// never run over all of them before a frame. What is handed over ([take]) is looked at in the order it came, the
/// newest first: the first [atOnce] are classified there and then, which is the first screen, so its rows never
/// start in the main list and jump to a section a frame later; after those, classifying goes on only until
/// [slice] has passed, and the rest is done in slices of that length between frames, with a word to whoever listens
/// when a slice changes something. A conversation not looked at yet has no tags and stands in the main list.
///
/// Read again with the same last words, date and contact, a conversation is not classified again. When a plugin is
/// switched on or off ([bind] sees it) every one held is, in the same slices; a plugin's other choices, and where
/// conversations are filed, change nothing a classifier says, and nothing is classified again for them.
class TagStore extends ChangeNotifier {
  TagStore(this.registry, {this.atOnce = 64, this.slice = const Duration(milliseconds: 2), this.onTagged});

  final PluginRegistry registry;

  /// How many are classified at once whatever the clock says: more than the list's first lot.
  final int atOnce;

  /// How long classifying may go on at a time once those are done.
  final Duration slice;

  /// Told of each conversation as it is classified, the first time and whenever its words have changed: where the
  /// rules for a message that has just come are run (list.dart).
  final void Function(MessageFacts facts, TagSet tags)? onTagged;

  PluginStore? _store;

  /// Which plugins were on when the tags held were worked out ([PluginRegistry.switches]).
  String? _switches;
  final _held = <int, _Held>{};
  final _waiting = <int, _Held>{};
  Timer? _later;
  bool _gone = false;

  /// Goes up whenever some conversation's tags change.
  int version = 0;

  /// How many conversations are still to be classified.
  int get waiting => _waiting.length;

  /// The tags of the conversation [thread]: none until it has been looked at.
  TagSet of(int thread) => _held[thread]?.tags ?? TagSet.none;

  /// What is held of the conversation [thread], as it was last handed over; null where it never was.
  MessageFacts? facts(int thread) => (_waiting[thread] ?? _held[thread])?.facts;

  /// The person's choices, given before anything is classified and again whenever they may have changed. Where a
  /// plugin has been switched on or off, everything held is classified again.
  void bind(PluginStore store) {
    final first = _store == null;
    _store = store;
    final switches = registry.switches(store);
    if (switches == _switches) return;
    _switches = switches;
    if (!first) {
      for (final e in _held.entries) {
        _waiting.putIfAbsent(e.key, () => e.value);
      }
    }
    _work(now: true);
  }

  /// Conversations that have just been read, the newest first.
  void take(Iterable<Conversation> fresh) {
    for (final c in fresh) {
      final facts = MessageFacts.conversation(c);
      final mark = (c.date.millisecondsSinceEpoch, facts.contact, facts.text);
      final had = _held[c.id];
      if (had != null && had.mark == mark && !_waiting.containsKey(c.id)) {
        // The same words: whether it is read or muted may have changed, and that is all.
        _held[c.id] = _Held(facts, mark, had.tags);
        continue;
      }
      _waiting[c.id] = _Held(facts, mark, had?.tags ?? TagSet.none);
    }
    _work(now: true);
  }

  /// Classifies what waits, oldest asked first: for as long as [slice] allows, and [atOnce] of them whatever the time
  /// where [now] (the list is about to draw them). The rest go on in a timer of their own, a slice at a time.
  void _work({required bool now}) {
    final store = _store;
    if (store == null || _gone) return;
    final clock = Stopwatch()..start();
    var done = 0;
    var changed = false;
    while (_waiting.isNotEmpty) {
      // A slice between frames always does one, so it ends however slow a classifier is.
      if (done >= (now ? atOnce : 1) && clock.elapsed >= slice) break;
      final thread = _waiting.keys.first;
      final next = _waiting.remove(thread)!;
      final tags = registry.classify(next.facts, store);
      if (!next.tags.same(tags)) changed = true;
      _held[thread] = _Held(next.facts, next.mark, tags);
      onTagged?.call(next.facts, tags);
      done++;
    }
    if (_waiting.isNotEmpty) {
      _later ??= Timer(Duration.zero, () {
        _later = null;
        _work(now: false);
      });
    }
    if (changed) {
      version++;
      // Whoever handed these over is about to draw them; only a slice between frames needs to say.
      if (!now) notifyListeners();
    }
  }

  @override
  void dispose() {
    _gone = true;
    _later?.cancel();
    super.dispose();
  }
}

/// One conversation's facts and the tags worked out of them (or, while it waits, the tags it had before).
class _Held {
  const _Held(this.facts, this.mark, this.tags);
  final MessageFacts facts;

  /// What the tags were worked out from: the date, whether a contact, the words.
  final (int, bool, String) mark;
  final TagSet tags;
}
