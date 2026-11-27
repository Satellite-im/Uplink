/// What the screens draw of the plugins: the tabs of the list's sections, a section's row as its plugin describes
/// it, and a quiet note a plugin can put in a widget slot. Drawn by the app, in the app's own type and colours; a
/// plugin says what, in words (plugin.dart).
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../art/svg_path.dart';
import '../kit/menu_room.dart';
import '../kit/settings_type.dart';
import '../reactions.dart';
import '../sms.dart';
import '../ui/common.dart';
import '../ui/dialup/dialup.dart' show DialupCount, RetroButton, isDialup;
import '../ui/nav_bar.dart';
import 'companies.dart' show ghostDomain;
import 'plugin.dart';
import 'registry.dart';
import '../kit/semantic_colors.dart';

/// The list's tabs, under its search field: "Messages" and each section that has conversations in it, with how
/// many, as one segmented toggle (Matt, 2026-11-14: "change the messages and codes to a segmented toggle"). They
/// were chips in a row that scrolled sideways.
///
/// A press with the other button on a tab, or a long press, asks for that tab's menu ([onMenu]; Matt, the same
/// message: "add a right click menu for the codes and messages tabs"). It is the kit's middle size (Matt, later
/// that day: "the segmented toggle for messages vs codes can be a size larger").
class SectionTabs extends StatelessWidget {
  const SectionTabs({super.key, required this.sections, required this.counts, required this.unread, required this.chosen, required this.onPick, this.onMenu, this.extra = const []});

  /// Tabs of the app's own after the sections' (the voice channels: lib/ui/conversations.dart).
  final List<({String id, LucideIcon icon, String label, int count})> extra;

  final List<PluginSection> sections;
  final Map<String, int> counts;

  /// The sections with something unread in them.
  final Set<String> unread;

  /// The section chosen; null is the main list.
  final String? chosen;
  final ValueChanged<String?> onPick;

  /// Asked for a tab's menu; null for the main list's.
  final ValueChanged<String?>? onMenu;

  /// What the toggle calls the main list, which the app calls null.
  static const _main = '';

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final values = [_main, for (final s in sections) s.id, for (final e in extra) e.id];

    // Icons alone (Matt, 2026-11-15: "use an icon only segmented toggle for the messages codes"), each tab's name said
    // to a screen reader, its unread count beside its icon where it has any.
    Widget label(String words, LucideIcon icon, {int? count}) => Semantics(
          label: count == null || count == 0 ? words : '$words, $count',
          excludeSemantics: true,
          child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
            AppIcon(icon, size: 18, strokeWidth: 2.2, wash: false),
            if (count != null && count > 0) ...[SizedBox(width: t.space(1)), Opacity(opacity: 0.7, child: Text('$count'))],
          ]),
        );

    return LayoutBuilder(builder: (context, box) {
      // The tabs share the toggle's width equally, so where a press landed says which tab it was on.
      void menu(double x) {
        final at = (x / (box.maxWidth / values.length)).floor().clamp(0, values.length - 1);
        onMenu?.call(values[at] == _main ? null : values[at]);
      }

      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: onMenu == null ? null : (d) => menu(d.localPosition.dx),
        onLongPressStart: onMenu == null ? null : (d) => menu(d.localPosition.dx),
        child: GlacierSegmentedControl(
          fullWidth: true,
          size: GlacierSegmentedSize.md,
          ariaLabel: 'Which conversations',
          value: chosen ?? _main,
          onValueChange: (v) => onPick(v == _main ? null : v),
          options: [
            // A tab's count is of its unread conversations, none where all are read (Matt, 2026-11-14: "the badge count
            // for codes that are already read").
            GlacierSegmentedOption(value: _main, label: label('Messages', LucideMore.messageCircle)),
            for (final s in sections) GlacierSegmentedOption(value: s.id, label: label(s.section.label, s.section.icon, count: counts[s.id])),
            for (final e in extra) GlacierSegmentedOption(value: e.id, label: label(e.label, e.icon, count: e.count)),
          ],
        ),
      );
    });
  }
}

/// The button beside the list's tabs that marks every conversation of the tab shown as read (Matt, 2026-11-14:
/// "a button to mark all read"): its picture alone in a circle as tall as the tabs' toggle (Matt, later that day:
/// "change mark all as read to just be the icon in a circle button"), with its words in a tip while a pointer
/// rests on it. Quiet while nothing there is unread.
class MarkAllRead extends StatelessWidget {
  const MarkAllRead({super.key, required this.unread, required this.onPress});

