import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/market/market_api.dart';
import 'package:ghost_messaging/market/market_state.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/plugins/pack/pack.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/admin_page.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostPage, IconTap;
import 'package:ghost_messaging/ui/market/reports_page.dart';
import 'package:ghost_messaging/ui/market/review_item.dart';
import 'package:ghost_messaging/ui/market/review_queue.dart';
import 'package:glacier/glacier.dart' show GlacierSwitch;

import 'support/list_harness.dart';
import 'support/market_fakes.dart';

/// The review (lib/ui/admin_page.dart, lib/ui/market/review_queue.dart, review_item.dart, reports_page.dart; Matt,
/// 2026-11-20: "I'd like to be able to verify them for the store through a review process"): Settings › Admin's Plugin
/// review rows and this device's key, its retirement, a computer that follows its phone; the queue, signing in where it
/// stands; a submission's checks, what to look at closely, You asked and what changed, Try it and the samples, the file;
/// Approve only where this build trusts the key and the package checks out, its approval and a withdrawal of the
/// version before signed by the request's own key; a decision kept across a sign-in; notes for changes and rejection;
/// listing, unlisting and withdrawing; the screenshots drawn in Dart; and the reports.
Finder _key(String k) => find.byKey(ValueKey(k));

/// A paired computer that follows its phone: Sms.followsPhone.
class _Followed implements SmsCalls {
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async => null;
}

