import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../l10n/words.dart';
import 'fold.dart';
import 'settings_icons.dart';
import 'settings_type.dart';

// The settings vocabulary: a port of the web app's src/app/settings/kit/settingsKit.tsx with the `setk-*` rules of
// settings.css that dress it. Every pane says what it says through these, so the panes cannot each grow a dialect:
// one card (PaneSection), one row (SettingRow), one hero, one callout, one empty state, one footnote.
//
// Each class is one export of settingsKit.tsx, and each number is the stylesheet's own, read through the tokens.
// What the page does with selectors is done here with two small scopes:
// - a pane (`.settingsScreen__pane`) is a [SettingsPaneScope], which the screen puts over a section's page. Inside
//   one, a row's icon wears its chip in the section's colour, the cards arrive one after another, and a part can be
//   found by its name and lit (`[data-found]`);
// - a card (`.setk__card`) is a `GlacierScope(classes: {'setk__card'})`, which is how a segmented control on it gets
//   the deeper track settings.css gives it (../settings_css.dart).

/// 1rem: the page's own text size, which a rule that sets no `font-size` inherits.
double _rem(Tokens t) => t.lenOf('1rem');

/// [style] in another weight of its face (`font-weight` on text that otherwise inherits its font).
TextStyle _weighted(Tokens t, TextStyle style, String weight) => style.copyWith(
      fontWeight: t.weight(weight),
      fontVariations: [
        for (final variation in style.fontVariations ?? const <FontVariation>[])
          variation.axis == 'wght' ? FontVariation('wght', t.len('glacier-font-weight-$weight')) : variation,
      ],
    );

/// `var(--hue, var(--app-ink))`: the section's colour where a pane brings one, else the page's ink.
Color settingsHue(Tokens t) => t.colorOf('var(--hue, var(--app-ink))');

/// `color-mix(in srgb, var(--hue, var(--app-ink)) 16%, transparent)`: the chip under an icon in its section's colour.
/// None under Dial-Up's bevelled chrome, whose icons stand bare on the page as the era's did.
Color settingsHueWash(Tokens t) => _bevel(t) ? const Color(0x00000000) : t.colorOf('color-mix(in srgb, var(--hue, var(--app-ink)) 16%, transparent)');

/// Dial-Up's chrome (lib/ui/dialup/bevel.dart's isBevelChrome, read here from its token so the kit needs no app import).
bool _bevel(Tokens t) => t.raw('app-chrome-style')?.trim() == 'bevel';

// --- the pane ----------------------------------------------------------------------------------------------------

/// What a part of the kit registers so the screen can find it by the name it draws (settingsSearch.ts
/// `findSetting`): where it is, and how to light it.
class FoundSetting {
  FoundSetting._(this.name, this.context, this._light);

  /// The name as drawn, folded for matching.
  final String name;

  /// The part to bring into view: a row, a hero, or a whole card with its title.
  final BuildContext context;
  final VoidCallback _light;

  /// Lights it for a moment (`data-found`, settings.css `settingsFound`).
  void light() => _light();
}

/// The names a section's page draws, by the parts that draw them: a row's label, a card's title, a hero's line, or
/// anything wrapped in [SettingsFindableMark]. The screen asks it for the setting a search hit or a link named.
class SettingsFinder {
  final List<FoundSetting> _entries = [];

  /// The first part on the page whose name is [name], give or take case and curly quotes; null when the page does
  /// not draw it just now (signed out, say), which opens the page and nothing more.
  FoundSetting? find(String name) {
    final want = fold(name).trim();
    for (final entry in _entries) {
      if (entry.name == want && entry.context.mounted) return entry;
    }
    return null;
  }
}

/// `.settingsScreen__pane`: a section's page, for the parts of the kit drawn on it. The screen puts one over each
/// page (settings_screen.dart); a pane drawn outside Settings does without, and its rows are plain.
class SettingsPaneScope extends InheritedWidget {
  const SettingsPaneScope({super.key, required this.finder, this.whole = false, this.seeking, required super.child});

  final SettingsFinder finder;

  /// Whether a setting on this page is being looked for (a search's hit, a link into Settings): the page is then
  /// built whole in its first frame, where it otherwise builds its later cards in the frames after ([PaneBody]).
  final bool whole;

  /// The name of the setting being looked for while [whole], for a part that keeps it out of sight until asked
  /// ([settingsSought]). The port's own.
  final String? seeking;

  static SettingsPaneScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SettingsPaneScope>();

  @override
  bool updateShouldNotify(SettingsPaneScope old) => !identical(old.finder, finder) || old.seeking != seeking;
}

/// Whether the setting a search's hit or a link is looking for on this page is one of [names], folded as the finder
/// folds them: for a part that keeps rows behind Simple's More (GHST-103), which opens it in place for one of them so
/// the row is there to be found and lit (Matt, 2026-10-29: "Add the ability to search settings and plugins from the
/// command search", whose results reach the rows Simple keeps behind More). False where nothing is looked for, and
/// outside Settings.
bool settingsSought(BuildContext context, Iterable<String> names) {
  final seeking = SettingsPaneScope.maybeOf(context)?.seeking;
  if (seeking == null) return false;
  final want = fold(seeking).trim();
  return names.any((name) => fold(name).trim() == want);
}

