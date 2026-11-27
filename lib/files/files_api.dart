import 'dart:async';
import 'dart:convert';
import '../aside.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show immutable, kIsWeb;

import '../net/crypto.dart' show NetCrypto;
import '../net/file_seal_async.dart';
import '../net/hub_carrier.dart' show NetSigner;
import 'files_http.dart';

/// Why the files server said no: its words, and what it answered (a 409 says where an upload has got to in [have]).
class FilesError implements Exception {
  FilesError(this.status, this.message, {this.have, this.seq});
  final int status;
  final String message;
  final int? have;

  /// Where the log has got to, said with a 409 to an entry sent with `?after=` that the log has moved past.
  final int? seq;

  /// The server could not be reached at all.
  bool get offline => status == 0;
  @override
  String toString() => message;
}

/// A Files space's files on the relay (relay/lib/files.dart), spoken to over plain HTTPS: its token on every request,
/// and every write signed with this install's hub key ([NetSigner], the key it is known by in the space's roster).
class FilesApi {
  FilesApi({required this.base, required this.space, required this.token, required this.signer, FilesHttp? http}) : _http = http ?? defaultFilesHttp();

  /// Where the files are served: `https://gogho.st/files` for the relay at `wss://gogho.st/hub`.
  final Uri base;

  /// The relay's name for the space's files, and its token (both from the seed: FileSeal.filesRoom / filesToken).
  final String space;
  final String token;
  final NetSigner signer;

  /// How requests go (lib/files/files_http.dart): dart:io's HttpClient in the app, the page's fetch in a browser.
  final FilesHttp _http;

  /// Where the files of the relay at [hubUrl] are: the same server, `/files` in place of `/hub`.
  static Uri baseFor(String hubUrl) {
    final u = Uri.parse(hubUrl.trim());
    final segments = [...u.pathSegments.where((s) => s.isNotEmpty)];
    if (segments.isNotEmpty && segments.last == 'hub') segments.removeLast();
    return u.replace(scheme: u.scheme == 'ws' ? 'http' : (u.scheme == 'wss' ? 'https' : u.scheme), pathSegments: [...segments, 'files'], query: null, fragment: null);
  }

  /// The hex SHA-256 of a body to sign. A blob's piece is 4 MB: hashed on the UI's isolate with pointycastle that was
  /// some 200 ms each, the app frozen for the whole of an upload (GMFB-6, @matt: "The app is super laggy when in a
  /// voice call and uploading a video to the files"). A large body is hashed on another isolate, with package:crypto;
  /// in a browser, which has no other isolate, by the browser's own SHA-256 (lib/net/file_seal_async.dart).
  static Future<String> bodySha(List<int> body) async {
    if (body.length < 256 * 1024) return crypto.sha256.convert(body).toString();
    final bytes = body is Uint8List ? body : Uint8List.fromList(body);
    if (kIsWeb) return NetCrypto.hex(await SealAsync.sha256(bytes));
    return runAside(() => crypto.sha256.convert(bytes).toString());
  }

  String _path(String rest) => '${base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path}/$space$rest';

  /// The headers of a request carrying the space's token; with [signBody], signed by this install's hub key too.
  Future<Map<String, String>> _headers(String method, String path, {List<int>? signBody, bool sayHash = false}) async {
    final headers = {'authorization': 'Ghost $token'};
    if (signBody != null) {
      // Signed over what the relay sees: the method, the path with its query, the time and the body's hash.
      final time = DateTime.now().millisecondsSinceEpoch;
      final sha = await bodySha(signBody);
      final words = 'ghost-files v1\n$method\n$path\n$time\n$sha';
      final sig = await signer.sign(utf8.encode(words));
      headers
        ..['x-ghost-key'] = base64Encode(signer.publicKey)
        ..['x-ghost-time'] = '$time'
        ..['x-ghost-sig'] = base64Encode(sig);
      // A blob's piece says its hash and length up front, so the relay checks the signature before it reads the body
      // (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"). The words signed are the same as ever, so
      // a relay from before this reads the headers as nothing and checks the signature at the end, as it did.
      if (sayHash) {
        headers
          ..['x-ghost-body-sha256'] = sha
          ..['x-ghost-body-length'] = '${signBody.length}';
      }
    }
    return headers;
  }

