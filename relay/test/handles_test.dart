import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

/// The handles people linked, with the networks stood in for: no request leaves this machine.
const alice = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
const bob = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';
const carol = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3';

class Net {
  /// handle -> what its public profile says, per network.
  final bios = <String, String>{};
  final follows = <String, List<String>>{};
  final asked = <String>[];

  /// Who a sign-in's code belongs to: code -> (id, username).
  final codes = <String, (String, String)>{};

  /// The text service: the code it "sent" each number and is waiting to hear back, how many texts went, the
  /// numbers it will not text, and whether it answers at all.
  final texted = <String, String>{};
  var texts = 0;
  final landlines = <String>{};
  var textsDown = false;

  Future<Fetched> fetch(String method, Uri url, {Map<String, String> headers = const {}, String? body, bool outside = false}) async {
    asked.add('$method ${url.host}${url.path}${outside ? ' (outside)' : ''}');
    final q = url.queryParameters;
    if (url.host == 'public.api.bsky.app' && url.path.endsWith('getProfile')) {
      final bio = bios['bluesky:${q['actor']}'];
      return bio == null ? const Fetched(400, '{}') : Fetched(200, jsonEncode({'did': 'did:plc:${q['actor']}', 'description': bio}));
    }
    if (url.host == 'public.api.bsky.app' && url.path.endsWith('getFollows')) {
      final all = follows['bluesky:${q['actor']}'] ?? const [];
      final from = int.parse(q['cursor'] ?? '0');
      final page = all.skip(from).take(100).toList();
      return Fetched(200, jsonEncode({'follows': [for (final h in page) {'handle': h}], if (from + 100 < all.length) 'cursor': '${from + 100}'}));
    }
    if (url.path == '/api/v1/accounts/lookup') {
      final bio = bios['mastodon:${q['acct']}@${url.host}'];
      return bio == null ? const Fetched(404, '{}') : Fetched(200, jsonEncode({'id': '77', 'note': '<p>hello</p>', 'fields': [{'name': 'ghost', 'value': bio}]}));
    }
    if (url.path == '/api/v1/accounts/77/following') {
      return Fetched(200, jsonEncode([{'acct': 'local'}, {'acct': 'far@other.example'}]));
    }
    if (url.host == 'api.github.com' && url.path.endsWith('/following')) {
      return Fetched(200, jsonEncode([for (final h in follows['github:${url.pathSegments[1]}'] ?? const []) {'login': h}]));
    }
    if (url.host == 'api.github.com') {
      final bio = bios['github:${url.pathSegments.last}'];
      return bio == null ? const Fetched(404, '{}') : Fetched(200, jsonEncode({'id': 4242, 'bio': bio}));
    }
    if (url.host == 'discord.com' && url.path == '/api/oauth2/token') {
      final code = Uri.splitQueryString(body ?? '')['code'];
      return codes.containsKey(code) ? Fetched(200, jsonEncode({'access_token': 'tok-$code'})) : const Fetched(400, '{}');
    }
    if (url.host == 'discord.com' && url.path == '/api/users/@me') {
      final who = codes[headers['Authorization']!.substring('Bearer tok-'.length)]!;
      return Fetched(200, jsonEncode({'id': who.$1, 'username': who.$2, 'global_name': 'Name of ${who.$2}', 'avatar': 'av${who.$1}'}));
    }
    if (url.host == 'api.x.com' && url.path == '/2/oauth2/token') {
      final form = Uri.splitQueryString(body ?? '');
      // PKCE: the verifier that comes back must be the one whose hash went out.
      if (!codes.containsKey(form['code']) || (form['code_verifier'] ?? '').length < 43) return const Fetched(400, '{}');
      return Fetched(200, jsonEncode({'access_token': 'tok-${form['code']}'}));
    }
    if (url.host == 'verify.twilio.com') {
      if (textsDown) return const Fetched(503, '');
      if (headers['Authorization'] != 'Basic ${base64Encode(utf8.encode('ACsid:secret'))}') return const Fetched(401, '{}');
      final form = Uri.splitQueryString(body ?? '');
      final to = form['To']!;
      if (url.path == '/v2/Services/VAservice/Verifications') {
        if (form['Channel'] != 'sms') return const Fetched(400, '{}');
        if (landlines.contains(to)) return const Fetched(403, '{"code": 60205}');
        texts++;
        // The same code while one is waiting, as the service sends it.
        texted[to] ??= '${482913 + texts}';
        return Fetched(201, jsonEncode({'status': 'pending', 'to': to}));
      }
      if (url.path == '/v2/Services/VAservice/VerificationCheck') {
        final want = texted[to];
        if (want == null) return const Fetched(404, '{}');
        if (form['Code'] != want) return Fetched(200, jsonEncode({'status': 'pending'}));
        texted.remove(to);
        return Fetched(200, jsonEncode({'status': 'approved'}));
      }
      return const Fetched(404, '{}');
    }
    if (url.host == 'api.x.com' && url.path == '/2/users/me') {
      final who = codes[headers['Authorization']!.substring('Bearer tok-'.length)]!;
      return Fetched(200, jsonEncode({'data': {'id': who.$1, 'username': who.$2}}));
    }
    return const Fetched(404, '');
  }
}

