import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

/// Two installs and the real relay with its keeper of handles, on this machine. Only the networks themselves are
/// stood in for: what GitHub says of a profile, and what Discord says of a sign-in.
Future<void> _tick([int ms = 20]) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _until(bool Function() done, {String? reason}) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await _tick(10);
  }
  expect(done(), isTrue, reason: reason);
}

class _Install {
  _Install(String url) : hub = HubCarrier(url: url, signer: KeysSigner(NetKeys.generate()));
  final HubCarrier hub;
  final store = MemoryMeStore();
  final routes = ChangeNotifier();
  late Me me = Me.forTest();

  Future<void> open() async {
    await hub.start();
    await _until(() => hub.state.value == CarrierState.up, reason: hub.problem);
    await me.start(store, routes, () => hub);
  }
}

void main() {
  late Relay relay;
  late int port;
  late Directory dir;
  final bios = <String, String>{};
  final follows = <String, List<String>>{};

  /// The text service: the code it "sent" each number, waiting to hear it back.
  final texted = <String, String>{};

  Future<Fetched> fetch(String method, Uri url, {Map<String, String> headers = const {}, String? body, bool outside = false}) async {
    if (url.host == 'api.github.com' && url.path.endsWith('/following')) {
      return Fetched(200, jsonEncode([for (final h in follows[url.pathSegments[1]] ?? const <String>[]) {'login': h}]));
    }
    if (url.host == 'api.github.com') {
      final bio = bios[url.pathSegments.last];
      return bio == null ? const Fetched(404, '{}') : Fetched(200, jsonEncode({'id': url.pathSegments.last.hashCode, 'bio': bio}));
    }
    if (url.host == 'discord.com' && url.path == '/api/oauth2/token') return Fetched(200, jsonEncode({'access_token': 't'}));
    if (url.host == 'discord.com') return Fetched(200, jsonEncode({'id': '9001', 'username': 'Maya.D'}));
    if (url.host == 'verify.twilio.com') {
      final form = Uri.splitQueryString(body ?? '');
      if (url.path.endsWith('/Verifications')) {
        texted[form['To']!] = '482913';
        return Fetched(201, jsonEncode({'status': 'pending'}));
      }
      final right = texted[form['To']] == form['Code'];
      if (right) texted.remove(form['To']);
      return Fetched(200, jsonEncode({'status': right ? 'approved' : 'pending'}));
    }
    return const Fetched(404, '');
  }

  setUp(() async {
    bios.clear();
    follows.clear();
    texted.clear();
    dir = Directory.systemTemp.createTempSync('me');
    relay = Relay(hub: Hub(handles: Handles(dataDir: dir, fetch: fetch, config: const HandlesConfig(publicUrl: 'http://127.0.0.1', discordId: 'id', discordSecret: 'secret', twilioSid: 'ACsid', twilioToken: 'secret', twilioVerify: 'VAservice'))));
    port = await relay.start(port: 0);
  });
  tearDown(() async {
    await relay.stop();
    dir.deleteSync(recursive: true);
  });

  String url() => 'ws://127.0.0.1:$port/hub';

  test('the phone and the server hash a handle the same way', () {
    for (final (network, handle) in [('discord', '@Maya'), ('mastodon', ' maya@Mastodon.Social '), ('x', 'MAYA_x')]) {
      expect(handleKey(network, handle), Handles.keyOf(network, handle));
      expect(handleFits(network, tidyHandle(handle)), Handles.wellFormed(network, Handles.tidy(network, handle)));
    }
    expect(Me.split('@maya, jordan\n  Sam;maya'), ['maya', 'jordan', 'sam']);
    expect(networkOf('mastodon').profile('maya@mastodon.social'), 'https://mastodon.social/@maya');
    expect(networkOf('discord').profile('maya'), isNull);
  });

  test('the phone and the server read a number the same way, and only our own text is read for its code', () {
    for (final written in ['(555) 010-0199', '+1 555 010 0199', '15550100199', '555.010.0199', '+44 20 7946 0958', '5550199', 'call me', '+1 055 010 0199', '']) {
      expect(tidyNumber(written), Handles.tidyNumber(written), reason: written);
      expect(numberFits(tidyNumber(written)), Handles.wellFormed('phone', Handles.tidyNumber(written)), reason: written);
      if (numberFits(tidyNumber(written))) expect(handleKey('phone', tidyNumber(written)), Handles.keyOf('phone', written));
    }
    expect(showNumber('+15550100199'), '+1 (555) 010-0199');
    expect(showNumber('+442079460958'), '+442079460958');
    // What is typed back in the field is read as the same number.
    expect(tidyNumber(showNumber('+15550100199')), '+15550100199');
    expect(ownCodeIn('Your Uplink verification code is: 482913'), '482913');
    expect(ownCodeIn('Your Ghost Messaging verification code is: 482913'), '482913', reason: 'the name the texting service still gives it, and a relay not brought up to date');
    expect(ownCodeIn('Your Coinbase verification code is 771204. Do not share it.'), isNull);
    expect(ownCodeIn('Uplink is out: 0.7.11'), isNull);
  });

  // Matt, 2026-11-15: "add them to a ignore or archive list on my ghost account specifically" (lib/kept_lists.dart).
  test('an install keeps its lists on the relay sealed: read back by it alone, unreadable on the server', () async {
    final maya = _Install(url()), bob = _Install(url());
    await maya.open();
    await bob.open();
    maya.me.wake();
    bob.me.wake();
    await _until(() => maya.me.ready && bob.me.ready);
    expect(await maya.me.kept(), isNull);
    await maya.me.keep({'v': 1, 'inbox': {'inbox_telegram_deleted': '10\u001f20'}, 'threads': {'44': 1763200000000}, 'msgs': ['sms:7']});
    final back = await maya.me.kept();
    expect((back!['inbox'] as Map)['inbox_telegram_deleted'], '10\u001f20');
    expect((back['threads'] as Map)['44'], 1763200000000);
    expect(await bob.me.kept(), isNull, reason: 'each install its own');
    relay.hub!.handles!.save();
    final file = File('${dir.path}/handles.json').readAsStringSync();
    expect(file, isNot(contains('inbox_telegram')), reason: 'sealed: the server can\'t read it');
    expect(file, contains('kept'));
  });

  test('Maya\'s number is verified by the code texted to it; nobody is told it, and it is hers after a restart', () async {
    final maya = _Install(url()), bob = _Install(url());
    await maya.open();
    await bob.open();
    maya.me.wake();
    await _until(() => maya.me.ready);
    expect(maya.me.texts, isTrue);
    expect(maya.me.number, isNull);

    // Bob, who has her number, watches for it (no app of ours does: one made to could).
    bob.hub.sayHandles({'dir': 'hello'});
    bob.hub.sayHandles({'dir': 'watch', 'add': [handleKey('phone', '+15550100199')]});
    final told = <Map<String, dynamic>>[];
    final sub = bob.hub.handles.listen(told.add);

    await expectLater(maya.me.textCode('555 0199'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('does not look like a phone number'))));
    expect(await maya.me.textCode('(555) 010-0199'), '+15550100199');
    await expectLater(maya.me.tryCode('+15550100199', '000000'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('not the code'))));
    expect(maya.me.number, isNull);
    await maya.me.tryCode('(555) 010-0199', texted['+15550100199']!);
    expect(maya.me.number, '+15550100199');
    expect(maya.me.accounts, isEmpty, reason: 'a number is not an account friends are told about');
    // The number verified turns "Tell friends I'm here" on by itself (Matt, 2026-11-14: "once an account is linked
    // or the phone number verified, automatically tick tell friends I'm here").
    expect(maya.me.listed, isTrue);

    maya.me.setListed(true);
    await _tick(120);
    expect(told.where((m) => m['dir'] == 'joined'), isEmpty);
    await sub.cancel();

    // The server kept its hash, not the number.
    relay.hub!.handles!.save();
    expect(File('${dir.path}/handles.json').readAsStringSync(), isNot(contains('5550100199')));

    // The app restarted: still hers, by the phone's word on the number and the server's on the link.
    final again = Me.forTest();
    await again.start(maya.store, maya.routes, () => maya.hub);
    await _until(() => again.ready);
    expect(again.number, '+15550100199');

    await again.unlink('phone');
    expect(again.number, isNull);
    await _until(() => relay.hub!.handles!.linked == 0);
    for (final i in [maya, bob]) {
      await i.hub.stop();
    }
  });

  test('a paired computer verifies the number through the phone: the phone\'s install is the one linked', () async {
    final phone = _Install(url());
    await phone.open();
    // The computer's Me asks the phone's (android DeskCalls "me" → Me.forComputer); the link itself is
    // test/desk_link_test.dart's.
    Future<Map<String, dynamic>> ask(Map<String, Object?> what) async => Map<String, dynamic>.from((await phone.me.forComputer({'what': what})) as Map);
    final mac = Me.forTest();
    await mac.followPhone(ask);
    expect(mac.ready, isTrue, reason: 'the phone woke its own conversation with the server to answer');
    expect(mac.texts, isTrue);

    expect(await mac.textCode('443 653 7451'), '+14436537451');
    await expectLater(mac.tryCode('+14436537451', '111111'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('not the code'))));
    await mac.tryCode('+14436537451', texted['+14436537451']!);
    expect(mac.number, '+14436537451');
    expect(phone.me.number, '+14436537451', reason: 'linked to the phone, not to the computer');
    expect(relay.hub!.handles!.linked, 1);

    // Opened again, the computer reads it from the phone; and what the phone will not do for it, it says.
    final again = Me.forTest();
    await again.followPhone(ask);
    expect(again.number, '+14436537451');
    await expectLater(again.forgetEverything(), throwsA(isA<MeError>()));
    expect(relay.hub!.handles!.linked, 1);
    await again.unlink('phone');
    await _until(() => relay.hub!.handles!.linked == 0);
    expect(phone.me.number, isNull);

    // "Tell friends I'm here" from the computer is the phone's (Matt, 2026-11-15: "tell friends i'm here toggle isn't
    // working on mac and windows only on mobile").
    final was = phone.me.listed;
    again.setListed(!was);
    expect(again.listed, !was, reason: 'the switch moves at once');
    await _until(() => phone.me.listed == !was);
    final third = Me.forTest();
    await third.followPhone(ask);
    expect(third.listed, !was, reason: 'read back from the phone');
    // A phone that will not do it puts the switch back, and says why.
    final refused = Me.forTest();
    await refused.followPhone(ask);
    refused.asking = (_) async => throw MeError('The phone does not do that for a computer.');
    refused.setListed(was);
    await _until(() => refused.listed == !was);
    expect(refused.phoneSaid, contains('does not do that'));
    await phone.hub.stop();
  });

  test('nothing is said to the server about handles until an install uses them', () async {
    final a = _Install(url());
    await a.open();
    await _tick(100);
    expect(a.me.ready, isFalse, reason: 'no hello was said');
    a.me.wake();
    await _until(() => a.me.ready);
    expect(a.me.ways['github'], 'proof');
    expect(a.me.ways['discord'], 'signin');
    expect(a.me.ways['x'], 'off');
    expect(a.me.ways['phone'], 'text');
    await a.hub.stop();
  });

  test('Maya links GitHub by a code in her bio and turns on being found; Bob, watching for her, is told', () async {
    final maya = _Install(url()), bob = _Install(url());
    await maya.open();
    await bob.open();
    maya.me.wake();
    await _until(() => maya.me.ready);

    // Bob watches for two people. Nobody is here yet.
    expect(bob.me.addWatch('github', ['@Maya', 'jordan', 'not a handle!', 'maya']), 2);
    await _tick(80);
    expect(bob.me.joined, isEmpty);

    // Maya asks for her code. Without it in her bio the check fails and says why.
    final code = await maya.me.proofCode('github', 'Maya');
    bios['maya'] = 'hello';
    await expectLater(maya.me.check('github', 'maya'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('not in that profile'))));
    expect(maya.me.links, isEmpty);
    bios['maya'] = 'On Uplink. $code';
    // Maya has switched "Tell friends I'm here" off herself: linking does not undo that.
    maya.me.setListed(false);
    await maya.me.check('github', 'maya');
    expect(maya.me.links, {'github': 'maya'});
    expect(maya.me.listed, isFalse);

    // Linked, but not listed: Bob hears nothing.
    await _tick(80);
    expect(bob.me.joined, isEmpty);

    // Listed: Bob hears, and it is new until he looks.
    maya.me.setListed(true);
    await _until(() => bob.me.joined.isNotEmpty);
    expect(bob.me.joined.single.handle, 'maya');
    expect(bob.me.joined.single.network, 'github');
    expect(bob.me.unseen, 1);
    bob.me.markSeen();
    expect(bob.me.unseen, 0);

    // What the server kept names neither of them.
    relay.hub!.handles!.save();
    final kept = File('${dir.path}/handles.json').readAsStringSync();
    expect(kept, isNot(contains('maya')));
    expect(kept, isNot(contains('jordan')));

    // Bob's phone remembers across a restart of the app, and is not told twice.
    final again = Me.forTest();
    await again.start(bob.store, bob.routes, () => bob.hub);
    await _until(() => again.ready);
    await _tick(80);
    expect(again.joined.length, 1);
    expect(again.watch.length, 2);

    // Maya unlinks: the server has nothing of hers, and a new watcher hears nothing.
    await maya.me.unlink('github');
    final carol = _Install(url());
    await carol.open();
    carol.me.addWatch('github', ['maya']);
    await _tick(120);
    expect(carol.me.joined, isEmpty);
    for (final i in [maya, bob, carol]) {
      await i.hub.stop();
    }
  });

  test('someone who was away is told when their app next opens', () async {
    final maya = _Install(url()), bob = _Install(url());
    await bob.open();
    bob.me.addWatch('github', ['maya']);
    await _tick(80);
    await bob.hub.stop();

    await maya.open();
    final code = await maya.me.proofCode('github', 'maya');
    bios['maya'] = code;
    await maya.me.check('github', 'maya');
    maya.me.setListed(true);
    await _tick(100);

    final later = HubCarrier(url: url(), signer: bob.hub.signer);
    await later.start();
    await _until(() => later.state.value == CarrierState.up);
    final me = Me.forTest();
    await me.start(bob.store, bob.routes, () => later);
    await _until(() => me.joined.isNotEmpty, reason: 'told on coming back');
    expect(me.joined.single.handle, 'maya');
    await later.stop();
    await maya.hub.stop();
  });

  test('Discord is linked by signing in: the address to open, and the link arriving when the browser is done', () async {
    final maya = _Install(url());
    await maya.open();
    final address = Uri.parse(await maya.me.signInAddress('discord'));
    expect(address.path, '/link/discord');
    // The browser's part, by hand: Discord sends it back with a code.
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/link/discord/callback?code=c&state=${address.queryParameters['s']}'));
    final response = await request.close();
    expect(response.statusCode, 200);
    await response.drain<void>();
    client.close(force: true);
    await _until(() => maya.me.links.containsKey('discord'));
    expect(maya.me.links['discord'], 'maya.d');
    // X has no sign-in set up on this server: said so.
    await expectLater(maya.me.signInAddress('x'), throwsA(isA<MeError>().having((e) => e.message, 'message', contains('not set up'))));
    await maya.hub.stop();
  });

  test('who Maya follows on GitHub is brought into her watch list, and removing everything removes it there too', () async {
    final maya = _Install(url());
    await maya.open();
    await expectLater(maya.me.importFollows('github'), throwsA(isA<MeError>()));
    final code = await maya.me.proofCode('github', 'maya');
    bios['maya'] = code;
    await maya.me.check('github', 'maya');
    follows['maya'] = ['Jordan', 'sam', 'maya', 'jordan'];
    expect(await maya.me.importFollows('github'), 2, reason: 'herself and the one said twice are left out');
    expect(maya.me.watch.map((w) => w.handle).toSet(), {'jordan', 'sam'});
    final handles = relay.hub!.handles!;
    await _until(() => handles.watched == 2);

    maya.me.removeWatch(const Watched('github', 'sam'));
    await _until(() => handles.watched == 1);

    await maya.me.forgetEverything();
    expect(maya.me.links, isEmpty);
    expect(maya.me.watch, isEmpty);
    expect(handles.linked, 0);
    expect(handles.watched, 0);
    await maya.hub.stop();
  });
}
