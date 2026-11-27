import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app's links into gogho.st/docs (lib/ui/common.dart's openDocs and docsButton) go to pages the docs have
/// (docs-src/pages.mjs; Matt, 2026-11-19: "Spend time creating a /docs/ page on ghost messaging"). The Marketplace's are
/// part of the app's contract with the docs (Matt, 2026-11-20: "Please include documents on how users can develop
/// plugins"): Marketplace › How to build a plugin, Settings › Developer's Plugins in development, the submission form's
/// guidelines row, and the Marketplace's own help.
void main() {
  final pages = File('docs-src/pages.mjs').readAsStringSync();
  final slugs = {for (final m in RegExp(r"slug: '([a-z0-9-]+)'").allMatches(pages)) m.group(1)!};

  test('every docs page the app opens is in the docs', () {
    final asked = <String, String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"(?:openDocs|docsButton)\(\s*'([^']*)'").allMatches(f.readAsStringSync())) {
        asked[m.group(1)!] = f.path;
      }
    }
    expect(asked, isNotEmpty, reason: 'the app links some docs pages by name');
    for (final e in asked.entries) {
      // openDocs('') is the docs' own front page.
      if (e.key.isEmpty) continue;
      expect(slugs, contains(e.key), reason: '${e.value} opens /docs/${e.key}/, and docs-src/pages.mjs has no page by that name');
    }
  });

  test('the pages the Marketplace links are there, each with its body', () {
    for (final slug in ['plugins', 'build-a-plugin', 'plugin-testing', 'plugin-guidelines']) {
      expect(slugs, contains(slug));
      expect(File('docs-src/pages/$slug.html').existsSync(), isTrue, reason: 'docs-src/pages/$slug.html');
    }
  });
}