void main() {
  late Net net;
  late Handles h;
  late Map<String, List<Map<String, Object?>>> heard;
  late Directory dir;
  const config = HandlesConfig(publicUrl: 'http://127.0.0.1', discordId: 'did', discordSecret: 'dsecret', xId: 'xid', telegramBot: 'ghost_bot', telegramToken: '123:abc');

  // The same function each time for one install, as a connection's is: leaving is by that function.
  final tells = <String, void Function(Map<String, Object?>)>{};
  void Function(Map<String, Object?>) tellOf(String id) => tells[id] ??= (m) => (heard[id] ??= []).add(m);
  void come(Handles to, String id) {
    heard[id] ??= [];
    to.came(id, tellOf(id), key: utf8.encode('key of $id'));
  }

  void leave(Handles from, String id) => from.went(id, tellOf(id));
  Map<String, Object?>? last(String id, String dir) => heard[id]!.lastWhere((m) => m['dir'] == dir, orElse: () => const {}).isEmpty ? null : heard[id]!.lastWhere((m) => m['dir'] == dir);

  setUp(() {
    net = Net();
    heard = {};
    dir = Directory.systemTemp.createTempSync('handles');
    h = Handles(dataDir: dir, config: config, fetch: net.fetch)..load();
    for (final id in [alice, bob]) {
      come(h, id);
    }
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> prove(String id, String network, String handle) async {
    await h.said(id, {'dir': 'proof', 'p': network, 'handle': handle});
    final code = last(id, 'proof')!['code'] as String;
    net.bios['$network:${Handles.tidy(network, handle)}'] = 'I am on Uplink $code';
    await h.said(id, {'dir': 'check', 'p': network, 'handle': handle});
  }

  // Matt, 2026-11-21: "make a chrome plugin ... sync the cURL entries across all devices". The Chrome extension
  // (messaging/extension) seals the captured cookies and keeps them here; every device of the account reads them.
  test('curl entries: kept per identity, read back, replaced, cleared, and kept across a restart', () async {
    // Nothing kept yet.
    await h.said(alice, {'dir': 'curl-kept'});
    expect(last(alice, 'curl-kept'), {'dir': 'curl-kept', 'blob': null});

    await h.said(alice, {'dir': 'curl-keep', 'blob': 'sealed-one'});
    expect(last(alice, 'curl-keep'), containsPair('ok', true));
    await h.said(alice, {'dir': 'curl-kept'});
    expect(last(alice, 'curl-kept'), {'dir': 'curl-kept', 'blob': 'sealed-one'});

    // Another device on the same identity reads the same slot.
    expect(h.accountOf, isNull); // (unset in this test; the slot is keyed purely by the hub id)
    // Replaced by a later write.
    await h.said(alice, {'dir': 'curl-keep', 'blob': 'sealed-two'});
    await h.said(alice, {'dir': 'curl-kept'});
    expect(last(alice, 'curl-kept'), {'dir': 'curl-kept', 'blob': 'sealed-two'});

    // Bob's is his own.
    await h.said(bob, {'dir': 'curl-kept'});
    expect(last(bob, 'curl-kept'), {'dir': 'curl-kept', 'blob': null});

    // Too big is refused.
    await h.said(alice, {'dir': 'curl-keep', 'blob': 'x' * (Handles.maxCurl + 1)});
    expect(last(alice, 'err'), containsPair('about', 'curl-keep'));

    // An empty blob clears it.
    await h.said(alice, {'dir': 'curl-keep', 'blob': ''});
    await h.said(alice, {'dir': 'curl-kept'});
    expect(last(alice, 'curl-kept'), {'dir': 'curl-kept', 'blob': null});

    // Kept across a restart.
    await h.said(alice, {'dir': 'curl-keep', 'blob': 'sealed-three'});
    h.save();
    final again = Handles(dataDir: dir, config: config, fetch: net.fetch)..load();
    come(again, alice);
    await again.said(alice, {'dir': 'curl-kept'});
    expect(last(alice, 'curl-kept'), {'dir': 'curl-kept', 'blob': 'sealed-three'});
  });

  // Matt, 2026-11-14: "create a profile and username under "me" to register a username and add friends on the
  // platform".
  test('usernames: claimed once, found by anyone, kept only as hashes, and given up', () async {
    expect(Handles.goodName('Matt_W'), isTrue);
    expect(Handles.goodName('ab'), isFalse);
    expect(Handles.goodName('admin'), isFalse);
    expect(Handles.goodName('a..b'), isFalse);
    expect(Handles.nameKey('@Matt'), Handles.nameKey('matt'));
    await h.said(alice, {'dir': 'claim', 'name': 'Maya'});
    expect(last(alice, 'claim'), containsPair('ok', true));
    // Taken: Bob cannot have it, whatever case he types.
    await h.said(bob, {'dir': 'claim', 'name': 'MAYA'});
    expect(last(bob, 'claim'), containsPair('err', 'taken'));
    // Found by its name: the install and its key, to seal what is sent to it.
    await h.said(bob, {'dir': 'whois', 'name': '@maya'});
    expect(last(bob, 'whois'), {'dir': 'whois', 'name': 'maya', 'id': alice, 'key': base64Encode(utf8.encode('key of $alice'))});
    await h.said(bob, {'dir': 'whois', 'name': 'nobody'});
    expect(last(bob, 'whois'), containsPair('none', true));
    // A new one gives the old one up.
    await h.said(alice, {'dir': 'claim', 'name': 'maya.chen'});
    await h.said(bob, {'dir': 'whois', 'name': 'maya'});
    expect(last(bob, 'whois'), containsPair('none', true));
    await h.said(bob, {'dir': 'claim', 'name': 'maya'});
    expect(last(bob, 'claim'), containsPair('ok', true));
    // Kept across a restart. Since 2026-11-19 the usernames themselves are kept too, for the admin page's list of who
    // signed up (Matt: "allow me to see all users who signed up on the relay"); a name given up goes with it.
    h.save();
    final file = File('${dir.path}/handles.json').readAsStringSync();
    expect(file, contains('maya.chen'));
    final again = Handles(dataDir: dir, config: config, fetch: net.fetch)..load();
    come(again, carol);
    await again.said(carol, {'dir': 'whois', 'name': 'maya.chen'});
    expect(last(carol, 'whois'), containsPair('id', alice));
    // Given up.
    come(again, alice);
    await again.said(alice, {'dir': 'release'});
    await again.said(carol, {'dir': 'whois', 'name': 'maya.chen'});
    expect(last(carol, 'whois'), containsPair('none', true));
    // Not walked through: lookups are limited.
    for (var i = 0; i < Handles.lookupsAnHour; i++) {
      await again.said(carol, {'dir': 'whois', 'name': 'name$i'});
    }
    await again.said(carol, {'dir': 'whois', 'name': 'maya'});
    expect(last(carol, 'err'), containsPair('about', 'whois'));
  });

  // Matt, 2026-11-19: "Build a new points system into the app called souls ... a simple admin page for me to login to
  // ... make sure only my matt account can access it and allow me to see all users who signed up on the relay and issue
  // special badges and souls".
  // Matt, 2026-11-20: "add the ability to tie users names to their accounts when they sign back in later or reconnect to
  // the app so that we can give out bug bounties properly".
  test('the admin list names people as their names are said, keeps names given up, and shows each one\'s account', () async {
    const salt = '0123456789abcdef0123456789abcdef';
    final adminConfig = HandlesConfig(adminUser: 'wisp-keeper-1a2b', adminHash: '$salt:${Handles.adminHashOf(salt, 'open sesame')}');
    final a = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    a.accountOf = (id) => id == bob ? '0x00000000000000000000000000000000000000b0' : null;
    for (final id in [alice, bob, carol]) {
      come(a, id);
    }
    await a.said(alice, {'dir': 'claim', 'name': 'matt'});
    await a.said(bob, {'dir': 'claim', 'name': 'bob_builder'});
    // Bob takes another name: the first is kept as one he held.
    await a.said(bob, {'dir': 'claim', 'name': 'bobby'});
    await a.said(alice, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'open sesame'});
    Map users() => {for (final u in (last(alice, 'admin-users')!['users'] as List).cast<Map>()) u['id']: u};
    await a.said(alice, {'dir': 'admin-users'});
    expect(users()[bob]['name'], 'bobby');
    expect(users()[bob]['was'], ['bob_builder']);
    expect(users()[bob]['account'], '0x00000000000000000000000000000000000000b0');
    expect(users()[alice].containsKey('account'), isFalse);

    // A name the list has only as a hash (claimed on an older app, which never says it): named once anyone looks it up.
    a.save();
    final again = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    for (final id in [alice, bob, carol]) {
      come(again, id);
    }
    again.forgetShownForTest(bob);
    await again.said(alice, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'open sesame'});
    await again.said(alice, {'dir': 'admin-users'});
    expect(users()[bob]['name'], isNull);
    await again.said(carol, {'dir': 'whois', 'name': 'Bobby'});
    await again.said(alice, {'dir': 'admin-users'});
    expect(users()[bob]['name'], 'bobby');
    expect(users()[bob]['was'], ['bob_builder'], reason: 'kept across a restart');
    // A name nobody holds is not learned.
    again.learnName('nobody_here');
    await again.said(alice, {'dir': 'admin-users'});
    expect(users().values.where((u) => u['name'] == 'nobody_here'), isEmpty);
  });

  test('souls and special badges: only @matt with the admin password gives them; each person is told', () async {
    const salt = '0123456789abcdef0123456789abcdef';
    final adminConfig = HandlesConfig(adminUser: 'wisp-keeper-1a2b', adminHash: '$salt:${Handles.adminHashOf(salt, 'open sesame')}');
    final a = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    for (final id in [alice, bob, carol]) {
      come(a, id);
    }
    await a.said(alice, {'dir': 'claim', 'name': 'matt'});
    await a.said(bob, {'dir': 'claim', 'name': 'bob_builder'});
    await a.said(bob, {'dir': 'souls?'});
    expect(last(bob, 'souls'), {'dir': 'souls', 'n': 0, 'special': <String>[]});

    // Someone else with the right password, or @matt with the wrong one: refused, and nothing admin is answered.
    await a.said(bob, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'open sesame'});
    expect(last(bob, 'admin'), containsPair('ok', false));
    await a.said(alice, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'wrong'});
    expect(last(alice, 'admin'), containsPair('ok', false));
    await a.said(alice, {'dir': 'admin-users'});
    expect(last(alice, 'admin-users'), containsPair('ok', false));

    await a.said(alice, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'open sesame'});
    expect(last(alice, 'admin'), containsPair('ok', true));
    await a.said(alice, {'dir': 'admin-users'});
    final users = (last(alice, 'admin-users')!['users'] as List).cast<Map>();
    expect({for (final u in users) u['name']}, containsAll(['matt', 'bob_builder']));

    // Souls to Bob, told to him there and then; a badge too, which others see beside him.
    await a.said(alice, {'dir': 'admin-give', 'to': bob, 'souls': 25, 'why': 'Found the crash on Windows'});
    expect(last(bob, 'souls'), containsPair('n', 25));
    expect(last(bob, 'souls'), containsPair('why', 'Found the crash on Windows'));
    await a.said(alice, {'dir': 'admin-badge', 'to': bob, 'badge': 'bughunter', 'on': true});
    expect(last(bob, 'souls')!['special'], ['bughunter']);
    await a.said(alice, {'dir': 'admin-badge', 'to': bob, 'badge': 'made-up', 'on': true});
    expect(last(alice, 'admin-badge'), containsPair('ok', false));
    await a.said(carol, {'dir': 'badges', 'ids': [bob], 'names': ['bob_builder']});
    expect(last(carol, 'badges')!['special'], {bob: ['bughunter']});
    expect(last(carol, 'badges')!['specialNames'], {'bob_builder': ['bughunter']});
    // Taking more than there are leaves none, not fewer than none.
    await a.said(alice, {'dir': 'admin-give', 'to': bob, 'souls': -100});
    expect(last(bob, 'souls'), containsPair('n', 0));
    await a.said(alice, {'dir': 'admin-log'});
    expect((last(alice, 'admin-log')!['grants'] as List).length, 3);

    // Matt, 2026-11-21: "notify a user when they have recieved souls wiht a description for why like "bug bounty" etc
    // it should notify them next time they connect to the app (or immediatly if they're connected in real time)".
    // Said live with an id; kept until the app says it showed them.
    expect(last(bob, 'souls')!['gift'], isA<String>(), reason: 'souls taken back are said too, once');
    // Carol is away: given 40 souls for a bug bounty, and a badge.
    await a.said(alice, {'dir': 'admin-give', 'to': carol, 'souls': 40, 'why': 'Bug bounty'});
    await a.said(alice, {'dir': 'admin-badge', 'to': carol, 'badge': 'bughunter', 'on': true});

    // Kept across a restart; signed in only while connected.
    a.save();
    final again = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    come(again, bob);
    await again.said(bob, {'dir': 'hello'});
    expect(last(bob, 'hello'), containsPair('special', ['bughunter']));
    // Bob's gifts came while he was connected, but his app never said it showed them: said again.
    expect([for (final g in last(bob, 'souls-gifts')!['list'] as List) (g as Map)['souls'] ?? g['badge']], [25, 'bughunter', -100]);
    // Carol connects: told what came while she was away, with why, until her app says it showed them.
    come(again, carol);
    await again.said(carol, {'dir': 'hello'});
    final away = last(carol, 'souls-gifts')!;
    expect(away['n'], 40);
    final list = (away['list'] as List).cast<Map>();
    expect([for (final g in list) (g['souls'], g['why'], g['badge'])], [(40, 'Bug bounty', null), (null, null, 'bughunter')]);
    await again.said(carol, {'dir': 'souls-seen', 'ids': [list.first['g']]});
    await again.said(carol, {'dir': 'hello'});
    expect([for (final g in last(carol, 'souls-gifts')!['list'] as List) (g as Map)['badge']], ['bughunter']);
    await again.said(carol, {'dir': 'souls-seen', 'ids': [list.last['g']]});
    final before = heard[carol]!.length;
    await again.said(carol, {'dir': 'hello'});
    expect(heard[carol]!.skip(before).where((m) => m['dir'] == 'souls-gifts'), isEmpty, reason: 'nothing left to say');
    come(again, alice);
    await again.said(alice, {'dir': 'admin-users'});
    expect(last(alice, 'admin-users'), containsPair('ok', false), reason: 'a new connection signs in again');
    // Guessing is limited.
    for (var i = 0; i < Handles.adminTriesAnHour; i++) {
      await again.said(alice, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'guess $i'});
    }
    await again.said(alice, {'dir': 'admin-login', 'user': 'wisp-keeper-1a2b', 'pass': 'open sesame'});
    expect(last(alice, 'admin'), containsPair('ok', false));
  });

  // Matt, 2026-11-20: "I would like users to be able to develop and submit their own plugins to our plugin marketplace
  // and I'd like to be able to verify them for the store through a review process". The Marketplace's review rides on
  // the admin page's sign-in (relay/lib/market.dart), so a sign-in is now the connection's that made it, and it ages.
  group('the admin page\'s sign-in, for the Marketplace', () {
    const salt = '0123456789abcdef0123456789abcdef';
    final adminConfig = HandlesConfig(adminUser: 'k', adminHash: '$salt:${Handles.adminHashOf(salt, 'pw')}');

    test('is the connection\'s that signed in, for eight hours; the market asks how lately; it goes with its connection and a restart', () async {
      var clock = DateTime.utc(2026, 11, 20, 9);
      final a = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch, now: () => clock)..load();
      come(a, alice);
      come(a, bob);
      await a.said(alice, {'dir': 'claim', 'name': 'matt'});
      expect(a.adminSignedIn(alice), isFalse, reason: 'before signing in');
      await a.said(alice, {'dir': 'admin-login', 'user': 'k', 'pass': 'pw'});
      expect(last(alice, 'admin'), containsPair('ok', true));
      expect(a.adminSignedIn(alice), isTrue);
      expect(a.adminSignedIn(alice, within: const Duration(minutes: 30)), isTrue);
      expect(a.adminSignedIn(bob), isFalse);
      clock = clock.add(const Duration(minutes: 31));
      expect(a.adminSignedIn(alice, within: const Duration(minutes: 30)), isFalse, reason: 'not lately enough to approve');
      expect(a.adminSignedIn(alice), isTrue);
      await a.said(alice, {'dir': 'admin-users'});
      expect(last(alice, 'admin-users'), containsPair('ok', true));
      clock = clock.add(const Duration(hours: 8));
      expect(a.adminSignedIn(alice), isFalse, reason: 'eight hours on');
      await a.said(alice, {'dir': 'admin-users'});
      expect(last(alice, 'admin-users'), containsPair('ok', false), reason: 'nor the admin page itself');
      await a.said(alice, {'dir': 'admin-login', 'user': 'k', 'pass': 'pw'});
      expect(a.adminSignedIn(alice), isTrue);
      leave(a, alice);
      expect(a.adminSignedIn(alice), isFalse, reason: 'its connection left');
      come(a, alice);
      await a.said(alice, {'dir': 'admin-login', 'user': 'k', 'pass': 'pw'});
      expect(a.adminSignedIn(alice), isTrue);
      a.save();
      final again = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch, now: () => clock)..load();
      come(again, alice);
      expect(again.adminSignedIn(alice), isFalse, reason: 'a restart signs everyone out');
      // Not an admin's account any more: signed in or not, no.
      await a.said(alice, {'dir': 'claim', 'name': 'not_matt'});
      expect(a.adminSignedIn(alice), isFalse);
    });

    test('two connections of one identity: each its own sign-in, and each answer to the one that asked', () async {
      final a = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
      final byPhone = <Map<String, Object?>>[], byComputer = <Map<String, Object?>>[];
      void Function(Map<String, Object?>) phone = byPhone.add, computer = byComputer.add;
      a.came(alice, phone, key: utf8.encode('key of $alice'));
      await a.said(alice, {'dir': 'claim', 'name': 'matt'}, phone);
      await a.said(alice, {'dir': 'admin-login', 'user': 'k', 'pass': 'pw'}, phone);
      expect(byPhone.last, {'dir': 'admin', 'ok': true}, reason: 'the sign-in\'s answer reached the phone');
      // A computer that became the same you comes, and goes.
      a.came(alice, computer);
      a.went(alice, computer);
      expect(a.adminSignedIn(alice), isTrue, reason: 'the phone is still signed in');
      await a.said(alice, {'dir': 'admin-users'}, phone);
      expect(byPhone.last, containsPair('ok', true));
      a.came(alice, computer);
      await a.said(alice, {'dir': 'admin-users'}, computer);
      expect(byComputer.last, containsPair('ok', false), reason: 'the computer never signed in');
      expect(byPhone.where((m) => m['dir'] == 'admin-users'), hasLength(1), reason: 'its refusal went to the computer');
      a.went(alice, phone);
      expect(a.adminSignedIn(alice), isFalse);
    });

    test('an identity\'s key is kept while any of its connections is here, and forgotten with the last', () async {
      final a = Handles(dataDir: dir, config: config, fetch: net.fetch)..load();
      final byPhone = <Map<String, Object?>>[], byComputer = <Map<String, Object?>>[];
      void Function(Map<String, Object?>) phone = byPhone.add, computer = byComputer.add;
      a.came(alice, phone, key: utf8.encode('key of $alice'));
      a.came(alice, computer);
      a.went(alice, phone);
      await a.said(alice, {'dir': 'claim', 'name': 'alice_k'}, computer);
      expect(byComputer.last, containsPair('ok', true), reason: 'the computer is still here: the key they share is too');
      a.went(alice, computer);
      // Here again with no key said: nothing is left of the one from before.
      a.came(alice, computer);
      await a.said(alice, {'dir': 'claim', 'name': 'alice_k2'}, computer);
      expect(byComputer.last['err'], contains('Connect again'));
      a.went(alice, computer);
    });

    test('when a username was claimed, kept when it is claimed again; and the name itself', () async {
      var clock = DateTime.utc(2026, 11, 1, 15, 30);
      final a = Handles(dataDir: dir, config: config, fetch: net.fetch, now: () => clock)..load();
      come(a, alice);
      expect(a.claimedOn(alice), isNull);
      expect(a.usernameOf(alice), isNull);
      await a.said(alice, {'dir': 'claim', 'name': 'Maya.B'});
      expect(a.claimedOn(alice), DateTime.utc(2026, 11, 1));
      expect(a.usernameOf(alice), 'maya.b');
      clock = DateTime.utc(2026, 11, 5, 8);
      await a.said(alice, {'dir': 'claim', 'name': 'maya.b'});
      expect(last(alice, 'claim'), containsPair('ok', true));
      expect(a.claimedOn(alice), DateTime.utc(2026, 11, 1), reason: 'claiming the name it holds again keeps its day');
      await a.said(alice, {'dir': 'claim', 'name': 'maya_b'});
      expect(a.claimedOn(alice), DateTime.utc(2026, 11, 5), reason: 'another name is claimed anew');
      a.save();
      final again = Handles(dataDir: dir, config: config, fetch: net.fetch, now: () => clock)..load();
      expect(again.claimedOn(alice), DateTime.utc(2026, 11, 5));
      expect(again.usernameOf(alice), 'maya_b');
      await a.said(alice, {'dir': 'release'});
      expect(a.claimedOn(alice), isNull);
      expect(a.usernameOf(alice), isNull);
    });
  });

  // Matt, 2026-11-20: "allow the user to choose one badge to showcase next to their names don't show them all".
  test('one badge shown beside a name: the one its holder chose of theirs, else their highest', () async {
    const salt = '0123456789abcdef0123456789abcdef';
    final adminConfig = HandlesConfig(adminUser: 'k', adminHash: '$salt:${Handles.adminHashOf(salt, 'pw')}');
    final a = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    for (final id in [alice, bob, carol]) {
      come(a, id);
    }
    await a.said(alice, {'dir': 'claim', 'name': 'matt'});
    await a.said(bob, {'dir': 'claim', 'name': 'bob_builder'});
    await a.said(alice, {'dir': 'admin-login', 'user': 'k', 'pass': 'pw'});
    await a.said(alice, {'dir': 'admin-badge', 'to': bob, 'badge': 'alpha', 'on': true});
    await a.said(alice, {'dir': 'admin-badge', 'to': bob, 'badge': 'bughunter', 'on': true});
    await a.said(carol, {'dir': 'badges', 'ids': [bob], 'names': ['bob_builder']});
    expect(last(carol, 'badges')!['show'], {bob: 'bughunter'}, reason: 'none chosen: the highest');
    await a.said(bob, {'dir': 'showcase', 'badge': 'alpha'});
    expect(last(bob, 'souls'), containsPair('show', 'alpha'));
    await a.said(carol, {'dir': 'badges', 'ids': [bob], 'names': ['bob_builder']});
    expect(last(carol, 'badges')!['show'], {bob: 'alpha'});
    expect(last(carol, 'badges')!['showNames'], {'bob_builder': 'alpha'});
    await a.said(bob, {'dir': 'showcase', 'badge': 'team'});
    expect(last(bob, 'err'), containsPair('about', 'showcase'), reason: 'not one of his');
    // Kept across a restart.
    a.save();
    final again = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    expect(again.showcaseOf(bob), 'alpha');
  });

  test('an install says its own username as it says hello, and the admin list names it', () async {
    const salt = '0123456789abcdef0123456789abcdef';
    final adminConfig = HandlesConfig(adminUser: 'u-keeper', adminHash: '$salt:${Handles.adminHashOf(salt, 'pw')}');
    final a = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    come(a, alice);
    come(a, bob);
    await a.said(alice, {'dir': 'claim', 'name': 'matt'});
    await a.said(bob, {'dir': 'claim', 'name': 'early_bird'});
    a.save();
    // As a relay from before kept it: the hashes alone.
    final raw = (jsonDecode(File('${dir.path}/handles.json').readAsStringSync()) as Map)..['shown'] = <String, String>{};
    File('${dir.path}/handles.json').writeAsStringSync(jsonEncode(raw));
    final b = Handles(dataDir: dir, config: adminConfig, fetch: net.fetch)..load();
    come(b, alice);
    come(b, bob);
    await b.said(bob, {'dir': 'hello', 'name': 'someone_else'});
    await b.said(alice, {'dir': 'hello', 'name': 'matt'});
    await b.said(alice, {'dir': 'admin-login', 'user': 'u-keeper', 'pass': 'pw'});
    await b.said(alice, {'dir': 'admin-users'});
    final names = {for (final u in (last(alice, 'admin-users')!['users'] as List).cast<Map>()) u['id']: u['name']};
    expect(names[bob], isNull, reason: 'a name that is not the one it holds is not taken');
    await b.said(bob, {'dir': 'hello', 'name': 'early_bird'});
    await b.said(alice, {'dir': 'admin-users'});
    final again = {for (final u in (last(alice, 'admin-users')!['users'] as List).cast<Map>()) u['id']: u['name']};
    expect(again[bob], 'early_bird');
  });

  // Matt, 2026-11-15: "add them to a ignore or archive list on my ghost account specifically".
  test('an install keeps one sealed blob for itself, across a restart; no one else gets it', () async {
    await h.said(alice, {'dir': 'kept'});
    expect(last(alice, 'kept')!['blob'], isNull);
    await h.said(alice, {'dir': 'keep', 'blob': 'c2VhbGVk'});
    expect(last(alice, 'keep'), containsPair('ok', true));
    await h.said(bob, {'dir': 'kept'});
    expect(last(bob, 'kept')!['blob'], isNull, reason: 'each install its own');
    h.save();
    final again = Handles(dataDir: dir, config: config, fetch: net.fetch)..load();
    come(again, alice);
    await again.said(alice, {'dir': 'kept'});
    expect(last(alice, 'kept')!['blob'], 'c2VhbGVk');
    await again.said(alice, {'dir': 'keep', 'blob': 'x' * (Handles.maxKept + 1)});
    expect(last(alice, 'err'), containsPair('about', 'keep'));
  });

  test('a handle is tidied and hashed the same however it is written', () {
    expect(Handles.keyOf('discord', '@Maya'), Handles.keyOf('discord', ' maya '));
    expect(Handles.keyOf('discord', 'maya'), isNot(Handles.keyOf('x', 'maya')));
    expect(Handles.keyOf('x', 'maya'), hexOf(sha256(utf8.encode('ghost-handle v1|x|maya'))));
    expect(Handles.wellFormed('mastodon', 'maya@mastodon.social'), isTrue);
    expect(Handles.wellFormed('mastodon', 'maya@localhost'), isFalse);
    expect(Handles.wellFormed('mastodon', 'maya@10.0.0.1'), isFalse);
    expect(Handles.wellFormed('mastodon', 'maya@evil.example/../x'), isFalse);
    expect(Handles.wellFormed('bluesky', 'maya.bsky.social'), isTrue);
    expect(Handles.wellFormed('github', 'maya/../x'), isFalse);
    expect(hexOf(hmacSha256(utf8.encode('key'), utf8.encode('The quick brown fox jumps over the lazy dog'))), 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8');
  });

  test('hello says how each network is linked, and a network with no sign-in set up is off', () async {
    await h.said(alice, {'dir': 'hello'});
    final ways = last(alice, 'hello')!['ways'] as Map;
    expect(ways, {'discord': 'signin', 'telegram': 'signin', 'x': 'signin', 'bluesky': 'proof', 'mastodon': 'proof', 'github': 'proof', 'phone': 'off'});
    expect(Handles(fetch: net.fetch).ways['discord'], 'off');
    final bare = Handles(fetch: net.fetch)..load();
    come(bare, carol);
    await bare.said(carol, {'dir': 'link', 'p': 'discord'});
    expect(last(carol, 'err')!['err'], contains('not set up'));
  });

  test('a code in the profile proves the account; without it nothing is linked', () async {
    await h.said(alice, {'dir': 'proof', 'p': 'bluesky', 'handle': '@Maya.bsky.social'});
    final code = last(alice, 'proof')!['code'] as String;
    expect(code, startsWith('ghost-'));
    // Someone else's code for the same handle is another code.
    await h.said(bob, {'dir': 'proof', 'p': 'bluesky', 'handle': 'maya.bsky.social'});
    expect(last(bob, 'proof')!['code'], isNot(code));

    net.bios['bluesky:maya.bsky.social'] = 'just me';
    await h.said(alice, {'dir': 'check', 'p': 'bluesky', 'handle': 'maya.bsky.social'});
    expect(last(alice, 'err')!['err'], contains('not in that profile'));
    expect(h.linked, 0);

    // Bob's code in Maya's profile links it to Bob, not to Alice who asks.
    net.bios['bluesky:maya.bsky.social'] = 'hi ${last(bob, 'proof')!['code']}';
    await h.said(alice, {'dir': 'check', 'p': 'bluesky', 'handle': 'maya.bsky.social'});
    expect(h.linked, 0);

    net.bios['bluesky:maya.bsky.social'] = 'hi $code';
    await h.said(alice, {'dir': 'check', 'p': 'bluesky', 'handle': 'maya.bsky.social'});
    expect(last(alice, 'linked'), {'dir': 'linked', 'p': 'bluesky', 'handle': 'maya.bsky.social', 'k': Handles.keyOf('bluesky', 'maya.bsky.social')});
    expect(h.linked, 1);
  });

  test('someone watching is told when a listed handle joins, at once or when they next come; never an unlisted one', () async {
    final k = Handles.keyOf('github', 'maya');
    await h.said(bob, {'dir': 'watch', 'add': [k, Handles.keyOf('github', 'nobody')]});
    expect(last(bob, 'watching')!['n'], 2);
    expect(last(bob, 'joined'), isNull);

    // Linked but not listed: nobody hears.
    await prove(alice, 'github', 'Maya');
    expect(h.linked, 1);
    expect(last(bob, 'joined'), isNull);

    // Listed: Bob hears the hash, and only the hash.
    await h.said(alice, {'dir': 'listed', 'on': true});
    expect(last(bob, 'joined'), {'dir': 'joined', 'list': [k]});

    // Carol starts watching afterwards: told it is already here.
    come(h, carol);
    await h.said(carol, {'dir': 'watch', 'add': [k]});
    expect(last(carol, 'joined'), {'dir': 'joined', 'list': [k], 'already': true});

    // Someone away is told when they next say hello.
    leave(h, bob);
    heard[bob]!.clear();
    final mk = Handles.keyOf('mastodon', 'maya@mastodon.social');
    await h.said(bob, {'dir': 'watch', 'add': [mk]}); // not connected: not heard
    come(h, bob);
    await h.said(bob, {'dir': 'watch', 'add': [mk]});
    leave(h, bob);
    await prove(alice, 'mastodon', 'maya@mastodon.social');
    expect(net.asked.last, contains('(outside)'));
    come(h, bob);
    heard[bob]!.clear();
    await h.said(bob, {'dir': 'hello'});
    expect(last(bob, 'joined'), {'dir': 'joined', 'list': [mk]});
    heard[bob]!.clear();
    await h.said(bob, {'dir': 'hello'});
    expect(last(bob, 'joined'), isNull, reason: 'told once');

    // Listing turned off: a new watcher hears nothing.
    await h.said(alice, {'dir': 'listed', 'on': false});
    heard[carol]!.clear();
    await h.said(carol, {'dir': 'watch', 'add': [mk]});
    expect(last(carol, 'joined'), isNull);
    // Nobody is told of their own handle.
    await h.said(alice, {'dir': 'watch', 'add': [k]});
    await h.said(alice, {'dir': 'listed', 'on': true});
    expect(last(alice, 'joined'), isNull);
  });

  test('what is kept names no handle, and comes back after a restart', () async {
    await prove(alice, 'github', 'maya');
    await h.said(alice, {'dir': 'listed', 'on': true});
    await h.said(bob, {'dir': 'watch', 'add': [Handles.keyOf('x', 'someone')]});
    h.save();
    final kept = File('${dir.path}/handles.json').readAsStringSync();
    expect(kept, isNot(contains('maya')));
    expect(kept, isNot(contains('someone')));
    expect(kept, isNot(contains('4242')), reason: 'the account number is kept hashed');
    expect(kept, contains(Handles.keyOf('github', 'maya')));

    final again = Handles(dataDir: dir, config: config, fetch: net.fetch)..load();
    expect(again.linked, 1);
    expect(again.listed, 1);
    expect(again.watched, 1);
    // The same secret, so a code given before the restart still proves.
    expect(again.codeFor(alice, 'github', 'maya'), h.codeFor(alice, 'github', 'maya'));
    come(again, alice);
    await again.said(alice, {'dir': 'hello'});
    expect((last(alice, 'hello')!['links'] as List).single, containsPair('p', 'github'));
    expect(last(alice, 'hello')!['listed'], isTrue);

    // Forget: nothing of Alice is left.
    await again.said(alice, {'dir': 'forget'});
    again.save();
    expect(File('${dir.path}/handles.json').readAsStringSync(), isNot(contains(alice)));
  });

  test('an account linked from a second install leaves the first', () async {
    await prove(alice, 'github', 'maya');
    // The same account (GitHub's number for it), now proved by Bob's install: a new phone.
    await prove(bob, 'github', 'maya');
    expect(h.linked, 1);
    await h.said(alice, {'dir': 'hello'});
    expect(last(alice, 'hello')!['links'], isEmpty);
    await h.said(bob, {'dir': 'unlink', 'p': 'github'});
    expect(h.linked, 0);
  });

  test('who you follow is read only for the account you proved, and comes back tidy', () async {
    net.follows['bluesky:maya.bsky.social'] = [for (var i = 0; i < 250; i++) 'Friend$i.bsky.social'];
    await h.said(alice, {'dir': 'follows', 'p': 'bluesky', 'handle': 'maya.bsky.social'});
    expect(last(alice, 'err')!['err'], contains('Link that account first'));
    await prove(alice, 'bluesky', 'maya.bsky.social');
    await h.said(alice, {'dir': 'follows', 'p': 'bluesky', 'handle': 'maya.bsky.social'});
    final got = last(alice, 'follows')!['handles'] as List;
    expect(got.length, 250);
    expect(got.first, 'friend0.bsky.social');

    await prove(alice, 'mastodon', 'maya@mastodon.social');
    await h.said(alice, {'dir': 'follows', 'p': 'mastodon', 'handle': 'maya@mastodon.social'});
    expect(last(alice, 'follows')!['handles'], ['local@mastodon.social', 'far@other.example']);
    await h.said(alice, {'dir': 'follows', 'p': 'discord', 'handle': 'maya'});
    expect(last(alice, 'err')!['err'], contains('cannot be read'));
  });

  test('an install may make this server fetch only so often', () async {
    net.bios['github:maya'] = 'nothing';
    for (var i = 0; i < Handles.fetchesAnHour; i++) {
      await h.said(alice, {'dir': 'check', 'p': 'github', 'handle': 'maya'});
    }
    final before = net.asked.length;
    await h.said(alice, {'dir': 'check', 'p': 'github', 'handle': 'maya'});
    expect(last(alice, 'err')!['err'], contains('Too many'));
    expect(net.asked.length, before);
  });

  group('a phone number, by a code texted to it', () {
    const texting = HandlesConfig(publicUrl: 'http://127.0.0.1', twilioSid: 'ACsid', twilioToken: 'secret', twilioVerify: 'VAservice');
    const hers = '+15550100199';
    late DateTime clock;
    late Handles t;

    Handles make([HandlesConfig config = texting]) {
      final made = Handles(dataDir: dir, config: config, fetch: net.fetch, now: () => clock)..load();
      for (final id in [alice, bob, carol]) {
        come(made, id);
      }
      return made;
    }

    Future<void> text(String id, String number) => t.said(id, {'dir': 'text', 'p': 'phone', 'handle': number});
    Future<void> code(String id, String number, String code) => t.said(id, {'dir': 'code', 'p': 'phone', 'handle': number, 'code': code});
    int checks() => net.asked.where((a) => a.endsWith('/VerificationCheck')).length;

    setUp(() {
      clock = DateTime.utc(2026, 11, 14, 12);
      t = make();
    });

    test('a number is tidied the same however it is written, and only a whole one is taken', () {
      for (final written in ['(555) 010-0199', '555.010.0199', '1 555 010 0199', '+1 555 010 0199', ' +15550100199 ']) {
        expect(Handles.tidyNumber(written), hers, reason: written);
        expect(Handles.keyOf('phone', written), Handles.keyOf('phone', hers));
      }
      expect(Handles.tidyNumber('+44 20 7946 0958'), '+442079460958');
      expect(Handles.tidyNumber('call me'), '');
      expect(Handles.tidyNumber('555-0199 ext 2'), '');
      expect(Handles.wellFormed('phone', hers), isTrue);
      expect(Handles.wellFormed('phone', '+442079460958'), isTrue);
      for (final not in ['', '5550199', '+1555', '+10550100199', '+155501001990', '+0442079460958']) {
        expect(Handles.wellFormed('phone', Handles.tidyNumber(not)), isFalse, reason: not);
      }
    });

    test('with no text service set up a number is off, and nothing is sent', () async {
      expect(h.ways['phone'], 'off');
      expect(t.ways['phone'], 'text');
      await h.said(alice, {'dir': 'text', 'p': 'phone', 'handle': hers});
      expect(last(alice, 'err')!['err'], contains('not set up'));
      await h.said(alice, {'dir': 'code', 'p': 'phone', 'handle': hers, 'code': '482914'});
      expect(last(alice, 'err')!['err'], contains('not set up'));
      // Half set up is not set up.
      expect(Handles(config: const HandlesConfig(twilioSid: 'ACsid', twilioToken: 'secret'), fetch: net.fetch).ways['phone'], 'off');
      expect(net.texts, 0);
      expect(HandlesConfig.fromEnvironment({'GHOST_TWILIO_SID': 'ACsid', 'GHOST_TWILIO_TOKEN': 'secret', 'GHOST_TWILIO_VERIFY': 'VAservice', 'GHOST_TEXT_TO': '+1, +44,nonsense', 'GHOST_TEXTS_A_DAY': '50'}).textTo, ['+1', '+44']);
      expect(HandlesConfig.fromEnvironment(const {}).texts, isFalse);
      expect(HandlesConfig.fromEnvironment(const {}).textTo, ['+1']);
    });

    test('badges: whether ids and usernames verified a number, yes or no, never the number (Matt, 2026-11-19: "add the verfied by number badge")', () async {
      await t.said(alice, {'dir': 'claim', 'name': 'maya'});
      await t.said(carol, {'dir': 'claim', 'name': 'cara'});
      await text(alice, hers);
      await code(alice, hers, net.texted[hers]!);
      expect(t.linked, 1);
      await t.said(bob, {'dir': 'badges', 'ids': [alice, carol, 'nobody'], 'names': ['@Maya', 'cara', 'nobody', 'not a name!']});
      expect(last(bob, 'badges'), {'dir': 'badges', 'ids': [alice], 'names': ['maya']});
      // Asked too often in an hour: told to wait.
      for (var i = 0; i < Handles.badgesAnHour; i++) {
        await t.said(bob, {'dir': 'badges', 'ids': [alice]});
      }
      expect(last(bob, 'err')!['err'], contains('Too many'));
    });

    test('the code that reached the number links it; a wrong one, and someone else\'s try, do not', () async {
      await text(alice, '(555) 010-0199');
      expect(last(alice, 'text'), {'dir': 'text', 'p': 'phone', 'handle': hers});
      final sent = net.texted[hers]!;

      await code(alice, hers, '000000');
      expect(last(alice, 'err')!['err'], contains('not the code'));
      expect(t.linked, 0);

      // Bob knows her number, and guesses: his guess is not even passed on.
      final before = checks();
      await code(bob, hers, sent);
      expect(last(bob, 'err')!['err'], contains('Ask for a code first'));
      expect(checks(), before);
      expect(t.linked, 0);

      // Written as the text shows it, with a space.
      await code(alice, '555 010 0199', '${sent.substring(0, 3)} ${sent.substring(3)}');
      expect(last(alice, 'linked'), {'dir': 'linked', 'p': 'phone', 'handle': hers, 'k': Handles.keyOf('phone', hers)});
      expect(t.linked, 1);
      await t.said(alice, {'dir': 'hello'});
      expect((last(alice, 'hello')!['links'] as List).single, containsPair('p', 'phone'));

      // Good once: the same code again proves nothing.
      await code(alice, hers, sent);
      expect(last(alice, 'err')!['about'], 'code');

      // What is kept is the number's hash, never the number.
      t.save();
      final kept = File('${dir.path}/handles.json').readAsStringSync();
      expect(kept, isNot(contains('5550100199')));
      expect(kept, contains(Handles.keyOf('phone', hers)));

      // A code is not a profile's: the other ways of linking refuse a number.
      await t.said(alice, {'dir': 'proof', 'p': 'phone', 'handle': hers});
      expect(last(alice, 'err')!['err'], contains('code sent to it'));
      await t.said(alice, {'dir': 'follows', 'p': 'phone', 'handle': hers});
      expect(last(alice, 'err')!['err'], contains('cannot be read'));
      await t.said(alice, {'dir': 'text', 'p': 'github', 'handle': 'maya'});
      expect(last(alice, 'err')!['err'], contains('Only a phone number'));

      await t.said(alice, {'dir': 'unlink', 'p': 'phone'});
      expect(t.linked, 0);
    });

    test('a code runs out after ten minutes', () async {
      await text(alice, hers);
      final sent = net.texted[hers]!;
      clock = clock.add(const Duration(minutes: 11));
      final before = checks();
      await code(alice, hers, sent);
      expect(last(alice, 'err')!['err'], contains('Ask for a code first'));
      expect(checks(), before);
    });

    test('a number that moves to a new phone leaves the old one', () async {
      await text(alice, hers);
      await code(alice, hers, net.texted[hers]!);
      await text(bob, hers);
      await code(bob, hers, net.texted[hers]!);
      expect(t.linked, 1);
      await t.said(alice, {'dir': 'hello'});
      expect(last(alice, 'hello')!['links'], isEmpty);
      await t.said(bob, {'dir': 'hello'});
      expect((last(bob, 'hello')!['links'] as List).single, containsPair('k', Handles.keyOf('phone', hers)));
    });

    test('a linked number is told to nobody, listed or not', () async {
      final k = Handles.keyOf('phone', hers);
      // Bob watches for her number before she links it, Carol after.
      await t.said(bob, {'dir': 'watch', 'add': [k]});
      await t.said(alice, {'dir': 'listed', 'on': true});
      await text(alice, hers);
      await code(alice, hers, net.texted[hers]!);
      await t.said(carol, {'dir': 'watch', 'add': [k]});
      await t.said(alice, {'dir': 'listed', 'on': false});
      await t.said(alice, {'dir': 'listed', 'on': true});
      expect(last(bob, 'joined'), isNull);
      expect(last(carol, 'joined'), isNull);
      // And nothing waits for one who was away.
      leave(t, bob);
      await t.said(alice, {'dir': 'unlink', 'p': 'phone'});
      await text(alice, hers);
      await code(alice, hers, net.texted[hers]!);
      come(t, bob);
      await t.said(bob, {'dir': 'hello'});
      expect(last(bob, 'joined'), isNull);
    });

    test('only so many texts: for one install, to one number, and in all', () async {
      const other = '+15550100142';
      for (var i = 0; i < Handles.textsAnHour; i++) {
        await text(alice, hers);
      }
      expect(net.texts, 3);
      // Alice has had her three, to any number; and her number its three, whoever asks.
      await text(alice, other);
      expect(last(alice, 'err')!['err'], contains('asked for a few codes'));
      await text(bob, hers);
      expect(last(bob, 'err')!['err'], contains('That number has been sent'));
      expect(net.texts, 3);

      // An hour on, three more: six in a day, and then no more that day.
      clock = clock.add(const Duration(minutes: 61));
      for (var i = 0; i < Handles.textsAnHour; i++) {
        await text(alice, other);
      }
      expect(net.texts, 6);
      clock = clock.add(const Duration(minutes: 61));
      await text(alice, other);
      expect(last(alice, 'err')!['err'], contains('asked for a few codes'));
      expect(net.texts, 6);
      clock = clock.add(const Duration(hours: 23));
      await text(alice, other);
      expect(net.texts, 7);

      // In all: a server set to two a day sends two, to anyone.
      t = make(const HandlesConfig(twilioSid: 'ACsid', twilioToken: 'secret', twilioVerify: 'VAservice', textsADay: 2));
      await text(alice, '+15550100101');
      await text(bob, '+15550100102');
      await text(carol, '+15550100103');
      expect(last(carol, 'err')!['err'], contains('No more codes can be sent today'));
      expect(net.texts, 9);
    });

    test('only so many tries of a code', () async {
      await text(alice, hers);
      for (var i = 0; i < Handles.triesAnHour; i++) {
        await code(alice, hers, '111111');
      }
      final before = checks();
      await code(alice, hers, net.texted[hers]!);
      expect(last(alice, 'err')!['err'], contains('Too many tries'));
      expect(checks(), before);
      expect(t.linked, 0);
    });

    test('a number that may not be texted is refused before anything is sent; one the service refuses says so', () async {
      await text(alice, '+44 20 7946 0958');
      expect(last(alice, 'err')!['err'], contains('country'));
      await text(alice, 'my number');
      expect(last(alice, 'err')!['err'], contains('does not look like a phone number'));
      expect(net.asked, isEmpty);

      net.landlines.add(hers);
      await text(alice, hers);
      expect(last(alice, 'err')!['err'], contains('cannot be sent a text'));
      net.landlines.clear();
      net.textsDown = true;
      await text(alice, hers);
      expect(last(alice, 'err')!['err'], contains('could not be sent just now'));
      net.textsDown = false;
      await text(alice, hers);
      expect(last(alice, 'text')!['handle'], hers);
      net.textsDown = true;
      await code(alice, hers, net.texted[hers]!);
      expect(last(alice, 'err')!['err'], contains('could not be checked'));
      expect(t.linked, 0);

      // A wrong password for the service is the service being down, to the person.
      t = make(const HandlesConfig(twilioSid: 'ACsid', twilioToken: 'wrong', twilioVerify: 'VAservice'));
      net.textsDown = false;
      await text(bob, '+15550100142');
      expect(last(bob, 'err')!['err'], contains('could not be sent just now'));
    });
  });

  group('signing in, through the relay\'s own pages', () {
    late Relay relay;
    late int port;
    late HttpClient client;

    Future<({int status, String body, String? location})> get(String path) async {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
      request.followRedirects = false;
      final response = await request.close();
      return (status: response.statusCode, body: await utf8.decodeStream(response), location: response.headers.value('location'));
    }

    setUp(() async {
      relay = Relay(hub: Hub(handles: h));
      port = await relay.start(port: 0);
      client = HttpClient();
    });
    tearDown(() async {
      client.close(force: true);
      await relay.stop();
    });

    Future<String> state(String id, String network) async {
      await h.said(id, {'dir': 'link', 'p': network});
      final url = Uri.parse(last(id, 'link')!['url'] as String);
      expect(url.path, '/link/$network');
      return url.queryParameters['s']!;
    }

    test('Discord: the app is sent to Discord, and what Discord says on the way back is who signed in', () async {
      final s = await state(alice, 'discord');
      final start = await get('/link/discord?s=$s');
      expect(start.status, 302);
      final to = Uri.parse(start.location!);
      expect(to.host, 'discord.com');
      expect(to.queryParameters['scope'], 'identify');
      expect(to.queryParameters['state'], s);
      expect(to.queryParameters['redirect_uri'], 'http://127.0.0.1/link/discord/callback');

      net.codes['good'] = ('9001', 'Maya');
      final bad = await get('/link/discord/callback?code=wrong&state=$s');
      expect(bad.status, 400);
      expect(h.linked, 0);
      // A state is good once: the failed try used it up.
      final spent = await get('/link/discord/callback?code=good&state=$s');
      expect(spent.status, 400);

      final s2 = await state(alice, 'discord');
      final done = await get('/link/discord/callback?code=good&state=$s2');
      expect(done.status, 200);
      expect(done.body, contains('@maya on Discord is linked'));
      // What Discord said of the account comes with it, for the app to fill in a profile from (Matt, 2026-11-19: "sign
      // up with discord"); it is not kept.
      expect(last(alice, 'linked'), {
        'dir': 'linked',
        'p': 'discord',
        'handle': 'maya',
        'k': Handles.keyOf('discord', 'maya'),
        'about': {'name': 'Name of Maya', 'picture': 'https://cdn.discordapp.com/avatars/9001/av9001.png?size=256'},
      });
      expect(File('${dir.path}/handles.json').existsSync() ? File('${dir.path}/handles.json').readAsStringSync() : '', isNot(contains('Name of Maya')));
    });

    test('X: with a challenge whose answer only this server has', () async {
      final s = await state(bob, 'x');
      final to = Uri.parse((await get('/link/x?s=$s')).location!);
      expect(to.host, 'x.com');
      expect(to.queryParameters['code_challenge_method'], 'S256');
      expect(to.queryParameters['code_challenge']!.length, 43);
      net.codes['xcode'] = ('55', 'Bob_X');
      final done = await get('/link/x/callback?code=xcode&state=$s');
      expect(done.status, 200);
      expect(last(bob, 'linked')!['handle'], 'bob_x');
    });

    test('Telegram: only what its bot signed is believed, and not for long', () async {
      final s = await state(alice, 'telegram');
      final page = await get('/link/telegram?s=$s');
      expect(page.status, 200);
      expect(page.body, contains('data-telegram-login="ghost_bot"'));

      final when = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      String signed(Map<String, String> fields) {
        final lines = [for (final k in fields.keys.toList()..sort()) '$k=${fields[k]}'].join('\n');
        return hexOf(hmacSha256(sha256(utf8.encode('123:abc')), utf8.encode(lines)));
      }

      final fields = {'id': '777', 'first_name': 'Maya', 'username': 'MayaTG', 'auth_date': '$when'};
      String query(Map<String, String> f, String hash, String st) => Uri(queryParameters: {...f, 'hash': hash, 'state': st}).query;

      // Another username under the same signature: refused.
      final forged = await get('/link/telegram/callback?${query({...fields, 'username': 'someoneelse'}, signed(fields), s)}');
      expect(forged.status, 400);
      expect(h.linked, 0);

      final s2 = await state(alice, 'telegram');
      final old = {...fields, 'auth_date': '${when - 90000}'};
      expect((await get('/link/telegram/callback?${query(old, signed(old), s2)}')).status, 400);

      final s3 = await state(alice, 'telegram');
      final done = await get('/link/telegram/callback?${query(fields, signed(fields), s3)}');
      expect(done.status, 200);
      expect(last(alice, 'linked')!['handle'], 'mayatg');

      // No username: said so, and nothing linked.
      final s4 = await state(bob, 'telegram');
      final bare = {'id': '778', 'first_name': 'Bob', 'auth_date': '$when'};
      final none = await get('/link/telegram/callback?${query(bare, signed(bare), s4)}');
      expect(none.status, 400);
      expect(none.body, contains('has no username'));
    });

    test('a sign-in that finishes while the app is away is told when it comes back', () async {
      final s = await state(alice, 'discord');
      leave(h, alice);
      heard[alice]!.clear();
      net.codes['good'] = ('9001', 'maya');
      expect((await get('/link/discord/callback?code=good&state=$s')).status, 200);
      come(h, alice);
      await h.said(alice, {'dir': 'hello'});
      expect(last(alice, 'linked')!['handle'], 'maya');
    });

    test('an address that is not a sign-in is the relay\'s own answer', () async {
      expect((await get('/link/discord?s=nothing')).status, 400);
      expect((await get('/link/github?s=x')).body, contains('Ghost Messaging relay'));
      expect((await get('/')).body, contains('Ghost Messaging relay'));
    });
  });

  // DNS rebinding: a name that is public when checked and private when connected to. The connection goes to the
  // address it is given, whatever the name says now (here a name nothing answers for at all), and the name is still
  // what the certificate is checked against.
  test('an outside fetch connects to the address that was checked, with the name for the certificate', () async {
    final tmp = Directory.systemTemp.createTempSync('fetchat');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // A certificate authority of its own and a certificate for the name, as the system's checker wants them.
    Future<void> openssl(List<String> args) async {
      final r = await Process.run('openssl', args, workingDirectory: tmp.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    File('${tmp.path}/ext').writeAsStringSync('subjectAltName=DNS:rebind.invalid\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n');
    File('${tmp.path}/caext').writeAsStringSync('[req]\ndistinguished_name=dn\n[dn]\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n');
    await openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', '-subj', '/CN=test authority', '-config', 'caext', '-extensions', 'v3']);
    await openssl(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'k.pem', '-out', 'c.csr', '-subj', '/CN=rebind.invalid', '-config', 'caext']);
    await openssl(['x509', '-req', '-in', 'c.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'c.pem', '-days', '2', '-extfile', 'ext']);
    final server = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, SecurityContext()..useCertificateChain('${tmp.path}/c.pem')..usePrivateKey('${tmp.path}/k.pem'));
    addTearDown(() => server.close(force: true));
    final hosts = <String?>[];
    server.listen((r) {
      hosts.add(r.headers.value('host'));
      r.response
        ..write('hello')
        ..close();
    });
    final trust = SecurityContext()..setTrustedCertificates('${tmp.path}/ca.pem');
    final got = await fetchAt('GET', Uri.parse('https://rebind.invalid:${server.port}/x'), InternetAddress.loopbackIPv4, context: trust);
    expect((got.status, got.body), (200, 'hello'));
    expect(hosts, ['rebind.invalid:${server.port}']);
    // Another name at the same address: the certificate is not its.
    expect((await fetchAt('GET', Uri.parse('https://other.invalid:${server.port}/x'), InternetAddress.loopbackIPv4, context: trust)).status, 0);
    // And an address typed as private is refused before anything is connected to.
    expect((await defaultFetch('GET', Uri.parse('https://127.0.0.1:${server.port}/x'), outside: true)).status, 0);
    expect(hosts, hasLength(1));
  }, skip: Platform.isWindows);
}
