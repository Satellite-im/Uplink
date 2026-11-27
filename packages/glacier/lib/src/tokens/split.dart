/// Splitting a CSS value or a selector list at its top level: in a file that imports nothing, so the token sheet's
/// parser (sheet.dart) is plain Dart and a tool can run it without the engine (tool/token_sheet.dart).
library;

/// Splits [s] on [sep] where it stands outside every bracket. With a space as the separator, runs of white space are
/// one separator and empty pieces are dropped.
List<String> splitTop(String s, String sep) {
  final out = <String>[];
  var depth = 0, start = 0;
  final space = sep == ' ';
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '(' || ch == '[') {
      depth++;
    } else if (ch == ')' || ch == ']') {
      depth--;
    } else if (depth == 0 && (space ? (ch == ' ' || ch == '\n' || ch == '\t') : ch == sep)) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  final trimmed = out.map((p) => p.trim());
  return (space ? trimmed.where((p) => p.isNotEmpty) : trimmed).toList();
}
