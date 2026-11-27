import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'field_context.dart';
import 'field_core.dart';
import 'input.dart' show GlacierInput;
import 'pressable.dart';

export 'field_context.dart' show FieldContextValue, GlacierFieldContext;
export 'field_core.dart' show GlacierFieldSize, GlacierTextSelectionControls, GlacierTextSelectionToolbar;

/// `kitMessages.clearSearch` (packages/react/src/i18n/messages.ts): the clear button's name.
const Map<String, String> _clearSearch = {
  'en': 'Clear search',
  'es': 'Borrar búsqueda',
  'fr': 'Effacer la recherche',
  'de': 'Suche löschen',
  'ja': '検索をクリア',
  'pt': 'Limpar pesquisa',
  'zh': '清空搜索',
  'ar': 'مسح البحث',
};

/// A `<button>`'s own font size where no stylesheet gives it one, which the kit's does not: the browser's
/// 13.3333px. The clear button is `1.5em` of it across and its cross `1em`.
const double _buttonFontSize = 13.3333;

/// The kit's search field: a port of `SearchField` (packages/react/src/atoms/inputs/SearchField/SearchField.tsx and
/// SearchField.module.css). A magnifier at the leading edge, the text, and one trailing slot shared by the clear
/// button (once there is a value) and the [shortcut] hint (while there is none).
///
/// The parameters are the React props under the same names; `...rest`, which the original spreads onto its
/// `<input>`, is the named ones here: [disabled], [readOnly], [autoFocus], [onKeyDown], [onFocus], [onBlur],
/// [ariaLabel], [ariaInvalid], [ariaExpanded], [ariaControls] and the keyboard hints.
///
/// What differs from the original:
/// - A [controller] may hold the text in place of [value]; [focusNode] is the `ref`.
/// - [onSubmitted] and [onEditingComplete] are the soft keyboard's action key (Search, by default) or Enter.
/// - Clearing leaves the focus where it was. On the page the click moved it to the button, which then left the
///   document, and the field had to be clicked again to type.
/// - The magnifier and the cross are the original's own two drawings (not the icon pack's), drawn stroke for
///   stroke. The magnifier is `1em` of the text around the field, as on the page; the clear button measures by a
///   `<button>`'s own 13.3333px, which is what the page's did.
/// - The selection colour and the touch handles and menu are as [GlacierInput] has them.
/// - [clearLabel] names the clear button where the kit's own words (eight languages, by the ambient [Localizations])
///   are not wanted. The page read its language from the kit's LocaleProvider, which has no port yet.
/// - `skeleton` is not ported (the Skeleton atom is not in this package yet).
///
/// Kept from the original although it looks like a slip: a disabled field with a value still shows a clear button
/// that works, and its magnifier is not dimmed with it (`:disabled` dims the `<input>` alone).
class GlacierSearchField extends StatelessWidget {
  const GlacierSearchField({
    super.key,
    this.value,
    this.defaultValue = '',
    this.onValueChange,
    this.placeholder = 'Search',
    this.size = GlacierFieldSize.md,
    this.shortcut,
    this.glass = false,
    this.id,
    this.controller,
    this.focusNode,
    this.disabled = false,
    this.readOnly = false,
    this.autoFocus = false,
    this.autoComplete,
    this.autoCapitalize,
    this.autoCorrect,
    this.spellCheck,
    this.maxLength,
    this.inputMode,
    this.enterKeyHint,
    this.onKeyDown,
    this.onFocus,
    this.onBlur,
    this.onSubmitted,
    this.onEditingComplete,
    this.ariaLabel,
    this.ariaInvalid,
    this.ariaExpanded,
    this.ariaControls,
    this.clearLabel,
    this.selectionControls,
    this.contextMenuBuilder,
  });

  /// The text, where the parent holds it. Null leaves it to the field ([defaultValue]) or to a [controller].
  final String? value;
  final String defaultValue;

  /// Told of every edit, and of the clear button's empty string.
  final ValueChanged<String>? onValueChange;
  final String placeholder;
  final GlacierFieldSize size;

