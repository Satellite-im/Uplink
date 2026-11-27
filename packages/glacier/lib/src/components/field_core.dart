import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoTextSelectionControls, CupertinoTheme, CupertinoThemeData;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'pressable.dart';
import '../tokens/line_height.dart';
import '../plain.dart';

// What GlacierInput, GlacierSearchField, GlacierKbd and GlacierCommandPalette draw with and share: the kit's text in
// a browser's `line-height: normal`, a CSS box (background, border, ring, shadows, the glass highlight), the glass
// backdrop, and the `<input>` element itself. Nothing here is a component of the React kit; it is the part of the
// browser those components stood on.

/// `ControlSize` of the React kit (atoms/inputs/Button/Button.tsx), as the text fields take it.
enum GlacierFieldSize { sm, md, lg }

/// The kit's face at an exact size, with a browser's `line-height: normal` and no tracking unless asked: the text of
/// an `<input>` or a palette row, neither of which sits on the type scale's leading.
TextStyle kitFont(Tokens t, {required double fontSize, required Color color, String weight = 'regular', bool mono = false, double letterSpacing = 0}) {
  final fonts = t.families(mono ? 'glacier-font-mono' : 'glacier-font-sans');
  final face = TextStyle(
    fontFamily: fonts.isEmpty ? null : fonts.first,
    fontFamilyFallback: fonts.length > 1 ? fonts.sublist(1) : null,
    fontSize: fontSize,
    leadingDistribution: TextLeadingDistribution.even,
    letterSpacing: letterSpacing,
    fontWeight: t.weight(weight),
    fontVariations: [ui.FontVariation('wght', t.len('glacier-font-weight-$weight'))],
    color: color,
    decoration: TextDecoration.none,
  );
  return face.copyWith(height: normalLineHeight(face, dpr: t.css.lineDpr) / fontSize);
}

/// The font size text inherits where a stylesheet says `1em` and sets no size of its own: the surrounding text's, or
/// the root's 1rem where nothing has set one.
double inheritedFontSize(BuildContext context, Tokens t) => DefaultTextStyle.of(context).style.fontSize ?? t.css.rem;

/// CSS `saturate(s)`, row by row (Filter Effects 1).
List<double> _saturation(double s) => <double>[
  0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, //
  0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, //
  0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s,
];

/// CSS `saturate(s)` as a colour filter.
ui.ColorFilter saturateFilter(double s) {
  final m = _saturation(s);
  return ui.ColorFilter.matrix(<double>[m[0], m[1], m[2], 0, 0, m[3], m[4], m[5], 0, 0, m[6], m[7], m[8], 0, 0, 0, 0, 0, 1, 0]);
}

/// One colour as CSS `saturate(s)` leaves it.
Color saturated(Color color, double s) {
  final m = _saturation(s);
  double channel(int row) => (m[row * 3] * color.r + m[row * 3 + 1] * color.g + m[row * 3 + 2] * color.b).clamp(0.0, 1.0);
  return Color.from(alpha: color.a, red: channel(0), green: channel(1), blue: channel(2), colorSpace: color.colorSpace);
}

/// `backdrop-filter: blur(...) saturate(...)` behind a rounded box. [amount] fades the filter in, 0 to 1, for a
/// surface that enters: a backdrop filter under an [Opacity] has nothing behind it to blur, so glass fades by its
/// own strength and its paint's alpha instead.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key, required this.blur, this.saturate = 1, this.radius = 0, this.amount = 1});

  /// The blur's standard deviation in logical pixels, which is what CSS's `blur()` takes.
  final double blur;
  final double saturate;
  final double radius;
  final double amount;

  @override
  Widget build(BuildContext context) {
    if (amount <= 0) return const SizedBox.expand();
    final sigma = blur * amount;
    final strength = 1 + (saturate - 1) * amount;
    ui.ImageFilter filter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
    if (strength != 1) filter = ui.ImageFilter.compose(outer: saturateFilter(strength), inner: filter);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(enabled: !glacierPlain, filter: filter, child: const SizedBox.expand()),
    );
  }
}

