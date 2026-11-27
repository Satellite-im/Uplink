import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bounty.dart';
import 'feedback.dart';
import 'files.dart';
import 'hub.dart';
import 'market.dart';
import 'sha256.dart';
import 'souls_send.dart';
import 'web_app.dart';
import 'ws_door.dart';

/// Uplink's relay (docs/desktop.md): a WebSocket server a phone and the computer it is paired with both dial
/// out to when they are on different networks. It passes what one sends to the other while both are connected, and
/// that is all.
///
/// - A pairing has a **channel** (32 hex digits, the last part of the address) and a **token** (64 hex digits), both
///   made by the two ends from the key only they hold. The first to name a channel sets its token; from then only
///   holders of it get in, one phone and one computer at a time.
/// - **What is kept:** for each channel, the SHA-256 of its token and the day it was last used. No frame is ever
///   written anywhere or held for later: with the other end away a frame is dropped and its sender told.
/// - **What it can see:** that two addresses share a channel, when, and how much they send. The frames are sealed
///   with a key it never has (android/.../DeskCrypto.kt, lib/desktop/link/crypto.dart), and it logs no addresses.
/// - A channel is removed when either end says so (unpairing), or after ninety days unused. One made for pairing
///   (`temp`) lives ten minutes at most, goes as soon as both ends have left it, and is never written to disk.
class Relay {
  Relay({this.dataDir, DateTime Function()? now, this.verbose = false, this.hub, this.files, this.feedback, this.market, this.bounty, this.souls, this.web, this.appOrigin, WireBudget? wire})
      : _now = now ?? DateTime.now,
        wire = wire ?? hub?.wire ?? WireBudget.shared;

  /// The address of the app in a browser served apart from this relay (`GHOST_APP_ORIGIN`, [appOriginFrom]; for
  /// gogho.st, https://app.gogho.st), whose page sends two things here: a report to the Marketplace's review
  /// (`POST /market/abuse`) and feedback (`POST /feedback`). A browser lets that page read their answers only where the
  /// answers say so (CORS), and only those two say so, to that address alone. None where null: no answer says so.
  final String? appOrigin;

  /// The headers a request from [appOrigin] to those two may carry: what they are signed with, and the body's kind.
  static const appHeaders = 'content-type, x-ghost-key, x-ghost-time, x-ghost-sig, x-ghost-body-sha256, x-ghost-body-length';

  /// What a request from [appOrigin] to a Files space's files (`/files/...`, files.dart) may carry besides: the space's
  /// token, and the part of a blob asked for. And the ways it may ask: list and read, make and write, delete.
  static const filesHeaders = 'authorization, range, $appHeaders';
  static const filesMethods = 'GET, PUT, POST, DELETE';

  /// `GHOST_APP_ORIGIN` from [env], as a browser names an address in its `Origin` header: https and a host (a port
  /// where one is said), or http to this machine, for a try here; lower case, no slash after. Null where it is unset,
  /// or anything else (said on stderr).
  static String? appOriginFrom(Map<String, String> env) {
    final said = (env['GHOST_APP_ORIGIN'] ?? '').trim();
    if (said.isEmpty) return null;
    final origin = said.toLowerCase().replaceFirst(RegExp(r'/$'), '');
    if (RegExp(r'^https://[a-z0-9.-]+(:[0-9]{1,5})?$').hasMatch(origin) || RegExp(r'^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?$').hasMatch(origin)) return origin;
    stderr.writeln('relay: GHOST_APP_ORIGIN is not an address a browser names (https://host, or http://127.0.0.1:port): left off');
    return null;
  }

  /// The app in a browser, as plain files (web_app.dart), served under `/app/`; none where null.
  final WebApp? web;

  /// What every connection may hold together, waiting to go out or half come in (ws_door.dart, [WireBudget]): the
  /// hub's, so the pairings' door and the hub's count against one budget.
  final WireBudget wire;

  /// Where people's apps find each other (hub.dart), served at any address ending in `/hub`; none where null.
  final Hub? hub;

  /// Files spaces' sealed files (files.dart), served under `/files/`; none where null.
  final Files? files;

  /// Feedback from the app, filed in a Notion board (feedback.dart), served under `/feedback`; none where null.
  final Feedback? feedback;

  /// Bounties paid in souls by the bounty key (bounty.dart), under `/bounty`; none where null.
  final Bounty? bounty;

