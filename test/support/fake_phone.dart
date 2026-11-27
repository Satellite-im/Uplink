import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_messaging/desktop/link/crypto.dart';
import 'package:ghost_messaging/desktop/link/link.dart';

/// A phone, for the Mac's tests: what android/.../DeskSession.kt, Desk.kt and DeskService.kt do, in Dart, with made-up
/// conversations behind it. It listens on a port of this machine as the phone does on the local network, and dials a
/// relay as the phone does. It is a second writing of the phone's side, so it shows the Mac's side holds to the
/// protocol as written down (docs/desktop.md), not to itself; the two real sides meet on the emulator.
class FakePhone {
  FakePhone({this.name = 'Fold'});

  final String name;
  final keys = <String, Uint8List>{};
  final modes = <String, String>{};
  ({String pid, Uint8List key, Uint8List public, DeskOffer offer})? pending;
  String pendingMode = 'both';
  bool mine = false;
  bool theirs = false;

  /// A phone whose app is from before a computer could do more than read and send text: it does none of the newer
  /// things, and says so in the words the real one does.
  bool old = false;

  /// What the Mac handed over in pieces and had sent, whole: pictures, a voice recording, a sticker.
  final uploads = <String, BytesBuilder>{};
  final handed = <({String what, String name, String body, List<Uint8List> bytes})>[];

  /// What the Mac asked the phone to do to what it keeps.
  final did = <String>[];

  /// What the Mac asked to be sent, and by which names.
  final sent = <({List<String> addresses, String body})>[];
  final sentKeys = <String, int>{};
  final read = <int>[];
  final heard = <String>[];

  /// Each lot of conversations the Mac asked for: from which row, and how many.
  final asked = <({int offset, int limit})>[];

  /// Each time a conversation's messages were asked for, and how many of them.
  final askedMessages = <({int thread, int limit})>[];

  /// Every hello this phone answered, by how it arrived.
  final hellos = <String>[];

  /// What the first lot also carries, beyond its own rows: a conversation as Google Messages' bridge has it, with
  /// words newer than Android's own row of it further down (android Store.conversationsPage).
  List<Map<String, dynamic>> firstToo = [];

  List<Map<String, dynamic>> conversations = [
    {'id': 7, 'date': 1700000000000, 'people': [{'address': '+15550100', 'name': 'Maya', 'photo': null}], 'snippet': 'See you at 7', 'unread': true, 'error': false, 'archived': false},
    {'id': 9, 'date': 1690000000000, 'people': [{'address': '+15550111', 'name': 'Dad', 'photo': null}], 'snippet': 'Call me', 'unread': false, 'error': false, 'archived': false},
  ];
  final messages = <int, List<Map<String, dynamic>>>{
    7: [{'id': 1, 'kind': 'sms', 'address': '+15550100', 'body': 'See you at 7', 'date': 1700000000000, 'outgoing': false, 'state': 'received', 'parts': const []}],
  };
  Uint8List picture = Uint8List.fromList(List.generate(900000, (i) => i % 251));
  int _nextMessage = 100;

  ServerSocket? _server;
  final _sessions = <_Session>[];
  final _relays = <WebSocket>[];

  int get port => _server!.port;
  Peer get peer => Peer('127.0.0.1', port);

  // --- the local network ------------------------------------------------------------------------------------------------