/// A CSS box, painted as a stylesheet describes one: `background`, `border` (which may be thicker at the bottom, as
/// a `<kbd>`'s is), a `0 0 0 Npx` ring, blurred outer shadows, and the glass's `inset 0 Npx 0` highlight.
///
/// Flutter's own [BoxDecoration] paints a shadow under the whole box, which shows through a translucent one; CSS
/// never draws a shadow inside the border box, and neither does this.
class KitBoxPainter extends CustomPainter {
  const KitBoxPainter({
    required this.radius,
    this.fill,
    this.border,
    this.borderWidth = 0,
    this.borderBottomWidth,
    this.ring,
    this.ringSpread = 0,
    this.shadows = const [],
    this.highlight,
    this.highlightHeight = 0,
    this.highlightInsideBorder = true,
  });

  final double radius;
  final Color? fill;
  final Color? border;
  final double borderWidth;

  /// `border-bottom-width`, where it differs.
  final double? borderBottomWidth;
  final Color? ring;
  final double ringSpread;
  final List<BoxShadow> shadows;

  /// `box-shadow: inset 0 <highlightHeight> 0 <highlight>`.
  final Color? highlight;
  final double highlightHeight;

  /// An inset shadow starts at the padding box. False for a box whose border belongs to an element laid over it.
  final bool highlightInsideBorder;

  /// Whether a colour is there to be seen: given, and not wholly transparent.
  static bool _shows(Color? color) => color != null && color.a > 0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = radius.clamp(0.0, size.shortestSide / 2);
    final outer = RRect.fromRectAndRadius(rect, Radius.circular(r));
    final bottom = borderBottomWidth ?? borderWidth;
    final inner = RRect.fromLTRBAndCorners(
      rect.left + borderWidth,
      rect.top + borderWidth,
      rect.right - borderWidth,
      rect.bottom - bottom,
      topLeft: Radius.circular((r - borderWidth).clamp(0.0, double.infinity)),
      topRight: Radius.circular((r - borderWidth).clamp(0.0, double.infinity)),
      bottomLeft: Radius.elliptical((r - borderWidth).clamp(0.0, double.infinity), (r - bottom).clamp(0.0, double.infinity)),
      bottomRight: Radius.elliptical((r - borderWidth).clamp(0.0, double.infinity), (r - bottom).clamp(0.0, double.infinity)),
    );

    // Back to front, as CSS stacks them: outer shadows (kept out from under the box), the ring, the background,
    // the border, then the inset highlight.
    final blurred = shadows.where((s) => _shows(s.color)).toList();
    if (blurred.isNotEmpty) {
      var reach = 0.0;
      for (final s in blurred) {
        final extent = s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance;
        if (extent > reach) reach = extent;
      }
      canvas.save();
      canvas.clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(rect.inflate(reach + 1))
          ..addRRect(outer),
      );
      for (final s in blurred) {
        // CSS's blur radius is twice the Gaussian's deviation, exactly; [BoxShadow.toPaint] takes a wider one.
        final paint = Paint()..color = s.color;
        if (s.blurRadius > 0 && !debugDisableShadows) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurRadius / 2);
        canvas.drawRRect(outer.shift(s.offset).inflate(s.spreadRadius), paint);
      }
      canvas.restore();
    }
    if (_shows(ring) && ringSpread > 0) canvas.drawDRRect(outer.inflate(ringSpread), outer, Paint()..color = ring!);
    if (_shows(fill)) canvas.drawRRect(outer, Paint()..color = fill!);
    if (_shows(border) && (borderWidth > 0 || bottom > 0)) canvas.drawDRRect(outer, inner, Paint()..color = border!);
    if (_shows(highlight) && highlightHeight > 0) {
      final box = highlightInsideBorder ? inner : outer;
      canvas.save();
      canvas.clipRRect(box);
      canvas.drawDRRect(box.inflate(highlightHeight + 1), box.shift(Offset(0, highlightHeight)), Paint()..color = highlight!);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(KitBoxPainter old) =>
      old.radius != radius ||
      old.fill != fill ||
      old.border != border ||
      old.borderWidth != borderWidth ||
      old.borderBottomWidth != borderBottomWidth ||
      old.ring != ring ||
      old.ringSpread != ringSpread ||
      !listEquals(old.shadows, shadows) ||
      old.highlight != highlight ||
      old.highlightHeight != highlightHeight ||
      old.highlightInsideBorder != highlightInsideBorder;
}

/// What an `<input>` is doing, for the rules a stylesheet hangs on `:hover`, `:focus`, `:disabled` and
/// `[aria-invalid]`.
@immutable
class FieldStatus {
  const FieldStatus({this.hovered = false, this.focused = false, this.disabled = false, this.invalid = false});
  final bool hovered;

