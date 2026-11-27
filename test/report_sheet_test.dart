import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/net/packet.dart' show Envelope;
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_models.dart' show SealedReportRow;
import 'package:ghost_messaging/net/net.dart' show Net;
import 'package:ghost_messaging/sms.dart' show Sms;
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/safety/abuse_report.dart';
import 'package:ghost_messaging/ui/market/people_reports_page.dart';
import 'package:ghost_messaging/ui/report_sheet.dart';

import 'support/space_call_harness.dart';

/// GMFB-40, "Report a user or message": the sheet, what it sends, what it keeps here, the space chat's way into it,
/// and the reviewer's page that opens the sealed reports.

/// Scrolls until [key]'s row is drawn, and presses it.
Future<void> _press(WidgetTester tester, String key) async {
  // Built lazily: scrolled down to where it is, or up where it was passed.
  final f = find.byKey(ValueKey(key));
  if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 120, scrollable: find.byType(Scrollable).first);
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

const _target = ReportTarget(
  id: 'a4bbad8bc42293e4a4bbad8bc42293e4',
  username: 'pest',
  name: 'Pest',
  place: 'chat',
  placeName: 'Pest',
  messages: [
    ReportedMessage(from: '@pest', name: 'Pest', at: 1, text: 'hi'),
    ReportedMessage(from: '@me', name: 'You', at: 2, text: 'hello', mine: true),
    ReportedMessage(from: '@pest', name: 'Pest', at: 3, text: 'something nasty', reported: true),
  ],
);

/// No friends, nobody blocked: the sheet asks Buddies whether someone is blocked already.
class _NoBuddies implements BuddiesPort {
  @override
  Future<({String id, String key})> me() async => (id: 'me', key: '');
  @override
  String? get username => 'me';
  @override
  String get displayName => 'Me';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => '[]';
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => false;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}