  Future<void> listen({int port = 0}) async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen((socket) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      socket.done.then((_) {}, onError: (_) {});
      late final _Session session;
      session = _Session(this, 'local', (frame) {
        final head = Uint8List(4);
        ByteData.sublistView(head).setUint32(0, frame.length);
        socket.add(head);
        socket.add(frame);
      }, socket.destroy);
      var buffer = Uint8List(0);
      socket.listen((bytes) {
        buffer = Uint8List.fromList([...buffer, ...bytes]);
        while (buffer.length >= 4) {
          final length = ByteData.sublistView(buffer, 0, 4).getUint32(0);
          if (buffer.length - 4 < length) break;
          session.receive(Uint8List.sublistView(buffer, 4, 4 + length));
          buffer = Uint8List.sublistView(buffer, 4 + length);
        }
      }, onDone: session.close, onError: (_) => session.close(), cancelOnError: true);
    });
  }

  /// The phone leaves the local network (its Wi-Fi goes): the port closes and so does every connection through it.
  Future<void> leaveLocal() async {
    final was = _server?.port;
    await _server?.close();
    _server = null;
    for (final s in List.of(_sessions)) {
      if (s.via == 'local') s.close();
    }
    _lastPort = was;
  }

  int? _lastPort;
  Future<void> rejoinLocal() => listen(port: _lastPort ?? 0);

  // --- the relay --------------------------------------------------------------------------------------------------------

  Future<void> joinRelay(String base, String channel, String token, {bool temp = false}) async {
    final ws = await WebSocket.connect('$base/$channel');
    _relays.add(ws);
    ws.add(jsonEncode({'auth': token, 'role': 'phone', if (temp) 'temp': true}));
    _Session? session;
    ws.listen((data) {
      if (data is String) {
        final said = jsonDecode(data) as Map;
        if (said.containsKey('peer') && said['peer'] != true) session?.close();
        return;
      }
      final frame = Uint8List.fromList(data as List<int>);
      if (frame.isNotEmpty && frame[0] == DeskCrypto.hello) {
        session?.close();
        session = _Session(this, 'relay', ws.add, () {});
      }
      session?.receive(frame);
    }, onDone: () => session?.close());
  }

  Future<void> joinPairingRelay() => joinRelay(pending!.offer.relay, DeskCrypto.pairingChannel(pending!.offer.secret), DeskCrypto.pairingToken(pending!.offer.secret), temp: true);
  Future<void> joinPairedRelay(String id, String base) => joinRelay(base, DeskCrypto.relayChannel(keys[id]!), DeskCrypto.relayToken(keys[id]!));

  Future<void> leaveRelay() async {
    for (final ws in List.of(_relays)) {
      await ws.close();
    }
    _relays.clear();
  }

  // --- pairing, as the phone's screen drives it ---------------------------------------------------------------------------

  /// The code was scanned: the phone's own key pair, and the pairing's key.
  void scan(String code, {String? mode}) {
    final offer = DeskOffer.parse(code)!;
    final pair = DeskCrypto.newKeyPair();
    pending = (pid: DeskCrypto.pairingId(offer.secret), key: DeskCrypto.pairKey(pair, offer.key, offer.secret)!, public: pair.public, offer: offer);
    pendingMode = mode ?? offer.mode;
    mine = false;
    theirs = false;
  }

  String get code => DeskCrypto.code(pending!.key);

  void confirm() {
    mine = true;
    final s = _pairingSession;
    s?.event('mode', {'mode': pendingMode});
    s?.event('confirmed');
    _finishIfBoth();
  }

  _Session? get _pairingSession => _sessions.where((s) => s.pairing && s.live).firstOrNull;

  void _finishIfBoth() {
    final p = pending;
    final s = _pairingSession;
    if (p == null || s == null || !mine || !theirs) return;
    final id = DeskCrypto.id(p.key);
    keys[id] = p.key;
    modes[id] = pendingMode;
    s.id = id;
    s.pairing = false;
    pending = null;
  }

  // --- once paired --------------------------------------------------------------------------------------------------------

  String? get via {
    final live = _sessions.where((s) => s.live && !s.pairing);
    return live.any((s) => s.via == 'local') ? 'local' : live.firstOrNull?.via;
  }

  /// A text arrived for conversation [thread].
  void arrive(int thread, String body) {
    messages.putIfAbsent(thread, () => []).insert(0, {'id': _nextMessage++, 'kind': 'sms', 'address': '+15550100', 'body': body, 'date': DateTime.now().millisecondsSinceEpoch, 'outgoing': false, 'state': 'received', 'parts': const []});
    changed(thread);
  }

  void changed(int thread) {
    for (final s in _sessions) {
      if (s.live && !s.pairing) s.event('changed', {'thread': thread});
    }
  }

  void unpair(String id) {
    for (final s in List.of(_sessions)) {
      if (s.id == id) {
        s.event('unpaired');
        s.close();
      }
    }
    keys.remove(id);
  }

  void setMode(String id, String mode) {
    modes[id] = mode;
    for (final s in _sessions) {
      if (s.id == id && s.live) s.event('mode', {'mode': mode});
    }
  }

  Future<void> stop() async {
    await _server?.close();
    for (final s in List.of(_sessions)) {
      s.close();
    }
    await leaveRelay();
  }

  /// What the computer asked of Settings › Me, and who answers it: null is a phone whose app is not open.
  final meAsked = <Map<String, Object?>>[];
  Object? Function(Map<String, Object?> what)? me;

  dynamic _call(String method, Map<String, dynamic> a) {
    switch (method) {
      case 'ping':
        return null;
      case 'conversations':
        return conversations;
      case 'conversationsPage':
        if (a['archived'] == true) return {'items': [for (final c in conversations) if (c['archived'] == true) c], 'next': null};
        final offset = (a['offset'] as num?)?.toInt() ?? 0;
        final limit = ((a['limit'] as num?)?.toInt() ?? 250).clamp(1, 250);
        final end = (offset + limit).clamp(0, conversations.length);
        asked.add((offset: offset, limit: limit));
        return {'items': [...conversations.sublist(offset.clamp(0, conversations.length), end), if (offset == 0) ...firstToo], 'next': end < conversations.length ? end : null};
      case 'conversation':
        return conversations.where((c) => c['id'] == a['thread']).firstOrNull;
      case 'archivedCount':
        return conversations.where((c) => c['archived'] == true).length;
      case 'messages':
        // As the phone hands them over: the newest first, and no more than were asked for.
        final thread = (a['thread'] as num).toInt();
        final limit = (a['limit'] as num?)?.toInt() ?? 300;
        askedMessages.add((thread: thread, limit: limit));
        return (messages[thread] ?? const <Map<String, dynamic>>[]).take(limit).toList();
      case 'people':
        return conversations.firstWhere((c) => c['id'] == a['thread'])['people'];
      case 'threadFor':
        return 7;
      case 'send':
        final key = a['key'] as String;
        if (sentKeys.containsKey(key)) return {'thread': sentKeys[key], 'again': true};
        final body = a['body'] as String;
        if (body.trim().isEmpty) throw 'Nothing to send';
        sent.add((addresses: [for (final x in a['addresses'] as List) '$x'], body: body));
        sentKeys[key] = 7;
        messages.putIfAbsent(7, () => []).insert(0, {'id': _nextMessage++, 'kind': 'sms', 'address': '', 'body': body, 'date': DateTime.now().millisecondsSinceEpoch, 'outgoing': true, 'state': 'sent', 'parts': const []});
        changed(7);
        return {'thread': 7};
      case 'markRead':
        read.add((a['thread'] as num).toInt());
        conversations.firstWhere((c) => c['id'] == a['thread'])['unread'] = false;
        return null;
      case 'part':
        final offset = (a['offset'] as num?)?.toInt() ?? 0;
        final end = (offset + 384 * 1024).clamp(0, picture.length);
        return {'data': base64.encode(picture.sublist(offset, end)), 'total': picture.length};
      case 'e2e':
        return {'address': a['address'], 'state': 'none'};
      case 'draft':
        return null;
      case 'setDraft' || 'threadFlag' || 'archive':
        return null;
      // What a phone with the newer app does for a computer (android DeskCalls.CAPS); an older one ([old]) does none.
      case 'caps' when !old:
        return ['deleteMessage', 'deleteThread', 'deleteThreads', 'editMessage', 'resendMms', 'setBlocked', 'blockedNumbers', 'e2eOffer', 'e2eOff', 'e2eVerify', 'e2ePlainSeen', 'e2eList', 'mmsStatus', 'voiceLimit', 'put', 'drop', 'sendPictures', 'sendVoice', 'sendSticker', 'ownNumber', 'me'];
      case 'put' when !old:
        final id = a['upload'] as String, offset = (a['offset'] as num).toInt(), total = (a['total'] as num).toInt();
        final data = base64.decode(a['data'] as String);
        final had = uploads.putIfAbsent(id, () => BytesBuilder());
        if (offset != had.length) throw 'A piece came out of its turn';
        if (had.length + data.length > total) throw 'More came than it said it holds';
        had.add(data);
        return {'have': had.length};
      case 'sendPictures' || 'sendVoice' || 'sendSticker' when !old:
        final key = a['key'] as String;
        if (sentKeys.containsKey(key)) return {'thread': sentKeys[key], 'again': true};
        Uint8List take(String id) => (uploads.remove(id) ?? (throw 'That was not handed over')).takeBytes();
        if (method == 'sendPictures') {
          for (final f in (a['files'] as List)) {
            if (!'${(f as Map)['type']}'.startsWith('image/')) throw 'Only pictures can be sent from a computer for now';
          }
          handed.add((what: 'pictures', name: [for (final f in (a['files'] as List)) '${(f as Map)['name']}'].join(','), body: '${a['body'] ?? ''}', bytes: [for (final f in (a['files'] as List)) take('${(f as Map)['upload']}')]));
        } else {
          handed.add((what: method == 'sendVoice' ? 'voice' : 'sticker', name: '${a['name']}', body: '', bytes: [take(a['upload'] as String)]));
        }
        sentKeys[key] = 7;
        changed(7);
        return {'thread': 7};
      case 'voiceLimit' when !old:
        return {'seconds': 91, 'bytes': 299008};
      case 'deleteMessage' || 'editMessage' || 'setBlocked' || 'e2eOff' || 'e2eVerify' || 'e2ePlainSeen' when !old:
        did.add('$method ${a['id'] ?? a['address']}');
        return null;
      case 'deleteThreads' when !old:
        did.add('deleteThreads ${a['threads']}');
        conversations = [for (final c in conversations) if (!(a['threads'] as List).contains(c['id'])) c];
        return (a['threads'] as List).length;
      case 'resendMms' when !old:
        did.add('resendMms ${a['id']}');
        return 7;
      case 'e2eOffer' when !old:
        did.add('e2eOffer ${a['address']}');
        return {'address': a['address'], 'state': 'offered'};
      case 'e2eList' || 'blockedNumbers' when !old:
        return [{'address': '+15550100', 'state': 'on'}];
      case 'mmsStatus' when !old:
        return {'dataOn': true};
      case 'ownNumber' when !old:
        return '+14436537451';
      // Settings › Me's number, done by the phone's Dart side (android DartAsk, Me.forComputer): [me] stands in.
      case 'me' when !old:
        final what = (a['what'] as Map).cast<String, Object?>();
        meAsked.add(what);
        if (me == null) throw 'Open Uplink on your phone, then try again.';
        return me!(what);
      default:
        throw 'The phone doesn\'t do "$method" for a computer';
    }
  }
}