  /// `:focus`, from the keyboard or a tap alike.
  final bool focused;
  final bool disabled;
  final bool invalid;
}

/// How an `<input>` is painted in one [FieldStatus]: what its stylesheet's cascade comes to.
@immutable
class FieldLook {
  const FieldLook({
    required this.background,
    required this.border,
    required this.ring,
    this.ringSpread = 0,
    this.highlight = const Color(0x00000000),
    this.underlay = const Color(0x00000000),
    this.underlayHighlight = const Color(0x00000000),
    this.backdrop = false,
  });

  /// `background-color`, `border-color` and `box-shadow` are the three the stylesheets transition.
  final Color background;
  final Color border;

  /// `box-shadow: 0 0 0 <ringSpread> <ring>`.
  final Color ring;
  final double ringSpread;

  /// `box-shadow: inset 0 hairline 0 <highlight>` on the input itself (Input's glass).
  final Color highlight;

  /// The wrapper's own material behind the input (SearchField's glass): its background and its highlight. These do
  /// not transition and are not dimmed with a disabled input, being another element's.
  final Color underlay;
  final Color underlayHighlight;

  /// Whether the glass blurs what is behind the field.
  final bool backdrop;

  /// Between two colours as a transition runs between them. A colour that is not there at one end (`transparent`,
  /// or no shadow at all) is the other end's colour at no strength, which is what CSS's premultiplied mixing comes to;
  /// lerped from transparent black it would pass through a grey.
  static Color _between(Color a, Color b, double t) {
    final from = a.a == 0 ? b.withValues(alpha: 0) : a;
    final to = b.a == 0 ? a.withValues(alpha: 0) : b;
    return Color.lerp(from, to, t)!;
  }

  /// The look part of the way from [a] to [b]. Only what the stylesheets transition moves; the underlay and the
  /// backdrop are [b]'s from the start.
  static FieldLook lerp(FieldLook a, FieldLook b, double t) => FieldLook(
    background: _between(a.background, b.background, t),
    border: _between(a.border, b.border, t),
    ring: _between(a.ring, b.ring, t),
    ringSpread: a.ringSpread + (b.ringSpread - a.ringSpread) * t,
    highlight: _between(a.highlight, b.highlight, t),
    underlay: b.underlay,
    underlayHighlight: b.underlayHighlight,
    backdrop: b.backdrop,
  );

  @override
  bool operator ==(Object other) =>
      other is FieldLook &&
      other.background == background &&
      other.border == border &&
      other.ring == ring &&
      other.ringSpread == ringSpread &&
      other.highlight == highlight &&
      other.underlay == underlay &&
      other.underlayHighlight == underlayHighlight &&
      other.backdrop == backdrop;

  @override
  int get hashCode => Object.hash(background, border, ring, ringSpread, highlight, underlay, underlayHighlight, backdrop);
}

/// Runs a field's paint from the look it had to the one its state now asks for.
class _LookTween extends Tween<FieldLook> {
  _LookTween({super.end});

  @override
  FieldLook lerp(double t) => FieldLook.lerp(begin!, end!, t);
}

/// What the widgets laid over a field (a clear button, an icon) may ask of it.
class GlacierFieldHandle {
  GlacierFieldHandle._(this._state);
  final GlacierFieldCoreState _state;

  String get text => _state._controller.text;
  FieldStatus get status => _state._status;
  FocusNode get focusNode => _state._focus;

  /// What a component's own `setValue(next); onValueChange?.(next)` does: the field takes the text where it owns it,
  /// and the listener is told either way.
  void setValue(String next) => _state._setByComponent(next);
}

