import '../../ui/souls.dart' show SoulsChip, showSouls;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../kit/settings_type.dart';
import '../../ui/dialup/bevel.dart' show DialupColors, isBevelChrome;
import '../../ui/feedback_screen.dart';
import '../../ui/window_chrome.dart';
import '../../ui/window_title.dart';

/// The Mac window's title strip (Matt, 2026-11-19: "I want the top bar where we drag like the window titlebar to house
/// these buttons we can roll a custom titlebar if we need to that's a bit thicker to fit the content"): across the
/// whole window above every page, in the look's colours, the three window buttons centred at its left
/// (macos/Runner/MainFlutterWindow.swift places them by the height said here), in the middle the name of what is open
/// (the circle, the conversation, or the app's own with neither: lib/ui/window_title.dart), and the
/// app's own buttons at its right: Share feedback, and whatever else is put in [extras]. Pressed and dragged anywhere
/// else it moves the window; a double click zooms it, as a title bar does ([WindowDragArea]).
class DeskTitleBar extends StatelessWidget {
  const DeskTitleBar({super.key, required this.navigator});

  /// The app's navigator: the strip stands above it, so what its buttons open goes there.
  final GlobalKey<NavigatorState> navigator;

  /// How tall the strip is: a little more than the Mac's own, to fit buttons.
  static const double height = 40;

  /// More buttons for the strip's right end, before Share feedback, each made with the app's navigator.
  static final List<Widget Function(BuildContext context, GlobalKey<NavigatorState> navigator)> extras = [];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: MacChrome.covered,
        // Nothing of it under a video at full screen, which is drawn over the pages below this strip alone.
        builder: (context, covered, _) => covered ? const SizedBox.shrink() : _strip(context),
      );

  Widget _strip(BuildContext context) {
    final t = context.tokens;
    final dialup = isBevelChrome(t);
    final ground = dialup ? DialupColors.of(t).chrome : t.color('glacier-bg');
    MacChrome.sayStrip(height: height, dark: ground.computeLuminance() < 0.4);
    final room = t.space(1);
    return WindowDragArea(
      child: Container(
        key: const ValueKey('desk-title-bar'),
        height: height,
        decoration: BoxDecoration(color: ground, border: Border(bottom: BorderSide(color: t.color('app-rule')))),
        padding: EdgeInsetsDirectional.only(start: MacChrome.lightsRoom, end: t.space(2)),
        child: Row(children: [
          Expanded(
            child: Center(
              // The circle or conversation that is open, where one is, and the app's name otherwise (Matt,
              // 2026-11-24: "show the active circle or conversation name in the titlebar where the "ghost messaging"
              // title is"; lib/ui/window_title.dart). The window is told too, for the Window menu and Mission Control.
              child: ValueListenableBuilder<String?>(
                valueListenable: WindowTitle.now,
                builder: (context, open, _) {
                  final name = open ?? WindowTitle.app;
                  MacChrome.sayTitle(name);
                  return Text(name, key: const ValueKey('desk-title'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color(open == null ? 'app-ink-3' : 'app-ink-2')));
                },
              ),
            ),
          ),
          for (final make in extras) Padding(padding: EdgeInsetsDirectional.only(start: room), child: make(context, navigator)),
          // Souls, with their flame, beside Share feedback (lib/ui/souls.dart; Matt, 2026-11-19).
          Padding(
            padding: EdgeInsetsDirectional.only(start: room),
            child: SoulsChip(
              side: 28,
              onOpen: () {
                final c = navigator.currentContext;
                if (c != null) showSouls(c);
              },
            ),
          ),
          Padding(
            padding: EdgeInsetsDirectional.only(start: room),
            child: FeedbackButton(
              side: 28,
              onOpen: () {
                final c = navigator.currentContext;
                if (c != null) FeedbackButton.open(c);
              },
            ),
          ),
        ]),
      ),
    );
  }
}