/// The children of a pane, laid out as the page lays out `.settingsScreen__pane`'s: a column with `--glacier-space-4`
/// between them. A section's page is one of these (it stands where a React pane returned a fragment), and it tells
/// each child its place, which is what `.setk:nth-child(n)` reads to stagger the cards' arrival.
///
/// What differs from the page: a pane's first [soon] children are built with the pane, and [soon] more each frame
/// after. Appearance is thirteen cards of small drawings, and built whole its one frame was 24 ms on a Mac
/// (measured, tool/perf.sh), and 17 with all but two of them built in the second. Nothing that is seen comes later
/// than it did: each card rises 40 ms after the one before it, and a card two frames on is built 17 ms after its
/// neighbour.
class PaneBody extends StatefulWidget {
  const PaneBody({super.key, required this.children});

  final List<Widget> children;

  /// How many of a pane's children are built in its first frame, and how many more in each frame after.
  static const int soon = 2;

  @override
  State<PaneBody> createState() => _PaneBodyState();
}

class _PaneBodyState extends State<PaneBody> {
  /// How many of the children are built so far.
  late int _built = math.min(widget.children.length, PaneBody.soon);

  /// A frame's callback is already asked for: one lot of children a frame, however often the pane is built in it.
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    // A page opened at one of its settings is built whole: the setting is looked for from its first frame.
    if (context.getInheritedWidgetOfExactType<SettingsPaneScope>()?.whole ?? false) _built = widget.children.length;
  }

  /// [PaneBody.soon] more of the children a frame from now.
  void _more() {
    if (_waiting) return;
    _waiting = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _waiting = false;
      if (mounted) setState(() => _built = math.min(widget.children.length, _built + PaneBody.soon));
    });
  }

  @override
  Widget build(BuildContext context) {
    final gap = context.tokens.space(4);
    final children = widget.children;
    final count = math.min(_built, children.length);
    if (count < children.length) _more();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) SizedBox(height: gap),
          // The page's title is the pane's first child, so the first of these is its second.
          _NthChild(nth: i + 2, child: children[i]),
        ],
      ],
    );
  }
}

/// A pane's child told its place among the pane's children, counted from 1 as `:nth-child` counts.
class _NthChild extends InheritedWidget {
  const _NthChild({required this.nth, required super.child});
  final int nth;

  static int? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_NthChild>()?.nth;

  @override
  bool updateShouldNotify(_NthChild old) => old.nth != nth;
}

/// `animation: settingsRise 360ms var(--glacier-ease-out) both; animation-delay: calc(40ms * var(--i, 0))`: a row or
/// a card arriving, a little after the one before it, rising a few pixels as it fades in. Still under reduced motion.
class SettingsRise extends StatefulWidget {
  const SettingsRise({super.key, this.index = 0, required this.child});

  /// `--i`: its place in the arrival.
  final int index;
  final Widget child;

  @override
  State<SettingsRise> createState() => _SettingsRiseState();
}

class _SettingsRiseState extends State<SettingsRise> with SingleTickerProviderStateMixin {
  /// Milliseconds: how long the rise takes, and how much later each place in the arrival starts.
  static const _rise = 360, _step = 40;

  /// Runs over the delay and the rise together; [_eased] is still through the delay, then eases over the rest.
  AnimationController? _controller;
  Animation<double>? _eased;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final t = context.tokens;
    final delay = _step * widget.index;
    final controller = AnimationController(vsync: this, duration: Duration(milliseconds: delay + _rise));
    _controller = controller;
    _eased = CurvedAnimation(parent: controller, curve: Interval(delay / (delay + _rise), 1, curve: t.curve('glacier-ease-out')));
    if (t.reducedMotion) {
      controller.value = 1;
    } else {
      controller.forward();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final eased = _eased!;
    return AnimatedBuilder(
      animation: eased,
      child: widget.child,
      builder: (context, child) {
        final v = eased.value.clamp(0.0, 1.0);
        // The same wrappers at rest as on the way, so what arrives keeps its state once it has.
        return Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child));
      },
    );
  }
}

/// A part of a page that the search can open onto: it says its [name] to the pane's [SettingsFinder] while it is
/// drawn, and when it is lit it wears the section's colour for a moment and lets it go (`[data-found]`:
/// `animation: settingsFound 1.6s var(--glacier-ease-out)`, 18% of the hue held for the first third; under reduced
/// motion a still 12% for as long).
///
/// The kit's own parts are wrapped in one. A page that names something its own way wraps it in this too, which is
/// the page's `data-findable`.
class SettingsFindableMark extends StatefulWidget {
  const SettingsFindableMark({super.key, required this.name, required this.child});

  /// The words as drawn; null registers nothing.
  final String? name;
  final Widget child;

  /// On the box that holds a part's light: it has a colour while the part is lit (`data-found`), and none at rest.
  static const Key lightKey = ValueKey<String>('settings-found');

  /// Whether the part at [light], a box found by [lightKey], is lit just now.
  static bool isLit(Widget light) => light is DecoratedBox && (light.decoration as BoxDecoration).color != null;

  @override
  State<SettingsFindableMark> createState() => _SettingsFindableMarkState();
}

