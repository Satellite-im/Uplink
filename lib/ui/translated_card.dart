/// A message's words as a plugin shows them ([ShownText]: the Translate plugin, lib/plugins/translate.dart), drawn the
/// same way by every conversation that has bubbles: texts and Uplink (lib/ui/thread.dart), Telegram and Signal
/// (lib/ui/inbox_ui.dart) and a space's chat (lib/ui/hangout_screen.dart). Matt, 2026-11-17: "add a translate plugin
/// which can automatically translate texts when detected from another language and show the original text dimmed in a
/// card with the translated text for the actual message bubble".
///
/// [ShownWords] asks the plugins (shown_store.dart) and hands its builder what to put in the bubble; [OriginalCard] is
/// the dimmed card over the bubble with the words as they came, which a tap swaps with the bubble's and a long press
/// copies; [OriginalLine] is the same said as a dim italic line under Dial-Up's transcript line, where there are no
/// bubbles. Every colour is the look's own (app-paper-2, app-ink-3, the look's rim), so the card is at home in each.
library;

import 'package:flutter/services.dart' show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide_more.dart';
import '../backgrounds.dart' show lookCorner, theirBubble, theirRim;
import '../kit/settings_type.dart';
import '../plugins/plugin.dart';
import '../plugins/registry.dart';
import '../plugins/shown_store.dart';
import '../plugins/translate.dart' show TranslatePlugin;
import 'common.dart' show Choice, GhostSpinner, toast;
import 'dialup/bevel.dart' show DialupColors, isBevelChrome;
import 'plugins_page/plugin_art.dart' show PluginHues;
import 'message_line.dart' show lineSize;

/// What one message shows, and which way round: [bubble] in the bubble, [card] in the card over it.
@immutable
class ShownView {
  const ShownView(this.id, this.shown, {this.flipped = false});
  final String id;
  final ShownText shown;

  /// The person swapped it: the words as they came in the bubble, the plugin's in the card.
  final bool flipped;

  /// There are two wordings to swap, and the plugin has finished its own.
  bool get canFlip => shown.original != null && !shown.busy;
  bool get swapped => flipped && canFlip;

  /// The words for the bubble and for the card (null: no card), the card's heading, and the word that swaps them.
  String get bubble => swapped ? shown.original! : shown.text;
  String? get card => shown.original == null ? null : (swapped ? shown.text : shown.original);
  String? get heading => swapped ? (shown.flipNote ?? shown.note) : shown.note;
  String get word => swapped ? shown.showShown : shown.showOriginal;

  void flip() => ShownStore.instance.flip(id);

  /// Whether [o] would draw the same, so nothing need be built again.
  bool same(ShownView? o) => o != null && o.id == id && o.flipped == flipped && shown.same(o.shown);
}

/// Asks the plugins what [facts]' words are shown as and builds with the answer: null where they are shown as they
/// are (or [facts] is null: the person's own, one being sent, a notice). Drawn again when the answer lands, and when
/// the person swaps it.
class ShownWords extends StatefulWidget {
  const ShownWords({super.key, required this.facts, required this.builder});
  final MessageFacts? facts;
  final Widget Function(BuildContext context, ShownView? view) builder;

  @override
  State<ShownWords> createState() => _ShownWordsState();
}

class _ShownWordsState extends State<ShownWords> {
  ShownView? _last;

  @override
  void initState() {
    super.initState();
    ShownStore.instance.addListener(_changed);
  }

  @override
  void dispose() {
    ShownStore.instance.removeListener(_changed);
    super.dispose();
  }

  /// Drawn again only where this message's own answer changed, or is due to be asked again: a list of bubbles is not
  /// all drawn again for each one that lands.
  void _changed() {
    final facts = widget.facts;
    if (facts == null || !mounted) return;
    final store = ShownStore.instance;
    final id = ShownStore.keyOf(facts);
    final held = store.held(id);
    final now = held == null ? null : ShownView(id, held, flipped: store.flipped(id));
    if (store.due(id) || (now == null ? _last != null : !now.same(_last))) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final facts = widget.facts;
    if (facts == null) {
      _last = null;
      return widget.builder(context, null);
    }
    final store = ShownStore.instance;
    final shown = store.of(facts, AppStore(AppState.of(context)));
    final id = ShownStore.keyOf(facts);
    _last = shown == null ? null : ShownView(id, shown, flipped: store.flipped(id));
    return widget.builder(context, _last);
  }
}

void _copy(BuildContext context, String text) {
  HapticFeedback.selectionClick();
  Clipboard.setData(ClipboardData(text: text));
  toast(context, 'Copied');
}

