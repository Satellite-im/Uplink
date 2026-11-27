import 'package:flutter/widgets.dart';

/// What a Field hands the form control inside it (`FieldContextValue` of internal/FieldContext.ts).
///
/// On the page [id] and [describedBy] are element ids: the label points at the control by `for`, and the control at
/// its description by `aria-describedby`. A semantics tree has no such pointers, so beside them this carries the
/// words themselves, [label] and [description], for the control to say. Both are this port's own and optional.
@immutable
class FieldContextValue {
  const FieldContextValue({required this.id, this.describedBy, this.invalid = false, this.label, this.description});

  final String id;
  final String? describedBy;
  final bool invalid;

  /// The field's label, which `<label for>` gives the control as its name on the page.
  final String? label;

  /// The description or error that [describedBy] points at on the page.
  final String? description;

  @override
  bool operator ==(Object other) =>
      other is FieldContextValue && other.id == id && other.describedBy == describedBy && other.invalid == invalid && other.label == label && other.description == description;

  @override
  int get hashCode => Object.hash(id, describedBy, invalid, label, description);
}

/// The port of internal/FieldContext.ts: shared between the Field molecule (which provides it) and the form-control
/// atoms (which read it), so atoms never import upward from molecules. [maybeOf] is `useField()`.
class GlacierFieldContext extends InheritedWidget {
  const GlacierFieldContext({super.key, required this.value, required super.child});

  final FieldContextValue value;

  /// The surrounding Field's wiring, or null where there is none (`useField`).
  static FieldContextValue? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlacierFieldContext>()?.value;

  @override
  bool updateShouldNotify(GlacierFieldContext oldWidget) => oldWidget.value != value;
}