class _SettingsFindableMarkState extends State<SettingsFindableMark> with SingleTickerProviderStateMixin {
  SettingsFinder? _finder;
  FoundSetting? _entry;
  AnimationController? _light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _register(SettingsPaneScope.maybeOf(context)?.finder);
  }

  @override
  void didUpdateWidget(SettingsFindableMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name) {
      _unregister();
      _register(SettingsPaneScope.maybeOf(context)?.finder);
    }
  }

  /// Says the name to [finder], in place of whatever was said before; nothing with no finder or no name.
  void _register(SettingsFinder? finder) {
    if (identical(finder, _finder) && _entry != null) return;
    _unregister();
    final name = widget.name;
    if (finder == null || name == null) return;
    _finder = finder;
    _entry = FoundSetting._(fold(name).trim(), context, _lightUp);
    finder._entries.add(_entry!);
  }

  void _unregister() {
    final entry = _entry;
    if (entry != null) _finder?._entries.remove(entry);
    _entry = null;
    _finder = null;
  }

  /// Starts the light from its beginning: what [FoundSetting.light] calls.
  void _lightUp() {
    if (!mounted) return;
    // The light is a moment, not a movement: it lasts as long on a device that asks for less motion, and holds still.
    final light = _light ??= AnimationController(vsync: this, duration: const Duration(milliseconds: 1600), animationBehavior: AnimationBehavior.preserve)..addListener(() => setState(() {}));
    light.forward(from: 0);
  }

  @override
  void dispose() {
    _unregister();
    _light?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final light = _light;
    Color? colour;
    if (light != null && light.isAnimating) {
      final t = context.tokens;
      final double strength;
      if (t.reducedMotion) {
        strength = 12;
      } else {
        // `0%, 35% { background }`: held, then eased out to the part's own ground by the end.
        final v = light.value;
        strength = v <= 0.35 ? 18 : 18 * (1 - t.curve('glacier-ease-out').transform((v - 0.35) / 0.65));
      }
      colour = t.colorOf('color-mix(in srgb, var(--hue, var(--glacier-text)) ${strength.toStringAsFixed(3)}%, transparent)');
    }
    // Always there, lit or not, so the part under it keeps its state when the light comes and goes.
    return DecoratedBox(
      key: SettingsFindableMark.lightKey,
      decoration: BoxDecoration(color: colour, borderRadius: colour == null ? null : BorderRadius.circular(context.tokens.radius('lg'))),
      child: widget.child,
    );
  }
}

// --- the card ----------------------------------------------------------------------------------------------------

/// Port of `PaneSection` (settingsKit.tsx; `.setk`, `.setk__title`, `.setk__desc`, `.setk__card`, `.setk__footer`):
/// the group card. Rows inside share one surface and hairline separators.
///
/// What differs from the web original: the hairline between two rows (`.setk-row + .setk-row`) is drawn by the card,
/// which knows a row by its type ([SettingRow], [SettingRowBox], or anything else that says it is a [PaneRow]); a
/// row wrapped in another widget is not seen as one and gets no line, so hand the card its rows directly.
class PaneSection extends StatelessWidget {
  const PaneSection({super.key, this.title, this.description, this.footer, required this.children});

  /// ONE heading style: a small-caps muted caption above the card. The search finds the card by it.
  final String? title;

  /// A muted introduction between the title and the card.
  final Widget? description;

  /// A muted footnote BELOW the card: status readouts, attached to their group.
  final Widget? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(2);
    final small = pageText(t, t.fontSize('sm'), height: t.len('glacier-leading-sm'), color: t.color('app-ink-2'));
    final side = EdgeInsets.symmetric(horizontal: t.space(2));
    final titleSize = t.lenOf('0.72rem');

    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final ruled = i > 0 && _isRow(child) && _isRow(children[i - 1]);
      rows.add(ruled ? DecoratedBox(position: DecorationPosition.foreground, decoration: _RowRule(t), child: Padding(padding: EdgeInsets.only(top: t.len('glacier-hairline')), child: child)) : child);
    }

    Widget section = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null && title!.isNotEmpty)
          Padding(
            padding: side,
            child: Semantics(
              label: title!.t,
              child: ExcludeSemantics(
                // `text-transform: uppercase`: drawn in capitals, named as written. Dial-Up's group labels are as
                // written, as the era's group boxes had them. In the language drawn (lib/l10n/words.dart).
                child: Text(
                  _bevel(t) ? title!.t : title!.t.toUpperCase(),
                  style: pageText(t, titleSize, weight: 'semibold', color: t.color('app-ink-3'), tracking: t.len('app-tracking-caps', em: titleSize)),
                ),
              ),
            ),
          ),
        if (title != null && title!.isNotEmpty) SizedBox(height: gap),
        // Each line as tall as the page's, to the fraction (the kit's ExactLines): a page of whole-pixel lines ended
        // fifty device pixels short of the page's.
        if (description != null) ...[Padding(padding: side, child: DefaultTextStyle(style: small, child: ExactLines(lineHeight: small.fontSize! * small.height!, child: description!))), SizedBox(height: gap)],
        GlacierScope(
          classes: const {'setk__card'},
          // In a look that rules its shapes (Sharp: `--app-bubble-rim`) the card wears a line, where its
          // paper-2 on Sharp's black was 1.1:1 and the card all but vanished.
          child: DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(t.radius('lg')),
              border: (t.raw('app-bubble-rim') ?? '').isEmpty || _bevel(t) ? null : Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline')),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.radius('lg')),
              child: ColoredBox(
                color: t.color('app-paper-2'),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: rows),
              ),
            ),
          ),
        ),
        if (footer != null) ...[SizedBox(height: gap), Padding(padding: side, child: DefaultTextStyle(style: small, child: ExactLines(lineHeight: small.fontSize! * small.height!, child: footer!)))],
      ],
    );

    section = SettingsFindableMark(name: title, child: section);
    if (SettingsPaneScope.maybeOf(context) == null) return section;
    // `.settingsScreen__pane .setk:nth-child(2..6) { --i: 1..5 }`; any other place arrives at once.
    final nth = _NthChild.of(context);
    return SettingsRise(index: nth != null && nth >= 2 && nth <= 6 ? nth - 1 : 0, child: section);
  }

  static bool _isRow(Widget child) => child is PaneRow;
}