  /// How many conversations of the tab shown are unread.
  final int unread;
  final VoidCallback onPress;

  /// How wide and tall it is: the tabs' toggle's height, so the two stand level.
  static double size(Tokens t) => t.len('glacier-control-height-md');

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final any = unread > 0;
    final ink = t.color(any ? 'app-ink' : 'app-ink-4');
    return HoverTip(
      message: any ? 'Mark all read' : 'Nothing unread',
      below: true,
      end: true,
      child: GlacierPressable(
        onPressed: any ? onPress : null,
        semanticLabel: any ? 'Mark all read, $unread unread' : 'Mark all read, nothing unread',
        builder: (context, state) => GlacierFocusRing(
          visible: state.focused,
          radius: t.radius('full'),
          child: Container(
            width: size(t),
            height: size(t),
            decoration: BoxDecoration(
              color: t.color(state.pressed && any ? 'app-paper-3' : 'app-paper-2'),
              shape: BoxShape.circle,
              border: Border.all(color: t.color('app-rule')),
            ),
            alignment: Alignment.center,
            child: ExcludeSemantics(child: AppIcon(Lucide.checkCheck, size: 17, strokeWidth: 2.2, wash: false, color: ink)),
          ),
        ),
      ),
    );
  }
}

/// The list's filter: a round button beside Mark all read, as tall as the tabs' toggle, that opens a small menu of
/// the kinds of text (lib/plugins/kinds.dart) to show or hide in Messages and to show alone (Matt, 2026-11-14: "I'm
/// thinking a filter dropdown where showing spam, political messages, and debt collectors are filtered out by
/// default"). It wears how many conversations it is hiding, and is drawn filled while one kind is shown alone.
class FilterButton extends StatefulWidget {
  const FilterButton({super.key, required this.hidden, required this.rows, this.only = false});

  /// How many conversations the filter is hiding from Messages.
  final int hidden;

  /// The menu's rows, asked for as it opens and each time the list is drawn while it is open.
  final List<Widget> Function(BuildContext context) rows;

  /// One kind is shown alone.
  final bool only;

