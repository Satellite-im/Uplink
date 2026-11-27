import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';

/// The size of all the app's words, chosen in Settings › Appearance › Text (GMFB-41, from the Uplink gap review: "a
/// text-size slider"): [AppState.textPercent], 80% to 150%, laid over everything the app draws by multiplying what
/// the device itself asks for (Android's and iOS's own font size, a browser's). Put under each app's root (lib/main.dart,
/// lib/desktop/main.dart, lib/web/app.dart), above the pages, so sheets, menus and toasts are sized with them.
///
/// At 100% nothing is put in the way: the page is drawn exactly as it was before there was a choice.
class AppTextScale extends StatelessWidget {
  const AppTextScale({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final by = (AppState.maybeOf(context)?.textPercent ?? 100) / 100;
    if (by == 1) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(data: media.copyWith(textScaler: ScaledBy(media.textScaler, by)), child: child);
  }
}

/// The device's own scaling of a size ([device], which on Android 14 is not one number: large sizes grow less), and
/// then the app's own [by] on top of it.
class ScaledBy extends TextScaler {
  const ScaledBy(this.device, this.by);
  final TextScaler device;
  final double by;

  @override
  double scale(double fontSize) => device.scale(fontSize) * by;

  @override
  // ignore: deprecated_member_use
  double get textScaleFactor => device.textScaleFactor * by;

  @override
  bool operator ==(Object other) => other is ScaledBy && other.device == device && other.by == by;

  @override
  int get hashCode => Object.hash(device, by);

  @override
  String toString() => '$device × $by';
}

/// The text size from [AppState.textSmallest] to [AppState.textLargest] percent in steps of five, dragged or tapped
/// along its track, with 100% marked: drawn as the loudness sliders are (lib/ui/voice_screen.dart VolumeSlider),
/// whose track starts at nothing and marks its middle.
class TextSizeSlider extends StatelessWidget {
  const TextSizeSlider({super.key, required this.percent, required this.onChanged});
  final int percent;
  final ValueChanged<int> onChanged;

  static const _least = AppState.textSmallest, _most = AppState.textLargest;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    int step(int by) => AppState.textStep(percent + by);
    return Semantics(
      label: 'Text size',
      value: '$percent%',
      increasedValue: '${step(5)}%',
      decreasedValue: '${step(-5)}%',
      onIncrease: () => onChanged(step(5)),
      onDecrease: () => onChanged(step(-5)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        void at(double x) => onChanged(AppState.textStep(_least + (x / w).clamp(0.0, 1.0) * (_most - _least)));
        double along(int p) => (p - _least) / (_most - _least);
        final frac = along(percent).clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => at(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
          child: SizedBox(
            height: 32,
            child: Stack(alignment: AlignmentDirectional.centerStart, children: [
              Container(height: 6, decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(3))),
              Container(width: w * frac, height: 6, decoration: BoxDecoration(color: t.color('app-accent'), borderRadius: BorderRadius.circular(3))),
              PositionedDirectional(start: w * along(100) - 1, child: Container(width: 2, height: 12, color: t.color('app-ink-4'))),
              PositionedDirectional(
                start: (w * frac - 11).clamp(0.0, w - 22),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('app-paper'), border: Border.all(color: t.color('app-accent'), width: 2), boxShadow: t.shadowOf('0 1px 4px rgba(0,0,0,0.2)')),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }
}
