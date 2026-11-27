/// The app's own emoji picker (Matt, 2026-11-19: "roll an in house emoji picker we should be able to pull the code out
/// from other apps we've built"): Ghost Keyboard's emoji panel (a tab for each group, recent first, a skin tone, a
/// search by name, keyword or shortcode) as a sheet over the chat, the way the sticker sheet comes up
/// (lib/ui/sticker_picker.dart). It stays up while emoji are picked, each going into the box where the cursor is; a
/// press outside it, or Escape, puts it away. The data is lib/emoji_data.dart.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../emoji_data.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import 'common.dart';
import '../l10n/words.dart';

/// Puts [emoji] into [c] where its cursor is (in place of what is selected), the cursor after it.
void insertEmoji(TextEditingController c, String emoji) {
  final v = c.value;
  final sel = v.selection;
  final start = sel.isValid ? sel.start : v.text.length;
  final end = sel.isValid ? sel.end : v.text.length;
  final text = v.text.replaceRange(start, end, emoji);
  c.value = v.copyWith(text: text, selection: TextSelection.collapsed(offset: start + emoji.length), composing: TextRange.empty);
}

/// Shows the picker; each emoji picked goes to [onPick] (and into the recent ones). Done when it is put away.
Future<void> showEmojiPicker(BuildContext context, {required ValueChanged<String> onPick}) {
  return Navigator.of(context).push<void>(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => EmojiSheet(onPick: onPick),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The picker's sheet: the search, the groups' tabs, the skin tone, and the emoji under their headings.
class EmojiSheet extends StatefulWidget {
  const EmojiSheet({super.key, required this.onPick, this.data});
  final ValueChanged<String> onPick;

  /// The list, where it is in hand already (a test); read from the app's assets otherwise.
  final EmojiData? data;

  @override
  State<EmojiSheet> createState() => _EmojiSheetState();
}

class _EmojiSheetState extends State<EmojiSheet> {
  EmojiData? _data;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  // A key on each group's heading, by the group's place, for its tab to scroll to.
  final _headings = <int, GlobalKey>{};
  bool _tones = false;

  @override
  void initState() {
    super.initState();
    _data = widget.data ?? EmojiData.loaded;
    if (_data == null) {
      EmojiData.load().then((d) {
        if (mounted) setState(() => _data = d);
      });
    }
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// An emoji pressed: counted among the recent ones and handed on. The sheet stays up for the next.
  void _pick(String emoji, EmojiChoices choices) {
    HapticFeedback.selectionClick();
    choices.used(emoji);
    widget.onPick(emoji);
    setState(() {});
  }

  /// A tab pressed: scrolls to that group's heading, where it has been built.
  void _jump(int section) {
    final there = _headings[section]?.currentContext;
    if (there != null) Scrollable.ensureVisible(there, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final choices = EmojiChoices(AppState.of(context));
    final pad = MediaQuery.paddingOf(context);
    final screen = MediaQuery.sizeOf(context);
    final data = _data;
    final query = _search.text.trim();
    final tone = choices.tone;
    final recent = choices.recent;
    final cell = t.lenOf('2.75rem');
    final face = pageText(t, t.lenOf('1.6rem'), color: t.color('app-ink'), height: 1.15);

    Widget emojiCell(String e, String label) => GlacierPressable(
          key: ValueKey('emoji-$e'),
          onPressed: () => _pick(e, choices),
          semanticLabel: label,
          builder: (context, state) => AnimatedScale(
            scale: state.pressed ? 0.86 : 1,
            duration: const Duration(milliseconds: 100),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(color: state.hovered || state.pressed ? t.color('app-paper-3') : const Color(0x00000000), borderRadius: BorderRadius.circular(t.radius('md'))),
              child: Text(e, style: face, textScaler: TextScaler.noScaling),
            ),
          ),
        );

    SliverGrid grid(List<(String, String)> items) => SliverGrid(
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: cell, mainAxisSpacing: 2, crossAxisSpacing: 2),
          delegate: SliverChildBuilderDelegate((context, i) => emojiCell(items[i].$1, items[i].$2), childCount: items.length),
        );

    Widget heading(int section, String words) => SliverToBoxAdapter(
          child: Padding(
            key: _headings.putIfAbsent(section, GlobalKey.new),
            padding: EdgeInsetsDirectional.fromSTEB(t.space(1), t.space(3), t.space(1), t.space(1)),
            child: Text(words.toUpperCase(), style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'))),
          ),
        );

    final slivers = <Widget>[];
    if (data != null && query.isNotEmpty) {
      final found = data.search(query);
      if (found.isEmpty) {
        slivers.add(SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(t.space(6)),
            child: Text('No emoji for "$query"', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ),
        ));
      } else {
        slivers.add(grid([for (final e in found) (e.toned(tone), e.label)]));
      }
    } else if (data != null) {
      if (recent.isNotEmpty) {
        slivers
          ..add(heading(-1, 'Recent'))
          ..add(grid([for (final e in recent) (e, e)]));
      }
      for (final (group, _, name) in EmojiData.groups) {
        slivers
          ..add(heading(group, name))
          ..add(grid([for (final e in data.inGroup(group)) (e.toned(tone), e.label)]));
      }
    }

    // The tabs: recent (where there are any), then each group by its emoji.
    final tabs = <(int, Widget, String)>[
      if (recent.isNotEmpty && query.isEmpty) (-1, AppIcon(Lucide.clock, size: 18, color: t.color('app-ink-2')), 'Recent'),
      if (query.isEmpty) for (final (group, mark, name) in EmojiData.groups) (group, Text(mark, style: pageText(t, t.lenOf('1.15rem'), color: t.color('app-ink')), textScaler: TextScaler.noScaling), name),
    ];

    const hands = ['✋', '✋🏻', '✋🏼', '✋🏽', '✋🏾', '✋🏿'];
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.radius('xl')),
              child: ColoredBox(
                key: const ValueKey('emoji-sheet'),
                color: t.color('app-paper-2'),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: t.lenOf('30rem'), maxHeight: (screen.height * 0.55).clamp(300.0, 480.0)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    // The search, and the skin tone: a hand in it, which offers the six.
                    Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(3), t.space(1)),
                      child: Row(children: [
                        Expanded(
                          child: GlacierInput(
                            key: const ValueKey('emoji-search'),
                            controller: _search,
                            focusNode: _focus,
                            placeholder: 'Search emoji'.t,
                            ariaLabel: 'Search emoji',
                            autoCorrect: false,
                            size: GlacierFieldSize.sm,
                          ),
                        ),
                        SizedBox(width: t.space(2)),
                        GlacierPressable(
                          key: const ValueKey('emoji-tone'),
                          onPressed: () => setState(() => _tones = !_tones),
                          semanticLabel: 'Skin tone',
                          builder: (context, state) => Container(
                            width: t.lenOf('2.25rem'),
                            height: t.lenOf('2.25rem'),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: _tones || state.pressed ? t.color('app-paper-3') : const Color(0x00000000), borderRadius: BorderRadius.circular(t.radius('md'))),
                            child: Text(hands[tone], style: pageText(t, t.lenOf('1.25rem'), color: t.color('app-ink')), textScaler: TextScaler.noScaling),
                          ),
                        ),
                      ]),
                    ),
                    if (_tones)
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space(3)),
                        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          for (final (i, h) in hands.indexed)
                            GlacierPressable(
                              key: ValueKey('emoji-tone-$i'),
                              onPressed: () => setState(() {
                                choices.tone = i;
                                _tones = false;
                              }),
                              semanticLabel: i == 0 ? 'No skin tone' : 'Skin tone $i',
                              builder: (context, state) => Container(
                                width: t.lenOf('2.25rem'),
                                height: t.lenOf('2.25rem'),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: i == tone ? t.color('app-paper-3') : const Color(0x00000000),
                                  borderRadius: BorderRadius.circular(t.radius('md')),
                                  border: i == tone ? Border.all(color: t.color('app-ink-3')) : null,
                                ),
                                child: Text(h, style: pageText(t, t.lenOf('1.2rem'), color: t.color('app-ink')), textScaler: TextScaler.noScaling),
                              ),
                            ),
                        ]),
                      ),
                    if (tabs.isNotEmpty)
                      SizedBox(
                        height: t.lenOf('2.5rem'),
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.symmetric(horizontal: t.space(2)),
                          children: [
                            for (final (section, mark, name) in tabs)
                              GlacierPressable(
                                key: ValueKey('emoji-tab-$section'),
                                onPressed: () => _jump(section),
                                semanticLabel: name,
                                builder: (context, state) => Container(
                                  width: t.lenOf('2.5rem'),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(color: state.hovered || state.pressed ? t.color('app-paper-3') : const Color(0x00000000), borderRadius: BorderRadius.circular(t.radius('md'))),
                                  child: mark,
                                ),
                              ),
                          ],
                        ),
                      ),
                    Container(height: 1, color: t.color('app-rule')),
                    Expanded(
                      child: data == null
                          ? const Center(child: GhostSpinner(size: 22))
                          : CustomScrollView(
                              controller: _scroll,
                              slivers: [for (final s in slivers) SliverPadding(padding: EdgeInsets.symmetric(horizontal: t.space(2)), sliver: s), SliverToBoxAdapter(child: SizedBox(height: t.space(2)))],
                            ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
