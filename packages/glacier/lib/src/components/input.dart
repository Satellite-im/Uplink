import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../tokens/theme.dart';
import '../tokens/tokens.dart';
import 'field_context.dart';
import 'field_core.dart';

export 'field_context.dart' show FieldContextValue, GlacierFieldContext;
export 'field_core.dart' show GlacierFieldSize, GlacierTextSelectionControls, GlacierTextSelectionToolbar;

/// `type` on an `<input>`, for the kinds that are a line of text. It picks the soft keyboard and, for a password,
/// hides the characters.
enum GlacierInputType { text, password, email, number, tel, url, search }

/// The kit's single-line text field: a port of `Input` (packages/react/src/atoms/inputs/Input/Input.tsx and
/// Input.module.css), reading the surrounding Field as internal/FieldContext.ts has it ([GlacierFieldContext]).
///
/// The parameters are the React props under the same names. `...rest`, which the original spreads onto its `<input>`,
/// is the named ones here that Ghost.md and the kit use: [value], [defaultValue], [onChange], [placeholder], [type],
/// [disabled], [readOnly], [autoFocus], [autoComplete], [autoCapitalize], [autoCorrect], [spellCheck], [maxLength],
/// [inputMode], [enterKeyHint], [onKeyDown], [onFocus], [onBlur], [ariaLabel], [ariaInvalid].
///
/// What differs from the original:
/// - [onChange] is handed the text, not an event. With [value] the field is controlled, as in React: an edit the
///   parent does not take is put back. A [controller] may be given instead, which then holds the text.
/// - [focusNode] is the `ref`: focus it to focus the field.
/// - [onSubmitted] is the soft keyboard's action key or Enter, which a form's submit took on the page.
/// - The box is `border-box`, as Ghost.md's page makes every element: the border is inside the control height.
/// - The selection is `--glacier-selection` (the page left it to the browser), and a touch selection's handles and
///   cut, copy and paste menu are the kit's own ([selectionControls], [contextMenuBuilder]) where a browser brought
///   its own.
/// - An icon in a slot is sized to the slot (1.125rem) and coloured with it unless it says otherwise; on the page
///   it kept whatever size it was made at.
/// - `autoCapitalize` left unset is the browser's default for the type: sentences for text and search, none for
///   the rest.
/// - `skeleton` is not ported (the Skeleton atom is not in this package yet).
class GlacierInput extends StatelessWidget {
  const GlacierInput({
    super.key,
    this.size = GlacierFieldSize.md,
    this.glass = false,
    this.leadingIcon,
    this.trailingIcon,
    this.trailing,
    this.trailingExtent = 0,
    this.id,
    this.type = GlacierInputType.text,
    this.value,
    this.defaultValue,
    this.onChange,
    this.controller,
    this.focusNode,
    this.placeholder,
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
    this.inputFormatters,
    this.onKeyDown,
    this.onFocus,
    this.onBlur,
    this.onSubmitted,
    this.ariaLabel,
    this.ariaInvalid,
    this.selectionControls,
    this.contextMenuBuilder,
  });

  final GlacierFieldSize size;

  /// Renders the frosted glass material instead of a solid surface.
  final bool glass;

  /// Icon or adornment pinned to the leading edge; the text pads clear of it.
  final Widget? leadingIcon;

  /// Icon or adornment pinned to the trailing edge, such as a clear button.
  final Widget? trailingIcon;

  /// A control pinned inside the trailing edge at its own size, not an icon's: a message field's send button. The
  /// text pads clear of it by [trailingExtent], its width. Not in the React kit, whose fields put such a button
  /// beside the input; added for Ghost.md's chat (Matt, 2026-10-17: "the send button should be nested inside the
  /// input as well to the right"). Takes the place of [trailingIcon] when both are given.
  final Widget? trailing;

  /// How wide [trailing] is, in logical pixels: the room the text keeps clear for it.
  final double trailingExtent;

