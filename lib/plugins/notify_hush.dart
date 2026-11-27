/// No notification for a text the list hides (GMFB-18, Matt, Android 0.12.3: "Spam messages still sending notifications.
/// If we dont have a specific kind of message enabled like political messages we shouldn't get notified via sms for
/// those messages").
///
/// The phone's side posts a text's notification as it arrives, often with the app closed (android Notifier.incoming),
/// so it cannot ask the plugins. It is handed what they would answer instead: the rules that put a text from a stranger
/// in a kind the filter hides (Kinds of text, kinds.dart) or in Spam (spam.dart) while Spam is hidden, worked out from
/// the person's choices and kept in Android's preferences as one JSON choice, [key]. The patterns are the plugins' own,
/// written out from them, never copied into Kotlin by hand; android NotifyHush.kt reads them, and both sides are held to
/// test/notify_hush_vectors.json. A conversation filed by hand ("Not political", "Move to Spam") is in it too, so
/// "Not …" lets its notifications through for good and one moved into a hidden kind stays silent.
///
/// A hushed text still arrives and is kept; only the notification is not made. Written again whenever a plugin's
/// choice, a filter choice or a filing changes ([AppState.choicesChanged]), and as the app starts.
library;

import 'dart:async';
import 'dart:convert';
import '../platform_info.dart';

import '../app_state.dart';
import 'kinds.dart';
import 'plugin.dart';
import 'registry.dart';
import 'spam.dart';

/// Writes the rules the phone's side hushes a text's notification by: [export] makes them, [start] keeps them written.
class NotifyHush {
  NotifyHush._();

  /// The choice the rules are kept under, in Android's "ui" preferences.
  static const key = 'notify_hush';

  /// Whether the filter shows [s] in Messages: the person's choice, else the kind's own default (ListPlugins.kindShown,
  /// read from the store so a test can hand its own).
  static bool shown(PluginSection s, PluginStore store) {
    final v = store.read('filter_${s.id}');
    return v == null ? !s.section.hidden : v == 'on';
  }

  /// The rules, as the phone's side reads them. Null parts are plugins that are off.
  static Map<String, Object?> export(PluginRegistry registry, PluginStore store) {
    final sections = registry.sections(store);
    final hidden = {for (final s in sections) if (s.section.filter && !shown(s, store)) s.id};
    final ids = {for (final s in sections) s.id};

    Map<String, Object?>? kinds;
    Map<String, Object?>? spam;
    for (final plugin in registry.plugins) {
      if (!registry.isOn(plugin, store)) continue;
      final prefs = registry.prefsOf(plugin, store);
      if (plugin is KindsPlugin) {
        kinds = {
          'groups': prefs.flag('groups'),
          'networks': prefs.flag('networks'),
          'spamFirst': prefs.flag('spam_first'),
          'weakNeeded': KindsPlugin.weakNeededOf(prefs),
          // Every kind that is on, in the order a text is asked about them: the first that takes it has it, and only a
          // hidden one hushes it.
          'list': [
            for (final k in plugin.kinds)
              if (prefs.flag('kind_${k.id}'))
                {
                  'id': k.id,
                  'hide': hidden.contains(k.id),
                  'notSpam': k.notSpam,
                  'strong': k.strong,
                  'weak': k.weak,
                  // The person's own words, as TextKind.matches asks them: each a pattern of itself.
                  'words': [for (final w in wordsOf(prefs, 'words_${k.id}')) RegExp.escape(w)],
                },
          ],
        };
      } else if (plugin is SpamPlugin) {
        final t = SpamTuning.of(prefs);
        spam = {
          'hide': hidden.contains(SpamPlugin.section),
          'groups': prefs.flag('groups'),
          'networks': prefs.flag('networks'),
          'base': t.base,
          'codesLenient': t.allowances && t.codesLenient,
          'shortLenient': t.allowances && t.shortLenient,
          'strongDouble': t.strongDouble,
          'rules': [
            for (final r in plugin.rules)
              if (!t.off.contains(r.id)) {'id': r.id, 'words': r.words, 'sender': r.sender, 'strong': r.strong},
          ],
          // As judgeSpam's _hasWord asks them: each a pattern of itself.
          'alwaysWords': [for (final w in t.alwaysWords) RegExp.escape(w)],
          'neverWords': [for (final w in t.neverWords) RegExp.escape(w)],
          'alwaysSenders': t.alwaysSenders,
          'neverSenders': t.neverSenders,
        };
      }
    }
    // Filed by hand: hushed where it was filed in a kind the filter hides, let through anywhere else (the main list,
    // "Not …"; or a section that is shown). A filing whose section is gone is left to the rules, as the list leaves it.
    final filed = <String, bool>{
      for (final e in registry.filing(store).all.entries)
        if (e.value == Filing.main || ids.contains(e.value)) '${e.key}': hidden.contains(e.value),
    };
    return {'v': 1, 'kinds': kinds, 'spam': spam, 'filed': filed};
  }

  /// A write is waiting to run: further changes in the same run add nothing.
  static bool _due = false;

  /// Keeps [key] up to date from here on: written now, and again (once for a run of changes) whenever a choice that
  /// changes it does. On Android alone: a computer or an iPhone posts no texts' notifications.
  static void start(AppState app, {PluginRegistry? registry}) {
    if (!PlatformInfo.isAndroid) return;
    void write() {
      _due = false;
      try {
        app.keep(key, jsonEncode(export(registry ?? PluginRegistry.instance, AppStore(app))));
      } catch (_) {}
    }

    AppState.choicesChanged = (_) {
      if (_due) return;
      _due = true;
      scheduleMicrotask(write);
    };
    write();
  }
}