  /// The address of [path] (which may carry a query) on the relay.
  Uri _url(String path) => base.replace(path: path.split('?').first, query: path.contains('?') ? path.substring(path.indexOf('?') + 1) : null);

  /// The answer as JSON; a status of 300 or more is thrown as a [FilesError] with the relay's words.
  Future<Map<String, dynamic>> _json(FilesAnswer res) async {
    final text = await res.body.transform(utf8.decoder).join();
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      m = {};
    }
    if (res.status >= 300) throw FilesError(res.status, m['err'] is String ? m['err'] as String : 'The files server said ${res.status}.', have: (m['have'] as num?)?.toInt(), seq: (m['seq'] as num?)?.toInt());
    return m;
  }

  /// One request and its JSON answer. Every way of not reaching the server comes out as a [FilesError] of status 0
  /// (the transport's to say: lib/files/files_http.dart).
  Future<Map<String, dynamic>> _call(String method, String rest, {List<int>? body, bool sign = false, bool sayHash = false}) async {
    final path = _path(rest);
    final headers = await _headers(method, path, signBody: sign ? (body ?? const []) : null, sayHash: sayHash);
    return _json(await _http.send(method, _url(path), headers, body));
  }

  /// Makes the space on the relay, or finds it: [owner] (the space owner's public key, hex) may remove anyone's file.
  /// [rv], from the owner's or an admin's device, says the space's newest roster revision (FilesStore._statement), so the
  /// relay refuses an older roster shown to it later; signed with the rest of the request.
  Future<FilesInfo> ensure({String owner = '', Map<String, Object?>? rv}) async =>
      FilesInfo.from(await _call('PUT', '', body: utf8.encode(jsonEncode({'owner': owner, 'rv': ?rv})), sign: true));

  /// What the relay says of the space now.
  Future<FilesInfo> info() async => FilesInfo.from(await _call('GET', ''));

  /// The log's entries after [after]: each `{s, by, at, o}` with `o` the sealed operation in base64.
  Future<({List<Map<String, dynamic>> ops, int seq, bool more})> log({int after = 0}) async {
    final m = await _call('GET', '/log?after=$after');
    return (ops: [for (final o in (m['ops'] as List? ?? const [])) (o as Map).cast<String, dynamic>()], seq: (m['seq'] as num?)?.toInt() ?? 0, more: m['more'] == true);
  }

  /// Adds a sealed operation to the log: its number. With [after] (the last entry this device has read, which the
  /// entry is signed with), it goes right after that one or the relay answers 409 with where the log has got to.
  Future<int> append(Uint8List sealed, {int? after}) async => ((await _call('POST', after == null ? '/log' : '/log?after=$after', body: sealed, sign: true))['seq'] as num).toInt();

  /// Room for a sealed file of [size] bytes: its blob's id. `pre` says every piece of it will say its hash up front
  /// ([put]), so the relay refuses one that doesn't before reading it; a relay from before reads past it.
  Future<String> newBlob(int size) async => (await _call('POST', '/blobs', body: utf8.encode(jsonEncode({'size': size, 'pre': true})), sign: true))['id'] as String;

  /// How many sealed bytes of [blob] the relay has, how many it is to be, and whether it was finished ([done]).
  Future<({int have, int size, bool done})> state(String blob) async {
    final m = await _call('GET', '/blobs/$blob/state');
    return (have: (m['have'] as num).toInt(), size: (m['size'] as num).toInt(), done: m['done'] == true);
  }

  /// A piece of a blob at [offset] (where it has got to): what it has after.
  Future<int> put(String blob, int offset, Uint8List bytes) async => ((await _call('PUT', '/blobs/$blob?offset=$offset', body: bytes, sign: true, sayHash: true))['have'] as num).toInt();

  /// Tells the relay [blob] is all there.
  Future<void> done(String blob) => _call('POST', '/blobs/$blob/done', sign: true);

  /// Lets [blob] go on the relay: this device's own, or the owner's; or anyone's, as a moderator or admin, with the
  /// space's [roster] (as for [ensure]) that says so.
  Future<void> deleteBlob(String blob, {Map<String, Object?>? roster}) => _call('DELETE', '/blobs/$blob', body: roster == null ? null : utf8.encode(jsonEncode({'roster': roster})), sign: true);

  /// The blob from [start] on (to [end], inclusive, where given), as it streams in. Throws a [FilesError] for a refusal.
  Future<Stream<List<int>>> read(String blob, {int start = 0, int? end}) async {
    final path = _path('/blobs/$blob');
    final headers = await _headers('GET', path);
    if (start > 0 || end != null) headers['range'] = 'bytes=$start-${end ?? ''}';
    final res = await _http.send('GET', _url(path), headers, null);
    if (res.status != 200 && res.status != 206) await _json(res);
    if (start > 0 && res.status == 200) {
      // A server that ignored the Range: what was had is skipped.
      var skip = start;
      return res.body.map((piece) {
        if (skip <= 0) return piece;
        if (piece.length <= skip) {
          skip -= piece.length;
          return const <int>[];
        }
        final rest = piece.sublist(skip);
        skip = 0;
        return rest;
      });
    }
    return res.body;
  }

  /// Drops its connections at once, whatever is under way on them.
  void close() => _http.close(force: true);

  /// Lets its connections go once what is under way on them is done (a client replaced, not stopped).
  void closeIdle() => _http.close();
}

