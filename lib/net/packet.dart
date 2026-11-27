import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';

/// One thing said from one install to another over the routes (lib/net): a text, a receipt, "typing", a call being
/// set up. It is the same envelope whichever route carries it, and its [id] is how a second copy arriving by
/// another route is known for one.
class Envelope {
  Envelope({String? id, required this.kind, this.body = const {}, int? at, this.ack = true, this.fs})
      : id = id ?? NetCrypto.hex(NetCrypto.randomBytes(8)),
        at = at ?? DateTime.now().millisecondsSinceEpoch;

  /// Sixteen hex digits, made by the sender.
  final String id;

  /// What it is: `text`, `read`, `typing`, `call`, `room`, `hello`, `ack`. A kind this build does not know is
  /// passed over, not an error: a newer build may say more.
  final String kind;
  final Map<String, dynamic> body;

  /// When it was made, by the sender's clock, in milliseconds.
  final int at;

  /// Whether the sender wants to be told it arrived. Not for chatter (typing), nor for the telling itself.
  final bool ack;

  /// The sending device's forward-secrecy key, as it offers it (lib/net/forward_secrecy.dart, GMFB-26): `f` in the
  /// bytes, which a build from before passes over. Null where it offers none.
  final Map<String, dynamic>? fs;

  /// This envelope with [bundle] as its [fs], the same in every other way.
  Envelope withFs(Map<String, dynamic>? bundle) => Envelope(id: id, kind: kind, body: body, at: at, ack: ack, fs: bundle);

