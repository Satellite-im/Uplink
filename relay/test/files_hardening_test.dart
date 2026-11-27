// The Files store's second round (Matt, 2026-11-17: "Finish the missing pieces that went unfinished" (of Circles and
// Files spaces, released in 0.9.2)): a log entry sent with ?after= lands right there or not at all, a moderator's
// delete frees the blob when it shows a roster the owner's signatures vouch for, a piece says its hash up front and is
// refused before its body, a wrong token is no space, and every limit has a name in the environment. And through all
// of it, a request as 0.9.2 sends it is taken as it was.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_relay/files.dart';
import 'package:ghost_relay/files_roster.dart';
import 'package:ghost_relay/p256.dart';
import 'package:ghost_relay/relay.dart';
import 'package:ghost_relay/sha256.dart';
import 'package:test/test.dart';

class Person {
  Person(int n) : scalar = List.generate(32, (i) => (n * 37 + i * 13 + 5) & 0xff) {
    key = P256.publicOf(scalar);
  }
  final List<int> scalar;
  late final List<int> key;
  int _nonce = 1;
  String get id => FilesRoster.idOf(key);
  String get keyHex => hexOf(key);

  List<int> sign(List<int> message) {
    final nonce = sha256([...scalar, for (var i = 0; i < 8; i++) (_nonce >> (8 * i)) & 0xff, ...message]);
    _nonce++;
    return P256.sign(scalar, message, nonce);
  }

  /// The headers a write carries; [bodySha] in place of the body's own where a piece says its hash up front.
  Map<String, String> signed(String method, String path, List<int> body, {String? bodySha}) {
    final time = DateTime.now().millisecondsSinceEpoch;
    final words = Files.signedWords(method, path, time, bodySha ?? hexOf(sha256(body)));
    return {'x-ghost-key': base64Encode(key), 'x-ghost-time': '$time', 'x-ghost-sig': base64Encode(sign(utf8.encode(words)))};
  }
}

/// A roster as the app signs one (lib/voice/roles.dart's Roster.signed and trustedFor): the words, then its JSON.
Map<String, Object?> roster({required Person owner, required Person by, required int version, Map<String, String> assigned = const {}, Set<String> banned = const {}, Map<String, String> grants = const {}}) {
  final body = {
    'o': owner.keyHex,
    'v': version,
    'roles': [
      {'id': 'admin', 'n': 'Admin', 'p': ['speak', 'chat', 'uploadFiles', 'manageFiles'], 'r': 30},
      {'id': 'moderator', 'n': 'Moderator', 'p': ['speak', 'chat', 'uploadFiles', 'manageFiles'], 'r': 20},
      {'id': 'member', 'n': 'Member', 'p': ['speak', 'chat', 'uploadFiles'], 'r': 10},
    ],
    'a': assigned,
    'g': grants,
    'b': banned.toList()..sort(),
    'm': const [],
    'n': 'member',
    'by': by.id,
    'k': by.keyHex,
  };
  final signed = utf8.encode('ghost-hangout roster|${jsonEncode(body)}');
  return {'r': base64Encode(signed), 's': hexOf(by.sign(signed))};
}

/// What an owner's or admin's device says of roster [r] as it opens a space (the app's FilesStore._statement): its
/// version, the hash of its bytes, its admins, and from an admin the owner's grant.
Map<String, Object?> statement(Map<String, Object?> r, {required int version, List<String> admins = const [], String? grant}) =>
    {'v': version, 'h': hexOf(sha256(base64Decode(r['r'] as String))), 'ad': admins, 'g': ?grant};

String grant(Person owner, Person admin) => hexOf(owner.sign(utf8.encode('ghost-hangout admin|${owner.keyHex}|${admin.id}')));

const space = '00ff00ff00ff00ff00ff00ff00ff00ff';
final token = 'a1' * 32;

