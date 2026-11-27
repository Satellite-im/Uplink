// The app's words, for translating (GMFB-32; lib/l10n/words.dart):
//
//     dart run tool/l10n.dart            writes assets/l10n/app_en.arb from the code, and says how much each language has
//     dart run tool/l10n.dart missing es writes build/l10n/missing_es.json: the English with no Spanish yet, by key
//
// Each key is `w` and eight hex digits made from the English alone, so a word keeps its key wherever it moves, and a
// translation is kept for exactly the English it was made for: English that changes is a new key, and is drawn in
// English until it is translated again. test/l10n_test.dart runs [extract] and fails where app_en.arb is behind the
// code.
import 'dart:convert';
import 'dart:io';

/// The English the app draws through something that translates it: `Tr('…')`, `'…'.t` and `'…'.tf(`, `Choice('…'`,
/// and what is given to the kit's words (`label:`, `title:`, `hint:`, `placeholder:`, `footer:`), each a literal with
/// nothing put into it (no `$`). A literal given to something that doesn't translate is in the file too, which costs a
/// translation nobody sees and nothing else.
final _patterns = [
  RegExp(r"""\bTr\(\s*('(?:[^'\\$\n]|\\.)*'|"(?:[^"\\$\n]|\\.)*")\s*[,)]"""),
  RegExp(r"""('(?:[^'\\$\n]|\\.)*'|"(?:[^"\\$\n]|\\.)*")\.tf?\b"""),
  RegExp(r"""\bChoice\(\s*('(?:[^'\\$\n]|\\.)*'|"(?:[^"\\$\n]|\\.)*")\s*,"""),
  RegExp(r"""\b(?:label|title|hint|placeholder|footer|header|semanticLabel): ('(?:[^'\\$\n]|\\.)*'|"(?:[^"\\$\n]|\\.)*")\s*[,)\n]"""),
];

/// What a Dart literal (with its quotes) says.
String unquote(String lit) {
  final body = lit.substring(1, lit.length - 1);
  return body.replaceAllMapped(RegExp(r'\\(.)'), (m) => switch (m[1]) { 'n' => '\n', 't' => '\t', _ => m[1]! });
}

/// The key for [english]: `w` and FNV-1a's 32 bits of its UTF-8, in hex.
String keyOf(String english) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(english)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return 'w${h.toRadixString(16).padLeft(8, '0')}';
}

/// In Settings' own files, every literal that reads as words (a capital, then letters): the state lines under each
/// section are made of them ("Light · White bubbles"), returned from small functions the patterns above don't see,
/// and drawn translated piece by piece (translatedParts).
final _settingsFiles = RegExp(r'lib/ui/settings[a-z_]*\.dart$');
final _wordsLiteral = RegExp(r"""'([A-Z][a-z][^'\\$\n]*)'""");

final _summaryStart = RegExp(r'String [a-zA-Z]*[sS]ummary\(|summary: \(');

/// The code from [at] to the end of what opens there: a block or brackets, or an arrow's one expression (to the `;`
/// or the `,` that ends it at its own depth).
String _braced(String src, int at) {
  if (at < 0) return '';
  var depth = 0;
  final arrow = src.startsWith('=>', at);
  for (var i = arrow ? at + 2 : at; i < src.length; i++) {
    final c = src[i];
    if (c == '{' || c == '(' || c == '[') depth++;
    if (c == '}' || c == ')' || c == ']') {
      depth--;
      if (!arrow && depth == 0) return src.substring(at, i + 1);
      if (arrow && depth < 0) return src.substring(at, i);
    }
    if (arrow && depth == 0 && (c == ';' || c == ',')) return src.substring(at, i);
  }
  return src.substring(at);
}

/// Every piece of English in [root]'s lib/, by key. What's New's notes are left out: they say what each version was.
Map<String, String> extract(String root) {
  final out = <String, String>{};
  final files = Directory('$root/lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !f.path.endsWith('changelog.dart')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final src = f.readAsStringSync();
    if (_settingsFiles.hasMatch(f.path.replaceAll('\\', '/'))) {
      for (final m in _wordsLiteral.allMatches(src)) {
        out[keyOf(m[1]!)] = m[1]!;
      }
    }
    // A section's state line, written in a function of its own anywhere (`String meSummary(SettingsModel m)`) or as
    // the section's `summary:`: the words in it, for translatedParts.
    for (final start in _summaryStart.allMatches(src)) {
      final body = _braced(src, src.indexOf(RegExp(r'[{(]|=>'), start.end));
      for (final m in _wordsLiteral.allMatches(body)) {
        out[keyOf(m[1]!)] = m[1]!;
      }
    }
    for (final p in _patterns) {
      for (final m in p.allMatches(src)) {
        final words = unquote(m[1]!);
        if (words.trim().isEmpty || !RegExp('[A-Za-z]').hasMatch(words)) continue;
        out[keyOf(words)] = words;
      }
    }
  }
  return out;
}

/// [words] as an ARB file for [locale], by key in order.
String arb(String locale, Map<String, String> words) {
  final keys = words.keys.toList()..sort();
  return '${const JsonEncoder.withIndent('  ').convert({'@@locale': locale, for (final k in keys) k: words[k]})}\n';
}

Map<String, String> readArb(File f) {
  if (!f.existsSync()) return {};
  final m = (jsonDecode(f.readAsStringSync()) as Map).cast<String, Object?>();
  return {for (final e in m.entries) if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String};
}

void main(List<String> args) {
  final root = Directory.current.path;
  final en = extract(root);
  if (args.length == 2 && args[0] == 'missing') {
    final there = readArb(File('$root/assets/l10n/app_${args[1]}.arb'));
    final missing = {for (final e in en.entries) if (!there.containsKey(e.key)) e.key: e.value};
    Directory('$root/build/l10n').createSync(recursive: true);
    File('$root/build/l10n/missing_${args[1]}.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(missing));
    stdout.writeln('${missing.length} pieces of English with no ${args[1]} yet: build/l10n/missing_${args[1]}.json');
    return;
  }
  Directory('$root/assets/l10n').createSync(recursive: true);
  File('$root/assets/l10n/app_en.arb').writeAsStringSync(arb('en', en));
  stdout.writeln('app_en.arb: ${en.length} pieces of English');
  for (final f in Directory('$root/assets/l10n').listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.startsWith('app_') || name == 'app_en.arb') continue;
    final there = readArb(f);
    final have = en.keys.where(there.containsKey).length;
    stdout.writeln('$name: $have of ${en.length} (${(100 * have / en.length).toStringAsFixed(1)}%), ${there.length - have} no longer in the code');
  }
}
