import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/api/api.dart';
import 'package:ghost_messaging/api/remote.dart';
import 'package:ghost_messaging/api/seal.dart';
import 'package:ghost_messaging/api/server.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/desktop/link/crypto.dart' show DeskCrypto;
import 'package:ghost_messaging/api/methods.dart';
import 'package:ghost_messaging/ui/api_pane.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/settings_panes.dart';
import 'package:ghost_relay/relay.dart';

import 'support/list_harness.dart';

/// The app's API (lib/api; Matt, 2026-11-17: "build an entire API that we can use to interact with every aspect of the
/// app frontend and backend ... as well as test areas"): its registry's checks, the HTTP server, and the relay link
/// sealed end to end, and that tool/ghost-api.mjs's keys and seals are the app's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Real sockets: the test binding answers every HTTP request with 400 otherwise.
  HttpOverrides.global = null;

  setUpAll(() {
    // No phone underneath: what the app keeps there goes nowhere.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null);
    if (Api.instance.method('test.echo') != null) return;
    Api.instance.registerAll([
      ApiMethod(
        name: 'test.echo',
        summary: 'Says back what it was given.',
        params: const [ApiParam('text', 'string', 'Words.', required: true), ApiParam('times', 'int', 'How many.')],
        run: (p) async => {'text': List.filled((p['times'] as num?)?.toInt() ?? 1, p['text']).join(' ')},
      ),
      ApiMethod(name: 'test.fail', summary: 'Always fails.', run: (_) async => throw StateError('it went wrong')),
    ]);
  });

  test('a call is checked against what the method takes, run, logged, and answered in one shape', () async {
    expect(await Api.instance.call('test.echo', {'text': 'hi', 'times': 2}), {'text': 'hi hi'});
    await expectLater(Api.instance.call('test.echo', {}), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(Api.instance.call('test.echo', {'text': 3}), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'bad_params')));
    await expectLater(Api.instance.call('nope.nothing', {}), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'not_found')));
    final failed = await Api.instance.answer({'method': 'test.fail', 'id': 7}, via: 'here');
    expect(failed, {'id': 7, 'ok': false, 'error': {'code': 'failed', 'message': 'it went wrong'}});
    expect(Api.instance.calls.value.first.method, 'test.fail');
    expect(Api.instance.calls.value.first.ok, isFalse);
    final docs = Api.instance.describe();
    expect((docs['methods'] as List).any((m) => (m as Map)['name'] == 'test.echo'), isTrue);
  });

  test('the remote link\'s keys and seals are tool/ghost-api.mjs\'s (values made by its own code)', () {
    final s = ApiSeal(DeskCrypto.unhex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'));
    expect(s.channel, 'c61c9d31febcacdc66c7b4e951cddf19');
    expect(s.token, '9243964e551feec2ab698dacc09a4197db9ea015f2ac68bc7e3b4b5a5ea0cacd');
    final fromNode = DeskCrypto.unhex('0707070707070707070707073a6ed9d5153728c596c1954f3648a55a96cbcff21fb67d794e438d185f81bb7b7560aba2c4');
    expect(utf8.decode(s.open(fromNode)!), '{"method":"api.ping"}');
    expect(s.open(s.seal(utf8.encode('back'))), utf8.encode('back'));
    final tampered = s.seal(utf8.encode('back'))..[20] ^= 1;
    expect(s.open(tampered), isNull, reason: 'a changed frame does not open');
    expect(ApiSeal.secretOf('ghostapi1:${'ab' * 32}'), isNotNull);
    expect(ApiSeal.secretOf('ghostapi1:short'), isNull);
  });

  test('over HTTP: the documentation, a call with the token, and none without', () async {
    final app = AppState()
      ..set('api_local', 'on')
      ..set('api_port', '0');
    await ApiServer.instance.apply(app);
    addTearDown(ApiServer.instance.stop);
    final at = ApiServer.instance.addresses.value!.first;
    final token = ApiServer.token(app);
    final http = HttpClient();
    Future<(int, Map)> ask(String method, String path, {Object? body, String? auth}) async {
      final r = await http.openUrl(method, Uri.parse('http://$at$path'));
      if (auth != null) r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $auth');
      if (body != null) r.write(jsonEncode(body));
      final res = await r.close();
      return (res.statusCode, jsonDecode(await utf8.decoder.bind(res).join()) as Map);
    }

    final (s1, a1) = await ask('POST', '/api/test.echo', body: {'text': 'yo'});
    expect(s1, 401);
    expect((a1['error'] as Map)['code'], 'unauthorized');
    final (s2, a2) = await ask('POST', '/api/test.echo', body: {'text': 'yo', 'times': 3}, auth: token);
    expect(s2, 200);
    expect(a2, {'ok': true, 'result': {'text': 'yo yo yo'}});
    final (s3, a3) = await ask('GET', '/api', auth: token);
    expect(s3, 200);
    expect(((a3['result'] as Map)['methods'] as List).length, greaterThan(1));
    final (s4, _) = await ask('POST', '/api/test.echo', body: {}, auth: token);
    expect(s4, 400);
    final (s5, a5) = await ask('POST', '/api', body: {'method': 'test.echo', 'params': {'text': 'x'}, 'id': 'q1'}, auth: token);
    expect([s5, a5['id'], (a5['result'] as Map)['text']], [200, 'q1', 'x']);
    // Nearly the token, and the token with more after it, are no token.
    final (s7, _) = await ask('POST', '/api/test.echo', body: {'text': 'yo'}, auth: '${token.substring(0, token.length - 1)}x');
    final (s8, _) = await ask('POST', '/api/test.echo', body: {'text': 'yo'}, auth: '${token}0');
    final (s9, _) = await ask('POST', '/api/test.echo', body: {'text': 'yo'}, auth: token.substring(0, 8));
    expect([s7, s8, s9], [401, 401, 401]);
    expect([ApiServer.sameText('Bearer a', 'Bearer a'), ApiServer.sameText('', 'Bearer a'), ApiServer.sameText('Bearer é', 'Bearer e'), ApiServer.sameText('', '')], [true, false, false, true]);
    // A new token shuts the old one out.
    ApiServer.newToken(app);
    final (s6, _) = await ask('POST', '/api/test.echo', body: {'text': 'yo'}, auth: token);
    expect(s6, 401);
    http.close();
  });

  test('through a relay: a client with the connection string calls the phone, sealed both ways', () async {
    final relay = Relay();
    final port = await relay.start(port: 0);
    addTearDown(relay.stop);
    ApiRemote.relayOverride = 'ws://127.0.0.1:$port/relay';
    addTearDown(() => ApiRemote.relayOverride = null);
    final app = AppState()..set('api_remote', 'on');
    await ApiRemote.instance.apply(app);
    addTearDown(() async {
      app.set('api_remote', 'off');
      await ApiRemote.instance.apply(app);
    });
    for (var i = 0; i < 100 && ApiRemote.instance.state.value != 'waiting'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(ApiRemote.instance.state.value, 'waiting');

    // The client: tool/ghost-api.mjs's part, in Dart.
    final seal = ApiSeal(ApiSeal.secretOf(ApiRemote.connection(app))!);
    final ws = await WebSocket.connect('ws://127.0.0.1:$port/relay/${seal.channel}');
    final said = <Map>[];
    final answers = <Map>[];
    ws.listen((d) {
      if (d is String) {
        said.add(jsonDecode(d) as Map);
      } else {
        final clear = seal.open(d as List<int>);
        if (clear != null) answers.add(jsonDecode(utf8.decode(clear)) as Map);
      }
    });
    ws.add(jsonEncode({'auth': seal.token, 'role': 'desk'}));
    for (var i = 0; i < 100 && !said.any((m) => m['peer'] == true); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    ws.add(seal.seal(utf8.encode(jsonEncode({'id': 1, 'method': 'test.echo', 'params': {'text': 'far', 'times': 2}}))));
    for (var i = 0; i < 100 && answers.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(answers.single, {'id': 1, 'ok': true, 'result': {'text': 'far far'}});
    expect(Api.instance.calls.value.first.via, 'relay');
    // Without the key, a frame is not opened and not answered.
    ws.add(utf8.encode('{"id": 2, "method": "test.echo", "params": {"text": "x"}}'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(answers.length, 1);
    await ws.close();
  });

  testWidgets('Settings › API: shown in developer mode, every method listed, and one run from its own page', (tester) async {
    final sheet = await loadSheet(tester);
    final app = AppState();
    if (Api.instance.method('app.info') == null) Api.instance.registerAll(appMethods(app));
    expect(settingsSections.firstWhere((s) => s.id == 'api').when!(SettingsModel(app)), isFalse, reason: 'hidden until developer mode');
    app.setFlag('dev_mode', true);
    expect(settingsSections.firstWhere((s) => s.id == 'api').when!(SettingsModel(app)), isTrue);
    await pumpScreen(tester, sheet, const SettingsSectionScreen('api'), app);
    await settle(tester);
    expect(find.text('Serve the API'), findsOneWidget);
    expect(find.text('Through the relay'), findsOneWidget);
    // The method's row (not "Recent calls", where an earlier test's call is), by its description.
    await tester.ensureVisible(find.text('Says back what it was given.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Says back what it was given.'));
    await settle(tester);
    expect(find.byType(ApiMethodPage), findsOneWidget);
    await tester.enterText(find.byType(EditableText).first, '{"text": "from settings", "times": 2}');
    await tester.tap(find.text('Run test.echo'));
    await settle(tester);
    expect(find.textContaining('from settings from settings'), findsOneWidget);
  });
}
