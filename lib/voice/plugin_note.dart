import 'package:flutter/foundation.dart';

/// What a plugin says in a space's chat, for it to draw as a card of its own (Matt, 2026-11-19: "allow plugins to
/// render messages like these as cards with iconography and details"): Record call's "started recording" and "stopped
/// recording" (lib/plugins/record_call.dart), and whatever a plugin says next.
///
/// It rides with the message's words (`pn` on the wire, HangoutMessage), which stay a sentence a build from before, a
/// browser's page or a list's preview shows as it is. A build that has the plugin draws the card its [kind] and
/// [details] make (GhostPlugin.card); one without it shows the words.
@immutable
class PluginChatNote {
  const PluginChatNote(this.plugin, this.kind, [this.details = const {}]);

  /// The plugin's id (GhostPlugin.id) and what it is saying: "recordcall" and "started".
  final String plugin;
  final String kind;

  /// Facts for the card, by name: "by", "seconds", "voices", "savedTo". Words, each short.
  final Map<String, String> details;

  // What is taken from the wire: the plugin and kind as short lowercase words, at most [mostDetails] details, each
  // value cut to [detailMost] characters.
  static final _word = RegExp(r'^[a-z0-9_]{1,32}$');
  static final _key = RegExp(r'^[A-Za-z0-9_]{1,32}$');
  static const mostDetails = 8;
  static const detailMost = 200;

  Map<String, Object> toJson() => {'p': plugin, 'k': kind, if (details.isNotEmpty) 'd': details};

  /// From what came; null where it is not one, and only as much as a card may hold.
  static PluginChatNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final p = j['p'], k = j['k'];
    if (p is! String || k is! String || !_word.hasMatch(p) || !_word.hasMatch(k)) return null;
    final d = j['d'];
    final details = <String, String>{};
    if (d is Map) {
      for (final e in d.entries) {
        if (details.length >= mostDetails) break;
        final key = '${e.key}', value = e.value;
        if (!_key.hasMatch(key) || value is! String) continue;
        details[key] = value.length > detailMost ? value.substring(0, detailMost) : value;
      }
    }
    return PluginChatNote(p, k, details);
  }

  /// Record call's line in a chat's words: "🔴 Maya started recording this call. ..." and "⏹ Maya stopped recording."
  /// (lib/voice/recorder.dart). The emoji is what travels, for a build from before and a browser's page; a build with
  /// this draws the app's own icon in its place wherever the words are shown and not the card: a quote, a thread, a
  /// list's preview (GMFB-43: "use the icons ... instead of emoji").
  static final _recordingLine = RegExp('^(\u{1F534}|\u23F9)\uFE0F? ?(.*? (?:started|stopped) recording\\b.*)\$', unicode: true, dotAll: true);

  /// [text] where it is Record call's line: whether it says the recording started (else stopped), and the words
  /// without the emoji. Null for any other words.
  static ({bool started, String words})? recordingLine(String text) {
    final m = _recordingLine.firstMatch(text);
    if (m == null) return null;
    return (started: m.group(1) == '\u{1F534}', words: m.group(2)!);
  }

  @override
  bool operator ==(Object other) => other is PluginChatNote && other.plugin == plugin && other.kind == kind && mapEquals(other.details, details);

  @override
  int get hashCode => Object.hash(plugin, kind, Object.hashAllUnordered(details.entries.map((e) => '${e.key}=${e.value}')));
}