class _Session {
  _Session(this.phone, this.via, this.out, this.drop) {
    phone._sessions.add(this);
  }

  final FakePhone phone;
  final String via;
  final void Function(Uint8List frame) out;
  final void Function() drop;
  String id = '';
  bool pairing = false;
  bool live = false;
  bool closed = false;
  DeskChannel? channel;

  void receive(Uint8List frame) {
    if (closed || frame.isEmpty) return;
    final body = Uint8List.sublistView(frame, 1);
    if (frame[0] == DeskCrypto.hello) {
      if (channel != null) return close();
      final o = jsonDecode(utf8.decode(body)) as Map;
      final name = o['id'] as String;
      final wantsPairing = o['pair'] == true;
      final pending = wantsPairing && phone.pending?.pid == name ? phone.pending : null;
      final key = wantsPairing ? pending?.key : phone.keys[name];
      phone.hellos.add(via);
      if (key == null) {
        out(Uint8List.fromList([DeskCrypto.hello, ...utf8.encode(jsonEncode({'v': 1, 'err': 'unknown'}))]));
        return close();
      }
      final mine = DeskCrypto.newKeyPair();
      final nonce = DeskCrypto.randomBytes(16);
      final keys = DeskCrypto.sessionKeys(key, base64.decode(o['n'] as String), nonce, mine, base64.decode(o['e'] as String))!;
      channel = DeskChannel(sendKey: keys.phone, receiveKey: keys.desk);
      id = name;
      pairing = wantsPairing;
      out(Uint8List.fromList([DeskCrypto.hello, ...utf8.encode(jsonEncode({'v': 1, 'n': base64.encode(nonce), 'e': base64.encode(mine.public), if (pending != null) 'k': base64.encode(pending.public)}))]));
      return;
    }
    final text = channel?.open(body);
    if (text == null) return close();
    final m = jsonDecode(text) as Map<String, dynamic>;
    switch (m['t']) {
      case 'ready':
        live = true;
        _send({'t': 'ready', 'name': phone.name, 'app': '0.7.0', 'proto': 1, 'mode': pairing ? phone.pendingMode : (phone.modes[id] ?? 'both')});
      case 'ev':
        if (!live) return close();
        final name = m['m'] as String;
        phone.heard.add(name);
        switch (name) {
          case 'confirmed':
            phone.theirs = true;
            phone._finishIfBoth();
          case 'unpaired':
            phone.keys.remove(id);
            close();
          case 'mode':
            if (!pairing) phone.modes[id] = (m['a'] as Map)['mode'] as String;
          case 'bye' || 'cancel':
            close();
        }
      case 'req':
        if (!live) return close();
        final answer = <String, dynamic>{'t': 'res', 'id': m['id']};
        if (pairing) {
          _send({...answer, 'ok': false, 'e': 'Not paired yet'});
          return;
        }
        try {
          _send({...answer, 'ok': true, 'r': phone._call(m['m'] as String, (m['a'] as Map?)?.cast<String, dynamic>() ?? const {})});
        } catch (e) {
          _send({...answer, 'ok': false, 'e': '$e'});
        }
      default:
        close();
    }
  }

  void _send(Map<String, dynamic> message) {
    if (closed || channel == null) return;
    try {
      out(Uint8List.fromList([DeskCrypto.sealed, ...channel!.seal(jsonEncode(message))]));
    } catch (_) {
      close();
    }
  }

  void event(String name, [Map<String, dynamic>? args]) {
    if (live) _send({'t': 'ev', 'm': name, 'a': ?args});
  }

  void close() {
    if (closed) return;
    closed = true;
    live = false;
    phone._sessions.remove(this);
    drop();
  }
}
