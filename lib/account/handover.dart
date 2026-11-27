import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../net/crypto.dart';
import 'account_crypto.dart';

/// Signing in on a new device by scanning its code with a phone already signed in (GMFB-45, Matt: "It would be nice to
/// be able to scan a QR code on desktop with my mobile phone to login"; his choice on 2026-11-23: "Words, behind phone
/// lock"). The phone hands the account's recovery words to the new device, which then signs in with them as if they
/// had been typed (Account.signInWithWords), so no password and no texted code is asked.
///
/// - **The code** ([HandoverCode]) holds a public key made for this one sign-in, a random secret, and the address of
///   the relay the new device is on. Nothing of any account.
/// - **How the two reach each other**: both join a room on the relay's hub (relay/lib/hub.dart, "Rooms": the first to
///   name a room sets its token) whose name and token are made from the secret. A room is what a voice room and a QR
///   shown on another screen (lib/net/pair_room.dart) already use, so the relay needs nothing new, and an app from
///   before never hears of such a room. Everything said in it is sealed with a key made from the secret, which the
///   relay never sees.
/// - **The key**: the phone makes a key pair of its own for this one sign-in and says its public half. Both then hold
///   ECDH of the two, through HKDF salted with the secret and bound to both public keys ([HandoverKeys]). The six
///   digits both show are made from that key, so a different key on either side, or another secret, shows as
///   different digits. The new device also proves it holds the key before the phone lets anyone approve.
/// - **The words** are sealed with a key made from that one, sent once, and taken once: the new device takes one
///   answer and leaves the room, and each side gives up two minutes after it began ([lifetime]).
/// - **Never** logged, written anywhere on the way, or kept by the relay (the room's packets are passed on, not kept).
///
/// The phone asks its own lock before [HandoverPhone.approve] is called; that is the screen's work
/// (lib/ui/handover_screens.dart), since this file knows nothing of the device.
abstract final class Handover {
  /// How long a code is good for, counted on each side from when that side began.
  static const lifetime = Duration(minutes: 2);

  /// How often the phone says who it is again until the new device answers.
  static const helloEvery = Duration(seconds: 3);
}

/// The room the two meet in: the relay's hub in the app (lib/account/handover_hub.dart), two ends in memory in a test.
abstract class HandoverRoom {
  /// Joins the room [name] with [token]. Throws where the relay can't be reached or won't let this app in.
  Future<void> join(String name, String token);

  /// Says [packet] to whoever else is in the room. Throws where it can't be said.
  void say(Uint8List packet);

  /// What the others in the room said.
  Stream<Uint8List> get heard;

  /// Leaves the room.
  void leave();
}

/// What the new device's QR code holds: its public key for this sign-in (33 bytes), a secret (32 random bytes) and
/// the relay it is on. As words: `GHOSTSIGNIN1:<key and secret, base64>:<the relay's hub address>`. Not a link, so a
/// phone's own camera opens nothing with it.
class HandoverCode {
  HandoverCode({required this.key, required this.secret, required this.relay});
  final Uint8List key;
  final Uint8List secret;
  final String relay;

  static const tag = 'GHOSTSIGNIN1:';

  /// Whether [text] is meant as one of these (it may still not [parse]).
  static bool isOne(String text) => text.trim().startsWith(tag);

  String get text => '$tag${base64Url.encode([...key, ...secret]).replaceAll('=', '')}:$relay';

  /// The code in [text]; null where it is not one, or its key is no key.
  static HandoverCode? parse(String text) {
    final t = text.trim();
    if (!t.startsWith(tag)) return null;
    final rest = t.substring(tag.length);
    final cut = rest.indexOf(':');
    if (cut < 0) return null;
    final relay = rest.substring(cut + 1).trim();
    if (relay.isEmpty || relay.length > 200) return null;
    try {
      final b = base64Url.decode(base64Url.normalize(rest.substring(0, cut)));
      if (b.length != 33 + 32) return null;
      final key = Uint8List.fromList(b.sublist(0, 33));
      // A point on the curve, or nothing can be agreed with it.
      if (NetCrypto.agree(NetKeys.generate(), key) == null) return null;
      return HandoverCode(key: key, secret: Uint8List.fromList(b.sublist(33)), relay: relay);
    } catch (_) {
      return null;
    }
  }

  // The room's name and token at the relay, and the key everything said in it is sealed with: all from the secret.
  String get room => NetCrypto.hex(NetCrypto.derive(secret, 'signin room').sublist(0, 16));
  String get token => NetCrypto.hex(NetCrypto.derive(secret, 'signin token'));
  Uint8List get roomKey => NetCrypto.derive(secret, 'signin room key');