/// `border-block-start: var(--glacier-hairline) solid var(--app-rule)`: the line over a row that follows a row.
class _RowRule extends Decoration {
  const _RowRule(this.t);
  final Tokens t;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _RowRulePainter(t.color('app-rule'), t.len('glacier-hairline'));
}

/// Draws the line along the top edge of the box, [width] thick.
class _RowRulePainter extends BoxPainter {
  _RowRulePainter(this.color, this.width);
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    canvas.drawRect(Rect.fromLTWH(offset.dx, offset.dy, configuration.size!.width, width), Paint()..color = color);
  }
}

// --- the row -----------------------------------------------------------------------------------------------------

/// A widget that is one row of a card (`.setk-row`), for the hairline a card draws between two of them. [SettingRow]
/// and [SettingRowBox] are; a page's own widget that builds exactly one row, with some state of its own, says so by
/// implementing this.
abstract interface class PaneRow {}

/// `layout` of a [SettingRow]: the control at the row's end, or across the row under its words.
enum SettingRowLayout { trailing, stacked }

/// `<div className="setk-row">` on its own: a row's padding round something a pane lays out itself (Appearance's
/// cards of cards). It counts as a row for the hairline between rows.
class SettingRowBox extends StatelessWidget implements PaneRow {
  const SettingRowBox({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(padding: EdgeInsets.all(context.tokens.space(3)), child: child);
}

/// Port of `SettingRow` (settingsKit.tsx; `.setk-row` and its parts): a label over its caption, with a control or a
/// value at its end, or the whole row a button with a chevron.
///
/// What differs from the web original:
/// - [label] is words, not any content: it is what the search finds the row by, and what a pressable row is called.
/// - A pressable row shows the kit's focus ring inside its edge, where the page left the browser's own.
/// - What else the page put in a label (a member's role after their handle, OrganizationSheet.tsx) is [labelAfter],
///   set in the label's line after its words.
class SettingRow extends StatelessWidget implements PaneRow {
  const SettingRow({
    super.key,
    this.icon,
    required this.label,
    this.labelAfter,
    this.hint,
    this.control,
    this.value,
    this.onPress,
    this.layout = SettingRowLayout.trailing,
    this.disabled = false,
    this.disabledReason,
    this.labelColor,
  });

  final Widget? icon;
  final String label;

  /// The label's colour where it is not the text's own: a member's name in their role's colour.
  final Color? labelColor;

  /// Something small in the label's line after its words, on their baseline: a chip.
  final Widget? labelAfter;

  /// The caption, bound under the label.
  final Widget? hint;

  /// Trailing control: Switch, SegmentedControl, Button.
  final Widget? control;

  /// Trailing muted text for display rows.
  final Widget? value;

  /// Makes the whole row the button; a chevron appears by itself.
  final VoidCallback? onPress;

  /// `trailing` seats the control at the row's end; `stacked` gives it the full width below the text.
  final SettingRowLayout layout;
  final bool disabled;

  /// Why the row is disabled, said one way everywhere.
  final String? disabledReason;

  bool get _off => disabled || (disabledReason != null && disabledReason!.isNotEmpty);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(3);
    final inPane = SettingsPaneScope.maybeOf(context) != null;
    final sm = t.fontSize('sm');

    Widget? chip;
    if (icon != null) {
      chip = inPane
          // `.settingsScreen__pane .setk-row__icon`: the list's chip, with the glyph at 1.05rem.
          ? Container(
              width: t.lenOf('1.85rem'),
              height: t.lenOf('1.85rem'),
              // Its corners under the look's radius scale, as the kit's own radii are (square in Dial-Up and Runestone).
              decoration: BoxDecoration(color: settingsHueWash(t), borderRadius: BorderRadius.circular(t.lenOf('0.55rem') * t.number('glacier-radius-scale'))),
              alignment: Alignment.center,
              child: SizedBox.square(dimension: t.lenOf('1.05rem'), child: FittedBox(child: IconTheme.merge(data: IconThemeData(color: settingsHue(t)), child: icon!))),
            )
          : icon!;
    }

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (labelAfter == null)
          ExactLines.of(Text(label.t, style: pageText(t, t.fontSize('md'), weight: 'medium', color: labelColor)), normal: true, dpr: t.css.lineDpr)
        else
          Text.rich(
            TextSpan(
              text: label.t,
              children: [WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic, child: labelAfter!)],
            ),
            style: pageText(t, t.fontSize('md'), weight: 'medium', color: labelColor),
          ),
        if (hint != null) ...[
          SizedBox(height: t.lenOf('0.15rem')),
          DefaultTextStyle(style: pageText(t, sm, height: t.len('glacier-leading-sm'), color: t.color('app-ink-2')), child: ExactLines(lineHeight: sm * t.len('glacier-leading-sm'), child: hint!)),
        ],
        if (disabledReason != null && disabledReason!.isNotEmpty) ...[
          SizedBox(height: t.lenOf('0.15rem')),
          Text(disabledReason!, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3')).copyWith(fontStyle: FontStyle.italic)),
        ],
      ],
    );

