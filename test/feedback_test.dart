import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/feedback/feedback_api.dart';
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/net/hub_carrier.dart' show KeysSigner;
import 'package:ghost_messaging/sms.dart' show Sms;
import 'package:ghost_messaging/ui/circles/members_drawer.dart' show MembersDrawer;
import 'package:ghost_messaging/ui/common.dart' show GhostPage;
import 'package:ghost_messaging/ui/feedback_screen.dart';

import 'support/space_call_harness.dart';

/// Share feedback (Matt, 2026-11-19: "add a "share feedback" button hovering in the topbar of the app ... upload
/// screenshots and explain a bug, suggest a feature ... optionally provide their username automatically so we can give
/// out bug bounties"): the request the app sends to the relay, and the form it is written in.

/// A relay of the test's own on 127.0.0.1: what it was sent, and what it answers.
class _Relay {
  _Relay._(this.server);
  final HttpServer server;
  final got = <({String method, String path, Map<String, String> headers, List<int> body})>[];
  int status = 200;
  Map<String, Object?> answer = {'ok': true, 'id': 'GMFB-12'};

  static Future<_Relay> start() async {
    final r = _Relay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    r.server.listen((req) async {
      final body = <int>[];
      await for (final b in req) {
        body.addAll(b);
      }
      final headers = <String, String>{};
      req.headers.forEach((name, values) => headers[name] = values.join(','));
      r.got.add((method: req.method, path: req.uri.path, headers: headers, body: body));
      req.response
        ..statusCode = r.status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(r.answer));
      await req.response.close();
    });
    return r;
  }

  String get hub => 'ws://127.0.0.1:${server.port}/hub';
}

FeedbackReport _report({String? username = 'matt', List<FeedbackShot> shots = const []}) => FeedbackReport(
      type: FeedbackType.bug,
      title: 'Send does nothing',
      text: 'I pressed Send and nothing happened.',
      username: username,
      platform: 'android',
      version: '0.9.33',
      shots: shots,
    );

/// Real sockets: a widget test in the same file puts a stand-in HttpClient that answers 400 to everything in place.
class _RealHttp extends HttpOverrides {}

Future<T> _real<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _RealHttp());

/// Scrolls the form until [key]'s row is drawn, and presses it.
Future<void> _press(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 120, scrollable: find.byType(Scrollable).first);
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pump();
}