void main() {
  late Directory dir;
  InstalledPlugins? installed;
  late FakeRelay relay;
  late MarketApi api;
  late AppState state;
  final admin = KeysSigner(NetKeys.generate());
  final adminKey = base64Encode(admin.publicKey);
  final copied = <String>[];
  final asked = <Map<String, Object?>>[];
  final oldInstalled = InstalledPlugins.instance, oldMarket = MarketState.instance, oldRegistry = PluginRegistry.instance, oldCalls = Sms.calls;

  setUp(() {
    ListPhone(const []).install();
    copied.clear();
    asked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add(((call.arguments as Map)['text'] as String?) ?? '');
      return null;
    });
    dir = Directory.systemTemp.createTempSync('market-review-');
    PluginRegistry.instance = PluginRegistry(shippedPlugins);
    installed = null;
    relay = FakeRelay();
    api = MarketApi(hubUrl: 'https://relay.test', signer: admin, transport: relay.call);
    // It reads InstalledPlugins.instance as it goes: each test puts its own in place.
    MarketState.instance = MarketState(api: () => api, cache: Directory('${dir.path}/market'), appVersion: '0.10.1');
    state = AppState();
  });
  tearDown(() {
    InstalledPlugins.instance = oldInstalled;
    MarketState.instance = oldMarket;
    PluginRegistry.instance = oldRegistry;
    Sms.calls = oldCalls;
    dir.deleteSync(recursive: true);
  });

  /// The relay's answers to the admin page: the sign-in, the people, the log.
  Future<Map<String, dynamic>> ask(Map<String, Object?> what) async {
    asked.add(what);
    return switch (what['dir']) {
      'admin-login' => what['pass'] == 'right' ? (() {
          relay.store.admin = true;
          return <String, dynamic>{'ok': true};
        })() : <String, dynamic>{'ok': false, 'err': 'That isn\'t right.'},
      'admin-users' => {'ok': true, 'users': const []},
      'admin-log' => {'ok': true, 'grants': const []},
      _ => {'ok': false},
    };
  }

  /// This build's review keys on this device, as the runtime holds them: the admin's own pinned unless [keys] says
  /// otherwise. Made inside the test, whose zone its work runs in.
  var made = 0;
  Future<InstalledPlugins> ready({List<String>? keys}) async => installed = InstalledPlugins.instance = await installedFor(state, Directory('${dir.path}/plugins-${made++}'), keys: keys ?? [adminKey]);

  Future<void> show(WidgetTester tester, Widget screen, {Size size = const Size(412, 6400)}) async {
    if (installed == null) await ready();
    await tester.pumpWidget(const SizedBox());
    final sheet = await loadSheet(tester);
    await pumpScreen(tester, sheet, screen, state, size: size);
  }

  Future<void> signIn(WidgetTester tester, {Finder? within}) async {
    Finder inside(String k) => within == null ? _key(k) : find.descendant(of: within, matching: _key(k));
    await tester.enterText(find.descendant(of: inside('admin-user'), matching: find.byType(EditableText)), 'wisp-keeper');
    await tester.enterText(find.descendant(of: inside('admin-pass'), matching: find.byType(EditableText)), 'right');
    await tester.tap(inside('admin-sign-in'));
    await settle(tester);
  }

  /// Engine and isolate work (a diff, a picture decoded in Dart) let through until [done]: a turn of the real event loop
  /// and a frame at a time, never a fixed wait, with a deadline far past what a machine with every core busy needs.
  Future<void> until(WidgetTester tester, bool Function() done) async {
    final watch = Stopwatch()..start();
    while (!done() && watch.elapsed < const Duration(seconds: 60)) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Uint8List bills({String version = '1.0.0', String id = 'mybills', void Function(Map<String, Object?> j)? change}) => packFile(billsJson(id: id), (j) {
        j['version'] = version;
        j['developer'] = 'maya';
        change?.call(j);
      });

  bool pressable(WidgetTester tester, String key) {
    final row = tester.widget<SettingRow>(_key(key));
    return row.onPress != null && !row.disabled;
  }

  String hint(WidgetTester tester, String key) => ((tester.widget<SettingRow>(_key(key)).hint as Text?)?.data) ?? '';

  testWidgets('Settings › Admin: Plugin review with the queue, this device\'s key and its retirement; with no market given, nothing throws', (tester) async {
    relay.store.put(bills(), status: 'submitted');
    relay.store.reports['0123456789abcdef'] = {'rid': '0123456789abcdef', 'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': '', 'username': null, 'verified': false, 'at': 1, 'done': false, 'doneAt': null};
    Widget panel(MarketApi? market) => GhostPage(title: 'Admin', body: SettingsPaneScope(finder: SettingsFinder(), child: ListView(padding: const EdgeInsets.all(16), children: [AdminPanel(ask: ask, market: market)])));
    await show(tester, panel(api));
    await signIn(tester);
    expect(_key('admin-plugin-review'), findsOneWidget);
    expect(hint(tester, 'admin-market'), '1 waiting · 1 report');
    expect(MarketState.instance.reviewWaiting, 1, reason: 'the Marketplace\'s own row hears it');
    expect(hint(tester, 'admin-market-key'), '${adminKey.substring(0, 12)}… · trusted by this build');
    await tester.tap(_key('admin-market-key'));
    await settle(tester);
    expect(copied.last, adminKey);
    // Its retirement: asked first, signed by the key itself, copied, nothing sent.
    final sent = relay.asked.length;
    await tester.tap(_key('admin-market-retire'));
    await settle(tester);
    expect(find.text('Keep it offline. Sending it later makes every build stop trusting this key, for good.'), findsOneWidget);
    await tester.tap(find.text('Make the retirement'));
    await settle(tester);
    await until(tester, () => copied.length == 2);
    final retirement = PackRetirement.fromJson(jsonDecode(copied.last) as Map);
    expect(retirement.key, adminKey);
    expect(verifyRetirement(retirement), isTrue);
    expect(relay.asked.length, sent);
    // A key this build doesn't pin.
    await ready(keys: [reviewKey]);
    await show(tester, panel(api));
    await signIn(tester);
    expect(hint(tester, 'admin-market-key'), '${adminKey.substring(0, 12)}… · not trusted by this build: its approvals wouldn\'t install');
    // No identity of its own, and the app's own Marketplace when none is given: said, never thrown.
    await show(tester, panel(MarketApi(hubUrl: 'https://relay.test', transport: relay.call)));
    await signIn(tester);
    expect(hint(tester, 'admin-market-key'), 'This device has no Uplink identity of its own: review from your phone.');
    expect(_key('admin-market-retire'), findsNothing);
    await show(tester, panel(null));
    await signIn(tester);
    expect(_key('admin-market'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a computer that follows its phone is sent to become the same you', (tester) async {
    Sms.calls = _Followed();
    expect(Sms.followsPhone, isTrue);
    await show(tester, GhostPage(title: 'Admin', body: ListView(children: [AdminPanel(ask: ask, market: api)])));
    expect(find.text('Reviewing needs your Uplink identity on this computer. Become the same you as your phone in Settings › Me.'), findsOneWidget);
    expect(_key('admin-same-you'), findsOneWidget);
    expect(_key('admin-sign-in'), findsNothing);
  });

  testWidgets('the queue: signed out by the relay it signs in right there, then reads the queue', (tester) async {
    final first = relay.store.put(bills(), status: 'approved');
    final update = relay.store.put(bills(version: '1.1.0', change: (j) => j['permissions'] = ['sort', 'copy', 'markread', 'write']), status: 'submitted');
    final fresh = relay.store.put(bills(id: 'parcelsmine'), status: 'in_review');
    relay.store.verified = false;
    relay.store.admin = false;
    await show(tester, ReviewQueueScreen(api: api, ask: ask));
    expect(_key('market-review-signin'), findsOneWidget);
    await signIn(tester, within: _key('market-review-signin'));
    expect(_key('market-review-signin'), findsNothing);
    expect(find.text('WAITING'), findsOneWidget);
    expect(find.text('IN REVIEW'), findsOneWidget);
    expect(hint(tester, 'market-review-$update'), 'Update from 1.0.0 · can now: write · developer not verified');
    expect(hint(tester, 'market-review-$fresh'), 'New plugin · developer not verified');
    expect(_key('market-review-$first'), findsOneWidget, reason: 'decided lately');
    expect(find.text('Reports · 0 open'), findsOneWidget);
  });

  testWidgets('a submission: its checks, what to look at closely, Try it on the samples, and the file', (tester) async {
    final sid = relay.store.put(bills(), status: 'submitted', notes: 'Try it on s01.');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(_key('market-review-item-$sid'), findsOneWidget);
    expect(_key('market-review-mismatch'), findsNothing);
    final checks = find.descendant(of: _key('market-review-checks'), matching: find.byType(Text));
    final said = [for (final e in checks.evaluate()) (e.widget as Text).data ?? ''];
    expect(said, containsAll(['SHA-256 matches', 'Sent canonical', 'No problems found']));
    expect(find.descendant(of: _key('market-review-what'), matching: find.text('Sorts texts into its own tabs and kinds')), findsOneWidget);
    expect(find.descendant(of: _key('market-review-risky'), matching: find.textContaining('rules.actions[0] (copy, "Copy the amount"): "{tag:bill}"')), findsOneWidget);
    expect(find.descendant(of: _key('market-review-risky'), matching: find.textContaining('rules.incoming[0]: marks read Receipts texts as they come, once "autoread" is on')), findsOneWidget);
    expect(find.descendant(of: _key('market-review-manifest'), matching: find.textContaining('"icon": <icon: ${billsIcon.length} bytes>')), findsOneWidget);
    expect(find.text('Try it on s01.'), findsOneWidget, reason: 'the developer\'s notes');
    expect(_key('market-review-start'), findsOneWidget);
    // Try it, as the app would run it: s01 is a bill of $45.20, in Bills, with its button.
    await tester.enterText(find.descendant(of: _key('market-review-try-text'), matching: find.byType(EditableText)), packSamples.first.text);
    await tester.tap(_key('market-review-try'));
    await settle(tester);
    final lines = [for (final e in find.descendant(of: _key('market-review-try-result'), matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? ''];
    expect(lines, contains('Tags: bill=\$45.20'));
    expect(lines, contains('It goes to Bills'));
    expect(lines.any((l) => l.contains('Copy the amount')), isTrue);
    expect(lines.any((l) => l.startsWith('In this app, ') && l.endsWith(' takes this text first')), isTrue, reason: 'Kinds of text sorts first');
    await tester.tap(find.text('Try the samples'));
    await settle(tester);
    final samples = [for (final e in find.descendant(of: _key('market-review-samples'), matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? ''];
    expect(samples.first, startsWith('s01 · Bills · bill=\$45.20'));
    expect(samples.where((l) => l.startsWith('s12 · nothing')), hasLength(1), reason: 'a sign-in code is left alone');
    // Started: its developer sees it's being reviewed.
    await tester.tap(_key('market-review-start'));
    await settle(tester);
    expect(relay.store.decided.last, containsPair('decision', 'start'));
    expect(relay.store.submissions[sid]!['status'], 'in_review');
  });

  testWidgets('a package that isn\'t the one the store lists says so, and can\'t be approved', (tester) async {
    final sid = relay.store.put(bills(), status: 'submitted');
    relay.store.submissions[sid]!['sha256'] = 'f' * 64;
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(find.text('This package isn\'t the one the store lists. Don\'t approve it.'), findsOneWidget);
    expect(find.text('SHA-256 doesn\'t match'), findsOneWidget);
    expect(pressable(tester, 'market-review-approve'), isFalse);
    expect(find.text('The plugin has problems.'), findsOneWidget);
  });

  testWidgets('Approve: only with a key this build pins and isn\'t retired, and a package that is the row\'s', (tester) async {
    final sid = relay.store.put(bills(), status: 'submitted');
    // Unpinned.
    await ready(keys: [reviewKey]);
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(pressable(tester, 'market-review-approve'), isFalse);
    expect(find.text('This build doesn\'t trust this device\'s key for reviews: its approvals wouldn\'t install.'), findsOneWidget);
    // Pinned, then retired by its own signature, as the revoked list would hand it over.
    await retire(await ready(), admin);
    expect(installed!.retiredKeys, {adminKey});
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(pressable(tester, 'market-review-approve'), isFalse);
    expect(find.text('This build doesn\'t trust this device\'s key for reviews: its approvals wouldn\'t install.'), findsOneWidget);
    await ready();
    // A row whose version isn't its package's.
    relay.store.submissions[sid]!['version'] = '9.9.9';
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(pressable(tester, 'market-review-approve'), isFalse);
    expect(find.text('The plugin has problems.'), findsOneWidget);
    relay.store.submissions[sid]!['version'] = '1.0.0';
    // No identity of its own.
    await show(tester, ReviewItemScreen(sid, api: MarketApi(hubUrl: 'https://relay.test', transport: relay.call), ask: ask));
    expect(find.textContaining('Reviewing needs your Uplink identity on this'), findsOneWidget);
    // Pinned: the approval is over the package's own id and version and the SHA-256 worked out here, by the key that
    // signs the request.
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(pressable(tester, 'market-review-approve'), isTrue);
    await tester.tap(_key('market-review-approve'));
    await settle(tester);
    final d = relay.store.decided.last;
    expect(d['decision'], 'approve');
    final approval = PackApproval.fromJson(d['approval'] as Map);
    final sha = relay.store.submissions[sid]!['sha256'] as String;
    expect(sha, sha256Hex(bills()));
    expect(verifyApproval(approval, plugin: 'mybills', version: '1.0.0', sha256: sha, keys: [adminKey]), isTrue);
    expect(approval.key, d['key'], reason: 'the request\'s own key');
    expect(d.containsKey('revokes'), isFalse, reason: 'the version before is kept unless asked');
    expect(find.text('Approved and listed'), findsOneWidget);
  });

  testWidgets('an update: what\'s new in it, the change since the version listed, and the version before withdrawn too', (tester) async {
    final before = bills();
    relay.store.put(before, status: 'approved');
    final sid = relay.store.put(bills(version: '1.1.0', change: (j) => j['tagline'] = 'Bills, in a tab of their own'), status: 'submitted');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    await until(tester, () => find.descendant(of: _key('market-review-diff'), matching: find.textContaining('+ ')).evaluate().isNotEmpty);
    final diff = [for (final e in find.descendant(of: _key('market-review-diff'), matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? ''];
    expect(diff, contains('-   "tagline": "Bills and payment reminders in a tab of their own",'));
    expect(diff, contains('+   "tagline": "Bills, in a tab of their own",'));
    expect(diff, contains('+   "version": "1.1.0"'));
    await tester.tap(_key('market-review-revoke-previous'));
    await settle(tester);
    expect(tester.widget<GlacierSwitch>(_key('market-review-revoke-previous')).checked, isTrue);
    await tester.tap(_key('market-review-approve'));
    await settle(tester);
    final d = relay.store.decided.last;
    final revokes = [for (final r in d['revokes'] as List) PackRevocation.fromJson(r as Map)];
    expect(revokes, hasLength(1));
    expect(revokes.single.sha256, sha256Hex(before));
    expect(revokes.single.why, 'Replaced by 1.1.0: update it from its page.');
    expect(verifyRevocation(revokes.single, keys: [adminKey]), isTrue);
  });

  testWidgets('You asked, and what changed since; a decision refused for a sign-in is sent again, its note kept', (tester) async {
    relay.store.put(bills(), status: 'changes_requested', reviewerNotes: [{'at': 1, 'by': 'reviewer', 'text': 'Say in its description that it marks receipts read.', 'status': 'changes_requested'}]);
    final sid = relay.store.put(bills(version: '1.0.1', change: (j) => j['description'] = '${j['description']} It can mark receipts read.'), status: 'submitted');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(find.text('You asked: Say in its description that it marks receipts read.'), findsOneWidget);
    await until(tester, () => find.descendant(of: _key('market-review-diff-asked'), matching: find.textContaining('+ ')).evaluate().isNotEmpty);
    expect(find.descendant(of: _key('market-review-diff-asked'), matching: find.textContaining('It can mark receipts read.')), findsOneWidget);
    // Changes and Reject need a note.
    await tester.tap(_key('market-review-changes'));
    await settle(tester);
    expect(find.text('Say what to change in the note first.'), findsOneWidget);
    await tester.tap(_key('market-review-reject'));
    await settle(tester);
    expect(find.text('Say why in the note first.'), findsOneWidget);
    expect(relay.store.decided, isEmpty);
    // Signed out by the relay: the sign-in in a sheet, then the same decision again.
    relay.store.decideRefusals.add((status: 403, body: {'ok': false, 'error': 'not_admin', 'message': 'Sign in on Settings › Admin again to do that.'}));
    await tester.enterText(find.descendant(of: _key('market-review-note'), matching: find.byType(EditableText)), 'Say which kind it adds, too.');
    await tester.tap(_key('market-review-changes'));
    await settle(tester);
    expect(_key('market-review-signin-sheet'), findsOneWidget);
    await signIn(tester, within: _key('market-review-signin-sheet'));
    await settle(tester);
    expect(relay.store.decided.map((d) => d['refused'] ?? d['decision']), ['not_admin', 'changes']);
    expect(relay.store.decided.last['note'], 'Say which kind it adds, too.');
    expect(relay.store.decided.first['note'], 'Say which kind it adds, too.', reason: 'the same decision');
    expect(relay.store.submissions[sid]!['status'], 'changes_requested');
  });

  testWidgets('a decision that can\'t reach the Marketplace is kept, its note with it, and Try again sends it as it was', (tester) async {
    final sid = relay.store.put(bills(), status: 'in_review');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    await tester.enterText(find.descendant(of: _key('market-review-note'), matching: find.byType(EditableText)), 'Thanks: a clear one.');
    relay.down = true;
    await tester.tap(_key('market-review-approve'));
    await settle(tester);
    expect(find.text('Couldn\'t reach the Marketplace. Try again in a moment.'), findsOneWidget);
    expect(_key('market-review-again'), findsOneWidget);
    expect(relay.store.decided, isEmpty);
    final tried = relay.asked.where((r) => r.method == 'POST' && r.url.path == '/market/review/$sid').single;
    final first = PackApproval.fromJson((jsonDecode(utf8.decode(tried.body)) as Map)['approval'] as Map);
    relay.down = false;
    await tester.tap(_key('market-review-again'));
    await settle(tester);
    final d = relay.store.decided.single;
    expect(d['decision'], 'approve');
    expect(d['note'], 'Thanks: a clear one.');
    expect(PackApproval.fromJson(d['approval'] as Map).toJson(), first.toJson(), reason: 'the same approval, sent again');
    expect(verifyApproval(first, plugin: 'mybills', version: '1.0.0', sha256: sha256Hex(bills()), keys: [adminKey]), isTrue);
    expect(_key('market-review-again'), findsNothing);
    expect(relay.store.submissions[sid]!['status'], 'approved');
  });

  testWidgets('Unlist, List again and Withdraw this version send C\'s bodies', (tester) async {
    relay.store.unlistedBy = 'admin';
    final sid = relay.store.put(bills(), status: 'approved');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    await tester.tap(_key('market-review-unlist'));
    await settle(tester);
    await tester.tap(find.text('Unlist').last);
    await settle(tester);
    expect(relay.store.decided.last, {'plugin': 'mybills', 'route': 'listing', 'listed': false});
    await tester.tap(_key('market-review-relist'));
    await settle(tester);
    await tester.tap(find.text('List again').last);
    await settle(tester);
    expect(relay.store.decided.last, {'plugin': 'mybills', 'route': 'listing', 'listed': true});
    await tester.tap(_key('market-review-revoke'));
    await settle(tester);
    await tester.enterText(find.byType(EditableText).last, 'It mutes texts it shouldn\'t');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    await tester.tap(find.text('Withdraw this version').last);
    await settle(tester);
    await until(tester, () => relay.store.decided.last['route'] == 'revoke');
    final r = PackRevocation.fromJson(relay.store.decided.last);
    expect(r.sha256, sha256Hex(bills()));
    expect(r.why, 'It mutes texts it shouldn\'t');
    expect(verifyRevocation(r, keys: [adminKey]), isTrue);
  });

  testWidgets('the developer: who they are, and blocking them with their plugins unlisted too', (tester) async {
    final sid = relay.store.put(bills(), status: 'submitted');
    relay.store.verified = false;
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(find.descendant(of: _key('market-review-developer'), matching: find.textContaining('@maya · 1 plugin · 1 submission · first ')), findsOneWidget);
    expect(find.text('Number not verified'), findsOneWidget);
    await tester.tap(_key('market-review-block'));
    await settle(tester);
    await tester.tap(find.text('Block @maya, and unlist their plugins too'));
    await settle(tester);
    expect(relay.store.decided.last, {'block': 'd' * 32, 'blocked': true, 'unlist': true});
    expect(find.text('Let them submit again'), findsOneWidget);
  });

  testWidgets('screenshots are drawn by the Dart decoder alone; an interlaced one can\'t be shown here', (tester) async {
    final plain = billsIcon;
    final interlaced = Uint8List.fromList(billsIcon)..[28] = 1;
    final sid = relay.store.put(bills(change: (j) => j['shots'] = [sha256Hex(plain), sha256Hex(interlaced)]), status: 'submitted', shots: [plain, interlaced]);
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    await until(tester, () => find.byType(RawImage).evaluate().isNotEmpty && find.text('Can\'t show this picture here').evaluate().isNotEmpty);
    expect(find.descendant(of: _key('market-review-shot-0'), matching: find.byType(RawImage)), findsOneWidget);
    expect(find.descendant(of: _key('market-review-shot-1'), matching: find.text('Can\'t show this picture here')), findsOneWidget);
    expect(find.descendant(of: _key('market-review-listing'), matching: find.byType(Image)), findsNothing, reason: 'never the platform\'s codecs');
    expect(find.text('Check the screenshots show no real person\'s texts or number.'), findsOneWidget);
  });

  testWidgets('reports: each with its reason, words and who, and Mark done', (tester) async {
    relay.store.reports['0123456789abcdef'] = {'rid': '0123456789abcdef', 'plugin': 'mybills', 'version': '1.0.0', 'reason': 'privacy', 'text': 'It asked to mark everything read.', 'username': 'kevin', 'verified': true, 'at': 1763600000000, 'done': false, 'doneAt': null};
    relay.store.reports['fedcba9876543210'] = {'rid': 'fedcba9876543210', 'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': '', 'username': null, 'verified': false, 'at': 1763600000000, 'done': false, 'doneAt': null};
    await show(tester, ReportsScreen(api: api));
    expect(_key('market-reports'), findsOneWidget);
    expect(find.text('mybills 1.0.0 · It asks too much of my texts'), findsOneWidget);
    expect(find.textContaining('@kevin (verified)'), findsOneWidget);
    expect(find.textContaining('No username'), findsOneWidget);
    await tester.tap(_key('market-report-done-0123456789abcdef'));
    await settle(tester);
    expect(relay.store.decided.last, {'resolved': '0123456789abcdef'});
    expect(_key('market-report-done-0123456789abcdef'), findsNothing);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('reports signed out by the relay sign in right there, and Mark done refused for it is done after a sign-in', (tester) async {
    // A relay restarted with a deploy, or 8 hours gone: the page said "Sign in on Settings › Admin again" with no way
    // to, outside the Marketplace (review, 2026-11-20).
    relay.store.reports['0123456789abcdef'] = {'rid': '0123456789abcdef', 'plugin': 'mybills', 'version': '1.0.0', 'reason': 'spam', 'text': '', 'username': null, 'verified': false, 'at': 1763600000000, 'done': false, 'doneAt': null};
    relay.store.admin = false;
    await show(tester, ReportsScreen(api: api, ask: ask));
    expect(_key('market-reports-signin'), findsOneWidget);
    await signIn(tester, within: _key('market-reports-signin'));
    expect(_key('market-reports-signin'), findsNothing);
    expect(_key('market-report-done-0123456789abcdef'), findsOneWidget);
    relay.store.admin = false;
    await tester.tap(_key('market-report-done-0123456789abcdef'));
    await settle(tester);
    expect(_key('market-reports-signin-sheet'), findsOneWidget);
    await signIn(tester, within: _key('market-reports-signin-sheet'));
    await settle(tester);
    expect(relay.store.decided.last, {'resolved': '0123456789abcdef'});
    expect(_key('market-report-done-0123456789abcdef'), findsNothing);
    // Read again and signed out: said, with the sign-in, over the reports still shown.
    relay.store.admin = false;
    await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Refresh'));
    await settle(tester);
    expect(_key('market-reports-signin'), findsOneWidget);
    expect(find.text('mybills 1.0.0 · It\'s spam'), findsOneWidget);
  });

  testWidgets('a package of thousands of problems shows the first hundred, and how many more', (tester) async {
    // Any submitter's package could hold one problem in every few bytes, and the reviewer's screen drew a line for each:
    // minutes, on the one phone that holds the review key (review, 2026-11-20).
    final sid = relay.store.put(bills(change: (j) => ((j['rules'] as Map)['tags'] as List)[0] = {...(((j['rules'] as Map)['tags'] as List)[0] as Map), for (var i = 0; i < 4000; i++) 'k$i': 1}), status: 'submitted');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    final lines = [for (final e in find.descendant(of: _key('market-review-checks'), matching: find.byType(Text)).evaluate()) (e.widget as Text).data ?? ''];
    expect(lines.where((l) => l.startsWith('error unknown_field')), hasLength(packIssuesMost - 1));
    expect(lines.where((l) => l.startsWith('error too_many_issues')).single, endsWith('And 3901 more problems like these: fix the ones above and check it again.'));
  });

  testWidgets('its icon is drawn by the Dart decoder alone, over its symbol', (tester) async {
    final sid = relay.store.put(bills(), status: 'submitted');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    await until(tester, () => _key('market-review-icon').evaluate().isNotEmpty);
    expect(find.descendant(of: _key('market-review-head'), matching: find.byType(RawImage)), findsOneWidget);
    expect(find.descendant(of: _key('market-review-head'), matching: find.byType(Image)), findsNothing, reason: 'a stranger\'s icon never reaches the platform\'s codecs on the review device');
  });

  testWidgets('withdrawals are signed over the packages this device worked out, never over a hash the relay names', (tester) async {
    // A relay broken into could name another plugin's approved package as "the version before", or as the row's own:
    // one press then withdrew that plugin on every device (review, 2026-11-20).
    final before = bills();
    relay.store.put(before, status: 'approved');
    final victim = packFile(billsJson(id: 'victim'), (j) => j['developer'] = 'ada');
    final sid = relay.store.put(bills(version: '1.1.0'), status: 'submitted');
    final honest = relay.store.answer('GET', '/market/review/$sid', const {}, const [])!.body! as Map<String, Object?>;
    Map<String, Object?> lying(Map<String, Object?> previous) => {...honest, 'previous': previous};
    // The version before named by another plugin's hash.
    relay.answers['GET /market/review/$sid'] = (status: 200, body: lying({'version': '1.0.0', 'sha256': sha256Hex(victim), 'package': base64Encode(before)}));
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(_key('market-review-revoke-previous'), findsNothing);
    expect(_key('market-review-revoke-previous-off'), findsOneWidget);
    // Another plugin's package handed over as the version before, its own hash and all.
    relay.answers['GET /market/review/$sid'] = (status: 200, body: lying({'version': '1.0.0', 'sha256': sha256Hex(victim), 'package': base64Encode(victim)}));
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(_key('market-review-revoke-previous'), findsNothing, reason: 'its package isn\'t this plugin\'s');
    // The honest answer: offered, and signed over the hash worked out here.
    relay.answers.remove('GET /market/review/$sid');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(_key('market-review-revoke-previous'), findsOneWidget);
    // Withdraw this version, of a row whose hash isn't its package's: refused here, nothing signed.
    final approved = relay.store.submissions.values.firstWhere((s) => s['status'] == 'approved')['sid'] as String;
    final row = relay.store.answer('GET', '/market/review/$approved', const {}, const [])!.body! as Map<String, Object?>;
    relay.answers['GET /market/review/$approved'] = (status: 200, body: {...row, 'submission': {...(row['submission'] as Map), 'sha256': sha256Hex(victim)}});
    await show(tester, ReviewItemScreen(approved, api: api, ask: ask));
    expect(pressable(tester, 'market-review-revoke'), isFalse);
    expect(hint(tester, 'market-review-revoke'), 'This package isn\'t the one the store lists: it can\'t be withdrawn from here.');
    expect(relay.store.decided.where((d) => d['route'] == 'revoke'), isEmpty);
  });

  testWidgets('its screenshots and its "By @" are its package\'s own: a relay that names others holds Approve back', (tester) async {
    // An approval covers the package's own screenshots and developer, which every user's page draws; the screen drew the
    // relay's list and name, so a relay broken into could have pictures nobody saw approved, under another name (review,
    // 2026-11-20).
    final shot = billsIcon;
    final honest = relay.store.put(bills(change: (j) => j['shots'] = [sha256Hex(shot)]), status: 'submitted', shots: [shot]);
    await show(tester, ReviewItemScreen(honest, api: api, ask: ask));
    expect(hint(tester, 'market-review-approve'), isNot(contains('loading')));
    expect(pressable(tester, 'market-review-approve'), isFalse, reason: 'not before its screenshots are seen');
    expect(find.text('Its screenshots are still loading.'), findsOneWidget);
    await until(tester, () => find.descendant(of: _key('market-review-shot-0'), matching: find.byType(RawImage)).evaluate().isNotEmpty);
    expect(_key('market-review-listing-mismatch'), findsNothing);
    expect(pressable(tester, 'market-review-approve'), isTrue);
    // The package names one picture and one developer, the relay's row others, and it serves its own at route 12.
    final other = brokenPng();
    final lying = relay.store.put(bills(id: 'mycards', change: (j) {
      j['shots'] = [sha256Hex(shot)];
      j['developer'] = 'chasealerts';
    }), status: 'submitted', shots: [other]);
    relay.store.submissions[lying]!['developer'] = 'maya';
    await show(tester, ReviewItemScreen(lying, api: api, ask: ask));
    await until(tester, () => find.descendant(of: _key('market-review-shot-0'), matching: find.text('Not the picture its file names')).evaluate().isNotEmpty);
    expect(_key('market-review-listing-mismatch'), findsOneWidget);
    expect(find.descendant(of: _key('market-review-head'), matching: find.textContaining('@chasealerts')), findsOneWidget, reason: 'the "By @" its page will say');
    expect(pressable(tester, 'market-review-approve'), isFalse);
    expect(find.text('The store\'s listing isn\'t the one this package names. Don\'t approve it.'), findsWidgets);
    // A picture it names that can't be shown here can't be checked here either.
    final interlaced = Uint8List.fromList(billsIcon)..[28] = 1;
    final hidden = relay.store.put(bills(id: 'mytickets', change: (j) => j['shots'] = [sha256Hex(interlaced)]), status: 'submitted', shots: [interlaced]);
    await show(tester, ReviewItemScreen(hidden, api: api, ask: ask));
    await until(tester, () => find.text('Can\'t show this picture here').evaluate().isNotEmpty);
    expect(pressable(tester, 'market-review-approve'), isFalse);
    expect(find.text('A screenshot can\'t be shown on this device, so it can\'t be checked: ask for changes.'), findsOneWidget);
  });

  testWidgets('a screenshot that only failed to come is no sign the listing is wrong: Approve waits, and Refresh fetches it', (tester) async {
    // Any failure to fetch route 12 was counted with the mismatches, so a dropped connection or a busy relay put "Don't
    // approve it" at the top of an honest submission's page (review, 2026-11-20).
    final shot = billsIcon;
    final honest = relay.store.put(bills(change: (j) => j['shots'] = [sha256Hex(shot)]), status: 'submitted', shots: [shot]);
    for (final (status, error) in [(503, 'busy'), (429, 'rate_limited')]) {
      relay.answers['GET /market/submissions/$honest/shots/0'] = (status: status, body: {'ok': false, 'error': error, 'message': 'Too much at once. Try again in a minute.'});
      await show(tester, ReviewItemScreen(honest, api: api, ask: ask));
      await until(tester, () => find.descendant(of: _key('market-review-shot-0'), matching: find.text('Couldn\'t load this picture. Refresh to try again.')).evaluate().isNotEmpty);
      expect(_key('market-review-listing-mismatch'), findsNothing, reason: error);
      expect(find.text('The store\'s listing isn\'t the one this package names. Don\'t approve it.'), findsNothing, reason: error);
      expect(pressable(tester, 'market-review-approve'), isFalse, reason: '$error: not before its screenshots are seen');
      expect(find.text('A screenshot couldn\'t be loaded. Refresh to try again.'), findsOneWidget, reason: error);
      // Route 12 answers again: Refresh fetches it, and it can be approved.
      relay.answers.remove('GET /market/submissions/$honest/shots/0');
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Refresh'));
      await until(tester, () => find.descendant(of: _key('market-review-shot-0'), matching: find.byType(RawImage)).evaluate().isNotEmpty);
      expect(pressable(tester, 'market-review-approve'), isTrue, reason: error);
    }
  });

  testWidgets('reviewed on a computer, what it can do and what is new are as on a phone, where it does the most', (tester) async {
    // A computer's words leave out silencing and marking read as texts come, which every phone runs: an update that
    // added silencing showed nothing new there (review, 2026-11-20).
    relay.store.put(bills(), status: 'approved');
    final sid = relay.store.put(bills(version: '1.1.0', change: (j) {
      j['permissions'] = [...(j['permissions'] as List), 'mute'];
      ((((j['rules'] as Map)['incoming'] as List)[0]) as Map)['do'] = ['markread', 'mute'];
    }), status: 'submitted');
    Sms.calls = _Followed();
    expect(packHere(), 'computer');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(find.descendant(of: _key('market-review-what'), matching: find.text('As on a phone, where it does the most.')), findsOneWidget);
    expect(_key('market-review-new'), findsOneWidget);
    expect(find.descendant(of: _key('market-review-what'), matching: find.text('Can silence notifications')), findsNWidgets(2), reason: 'what it can do, and new in this version');
    expect(find.descendant(of: _key('market-review-what'), matching: find.text('Can silence Receipts texts as they come, once you switch it on')), findsNWidgets(2));
  });

  testWidgets('Withdraw this version only where this build pins this device\'s key: no app would take one by another', (tester) async {
    // The store took a withdrawal by a key no build pins, and every device dropped it: the plugin ran on everywhere
    // (review, 2026-11-20). A retired key's still count.
    final sid = relay.store.put(bills(), status: 'approved');
    await ready(keys: [reviewKey]);
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(pressable(tester, 'market-review-revoke'), isFalse);
    expect(hint(tester, 'market-review-revoke'), 'This build doesn\'t trust this device\'s key: no app would take its withdrawal.');
    await retire(await ready(), admin);
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(pressable(tester, 'market-review-revoke'), isTrue, reason: 'retired, its withdrawals still count');
  });

  testWidgets('a note the Marketplace would refuse is said here and nothing is sent; a listing\'s note is cut whole', (tester) async {
    // The relay holds review notes to a plugin's own rule for words and answered a slip with "Something in that isn't
    // right." alone; and the 500 a listing takes was cut through a space or half an emoji, which it refuses too
    // (review, 2026-11-20).
    final waiting = relay.store.put(bills(), status: 'in_review');
    await show(tester, ReviewItemScreen(waiting, api: api, ask: ask));
    Future<void> note(String words) async {
      await tester.enterText(find.descendant(of: _key('market-review-note'), matching: find.byType(EditableText)), words);
      await settle(tester);
    }

    await note('Lovely 🤦\u200D♀️');
    await tester.tap(_key('market-review-changes'));
    await settle(tester);
    expect(find.textContaining('The note: Emoji made of several'), findsOneWidget);
    expect(relay.store.decided, isEmpty);
    await tester.pump(const Duration(seconds: 6));
    await settle(tester);
    await note('Say which kind it adds.\r\nThanks!');
    await tester.tap(_key('market-review-changes'));
    await settle(tester);
    expect(relay.store.decided.single['note'], 'Say which kind it adds.\nThanks!');
    // A listing's note: the first 500 of the note, ending in no space and no half of an emoji.
    relay.store.unlistedBy = 'admin';
    final listed = relay.store.put(bills(id: 'mycards'), status: 'approved');
    await show(tester, ReviewItemScreen(listed, api: api, ask: ask));
    for (final (words, sent) in [('${'a' * 499} and more', 'a' * 499), ('${'a' * 499}😀 and more', 'a' * 499)]) {
      await note(words);
      await tester.tap(_key(relay.store.plugins['mycards']!['listing'] == 'listed' ? 'market-review-unlist' : 'market-review-relist'));
      await settle(tester);
      await tester.tap(find.text(relay.store.plugins['mycards']!['listing'] == 'listed' ? 'Unlist' : 'List again').last);
      await settle(tester);
      expect(relay.store.decided.last['note'], sent);
    }
  });

  testWidgets('on a phone, a sign-in a decision needs is on a page whose fields the keyboard leaves in sight', (tester) async {
    // A sheet rising from the foot of the screen sat under the keyboard once a field was pressed: its fields and Sign
    // in all hidden, for every approval half an hour after signing in (review, 2026-11-20).
    final sid = relay.store.put(bills(), status: 'in_review');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    relay.store.decideRefusals.add((status: 403, body: {'ok': false, 'error': 'not_admin', 'message': 'Sign in on Settings › Admin again to do that.'}));
    await tester.enterText(find.descendant(of: _key('market-review-note'), matching: find.byType(EditableText)), 'Say which kind it adds.');
    await tester.tap(_key('market-review-changes'));
    await settle(tester);
    expect(_key('market-review-signin-sheet'), findsOneWidget);
    // A phone's screen, 412 by 892, and the keyboard up over 320 of its points.
    tester.view.physicalSize = const Size(412, 892) * tester.view.devicePixelRatio;
    tester.view.viewInsets = FakeViewPadding(bottom: 320 * tester.view.devicePixelRatio);
    await settle(tester);
    await tester.tap(find.descendant(of: _key('admin-user'), matching: find.byType(EditableText)));
    await settle(tester);
    for (final k in ['admin-user', 'admin-pass', 'admin-sign-in']) {
      expect(tester.getRect(find.descendant(of: _key('market-review-signin-sheet'), matching: _key(k))).bottom, lessThanOrEqualTo(892 - 320), reason: k);
    }
    await signIn(tester, within: _key('market-review-signin-sheet'));
    await settle(tester);
    expect(relay.store.decided.map((d) => d['refused'] ?? d['decision']), ['not_admin', 'changes']);
    expect(_key('market-review-signin-sheet'), findsNothing, reason: 'its page gone once signed in');
  });

  testWidgets('a version of a plugin its developer took off is approved off the Marketplace, and the screen says so', (tester) async {
    // The relay keeps the developer's choice whatever the version's list says (C.6): the hint said "and listed" and the
    // toast "Approved and listed" while the developer was told to list it (review, 2026-11-20).
    final first = relay.store.put(bills(), status: 'approved');
    relay.store.plugins['mybills']!
      ..['listing'] = 'unlisted'
      ..['by'] = 'owner';
    relay.store.submissions[first]!['listing'] = 'unlisted';
    final sid = relay.store.put(bills(version: '1.1.0'), status: 'submitted');
    await show(tester, ReviewItemScreen(sid, api: api, ask: ask));
    expect(hint(tester, 'market-review-approve'), 'Signed here with this device\'s key, and listed, unless its developer took it off the Marketplace.');
    await tester.tap(_key('market-review-approve'));
    await settle(tester);
    expect(find.text('Approved: it stays off the Marketplace until its developer lists it'), findsOneWidget);
    expect(find.text('Approved and listed'), findsNothing);
  });

  test('the line diff: Myers\' shortest edit, and giving up past its bound', () {
    expect(lineDiff(['a', 'b', 'c'], ['a', 'x', 'c']), ['  a', '- b', '+ x', '  c']);
    expect(lineDiff(['a', 'b'], ['a', 'b', 'c']), ['  a', '  b', '+ c']);
    expect(lineDiff(['a', 'b', 'c', 'd'], ['b', 'd']), ['- a', '  b', '- c', '  d']);
    final a = [for (var i = 0; i < 3000; i++) 'a$i'], b = [for (var i = 0; i < 3000; i++) 'b$i'];
    expect(lineDiff(a, b), isNull, reason: 'too different to compare here');
    expect(lineDiff(a, b, most: 6000), hasLength(6000));
    expect(diffShown(['  1', '  2', '  3', '  4', '- 5', '+ 6', '  7', '  8', '  9']), ['  3', '  4', '- 5', '+ 6', '  7', '  8']);
    // Inside a phrase, anything outside printable ASCII is shown as itself would never be.
    expect(prettyPack({'rules': {'tags': [{'tag': 'x', 'any': ['pаy now']}]}}), contains('"p\\u{0430}y now"'));
  });
}