    Widget main(double width) => Row(
          children: [
            if (chip != null) ...[chip, SizedBox(width: gap)],
            Expanded(child: text),
            if (value != null) ...[
              SizedBox(width: gap),
              // `max-inline-size: 55%; text-align: end; font-variant-numeric: tabular-nums`
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width * 0.55),
                child: DefaultTextStyle(
                  style: pageText(t, sm, color: t.color('app-ink-3')).copyWith(fontFeatures: [...?pageText(t, sm).fontFeatures, const FontFeature.tabularFigures()]),
                  textAlign: TextAlign.end,
                  child: _RowValue(child: value!),
                ),
              ),
            ],
            if (control != null && layout == SettingRowLayout.trailing) ...[SizedBox(width: gap), control!],
            if (onPress != null) ...[SizedBox(width: gap), ExcludeSemantics(child: SettingsIcon(SettingsGlyph.chevronRight, size: 18, color: t.color('app-ink-4')))],
          ],
        );

    final Widget row;
    if (onPress != null) {
      // The pressable row is its own button but draws exactly like the others.
      row = Opacity(
        opacity: _off ? 0.5 : 1,
        child: GlacierPressable(
          onPressed: _off ? null : onPress,
          builder: (context, state) => GlacierFocusRing(
            visible: state.focused,
            radius: t.radius('sm'),
            offset: -3,
            child: ColoredBox(
              color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
              child: Padding(padding: EdgeInsets.all(gap), child: LayoutBuilder(builder: (context, box) => main(box.maxWidth))),
            ),
          ),
        ),
      );
    } else {
      final Widget plain = Padding(
        padding: EdgeInsets.all(gap),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              main(box.maxWidth),
              if (control != null && layout == SettingRowLayout.stacked) Padding(padding: EdgeInsets.only(top: gap), child: control!),
            ],
          ),
        ),
      );
      // `inert`, not just the look: out of reach of a tap, of the Tab key and of a screen reader. The same wrappers
      // either way, so a control keeps its state when its row is switched off and on.
      row = Opacity(
        opacity: _off ? 0.5 : 1,
        child: IgnorePointer(ignoring: _off, child: ExcludeFocus(excluding: _off, child: ExcludeSemantics(excluding: _off, child: plain))),
      );
    }
    return SettingsFindableMark(name: label.t, child: DefaultTextStyle(style: pageText(t, _rem(t)), child: row));
  }
}

/// Marks a row's value slot, so a [RowAction] in it knows where it is (`.setk-row__value > .setk-action`).
class _RowValue extends InheritedWidget {
  const _RowValue({required super.child});

  static bool around(BuildContext context) => context.getInheritedWidgetOfExactType<_RowValue>() != null;

  @override
  bool updateShouldNotify(_RowValue old) => false;
}

// --- the hero ----------------------------------------------------------------------------------------------------

/// A line under a hero's meta with a dot: what state the thing is in (`status` of `PaneHero`).
class PaneHeroStatus {
  const PaneHeroStatus(this.text, {this.pulse = false});
  final String text;

  /// The dot breathes while something is happening.
  final bool pulse;
}

/// Port of `PaneHero` (settingsKit.tsx; `.setk-hero` and its parts): one anatomy for "this thing, at a glance".
///
/// What differs from the web original: [title] is words, as [SettingRow.label] is, since the search finds the hero
/// by it.
class PaneHero extends StatelessWidget {
  const PaneHero({super.key, this.glyph, required this.title, this.meta, this.status, this.trailing, this.onPress});

  final Widget? glyph;
  final String title;
  final Widget? meta;
  final PaneHeroStatus? status;
  final Widget? trailing;

  /// The whole hero pressable, without looking like a button (About's version).
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(3);
    final inPane = SettingsPaneScope.maybeOf(context) != null;
    final sm = t.fontSize('sm');
    final titleSize = t.fontSize('2xl');
    final quiet = pageText(t, sm, color: t.color('app-ink-2'));

