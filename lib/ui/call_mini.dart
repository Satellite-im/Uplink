import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../desktop/mini_window.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../voice/channels.dart' show Voice;
import 'common.dart' show toast;
import 'ripple_avatar.dart' show RippleAvatar;
import 'voice_screen.dart' show sayMicLocked;
import 'window_chrome.dart' show WindowDragArea;

/// What the mini window (lib/desktop/mini_window.dart, GMFB-41: "An always-on-top call overlay for games on desktop")
/// is and says.
abstract final class MiniWords {
  static const enter = 'Mini window', back = 'Back to the full window', leave = 'Leave the call';
  static const cant = 'The window can\'t be made small right now. Leave full screen first.';
}

/// Makes the window the call's mini window, or says why it couldn't be: what the dock's button and the shortcut do.
Future<void> toggleCallMini(BuildContext context) async {
  final was = CallMini.instance.on;
  final now = await CallMini.instance.toggle();
  if (!was && !now && context.mounted && Voice.instance.session != null) toast(context, MiniWords.cant);
}

/// Over the whole app, the computer's window at its root (lib/desktop/main.dart): [child] as ever, or, while the
/// window is the mini window ([CallMini.on]), the call's faces and buttons in its place ([mini], [CallMiniView] but for
/// a test). [child] stays in the tree all the while, laid out at the size the window had and not drawn, its tickers
/// still, so nothing in it is lost or squeezed into the small window.
class CallMiniFrame extends StatefulWidget {
  const CallMiniFrame({super.key, required this.child, this.controller, this.mini});
  final Widget child;
  final CallMini? controller;
  final WidgetBuilder? mini;

  @override
  State<CallMiniFrame> createState() => _CallMiniFrameState();
}

class _CallMiniFrameState extends State<CallMiniFrame> {
  /// The window's size before it was made small: what [CallMiniFrame.child] is laid out at meanwhile.
  Size? _full;

  CallMini get _mini => widget.controller ?? CallMini.instance;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _mini,
        builder: (context, _) {
          final on = _mini.on;
          final now = MediaQuery.sizeOf(context);
          // Kept while the window is its own size; while it is small, the last of those.
          if (!on || _full == null) _full = now;
          final full = _full!;
          // The same widgets either way, so the app under it is never built anew: only their settings change.
          return Stack(children: [
            Positioned.fill(
              child: Offstage(
                offstage: on,
                child: TickerMode(
                  enabled: !on,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.topStart,
                      minWidth: on ? full.width : null,
                      maxWidth: on ? full.width : null,
                      minHeight: on ? full.height : null,
                      maxHeight: on ? full.height : null,
                      child: MediaQuery(data: on ? MediaQuery.of(context).copyWith(size: full) : MediaQuery.of(context), child: widget.child),
                    ),
                  ),
                ),
              ),
            ),
            if (on) Positioned.fill(key: const ValueKey('call-mini'), child: (widget.mini ?? (_) => const CallMiniView())(context)),
          ]);
        },
      );
}

/// The mini window's page: the call's name and Back to the full window along the top (the window is moved by it on a
/// Mac, whose three buttons are hidden meanwhile), the faces rippling as each talks, and Mute, Deafen and Leave.
class CallMiniView extends StatelessWidget {
  const CallMiniView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: ListenableBuilder(
        listenable: v,
        builder: (context, _) {
          final s = v.session;
          if (s == null) return const SizedBox.shrink();
          final levels = v.media?.levels ?? s.media.levels;
          return ListenableBuilder(
            listenable: Listenable.merge([s, levels]),
            builder: (context, _) {
              final loud = levels.value;
              final people = [
                (id: 'me', name: s.name.isEmpty ? 'You' : s.name, muted: s.muted || s.deafened),
                for (final m in s.members.values) (id: m.id, name: v.nameOf(m.id), muted: m.muted || v.silenced(m.id)),
              ];
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                WindowDragArea(
                  child: Container(
                    height: 34,
                    padding: EdgeInsetsDirectional.only(start: t.space(3), end: t.space(1)),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.color('app-rule')))),
                    child: Row(children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: t.online)),
                      SizedBox(width: t.space(2)),
                      Expanded(child: Text(s.channel.name, key: const ValueKey('call-mini-name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink')))),
                      _MiniButton(key: const ValueKey('call-mini-back'), icon: Lucide.maximize, label: MiniWords.back, size: 28, onPressed: () => unawaited(CallMini.instance.leave())),
                    ]),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(3)),
                    child: Wrap(alignment: WrapAlignment.center, spacing: t.space(3), runSpacing: t.space(2), children: [
                      for (final p in people)
                        SizedBox(
                          key: ValueKey('call-mini-face-${p.id}'),
                          width: 52,
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            RippleAvatar(name: p.name, level: p.muted ? 0 : (loud[p.id] ?? 0), muted: p.muted, size: 40),
                            SizedBox(height: t.space(1)),
                            Text(p.id == 'me' ? 'You' : p.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-2'))),
                          ]),
                        ),
                    ]),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(bottom: t.space(3)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, spacing: t.space(3), children: [
                    _MiniButton(
                      key: const ValueKey('call-mini-mute'),
                      icon: s.muted ? LucideMore.micOff : Lucide.mic,
                      label: s.muted ? 'Unmute' : 'Mute',
                      on: s.muted,
                      onPressed: () => s.locked ? sayMicLocked(context, s) : s.setMuted(!s.muted),
                    ),
                    _MiniButton(
                      key: const ValueKey('call-mini-deafen'),
                      icon: s.deafened ? LucideMore.headphoneOff : LucideMore.headphones,
                      label: s.deafened ? 'Hear again' : 'Deafen',
                      on: s.deafened,
                      onPressed: () => s.setDeafened(!s.deafened),
                    ),
                    _MiniButton(key: const ValueKey('call-mini-leave'), icon: LucideMore.phoneOff, label: MiniWords.leave, danger: true, onPressed: () => unawaited(Voice.instance.leave())),
                  ]),
                ),
              ]);
            },
          );
        },
      ),
    );
  }
}

/// A round button of the mini window's: [on] filled in ink, [danger] in red.
class _MiniButton extends StatelessWidget {
  const _MiniButton({super.key, required this.icon, required this.label, required this.onPressed, this.on = false, this.danger = false, this.size = 40});
  final LucideIcon icon;
  final String label;
  final VoidCallback onPressed;
  final bool on, danger;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: danger ? t.danger.withValues(alpha: state.pressed ? 0.8 : 1) : (on ? t.color('app-ink') : t.color(state.pressed || state.hovered ? 'app-paper-3' : 'app-paper-2')),
        ),
        child: AppIcon(icon, size: size * 0.45, wash: false, color: danger ? const Color(0xFFFFFFFF) : (on ? t.color('app-paper') : t.color('app-ink'))),
      ),
    );
  }
}