  /// The envelope as bytes: JSON, with a key only for what says something (`n` where no answer is asked for).
  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode({'i': id, 'k': kind, 'a': at, if (body.isNotEmpty) 'b': body, if (!ack) 'n': 1, if (fs != null) 'f': fs})));

  static Envelope? decode(List<int> bytes) {
    try {
      final m = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final id = m['i'], kind = m['k'];
      if (id is! String || kind is! String || id.isEmpty || id.length > 64) return null;
      final f = m['f'];
      return Envelope(id: id, kind: kind, body: (m['b'] as Map?)?.cast<String, dynamic>() ?? const {}, at: (m['a'] as num?)?.toInt() ?? 0, ack: m['n'] != 1, fs: f is Map ? f.cast<String, dynamic>() : null);
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() => 'Envelope($kind $id)';
}

/// An envelope as a route carries it: a byte saying how it is wrapped, who it is from (their name, 16 bytes), and
/// the envelope, sealed or not. A packet too long for a route (a data SMS holds 133 bytes) crosses in parts.
///
///     [version and flags][from, 16 bytes][the envelope, sealed with the pair's key or as it is]
///     [version and flags | part][from, 16 bytes][which packet, 4 bytes][part number][how many][a piece of the above's last field]
///
/// The flags: 1 sealed, 2 a part, 4 sealed for forward secrecy (lib/net/forward_secrecy.dart, GMFB-26), whose last
/// field is laid out as that file says, 8 passed on by a device of the account it was for to the account's own name,
/// unopened (never passed on again). A build from before takes a forward-secret packet for an ordinary sealed one,
/// can't open it, and drops it; it is only sent to devices that said they can open it.
class Packet {
  Packet._(this.from, this.sealed, this.payload, this.group, this.index, this.count, {this.fs = false, this.passed = false});

  /// Passed on, unopened, by a device of the account it was for (flag 8).
  final bool passed;
  static const _passed = 8;

  // The first byte holds the version in its high four bits and these flags in its low. [head] is how many bytes
  // come before a whole packet's envelope, [partHead] before a part's piece.
  static const version = 1;
  static const _sealed = 1;
  static const _part = 2;
  static const _fs = 4;
  static const head = 17;
  static const partHead = head + 6;

  /// The sender's name (NetCrypto.idOf), 32 hex digits.
  final String from;
  final bool sealed;

  /// Sealed for forward secrecy, not with the pair's key alone.
  final bool fs;
  final Uint8List payload;

  /// For a part: which packet it is a piece of, which piece, and of how many. Null for a whole packet.
  final String? group;
  final int index;
  final int count;

  bool get isPart => group != null;

  /// A whole packet's bytes: one byte of version and flags, the sender's id, then [payload]. [fs] counts only with
  /// [sealed], and [passed] only with both.
  static Uint8List wrap({required String from, required bool sealed, required List<int> payload, bool fs = false, bool passed = false}) =>
      Uint8List.fromList([(version << 4) | (sealed ? _sealed : 0) | (sealed && fs ? _fs : 0) | (sealed && fs && passed ? _passed : 0), ...NetCrypto.unhex(from), ...payload]);

  /// [packet] as the pieces a route that carries at most [max] bytes at a time can take, or the packet itself where
  /// it fits. Null when it would take more than [maxParts].
  static List<Uint8List>? split(Uint8List packet, int max, {int maxParts = 255}) {
    if (packet.length <= max) return [packet];
    final room = max - partHead;
    if (room <= 0) return null;
    final body = packet.sublist(head);
    final count = (body.length / room).ceil();
    if (count > maxParts || count > 255) return null;
    final group = NetCrypto.randomBytes(4);
    return [
      for (var i = 0; i < count; i++)
        Uint8List.fromList([packet[0] | _part, ...packet.sublist(1, head), ...group, i, count, ...body.sublist(i * room, (i + 1) * room > body.length ? body.length : (i + 1) * room)]),
    ];
  }

  /// The packet [bytes] are, whole or a part; null for another version, or one cut short.
  static Packet? parse(List<int> bytes) {
    if (bytes.length < head + 1 || (bytes[0] >> 4) != version) return null;
    final from = NetCrypto.hex(bytes.sublist(1, head));
    final sealed = bytes[0] & _sealed != 0;
    final fs = sealed && bytes[0] & _fs != 0;
    final passed = fs && bytes[0] & _passed != 0;
    if (bytes[0] & _part == 0) return Packet._(from, sealed, Uint8List.fromList(bytes.sublist(head)), null, 0, 1, fs: fs, passed: passed);
    if (bytes.length < partHead + 1) return null;
    final count = bytes[head + 5], index = bytes[head + 4];
    if (count == 0 || index >= count) return null;
    return Packet._(from, sealed, Uint8List.fromList(bytes.sublist(partHead)), NetCrypto.hex(bytes.sublist(head, head + 4)), index, count, fs: fs, passed: passed);
  }
}

/// Puts a packet's parts back together as they arrive, in any order. Parts of a packet that never finishes are
/// dropped after [keepFor], and no more than [maxOpen] unfinished packets are held: a route anyone can send over
/// (SMS) must not be a way to fill the phone.
class PartJoiner {
  PartJoiner({this.keepFor = const Duration(minutes: 10), this.maxOpen = 64, DateTime Function()? now}) : _now = now ?? DateTime.now;
  final Duration keepFor;
  final int maxOpen;
  final DateTime Function() _now;
  final Map<String, _Open> _open = {};

  /// The whole packet once [part] is its last missing piece; null until then.
  Packet? add(Packet part) {
    if (!part.isPart) return part;
    final now = _now();
    _open.removeWhere((_, o) => now.difference(o.since) > keepFor);
    final key = '${part.from}:${part.group}';
    var open = _open[key];
    if (open == null) {
      if (_open.length >= maxOpen) _open.remove(_open.keys.first);
      open = _open[key] = _Open(part.count, now);
    }
    if (open.count != part.count) return null;
    open.pieces[part.index] = part.payload;
    if (open.pieces.length < open.count) return null;
    _open.remove(key);
    return Packet._(part.from, part.sealed, Uint8List.fromList([for (var i = 0; i < open.count; i++) ...open.pieces[i]!]), null, 0, 1, fs: part.fs, passed: part.passed);
  }
}

/// The pieces of one packet come so far, how many there are to be, and when the first came.
class _Open {
  _Open(this.count, this.since);
  final int count;
  final DateTime since;
  final Map<int, Uint8List> pieces = {};
}