    final inner = Padding(
      padding: EdgeInsets.all(gap),
      child: Row(
        children: [
          if (glyph != null) ...[
            Container(
              width: t.lenOf('2.75rem'),
              height: t.lenOf('2.75rem'),
              decoration: BoxDecoration(color: inPane ? settingsHueWash(t) : t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              alignment: Alignment.center,
              child: IconTheme.merge(data: IconThemeData(color: inPane ? settingsHue(t) : t.color('app-ink')), child: glyph!),
            ),
            SizedBox(width: gap),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The hero's word is big: it is the fact a bug report needs first.
                Text(
                  title,
                  style: pageText(t, titleSize, weight: 'semibold', height: 1.1, tracking: t.len('app-tracking-title', em: titleSize)).copyWith(
                        fontFeatures: [...?pageText(t, titleSize).fontFeatures, const FontFeature.tabularFigures()],
                      ),
                ),
                if (meta != null) ...[
                  SizedBox(height: t.lenOf('0.15rem')),
                  DefaultTextStyle(style: quiet.copyWith(height: t.len('glacier-leading-sm')), child: meta!),
                ],
                if (status != null) ...[
                  SizedBox(height: t.lenOf('0.15rem')),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(child: _HeroDot(pulse: status!.pulse)),
                      SizedBox(width: t.lenOf('0.4rem')),
                      Flexible(child: Text(status!.text, style: quiet)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[SizedBox(width: gap), trailing!],
        ],
      ),
    );

    final Widget hero = onPress == null
        ? inner
        : GlacierPressable(
            onPressed: onPress,
            builder: (context, state) => GlacierFocusRing(
              visible: state.focused,
              radius: t.radius('sm'),
              offset: -3,
              child: ColoredBox(color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000), child: inner),
            ),
          );
    return SettingsFindableMark(name: title, child: DefaultTextStyle(style: pageText(t, _rem(t)), child: hero));
  }
}

/// `.setk-hero__dot`, breathing under `[data-pulse]` (`setkPulse 1.6s ease-in-out infinite`: down to 0.3 and back).
class _HeroDot extends StatefulWidget {
  const _HeroDot({required this.pulse});
  final bool pulse;

  @override
  State<_HeroDot> createState() => _HeroDotState();
}

class _HeroDotState extends State<_HeroDot> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_HeroDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// Starts or stops the breathing as [_HeroDot.pulse] and reduced motion now have it; stopped, the dot is whole.
  void _sync() {
    final on = widget.pulse && !context.tokens.reducedMotion;
    if (on && !_beat.isAnimating) _beat.repeat();
    if (!on && _beat.isAnimating) {
      _beat.stop();
      _beat.value = 0;
    }
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final dot = Container(
      width: t.lenOf('0.5rem'),
      height: t.lenOf('0.5rem'),
      decoration: BoxDecoration(color: t.color('app-ink'), shape: BoxShape.circle),
    );
    return AnimatedBuilder(
      animation: _beat,
      child: dot,
      builder: (context, child) {
        // One keyframe at 50%, each half eased in and out.
        final v = _beat.value;
        final there = v < 0.5 ? Curves.easeInOut.transform(v * 2) : 1 - Curves.easeInOut.transform((v - 0.5) * 2);
        return Opacity(opacity: 1 - 0.7 * there, child: child);
      },
    );
  }
}

// --- the banner --------------------------------------------------------------------------------------------------

/// Port of `SettingsCallout` (settingsKit.tsx; `.setk-callout`): one banner, a paper-2 card with a hairline, for the
/// thing happening now.
class SettingsCallout extends StatelessWidget {
  const SettingsCallout({super.key, this.icon, this.action, required this.child});

  final Widget? icon;
  final Widget? action;

  /// The banner's words; several paragraphs go in a column with `--glacier-space-2` between them.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(3);
    final inPane = SettingsPaneScope.maybeOf(context) != null;
    final Widget callout = Container(
      padding: EdgeInsets.all(gap),
      decoration: BoxDecoration(
        color: t.color('app-paper-2'),
        borderRadius: BorderRadius.circular(t.radius('lg')),
        border: Border.all(color: t.color('app-rule'), width: t.len('glacier-hairline')),
      ),
      child: Row(
        children: [
          if (icon != null) ...[IconTheme.merge(data: IconThemeData(color: inPane ? settingsHue(t) : t.color('app-ink')), child: icon!), SizedBox(width: gap)],
          Expanded(child: DefaultTextStyle(style: pageText(t, t.fontSize('sm'), height: t.len('glacier-leading-sm')), child: child)),
          if (action != null) ...[SizedBox(width: gap), DefaultTextStyle(style: pageText(t, _rem(t)), child: action!)],
        ],
      ),
    );
    return inPane ? SettingsRise(child: callout) : callout;
  }
}

// --- gated / empty -----------------------------------------------------------------------------------------------

/// An empty state's one action (`action` of `SettingsEmpty`).
class SettingsEmptyAction {
  const SettingsEmptyAction(this.label, this.onPress);
  final String label;
  final VoidCallback onPress;
}

/// Port of `SettingsEmpty` (settingsKit.tsx; `.setk-empty`): one shape for "this pane needs something you have not
/// set up".
class SettingsEmpty extends StatelessWidget {
  const SettingsEmpty({super.key, this.icon, required this.title, this.body, this.action});