  /// The element's id, in the semantics tree; the surrounding Field's where this is null.
  final String? id;
  final GlacierInputType type;

  /// The text, where the parent holds it. Null leaves it to the field ([defaultValue]) or to a [controller].
  final String? value;
  final String? defaultValue;
  final ValueChanged<String>? onChange;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? placeholder;
  final bool disabled;
  final bool readOnly;
  final bool autoFocus;

  /// `autocomplete`, as the page writes it: `username`, `current-password`, `new-password`, `email`, `off`...
  final String? autoComplete;
  final TextCapitalization? autoCapitalize;
  final bool? autoCorrect;
  final bool? spellCheck;
  final int? maxLength;

  /// `inputmode`: the soft keyboard, where [type] alone would pick another.
  final TextInputType? inputMode;

  /// `enterkeyhint`: what the soft keyboard's action key says and does.
  final TextInputAction? enterKeyHint;
  final List<TextInputFormatter>? inputFormatters;

  /// `onKeyDown`: a key going down, or repeating, while the field has the focus. Answer
  /// [KeyEventResult.handled] to keep it from the text, as `preventDefault` did.
  final KeyEventResult Function(KeyEvent event)? onKeyDown;
  final VoidCallback? onFocus;
  final VoidCallback? onBlur;
  final ValueChanged<String>? onSubmitted;

  /// `aria-label`; the surrounding Field's label where this is null.
  final String? ariaLabel;

  /// `aria-invalid`; the surrounding Field's where this is null.
  final bool? ariaInvalid;
  final TextSelectionControls? selectionControls;
  final EditableTextContextMenuBuilder? contextMenuBuilder;

  /// The `<input>`'s own rules of Input.module.css, in the order the cascade settles them.
  static FieldLook lookOf(Tokens t, FieldStatus s, {required bool glass}) {
    const none = Color(0x00000000);

    // .input, then .glass (as specific, and later), then .input:disabled (more specific than either).
    var background = t.color(glass ? 'glacier-glass-regular' : 'glacier-surface');
    if (s.disabled) background = t.color('glacier-surface-sunken');

    // .input / .glass; :focus; [aria-invalid] (as specific as :focus, and later); [aria-invalid]:focus; and
    // :hover:not(:disabled):not(:focus), the most specific of them, which so wins over an invalid field's border.
    var border = t.color(glass ? 'glacier-glass-border' : 'glacier-border');
    if (s.focused) border = t.color('glacier-focus-ring');
    if (s.invalid) border = t.color('glacier-danger-border');
    if (s.invalid && s.focused) border = t.color('glacier-danger-solid');
    if (s.hovered && !s.disabled && !s.focused) border = t.color('glacier-border-strong');

    // box-shadow is one property: the glass's inset highlight until :focus puts the ring in its place.
    var ring = none;
    var highlight = glass ? t.color('glacier-glass-highlight') : none;
    if (s.focused) {
      ring = t.color(s.invalid ? 'glacier-danger-soft' : 'glacier-accent-soft');
      highlight = none;
    }
    return FieldLook(background: background, border: border, ring: ring, ringSpread: s.focused ? 3 : 0, highlight: highlight, backdrop: glass);
  }

  static const Map<String, String> _autofill = {
    'username': AutofillHints.username,
    'current-password': AutofillHints.password,
    'new-password': AutofillHints.newPassword,
    'email': AutofillHints.email,
    'name': AutofillHints.name,
    'given-name': AutofillHints.givenName,
    'family-name': AutofillHints.familyName,
    'nickname': AutofillHints.nickname,
    'organization': AutofillHints.organizationName,
    'one-time-code': AutofillHints.oneTimeCode,
    'tel': AutofillHints.telephoneNumber,
    'url': AutofillHints.url,
    'street-address': AutofillHints.fullStreetAddress,
    'postal-code': AutofillHints.postalCode,
    'country-name': AutofillHints.countryName,
  };

