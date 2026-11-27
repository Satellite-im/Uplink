import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../effects.dart';
import '../kit/settings_type.dart';
import 'common.dart';
import '../kit/semantic_colors.dart';

/// What a long press on a message brings up, beside the message itself (Matt, 2026-11-13: "I want the message
/// reactions to pop up under the message like imessage does", and "I'd like to be able to react with full screen
/// effects by pressing and holding on a message as well"): the reactions in a row under the bubble, what else can be
/// done with the message under those, the screen effects behind that menu's "Effects". The page dims round the
/// message, which stays lit. With no room under the bubble, it all sits above it.
Future<void> showMessagePopover(
  BuildContext context, {
  required Rect bubble,
  required bool outgoing,
  List<String> reactions = const [],
  Set<String> mine = const {},
  ValueChanged<String>? onReact,
  List<ScreenEffect> effects = const [],
  ValueChanged<ScreenEffect>? onEffect,
  required List<Choice> choices,
}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: const Color(0x00000000),
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 130),
    pageBuilder: (context, animation, _) => _Popover(
      animation: animation,
      bubble: bubble,
      outgoing: outgoing,
      reactions: reactions,
      mine: mine,
      onReact: onReact,
      effects: effects,
      onEffect: onEffect,
      choices: choices,
    ),
  ));
}

/// The popover's page: the scrim, then the reactions and the menu placed beside [bubble], coming in with [animation].
class _Popover extends StatelessWidget {
  const _Popover({required this.animation, required this.bubble, required this.outgoing, required this.reactions, required this.mine, required this.onReact, required this.effects, required this.onEffect, required this.choices});
  final Animation<double> animation;
  final Rect bubble;
  final bool outgoing;
  final List<String> reactions;
  final Set<String> mine;
  final ValueChanged<String>? onReact;
  final List<ScreenEffect> effects;
  final ValueChanged<ScreenEffect>? onEffect;
  final List<Choice> choices;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final screen = MediaQuery.sizeOf(context);
    final side = t.lenOf('2.5rem');
    final surface = BoxDecoration(color: t.color('app-paper-2'), border: Border.all(color: t.color('app-rule')), boxShadow: t.shadowOf('0 8px 28px rgba(0,0,0,0.22)'));
    void close() => Navigator.of(context).pop();

    Widget pill(List<Widget> children, {Widget? lead}) => DecoratedBox(
          decoration: surface.copyWith(borderRadius: BorderRadius.circular(side)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(side),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.all(t.space(1)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [?lead, ...children]),
            ),
          ),
        );

    Widget round(String emoji, String label, bool chosen, VoidCallback onPress) => GlacierPressable(
          onPressed: () {
            close();
            onPress();
          },
          semanticLabel: label,
          builder: (context, state) => AnimatedScale(
            scale: state.pressed ? 1.25 : 1,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: side,
              height: side,
              margin: EdgeInsets.symmetric(horizontal: t.lenOf('0.1rem')),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: chosen ? t.chosenWash : const Color(0x00000000),
                border: chosen ? Border.all(color: t.chosen, width: 2) : null,
              ),
              alignment: Alignment.center,
              child: Text(emoji, style: pageText(t, t.lenOf('1.4rem'), height: 1.15)),
            ),
          ),
        );

    final panel = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (reactions.isNotEmpty && onReact != null) pill([for (final e in reactions) round(e, mine.contains(e) ? 'Remove $e' : 'React $e', mine.contains(e), () => onReact!(e))]),
        // What can be done with the message; the screen effects are one item of it, which opens them in its place
        // (Matt, 2026-11-14: "Message effects should be under a literal effects item on thr message context that
        // opens a sub context to the effects not a row of effect icons").
        if (choices.isNotEmpty || (effects.isNotEmpty && onEffect != null)) ...[
          SizedBox(height: t.space(2)),
          _Menu(choices: choices, effects: onEffect == null ? const [] : effects, mine: mine, onEffect: onEffect, close: close, surface: surface),
        ],
      ],
    );

    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    return Stack(children: [
      // The page dims, the message stays lit; a tap anywhere outside puts it all away.
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: close,
          child: FadeTransition(opacity: animation, child: CustomPaint(painter: _Scrim(bubble, t.radius('lg'), t.menuScrim))),
        ),
      ),
      Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: _Beside(bubble: bubble, outgoing: outgoing, safe: EdgeInsets.fromLTRB(8, pad.top + 8, 8, pad.bottom + 8), gap: t.space(2)),
          child: FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween(begin: 0.8, end: 1.0).animate(curved),
              alignment: outgoing ? Alignment.topRight : Alignment.topLeft,
              child: ConstrainedBox(constraints: BoxConstraints(maxWidth: math.min(360, screen.width - 16)), child: panel),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// Where the popover sits: under the bubble on the bubble's own side, above it when there is no room under, and