/// The `<input>` both text fields draw: an [EditableText] in the kit's box, with the placeholder, the selection and
/// caret colours, hover and focus for the stylesheet's states, the 150ms transitions on its border, background and
/// ring, and a value that is controlled ([value]) or its own ([defaultValue], or a [controller]).
///
/// Internal to the kit: GlacierInput and GlacierSearchField are the components, and each hands this its own
/// stylesheet's cascade as [look] and its adornments as [overlay].
class GlacierFieldCore extends StatefulWidget {
  const GlacierFieldCore({
    super.key,
    required this.size,
    required this.paddingStart,
    required this.paddingEnd,
    required this.look,
    this.overlay,
    this.value,
    this.defaultValue = '',
    this.onChanged,
    this.controller,
    this.focusNode,
    this.placeholder,
    this.disabled = false,
    this.readOnly = false,
    this.invalid = false,
    this.autoFocus = false,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.spellCheck,
    this.autofillHints,
    this.maxLength,
    this.inputFormatters,
    this.onSubmitted,
    this.onEditingComplete,
    this.onKeyEvent,
    this.onFocusChange,
    this.semanticLabel,
    this.semanticHint,
    this.semanticIdentifier,
    this.semanticExpanded,
    this.semanticControls,
    this.selectionControls,
    this.contextMenuBuilder,
    this.textStyle,
    this.placeholderStyle,
    this.radius,
  }) : assert(value == null || controller == null, 'A field is controlled by its value or by a controller, not both.');

  final GlacierFieldSize size;

  /// `padding-inline-start` and `-end`, inside the border.
  final double paddingStart;
  final double paddingEnd;

  /// The component's stylesheet, as a function of the field's state.
  final FieldLook Function(Tokens tokens, FieldStatus status) look;

  /// Widgets positioned over the field, in a [Stack] the size of it.
  final List<Widget> Function(BuildContext context, GlacierFieldHandle field)? overlay;

  final String? value;
  final String defaultValue;

  /// Told of every edit the user makes, and of what a component sets through [GlacierFieldHandle.setValue].
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final bool disabled;
  final bool readOnly;
  final bool invalid;
  final bool autoFocus;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool? spellCheck;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final String? semanticLabel;
  final String? semanticHint;
  final String? semanticIdentifier;
  final bool? semanticExpanded;
  final Set<String>? semanticControls;

  /// The handles a touch selection is dragged by; null is the kit's own.
  final TextSelectionControls? selectionControls;

  /// The cut, copy and paste menu; null is the kit's own.
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  /// Laid over the kit's own text style, and over the placeholder's.
  final TextStyle? textStyle;
  final TextStyle? placeholderStyle;

  /// The corner radius; null is the kit's `--glacier-radius-lg`.
  final double? radius;

  static const Map<GlacierFieldSize, String> _fontStep = {GlacierFieldSize.sm: 'xs', GlacierFieldSize.md: 'sm', GlacierFieldSize.lg: 'md'};

  /// `--glacier-control-height-<size>`: how tall the field is.
  static double heightOf(Tokens t, GlacierFieldSize size) => t.len('glacier-control-height-${size.name}');

  /// The text's size at [size]: xs, sm and md of the type scale.
  static double fontSizeOf(Tokens t, GlacierFieldSize size) => t.fontSize(_fontStep[size]!);

  @override
  State<GlacierFieldCore> createState() => GlacierFieldCoreState();
}

/// The field's state. Public only so [GlacierFieldHandle] and the selection gestures can name it.
class GlacierFieldCoreState extends State<GlacierFieldCore> implements TextSelectionGestureDetectorBuilderDelegate {
  /// The controller and focus node made here where the widget brings none of its own.
  TextEditingController? _ownController;
  FocusNode? _ownFocus;
  late final TextSelectionGestureDetectorBuilder _gestures = TextSelectionGestureDetectorBuilder(delegate: this);
  late final GlacierFieldHandle _handle = GlacierFieldHandle._(this);

  bool _hovered = false;

  /// Whether the touch selection's handles are up; the text is being set from here, so [_onText] need not
  /// rebuild; a snap back to the parent's value is waiting for the frame's end; the focus last told to
  /// [GlacierFieldCore.onFocusChange].
  bool _showHandles = false;
  bool _syncing = false;
  bool _revertQueued = false;
  bool _wasFocused = false;

  TextEditingController get _controller => widget.controller ?? _ownController!;
  FocusNode get _focus => widget.focusNode ?? _ownFocus!;

  FieldStatus get _status => FieldStatus(hovered: _hovered && !widget.disabled, focused: _focus.hasFocus && !widget.disabled, disabled: widget.disabled, invalid: widget.invalid);

  // --- TextSelectionGestureDetectorBuilderDelegate ---
  @override
  final GlobalKey<EditableTextState> editableTextKey = GlobalKey<EditableTextState>();

  @override
  bool get forcePressEnabled => false;