void main() {
  setUp(() => Buddies.instance = Buddies(_NoBuddies()));
  tearDown(() => Buddies.instance = null);

  testWidgets('a message report: Send waits for a reason, then sends it with the messages, blocks where asked, and is listed here', (tester) async {
    final h = await SpaceHarness.load(tester);
    final sent = <AbuseReport>[];
    final blocked = <String>[];
    await h.shoot(
      tester,
      ReportForm(
        target: _target,
        send: (r) async {
          sent.add(r);
          return '0123456789abcdef';
        },
        block: (t) async => blocked.add(t.id),
      ),
      'report-message',
    );
    expect(find.text('something nasty'), findsOneWidget, reason: 'what goes with it is shown');
    await _press(tester, 'report-send');
    expect(sent, isEmpty, reason: 'no reason chosen yet');

    await _press(tester, 'report-reason-harassment');
    await tester.enterText(find.byKey(const ValueKey('report-note')), 'Every day this week.');
    await tester.pump();
    await _press(tester, 'report-block');
    await _press(tester, 'report-send');
    await tester.pump();
    await tester.pump();

    final r = sent.single;
    expect(r.kind, 'message');
    expect(r.reason, ReportReason.harassment);
    expect(r.note, 'Every day this week.');
    expect(r.subjectId, _target.id);
    expect(r.subjectUsername, 'pest');
    expect([for (final m in r.messages) if (m.reported) m.text], ['something nasty']);
    expect(r.messages, hasLength(3));
    expect(blocked, [_target.id]);

    final app = AppState.of(tester.element(find.byType(ReportForm)));
    final made = MadeReport.readAll(app.choice(reportsMadeKey, '[]'));
    expect(made.single.id, '0123456789abcdef');
    expect(made.single.who, '@pest');
    expect(made.single.blocked, isTrue);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a person report has no messages; someone with no Uplink id is not offered Block', (tester) async {
    final h = await SpaceHarness.load(tester);
    final sent = <AbuseReport>[];
    await h.shoot(tester, ReportForm(target: const ReportTarget(id: '', username: 'pest', name: 'Pest', place: 'profile'), send: (r) async => (sent..add(r)).isEmpty ? '' : 'fedcba9876543210'), 'report-person');
    expect(find.byKey(const ValueKey('report-block')), findsNothing);
    await _press(tester, 'report-reason-impersonation');
    await _press(tester, 'report-send');
    await tester.pump();
    expect(sent.single.kind, 'person');
    expect(sent.single.messages, isEmpty);
    await tester.pump(const Duration(seconds: 6));
  });

  // Second review of the web client: a report goes to Uplink's own review, which a page reaches only where it
  // was made for gogho.st's hub (app.gogho.st: its policy names the address, the relay lets it read the answer). A page
  // made for another relay says where to report from instead, and still offers Block.
  test('a report goes from anywhere but a page made for a relay not Uplink\'s', () {
    expect(reportsGoFromHere(browser: false, hub: 'wss://relay.example.com/hub'), isTrue);
    expect(reportsGoFromHere(browser: false, hub: Net.defaultHub), isTrue);
    expect(reportsGoFromHere(browser: true, hub: 'wss://gogho.st/hub'), isTrue);
    expect(reportsGoFromHere(browser: true, hub: 'wss://ghost-sms.com/hub'), isTrue);
    expect(reportsGoFromHere(browser: true, hub: 'wss://relay.example.com/hub'), isFalse);
    expect(reportsGoFromHere(browser: true, hub: 'ws://127.0.0.1:18990/hub'), isFalse);
  });

  testWidgets('in a page made for another relay the sheet says where to report from, and Block still works', (tester) async {
    final was = (Sms.browser, Net.homeHub);
    addTearDown(() {
      Sms.browser = was.$1;
      Net.homeHub = was.$2;
    });
    Sms.browser = true;
    Net.homeHub = 'wss://relay.example.com/hub';
    final h = await SpaceHarness.load(tester);
    final sent = <AbuseReport>[], blocked = <String>[];
    await h.shoot(tester, ReportForm(target: _target, send: (r) async => (sent..add(r)).isEmpty ? '' : 'x', block: (t) async => blocked.add(t.id)), 'report-not-here');
    expect(find.byKey(const ValueKey('report-not-here')), findsOneWidget);
    expect(find.textContaining('which this page can\'t reach: it was made for relay.example.com. Report @pest from app.gogho.st, or from Uplink on your phone or computer.'), findsOneWidget);
    expect(find.byKey(const ValueKey('report-send')), findsNothing);
    await _press(tester, 'report-block-only');
    await tester.pump();
    expect(blocked, [_target.id]);
    expect(sent, isEmpty);
    await tester.pump(const Duration(seconds: 6));

    // Made for gogho.st's hub (app.gogho.st): the form, as everywhere else.
    Net.homeHub = Net.defaultHub;
    await h.shoot(tester, ReportForm(key: const ValueKey('own'), target: _target, send: (r) async => 'x'), 'report-from-app-gogho-st');
    expect(find.byKey(const ValueKey('report-not-here')), findsNothing);
    expect(find.byKey(const ValueKey('report-reason-spam')), findsOneWidget);
  });

  testWidgets('a refusal is said and the form stays', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, ReportForm(target: _target, send: (r) async => throw const MarketError('rate_limited', 'That\'s a lot at once. Try again later.')), 'report-refused');
    await _press(tester, 'report-reason-spam');
    await _press(tester, 'report-send');
    await tester.pump();
    expect(find.text('That\'s a lot at once. Try again later.'), findsOneWidget);
    expect(find.byType(ReportForm), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Reports you\'ve made lists what this device reported, newest first', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, const SingleChildScrollView(child: ReportsMadeList()), 'reports-made-empty');
    expect(find.byKey(const ValueKey('reports-made-none')), findsOneWidget);
    final app = AppState.of(tester.element(find.byType(ReportsMadeList)));
    var raw = '[]';
    raw = MadeReport.withAdded(raw, MadeReport(id: 'one', kind: 'person', reason: ReportReason.spam, who: '@older', where: 'Their profile', at: DateTime(2026, 11, 20).millisecondsSinceEpoch));
    raw = MadeReport.withAdded(raw, MadeReport(id: 'two', kind: 'message', reason: ReportReason.harassment, who: '@newer', where: 'Book club', at: DateTime(2026, 11, 22).millisecondsSinceEpoch, blocked: true));
    app.set(reportsMadeKey, raw);
    await tester.pump();
    expect(find.text('@newer · Harassment'), findsOneWidget);
    expect(find.text('A message · Book club · 22 Nov 2026 · blocked'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const ValueKey('reports-made-two'))).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('reports-made-one'))).dy));
  });

  testWidgets('a space message is reported with what was said round it in the same chat, the writer known by their id', (tester) async {
    final h = await SpaceHarness.load(tester);
    final room = h.room(threaded: true);
    final sent = <AbuseReport>[];
    await h.shoot(
      tester,
      Builder(builder: (context) => Center(child: GestureDetector(key: const ValueKey('open'), behavior: HitTestBehavior.opaque, onTap: () => reportSpaceMessage(context, room, room.messages.firstWhere((m) => m.id == '2'), send: (r) async => (sent..add(r)).isEmpty ? '' : 'aaaaaaaaaaaaaaaa'), child: const SizedBox(width: 100, height: 40)))),
      'report-space',
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Report message'), findsOneWidget);
    await _press(tester, 'report-reason-spam');
    await _press(tester, 'report-send');
    await tester.pump();
    final r = sent.single;
    expect(r.place, 'space');
    expect(r.placeName, 'Friday hang');
    expect(r.subjectId, 'a');
    // The chat's own messages, not the thread's, oldest first.
    expect([for (final m in r.messages) m.text], ['Starting the movie in 10, hop in', 'Bring snacks 🍿', 'On my way!', 'Saving you a seat']);
    expect([for (final m in r.messages) if (m.reported) m.text], ['Bring snacks 🍿']);
    expect([for (final m in r.messages) if (m.mine) m.text], ['Saving you a seat']);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the reviewer\'s page opens what is sealed to this device\'s key, says what can\'t be opened, and marks done', (tester) async {
    final h = await SpaceHarness.load(tester);
    final reviewer = NetKeys.generate(), reporter = NetKeys.generate(), other = NetKeys.generate();
    final report = AbuseReport(kind: 'message', reason: ReportReason.harassment, note: 'Every day.', subjectId: 'b' * 32, subjectUsername: 'pest', subjectName: 'Pest', place: 'space', placeName: 'Book club', messages: _target.messages, reporterUsername: 'ada', at: DateTime(2026, 11, 22, 9).millisecondsSinceEpoch);
    final mine = (await tester.runAsync(() => sealReport(report, signer: KeysSigner(reporter), reviewKeys: [base64Encode(reviewer.public)])))!;
    final notMine = (await tester.runAsync(() => sealReport(report, signer: KeysSigner(reporter), reviewKeys: [base64Encode(other.public)])))!;
    final asked = <String>[];
    var done = false;
    final api = MarketApi(
      hubUrl: 'http://127.0.0.1:9/hub',
      signer: KeysSigner(reviewer),
      transport: (method, url, headers, body, {required most}) async {
        asked.add('$method ${url.path}');
        final answer = switch ('$method ${url.path}') {
          'GET /market/abuse' => {
              'ok': true,
              'reports': [
                {'rid': '1111111111111111', 'sealed': mine, 'at': 2, 'done': done, 'doneAt': null},
                {'rid': '2222222222222222', 'sealed': notMine, 'at': 1, 'done': false, 'doneAt': null},
              ],
            },
          'POST /market/abuse/1111111111111111' => () {
              done = true;
              return {'ok': true};
            }(),
          _ => {'ok': false, 'error': 'not_found', 'message': 'No.'},
        };
        return (status: 200, headers: const <String, String>{}, body: Uint8List.fromList(utf8.encode(jsonEncode(answer))));
      },
    );
    await h.shoot(tester, PeopleReportsScreen(api: api, keys: () async => reviewer), 'people-reports');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('@pest · Harassment'), findsOneWidget);
    expect(find.text('Can\'t be opened on this device'), findsOneWidget);
    expect(asked, ['GET /market/abuse']);

    await tester.tap(find.text('@pest · Harassment'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('something nasty'), findsOneWidget);
    expect(find.textContaining('their signature checks out'), findsOneWidget);
    expect(find.textContaining('Uplink id ${reporter.id}'), findsOneWidget);
    Navigator.of(tester.element(find.text('something nasty'))).pop();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byKey(const ValueKey('people-report-done-1111111111111111')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(asked.last, 'POST /market/abuse/1111111111111111');
    expect(done, isTrue);
    expect(find.text('Done'), findsWidgets);
    await tester.pump(const Duration(seconds: 6));
  });

  test('openAll opens each row with the key given, and leaves the rest closed', () async {
    final reviewer = NetKeys.generate(), reporter = NetKeys.generate();
    const r = AbuseReport(kind: 'person', reason: ReportReason.spam, subjectId: '', subjectUsername: 'x', place: 'profile', at: 5);
    final sealed = await sealReport(r, signer: KeysSigner(reporter), reviewKeys: [base64Encode(reviewer.public)]);
    final rows = openAll([
      SealedReportRow(rid: '1111111111111111', sealed: sealed, at: 1),
      SealedReportRow(rid: '2222222222222222', sealed: base64Encode(List.filled(200, 3)), at: 2),
    ], reviewer);
    expect(rows.first.opened!.report.subjectUsername, 'x');
    expect(rows.last.opened, isNull);
  });
}
