import 'dart:async';

import 'app_state.dart';
import 'me/me.dart';
import 'sms.dart';

/// Uplink's own lists of what was archived or deleted where the network itself could not do it, kept on the person's
/// Uplink account too (Matt, 2026-11-15: "if we can't actually delete telegram messages add them to a ignore or
/// archive list on my ghost account specifically"): a network's chats archived, deleted, pinned or with messages
/// deleted in Uplink alone (lib/inbox/inbox.dart's lists), and the conversations and texts deleted beside Google
/// Messages that Android would not let go of (android Store.kt's hidden_threads and hidden_msgs).
///
/// Kept on the relay sealed with a key only this install has (Me.keep), so the relay holds what it can't read. Read
/// back as Uplink reaches the relay and joined with what is here: an item deleted on either side stays deleted.
class KeptLists {
  KeptLists._();
  static final KeptLists instance = KeptLists._();

  /// The app's choices, which hold the networks' lists; set as the app starts (lib/main.dart), null in a test.
  AppState? app;
  Timer? _push;

  /// The account's copy has been read and joined in since the app opened: nothing is written over it before that.
  bool _pulled = false;

  /// What parts the items of a list kept as one choice: the unit separator, which no id has in it.
  static const _sep = '\u001f';

  /// The lists as they are here: the networks' (the `inbox_` choices) and Android's hidden conversations and texts.
  Future<Map<String, Object?>> _local() async {
    final hidden = await Sms.instance.hiddenLists();
    return {
      'v': 1,
      'inbox': app?.withPrefix('inbox_') ?? const {},
      'threads': hidden['threads'] ?? const {},
      'msgs': hidden['msgs'] ?? const [],
    };
  }

  /// A list changed here: kept on the account a few seconds later, once.
  void changed() {
    // Not set up (a test of a screen, a computer that keeps nothing of its own): nothing to keep.
    if (app == null) return;
    _push?.cancel();
    _push = Timer(const Duration(seconds: 5), () => unawaited(push()));
  }

  /// Keeps the lists on the account now, after reading the account's own first where that has not been done.
  /// Quietly nothing where the relay cannot be reached.
  Future<void> push() async {
    try {
      if (!_pulled) await pull();
      await Me.instance.keep(await _local());
    } catch (_) {}
  }

  /// What the account keeps, joined with what is here. True where anything was added here.
  Future<bool> pull() async {
    final kept = await Me.instance.kept();
    _pulled = true;
    if (kept == null) return false;
    var added = false;
    final app = this.app;
    final inbox = (kept['inbox'] as Map? ?? const {}).cast<String, Object?>();
    if (app != null) {
      for (final e in inbox.entries) {
        final there = '${e.value}'.split(_sep).where((x) => x.isNotEmpty).toSet();
        final here = app.choice(e.key, '').split(_sep).where((x) => x.isNotEmpty).toSet();
        if (there.difference(here).isEmpty) continue;
        app.set(e.key, here.union(there).join(_sep));
        added = true;
      }
    }
    final threads = (kept['threads'] as Map? ?? const {}).map((k, v) => MapEntry('$k', (v as num).toInt()));
    final msgs = [for (final m in (kept['msgs'] as List? ?? const [])) '$m'];
    if (threads.isNotEmpty || msgs.isNotEmpty) {
      if (await Sms.instance.addHiddenLists(threads, msgs)) added = true;
    }
    return added;
  }
}