  /// Souls sent from one person to another (souls_send.dart), under `/souls/send` and `/souls/receipt`; none where null.
  final SoulsSend? souls;

  /// The Marketplace, plugins from other developers and their review (market.dart), served under `/market`; none where
  /// null.
  final Market? market;

  /// Where `channels.json` is kept; null keeps nothing across restarts.
  final Directory? dataDir;
  final bool verbose;
  final DateTime Function() _now;

  /// The most bytes in one sealed frame passed between the two ends: a megabyte and room for the seal. A longer one
  /// closes the sender's connection.
  /// [tempLife]: how long a channel made for pairing lasts. [idleLife]: how long a pairing's channel is kept unused.
  /// [authWait]: how long a new connection has to say its token before it is closed (4401).
  /// [maxChannels]: the most channels kept at once; past it a new one is refused.
  static const maxFrame = (1 << 20) + 64;

  /// The longest message read at all: a frame past [maxFrame] closes the channel once it is read, and one past this
  /// ends the connection before it is held (ws_door.dart).
  static const maxMessage = maxFrame + (64 << 10);
  static const tempLife = Duration(minutes: 10);
  static const idleLife = Duration(days: 90);
  static const authWait = Duration(seconds: 10);
  static const maxChannels = 200000;

  final Map<String, _Channel> _channels = {};
  HttpServer? _server;
  // Runs sweep() every minute; _saver is the pending write of channels.json (_saveSoon).
  Timer? _sweeper;
  Timer? _saver;

  int get channelCount => _channels.length;

  /// Starts listening; the port it got (ask for 0 to be given a free one).
  Future<int> start({String host = '127.0.0.1', int port = 8787}) async {
    _load();
    final server = await HttpServer.bind(host, port);
    _server = server;
    // Nothing waits on what a listener returns: a request's own error, unhandled, would end the relay and every hub
    // connection with it, so each one's is its alone (review, 2026-11-20).
    server.listen((request) => unawaited(_handle(request).catchError((Object _) {})), onError: (_) {});
    hub?.start();
    await files?.start();
    await market?.start();
    _sweeper = Timer.periodic(const Duration(minutes: 1), (_) => sweep());
    return server.port;
  }

  /// Stops every part, writes channels.json once more and closes each end's connection (going away).
  Future<void> stop() async {
    _sweeper?.cancel();
    _saver?.cancel();
    hub?.stop();
    files?.stop();
    await market?.stop();
    _save();
    for (final c in _channels.values) {
      c.phone?.close(WebSocketStatus.goingAway);
      c.desk?.close(WebSocketStatus.goingAway);
    }
    await _server?.close(force: true);
  }

  static final _hexOnly = RegExp(r'^[0-9a-f]+$');
  static bool _hex(Object? text, int length) => text is String && text.length == length && _hexOnly.hasMatch(text);

  /// Today in UTC as `yyyy-mm-dd`: what a channel's last use is kept as.
  String _day() => _now().toUtc().toIso8601String().substring(0, 10);

  void _say(String what) {
    // Never an address, never a whole channel: enough to follow a pairing while trying the relay on a desk.
    if (verbose) stdout.writeln('${_now().toIso8601String()} $what');
  }

  /// One request, whatever it asks, never ending the relay: a path whose escapes aren't UTF-8 (`GET /market/%FF`, which
  /// Caddy passes on as it came) made the path's decoding throw before anything was routed, outside the market's own
  /// guard, and the error went unhandled, ending the relay and every hub connection with it, the market's day counts
  /// too; a request every two seconds kept it down (review, 2026-11-20). Such a request is a 400 and nothing more; any
  /// other error is a line on stderr and a 500, where nothing has been answered yet.
  Future<void> _handle(HttpRequest request) async {
    final List<String> segments;
    try {
      segments = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    } on FormatException {
      return _answerOnly(request, HttpStatus.badRequest);
    }
    try {
      await _route(request, segments);
    } on FormatException {
      // A query's escapes, read further in: the asker's mistake, not the relay's, and nothing to log.
      await _answerOnly(request, HttpStatus.badRequest);
    } catch (e) {
      stderr.writeln('relay: ${request.method} ${'$e'.split('\n').first}');
      await _answerOnly(request, HttpStatus.internalServerError);
    }
  }