  @override
  bool get selectionEnabled => !widget.disabled;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _ownController = TextEditingController(text: widget.value ?? widget.defaultValue);
    if (widget.focusNode == null) _ownFocus = FocusNode(debugLabel: 'GlacierField');
    _controller.addListener(_onText);
    _focus.addListener(_onFocus);
    _focus.canRequestFocus = !widget.disabled;
  }

  @override
  void didUpdateWidget(GlacierFieldCore oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownController)?.removeListener(_onText);
      if (widget.controller == null) {
        _ownController = TextEditingController.fromValue(oldWidget.controller?.value);
      } else {
        _ownController?.dispose();
        _ownController = null;
      }
      _controller.addListener(_onText);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_onFocus);
      if (widget.focusNode == null) {
        _ownFocus = FocusNode(debugLabel: 'GlacierField');
      } else {
        _ownFocus?.dispose();
        _ownFocus = null;
      }
      _focus.addListener(_onFocus);
    }
    _focus.canRequestFocus = !widget.disabled;
    // Controlled: the text is the parent's. Whatever it hands down is what shows.
    final value = widget.value;
    if (value != null && value != _controller.text) _setText(value);
  }

  @override
  void dispose() {
    _controller.removeListener(_onText);
    _focus.removeListener(_onFocus);
    _ownController?.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  /// Puts [text] in the field with the caret at its end, without [_onText] rebuilding for it.
  void _setText(String text) {
    _syncing = true;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _syncing = false;
  }

  void _onText() {
    // Rebuilt for the placeholder and for whatever the overlay shows of the text; a set made while this widget is
    // being rebuilt is already on its way to the screen.
    if (!_syncing && mounted) setState(() {});
  }

  /// Rebuilds for the focused look, and tells the listener once for each real change of focus.
  void _onFocus() {
    if (!mounted) return;
    setState(() {});
    final focused = _focus.hasFocus;
    if (focused == _wasFocused) return;
    _wasFocused = focused;
    widget.onFocusChange?.call(focused);
  }

  /// A controlled field shows its parent's value. Where the parent heard of an edit and kept its own, the text goes
  /// back to it once the frame the parent could have answered in has been built, as a controlled `<input>` snaps
  /// back in React.
  void _queueRevert() {
    if (widget.value == null || _revertQueued) return;
    _revertQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revertQueued = false;
      if (!mounted) return;
      final value = widget.value;
      if (value != null && value != _controller.text) {
        _setText(value);
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _onUserEdit(String text) {
    widget.onChanged?.call(text);
    _queueRevert();
  }

  /// [GlacierFieldHandle.setValue]: a controlled field leaves the text to its parent and only tells it.
  void _setByComponent(String next) {
    if (widget.value == null) {
      _setText(next);
      setState(() {});
    }
    widget.onChanged?.call(next);
  }

  void _requestKeyboard() => editableTextKey.currentState?.requestKeyboard();

  /// Whether a selection made by [cause] brings the drag handles up.
  bool _shouldShowHandles(SelectionChangedCause? cause) {
    // A field woken by something that shows no menu (a mouse, a key) shows no handles either.
    if (!_gestures.shouldShowSelectionToolbar || !_gestures.shouldShowSelectionHandles) return false;
    if (widget.disabled || _controller.text.isEmpty && cause != SelectionChangedCause.longPress) return false;
    if (widget.readOnly && _controller.selection.isCollapsed) return false;
    // Handles are a finger's: a selection the keyboard made, or the program (focus arriving, a value set), brings
    // none, as none appear in a browser's field until it is touched.
    return switch (cause) {
      SelectionChangedCause.tap ||
      SelectionChangedCause.doubleTap ||
      SelectionChangedCause.longPress ||
      SelectionChangedCause.forcePress ||
      SelectionChangedCause.drag ||
      SelectionChangedCause.toolbar ||
      SelectionChangedCause.stylusHandwriting => true,
      _ => false,
    };
  }

  /// Shows or hides the handles, keeps a long press's end in view, and on a desktop puts the menu away while the
  /// mouse drags a selection.
  void _onSelection(TextSelection selection, SelectionChangedCause? cause) {
    final show = _shouldShowHandles(cause);
    if (show != _showHandles) setState(() => _showHandles = show);
    if (cause == SelectionChangedCause.longPress) editableTextKey.currentState?.bringIntoView(selection.extent);
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        if (cause == SelectionChangedCause.drag) editableTextKey.currentState?.hideToolbar();
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final status = _status;
    final look = widget.look(t, status);
    final radius = widget.radius ?? t.radius('lg');
    final hairline = t.len('glacier-hairline');
    final height = GlacierFieldCore.heightOf(t, widget.size);
    final fontSize = GlacierFieldCore.fontSizeOf(t, widget.size);
    final style = kitFont(t, fontSize: fontSize, color: t.color('glacier-text')).merge(widget.textStyle);
    final placeholderStyle = style.copyWith(color: t.color('glacier-text-subtle')).merge(widget.placeholderStyle);
    final accent = t.color('glacier-accent-solid');

    Widget editable = EditableText(
      key: editableTextKey,
      controller: _controller,
      focusNode: _focus,
      readOnly: widget.readOnly || widget.disabled,
      obscureText: widget.obscureText,
      autocorrect: widget.autocorrect,
      enableSuggestions: widget.enableSuggestions,
      spellCheckConfiguration: widget.spellCheck == false ? const SpellCheckConfiguration.disabled() : null,
      style: style,
      // `caret-color: auto` is the text's own colour, and a browser's caret is one pixel wide.
      cursorColor: style.color ?? t.color('glacier-text'),
      cursorWidth: 1,
      backgroundCursorColor: t.color('glacier-text-subtle'),
      // A blurred field keeps its selection and stops showing it, as an `<input>` does.
      selectionColor: status.focused ? t.color('glacier-selection') : null,
      selectionControls: widget.selectionControls ?? GlacierTextSelectionControls(color: accent),
      showSelectionHandles: _showHandles,
      contextMenuBuilder: widget.contextMenuBuilder ?? (context, editable) => GlacierTextSelectionToolbar(tokens: t, editable: editable),
      autofocus: widget.autoFocus && !widget.disabled,
      keyboardType: widget.keyboardType ?? TextInputType.text,
      textInputAction: widget.textInputAction,
      textCapitalization: widget.textCapitalization,
      autofillHints: widget.disabled ? null : widget.autofillHints,
      inputFormatters: [...?widget.inputFormatters, if (widget.maxLength != null) LengthLimitingTextInputFormatter(widget.maxLength)],
      onChanged: _onUserEdit,
      onSubmitted: widget.onSubmitted,
      onEditingComplete: widget.onEditingComplete,
      onSelectionChanged: _onSelection,
      rendererIgnoresPointer: true,
      keyboardAppearance: t.isDark ? Brightness.dark : Brightness.light,
    );
    if (widget.onKeyEvent != null) {
      // `onKeyDown` on the element: the keys reach this before the text does, and a handled one goes no further.
      editable = Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: widget.onKeyEvent, child: editable);
    }

    final text = Stack(
      alignment: AlignmentDirectional.centerStart,
      children: [
        if (_controller.text.isEmpty && widget.placeholder != null)
          ExcludeSemantics(
            child: Text(widget.placeholder!, style: placeholderStyle, maxLines: 1, softWrap: false, overflow: TextOverflow.clip),
          ),
        // The arrows, Backspace and the rest of a hardware keyboard's editing keys, which an app's WidgetsApp would
        // otherwise be relied on for.
        DefaultTextEditingShortcuts(child: editable),
      ],
    );

    Widget input = TweenAnimationBuilder<FieldLook>(
      tween: _LookTween(end: look),
      duration: t.duration('glacier-duration-fast'),
      curve: t.curve('glacier-ease-out'),
      builder: (context, value, child) => CustomPaint(
        painter: KitBoxPainter(
          radius: radius,
          fill: value.background,
          border: value.border,
          borderWidth: hairline,
          ring: value.ring,
          ringSpread: value.ringSpread,
          highlight: value.highlight,
          highlightHeight: hairline,
        ),
        child: child,
      ),
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: hairline + widget.paddingStart, end: hairline + widget.paddingEnd),
        child: Align(alignment: AlignmentDirectional.centerStart, child: text),
      ),
    );
    input = _gestures.buildGestureDetector(behavior: HitTestBehavior.translucent, child: input);
    input = MouseRegion(
      cursor: widget.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.text,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: IgnorePointer(ignoring: widget.disabled, child: input),
    );
    input = Semantics(
      enabled: !widget.disabled,
      label: widget.semanticLabel,
      hint: widget.semanticHint ?? widget.placeholder,
      identifier: widget.semanticIdentifier,
      expanded: widget.semanticExpanded,
      controlsNodes: widget.semanticControls,
      validationResult: widget.invalid ? ui.SemanticsValidationResult.invalid : ui.SemanticsValidationResult.none,
      onTap: widget.disabled || widget.readOnly
          ? null
          : () {
              if (!_controller.selection.isValid) _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
              _requestKeyboard();
            },
      // In a browser, with the page's tree for screen readers on, a field is given the keyboard by focusing its element
      // in the page, which Flutter's engine says as the focus action and not as a tap: there it is taken as the tap is.
      // Without it a field the app had not focused itself took what was typed into its element and told the app
      // nothing. Nothing is added elsewhere.
      onFocus: !kIsWeb || widget.disabled || widget.readOnly
          ? null
          : () {
              if (!_controller.selection.isValid) _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
              _requestKeyboard();
            },
      // `:disabled { opacity: 0.5 }` is the input's own: the border, the ground and the words, not what is laid over.
      child: Opacity(opacity: widget.disabled ? 0.5 : 1, child: input),
    );

    final glassy = look.backdrop || look.underlay.a > 0 || look.underlayHighlight.a > 0;
    return TextFieldTapRegion(
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            if (look.backdrop) GlassBackdrop(blur: t.len('glacier-blur-sm'), saturate: t.len('glacier-glass-saturate'), radius: radius),
            if (glassy)
              CustomPaint(
                painter: KitBoxPainter(radius: radius, fill: look.underlay, highlight: look.underlayHighlight, highlightHeight: hairline, highlightInsideBorder: false),
              ),
            input,
            ...?widget.overlay?.call(context, _handle),
          ],
        ),
      ),
    );
  }
}