  /// Whether [a] and [b] are the same relay's address, however they were typed.
  static bool sameRelay(String a, String b) {
    String tidy(String s) => s.trim().toLowerCase().replaceFirst(RegExp(r'/+$'), '');
    return tidy(a) == tidy(b);
  }
}

/// The keys one sign-in is done with, the same on both ends where nobody changed anything on the way.
class HandoverKeys {
  HandoverKeys._(this._key);
  final Uint8List _key;

  /// From this end's pair and the other's public key, with the code's secret. [newKey] and [phoneKey] are the two
  /// public keys, each in its own place whichever end this is, so the key is bound to who is which. Null where
  /// [theirs] is no key.
  static HandoverKeys? make({required NetKeys mine, required List<int> theirs, required List<int> secret, required List<int> newKey, required List<int> phoneKey}) {
    final shared = NetCrypto.agree(mine, theirs);
    if (shared == null) return null;
    return HandoverKeys._(NetCrypto.hkdf(salt: secret, ikm: shared, info: [...utf8.encode('ghost signin v1'), ...newKey, ...phoneKey]));
  }

  /// Six digits, compared by eye (as a computer's pairing shows them, lib/desktop/link/crypto.dart).
  String get digits {
    final d = NetCrypto.derive(_key, 'signin digits');
    final n = (d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3];
    return (n % 1000000).toString().padLeft(6, '0');
  }

  /// What the words are sealed with.
  Uint8List get wordsKey => NetCrypto.derive(_key, 'signin words');

  /// Proof of holding the key, for [what]: 'ready' (the new device has it), 'done', 'no', 'gone'.
  Uint8List proof(String what) => NetCrypto.hmac(NetCrypto.derive(_key, 'signin proof'), utf8.encode(what));

  void forget() => _key.fillRange(0, _key.length, 0);
}

/// Where one end stands.
enum HandoverPhase {
  /// Not in the room yet.
  starting,

  /// In the room. The new device shows its code; the phone has said who it is and waits for the answer.
  waiting,

  /// Both hold the key: the digits are shown, to be compared.
  compare,

  /// The words were handed over (the new device has them; the phone heard so).
  done,

  /// The phone sent the words and has not heard that they came.
  sent,

  /// Two minutes passed.
  expired,

  /// The other end said no, or left.
  refused,

  /// Something came that should not have: a second phone, a message that was changed. Nothing is taken.
  failed,

  /// The relay could not be reached, or the two are on different relays.
  unreachable,
}

Uint8List? _bytes(Object? b64, [int? length]) {
  if (b64 is! String || b64.length > 4096) return null;
  try {
    final b = base64Decode(b64);
    return length != null && b.length != length ? null : b;
  } catch (_) {
    return null;
  }
}

