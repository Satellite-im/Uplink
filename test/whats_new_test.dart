import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/changelog.dart';
import 'package:ghost_messaging/ui/settings_panes.dart' show appVersion;
import 'package:ghost_messaging/ui/whats_new.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/art/lucide_more.dart';

import 'support/space_call_harness.dart';

/// What's new (lib/changelog.dart, lib/ui/whats_new.dart; Matt, 2026-11-19: "Implement a changelog that pops up ever
/// time a new update is released with release notes").
class _Opener extends StatefulWidget {
  const _Opener(this.current, {required this.seen, required this.onboarded});
  final String current, seen;
  final bool onboarded;
  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final app = AppState.of(context);
      if (widget.seen.isNotEmpty) app.set(changelogSeenKey, widget.seen);
      if (widget.onboarded) app.setFlag('onboarded', true);
      showWhatsNewIfUpdated(context, current: widget.current);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  test('versions compare as numbers, and the notes since one are the later ones up to this build, newest first', () {
    expect(laterVersion('0.9.10', '0.9.9'), isTrue);
    expect(laterVersion('0.9.9', '0.9.10'), isFalse);
    expect(laterVersion('1.0.0', '0.9.99'), isTrue);
    expect(laterVersion('0.9.20', '0.9.20'), isFalse);
    expect(laterVersion('0.9.20', ''), isTrue);
    const log = [
      ReleaseNotes('0.9.23', '', ['c']),
      ReleaseNotes('0.9.22', '', ['b']),
      ReleaseNotes('0.9.21', '', ['a']),
    ];
    expect(notesSince('0.9.21', '0.9.22', from: log).map((r) => r.version), ['0.9.22'], reason: 'not a later version this build is not');
    expect(notesSince('0.9.20', '0.9.23', from: log).map((r) => r.version), ['0.9.23', '0.9.22', '0.9.21']);
    expect(notesSince('0.9.23', '0.9.23', from: log), isEmpty);
  });

  test('every entry has a version, a date and words, newest first, and this build\'s version has one', () {
    expect(changelog, isNotEmpty);
    for (var i = 0; i < changelog.length; i++) {
      final r = changelog[i];
      expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(r.version), isTrue, reason: r.version);
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(r.date), isTrue, reason: r.version);
      expect(r.notes, isNotEmpty);
      if (i > 0) expect(laterVersion(changelog[i - 1].version, r.version), isTrue, reason: 'newest first');
    }
    // The build's own version has notes, or the release script would have stopped it.
    final pub = RegExp(r'^version:\s*([0-9.]+)\+', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1)!;
    expect(pub, appVersion, reason: 'pubspec.yaml and appVersion go together');
  });

  Future<void> open(WidgetTester tester, {required String seen, bool onboarded = true, String current = '0.9.22'}) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, _Opener(current, seen: seen, onboarded: onboarded), 'whats-new');
  }

  testWidgets('after an update the notes since the last version seen come up once', (tester) async {
    await open(tester, seen: '0.9.21', current: changelog.first.version);
    expect(find.text('What\'s new'), findsOneWidget);
    expect(find.text(changelog.first.notes.first), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the same version again shows nothing', (tester) async {
    await open(tester, seen: changelog.first.version, current: changelog.first.version);
    expect(find.text('What\'s new'), findsNothing);
  });

  testWidgets('a new install that is not set up yet is not told what is new', (tester) async {
    await open(tester, seen: '', onboarded: false, current: changelog.first.version);
    expect(find.text('What\'s new'), findsNothing);
  });

  testWidgets('a phone set up before notes were kept is shown the newest release\'s', (tester) async {
    await open(tester, seen: '', current: changelog.first.version);
    expect(find.text('What\'s new'), findsOneWidget);
    expect(find.text('Uplink ${changelog.first.version}'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  test('each note has a mark for what it is about, its name first (Matt, 2026-11-19: "use iconography and smaller text on release notes")', () {
    expect(noteIcon('Record call: record a space\'s call to one video file'), Lucide.circleDot, reason: 'by its name, not the "video" in its words');
    expect(noteIcon('Runestone comes with its textures: the look draws its buttons from a pack'), Lucide.scrollText, reason: 'Runestone\'s own notes keep its scroll');
    expect(noteIcon('Textures for every look: Settings › Appearance has the packs'), Lucide.palette);
    expect(noteIcon('Four looks: Uplink, Sharp, Dial-Up and Runestone. Phosphor is gone'), Lucide.palette, reason: 'by its name, not the looks it lists');
    expect(noteIcon('Uplink: Ghost Messaging has a new name. Your chats are as they were'), Lucide.tag, reason: 'by its name, not the chats it mentions');
    expect(noteIcon('Uplink on a Mac: a copy already installed keeps its old name in Finder'), Lucide.tag);
    expect(noteIcon('A new app icon: the Uplink logo, on your home screen'), Lucide.shapes);
    expect(noteIcon('Voice messages are louder in Uplink'), LucideMore.headphones, reason: 'a note that only mentions the app keeps its own mark');
    expect(noteIcon('Scribe: a recorded call written out'), Lucide.scrollText);
    expect(noteIcon('Live captions: in a call, see what everyone says'), Lucide.text);
    expect(noteIcon('Watch together: play a video'), Lucide.film);
    expect(noteIcon('SMS spaces: members whose phone number is linked'), Lucide.smartphone);
    expect(noteIcon('Mentions: type @ in a space'), Lucide.atSign);
    expect(noteIcon('The Codes tab is always there'), Lucide.keyRound);
    expect(noteIcon('Tap someone\'s picture or name in a space to open their profile.'), Lucide.circleUser, reason: 'a profile, though it says picture');
    expect(noteIcon('Windows: the app and its installer are signed'), Lucide.shieldCheck);
    expect(noteIcon('Help and docs: step-by-step guides at gogho.st/docs'), Lucide.bookOpen);
    expect(noteIcon('Something nobody has a word for'), Lucide.sparkles);
    expect(LucideMore.headphones, isNotNull);
    // Every note written so far has a mark of its own, not the sparkle left for nothing.
    for (final r in changelog) {
      for (final n in r.notes) {
        if (n.startsWith('What\'s new')) continue;
        expect(noteIcon(n), isNot(Lucide.sparkles), reason: n);
      }
    }
  });
}