/// What the relay says of a space: how much it holds and may hold, the largest file, and the log's last number.
/// An upload the relay holds part of and is not finished (relay/lib/files.dart `_info`'s `parts`): its blob's id, the
/// install that started it, its sealed size, how much is there, and when it last moved. Its room is held until it is
/// finished, removed, or let go by the relay a day after its last piece.
@immutable
class FilesPart {
  const FilesPart({required this.id, required this.by, required this.size, required this.have, required this.at});
  final String id, by;
  final int size, have;
  final DateTime at;

  /// One as the relay lists it; null where [j] isn't one.
  static FilesPart? from(Object? j) {
    if (j is! Map || j['id'] is! String || j['by'] is! String || j['z'] is! num) return null;
    return FilesPart(id: j['id'] as String, by: j['by'] as String, size: (j['z'] as num).toInt(), have: (j['h'] as num?)?.toInt() ?? 0, at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0));
  }

  Map<String, Object?> toJson() => {'id': id, 'by': by, 'z': size, 'h': have, 'at': at.millisecondsSinceEpoch};
}

class FilesInfo {
  const FilesInfo({this.seq = 0, this.used = 0, this.quota = 0, this.maxFile = 0, this.files = 0, this.owner = '', this.rv = 0, this.cas = false, this.parts = const []});

  /// Uploads not finished on the relay (a relay from before 2026-11-21 says none).
  final List<FilesPart> parts;
  final int seq, used, quota, maxFile, files;
  final String owner;

  /// The newest roster revision the relay has believed for the space (0 from a relay from before rosters).
  final int rv;

  /// Whether the relay puts an entry sent with `?after=` only right there (relay/lib/files.dart): then a signed entry
  /// out of its place was moved by the relay (FilesList.read).
  final bool cas;
  factory FilesInfo.from(Map<String, dynamic> m) => FilesInfo(
        seq: (m['seq'] as num?)?.toInt() ?? 0,
        used: (m['used'] as num?)?.toInt() ?? 0,
        quota: (m['quota'] as num?)?.toInt() ?? 0,
        maxFile: (m['maxFile'] as num?)?.toInt() ?? 0,
        files: (m['files'] as num?)?.toInt() ?? 0,
        owner: m['owner'] is String ? m['owner'] as String : '',
        rv: (m['rv'] as num?)?.toInt() ?? 0,
        cas: m['cas'] == 1,
        parts: [for (final p in (m['parts'] is List ? m['parts'] as List : const [])) ?FilesPart.from(p)],
      );
  /// As the relay says it ([FilesInfo.from] reads it back): the owner, the roster's revision and `cas` with the rest,
  /// so a space loaded from disk knows them before the relay is next asked.
  Map<String, Object?> toJson() => {'seq': seq, 'used': used, 'quota': quota, 'maxFile': maxFile, 'files': files, if (owner.isNotEmpty) 'owner': owner, if (rv != 0) 'rv': rv, if (cas) 'cas': 1, if (parts.isNotEmpty) 'parts': [for (final p in parts) p.toJson()]};
}
