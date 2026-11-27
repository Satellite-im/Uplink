/// Trying a pack without real texts (Matt, 2026-11-20: "a developer setting for users to be able to manually upload
/// plugins for development testing"): a text and who it's from, run through the pack as the app would run it, and what
/// came of it (its tags, the tab it went to, its row, the buttons offered where, what it would do as the text came, and
/// any built-in that would take the text first); and the sample texts every pack is tried on, a line each. On a dev
/// pack's own page, the submission form and the reviewer's page, so changing, reloading and trying happen in one place.
library;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../kit/settings_kit.dart';
import '../../kit/settings_type.dart';
import '../../plugins/pack/pack.dart';
import '../../plugins/registry.dart' show PluginStore;
import '../../l10n/words.dart';

/// Where a pack's button is offered, in words.
String _slotWords(String slot) => switch (slot) {
      'row' => 'On its row',
      'list.conversation.menu' => 'In a conversation\'s menu in the list',
      'conversation.header' => 'In a conversation\'s header',
      'conversation.message.menu' => 'In a message\'s menu',
      _ => slot,
    };

/// What one trial came to, as lines: what it tagged, where the text went, its row, its buttons, what it would do as
/// the text came, and what in this app would take it first.
List<String> trialLines(PluginPack pack, PackTrial r) {
  if (!r.seen) return const ['It doesn\'t see this text: it reads texts from numbers not in your contacts, one to one, and nothing else.'];
  String label(String key) => pack.rules.sections.where((s) => s.key == key).firstOrNull?.label ?? key;
  return [
    r.tags.isEmpty ? 'No tags' : 'Tags: ${[for (final e in r.tags.entries) e.value == null ? e.key : '${e.key}=${e.value}'].join(', ')}',
    r.section == null ? 'It stays in Messages' : 'It goes to ${label(r.section!)}',
    if (r.row != null && (r.row!.value != null || r.row!.caption != null)) 'Its row: ${[?r.row!.value, ?r.row!.caption].join(' · ')}',
    for (final e in r.actions.entries)
      if (e.value.isNotEmpty) '${_slotWords(e.key)}: ${e.value.join(', ')}',
    if (r.incoming.isNotEmpty) 'As it comes: ${[for (final i in r.incoming) i == 'markread' ? 'mark it read' : 'take its notification away'].join(' and ')}',
    if (r.shadowedBy != null) 'In this app, ${r.shadowedBy} takes this text first',
    'Took ${(r.took.inMicroseconds / 1000).toStringAsFixed(1)} ms',
  ];
}

/// "Try it" and "Try the samples" for [pack]. Its keys are [keyPrefix], then a name (try-text, try-from, try-on, try,
/// try-result, samples), then [keySuffix]: a dev pack's page passes `dev-plugin-` and `-<packId>`. Given the person's
/// [store], a built-in that would take a text first is named.
class TryPackSection extends StatefulWidget {
  const TryPackSection(this.pack, {super.key, required this.keyPrefix, this.keySuffix = '', this.store});

  final PluginPack pack;
  final String keyPrefix;
  final String keySuffix;
  final PluginStore? store;

  @override
  State<TryPackSection> createState() => _TryPackSectionState();
}

class _TryPackSectionState extends State<TryPackSection> {
  final _text = TextEditingController();
  final _from = TextEditingController(text: '72975');
  bool _on = false;
  List<String>? _result;
  List<(PackSample, String)>? _samples;

  Key _k(String name) => ValueKey('${widget.keyPrefix}$name${widget.keySuffix}');

  @override
  void dispose() {
    _text.dispose();
    _from.dispose();
    super.dispose();
  }

  /// Runs the typed text through the pack; with no sender typed it is from the short code 72975.
  void _try() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final from = _from.text.trim().isEmpty ? '72975' : _from.text.trim();
    setState(() {
      try {
        _result = trialLines(widget.pack, tryPack(widget.pack, text: text, from: from, switchesOn: _on, store: widget.store));
      } catch (e) {
        _result = ['It couldn\'t be tried: $e'];
      }
    });
  }

  /// Runs every sample text through the pack, and keeps a line for each saying what came of it.
  void _trySamples() {
    setState(() {
      _samples = [
        for (final s in packSamples)
          (
            s,
            () {
              try {
                final r = tryPack(widget.pack, text: s.text, from: s.from, switchesOn: _on, store: widget.store);
                if (!r.seen) return 'not seen';
                final label = r.section == null ? null : widget.pack.rules.sections.where((x) => x.key == r.section).firstOrNull?.label;
                final tags = [for (final e in r.tags.entries) e.value == null ? e.key : '${e.key}=${e.value}'];
                if (label == null && tags.isEmpty) return 'nothing';
                return [?label, ...tags].join(' · ');
              } catch (e) {
                return 'couldn\'t be tried';
              }
            }(),
          ),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final quiet = pageText(t, t.fontSize('sm'), height: 1.4, color: t.color('app-ink-2'));
    final mono = TextStyle(fontFamily: 'JetBrains Mono Variable', fontSize: t.fontSize('xs'), height: 1.45, color: t.color('app-ink-2'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PaneSection(
        title: 'Try it',
        description: const Tr('A text as if a number not in your contacts sent it, run through the plugin as the app would run it.'),
        children: [
          SettingRowBox(child: GlacierInput(key: _k('try-text'), controller: _text, placeholder: 'A text to try it on'.t, ariaLabel: 'A text to try it on', size: GlacierFieldSize.md, onSubmitted: (_) => _try())),
          SettingRow(icon: const AppIcon(Lucide.phone, size: 18), label: 'From', control: SizedBox(width: t.lenOf('8rem'), child: GlacierInput(key: _k('try-from'), controller: _from, ariaLabel: 'From', size: GlacierFieldSize.sm))),
          SettingRow(
            icon: const AppIcon(Lucide.slidersHorizontal, size: 18),
            label: 'Every switch on',
            hint: const Tr('Its settings\' switches all on, as if you had turned them on.'),
            control: GlacierSwitch(key: _k('try-on'), checked: _on, onCheckedChange: (on) => setState(() => _on = on), ariaLabel: 'Every switch on'),
          ),
          SettingRow(key: _k('try'), icon: const AppIcon(Lucide.play, size: 18), label: 'Try it', onPress: _try),
          if (_result != null)
            SettingRowBox(
              key: _k('try-result'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final line in _result!) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text(line, style: quiet))]),
            ),
        ],
      ),
      SizedBox(height: t.space(4)),
      PaneSection(
        title: 'Try the samples',
        description: const Tr('Bills, receipts and parcels, and texts no plugin like these should touch: a sign-in code, a friend\'s question, an appointment, a prize scam, a political text.'),
        children: [
          SettingRow(icon: const AppIcon(Lucide.listChecks, size: 18), label: _samples == null ? 'Try the samples' : 'Try them again', onPress: _trySamples),
          if (_samples != null)
            SettingRowBox(
              key: _k('samples'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final (s, said) in _samples!) Padding(padding: EdgeInsets.only(bottom: t.space(1)), child: Text('${s.id} · $said · ${s.text}', maxLines: 2, overflow: TextOverflow.ellipsis, style: mono)),
              ]),
            ),
        ],
      ),
    ]);
  }
}
