import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_models.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/ui/market/market_forms.dart';
import 'package:ghost_messaging/ui/market/my_submissions.dart';
import 'package:ghost_messaging/ui/market/submit_screen.dart';

import 'support/list_harness.dart';
import 'support/market_fakes.dart';

/// Marketplace › My submissions (lib/ui/market/my_submissions.dart; Matt, 2026-11-20: "I would like users to be able to
/// develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the store
/// through a review process", and "a listing process"): each status in words, the notes and a plugin's note, a blocked
/// account, withdrawing, taking a plugin off the Marketplace and listing it again, a new version from an approved one,
/// and the toasts a developer hears without opening it, each change once.
Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  late Directory dir;
  InstalledPlugins? installed;
  late FakeRelay relay;
  late MarketState market;
  late MarketApi api;
  late AppState state;
  final copied = <String>[];
  final oldInstalled = InstalledPlugins.instance, oldMarket = MarketState.instance, oldRegistry = PluginRegistry.instance;

  setUp(() {
    ListPhone(const []).install();
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(((call.arguments as Map)['text'] as String?) ?? '');
      return null;
    });
    dir = Directory.systemTemp.createTempSync('market-mine-');
    PluginRegistry.instance = PluginRegistry(shippedPlugins);
    installed = null;
    relay = FakeRelay();
    api = MarketApi(hubUrl: 'https://relay.test', signer: devSigner, transport: relay.call);
    // It reads InstalledPlugins.instance as it goes: each test puts its own in place.
    market = MarketState(api: () => api, cache: Directory('${dir.path}/market'), appVersion: '0.10.1');
    MarketState.instance = market;
    state = AppState();
  });
  tearDown(() {
    InstalledPlugins.instance = oldInstalled;
    MarketState.instance = oldMarket;
    PluginRegistry.instance = oldRegistry;
    dir.deleteSync(recursive: true);
  });

  /// This device's packs, read for the app the page draws from: made inside the test, whose zone its work runs in, the
  /// first time the test asks.
  Future<InstalledPlugins> ready() async => installed ??= InstalledPlugins.instance = await installedFor(state, Directory('${dir.path}/plugins'));

  Future<void> page(WidgetTester tester, {MarketApi? with_, String? highlight}) async {
    await ready();
    await tester.pumpWidget(const SizedBox());
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, MySubmissionsScreen(api: with_ ?? api, market: market, highlight: highlight), state, size: const Size(412, 5200));
  }

  Uint8List bills({String version = '1.0.0', String id = 'mybills', List<String> shots = const []}) => packFile(billsJson(id: id), (j) {
        j['version'] = version;
        j['developer'] = 'maya';
        j['shots'] = shots;
      });

  String status(WidgetTester tester, String sid) => tester.widget<Text>(_key('market-mine-status-$sid')).data!;

  test('each status in words, a withdrawal by review with its reason', () {
    SubmissionView v(String status, {String? listing, int? revokedAt}) => SubmissionView(sid: 'a' * 24, plugin: 'mybills', version: '1.0.0', status: status, listing: listing, revokedAt: revokedAt, revokedWhy: revokedAt == null ? null : 'It mutes texts it shouldn\'t');
    expect(submissionStatusWords(v('submitted')), 'Waiting for review');
    expect(submissionStatusWords(v('in_review')), 'In review');
    expect(submissionStatusWords(v('changes_requested')), 'Changes asked for');
    expect(submissionStatusWords(v('approved')), 'Approved');
    expect(submissionStatusWords(v('approved', listing: 'listed')), 'Approved · listed');
    expect(submissionStatusWords(v('approved', listing: 'unlisted')), 'Approved · not listed');
    expect(submissionStatusWords(v('approved', listing: 'listed', revokedAt: 1)), 'Withdrawn by review: It mutes texts it shouldn\'t');
    expect(submissionStatusWords(v('rejected')), 'Not accepted');
    expect(submissionStatusWords(v('withdrawn')), 'Withdrawn');
    expect(submissionStatusWords(v('superseded')), 'Replaced by a newer version');
    // A new version: one higher where approved, the same where changes were asked for, and above the one listed.
    expect(resubmitVersion(v('approved')), '1.0.1');
    expect(resubmitVersion(v('changes_requested')), '1.0.0');
    expect(resubmitVersion(v('changes_requested'), current: '1.2.0'), '1.2.1');
  });

  testWidgets('no identity, nothing yet, and a Marketplace that can\'t be reached', (tester) async {
    await page(tester, with_: MarketApi(hubUrl: 'https://relay.test', transport: relay.call));
    expect(_key('market-mine-who'), findsOneWidget);
    expect(_key('market-mine-me'), findsOneWidget);
    await page(tester);
    expect(find.text('Nothing sent yet. Submit a plugin when you\'ve made one.'), findsOneWidget);
    relay.down = true;
    await page(tester);
    expect(find.text(marketUnreachableWords), findsOneWidget);
    relay.down = false;
    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(find.text('Nothing sent yet. Submit a plugin when you\'ve made one.'), findsOneWidget);
  });

  testWidgets('a plugin\'s heading and note, its submissions\' statuses, the one just sent marked, and blocked', (tester) async {
    final first = relay.store.put(bills(), status: 'approved');
    final second = relay.store.put(bills(version: '1.1.0'), status: 'changes_requested', reviewerNotes: [{'at': relay.store.now, 'by': 'reviewer', 'text': 'Say what it marks read in its description.', 'status': 'changes_requested'}]);
    final other = relay.store.put(bills(id: 'parcelsmine'), status: 'submitted', notes: 'Try it on s07.');
    relay.store.plugins['mybills']!['note'] = 'Back soon';
    relay.store.blocked = true;
    await page(tester, highlight: other);
    expect(_key('market-mine-blocked'), findsOneWidget);
    expect(find.text('Listed · Back soon'), findsOneWidget);
    expect(find.text('Not listed'), findsOneWidget, reason: 'parcelsmine has no approval yet');
    expect(status(tester, first), 'Approved · listed');
    expect(status(tester, second), 'Changes asked for');
    expect(status(tester, other), 'Waiting for review');
    expect(_key('market-mine-marked'), findsOneWidget);
    expect(find.descendant(of: _key('market-mine-marked'), matching: _key('market-mine-$other')), findsOneWidget);
    // A submission's page: its notes, the reviewer's and the developer's own.
    await tester.tap(_key('market-mine-$second'));
    await settle(tester);
    expect(_key('market-mine-item-$second'), findsOneWidget);
    expect(find.descendant(of: _key('market-mine-notes'), matching: find.text('Say what it marks read in its description.')), findsOneWidget);
    expect(find.descendant(of: _key('market-mine-notes'), matching: find.textContaining('Reviewer · ')), findsOneWidget);
    expect(find.text('Reads texts from numbers not in your contacts'), findsOneWidget, reason: 'what it can do, from its package');
  });

  testWidgets('Withdraw asks, then sends route 13; Copy the package', (tester) async {
    final sid = relay.store.put(bills(), status: 'submitted');
    await page(tester);
    await tester.tap(_key('market-mine-$sid'));
    await settle(tester);
    await tester.tap(_key('market-mine-copy'));
    await settle(tester);
    expect(copied.single, utf8.decode(bills()));
    expect(find.text('Package copied'), findsOneWidget);
    await tester.tap(_key('market-mine-withdraw'));
    await settle(tester);
    expect(find.text('It leaves the review queue. Send a new version whenever you\'re ready.'), findsOneWidget);
    await tester.tap(find.text('Withdraw').last);
    await settle(tester);
    expect(relay.paths.where((p) => p == 'DELETE https://relay.test/market/submissions/$sid'), hasLength(1));
    expect(relay.store.submissions[sid]!['status'], 'withdrawn');
    expect(_key('market-mine-withdraw'), findsNothing, reason: 'nothing open to withdraw now');
  });

  testWidgets('Take it off the Marketplace and List it again send route 17', (tester) async {
    relay.store.put(bills(), status: 'approved');
    await page(tester);
    await tester.tap(_key('market-mine-unlist-mybills'));
    await settle(tester);
    expect(find.text('People who added it keep it. Nobody new can add it until you list it again.'), findsOneWidget);
    await tester.tap(find.text('Take it off the Marketplace').last);
    await settle(tester);
    expect(relay.store.decided.last, {'plugin': 'mybills', 'route': 'listing', 'listed': false});
    expect(find.text('Approved, not listed'), findsOneWidget);
    await tester.tap(_key('market-mine-relist-mybills'));
    await settle(tester);
    expect(relay.store.decided.last, {'plugin': 'mybills', 'route': 'listing', 'listed': true});
    expect(find.text('Listed'), findsOneWidget);
    // Taken off by review, only review lists it again.
    relay.store.plugins['mybills']!
      ..['listing'] = 'unlisted'
      ..['by'] = 'admin';
    await page(tester);
    expect(_key('market-mine-relist-mybills'), findsNothing);
  });

  testWidgets('Submit a new version: one higher than the approved one, its screenshots kept', (tester) async {
    await tester.runAsync(() => Me.instance.start(MemoryMeStore()..set('me_username', 'maya'), ValueNotifier(0), () => null));
    addTearDown(() => tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null)));
    final shot = billsIcon;
    final sid = relay.store.put(bills(shots: [sha256Hex(shot)]), status: 'approved', shots: [shot]);
    await page(tester);
    await tester.tap(_key('market-mine-$sid'));
    await settle(tester);
    expect(_key('market-mine-shot-0'), findsOneWidget);
    await tester.tap(_key('market-mine-resubmit'));
    await settle(tester);
    final form = tester.widget<SubmitPluginScreen>(find.byType(SubmitPluginScreen));
    expect(form.start?.id, 'mybills');
    expect(form.startVersion, '1.0.1');
    expect(form.from?.sid, sid);
    expect(tester.widget<EditableText>(find.descendant(of: _key('market-submit-version'), matching: find.byType(EditableText))).controller.text, '1.0.1');
    expect(_key('market-submit-shot-0'), findsOneWidget);
    expect(find.text('Kept'), findsOneWidget);
  });

  testWidgets('a developer hears of each decision once, without opening My submissions', (tester) async {
    final told = <String>[];
    final sub = market.notices.listen((n) => told.add(n.words));
    addTearDown(sub.cancel);
    final a = relay.store.put(bills(), status: 'submitted');
    final b = relay.store.put(bills(id: 'parcelsmine'), status: 'submitted', list: 'later');
    final c = relay.store.put(bills(id: 'thirdone'), status: 'in_review');
    await tester.runAsync(market.readMine);
    expect(told, isEmpty, reason: 'nothing the first time');
    relay.store.submissions[a]!['status'] = 'changes_requested';
    relay.store.submissions[c]!['status'] = 'rejected';
    // Approved, waiting to be listed by its developer.
    relay.store.submissions[b]!['status'] = 'approved';
    relay.store.submissions[b]!['listing'] = 'unlisted';
    await tester.runAsync(market.readMine);
    await tester.pump();
    expect(told, unorderedEquals([
      'Bills 1.0.0: changes asked for. See Marketplace › My submissions.',
      'Bills 1.0.0 was approved. List it from My submissions when you\'re ready.',
      'Bills 1.0.0 wasn\'t accepted.',
    ]));
    await tester.runAsync(market.readMine);
    await tester.pump();
    expect(told, hasLength(3), reason: 'each change once');
    // Listed, then taken off by review.
    relay.store.submissions[b]!['listing'] = 'listed';
    relay.store.plugins['parcelsmine']!['listing'] = 'listed';
    await tester.runAsync(market.readMine);
    relay.store.plugins['parcelsmine']!
      ..['listing'] = 'unlisted'
      ..['by'] = 'admin';
    await tester.runAsync(market.readMine);
    await tester.pump();
    expect(told.last, 'Bills was taken off the Marketplace.');
    // What My submissions read itself is seen: no toast for it later.
    relay.store.submissions[a]!['status'] = 'superseded';
    final got = await tester.runAsync(api.mine);
    await tester.runAsync(() => market.seenMine(got!));
    final before = told.length;
    await tester.runAsync(market.readMine);
    await tester.pump();
    expect(told, hasLength(before));
  });
}
