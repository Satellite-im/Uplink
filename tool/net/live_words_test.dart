import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/circles/invite_word.dart';
import 'package:ghost_messaging/invites/invite_relay.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';

/// Circles' invite words on a relay that is really there (relay/lib/invite_words.dart, lib/circles/invite_word.dart):
///
///     flutter test tool/net/live_words_test.dart --dart-define=HUB=wss://gogho.st/hub
///
/// The check run after tool/deploy-relay.mjs. A throwaway word, made up for each run, is claimed by one new install,
/// refused to another, looked up over the hub and, where the site is deployed with its /word/ route, over HTTP, and
/// dropped again: it leaves nothing behind.
const hub = String.fromEnvironment('HUB');

/// A new install, with keys made for this run, connected to the hub within ten seconds or the test fails.
Future<HubCarrier> _up() async {
  final c = HubCarrier(url: hub, signer: KeysSigner(NetKeys.generate()));
  await c.start();
  for (var i = 0; i < 400 && c.state.value != CarrierState.up; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(c.state.value, CarrierState.up, reason: c.problem ?? 'it did not connect to $hub');
  return c;
}

void main() {
  test('a word claimed, refused to another, found, and dropped, at $hub', () async {
    expect(hub, isNotEmpty, reason: 'say which: --dart-define=HUB=wss://…/hub');
    final a = await _up(), b = await _up();
    final word = 'live-check-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final link = 'https://gogho.st/join/#c.${'e' * 64}.${base64Url.encode(utf8.encode('Live check')).replaceAll('=', '')}';
    final mine = InviteWords(ask: (w) => askHub(a, w)), theirs = InviteWords(ask: (w) => askHub(b, w));

    await mine.claim(word, link);
    await expectLater(theirs.claim(word, link), throwsA(isA<InviteRelayError>()));
    expect(await theirs.resolve(word), link);

    final web = Uri.parse(hub.replaceFirst('wss://', 'https://').replaceFirst(RegExp(r'/hub$'), '/word/${inviteWordHash(word)}'));
    final client = HttpClient();
    final res = await (await client.getUrl(web)).close();
    final body = await utf8.decodeStream(res);
    client.close();
    stdout.writeln('GET /word/… answered ${res.statusCode}${res.statusCode == 200 ? '' : ' (the site\'s /word/ route is not deployed yet)'}');
    if (res.statusCode == 200) expect(openInviteWord(word, (jsonDecode(body) as Map)['b'] as String), link);

    await expectLater(theirs.drop(word), throwsA(isA<InviteRelayError>()));
    await mine.drop(word);
    expect(await theirs.resolve(word), isNull);
    await a.stop();
    await b.stop();
  });
}