  final Widget? icon;
  final String title;
  final Widget? body;
  final SettingsEmptyAction? action;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(2);
    final inPane = SettingsPaneScope.maybeOf(context) != null;
    final Widget empty = Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: t.space(6), horizontal: t.space(4)),
      decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg'))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Container(
              width: t.lenOf('2.75rem'),
              height: t.lenOf('2.75rem'),
              decoration: BoxDecoration(color: inPane ? settingsHueWash(t) : t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              alignment: Alignment.center,
              child: IconTheme.merge(data: IconThemeData(color: inPane ? settingsHue(t) : t.color('app-ink')), child: icon!),
            ),
            SizedBox(height: gap),
          ],
          Text(title.t, textAlign: TextAlign.center, style: pageText(t, _rem(t), weight: 'medium')),
          if (body != null) ...[
            SizedBox(height: gap),
            DefaultTextStyle(
              style: pageText(t, t.fontSize('sm'), height: t.len('glacier-leading-sm'), color: t.color('app-ink-2')),
              textAlign: TextAlign.center,
              child: body!,
            ),
          ],
          if (action != null) ...[
            SizedBox(height: gap),
            DefaultTextStyle(
              style: pageText(t, _rem(t)),
              child: SettingsWord(onPressed: action!.onPress, color: t.color('app-ink'), weight: 'semibold', child: Text(action!.label)),
            ),
          ],
        ],
      ),
    );
    return inPane ? SettingsRise(child: empty) : empty;
  }
}

// --- the footnote ------------------------------------------------------------------------------------------------

/// Port of `SettingsFootnote` (settingsKit.tsx; `.setk-footnote`): a small muted paragraph for the things that are
/// true but not rows.
class SettingsFootnote extends StatelessWidget {
  const SettingsFootnote({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(2)),
      child: DefaultTextStyle(style: pageText(t, t.fontSize('sm'), height: t.len('glacier-leading-sm'), color: t.color('app-ink-3')), child: child),
    );
  }
}

// --- a word that acts --------------------------------------------------------------------------------------------

/// `.app-word` (app.css) as the page's rule has it: a button that is only its word, in the font it stands in
/// (`font: inherit`) at the medium weight, muted until pressed, a thumb high. The settings kit's words are this with
/// a colour, a weight or a height of their own.
///
/// lib/app/widgets.dart has an `AppWord` that sets the kit's `md` text and its leading; this one takes the size and
/// the line of where it is put, as the stylesheet does, which the head of Settings and a word in a sentence need.
class SettingsWord extends StatelessWidget {
  const SettingsWord({
    super.key,
    required this.onPressed,
    required this.child,
    this.color,
    this.weight = 'medium',
    this.minHeight,
    this.padding,
    this.semanticLabel,
    this.haptic = HapticKind.light,
  });

  final VoidCallback? onPressed;
  final Widget child;

  /// The word's colour at rest; the page's is `--glacier-text-muted`, turning to `--glacier-text` while pressed.
  final Color? color;
  final String weight;

  /// `min-block-size`; the page's is `--glacier-space-12`.
  final double? minHeight;

  /// The page's is `var(--glacier-space-2) 0`.
  final EdgeInsetsGeometry? padding;
  final String? semanticLabel;
  final HapticKind? haptic;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = DefaultTextStyle.of(context).style;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: semanticLabel,
      haptic: haptic,
      builder: (context, state) {
        final ink = state.disabled
            ? t.color('glacier-text-subtle')
            : color ?? (state.pressed ? t.color('glacier-text') : t.color('glacier-text-muted'));
        Widget word = DefaultTextStyle(
          style: _weighted(t, base, weight).copyWith(color: ink),
          child: IconTheme.merge(data: IconThemeData(color: ink), child: child),
        );
        if (semanticLabel != null) word = ExcludeSemantics(child: word);
        return GlacierFocusRing(
          visible: state.focused,
          radius: t.radius('sm'),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight ?? t.space(12)),
            child: Padding(
              padding: padding ?? EdgeInsets.symmetric(vertical: t.space(2)),
              // As wide as its word, and the word in the middle of its height.
              child: Align(alignment: Alignment.center, widthFactor: 1, heightFactor: 1, child: word),
            ),
          ),
        );
      },
    );
  }
}

/// Port of `RowAction` (settingsKit.tsx; `.app-word.setk-action`): the quiet action a row carries, a word in ink.
class RowAction extends StatelessWidget {
  const RowAction({super.key, required this.onPress, required this.child, this.disabled = false});

  final VoidCallback onPress;
  final Widget child;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // In a row's value slot it keeps the row's size, not the value's small text, and stands off the control
    // (`.setk-row__value:has(> .setk-action)`, `.setk-row__value > .setk-action`).
    final inValue = _RowValue.around(context);
    Widget word = SettingsWord(
      onPressed: disabled ? null : onPress,
      color: t.color('app-ink'),
      weight: 'semibold',
      minHeight: t.space(10),
      padding: EdgeInsets.symmetric(vertical: t.space(2), horizontal: t.space(1)),
      child: child,
    );
    if (inValue) {
      word = Padding(
        padding: EdgeInsetsDirectional.only(end: t.space(2)),
        child: DefaultTextStyle(style: pageText(t, _rem(t)), child: word),
      );
    }
    return word;
  }
}

// --- a word that goes somewhere ----------------------------------------------------------------------------------

/// Port of `GoWord` (settingsKit.tsx; `.app-word.setk-go`): a word in a sentence that opens the setting it names,
/// set in the line as a word of it, in ink and underlined. Without somewhere to go, as on a page drawn outside
/// Settings, it is the word alone.
///
/// Put it in a sentence as a `WidgetSpan(alignment: PlaceholderAlignment.baseline, baseline: TextBaseline.alphabetic)`.
class GoWord extends StatelessWidget {
  const GoWord(this.word, {super.key, this.onPress});