  /// Whether [segments] is one of the two things the app's page sends from its own address ([appOrigin]), and this
  /// relay takes it: `/market/abuse`, `/feedback`.
  bool _fromTheApp(List<String> segments) =>
      (segments.length == 2 && segments[0] == 'market' && segments[1] == 'abuse' && market != null) || (segments.length == 1 && segments[0] == 'feedback' && feedback != null) || _souls(segments) || _filesFromTheApp(segments);

  /// Whether [segments] is one of the two routes souls are sent by (souls_send.dart), and this relay has them.
  bool _souls(List<String> segments) => souls != null && segments.length == 2 && segments[0] == 'souls' && (segments[1] == 'send' || segments[1] == 'receipt');

  /// Whether [segments] is a Files space's files, which the app's page at [appOrigin] lists, reads and writes from a
  /// build with Files spaces (docs/OPEN_NETWORK.md, part 6): `/files/<space>...`, and this relay keeps files. Every
  /// request still needs the space's token, and every write its signature, as from the app; the browser's rule only
  /// stops other pages reading the answers, and so it is for the app's page alone.
  bool _filesFromTheApp(List<String> segments) => segments.length >= 2 && segments[0] == 'files' && files != null;

  /// [status] and nothing else, where the answer hasn't begun: its headers sent already (or a WebSocket's), nothing.
  static Future<void> _answerOnly(HttpRequest request, int status) async {
    try {
      request.response
        ..statusCode = status
        ..headers.set(HttpHeaders.connectionHeader, 'close');
      await request.response.close();
    } catch (_) {}
  }