void main() {
  late Directory dir;
  late Relay relay;
  late int port;
  late HttpClient http;

  Future<void> boot({FilesConfig config = const FilesConfig()}) async {
    relay = Relay(files: Files(dir: Directory('${dir.path}/files'), config: config));
    port = await relay.start(port: 0);
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ghost-files-hardening');
    http = HttpClient();
    await boot();
  });
  tearDown(() async {
    http.close(force: true);
    await relay.stop();
    await dir.delete(recursive: true);
  });

  Future<({int status, Map json})> call(String method, String path, {Person? as, List<int> body = const [], String? tok, Map<String, String> headers = const {}}) async {
    final req = await http.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    req.headers.set('authorization', 'Ghost ${tok ?? token}');
    if (as != null) as.signed(method, path, body).forEach(req.headers.set);
    headers.forEach(req.headers.set);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    final bytes = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    Map json = const {};
    try {
      json = jsonDecode(utf8.decode(bytes)) as Map;
    } catch (_) {}
    return (status: res.statusCode, json: json);
  }

  List<int> json(Object o) => utf8.encode(jsonEncode(o));
  final owner = Person(1), maya = Person(2), sam = Person(3), theo = Person(4), ada = Person(5);

  /// A finished blob of [n] bytes added by [who], the 0.9.2 way (its signature checked at the end).
  Future<String> addBlob(Person who, {int n = 20}) async {
    final id = (await call('POST', '/files/$space/blobs', as: who, body: json({'size': n}))).json['id'] as String;
    expect((await call('PUT', '/files/$space/blobs/$id?offset=0', as: who, body: List.filled(n, 7))).status, HttpStatus.ok);
    expect((await call('POST', '/files/$space/blobs/$id/done', as: who)).status, HttpStatus.ok);
    return id;
  }

  test('a 0.9.2 client: unsigned entries at the end, pieces checked at the end, deletes with no body', () async {
    expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex}))).status, HttpStatus.created);
    expect((await call('PUT', '/files/$space', as: maya, body: json({'owner': owner.keyHex}))).status, HttpStatus.ok);
    expect((await call('POST', '/files/$space/log', as: maya, body: [1, 2, 3])).json['seq'], 1);
    expect((await call('POST', '/files/$space/log', as: sam, body: [4])).json['seq'], 2);
    final a = await addBlob(maya), b = await addBlob(sam);
    expect((await call('DELETE', '/files/$space/blobs/$a', as: maya)).status, HttpStatus.ok, reason: 'its uploader');
    expect((await call('DELETE', '/files/$space/blobs/$b', as: maya)).status, HttpStatus.forbidden, reason: 'not theirs, and no roster');
    expect((await call('DELETE', '/files/$space/blobs/$b', as: owner)).status, HttpStatus.ok, reason: 'the owner');
    final info = await call('GET', '/files/$space');
    expect(info.json['seq'], 2);
    expect(info.json['rv'], 0);
  });

  test('a wrong token is no space at all', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    final wrong = 'c' * 64;
    expect((await call('GET', '/files/$space', tok: wrong)).status, HttpStatus.notFound);
    expect((await call('GET', '/files/$space/log?after=0', tok: wrong)).status, HttpStatus.notFound);
    expect((await call('PUT', '/files/$space', as: maya, body: json({}), tok: wrong)).status, HttpStatus.notFound);
    expect((await call('GET', '/files/${'9' * 32}')).status, HttpStatus.notFound);
  });

  test('an entry sent with ?after= goes right after that one or not at all', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    expect((await call('POST', '/files/$space/log?after=0', as: maya, body: [1])).json['seq'], 1);
    final late = await call('POST', '/files/$space/log?after=0', as: sam, body: [2]);
    expect(late.status, HttpStatus.conflict);
    expect(late.json['seq'], 1, reason: 'told where the list has got to');
    expect((await call('POST', '/files/$space/log?after=1', as: sam, body: [2])).json['seq'], 2);
    // 0.9.2's, between: at the end, as always.
    expect((await call('POST', '/files/$space/log', as: theo, body: [3])).json['seq'], 3);
    expect((await call('POST', '/files/$space/log?after=2', as: maya, body: [4])).status, HttpStatus.conflict);
    expect((await call('POST', '/files/$space/log?after=nonsense', as: maya, body: [4])).status, HttpStatus.conflict);
  });

  test('entries written at once each get a number of their own, in the order they are written', () async {
    await call('PUT', '/files/$space', as: maya, body: json({}));
    // As 0.9.2 sends them (no ?after=): twenty at once from three people.
    final got = await Future.wait([for (var i = 0; i < 20; i++) call('POST', '/files/$space/log', as: [maya, sam, theo][i % 3], body: [i])]);
    expect(got.map((a) => a.status).toSet(), {HttpStatus.ok});
    expect(got.map((a) => a.json['seq']).toSet(), {for (var i = 1; i <= 20; i++) i});
    final page = await call('GET', '/files/$space/log?after=0');
    expect([for (final o in page.json['ops'] as List) (o as Map)['s']], [for (var i = 1; i <= 20; i++) i]);
  });

  group('a piece that says its hash up front', () {
    Future<({int status, Map json})> put(Person signer, String id, int offset, List<int> body, {String? sha, String? length}) {
      final path = '/files/$space/blobs/$id?offset=$offset';
      final said = sha ?? hexOf(sha256(body));
      return call('PUT', path, body: body, headers: {
        ...signer.signed('PUT', path, body, bodySha: said),
        Files.bodyShaHeader: said,
        Files.bodyLengthHeader: length ?? '${body.length}',
      });
    }

    test('is taken when it is what it said, and cut back off when not', () async {
      await call('PUT', '/files/$space', as: maya, body: json({}));
      final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 100}))).json['id'] as String;
      expect((await put(maya, id, 0, List.filled(60, 1))).json['have'], 60);
      // Signed for one body, another sent: refused, and none of it kept.
      final other = await put(maya, id, 60, List.filled(40, 2), sha: hexOf(sha256(List.filled(40, 3))));
      expect(other.status, HttpStatus.badRequest);
      expect((await call('GET', '/files/$space/blobs/$id/state')).json['have'], 60);
      expect((await put(maya, id, 60, List.filled(40, 2), length: '39')).status, HttpStatus.badRequest);
      expect((await put(maya, id, 60, List.filled(41, 2))).status, HttpStatus.requestEntityTooLarge);
      expect((await put(maya, id, 60, List.filled(40, 2))).json['have'], 100);
      expect((await call('POST', '/files/$space/blobs/$id/done', as: maya)).json['done'], true);
    });

    test('is refused before its body when it is not the uploader\'s, and costs the uploader nothing', () async {
      await relay.stop();
      await boot(config: const FilesConfig(writesPerMinute: 8));
      await call('PUT', '/files/$space', as: maya, body: json({}));
      final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 1 << 20}))).json['id'] as String;

      // Headers only, a megabyte promised and never sent: the answer comes without waiting for it.
      Future<int> headersOnly(Map<String, String> h) async {
        final socket = await Socket.connect('127.0.0.1', port);
        final path = '/files/$space/blobs/$id?offset=0';
        socket.write('PUT $path HTTP/1.1\r\nHost: x\r\nAuthorization: Ghost $token\r\nContent-Length: ${1 << 20}\r\n');
        h.forEach((k, v) => socket.write('$k: $v\r\n'));
        socket.write('\r\n');
        final head = await utf8.decoder.bind(socket).first.timeout(const Duration(seconds: 5));
        socket.destroy();
        return int.parse(head.split(' ')[1]);
      }

      final sha = hexOf(sha256(List.filled(1 << 20, 0)));
      final path = '/files/$space/blobs/$id?offset=0';
      // Sam's own key and signature, on Maya's blob.
      expect(await headersOnly({...sam.signed('PUT', path, const [], bodySha: sha), Files.bodyShaHeader: sha, Files.bodyLengthHeader: '${1 << 20}'}), HttpStatus.forbidden);
      // Maya's key named, a signature that isn't hers.
      final forged = {...sam.signed('PUT', path, const [], bodySha: sha), 'x-ghost-key': base64Encode(maya.key)};
      for (var i = 0; i < 12; i++) {
        expect(await headersOnly({...forged, Files.bodyShaHeader: sha, Files.bodyLengthHeader: '${1 << 20}'}), HttpStatus.unauthorized);
      }
      expect((await call('GET', '/files/$space/blobs/$id/state')).json['have'], 0);
      // Twelve forgeries later, Maya's eight writes a minute are all still hers.
      expect((await put(maya, id, 0, List.filled(1000, 1))).json['have'], 1000, reason: 'her budget was not spent by refused pieces');
    });
  });

  group('a moderator\'s delete', () {
    setUp(() async {
      expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex}))).json['owner'], owner.keyHex);
    });

    Future<int> del(Person who, String blob, Object? proof) async => (await call('DELETE', '/files/$space/blobs/$blob', as: who, body: proof == null ? const [] : json({'roster': proof}))).status;

    test('frees the blob with an owner-signed roster that makes them one', () async {
      final r1 = roster(owner: owner, by: owner, version: 1, assigned: {sam.id: 'moderator'});
      final a = await addBlob(maya), b = await addBlob(maya), c = await addBlob(owner);
      expect(await del(sam, a, null), HttpStatus.forbidden, reason: 'no roster: as before');
      expect(await del(sam, a, r1), HttpStatus.ok);
      expect((await call('GET', '/files/$space/blobs/$a')).status, HttpStatus.notFound, reason: 'the blob is gone');
      expect(File('${dir.path}/files/$space/blobs/$a').existsSync(), isFalse);
      // A member with the same roster can't; nor can the moderator remove the owner's file.
      expect(await del(theo, b, r1), HttpStatus.forbidden);
      expect(await del(sam, c, r1), HttpStatus.forbidden);
      // A roster signed by someone who isn't the owner or an admin is not believed.
      expect(await del(sam, b, roster(owner: owner, by: sam, version: 2, assigned: {sam.id: 'moderator'})), HttpStatus.forbidden);
      // One whose bytes were changed after signing either.
      final bent = {...r1, 'r': base64Encode(utf8.encode(utf8.decode(base64Decode(r1['r'] as String)).replaceFirst('"v":1', '"v":9')))};
      expect(await del(sam, b, bent), HttpStatus.forbidden);
      expect((await call('GET', '/files/$space')).json['rv'], 1);
    });

    test('an admin the owner made may sign the roster; one without the owner\'s grant may not', () async {
      final a = await addBlob(maya);
      final unGranted = roster(owner: owner, by: ada, version: 1, assigned: {ada.id: 'admin', sam.id: 'moderator'});
      expect(await del(sam, a, unGranted), HttpStatus.forbidden);
      final granted = roster(owner: owner, by: ada, version: 1, assigned: {ada.id: 'admin', sam.id: 'moderator'}, grants: {ada.id: grant(owner, ada)});
      expect(await del(sam, a, granted), HttpStatus.ok);
    });

    test('an older roster than the space has seen is refused: a demotion sticks, across a restart too', () async {
      final a = await addBlob(maya), b = await addBlob(maya);
      final asMod = roster(owner: owner, by: owner, version: 1, assigned: {sam.id: 'moderator'});
      expect(await del(sam, a, asMod), HttpStatus.ok);
      // The owner demotes Sam; the owner's device tells the relay, without the roster. A member's device can't.
      final demoted = roster(owner: owner, by: owner, version: 2);
      expect((await call('PUT', '/files/$space', as: theo, body: json({'rv': statement(demoted, version: 2)}))).json['rv'], 1, reason: 'not the owner\'s or an admin\'s word');
      expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex, 'rv': statement(demoted, version: 2)}))).json['rv'], 2);
      await relay.stop();
      await boot();
      expect((await call('GET', '/files/$space')).json['rv'], 2);
      expect(await del(sam, b, asMod), HttpStatus.forbidden);
      expect(await del(sam, b, demoted), HttpStatus.forbidden);
      // Banned, a moderator can't either.
      final banned = roster(owner: owner, by: owner, version: 3, assigned: {sam.id: 'moderator'}, banned: {sam.id});
      expect(await del(sam, b, banned), HttpStatus.forbidden);
      expect(await del(maya, b, null), HttpStatus.ok, reason: 'the uploader, as always');
    });

    test('a demoted admin can\'t sign their way back: no skipping ahead, no second roster at a version, the owner has the last word', () async {
      final a = await addBlob(maya), b = await addBlob(maya), c = await addBlob(maya);
      final adaGrant = grant(owner, ada);
      // Version 1: Ada an admin, by the owner.
      final v1 = roster(owner: owner, by: owner, version: 1, assigned: {ada.id: 'admin'}, grants: {ada.id: adaGrant});
      expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex, 'rv': statement(v1, version: 1, admins: [ada.id])}))).json['rv'], 1);
      // Ada, still an admin, makes Sam a moderator at version 2: one on, from an admin of version 1. Taken.
      final v2 = roster(owner: owner, by: ada, version: 2, assigned: {ada.id: 'admin', sam.id: 'moderator'}, grants: {ada.id: adaGrant});
      expect(await del(sam, a, v2), HttpStatus.ok);
      // The owner demotes Ada at version 3 and says so.
      final v3 = roster(owner: owner, by: owner, version: 3, assigned: {sam.id: 'moderator'});
      expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex, 'rv': statement(v3, version: 3)}))).json['rv'], 3);
      // Ada still holds the owner's grant: a roster she signs checks out, naming her admin again and Theo a moderator.
      final back = roster(owner: owner, by: ada, version: 4, assigned: {ada.id: 'admin', theo.id: 'moderator'}, grants: {ada.id: adaGrant});
      expect(await del(theo, b, back), HttpStatus.forbidden, reason: 'not an admin of version 3');
      final far = roster(owner: owner, by: ada, version: 1 << 40, assigned: {ada.id: 'admin', theo.id: 'moderator'}, grants: {ada.id: adaGrant});
      expect(await del(theo, b, far), HttpStatus.forbidden);
      expect((await call('PUT', '/files/$space', as: ada, body: json({'rv': statement(far, version: 1 << 40, admins: [ada.id], grant: adaGrant)}))).json['rv'], 3);
      // Another version 3, the owner's real one standing: refused.
      final twin = roster(owner: owner, by: owner, version: 3, assigned: {sam.id: 'moderator', theo.id: 'moderator'});
      expect(await del(theo, b, twin), HttpStatus.forbidden);
      expect(await del(sam, b, v3), HttpStatus.ok, reason: 'the real version 3 still frees Sam\'s deletes');
      expect((await call('GET', '/files/$space')).json['rv'], 3);
      // The owner's word is the last even downwards: a version an admin pushed on can be undone.
      expect((await call('PUT', '/files/$space', as: owner, body: json({'owner': owner.keyHex, 'rv': statement(v2, version: 2, admins: [ada.id])}))).json['rv'], 2);
      await relay.stop();
      await boot();
      expect((await call('GET', '/files/$space')).json['rv'], 2, reason: 'kept across a restart');
      expect(await del(sam, c, v2), HttpStatus.ok, reason: 'its hash kept too');
    });

    test('no roster is believed before the owner has opened the space', () async {
      const other = '11ff11ff11ff11ff11ff11ff11ff11ff';
      await call('PUT', '/files/$other', as: maya, body: json({'owner': owner.keyHex}));
      final id = (await call('POST', '/files/$other/blobs', as: maya, body: json({'size': 16}))).json['id'] as String;
      final r1 = roster(owner: owner, by: owner, version: 1, assigned: {sam.id: 'moderator'});
      expect((await call('DELETE', '/files/$other/blobs/$id', as: sam, body: json({'roster': r1}))).status, HttpStatus.forbidden);
    });
  });

  test('a blob a newer app started takes only pieces that say their hash up front', () async {
    await relay.stop();
    await boot(config: const FilesConfig(writesPerMinute: 8));
    await call('PUT', '/files/$space', as: maya, body: json({}));
    final id = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 100, 'pre': true}))).json['id'] as String;
    // Even with Maya's own signature, the 0.9.2 way: refused before its body, and costing her nothing.
    for (var i = 0; i < 10; i++) {
      expect((await call('PUT', '/files/$space/blobs/$id?offset=0', as: maya, body: List.filled(10, 1))).status, HttpStatus.forbidden);
    }
    expect((await call('GET', '/files/$space/blobs/$id/state')).json['have'], 0);
    final path = '/files/$space/blobs/$id?offset=0';
    final body = List.filled(100, 2), sha = hexOf(sha256(body));
    final ok = await call('PUT', path, body: body, headers: {...maya.signed('PUT', path, body, bodySha: sha), Files.bodyShaHeader: sha, Files.bodyLengthHeader: '100'});
    expect(ok.json['have'], 100);
    // Kept across a restart: still a newer app's blob.
    final other = (await call('POST', '/files/$space/blobs', as: maya, body: json({'size': 20, 'pre': true}))).json['id'] as String;
    await relay.stop();
    await boot();
    expect((await call('PUT', '/files/$space/blobs/$other?offset=0', as: maya, body: List.filled(20, 1))).status, HttpStatus.forbidden);
  });

  test('an entry refused for its place costs no write, and the answer says the relay takes ?after=', () async {
    await relay.stop();
    await boot(config: const FilesConfig(writesPerMinute: 4));
    await call('PUT', '/files/$space', as: maya, body: json({}));
    expect((await call('GET', '/files/$space')).json['cas'], 1);
    expect((await call('POST', '/files/$space/log?after=0', as: maya, body: [1])).json['seq'], 1);
    for (var i = 0; i < 6; i++) {
      expect((await call('POST', '/files/$space/log?after=0', as: maya, body: [2, i])).status, HttpStatus.conflict);
    }
    expect((await call('POST', '/files/$space/log?after=1', as: maya, body: [3])).json['seq'], 2, reason: 'six refusals spent none of four writes');
    final page = await call('GET', '/files/$space/log?after=0');
    expect([for (final o in page.json['ops'] as List) (o as Map)['c']], [1, 1], reason: 'each line says this relay wrote it');
  });

  test('every limit is read from the environment, and the defaults stay as they were', () {
    const d = FilesConfig();
    final none = FilesConfig.fromEnvironment(const {});
    expect([none.maxFile, none.spaceQuota, none.total, none.maxBody, none.maxOp, none.maxOps, none.maxLogBytes, none.spacesPerAddress, none.promisedPerAddress],
        [d.maxFile, d.spaceQuota, d.total, d.maxBody, d.maxOp, d.maxOps, d.maxLogBytes, d.spacesPerAddress, d.promisedPerAddress]);
    expect(d.maxLogBytes, 16 << 20);
    expect(d.spacesPerAddress, 20);
    // Raised with the 50 GB file limit (Matt, 2026-11-17: "Bump the upload limit to 50GB").
    expect(d.maxFile, greaterThanOrEqualTo(50000000000));
    expect(d.promisedPerAddress, greaterThanOrEqualTo(d.maxFile));
    expect(d.roomyQuota, greaterThanOrEqualTo(d.maxFile));
    expect(d.total, greaterThanOrEqualTo(d.roomyQuota));
    final env = {for (var i = 0; i < FilesConfig.names.length; i++) FilesConfig.names[i]: '${1000 + i}'};
    final c = FilesConfig.fromEnvironment(env);
    expect([c.maxFile, c.spaceQuota, c.total, c.spacesPerId, c.idleDays, c.writesPerMinute, c.maxBody, c.maxOp, c.maxOps, c.maxLogBytes, c.maxBlobs, c.maxSpaces, c.partHours, c.spacesPerAddress, c.promisedPerAddress],
        [for (var i = 0; i < FilesConfig.names.length; i++) 1000 + i]);
    expect(FilesConfig.fromEnvironment({'GHOST_FILES_MAX_BODY': '${64 << 20}'}).maxBody, 10 << 20, reason: 'no bigger than Caddy lets through');
    expect(FilesConfig.fromEnvironment({'GHOST_FILES_TOTAL': 'lots', 'GHOST_FILES_MAX_OP': '0'}).total, d.total);
    // tool/deploy-relay.mjs knows every one of these names (it refuses a name it doesn't).
    final known = File('../tool/deploy-relay.mjs').readAsStringSync();
    for (final n in FilesConfig.names) {
      expect(known, contains('$n:'), reason: n);
    }
  });
}