  /// Right-aligned slot for a keyboard shortcut hint, e.g. a GlacierKbd.
  final Widget? shortcut;

  /// Renders the frosted glass material instead of a solid surface.
  final bool glass;
  final String? id;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool disabled;
  final bool readOnly;
  final bool autoFocus;
  final String? autoComplete;
  final TextCapitalization? autoCapitalize;
  final bool? autoCorrect;
  final bool? spellCheck;
  final int? maxLength;
  final TextInputType? inputMode;
  final TextInputAction? enterKeyHint;

  /// `onKeyDown`: a key going down, or repeating, while the field has the focus. Answer
  /// [KeyEventResult.handled] to keep it from the text, as `preventDefault` did.
  final KeyEventResult Function(KeyEvent event)? onKeyDown;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;
  final ValueChanged<String>? onSubmitted;

  /// What the action key does besides [onSubmitted]. Null lets the field give up the focus on Search or Done, as a
  /// Flutter field does; a callback keeps it.
  final VoidCallback? onEditingComplete;
  final String? ariaLabel;
  final bool? ariaInvalid;

  /// `aria-expanded` and `aria-controls` (the id of what this field drives), for a field that is a combobox.
  final bool? ariaExpanded;
  final String? ariaControls;
  final String? clearLabel;
  final TextSelectionControls? selectionControls;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  /// The `<input>`'s rules of SearchField.module.css, in the order the cascade settles them.
  static FieldLook lookOf(Tokens t, FieldStatus s, {required bool glass}) {
    const none = Color(0x00000000);

    // .input; .input:disabled; then `.glass .input`, as specific as :disabled and after it.
    var background = t.color('glacier-surface');
    if (s.disabled) background = t.color('glacier-surface-sunken');
    if (glass) background = none;

    // .input; :focus; [aria-invalid]; `.glass .input`, as specific as those two and after both, so a glass field's
    // border holds through focus; then [aria-invalid]:focus and :hover:not(:disabled):not(:focus), which outrank it.
    var border = t.color('glacier-border');
    if (s.focused) border = t.color('glacier-focus-ring');
    if (s.invalid) border = t.color('glacier-danger-border');
    if (glass) border = t.color('glacier-glass-border');
    if (s.invalid && s.focused) border = t.color('glacier-danger-solid');
    if (s.hovered && !s.disabled && !s.focused) border = t.color('glacier-border-strong');

    final ring = s.focused ? t.color(s.invalid ? 'glacier-danger-soft' : 'glacier-accent-soft') : none;

    return FieldLook(
      background: background,
      border: border,
      ring: ring,
      ringSpread: s.focused ? 3 : 0,
      // The glass is the wrapper's: its ground and its highlight sit behind the input and do not answer its states.
      underlay: glass ? t.color('glacier-glass-regular') : none,
      underlayHighlight: glass ? t.color('glacier-glass-highlight') : none,
      backdrop: glass,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final field = GlacierFieldContext.maybeOf(context);
    final lg = size == GlacierFieldSize.lg;
    final pad = t.space(lg ? 10 : 8);
    final em = inheritedFontSize(context, t);
    final subtle = t.color('glacier-text-subtle');
    final language = Localizations.maybeLocaleOf(context)?.languageCode;

    return GlacierFieldCore(
      size: size,
      paddingStart: pad,
      paddingEnd: pad,
      look: (tokens, status) => lookOf(tokens, status, glass: glass),
      overlay: (context, input) => [
        FieldSlot(
          start: t.space(lg ? 4 : 3),
          ignorePointer: true,
          child: CustomPaint(size: Size.square(em), painter: _GlyphPainter(_Glyph.search, subtle)),
        ),
        // The clear button and the shortcut hint share the trailing slot, so only one shows at a time: the shortcut
        // hints how to focus an empty field; once there is a value, it becomes the clear button.
        if (input.text.isNotEmpty)
          FieldSlot(
            end: t.space(2),
            child: _ClearButton(label: clearLabel ?? _clearSearch[language] ?? _clearSearch['en']!, onPressed: () => input.setValue('')),
          )
        else if (shortcut != null)
          FieldSlot(end: t.space(3), ignorePointer: true, child: shortcut!),
      ],
      value: value,
      defaultValue: defaultValue,
      onChanged: onValueChange,
      controller: controller,
      focusNode: focusNode,
      placeholder: placeholder,
      disabled: disabled,
      readOnly: readOnly,
      invalid: ariaInvalid ?? field?.invalid ?? false,
      autoFocus: autoFocus,
      keyboardType: inputMode ?? TextInputType.text,
      textInputAction: enterKeyHint ?? TextInputAction.search,
      textCapitalization: autoCapitalize ?? TextCapitalization.sentences,
      autocorrect: autoCorrect ?? true,
      spellCheck: spellCheck,
      autofillHints: GlacierInput.autofillHintsOf(autoComplete),
      maxLength: maxLength,
      onSubmitted: onSubmitted,
      onEditingComplete: onEditingComplete,
      onKeyEvent: onKeyDown == null ? null : (node, event) => event is KeyUpEvent ? KeyEventResult.ignored : onKeyDown!(event),
      onFocusChange: onFocus == null && onBlur == null ? null : (focused) => focused ? onFocus?.call() : onBlur?.call(),
      semanticLabel: ariaLabel ?? field?.label,
      semanticHint: field?.description,
      semanticIdentifier: id ?? field?.id,
      semanticExpanded: ariaExpanded,
      semanticControls: ariaControls == null ? null : {ariaControls!},
      selectionControls: selectionControls,
      contextMenuBuilder: contextMenuBuilder,
    );
  }
}

/// `.clear`: a round button, quiet until it is hovered or focused from the keyboard.
class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    const none = Color(0x00000000);
    final fast = t.duration('glacier-duration-fast');
    final ease = t.curve('glacier-ease-out');
    // One node for a screen reader: a button, its name, its tap.
    return MergeSemantics(
      child: GlacierPressable(
        onPressed: onPressed,
        semanticLabel: label,
        builder: (context, state) {
          final lit = state.hovered || state.focused;
          final sunken = t.color('glacier-surface-sunken');
          return CustomPaint(
            // `:focus-visible { box-shadow: 0 0 0 3px accent-soft }`, which is not among the transitions.
            painter: KitBoxPainter(radius: t.radius('full'), ring: state.focused ? t.color('glacier-accent-soft') : null, ringSpread: 3),
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: state.hovered ? sunken : sunken.withValues(alpha: 0)),
              duration: fast,
              curve: ease,
              builder: (context, ground, child) => DecoratedBox(
                decoration: BoxDecoration(color: ground ?? none, shape: BoxShape.circle),
                child: child,
              ),
              child: SizedBox.square(
                dimension: _buttonFontSize * 1.5,
                child: Center(
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: t.color(lit ? 'glacier-text' : 'glacier-text-subtle')),
                    duration: fast,
                    curve: ease,
                    builder: (context, ink, _) => CustomPaint(size: const Size.square(_buttonFontSize), painter: _GlyphPainter(_Glyph.clear, ink ?? none)),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The magnifying glass at the field's start, and the cross on its clear button.
enum _Glyph { search, clear }

/// The two drawings SearchField.tsx carries inline, on their 16-unit grid: strokes of 1.5 in the current colour.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 16, size.height / 16);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    switch (glyph) {
      case _Glyph.search:
        // <circle cx="7" cy="7" r="4.5"/> and <path d="m11 11 3.5 3.5" stroke-linecap="round"/>
        canvas.drawCircle(const Offset(7, 7), 4.5, stroke);
        canvas.drawLine(const Offset(11, 11), const Offset(14.5, 14.5), stroke..strokeCap = StrokeCap.round);
      case _Glyph.clear:
        // <path d="m3.5 3.5 9 9"/> and <path d="m12.5 3.5-9 9"/>, both round-capped
        stroke.strokeCap = StrokeCap.round;
        canvas.drawLine(const Offset(3.5, 3.5), const Offset(12.5, 12.5), stroke);
        canvas.drawLine(const Offset(12.5, 3.5), const Offset(3.5, 12.5), stroke);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