  /// `autocomplete`'s words as the platform's autofill takes them. `off` is none; a word this does not know is
  /// passed on as written.
  static Iterable<String>? autofillHintsOf(String? autoComplete) {
    if (autoComplete == null) return const <String>[];
    final words = autoComplete.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty && w != 'on');
    if (words.isEmpty || words.contains('off')) return null;
    return [for (final word in words) _autofill[word] ?? word];
  }

  @override
  Widget build(BuildContext context) {
    final t = GlacierTheme.of(context);
    final field = GlacierFieldContext.maybeOf(context);
    final plain = type == GlacierInputType.text || type == GlacierInputType.search;
    final secret = type == GlacierInputType.password;

    final keyboard = inputMode ??
        switch (type) {
          GlacierInputType.text || GlacierInputType.search => TextInputType.text,
          GlacierInputType.password => TextInputType.visiblePassword,
          GlacierInputType.email => TextInputType.emailAddress,
          GlacierInputType.number => const TextInputType.numberWithOptions(signed: true, decimal: true),
          GlacierInputType.tel => TextInputType.phone,
          GlacierInputType.url => TextInputType.url,
        };

    // .sm / .md / .lg, then [data-leading] / [data-trailing], and .lg's own of each.
    final pad = t.space(switch (size) { GlacierFieldSize.sm => 3, GlacierFieldSize.md => 4, GlacierFieldSize.lg => 5 });
    final iconPad = t.space(size == GlacierFieldSize.lg ? 10 : 8);
    final slot = t.lenOf('1.125rem');
    final edge = t.space(3);

    Widget icon(Widget child) => SizedBox.square(
          dimension: slot,
          child: IconTheme.merge(
            data: IconThemeData(color: t.color('glacier-text-subtle'), size: slot),
            child: Center(child: child),
          ),
        );

    return GlacierFieldCore(
      size: size,
      paddingStart: leadingIcon != null ? iconPad : pad,
      paddingEnd: trailing != null ? trailingExtent + t.space(2) + t.space(1) : (trailingIcon != null ? iconPad : pad),
      look: (tokens, status) => lookOf(tokens, status, glass: glass),
      overlay: leadingIcon == null && trailingIcon == null && trailing == null
          ? null
          : (context, _) => [
                if (leadingIcon != null) FieldSlot(start: edge, ignorePointer: true, child: icon(leadingIcon!)),
                if (trailing != null)
                  FieldSlot(end: t.space(1), child: trailing!)
                else if (trailingIcon != null)
                  FieldSlot(end: edge, child: icon(trailingIcon!)),
              ],
      value: value,
      defaultValue: defaultValue ?? '',
      onChanged: onChange,
      controller: controller,
      focusNode: focusNode,
      placeholder: placeholder,
      disabled: disabled,
      readOnly: readOnly,
      invalid: ariaInvalid ?? field?.invalid ?? false,
      autoFocus: autoFocus,
      obscureText: secret,
      keyboardType: keyboard,
      textInputAction: enterKeyHint ?? (type == GlacierInputType.search ? TextInputAction.search : null),
      textCapitalization: autoCapitalize ?? (plain ? TextCapitalization.sentences : TextCapitalization.none),
      autocorrect: autoCorrect ?? plain,
      enableSuggestions: !secret,
      spellCheck: spellCheck,
      autofillHints: autofillHintsOf(autoComplete),
      maxLength: maxLength,
      inputFormatters: inputFormatters,
      onSubmitted: onSubmitted,
      onKeyEvent: onKeyDown == null ? null : (node, event) => event is KeyUpEvent ? KeyEventResult.ignored : onKeyDown!(event),
      onFocusChange: onFocus == null && onBlur == null ? null : (focused) => focused ? onFocus?.call() : onBlur?.call(),
      semanticLabel: ariaLabel ?? field?.label,
      semanticHint: field?.description,
      semanticIdentifier: id ?? field?.id,
      selectionControls: selectionControls,
      contextMenuBuilder: contextMenuBuilder,
    );
  }
}