/// An adornment pinned over a field at its start or end edge and centred on its height, as `position: absolute` with
/// an `inset-inline` puts one inside the field's flex box.
class FieldSlot extends StatelessWidget {
  const FieldSlot({super.key, this.start, this.end, this.ignorePointer = false, required this.child}) : assert((start == null) != (end == null));

  final double? start;
  final double? end;

  /// `pointer-events: none`: what is under it takes the touch.
  final bool ignorePointer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    Widget slot = Align(alignment: Alignment.center, widthFactor: 1, child: child);
    if (ignorePointer) slot = IgnorePointer(child: slot);
    return PositionedDirectional(start: start, end: end, top: 0, bottom: 0, child: slot);
  }
}

// --- selecting text by touch ---------------------------------------------------------------------------------------
//
// A browser brings its own handles and its own cut, copy and paste menu to an `<input>`; the React kit drew neither.
// Flutter's are Material's or Cupertino's, which this package does not use, so these are the kit's: the least that
// makes a field on a phone usable, drawn from the tokens. Either can be replaced on the field.

/// The drag handles of a touch selection: a drop in the accent, pointing at the text.
class GlacierTextSelectionControls extends TextSelectionControls with TextSelectionHandleControls {
  GlacierTextSelectionControls({required this.color});

  final Color color;