  @override
  State<FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<FilterButton> with WidgetsBindingObserver {
  bool _open = false;

  /// The room the menu has on screen, measured as it opens, and again when the window, its bars or the keyboard
  /// change while it is open (Matt, 2026-11-20: "the filter popover goes off screen it should make sure it renders on
  /// screen"). A long menu under the button ran off the window's foot.
  MenuRoom? _room;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!_open) return;
    // Measured once the frame has put the button where the new window has it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) setState(() => _room = MenuRoom.of(context));
    });
  }

  void _setOpen(bool open) => setState(() {
        _open = open;
        _room = open ? MenuRoom.of(context) : null;
      });

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = MarkAllRead.size(t);
    final ink = widget.only ? t.color('app-on-accent') : t.color('app-ink');
    final room = _room;
    final tallest = math.max(t.lenOf('12rem'), MediaQuery.sizeOf(context).height * 0.6);
    final widest = room?.width ?? double.infinity;
    return GlacierMenu(
      open: _open,
      onOpenChange: _setOpen,
      // Under the button, or over it where there is more room there; no taller or wider than the room it has.
      placement: room?.place(Placement.bottomEnd) ?? Placement.bottomEnd,
      ariaLabel: 'Filter',
      style: GlacierMenuStyle(
        minWidth: math.min(t.lenOf('16rem'), widest),
        maxWidth: math.min(t.lenOf('19rem'), widest),
        maxHeight: room == null ? tallest : math.min(tallest, room.height),
      ),
      trigger: (context, trigger) => HoverTip(
        message: widget.hidden == 0 ? 'Filter' : 'Filter · ${widget.hidden} hidden',
        below: true,
        end: true,
        // Dial-Up's is a square raised button like the rest of its window's, held while its menu is open, with the
        // taskbar's red square for the count, where the round grey pill was the one Uplink shape left on its page.
        child: isDialup(context)
            ? Stack(clipBehavior: Clip.none, children: [
                RetroButton(
                  onPressed: trigger.toggle,
                  icon: LucideMore.funnel,
                  semanticLabel: widget.hidden == 0 ? 'Filter' : 'Filter, ${widget.hidden} hidden',
                  toggled: _open || widget.only,
                  faceHeight: size,
                  minFaceWidth: size,
                  padding: EdgeInsets.zero,
                ),
                if (widget.hidden > 0) PositionedDirectional(end: 0, top: 0, child: ExcludeSemantics(child: DialupCount(count: widget.hidden))),
              ])
            : GlacierPressable(
              onPressed: trigger.toggle,
              semanticLabel: widget.hidden == 0 ? 'Filter' : 'Filter, ${widget.hidden} hidden',
              builder: (context, state) => GlacierFocusRing(
                visible: state.focused,
                radius: t.radius('full'),
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      color: widget.only ? t.color('app-accent') : t.color(state.pressed || _open ? 'app-paper-3' : 'app-paper-2'),
                      shape: BoxShape.circle,
                      border: Border.all(color: widget.only ? t.color('app-accent') : t.color('app-rule')),
                    ),
                    alignment: Alignment.center,
                    child: ExcludeSemantics(child: AppIcon(LucideMore.funnel, size: 16, strokeWidth: 2.2, wash: false, color: ink)),
                  ),
                  if (widget.hidden > 0)
                    PositionedDirectional(
                      end: -6,
                      top: -6,
                      child: ExcludeSemantics(
                        child: Container(
                          // As big as the pill's (Matt, 2026-11-15: "make the notification count badges a bit bigger on
                          // the filter and other places where they're listed").
                          constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          // In the app's accent (Matt, 2026-11-14: "Make the pill indicator on the filters thr same as
                          // the primary color").
                          decoration: BoxDecoration(color: t.color('app-accent'), borderRadius: BorderRadius.circular(12), border: Border.all(color: t.color('glacier-bg'), width: 2)),
                          child: Text(widget.hidden > 99 ? '99+' : '${widget.hidden}', style: t.textAt(13, weight: 'bold', height: 1.15, color: t.color('app-on-accent'))),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
      ),
      children: widget.rows(context),
    );
  }
}

/// A conversation in a section, drawn as the section's plugin describes it ([RowLook]): a card with its face and
/// name as the main list has them, then a value drawn large over the words (a code), or the words with a quiet line under them
/// saying why it is here; a button at its end and a word to press, where the look has them.
class PluginRow extends StatelessWidget {
  const PluginRow({super.key, required this.conversation, required this.look, required this.host, required this.onPress, required this.onLongPress, this.selecting = false, this.selected = false});

  final Conversation conversation;
  final RowLook look;

  /// What the look's actions are run with.
  final PluginHost host;

  /// A tap, where the look has none of its own.
  final VoidCallback onPress;
  final VoidCallback onLongPress;
  final bool selecting;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = conversation;
    final unread = c.unread;
    final face = t.lenOf('3rem');
    final words = (reactionSnippet(c.snippet) ?? c.snippet).replaceAll('\n', ' ');
    final value = look.value;
    final tap = look.tap;
    final quiet = pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.35);
    return GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: GlacierPressable(
        // While several are being chosen a tap chooses, as in the main list.
        onPressed: selecting || tap == null ? onPress : () => tap.run(host),
        semanticLabel: selecting ? '${look.title ?? c.title}, ${selected ? 'selected' : 'not selected'}' : (tap == null ? null : '${look.title ?? c.title}, ${value ?? words}. ${tap.label}'),
        // A card, as the main list's rows are (ConversationRow), with the same line round the one chosen.
        builder: (context, state) => Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
          child: Container(
            decoration: BoxDecoration(
              color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
              borderRadius: BorderRadius.circular(t.lenOf('1rem')),
              border: Border.all(color: selected ? t.color('app-ink') : const Color(0x00000000), width: 2),
            ),
            padding: EdgeInsets.symmetric(horizontal: t.space(3) - 2, vertical: t.space(3) - 2),
            child: Row(
              children: [
                if (selecting)
                  Container(
                    width: face,
                    height: face,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? t.chosen : const Color(0x00000000),
                      border: Border.all(color: selected ? t.chosen : t.color('app-ink-4'), width: 2),
                    ),
                    alignment: Alignment.center,
                    child: selected ? const AppIcon(Lucide.check, size: 22, strokeWidth: 2.6, wash: false, color: Color(0xFFFFFFFF)) : null,
                  )
                else if (look.face != null)
                  BrandFace(face: look.face!, size: face)
                else
                  // Named by its section (a company a code is from, read out of its words): the name's letters
                  // stand in its picture, where its number's would have said nothing.
                  Avatar(people: look.title != null && c.people.length == 1 ? [Person(address: c.people.first.address, name: look.title)] : c.people, size: face),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(child: Text(look.title ?? c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize(value == null ? 'md' : 'sm'), weight: unread ? 'bold' : 'semibold', color: t.color(value == null ? 'app-ink' : 'app-ink-2')))),
                        if (unread) ...[
                          SizedBox(width: t.space(2)),
                          Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: t.unread)),
                        ],
                        SizedBox(width: t.space(2)),
                        Text(listWhen(c.date), style: pageText(t, t.fontSize('xs'), weight: unread ? 'semibold' : 'regular', color: t.color(unread ? 'app-ink' : 'app-ink-3'))),
                      ]),
                      SizedBox(height: t.lenOf('0.15rem')),
                      if (value != null) ...[
                        Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('2xl'), weight: 'semibold', color: t.color('app-ink'), mono: true, tracking: 2, height: 1.2)),
                        SizedBox(height: t.lenOf('0.15rem')),
                        Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: quiet),
                      ] else
                        Text(words, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: unread ? 'medium' : 'regular', color: t.color(unread ? 'app-ink' : 'app-ink-2'), height: 1.35)),
                      if (look.caption != null || look.word != null) ...[
                        SizedBox(height: t.lenOf('0.2rem')),
                        Row(children: [
                          if (look.caption != null) Flexible(child: Text(look.caption!, maxLines: 1, overflow: TextOverflow.ellipsis, style: quiet)),
                          if (look.caption != null && look.word != null) Text('  ·  ', style: quiet),
                          if (look.word != null && !selecting)
                            GlacierPressable(
                              onPressed: () => look.word!.run(host),
                              semanticLabel: look.word!.label,
                              builder: (context, state) => Text(
                                look.word!.label,
                                style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color(state.pressed ? 'app-ink-3' : 'app-ink'), height: 1.35).copyWith(decoration: TextDecoration.underline),
                              ),
                            ),
                        ]),
                      ],
                    ],
                  ),
                ),
                if (look.end != null && !selecting) ...[
                  SizedBox(width: t.space(1)),
                  IconTap(icon: look.end!.icon, label: look.end!.label, size: 19, color: t.color('app-ink-2'), onPressed: () => look.end!.run(host)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A quiet line or two for a widget slot: what a section is, over its list.
class PluginNote extends StatelessWidget {
  const PluginNote(this.words, {super.key});
  final String words;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(2)),
      child: Text(words, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4)),
    );
  }
}