void main() {
  group('the request', () {
    late _Relay relay;
    setUp(() async => relay = await _real(_Relay.start));
    tearDown(() => relay.server.close(force: true));

    test('is a signed POST to /feedback on the hub\'s server, with the report as JSON, answered with the ticket id', () => _real(() async {
      final keys = NetKeys.generate();
      final png = Uint8List.fromList(List.generate(64, (i) => i));
      final id = await sendFeedback(_report(shots: [FeedbackShot(name: 'screenshot.png', mime: 'image/png', bytes: png)]), signer: KeysSigner(keys), hubUrl: relay.hub);
      expect(id, 'GMFB-12');
      expect(relay.got, hasLength(1));
      final r = relay.got.single;
      expect(r.method, 'POST');
      expect(r.path, '/feedback');
      final m = (jsonDecode(utf8.decode(r.body)) as Map).cast<String, dynamic>();
      expect(m['type'], 'bug');
      expect(m['title'], 'Send does nothing');
      expect(m['text'], 'I pressed Send and nothing happened.');
      expect(m['username'], 'matt');
      expect(m['platform'], 'android');
      expect(m['version'], '0.9.33');
      expect(m['shots'], [
        {'name': 'screenshot.png', 'mime': 'image/png', 'data': base64Encode(png)},
      ]);
      // Signed by this key over the method, the path, the time and the body's hash.
      expect(r.headers['x-ghost-key'], base64Encode(keys.public));
      final time = r.headers['x-ghost-time']!;
      expect((int.parse(time) - DateTime.now().millisecondsSinceEpoch).abs(), lessThan(60000));
      final sha = NetCrypto.hex(NetCrypto.sha256(r.body));
      final words = utf8.encode('ghost-feedback v1\nPOST\n/feedback\n$time\n$sha');
      expect(NetCrypto.verify(keys.public, words, base64Decode(r.headers['x-ghost-sig']!)), isTrue);
      // Not over anything else.
      expect(NetCrypto.verify(keys.public, utf8.encode('ghost-feedback v1\nPOST\n/files\n$time\n$sha'), base64Decode(r.headers['x-ghost-sig']!)), isFalse);
    }));

    test('leaves the username out where it was not to be said', () => _real(() async {
      await sendFeedback(_report(username: null), signer: KeysSigner(NetKeys.generate()), hubUrl: relay.hub);
      final m = (jsonDecode(utf8.decode(relay.got.single.body)) as Map).cast<String, dynamic>();
      expect(m.containsKey('username'), isFalse);
      expect(m['shots'], isEmpty);
    }));

    test('an error the relay answers is a FeedbackError in its words', () => _real(() async {
      relay
        ..status = 503
        ..answer = {'error': 'Feedback isn\'t set up on this server yet.'};
      await expectLater(
        sendFeedback(_report(), signer: KeysSigner(NetKeys.generate()), hubUrl: relay.hub),
        throwsA(isA<FeedbackError>().having((e) => e.message, 'message', 'Feedback isn\'t set up on this server yet.').having((e) => e.status, 'status', 503)),
      );
    }));

    test('a server that can\'t be reached says so', () => _real(() async {
      final port = relay.server.port;
      await relay.server.close(force: true);
      await expectLater(
        sendFeedback(_report(), signer: KeysSigner(NetKeys.generate()), hubUrl: 'ws://127.0.0.1:$port/hub'),
        throwsA(isA<FeedbackError>().having((e) => e.message, 'message', contains('Couldn\'t reach the server'))),
      );
    }));
  });

  // In a browser, which has no dart:io: the page's own fetch (lib/web/http.dart), here a stand-in for it. The same
  // signed POST, the same answers (second review of the web client: "Report and feedback don't work in a browser").
  group('from a page', () {
    test('the same signed POST to /feedback on the hub\'s server, answered with the ticket id', () async {
      final keys = NetKeys.generate();
      final got = <({String method, Uri url, Map<String, String> headers, List<int> body})>[];
      final id = await sendFeedback(_report(username: null), signer: KeysSigner(keys), hubUrl: 'wss://gogho.st/hub', transport: (method, url, headers, body, {required most}) async {
        got.add((method: method, url: url, headers: headers, body: body));
        return (status: 200, headers: const <String, String>{}, body: Uint8List.fromList(utf8.encode('{"ok":true,"id":"GMFB-77"}')));
      });
      expect(id, 'GMFB-77');
      final r = got.single;
      expect(r.method, 'POST');
      expect(r.url.toString(), 'https://gogho.st/feedback');
      expect(r.headers['content-type'], 'application/json; charset=utf-8');
      expect((jsonDecode(utf8.decode(r.body)) as Map)['text'], 'I pressed Send and nothing happened.');
      expect(r.headers['x-ghost-key'], base64Encode(keys.public));
      final time = r.headers['x-ghost-time']!;
      final sha = NetCrypto.hex(NetCrypto.sha256(r.body));
      expect(NetCrypto.verify(keys.public, utf8.encode('ghost-feedback v1\nPOST\n/feedback\n$time\n$sha'), base64Decode(r.headers['x-ghost-sig']!)), isTrue);
    });

    test('the relay\'s refusal in its words; no answer the page may read is "couldn\'t reach"', () async {
      await expectLater(
        sendFeedback(_report(), signer: KeysSigner(NetKeys.generate()), hubUrl: 'wss://gogho.st/hub', transport: (method, url, headers, body, {required most}) async {
          return (status: 503, headers: const <String, String>{}, body: Uint8List.fromList(utf8.encode('{"error":"Feedback isn\'t set up on this server yet."}')));
        }),
        throwsA(isA<FeedbackError>().having((e) => e.message, 'message', 'Feedback isn\'t set up on this server yet.').having((e) => e.status, 'status', 503)),
      );
      // What a browser does where the relay doesn't let the page's address read the answer: fetch fails, as with no
      // answer at all.
      await expectLater(
        sendFeedback(_report(), signer: KeysSigner(NetKeys.generate()), hubUrl: 'wss://gogho.st/hub', transport: (method, url, headers, body, {required most}) async => throw StateError('TypeError: Failed to fetch')),
        throwsA(isA<FeedbackError>().having((e) => e.message, 'message', contains('Couldn\'t reach the server'))),
      );
    });

    test('a browser is said in the version, and as the platform the relay files with none', () {
      // Here, a computer: as before.
      expect(FeedbackReport.thisVersion('0.9.40'), '0.9.40');
      expect(FeedbackReport.thisPlatform, isNot('web'));
    });
  });

  // GMFB-25 ("features that only exist on gogho.st ... fall back cleanly"): on a relay of someone's own with no board
  // set up, feedback was answered "Feedback isn't set up on this server yet" and went nowhere.
  test('a relay of someone\'s own that takes no feedback: it goes to Uplink\'s instead; any other refusal is that relay\'s to say', () async {
    const own = 'wss://relay.example.com/hub', ours = 'wss://gogho.st/hub';
    final asked = <String>[];
    Future<String> Function(String) sender(Map<String, Object> answers) => (url) async {
          asked.add(url);
          final a = answers[url]!;
          if (a is FeedbackError) throw a;
          return a as String;
        };
    // It has a board of its own: filed there, and ours never hears of it.
    expect(await sendFeedbackOrOurs(hubUrl: own, ours: ours, mayLeave: true, send: sender({own: 'OWN-3'})), 'OWN-3');
    expect(asked, [own]);
    // None set up there (503), or a relay from before it took any (404): to ours.
    for (final status in [503, 404]) {
      asked.clear();
      expect(await sendFeedbackOrOurs(hubUrl: own, ours: ours, mayLeave: true, send: sender({own: FeedbackError('Feedback isn\'t set up on this server yet.', status: status), ours: 'GMFB-70'})), 'GMFB-70');
      expect(asked, [own, ours], reason: '$status');
    }
    // Anything else it says is said: too many, too large, unreachable.
    for (final e in [FeedbackError('Too many reports. Try again later.', status: 429), FeedbackError('Couldn\'t reach the server. Check your connection and try again.')]) {
      asked.clear();
      await expectLater(sendFeedbackOrOurs(hubUrl: own, ours: ours, mayLeave: true, send: sender({own: e, ours: 'GMFB-70'})), throwsA(same(e)));
      expect(asked, [own]);
    }
    // On ours there is nowhere else to go, and a page in a browser speaks only to the relay it came from.
    asked.clear();
    final off = FeedbackError('Feedback isn\'t set up on this server yet.', status: 503);
    await expectLater(sendFeedbackOrOurs(hubUrl: ours, ours: ours, mayLeave: true, send: sender({ours: off})), throwsA(same(off)));
    await expectLater(sendFeedbackOrOurs(hubUrl: own, ours: ours, mayLeave: false, send: sender({own: off, ours: 'GMFB-70'})), throwsA(same(off)));
    expect(asked, [ours, own]);
    expect(feedbackGoesWords(ours), 'It goes to the Uplink team.');
    expect(feedbackGoesWords(own), 'It goes to your relay\'s own feedback board where it has one, and to the Uplink team where it doesn\'t.');
  });

  test('the address is the hub\'s server with /feedback in place of /hub', () {
    expect(feedbackUrlFor('wss://gogho.st/hub').toString(), 'https://gogho.st/feedback');
    expect(feedbackUrlFor('ws://127.0.0.1:8787/hub').toString(), 'http://127.0.0.1:8787/feedback');
    expect(feedbackUrlFor('wss://example.com/relay/hub').toString(), 'https://example.com/relay/feedback');
  });

  testWidgets('the form: Send waits for a description, and sends the kind, title, words, screenshot and username', (tester) async {
    final h = await SpaceHarness.load(tester);
    final sent = <FeedbackReport>[];
    // A 1×1 PNG.
    final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==');
    await h.shoot(
      tester,
      FeedbackScreen(
        username: 'matt',
        send: (r) async {
          sent.add(r);
          return 'GMFB-12';
        },
        pickPictures: () async => [(name: 'screenshot.png', bytes: png)],
      ),
      'feedback',
    );
    expect(find.text('Include my username (@matt)'), findsOneWidget);
    await _press(tester, 'feedback-send');
    expect(sent, isEmpty);

    // Feature idea, from the select.
    await tester.tap(find.byKey(const ValueKey('feedback-type')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.tap(find.text('Feature idea').last);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Feature idea'), findsOneWidget);

    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('feedback-title')), matching: find.byType(EditableText)), 'Dark mode');
    await tester.pump();
    await _press(tester, 'feedback-send');
    expect(sent, isEmpty, reason: 'a title alone is not enough');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('feedback-text')), matching: find.byType(EditableText)), 'A darker dark mode, please.');
    await tester.pump();

    // A screenshot: picked, decoded off the test's clock, and shown with a way to remove it.
    await _press(tester, 'feedback-add-shot');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(find.byKey(const ValueKey('feedback-shot-0')), findsOneWidget);
    await h.again(tester, 'feedback-filled');

    await _press(tester, 'feedback-send');
    await tester.pump();
    expect(sent, hasLength(1));
    final r = sent.single;
    expect(r.type, FeedbackType.feature);
    expect(r.title, 'Dark mode');
    expect(r.text, 'A darker dark mode, please.');
    expect(r.username, 'matt');
    expect(r.shots.single.mime, 'image/png');
    expect(r.toJson()['username'], 'matt');
    expect(find.text('Thanks! Sent as GMFB-12'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the username switch, off, leaves it out; with no username there is no switch', (tester) async {
    final h = await SpaceHarness.load(tester);
    final sent = <FeedbackReport>[];
    await h.shoot(tester, FeedbackScreen(username: 'matt', send: (r) async => (sent..add(r)).isEmpty ? '' : 'GMFB-13'), 'feedback-no-name');
    await _press(tester, 'feedback-username');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('feedback-text')), matching: find.byType(EditableText)), 'It crashed.');
    await tester.pump();
    await _press(tester, 'feedback-send');
    await tester.pump();
    expect(sent.single.username, isNull);
    expect(sent.single.toJson().containsKey('username'), isFalse);
    await tester.pump(const Duration(seconds: 6));

    await h.shoot(tester, FeedbackScreen(username: '', send: (r) async => 'x'), 'feedback-anonymous');
    expect(find.byKey(const ValueKey('feedback-username')), findsNothing);
  });

  // In a browser, which can't choose a picture yet: the words alone, and a row saying so, which a screen reader reads.
  testWidgets('in a browser the form sends words alone and says why there are no screenshots', (tester) async {
    final was = Sms.browser;
    addTearDown(() => Sms.browser = was);
    Sms.browser = true;
    final h = await SpaceHarness.load(tester);
    final sent = <FeedbackReport>[];
    await h.shoot(tester, FeedbackScreen(username: 'matt', send: (r) async => (sent..add(r)).isEmpty ? '' : 'GMFB-14'), 'feedback-browser');
    expect(find.byKey(const ValueKey('feedback-add-shot')), findsNothing);
    expect(find.byKey(const ValueKey('feedback-no-shots')), findsOneWidget);
    expect(find.text('Not from a browser yet'), findsOneWidget);
    expect(tester.getSemantics(find.byKey(const ValueKey('feedback-no-shots'))).label, contains('Not from a browser yet'));
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('feedback-text')), matching: find.byType(EditableText)), 'From a browser.');
    await tester.pump();
    await _press(tester, 'feedback-send');
    await tester.pump();
    expect(sent.single.shots, isEmpty);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a refusal is said and the form stays', (tester) async {
    final h = await SpaceHarness.load(tester);
    await h.shoot(tester, FeedbackScreen(username: '', send: (r) async => throw FeedbackError('Feedback isn\'t set up on this server yet.')), 'feedback-refused');
    await tester.enterText(find.descendant(of: find.byKey(const ValueKey('feedback-text')), matching: find.byType(EditableText)), 'Hello');
    await tester.pump();
    await _press(tester, 'feedback-send');
    await tester.pump();
    expect(find.text('Feedback isn\'t set up on this server yet.'), findsOneWidget);
    expect(find.byType(FeedbackScreen), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  // Matt, 2026-11-20: "make share feedback open in a drawer on mobile".
  group('Share feedback in a drawer on a phone', () {
    tearDown(() => FeedbackButton.drawerOverride = null);

    /// A page with something to press that opens Share feedback, as the list's row does: [open] says how.
    Widget opener(void Function(BuildContext context) open) => Builder(
          builder: (context) => Center(child: GestureDetector(key: const ValueKey('open-feedback'), behavior: HitTestBehavior.opaque, onTap: () => open(context), child: const SizedBox(width: 120, height: 48))),
        );

    Future<void> openIt(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('open-feedback')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('on a phone the button opens the form in the drawer from the foot', (tester) async {
      final h = await SpaceHarness.load(tester);
      FeedbackButton.drawerOverride = true;
      await h.shoot(tester, opener(FeedbackButton.open), 'feedback-drawer-closed');
      await openIt(tester);
      final drawer = find.byKey(const ValueKey('feedback-drawer'));
      expect(drawer, findsOneWidget);
      expect(find.text('Share feedback'), findsOneWidget, reason: 'the drawer\'s title');
      final screen = tester.getSize(find.byType(WidgetsApp));
      expect(tester.getRect(drawer).bottom, lessThan(screen.height), reason: 'standing on the foot of the screen');
      expect(find.ancestor(of: drawer, matching: find.byType(MembersDrawer)), findsOneWidget, reason: 'in the app\'s drawer, not a page');
      expect(find.byType(GhostPage), findsNothing, reason: 'no page was pushed');
      await h.again(tester, 'feedback-drawer-open');
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('on a computer the button opens the page, not the drawer', (tester) async {
      final h = await SpaceHarness.load(tester);
      FeedbackButton.drawerOverride = false;
      await h.shoot(tester, opener(FeedbackButton.open), 'feedback-page-closed');
      await openIt(tester);
      expect(find.byKey(const ValueKey('feedback-drawer')), findsNothing, reason: 'a computer keeps the page');
      expect(find.byType(FeedbackScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('in the drawer the form works as the page does, and sending closes it', (tester) async {
      final h = await SpaceHarness.load(tester);
      final sent = <FeedbackReport>[];
      await h.shoot(tester, opener((c) => showFeedbackDrawer(c, username: 'maya', send: (r) async => (sent..add(r)).isEmpty ? '' : 'GMFB-14')), 'feedback-drawer-send');
      await openIt(tester);
      await _press(tester, 'feedback-send');
      expect(sent, isEmpty, reason: 'Send waits for a description');
      await tester.enterText(find.descendant(of: find.byKey(const ValueKey('feedback-text')), matching: find.byType(EditableText)), 'The call drops when I lock my phone.');
      await tester.pump();
      await _press(tester, 'feedback-send');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sent.single.text, 'The call drops when I lock my phone.');
      expect(sent.single.username, 'maya');
      expect(find.byKey(const ValueKey('feedback-drawer')), findsNothing, reason: 'the drawer closed');
      expect(find.text('Thanks! Sent as GMFB-14'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('the drawer stands above the keyboard', (tester) async {
      final h = await SpaceHarness.load(tester);
      await h.shoot(tester, opener((c) => showFeedbackDrawer(c, username: '', send: (r) async => '')), 'feedback-drawer-keyboard');
      await openIt(tester);
      final screen = tester.getSize(find.byType(WidgetsApp));
      tester.view.viewInsets = FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
      await tester.pump();
      expect(tester.getRect(find.byKey(const ValueKey('feedback-drawer'))).bottom, lessThanOrEqualTo(screen.height - 300), reason: 'clear of a keyboard 300 high');
      tester.view.resetViewInsets();
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