/// The card over a bubble: the words as they came, dimmed, under a quiet heading ("Translated from Spanish"), with the
/// word that swaps them ("Show original") at its trailing edge. A tap swaps them with the bubble's; a long press copies
/// what the card holds. While the plugin is still at work it is the heading alone, with a small spinner ("Getting
/// Spanish ready…").
///
/// It sits on the bubble as a tab does, not as a second message (Matt, 2026-11-17: "show the original text dimmed in a
/// card with the translated text for the actual message bubble"): set in from the bubble's edge, its corners small
/// where it meets the bubble and a hair's gap between them, none in a look that rims its bubbles (Sharp),
/// so the two rims run together. Its icon and its word are the plugin's own colour, the one cue in the chat that
/// Translate did this; the words stay dimmed in the page's quiet ink.
class OriginalCard extends StatelessWidget {
  const OriginalCard({super.key, required this.view, required this.maxWidth, this.mine = false, this.scale = 1});
  final ShownView view;
  final double maxWidth;

  /// On the person's own side (a message of theirs swapped back): the card's corners follow the bubble's side.
  final bool mine;

  /// Settings › Appearance › Text size, and a computer's smaller bubbles, as the bubble under it has them.
  final double scale;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = view;
    final ink3 = t.color('app-ink-3');
    final accent = PluginHues.of(t, const TranslatePlugin().hue).accent;
    final rim = theirRim(t);
    final round = Radius.circular(lookCorner(t, '0.9rem', most: 1));
    final meet = Radius.circular(lookCorner(t, '0.35rem', most: 1));
    final radius = BorderRadius.only(topLeft: round, topRight: round, bottomLeft: meet, bottomRight: meet);
    final inset = t.space(2);
    final small = pageText(t, t.fontSize('xs') * scale, weight: 'semibold', color: ink3, height: 1.3);
    final card = v.card;
    final heading = Text.rich(
      TextSpan(children: [
        WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(padding: EdgeInsetsDirectional.only(end: t.space(1) + 1), child: AppIcon(LucideMore.languages, size: 12 * scale, strokeWidth: 2.2, wash: false, color: accent))),
        TextSpan(text: v.heading ?? ''),
        if (v.shown.busy) WidgetSpan(alignment: PlaceholderAlignment.middle, child: Padding(padding: EdgeInsetsDirectional.only(start: t.space(2)), child: SizedBox.square(dimension: 12 * scale, child: GhostSpinner(size: 12 * scale)))),
      ]),
      style: small,
    );
    // The word that swaps them stands apart from the heading, at its trailing edge, and drops whole to a line of its
    // own where the two do not fit: in a monospaced look the heading's "·" was left alone at a line's end.
    final head = !v.canFlip
        ? heading
        : Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: t.space(3),
            runSpacing: 2,
            children: [
              heading,
              Text(v.word, maxLines: 1, softWrap: false, style: small.copyWith(color: accent, decoration: TextDecoration.underline, decorationColor: accent.withValues(alpha: 0.5))),
            ],
          );
    final body = Container(
      constraints: BoxConstraints(maxWidth: maxWidth - inset),
      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2) - 1),
      decoration: BoxDecoration(
        // The page's own ground with a line round it, where a bubble is filled: the card reads as set aside, and it
        // is still a card on a chat background.
        color: t.color('glacier-bg'),
        borderRadius: radius,
        // The look's own rim where it rims its bubbles (Sharp); else the page's rule.
        border: rim ?? Border.all(color: t.color('app-rule')),
      ),
      // As wide as its widest line wants, so the word goes to the trailing edge when the words under it are wider.
      child: IntrinsicWidth(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          head,
          if (card != null) ...[
            SizedBox(height: t.space(1)),
            Text(card, style: pageText(t, t.fontSize('sm') * scale, color: ink3, height: 1.35)),
          ],
        ]),
      ),
    );
    return Padding(
      padding: EdgeInsetsDirectional.only(bottom: rim != null ? 0 : t.space(1) / 2, start: mine ? 0 : inset, end: mine ? inset : 0),
      child: Semantics(
        button: v.canFlip,
        label: [v.heading, card].whereType<String>().join(': '),
        hint: v.canFlip ? v.word : null,
        child: GlacierPressable(
          onPressed: v.canFlip ? v.flip : null,
          onLongPress: card == null ? null : () => _copy(context, card),
          builder: (context, state) => AnimatedOpacity(duration: const Duration(milliseconds: 90), opacity: state.pressed ? 0.7 : 1, child: body),
        ),
      ),
    );
  }
}