/// A company's face on a row (plugin.dart, RowFace): a disc of its own colour with its mark on it where the app
/// has one, else its name's first letter, in white or in ink, whichever reads on that colour.
class BrandFace extends StatelessWidget {
  const BrandFace({super.key, required this.face, required this.size});
  final RowFace face;
  final double size;

  /// Whether ink reads better than white on [color] (0xRRGGBB): by how light the colour is to the eye.
  static bool inkOn(int color) {
    double part(int c) {
      final v = c / 255;
      return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    }

    final light = 0.2126 * part((color >> 16) & 0xff) + 0.7152 * part((color >> 8) & 0xff) + 0.0722 * part(color & 0xff);
    return light > 0.5;
  }

  /// How much of the disc's width a mark's square takes. A company's name written out ("coinbase", "DISCOVER") is
  /// wide and low and can run nearly the disc's width; a badge that fills its square has to stay inside the round.
  static double markShare(String mark) {
    final box = svgPath(mark).getBounds();
    return box.height < box.width * 0.5 ? 0.78 : 0.56;
  }

  /// The letter that stands for [name]: its first letter or figure.
  static String letterOf(String name) {
    final m = RegExp('[A-Za-z0-9]').firstMatch(name);
    return m == null ? '?' : m.group(0)!.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = Color(0xFF000000 | face.color);
    return Semantics(
      label: face.name,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color, border: Border.all(color: t.color('app-rule'), width: 1)),
        alignment: Alignment.center,
        // Our own codes wear the app's mark, white on black, as the icon on the home screen has it: as wide as its
        // corners leave room for in the circle.
        child: face.domain == ghostDomain
            ? Image.asset('assets/art/ghost-mark.png', width: size * 0.74, height: size * 0.74, filterQuality: FilterQuality.medium)
            : face.mark != null
            ? CustomPaint(size: Size.square(size * markShare(face.mark!)), painter: _MarkPainter(face.mark!, inkOn(face.color) ? const Color(0xFF111111) : const Color(0xFFFFFFFF)))
            : Text(
                letterOf(face.name),
                style: pageText(t, size * 0.44, weight: 'bold', color: inkOn(face.color) ? const Color(0xFF111111) : const Color(0xFFFFFFFF), height: 1),
              ),
      ),
    );
  }
}

/// A company's mark: one filled path on a 24 by 24 square, drawn to fit.
class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.mark, this.color);
  final String mark;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(svgPath(mark), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.mark != mark || old.color != color;
}