  /// Hands a request to the part that serves its path (the hub, /link, /files, /word, /market, /feedback). What is left
  /// is a pairing's own connection: a WebSocket to an address ending in a channel's 32 hex digits, served here. Its first
  /// message is `{auth, role, temp?}`; after that bytes go to the other end untouched, and words are `{delete: true}`
  /// or `{ping}`. Close codes: 4400 bad hello, 4401 no token in time, 4403 wrong token or relay full, 4409 replaced by
  /// a newer connection of the same end, 4410 the channel was removed.
  Future<void> _route(HttpRequest request, List<String> segments) async {
    final name = segments.isEmpty ? '' : segments.last;
    final upgrade = WebSocketTransformer.isUpgradeRequest(request);
    // From the app's page at its own address ([appOrigin]): a report, feedback, or a Files space's files, its answer
    // readable by that page.
    if (!upgrade && appOrigin != null && _fromTheApp(segments)) {
      request.response.headers.add(HttpHeaders.varyHeader, 'Origin');
      if (request.headers.value('origin') == appOrigin) {
        request.response.headers.set('access-control-allow-origin', appOrigin!);
        // What the browser asks first, the headers being the app's own: yes, for a POST with them, for ten minutes.
        if (request.method == 'OPTIONS') {
          final files = _filesFromTheApp(segments);
          request.response
            ..statusCode = HttpStatus.noContent
            ..headers.set('access-control-allow-methods', files ? filesMethods : 'POST')
            ..headers.set('access-control-allow-headers', files ? filesHeaders : appHeaders)
            ..headers.set('access-control-max-age', '600');
          await request.response.close();
          return;
        }
      }
    }
    // The hub is its own thing with its own way in (hub.dart): `/hub`, behind whatever the web server puts before it.
    if (upgrade && name == 'hub' && hub != null) return hub!.accept(request);
    // Signing in with a network to link its handle (handles.dart): a browser's pages, under /link/.
    if (!upgrade && segments.isNotEmpty && segments.first == 'link' && hub?.handles != null) {
      if (await hub!.handles!.http(request)) return;
    }
    // A Files space's files (files.dart): plain HTTP under /files/, never a WebSocket.
    if (!upgrade && segments.isNotEmpty && segments.first == 'files' && files != null) return files!.handle(request);
    // A circle's invite word, for the site's /c/ page (invite_words.dart): GET /word/<hash>.
    if (!upgrade && segments.length == 2 && segments.first == 'word' && hub?.words != null) return hub!.words!.handle(request, segments[1]);
    // The Marketplace (market.dart): plain HTTP under /market. Nothing waits on what _handle returns (server.listen drops
    // it), so an error escaping the market would be unhandled in the root zone and end the relay, and every hub
    // connection with it: the market never throws, and this makes sure.
    if (!upgrade && segments.isNotEmpty && segments.first == 'market' && market != null) return market!.handle(request).catchError((Object _) {});
    // The app in a browser (web_app.dart): its files, under /app/.
    if (!upgrade && segments.isNotEmpty && segments.first == 'app' && web != null) return web!.handle(request, segments.sublist(1));
    // The app's Share feedback (feedback.dart): one POST to /feedback.
    if (!upgrade && segments.length == 1 && segments.first == 'feedback' && feedback != null) return feedback!.handle(request);
    // A bounty's souls (bounty.dart): one signed POST to /bounty.
    if (!upgrade && segments.length == 1 && segments.first == 'bounty' && bounty != null) return bounty!.handle(request);
    // Souls sent to a friend (souls_send.dart; GMFB-39): a signed POST to /souls/send, and /souls/receipt to check one.
    if (!upgrade && _souls(segments)) return souls!.handle(request, segments[1]);
    if (!upgrade || !_hex(name, 32)) {
      request.response
        ..statusCode = upgrade ? HttpStatus.notFound : HttpStatus.ok
        ..headers.contentType = ContentType.text
        ..write('Ghost Messaging relay\n');
      await request.response.close();
      return;
    }
    final WebSocket ws;
    try {
      // No compression, as the hub (hub.dart, accept): a deflated message opens out before its length is looked at.
      // And no message longer than a frame this door takes, with a margin, is held at all (ws_door.dart).
      final up = await upgradeGuarded(request, most: maxMessage, budget: wire);
      if (up == null) return;
      ws = up;
    } catch (_) {
      return;
    }
    ws.pingInterval = const Duration(seconds: 30);

    _Channel? channel;
    String role = '';
    final waiting = Timer(authWait, () {
      if (channel == null) ws.close(4401, 'no token');
    });

    // This connection has ended: frees its end of the channel and tells the other end its peer has gone.
    void leave() {
      waiting.cancel();
      final c = channel;
      if (c == null) return;
      channel = null;
      if (c.socket(role) != ws) return; // replaced by a newer connection of the same end
      c.set(role, null);
      _tell(c.other(role), {'peer': false});
      _say('${name.substring(0, 6)} $role left');
      // A channel made for pairing is done with once both ends have gone: it does not wait out its ten minutes.
      if (c.expires != null && c.phone == null && c.desk == null && identical(_channels[name], c)) _channels.remove(name);
    }

    ws.listen((data) {
      final c = channel;
      if (c == null) {
        // The first thing said is the token and which end this is.
        Map? hello;
        try {
          hello = data is String ? jsonDecode(data) as Map : null;
        } catch (_) {}
        final token = hello?['auth'];
        final asRole = hello?['role'];
        if (!_hex(token, 64) || (asRole != 'phone' && asRole != 'desk')) {
          _tell(ws, {'ok': false, 'err': 'bad hello'});
          ws.close(4400, 'bad hello');
          return;
        }
        final joined = _join(name, token as String, hello?['temp'] == true);
        if (joined == null) {
          _tell(ws, {'ok': false, 'err': 'refused'});
          ws.close(4403, 'refused');
          return;
        }
        waiting.cancel();
        role = asRole as String;
        joined.socket(role)?.close(4409, 'replaced');
        joined.set(role, ws);
        channel = joined;
        _tell(ws, {'ok': true, 'peer': joined.other(role) != null});
        _tell(joined.other(role), {'peer': true});
        _say('${name.substring(0, 6)} $role joined${joined.expires != null ? ' (pairing)' : ''}');
        return;
      }
      // A sealed frame: passed to the other end as it came, or dropped and the sender told where the other is away.
      if (data is List<int>) {
        if (data.length > maxFrame) {
          ws.close(WebSocketStatus.messageTooBig, 'too big');
          return;
        }
        final other = c.other(role);
        if (other == null || other.readyState != WebSocket.open) {
          _tell(ws, {'dropped': true});
        } else {
          other.add(data);
        }
        return;
      }
      // Words to the relay itself: unpairing (the channel goes, for both ends) or a ping to be answered.
      Map? said;
      try {
        said = jsonDecode(data as String) as Map;
      } catch (_) {}
      if (said?['delete'] == true) {
        _remove(name, 'deleted');
      } else if (said != null && said.containsKey('ping')) {
        _tell(ws, {'pong': said['ping']});
      }
    }, onDone: leave, onError: (_) => leave(), cancelOnError: true);
  }