/// inside the screen whatever the bubble's size.
class _Beside extends SingleChildLayoutDelegate {
  _Beside({required this.bubble, required this.outgoing, required this.safe, required this.gap});
  final Rect bubble;
  final bool outgoing;
  final EdgeInsets safe;
  final double gap;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(Size(constraints.maxWidth - safe.horizontal, constraints.maxHeight - safe.vertical));

  @override
  Offset getPositionForChild(Size size, Size child) {
    final x = (outgoing ? bubble.right - child.width : bubble.left).clamp(safe.left, math.max(safe.left, size.width - safe.right - child.width));
    final under = bubble.bottom + gap;
    final over = bubble.top - gap - child.height;
    final lowest = size.height - safe.bottom - child.height;
    final y = under <= lowest ? under : (over >= safe.top ? over : lowest.clamp(safe.top, math.max(safe.top, lowest)));
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRelayout(_Beside old) => old.bubble != bubble || old.outgoing != outgoing || old.safe != safe;
}

/// The dimmed page, with the message's own place left clear.
class _Scrim extends CustomPainter {
  _Scrim(this.bubble, this.radius, this.color);
  final Rect bubble;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = RRect.fromRectAndRadius(bubble.inflate(4), Radius.circular(radius + 4));
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRRect(hole)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_Scrim old) => old.bubble != bubble || old.color != color;
}

/// What can be done with a held message, as a list. "Effects" among it opens the screen effects in the list's own
/// place, each by its name, with the way back at the top: a menu inside the menu, where a row of the effects'
/// pictures used to hang under it.
class _Menu extends StatefulWidget {
  const _Menu({required this.choices, required this.effects, required this.mine, required this.onEffect, required this.close, required this.surface});
  final List<Choice> choices;
  final List<ScreenEffect> effects;
  final Set<String> mine;
  final ValueChanged<ScreenEffect>? onEffect;
  final VoidCallback close;
  final BoxDecoration surface;

  @override
  State<_Menu> createState() => _MenuState();
}

class _MenuState extends State<_Menu> {
  bool _effects = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    Widget row(String label, {Widget? lead, Widget? trail, required VoidCallback onPress, bool danger = false, String? says}) => GlacierPressable(
          onPressed: onPress,
          semanticLabel: says,
          builder: (context, state) {
            final ink = danger ? t.danger : t.color('app-ink');
            return ColoredBox(
              color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.lenOf('0.7rem')),
                child: Row(children: [
                  if (lead != null) ...[lead, SizedBox(width: t.space(3))],
                  Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: ink))),
                  if (trail != null) ...[SizedBox(width: t.space(3)), trail],
                ]),
              ),
            );
          },
        );

    Widget choice(Choice c) => row(
          c.label,
          trail: AppIcon(c.icon, size: 18, color: c.danger ? t.danger : t.color('app-ink')),
          danger: c.danger,
          onPress: () {
            widget.close();
            c.onPress();
          },
        );

    final Widget page;
    if (!_effects) {
      page = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in widget.choices.where((c) => !c.danger)) choice(c),
        // Above what deletes, under what does not.
        if (widget.effects.isNotEmpty)
          row(
            'Effects',
            says: 'Effects: react with one over the whole screen',
            trail: Row(mainAxisSize: MainAxisSize.min, children: [
              AppIcon(Lucide.sparkles, size: 18, color: t.color('app-ink')),
              SizedBox(width: t.space(1)),
              AppIcon(Lucide.chevronRight, size: 16, color: t.color('app-ink-3')),
            ]),
            onPress: () => setState(() => _effects = true),
          ),
        for (final c in widget.choices.where((c) => c.danger)) choice(c),
      ]);
    } else {
      page = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        row(
          'Effects',
          says: 'Back to the menu',
          lead: AppIcon(Lucide.chevronLeft, size: 18, color: t.color('app-ink-3')),
          onPress: () => setState(() => _effects = false),
        ),
        Container(height: 1, color: t.color('app-rule')),
        // Twenty of them: the list scrolls inside the menu, which stays a menu's size.
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: t.lenOf('15rem')),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final e in widget.effects)
                row(
                  effectLabel(e),
                  says: widget.mine.contains(effectReactionEmoji[e]) ? 'Take back ${effectLabel(e)}' : 'React with ${effectLabel(e)}, over the whole screen',
                  lead: SizedBox(width: t.lenOf('1.5rem'), child: Text(effectReactionEmoji[e]!, textAlign: TextAlign.center, style: pageText(t, t.lenOf('1.15rem'), height: 1.15))),
                  trail: widget.mine.contains(effectReactionEmoji[e]) ? AppIcon(Lucide.check, size: 16, color: t.chosen) : null,
                  onPress: () {
                    widget.close();
                    widget.onEffect?.call(e);
                  },
                ),
            ],
          ),
        ),
      ]);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: DecoratedBox(
        decoration: widget.surface.copyWith(borderRadius: BorderRadius.circular(t.radius('lg'))),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(t.radius('lg')),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: KeyedSubtree(key: ValueKey(_effects), child: page),
          ),
        ),
      ),
    );
  }
}