/// Whether [a] and [b] are the same, in the same time whichever byte differs.
bool _same(List<int>? a, List<int> b) {
  if (a == null || a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// What both ends share: the room, sealing with its key, the clock, and ending.
abstract class _HandoverEnd {
  _HandoverEnd(this._room, DateTime Function()? now) : _now = now ?? DateTime.now;
  final HandoverRoom _room;
  final DateTime Function() _now;

  /// Told whenever [phase] changes.
  void Function()? onChange;

  HandoverPhase get phase => _phase;
  HandoverPhase _phase = HandoverPhase.starting;

  /// The six digits, once both hold the key (the phone has them as soon as it has read the code).
  String? get digits => _keys?.digits;

  /// When this end gives up.
  DateTime? get deadline => _deadline;
  DateTime? _deadline;

  HandoverCode? _code;
  HandoverKeys? _keys;
  NetKeys? _mine;
  StreamSubscription<Uint8List>? _sub;
  Timer? _clock;
  bool _closed = false;

  bool get _over => _closed || (_deadline != null && !_now().isBefore(_deadline!));

  void _set(HandoverPhase p) {
    if (_phase == p) return;
    _phase = p;
    onChange?.call();
  }

  /// Joins the code's room and listens there; false (and [HandoverPhase.unreachable]) where it could not.
  Future<bool> _enter(HandoverCode code) async {
    _code = code;
    _deadline = _now().add(Handover.lifetime);
    _sub = _room.heard.listen(_packet);
    try {
      await _room.join(code.room, code.token);
    } catch (_) {
      _end(HandoverPhase.unreachable);
      return false;
    }
    if (_closed) return false;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    return true;
  }

  /// Looks at the clock: past the deadline, this end gives up. Called every second while in the room.
  void tick() {
    if (_closed) return;
    if (_over) {
      _end(HandoverPhase.expired);
      return;
    }
    _ticked();
  }

  void _ticked() {}

  void _packet(Uint8List sealed) {
    if (_closed) return;
    if (_over) {
      _end(HandoverPhase.expired);
      return;
    }
    final code = _code;
    if (code == null) return;
    // Not sealed with the room's key: not from anyone who read the code. Let go.
    final clear = NetCrypto.open(code.roomKey, sealed);
    if (clear == null) return;
    final Object? m;
    try {
      m = jsonDecode(utf8.decode(clear));
    } catch (_) {
      return;
    }
    if (m is Map) _heard(m);
  }

  void _heard(Map<dynamic, dynamic> m);

  void _say(Map<String, Object?> m) {
    final code = _code;
    if (code == null || _closed) return;
    try {
      _room.say(NetCrypto.seal(code.roomKey, utf8.encode(jsonEncode(m))));
    } catch (_) {}
  }

  bool _proves(Map<dynamic, dynamic> m, String what) {
    final keys = _keys;
    return keys != null && _same(_bytes(m['m'], 32), keys.proof(what));
  }

  /// Out of the room for good, standing at [as]: the keys and the secret are let go, and nothing more is heard or said.
  void _end(HandoverPhase as) {
    if (_closed) return;
    _closed = true;
    _clock?.cancel();
    _clock = null;
    _sub?.cancel();
    _sub = null;
    try {
      _room.leave();
    } catch (_) {}
    _keys?.forget();
    _keys = null;
    _mine = null;
    final secret = _code?.secret;
    secret?.fillRange(0, secret.length, 0);
    _code = null;
    _set(as);
  }
}

/// The new device's end: it makes the code, shows the digits once a phone has answered, and takes the words once.
class HandoverNewDevice extends _HandoverEnd {
  HandoverNewDevice({required HandoverRoom room, required this.relay, required this.onWords, DateTime Function()? now}) : super(room, now);

  /// The relay this device is on (its hub's address), said in the code so the phone can tell where to meet.
  final String relay;

  /// Given the words, once. They are kept nowhere here.
  final void Function(List<String> words) onWords;

  /// The code's words, for the QR; null before [start] and once this end is over.
  String? get codeText => _text;
  String? _text;

  Uint8List? _phoneKey;

  /// Makes a new key pair and secret and joins their room. The code is shown from [HandoverPhase.waiting] on.
  Future<void> start() async {
    final mine = _mine = NetKeys.generate();
    final code = HandoverCode(key: mine.public, secret: NetCrypto.randomBytes(32), relay: relay);
    _text = code.text;
    if (await _enter(code)) _set(HandoverPhase.waiting);
  }

  @override
  void _heard(Map<dynamic, dynamic> m) {
    switch (m['t']) {
      case 'hello':
        final theirs = _bytes(m['k'], 33);
        if (theirs == null) return;
        final had = _phoneKey;
        if (had != null) {
          // The same phone saying so again (it had not heard the answer): answered again. Another one: two phones
          // read this code, and there is no telling here which is the person's, so neither is given anything.
          if (_same(had, theirs)) {
            _say({'t': 'ready', 'm': base64Encode(_keys!.proof('ready'))});
          } else {
            _end(HandoverPhase.failed);
          }
          return;
        }
        final keys = HandoverKeys.make(mine: _mine!, theirs: theirs, secret: _code!.secret, newKey: _mine!.public, phoneKey: theirs);
        if (keys == null) return;
        _phoneKey = theirs;
        _keys = keys;
        _say({'t': 'ready', 'm': base64Encode(keys.proof('ready'))});
        _set(HandoverPhase.compare);
      case 'words':
        final keys = _keys;
        if (keys == null) return;
        final sealed = _bytes(m['c']);
        final clear = sealed == null ? null : NetCrypto.open(keys.wordsKey, sealed);
        // Not sealed with the key the digits were made from: changed on the way, or from someone else. Nothing is
        // taken, and this code is over.
        if (clear == null) {
          _end(HandoverPhase.failed);
          return;
        }
        List<String> words;
        try {
          words = utf8.decode(clear).split(' ');
        } catch (_) {
          words = const [];
        }
        clear.fillRange(0, clear.length, 0);
        if (!AccountCrypto.validWords(words)) {
          _end(HandoverPhase.failed);
          return;
        }
        _say({'t': 'done', 'm': base64Encode(keys.proof('done'))});
        // Out of the room before the words are used: a second answer has nobody to hear it.
        _end(HandoverPhase.done);
        onWords(words);
      case 'no':
        if (_proves(m, 'no')) _end(HandoverPhase.refused);
    }
  }

  /// The screen was left: the phone is told where one answered, and the code is good for nothing from here on.
  void close() {
    if (_closed) return;
    final keys = _keys;
    if (keys != null) _say({'t': 'gone', 'm': base64Encode(keys.proof('gone'))});
    _end(_phase);
  }

  @override
  void _end(HandoverPhase as) {
    _text = null;
    _phoneKey = null;
    super._end(as);
  }
}

/// The phone's end: it reads the code, shows the digits, and, once the person has said yes and the phone's lock has
/// been passed, hands the words over once.
class HandoverPhone extends _HandoverEnd {
  HandoverPhone({required HandoverRoom room, required this.code, this.relay, DateTime Function()? now}) : super(room, now);

  /// The code read from the new device's screen.
  final HandoverCode code;

  /// The relay this phone is on, where known: a new device on another relay would not find the account there.
  final String? relay;

  /// The relay the new device is on, where it is not this phone's ([HandoverPhase.unreachable]).
  String? get otherRelay => _otherRelay;
  String? _otherRelay;

  // The new device proved it holds the key; and the words have gone.
  bool _ready = false;
  bool _handed = false;
  DateTime? _saidHello;

  /// Whether the new device has answered with proof of the key: only then can the words go ([approve]).
  bool get ready => _ready;

  /// Makes this sign-in's key pair, joins the room and says who this phone is.
  Future<void> start() async {
    final mine = _mine = NetKeys.generate();
    final relay = this.relay;
    if (relay != null && !HandoverCode.sameRelay(relay, code.relay)) {
      _otherRelay = code.relay;
      _end(HandoverPhase.unreachable);
      return;
    }
    final keys = HandoverKeys.make(mine: mine, theirs: code.key, secret: code.secret, newKey: code.key, phoneKey: mine.public);
    if (keys == null) {
      _end(HandoverPhase.failed);
      return;
    }
    _keys = keys;
    if (!await _enter(code)) return;
    _hello();
    _set(HandoverPhase.waiting);
  }

  void _hello() {
    _saidHello = _now();
    _say({'t': 'hello', 'k': base64Encode(_mine!.public)});
  }

  // Said again until answered: the new device may have been between two connections when it was first said.
  @override
  void _ticked() {
    final said = _saidHello;
    if (!_ready && _mine != null && said != null && !_now().isBefore(said.add(Handover.helloEvery))) _hello();
  }

  @override
  void _heard(Map<dynamic, dynamic> m) {
    switch (m['t']) {
      case 'ready':
        // Proof made with the key this phone made from the code's own public key: only the device that showed the
        // code can make it. Anything else is let go, and the phone goes on waiting.
        if (_ready || !_proves(m, 'ready')) return;
        _ready = true;
        _set(HandoverPhase.compare);
      case 'done':
        if (_handed && _proves(m, 'done')) _end(HandoverPhase.done);
      case 'gone':
        if (_proves(m, 'gone')) _end(HandoverPhase.refused);
    }
  }

  /// Hands [words] to the new device, sealed with the key the digits were made from. Once only, only after the new
  /// device proved it holds the key, and only before the two minutes are up; false where nothing was sent. The caller
  /// has asked the phone's lock first.
  bool approve(List<String> words) {
    final keys = _keys;
    if (_closed || _handed || !_ready || keys == null) return false;
    if (_over) {
      _end(HandoverPhase.expired);
      return false;
    }
    _handed = true;
    _say({'t': 'words', 'c': base64Encode(NetCrypto.seal(keys.wordsKey, utf8.encode(words.join(' '))))});
    _set(HandoverPhase.sent);
    return true;
  }

  /// The digits were different, or the person changed their mind: the new device is told, and nothing is sent.
  void refuse() {
    if (_closed) return;
    final keys = _keys;
    if (keys != null && !_handed) _say({'t': 'no', 'm': base64Encode(keys.proof('no'))});
    _end(_handed ? _phase : HandoverPhase.refused);
  }

  /// The screen was left. Before the words went, that is a no.
  void close() {
    if (_closed) return;
    if (_handed) {
      _end(_phase);
    } else {
      refuse();
    }
  }
}