  final String word;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = DefaultTextStyle.of(context).style;
    if (onPress == null) return Text(word, style: base);
    final ink = t.color('app-ink');
    return GlacierPressable(
      onPressed: onPress,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: t.radius('sm'),
        child: Text(
          word,
          style: _weighted(t, base, 'medium').copyWith(
            color: ink,
            decoration: TextDecoration.underline,
            decorationColor: ink,
            decorationThickness: t.len('glacier-hairline'),
          ),
        ),
      ),
    );
  }
}

// --- pick one ----------------------------------------------------------------------------------------------------

/// Port of `Pick` (settingsKit.tsx; `.setk-pick`): a radio drawn as a ring with an ink dot when chosen; the row's
/// control.
class Pick extends StatelessWidget {
  const Pick({super.key, required this.checked, required this.label, required this.onPress, this.disabled = false});

  final bool checked;

  /// What choosing it does, for a screen reader: "Use Qwen3.5 4B".
  final String label;
  final VoidCallback onPress;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final target = t.space(10);
    final dot = t.lenOf('1.25rem');
    final ink = t.color('app-ink');
    final fast = t.duration('glacier-duration-fast');
    final ease = t.curve('glacier-ease-out');
    // `margin: calc(var(--glacier-space-2) * -1)`: a thumb's target that takes the room of the ring alone.
    final room = target - 2 * t.space(2);
    return SizedBox(
      width: room,
      height: room,
      child: OverflowBox(
        minWidth: target,
        maxWidth: target,
        minHeight: target,
        maxHeight: target,
        child: Opacity(
          opacity: disabled ? 0.4 : 1,
          child: Semantics(
            container: true,
            inMutuallyExclusiveGroup: true,
            checked: checked,
            enabled: !disabled,
            label: label.t,
            // The tap and the focus come up into this node from the pressable's own detectors.
            child: GlacierPressable(
              onPressed: disabled ? null : onPress,
              haptic: HapticKind.selection,
              excludeSemantics: true,
              builder: (context, state) => Center(
                child: GlacierFocusRing(
                  visible: state.focused,
                  color: ink,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: checked ? 1 : 0),
                    duration: t.reducedMotion ? Duration.zero : fast,
                    curve: ease,
                    builder: (context, on, _) => CustomPaint(
                      size: Size.square(dot),
                      // `border: 2px solid`, then `box-shadow: inset 0 0 0 0.3rem` growing in from it.
                      painter: _PickPainter(ring: Color.lerp(t.color('app-ink-3'), ink, on)!, fill: ink, inset: 2 + t.lenOf('0.3rem') * on, border: 2),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A [Pick]'s ring, and inside it a band of [fill] that grows inward from the ring as it is chosen: [inset] is how
/// far in from the edge the band reaches, the [border] included.
class _PickPainter extends CustomPainter {
  _PickPainter({required this.ring, required this.fill, required this.inset, required this.border});
  final Color ring, fill;
  final double inset, border;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    if (inset > border) {
      final width = inset - border;
      canvas.drawCircle(centre, radius - border - width / 2, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = fill);
    }
    canvas.drawCircle(centre, radius - border / 2, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = border
      ..color = ring);
  }

  @override
  bool shouldRepaint(_PickPainter old) => old.ring != ring || old.fill != fill || old.inset != inset || old.border != border;
}

// --- a Copy that says Copied -------------------------------------------------------------------------------------

/// Port of `useCopied` (settings/kit/useCopied.ts): `copy` puts [text] on the clipboard, and the value is true for a
/// second and a half after, however often it is pressed in that time. Dispose it with the button it drives.
class Copied extends ValueNotifier<bool> {
  Copied(this.text) : super(false);

  /// How long a Copy says Copied after it is pressed (`COPIED_MS`).
  static const Duration moment = Duration(milliseconds: 1500);

  String text;
  Timer? _timer;

  void copy() {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _timer?.cancel();
    value = true;
    _timer = Timer(moment, () => value = false);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Brings [found] into view in its scroller, as the page's `scrollIntoView({ block, behavior: 'smooth' })` does: to
/// the middle, or, for a part taller than most of the page (Appearance's themes), by its top, a
/// `--glacier-space-8` under the page's edge (`scroll-margin-block-start`), so its name shows.
void revealSetting(FoundSetting found) {
  final context = found.context;
  final object = context.findRenderObject();
  final scrollable = Scrollable.maybeOf(context);
  if (object is! RenderBox || !object.hasSize || scrollable == null) return;
  final t = context.tokens;
  final position = scrollable.position;
  final viewport = RenderAbstractViewport.of(object);
  final tall = object.size.height > position.viewportDimension * 0.6;
  final target = tall ? viewport.getOffsetToReveal(object, 0).offset - t.space(8) : viewport.getOffsetToReveal(object, 0.5).offset;
  final to = target.clamp(position.minScrollExtent, position.maxScrollExtent);
  if (t.reducedMotion) {
    position.jumpTo(to);
  } else {
    unawaited(position.animateTo(to, duration: t.duration('glacier-duration-slow'), curve: Curves.easeInOut));
  }
}