  /// Something the relay itself says to an end, in words; nothing is said to one that has gone.
  void _tell(WebSocket? ws, Map<String, Object?> what) {
    if (ws == null || ws.readyState != WebSocket.open) return;
    try {
      ws.add(jsonEncode(what));
    } catch (_) {}
  }

  /// The channel [name] for a holder of [token]: made if it is new, null if the token is not its own.
  _Channel? _join(String name, String token, bool temp) {
    final hash = hexOf(sha256(utf8.encode(token)));
    final had = _channels[name];
    if (had != null && had.expires != null && !_now().isBefore(had.expires!)) {
      _remove(name, 'expired');
    }
    final c = _channels[name];
    if (c != null) {
      if (c.hash != hash) return null;
      if (c.expires == null && c.day != _day()) {
        c.day = _day();
        _saveSoon();
      }
      return c;
    }
    if (_channels.length >= maxChannels) return null;
    final made = _Channel(hash, _day(), temp ? _now().add(tempLife) : null);
    _channels[name] = made;
    if (!temp) _saveSoon();
    return made;
  }

  /// Forgets the channel [name] and closes both its ends with 4410 and [why].
  void _remove(String name, String why) {
    final c = _channels.remove(name);
    if (c == null) return;
    final ends = [c.phone, c.desk];
    c.phone = null;
    c.desk = null;
    for (final ws in ends) {
      ws?.close(4410, why);
    }
    if (c.expires == null) _saveSoon();
    _say('${name.substring(0, 6)} $why');
  }

  /// Removes pairing channels past their ten minutes, and channels nobody has used for ninety days.
  void sweep() {
    final now = _now();
    final cutoff = now.subtract(idleLife).toUtc().toIso8601String().substring(0, 10);
    for (final name in _channels.keys.toList()) {
      final c = _channels[name]!;
      if (c.expires != null) {
        if (!now.isBefore(c.expires!)) _remove(name, 'expired');
      } else if (c.phone == null && c.desk == null && c.day.compareTo(cutoff) < 0) {
        _remove(name, 'unused');
      }
    }
  }

  // --- what is kept ----------------------------------------------------------------------------------------------------

  File? get _file => dataDir == null ? null : File('${dataDir!.path}/channels.json');

  /// Reads channels.json at the start: `{v, channels: {<channel>: {h: token hash, d: day last used}}}`.
  void _load() {
    final f = _file;
    if (f == null || !f.existsSync()) return;
    try {
      final all = (jsonDecode(f.readAsStringSync()) as Map)['channels'] as Map;
      for (final e in all.entries) {
        final v = e.value as Map;
        if (_hex(e.key, 32) && _hex(v['h'], 64) && v['d'] is String) _channels[e.key as String] = _Channel(v['h'] as String, v['d'] as String, null);
      }
    } catch (e) {
      stderr.writeln('channels.json could not be read: $e');
    }
    sweep();
  }

  /// Writes channels.json two seconds after the last change, so a burst of joins is one write.
  void _saveSoon() {
    if (dataDir == null) return;
    _saver?.cancel();
    _saver = Timer(const Duration(seconds: 2), _save);
  }

  /// Writes the pairings' channels (never one made for pairing) to a file beside and renames it over, so a stop
  /// halfway never leaves half a file.
  void _save() {
    final f = _file;
    if (f == null) return;
    try {
      dataDir!.createSync(recursive: true);
      final kept = {
        for (final e in _channels.entries)
          if (e.value.expires == null) e.key: {'h': e.value.hash, 'd': e.value.day},
      };
      final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode({'v': 1, 'channels': kept}));
      tmp.renameSync(f.path);
    } catch (e) {
      stderr.writeln('channels.json could not be written: $e');
    }
  }
}

/// One pairing's channel: what is kept of it, and the connection of each end while it is here.
class _Channel {
  _Channel(this.hash, this.day, this.expires);

  /// SHA-256 of the channel's token, in hex.
  final String hash;

  /// The day (UTC) it was last joined.
  String day;

  /// When a channel made for pairing ends; null for a pairing's own.
  final DateTime? expires;
  WebSocket? phone;
  WebSocket? desk;

  WebSocket? socket(String role) => role == 'phone' ? phone : desk;
  WebSocket? other(String role) => role == 'phone' ? desk : phone;
  void set(String role, WebSocket? ws) => role == 'phone' ? phone = ws : desk = ws;
}
