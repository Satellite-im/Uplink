import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../haptics/haptics.dart' show HapticKind;
import '../tokens/oklch.dart';
import '../tokens/theme.dart';
import 'input.dart';
import 'field_core.dart';
import 'pressable.dart';

/// `size` of a [GlacierColorPicker].
enum GlacierColorPickerSize { sm, md }

/// Port of `@glacier/react`'s `ColorPicker`: an OKLCH colour picker.
///
/// OKLCH, the space the kit's own ramps are authored in, so a colour's lightness means the same at every hue. Three
/// labelled sliders (lightness, chroma, hue), each painting the gradient it actually traverses, then a swatch, a hex
/// field and any [presets] as swatches to tap. A colour outside sRGB is named under the swatch rather than silently
/// clamped.
///
/// Controlled with [value] (hex, `#RRGGBB`) and [onValueChange], or uncontrolled from [defaultValue]. Reports hex.
///
/// What differs from the React original:
/// - `format: 'oklch'`, `alpha` and `skeleton` are not ported: the picker reports hex, opaque.
/// - [onChangeEnd] is an addition: it fires once a drag ends, so a caller can save then rather than on every frame.
class GlacierColorPicker extends StatefulWidget {
  const GlacierColorPicker({
    super.key,
    this.value,
    this.defaultValue = '#5B7CFA',
    this.onValueChange,
    this.onChangeEnd,
    this.presets = const [],
    this.size = GlacierColorPickerSize.md,
    this.disabled = false,
  });

  final String? value;
  final String defaultValue;
  final ValueChanged<String>? onValueChange;
  final ValueChanged<String>? onChangeEnd;
  final List<String> presets;
  final GlacierColorPickerSize size;
  final bool disabled;

  @override
  State<GlacierColorPicker> createState() => _GlacierColorPickerState();
}