  static const double _size = 22;

  /// An iPhone's own: a bar the line's height with a knob on it at each end of a selection, and nothing under a
  /// caret. They are the system's over the real app's page, which a web view tints with the caret's colour where
  /// the words can be edited (WebKit's interaction tint follows `caret-color`, as its source is remembered and
  /// not as seen beside the real app; the page gives its editor `var(--glacier-accent-solid)`, glyphTheme.ts). So
  /// they are Flutter's copy of the system's shapes, in [color].
  static final TextSelectionControls _iPhone = CupertinoTextSelectionControls();
  static bool get _onIPhone => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Size getHandleSize(double textLineHeight) => _onIPhone ? _iPhone.getHandleSize(textLineHeight) : const Size(_size, _size);

  @override
  Widget buildHandle(BuildContext context, TextSelectionHandleType type, double textLineHeight, [VoidCallback? onTap]) {
    if (_onIPhone) {
      return CupertinoTheme(
        data: CupertinoThemeData(selectionHandleColor: color),
        child: Builder(builder: (context) => _iPhone.buildHandle(context, type, textLineHeight, onTap)),
      );
    }
    final handle = SizedBox.square(
      dimension: _size,
      child: CustomPaint(
        painter: _HandlePainter(color),
        child: GestureDetector(onTap: onTap, behavior: HitTestBehavior.translucent),
      ),
    );
    // The drop points up and to the left; turned, it points up and to the right, or straight up.
    return switch (type) {
      TextSelectionHandleType.left => Transform.rotate(angle: math.pi / 2, child: handle),
      TextSelectionHandleType.right => handle,
      TextSelectionHandleType.collapsed => Transform.rotate(angle: math.pi / 4, child: handle),
    };
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) => _onIPhone
      ? _iPhone.getHandleAnchor(type, textLineHeight)
      : switch (type) {
          TextSelectionHandleType.collapsed => const Offset(_size / 2, -4),
          TextSelectionHandleType.left => const Offset(_size, 0),
          TextSelectionHandleType.right => Offset.zero,
        };