/// What Translate does, drawn as it is in a conversation, for its page on the Plugins page (Matt, 2026-11-17: "show
/// the original text dimmed in a card with the translated text for the actual message bubble"): a text in Spanish, the
/// words as they came dimmed in the card and the translation in the bubble. Dial-Up's transcript line where its chrome
/// is on. Nothing in it is pressable.
class TranslatePreview extends StatelessWidget {
  const TranslatePreview({super.key});

  static const _view = ShownView('preview', ShownText(text: 'Are you still coming to dinner on Saturday?', original: '¿Sigues viniendo a la cena del sábado?', note: 'Translated from Spanish', flipNote: 'English translation', showShown: 'Swap back'));

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) {
      final c = DialupColors.of(t);
      return IgnorePointer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(
            TextSpan(children: [
              TextSpan(text: 'Lucía: ', style: TextStyle(color: c.nameTheirs, fontWeight: FontWeight.w700)),
              TextSpan(text: _view.bubble),
            ]),
            style: pageText(t, 15, color: c.onChrome, height: 1.35),
          ),
          const OriginalLine(view: _view),
        ]),
      );
    }
    return LayoutBuilder(builder: (context, box) {
      final maxWidth = box.maxWidth * 0.86;
      final round = Radius.circular(lookCorner(t, '1.125rem', most: 1));
      return IgnorePointer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          OriginalCard(view: _view, maxWidth: maxWidth),
          Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
            decoration: BoxDecoration(color: theirBubble(t, onBackground: false), border: theirRim(t), borderRadius: BorderRadius.all(round)),
            child: Text(_view.bubble, style: pageText(t, t.fontSize('md'), color: t.color('app-ink'), height: 1.3)),
          ),
        ]),
      );
    });
  }
}

/// The card said as Dial-Up's transcript says things: a dim italic line under the message's own, the words as they
/// came and, in brackets after them, what the line above is ("(translated from Spanish)"). A tap swaps them; a long
/// press copies what the line holds.
class OriginalLine extends StatelessWidget {
  const OriginalLine({super.key, required this.view});
  final ShownView view;

  static String _lower(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = DialupColors.of(t);
    final v = view;
    final card = v.card;
    final note = v.swapped ? v.shown.called : _lower(v.heading ?? '');
    final style = pageText(t, lineSize(context, 14), color: c.inkSoft, height: 1.35).copyWith(fontStyle: FontStyle.italic);
    final line = Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text.rich(
        TextSpan(children: [
          if (card != null) TextSpan(text: '$card  '),
          TextSpan(text: '($note)'),
        ]),
        style: style,
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: v.canFlip ? v.flip : null,
      onLongPress: card == null ? null : () => _copy(context, card),
      child: Semantics(button: v.canFlip, hint: v.canFlip ? v.word : null, child: line),
    );
  }
}

/// The Translate plugin's lines for a message's menu, for the conversations that build their menus themselves
/// (Telegram and Signal, a space's chat): Translate, Copy translation, and the way round it is shown. None while the
/// plugin is off. A text's own conversation has them through its plugins' menu slot (lib/plugins/conversation.dart).
List<Choice> translateChoices(BuildContext context, MessageFacts? facts) {
  if (facts == null) return const [];
  final registry = PluginRegistry.instance;
  final plugin = registry.plugins.whereType<TranslatePlugin>().firstOrNull;
  if (plugin == null) return const [];
  final store = AppStore(AppState.of(context));
  if (!registry.isOn(plugin, store)) return const [];
  final host = _MenuHost(context, registry.prefsOf(plugin, store));
  return [
    for (final b in registry.actionsOf(Slots.messageMenu, MessagePlace(facts, TagSet.none), store, plugin))
      Choice(b.action.label, b.action.icon, () => b.action.run(host), danger: b.action.danger),
  ];
}

/// What a menu line of the Translate plugin may do away from a text's conversation: say something, and copy.
class _MenuHost implements PluginHost {
  _MenuHost(this.context, this.prefs);
  final BuildContext context;
  @override
  final PluginPrefs prefs;

  @override
  void say(String words) {
    if (context.mounted) toast(context, words);
  }

  @override
  void copy(String text, {String? say}) {
    Clipboard.setData(ClipboardData(text: text));
    if (say != null) this.say(say);
  }

  // The rest need a conversation's page under them: nothing here.
  @override
  void open(int thread) {}
  @override
  Future<void> markRead(int thread) async {}
  @override
  void move(int thread, String? section) {}
  @override
  void write(String text) {}
  @override
  void present(WidgetBuilder page) {}
  @override
  Future<void> deleteThread(int thread) async {}
  @override
  Future<void> reload() async {}
}