/// Six hex digits, with or without `#`, as an opaque colour; null for anything else.
Color? _parseHex(String text) {
  final h = text.trim().replaceFirst('#', '');
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// A colour as `#RRGGBB`, in capitals: what the picker reports.
String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

class _GlacierColorPickerState extends State<GlacierColorPicker> {
  /// The colour the sliders stand at. Kept in OKLCH, not read back from the hex, so a hue or a chroma the hex
  /// cannot carry (a grey's hue) stays where the person put it.
  late Oklch _colour = Oklch.fromColor(_parseHex(widget.value ?? widget.defaultValue) ?? const Color(0xFF5B7CFA));

  /// The hex last told to the listener: the same value coming back down is not news.
  String? _lastReported;

  @override
  void didUpdateWidget(GlacierColorPicker old) {
    super.didUpdateWidget(old);
    final v = widget.value;
    // A new value from outside (not the one this picker just reported) moves the sliders.
    if (v != null && v != _lastReported && v != old.value) {
      final c = _parseHex(v);
      if (c != null) _colour = Oklch.fromColor(c);
    }
  }

  /// Takes a colour and reports it as hex; [end] says the change is finished (a drag let go, a preset, a hex typed).
  void _set(Oklch next, {bool end = false}) {
    setState(() => _colour = next);
    final hex = _hex(next.toColor());
    _lastReported = hex;
    widget.onValueChange?.call(hex);
    if (end) widget.onChangeEnd?.call(hex);
  }

  /// Whether the colour asked for lies outside what sRGB can show: its round trip comes back different.
  bool get _outOfGamut {
    final back = Oklch.fromColor(_colour.toColor());
    return (back.l - _colour.l).abs() > 0.01 || (back.c - _colour.c).abs() > 0.01;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final sm = widget.size == GlacierColorPickerSize.sm;
    final gap = t.space(sm ? 2 : 3);
    final c = _colour;
    final swatch = c.toColor();
    return Opacity(
      opacity: widget.disabled ? 0.5 : 1,
      child: IgnorePointer(
        ignoring: widget.disabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Channel(
              label: 'Lightness',
              value: c.l,
              min: 0,
              max: 1,
              readout: '${(c.l * 100).round()}%',
              paint: (v) => Oklch(v, c.c, c.h).toColor(),
              onChanged: (v, end) => _set(Oklch(v, c.c, c.h), end: end),
              sm: sm,
            ),
            SizedBox(height: gap),
            _Channel(
              label: 'Chroma',
              value: c.c.clamp(0.0, 0.37),
              min: 0,
              max: 0.37,
              readout: c.c.toStringAsFixed(3),
              paint: (v) => Oklch(c.l, v, c.h).toColor(),
              onChanged: (v, end) => _set(Oklch(c.l, v, c.h), end: end),
              sm: sm,
            ),
            SizedBox(height: gap),
            _Channel(
              label: 'Hue',
              value: c.h,
              min: 0,
              max: 360,
              readout: '${c.h.round()}°',
              // A near-grey has no hue to show, so its track is painted with some chroma lent to it.
              paint: (v) => Oklch(c.l, c.c < 0.04 ? 0.12 : c.c, v).toColor(),
              onChanged: (v, end) => _set(Oklch(c.l, c.c, v), end: end),
              sm: sm,
            ),
            SizedBox(height: gap + t.space(1)),
            Row(
              children: [
                Container(
                  width: sm ? 32 : 40,
                  height: sm ? 32 : 40,
                  decoration: BoxDecoration(
                    color: swatch,
                    borderRadius: BorderRadius.circular(t.radius('md')),
                    border: Border.all(color: t.color('glacier-border-strong')),
                  ),
                ),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: GlacierInput(
                    key: ValueKey(_hex(swatch)),
                    size: sm ? GlacierFieldSize.sm : GlacierFieldSize.md,
                    defaultValue: _hex(swatch),
                    autoCapitalize: TextCapitalization.characters,
                    ariaLabel: 'Hex colour',
                    onSubmitted: (text) {
                      final parsed = _parseHex(text);
                      if (parsed != null) _set(Oklch.fromColor(parsed), end: true);
                    },
                  ),
                ),
              ],
            ),
            if (_outOfGamut) ...[
              SizedBox(height: t.space(1)),
              Text('Outside sRGB: shown as the nearest colour a screen can draw.', style: TextStyle(fontSize: 12, color: t.color('glacier-text-muted'))),
            ],
            if (widget.presets.isNotEmpty) ...[
              SizedBox(height: gap),
              Wrap(
                spacing: t.space(2),
                runSpacing: t.space(2),
                children: [
                  for (final p in widget.presets)
                    if (_parseHex(p) case final pc?)
                      GlacierPressable(
                        onPressed: () => _set(Oklch.fromColor(pc), end: true),
                        haptic: HapticKind.selection,
                        semanticLabel: _hex(pc),
                        builder: (context, state) => Container(
                          width: sm ? 24 : 28,
                          height: sm ? 24 : 28,
                          decoration: BoxDecoration(
                            color: pc,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _hex(pc) == _hex(swatch) ? t.color('glacier-text') : t.color('glacier-border'),
                              width: _hex(pc) == _hex(swatch) ? 2 : 1,
                            ),
                          ),
                        ),
                      ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One slider: its label and readout over a track painted with the colours it passes through.
class _Channel extends StatelessWidget {
  const _Channel({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.readout,
    required this.paint,
    required this.onChanged,
    required this.sm,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String readout;
  final Color Function(double) paint;
  final void Function(double value, bool end) onChanged;
  final bool sm;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final trackH = sm ? 14.0 : 18.0;
    final thumb = trackH + 8;
    final stops = [for (var i = 0; i <= 24; i++) paint(min + (max - min) * i / 24)];
    return Semantics(
      label: label,
      value: readout,
      slider: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(fontSize: sm ? 12 : 13, color: t.color('glacier-text-muted'))),
              const Spacer(),
              Text(readout, style: TextStyle(fontSize: sm ? 12 : 13, color: t.color('glacier-text-subtle'), fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
          SizedBox(height: t.space(1)),
          LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final usable = (w - thumb).clamp(1.0, double.infinity);
              // The value under a touch: the thumb's centre runs from half a thumb in to half a thumb short.
              double at(double dx) => (min + ((dx - thumb / 2) / usable).clamp(0.0, 1.0) * (max - min));
              final f = ((value - min) / (max - min)).clamp(0.0, 1.0);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                dragStartBehavior: DragStartBehavior.down,
                onTapDown: (d) => onChanged(at(d.localPosition.dx), false),
                onTapUp: (d) => onChanged(at(d.localPosition.dx), true),
                onHorizontalDragUpdate: (d) => onChanged(at(d.localPosition.dx), false),
                onHorizontalDragEnd: (_) => onChanged(value, true),
                child: SizedBox(
                  height: thumb,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: thumb / 2 - trackH / 2,
                        right: thumb / 2 - trackH / 2,
                        top: (thumb - trackH) / 2,
                        height: trackH,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: stops),
                            borderRadius: BorderRadius.circular(trackH / 2),
                            border: Border.all(color: t.color('glacier-border')),
                          ),
                        ),
                      ),
                      Positioned(
                        left: f * usable,
                        top: 0,
                        width: thumb,
                        height: thumb,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: paint(value),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFFFFFFF), width: 3),
                            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 1))],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