  @override
  bool operator ==(Object other) => other is GlacierTextSelectionControls && other.color == color;

  @override
  int get hashCode => color.hashCode;
}

/// The drop: a disc with its top-left quarter squared off into a point.
class _HandlePainter extends CustomPainter {
  _HandlePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final r = size.width / 2;
    canvas.drawPath(
      Path()
        ..addOval(Rect.fromCircle(center: Offset(r, r), radius: r))
        ..addRect(Rect.fromLTWH(0, 0, r, r)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter old) => old.color != color;
}

/// The cut, copy and paste menu over a selection: a raised bar of words, placed above the selection where there is
/// room and below it where there is not.
class GlacierTextSelectionToolbar extends StatelessWidget {
  const GlacierTextSelectionToolbar({super.key, required this.tokens, required this.editable});

  final Tokens tokens;
  final EditableTextState editable;

  /// The item's own label, or the platform's word for its kind; null for a kind with no word, which is left out.
  static String? _label(BuildContext context, ContextMenuButtonItem item) {
    if (item.label != null) return item.label;
    final words = Localizations.of<WidgetsLocalizations>(context, WidgetsLocalizations) ?? const DefaultWidgetsLocalizations();
    return switch (item.type) {
      ContextMenuButtonType.cut => words.cutButtonLabel,
      ContextMenuButtonType.copy => words.copyButtonLabel,
      ContextMenuButtonType.paste => words.pasteButtonLabel,
      ContextMenuButtonType.selectAll => words.selectAllButtonLabel,
      ContextMenuButtonType.lookUp => words.lookUpButtonLabel,
      ContextMenuButtonType.searchWeb => words.searchWebButtonLabel,
      ContextMenuButtonType.share => words.shareButtonLabel,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final items = [
      for (final item in editable.contextMenuButtonItems)
        if (_label(context, item) != null && item.onPressed != null) (label: _label(context, item)!, run: item.onPressed!),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    final anchors = editable.contextMenuAnchors;
    final gap = t.space(2);
    final edge = t.space(2);
    final top = MediaQuery.paddingOf(context).top + edge;
    final shift = Offset(edge, top);
    final barHeight = t.len('glacier-control-height-sm');
    final above = anchors.primaryAnchor - Offset(0, gap);
    final below = (anchors.secondaryAnchor ?? anchors.primaryAnchor) + Offset(0, GlacierTextSelectionControls._size - 2);
    final radius = t.radius('md');
    final hairline = t.len('glacier-hairline');
    final style = kitFont(t, fontSize: t.fontSize('sm'), color: t.color('glacier-text'), weight: 'medium');
    return Padding(
      padding: EdgeInsets.fromLTRB(edge, top, edge, edge),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(anchorAbove: above - shift, anchorBelow: below - shift, fitsAbove: barHeight <= above.dy - edge - top),
        child: CustomPaint(
          painter: KitBoxPainter(radius: radius, fill: t.color('glacier-surface-raised'), border: t.color('glacier-border'), borderWidth: hairline, shadows: t.shadow('glacier-shadow-3')),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Padding(
              padding: EdgeInsets.all(hairline),
              // A long language, or a platform with more to offer, scrolls sideways rather than running off the bar.
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final item in items)
                      GlacierPressable(
                        onPressed: item.run,
                        canRequestFocus: false,
                        builder: (context, state) => ColoredBox(
                          color: state.pressed ? t.color('glacier-active') : const Color(0x00000000),
                          child: SizedBox(
                            height: barHeight - hairline * 2,
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: t.space(3)),
                              child: Center(widthFactor: 1, child: Text(item.label, style: style, maxLines: 1)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
