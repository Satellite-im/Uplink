import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/open_space_chat.dart';
import 'package:ghost_messaging/voice/open_space.dart';

/// The open-space docs say what the app does (Matt, 2026-11-23: "please add docs with components from open spaces that
/// explains how they work"): every number the user's page (docs-src/pages/open-spaces.html) and the developers' flow
/// (docs-src/pages/developer/flows.html#open-space) give is read here from the code that decides it, so changing one
/// without the other fails. The page's drawings use the open-space mock tags, each listed in tool/build-docs.mjs's own
/// words, and the built page is the one docs-src makes (test/docs_slugs_test.dart, `node tool/build-docs.mjs --check`).
void main() {
  final page = File('docs-src/pages/open-spaces.html').readAsStringSync();
  final flows = File('docs-src/pages/developer/flows.html').readAsStringSync();
  final builder = File('tool/build-docs.mjs').readAsStringSync();
  const words = {3: 'three', 4: 'four', 8: 'eight', 10: 'ten', 13: 'thirteen'};
  // A face on the floor is about this many of its units across (OpenWorld.width's own words).
  const face = 56;

  test('the user page gives the app\'s own numbers', () {
    // Heard whole within about three faces, and not at all past about thirteen.
    expect(page, contains('Within about ${words[(OpenWorld.near / face).floor()]} steps of you'));
    expect(page, contains('about ${words[(OpenWorld.far / face).floor()]} pictures from you to it'));
    // Through a group's edge: "under a third" holds while it is.
    expect(OpenWorld.throughEdge, lessThan(1 / 3));
    expect(page, contains('at under a third of what distance alone would give'));
    expect(page, contains('A space holds up to ${OpenWorld.mostGroups} groups, and a group\'s name is up to ${OpenWorld.longestName} letters'));
    expect(page, contains('for about ${words[FloorBubbles.life.inSeconds]} seconds each'));
    expect(page, contains('Each stack shows the newest ${words[FloorBubbles.most]}'));
    // How it works, linked from the user's page to the developers' section that is there.
    expect(page, contains('href="/docs/developer/flows/#open-space"'));
    expect(flows, contains('<h2 id="open-space">'));
  });

  test('the developers\' flow gives the app\'s own numbers', () {
    String n(double x) => x == x.roundToDouble() ? '${x.round()}' : '$x';
    expect(flows, contains('where on the ${n(OpenWorld.width)} by ${n(OpenWorld.height)} floor'));
    expect(flows, contains('at most every ${OpenSpace.whileWalking.inMilliseconds} ms while walking'));
    expect(flows, contains('every ${OpenSpace.beatEvery.inSeconds} seconds while standing still'));
    expect(flows, contains('whole within ${n(OpenWorld.near)} units'));
    expect(flows, contains('nothing past ${n(OpenWorld.far)} (<code>far</code>'));
    expect(flows, contains('it is times ${OpenWorld.throughEdge} (<code>throughEdge</code>)'));
    expect(flows, contains('a name of up to ${OpenWorld.longestName} letters'));
    expect(flows, contains('one of ${words[SpaceGroup.hues.length]} hues'));
    expect(flows, contains('A space holds ${OpenWorld.mostGroups}.'));
    expect(flows, contains('kept as removed for ${OpenSpace.goneKept.inDays} days'));
    expect(flows, contains('${n(OpenWorld.radiusEmpty)} units, plus ${n(OpenWorld.radiusEach)} times the square root of how many are in it, up to ${n(OpenWorld.radiusMost)}'));
    expect(flows, contains('newest ${words[FloorBubbles.most]} (<code>most</code>)'));
    expect(flows, contains('stays ${FloorBubbles.life.inSeconds} seconds (<code>life</code>), fading over the last ${FloorBubbles.fade.inMilliseconds / 1000}'));
    expect(flows, contains('never below ${FloorBubbles.faintest}'));
  });

  test('the page is drawn with the open-space mock tags, and each is described where the mock tags are', () {
    final head = builder.substring(0, builder.indexOf('*/'));
    for (final tag in ['m-floor', 'm-standing', 'm-group', 'm-floor-bubbles', 'm-floor-bubble']) {
      expect(page, contains('<$tag'), reason: 'open-spaces.html draws with <$tag>');
      expect(head, contains('<$tag '), reason: 'tool/build-docs.mjs lists <$tag> among the mock tags');
      expect(builder, contains("'$tag': ("), reason: 'tool/build-docs.mjs draws <$tag>');
    }
  });
}
