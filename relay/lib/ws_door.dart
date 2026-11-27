import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'sha1.dart';

/// A WebSocket's doors, with a ceiling on a message's length in front of Dart's own parser (found in the review of
/// relays that talk, 2026-11-22). Dart's WebSocket holds a whole message in memory before anything can look at its
/// length, and takes as many bytes as arrive: one frame that says it is a terabyte long is read until the process has
/// nothing left, and so are a million small pieces of one message. Compression is off at every door already
/// (no_compression_test.dart); this is the rest of it.
///
/// So the socket is taken from the upgrade here ([upgradeGuarded] for a door that is dialled, [dialGuarded] for a
/// connection this relay makes), and every byte that comes in passes a [FrameGuard] first: it reads only the frames'
/// headers, skips over what they carry, and ends the socket the moment a message would be longer than that door takes,
/// before a byte of it is held. The handshake is made here as Dart's own makes it (RFC 6455, section 4), held to the
/// RFC's own example in test/ws_door_test.dart. Nothing but Dart's own library.

/// The longest first message any door takes: a hello, which is a few hundred bytes.
const firstMost = 16 << 10;

/// RFC 6455's string, added to the key before it is hashed.
const _guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// What a server answers the key [key] with (`Sec-WebSocket-Accept`, RFC 6455, section 4.2.2).
String acceptOf(String key) => base64Encode(sha1(ascii.encode('${key.trim()}$_guid')));

/// Reads the headers of the frames that come in, and nothing of what they carry: whether each message stays within
/// what its door takes ([most]; [first] for the first message, which is a hello at every door). Told every byte in
/// order ([take]); the first one past a limit, it says no and why ([why]), and says no from then on.
class FrameGuard {
  FrameGuard({required this.most, int? first, this.framesAMessage = 1024}) : first = first ?? most;

  /// The longest a message may be, its frames' payloads together; and the first message.
  final int most;
  final int first;

  /// The most frames one message may come in. Each piece Dart holds is a small object of its own, so a message in a
  /// million one-byte pieces costs far more than its length; no app sends one in more than a few.
  final int framesAMessage;

  /// Why it said no, once it has.
  String? why;

  /// The bytes of the message not yet finished that have come in: what Dart's parser holds until its last frame comes
  /// ([WireBudget] counts them). Nothing once it is finished, and nothing for a control frame, which is read at once.
  int holding = 0;

  /// Where in a frame the next byte is: its first byte, its length byte, the longer length's bytes, its mask, what it
  /// carries. Then what the frame's header said (last piece, control frame, masked, its length, what of it is left to
  /// read), and the message it belongs to: how many messages have begun, this one's length so far, and its pieces.
  static const _head = 0, _length = 1, _moreLength = 2, _mask = 3, _payload = 4;
  int _at = _head;
  bool _fin = false, _control = false, _masked = false;
  int _lengthBytes = 0, _len = 0, _left = 0;
  bool _inMessage = false;
  int _messages = 0, _message = 0, _frames = 0;

  /// The longest the message being read may be: [first] for the first, [most] after.
  int get _ceiling => _messages <= 1 ? first : most;

  /// A ping or pong with something in it that came between the pieces of a message is held back until that message's
  /// last piece has gone ([pass]): Dart's own parser keeps the pieces of a message where it reads a control frame's
  /// payload, so one coming between them took the message's first pieces with it, into the answer to the ping (found in
  /// the second review, 2026-11-23: a browser, which may split a long message, answering a ping meanwhile). An empty one
  /// does the parser no harm and goes through at once (the relay's own pings are empty, and their answers must not wait
  /// for a long message to end, or Dart's ping timeout would end the connection); so does a Close, which is answered.
  /// Each held is at most 125 bytes; more than [laterMost] inside one message ends the connection.
  static const laterMost = 32;
  final BytesBuilder _later = BytesBuilder(), _cur = BytesBuilder();
  int _laterFrames = 0;
  bool _diverting = false, _ended = false;

  /// Reads [bytes], the next that came in; false where the connection must end.
  bool take(List<int> bytes) => _run(bytes, null);

  /// Reads [bytes], the next that came in, and gives back what to hand on to the parser: the same bytes, with a ping or
  /// pong that has something in it, come between the pieces of a message, moved to just after its last piece. Null
  /// where the connection must end.
  Uint8List? pass(List<int> bytes) {
    final out = BytesBuilder(copy: false);
    return _run(bytes, out) ? out.takeBytes() : null;
  }

  /// Reads [bytes] a step at a time ([_step]). With [out], also copies them to it in order, but for a ping or pong
  /// inside a message that has something in it: that goes to [_later], and to [out] after the message's last piece.
  bool _run(List<int> bytes, BytesBuilder? out) {
    if (why != null) return false;
    var i = 0, run = 0;
    final n = bytes.length;
    // Copies what has been read since the last copy, up to [end], to where it goes now: the frame held aside, or out.
    void flush(int end) {
      if (out != null && end > run) (_diverting ? _cur : out).add(bytes.sublist(run, end));
      run = end;
    }

    while (i < n) {
      if (out != null && _at == _head && _inMessage) {
        final op = bytes[i] & 0x0f;
        // A ping or pong inside a message: held aside until its length says whether it has anything in it.
        if (op == 9 || op == 10) {
          flush(i);
          _diverting = true;
        }
      }
      final lengthRead = _at == _length;
      i = _step(bytes, i);
      if (i < 0) return false;
      if (out != null && _diverting) {
        if (lengthRead) {
          if (_len == 0) {
            // Empty: through at once.
            flush(i);
            out.add(_cur.takeBytes());
            _diverting = false;
          } else if (++_laterFrames > laterMost) {
            return _no('too many control frames inside one message');
          }
        }
        if (_diverting && _at == _head) {
          // The held one is whole: it waits for the message's last piece.
          flush(i);
          _later.add(_cur.takeBytes());
          _diverting = false;
        }
      }
      // A message's last piece has just gone: the pings and pongs held back for it follow.
      if (_ended) {
        _ended = false;
        if (out != null) {
          flush(i);
          out.add(_later.takeBytes());
          _laterFrames = 0;
        }
      }
    }
    flush(n);
    return true;
  }

  /// Reads what the state it is in reads, from [bytes] at [i]: where it got to, or -1 where the connection must end.
  int _step(List<int> bytes, int i) {
    final n = bytes.length;
    switch (_at) {
      case _head:
        final b = bytes[i++];
        // No extension is agreed at any door, so the three bits kept for them are always nothing.
        if (b & 0x70 != 0) return _fail('a frame with bits no extension agreed');
        _fin = b & 0x80 != 0;
        final op = b & 0x0f;
        _control = op >= 8;
        if (_control) {
          if (op > 10) return _fail('a frame of no kind a WebSocket has');
          if (!_fin) return _fail('a control frame in pieces');
        } else if (op == 0) {
          if (!_inMessage) return _fail('a piece of no message');
          if (++_frames > framesAMessage) return _fail('a message in too many pieces');
        } else if (op == 1 || op == 2) {
          if (_inMessage) return _fail('a message begun inside another');
          _inMessage = true;
          _messages++;
          _message = 0;
          _frames = 1;
        } else {
          return _fail('a frame of no kind a WebSocket has');
        }
        _at = _length;
      case _length:
        final b = bytes[i++];
        _masked = b & 0x80 != 0;
        final len = b & 0x7f;
        if (len < 126) {
          _len = len;
          if (!_lengthDone()) return -1;
        } else {
          if (_control) return _fail('a control frame too long');
          _len = 0;
          _lengthBytes = len == 126 ? 2 : 8;
          _at = _moreLength;
        }
      case _moreLength:
        _len = (_len << 8) | bytes[i++];
        // What is read of the length so far is already the least it can be: past the ceiling, the rest of a length
        // that may be a terabyte's is not waited for. (And so it never grows past a few bits more than the ceiling.)
        if (_message + _len > _ceiling) return _fail('a message longer than this door takes');
        if (--_lengthBytes == 0 && !_lengthDone()) return -1;
      case _mask:
        // The four bytes of the mask are skipped: nothing here reads what a frame carries.
        final step = min(_left, n - i);
        i += step;
        _left -= step;
        if (_left == 0) _startPayload();
      default:
        final step = min(_left, n - i);
        i += step;
        _left -= step;
        if (!_control) holding += step;
        if (_left == 0) _frameDone();
    }
    return i;
  }

  /// Says no for [reason], as [_step] gives it back: -1.
  int _fail(String reason) {
    _no(reason);
    return -1;
  }

  /// The frame's length is read: a control frame is held to 125 bytes, anything else is added to its message and the
  /// message held to its ceiling; then the mask is next, or what the frame carries. False where the connection must end.
  bool _lengthDone() {
    if (_control) {
      if (_len > 125) return _no('a control frame too long');
    } else {
      _message += _len;
      if (_message > _ceiling) return _no('a message longer than this door takes');
    }
    if (_masked) {
      _left = 4;
      _at = _mask;
    } else {
      _startPayload();
    }
    return true;
  }

  /// What the frame carries is next, to be skipped over; a frame that carries nothing is done already.
  void _startPayload() {
    _left = _len;
    _at = _payload;
    if (_left == 0) _frameDone();
  }

  /// A frame has been read to its end; where it was a message's last piece, the message is over and nothing of it held.
  void _frameDone() {
    if (!_control && _fin) {
      _inMessage = false;
      holding = 0;
      _ended = true;
    }
    _at = _head;
  }

  /// Remembers why ([why]), and is false: every read after it is refused too.
  bool _no(String reason) {
    why = reason;
    return false;
  }
}

/// What every connection through these doors may hold in memory at once, together: the part of a message that has
/// come in and isn't finished (which Dart's parser holds whole, up to the door's ceiling), and what waits to go out (the
/// answers to a peer's pings included: Dart answers each ping by itself, and holds the answer for as long as it isn't
/// read). One door's ceiling bounds one connection, but twenty thousand connections at a megabyte each would be twenty
/// gigabytes, where the relay has 300 MB in all.
///
/// A connection is ended for what it holds only as these say, never for a burst it is being given:
/// - **Past its share**: more than [eachOut] waiting to go out to it, for [stallFor] on end, whether it reads some of it
///   or not (the hub hands over what it keeps a piece at a time, so a device that reads holds a few hundred KB at most).
/// - **A message coming in stalled**: not grown by [inStep] (or finished) for [inStallFor], however little it is.
/// - **Everyone together past [most]**: those stalled longest go first (stalled: what waits for it has not gone down by
///   [outStep], or what comes in not grown by [inStep], for [minStall] or more), then those that have held more than
///   [bigShare] for [minStall] or more, the most first, until the rest fit. A device being handed what is kept, a piece
///   at a time, is neither, and neither is one reading a burst it is sent as fast as it comes.
/// - A connection whose own answers wait past [readPauseAbove] is not read from until they go down: a peer flooding pings
///   or anything else answered limits itself.
///
/// An ending is counted at once, and the socket is destroyed a moment after (a microtask, [GuardedSocket]): never inside
/// whatever was writing to many connections when the budget filled (found in the third review, 2026-11-23: a room's
/// broadcast had its list of members changed under it). Its numbers are the relay's settings
/// ([WireBudget.fromEnvironment]).
class WireBudget {
  WireBudget({this.most = 64 << 20, this.eachOut = 8 << 20, this.stallFor = const Duration(seconds: 10), this.inStallFor = const Duration(seconds: 20), this.minStall = const Duration(seconds: 2), DateTime Function()? now}) : _now = now ?? DateTime.now;

  /// The budget every door uses unless given another: the whole process's (bin/relay.dart makes it from the settings
  /// before anything is opened).
  static WireBudget shared = WireBudget();

  /// The settings it is made from: all connections together and one connection's waiting, in megabytes; how long being
  /// past its share, and a message coming in stalled, are borne, in seconds.
  static const names = ['GHOST_WIRE_MB', 'GHOST_WIRE_EACH_MB', 'GHOST_WIRE_STALL_S', 'GHOST_WIRE_IN_STALL_S'];

  /// From the relay's settings ([names]); a setting that isn't a whole number in its range keeps the default, and is
  /// said in [problems].
  factory WireBudget.fromEnvironment(Map<String, String> env, {List<String>? problems}) {
    int? read(String name, int least, int most) {
      final said = env[name]?.trim();
      if (said == null || said.isEmpty) return null;
      final n = int.tryParse(said);
      if (n == null || n < least || n > most) {
        problems?.add('$name=$said is not a whole number from $least to $most; the default is used');
        return null;
      }
      return n;
    }

    final all = read('GHOST_WIRE_MB', 8, 4096), each = read('GHOST_WIRE_EACH_MB', 1, 1024);
    final stall = read('GHOST_WIRE_STALL_S', 2, 600), inStall = read('GHOST_WIRE_IN_STALL_S', 2, 600);
    return WireBudget(
      most: (all ?? 64) << 20,
      eachOut: (each ?? 8) << 20,
      stallFor: Duration(seconds: stall ?? 10),
      inStallFor: Duration(seconds: inStall ?? 20),
    );
  }

  /// All connections together, in bytes: 64 MB of the relay's 300, beside the 96 MB the hub keeps for people who are
  /// away. And what may wait to go out to one connection: 8 MB.
  final int most;
  final int eachOut;

  /// How long a connection may be past [eachOut]; how long a message coming in may stall; and the least stall for which,
  /// when everyone together is past [most], a connection is ended for it.
  final Duration stallFor, inStallFor, minStall;

  /// How much must move for a connection not to be stalled: what waits going down by this much, or to nothing; the
  /// message coming in growing by this much, or finished.
  static const outStep = 64 << 10, inStep = 16 << 10;

  /// What waits to go out to a connection before the hub's hand-overs wait for it to go down ([WireHold.whenRoom]).
  static const paceBelow = 256 << 10;

  /// What waits to go out to a connection, its own answers, before nothing more is read from it; and below what it is
  /// read from again.
  static const readPauseAbove = 1 << 20, readAgainBelow = 256 << 10;

  /// More than this held by one connection makes it one that may be ended when everyone together is past [most]: a 32nd
  /// of [most], and never less than a megabyte, past anything a hand-over a piece at a time holds (a few hundred KB).
  int get bigShare => max(most ~/ 32, 1 << 20);

  /// The clock (a test's own), the bytes held by everyone together, the connections that hold anything, the hand-overs
  /// waiting for room in the order they began to wait, the once-a-second [sweep] while anything is held, and whether a
  /// round of letting hand-overs go on is due already ([_roomMade]).
  final DateTime Function() _now;
  int _used = 0;
  final Set<WireHold> _holding = {};
  final LinkedHashSet<WireHold> _waitingForRoom = LinkedHashSet();
  Timer? _sweeper;
  bool _resuming = false;

  /// What is held now, all connections together; and how many connections hold anything.
  int get used => _used;
  int get holders => _holding.length;

  /// How many hand-overs wait for the budget to have room (one waiting for its own connection to take what it was given
  /// is not among them: it goes on as that goes down, without anything else being looked at).
  int get waitingForRoom => _waitingForRoom.length;

  /// How many connections were ended for it, for a test and the log.
  int ended = 0;

  /// A connection's share, ended by [end] where it must go.
  WireHold open(void Function() end) => WireHold._(this, end);

  /// [h] holds something other than the [before] bytes it held: the total follows, when it went past [bigShare] is
  /// noted, the sweeper runs while anything is held, and where it holds less, those waiting for room are looked at.
  void _changed(WireHold h, int before) {
    final now = h.held;
    _used += now - before;
    if (now > bigShare) {
      h._bigAt ??= _now();
    } else {
      h._bigAt = null;
    }
    if (now > 0) {
      _holding.add(h);
      _sweeper ??= Timer.periodic(const Duration(seconds: 1), (_) => sweep());
    } else {
      _holding.remove(h);
    }
    if (now < before) _roomMade();
  }

  /// Applies the rules (normally once a second while anything is held; a test calls it with its own clock).
  void sweep() {
    final now = _now();
    for (final h in _holding.toList()) {
      final over = h._overAt;
      if (over != null && now.difference(over) >= stallFor) {
        _end(h);
      } else if (h._in > 0 && now.difference(h._inMoved) >= inStallFor) {
        _end(h);
      }
    }
    _fit(now);
    if (_holding.isEmpty) {
      _sweeper?.cancel();
      _sweeper = null;
    }
  }

  /// Where everyone together is past [most]: those stalled longest are ended, then those holding the most past
  /// [bigShare], until the rest fit. Whether [h] is still open after.
  bool _fit(DateTime now, [WireHold? h]) {
    if (_used <= most) return true;
    final may = [
      for (final x in _holding)
        if (x.stalledFor(now) >= minStall || (x._bigAt != null && now.difference(x._bigAt!) >= minStall)) x,
    ]..sort((a, b) {
        final byStall = b.stalledFor(now).compareTo(a.stalledFor(now));
        return byStall != 0 ? byStall : b.held.compareTo(a.held);
      });
    for (final x in may) {
      if (_used <= most) break;
      _end(x);
    }
    return h == null || !h._gone;
  }

  /// [h]'s connection is over, ended or closed: nothing of it is counted any more, and its hand-over never goes on.
  void _drop(WireHold h) {
    if (h._gone) return;
    final before = h.held;
    h._gone = true;
    h._in = h._out = h._behind = 0;
    h._overAt = h._bigAt = null;
    _waitingForRoom.remove(h);
    h._then = null;
    h._waitingOwn = false;
    _changed(h, before);
  }

  /// Counted at once, and its connection told ([GuardedSocket] destroys its socket a moment after, never inside
  /// whatever is writing to many connections).
  void _end(WireHold h) {
    if (h._gone) return;
    _drop(h);
    ended++;
    h._end();
  }

  /// Something was let go: hand-overs waiting for the budget to have room go on, the longest waiting first, while it has.
  void _roomMade() {
    if (_waitingForRoom.isEmpty || _resuming || _used >= most) return;
    _resuming = true;
    scheduleMicrotask(() {
      _resuming = false;
      while (_waitingForRoom.isNotEmpty && _used < most) {
        final h = _waitingForRoom.first;
        _waitingForRoom.remove(h);
        if (h._gone) continue;
        if (h._out >= paceBelow) {
          // Its own connection has yet to take what it was given: it goes on as that goes down.
          h._waitingOwn = true;
          continue;
        }
        final then = h._then;
        h._then = null;
        then?.call();
      }
    });
  }
}

/// One connection's share of a [WireBudget].
class WireHold {
  WireHold._(this.budget, this._end) : _inMoved = budget._now(), _outMoved = budget._now();
  final WireBudget budget;

  /// Ends its connection. Then what it holds, in bytes: of a message coming in, in the socket's queue, and behind a
  /// hand-over. The marks a stall is measured from (the incoming length when it last moved, what has gone out since
  /// the queue last moved, and when each last moved); since when it has been past [WireBudget.eachOut] and past
  /// [WireBudget.bigShare]; whether it is over; and the hand-over waiting to go on ([whenRoom]), with whether it waits
  /// on this connection's own queue.
  final void Function() _end;
  int _in = 0, _out = 0, _behind = 0;
  int _inMark = 0, _outGone = 0;
  DateTime _inMoved, _outMoved;
  DateTime? _overAt, _bigAt;
  bool _gone = false, _waitingOwn = false;
  void Function()? _then;

  /// What it holds now, in bytes; and what of it waits to go out (in the socket's queue, and the hub's own frames queued
  /// behind a hand-over).
  int get held => _in + _out + _behind;
  int get waiting => _out + _behind;

  /// What waits in the socket's own queue.
  int get queuedHere => _out;

  /// Whether it has been ended, or closed.
  bool get gone => _gone;

  /// How long it has held something without moving it: the longer of what comes in and what goes out, of those it
  /// holds anything of.
  Duration stalledFor(DateTime now) {
    var d = Duration.zero;
    if (_out + _behind > 0 && now.difference(_outMoved) > d) d = now.difference(_outMoved);
    if (_in > 0 && now.difference(_inMoved) > d) d = now.difference(_inMoved);
    return d;
  }

  /// Notes when what waits to go out went past [WireBudget.eachOut], and forgets it once it is back under.
  void _over() {
    if (_out + _behind > budget.eachOut) {
      _overAt ??= budget._now();
    } else {
      _overAt = null;
    }
  }

  /// The part of a message that has come in and isn't finished is now [n] bytes: false where the connection is ended.
  bool incoming(int n) {
    if (_gone) return false;
    final before = held, grew = n > _in;
    if (n == 0 || _in == 0 || n - _inMark >= WireBudget.inStep || n < _inMark) {
      _inMoved = budget._now();
      _inMark = n;
    }
    _in = n;
    budget._changed(this, before);
    return !grew || budget._fit(budget._now(), this);
  }

  /// [n] more bytes wait in the socket's queue: false where the connection is ended.
  bool queued(int n) {
    if (_gone) return false;
    final before = held;
    if (_out + _behind == 0) {
      _outMoved = budget._now();
      _outGone = 0;
    }
    _out += n;
    _over();
    budget._changed(this, before);
    return budget._fit(budget._now(), this);
  }

  /// [n] bytes have gone from the socket's queue to the socket.
  void sent(int n) {
    if (_gone) return;
    final before = held;
    _out = max(0, _out - n);
    _moved(n);
    _over();
    budget._changed(this, before);
    if (_waitingOwn && _out < WireBudget.paceBelow) {
      _waitingOwn = false;
      if (budget._used < budget.most) {
        final then = _then;
        _then = null;
        if (then != null) scheduleMicrotask(then);
      } else {
        budget._waitingForRoom.add(this);
      }
    }
  }

  /// [n] bytes went out: it is not stalled once [WireBudget.outStep] have gone since it last moved, or nothing waits.
  void _moved(int n) {
    _outGone += n;
    if (_out + _behind == 0 || _outGone >= WireBudget.outStep) {
      _outMoved = budget._now();
      _outGone = 0;
    }
  }

  /// The hub's own frames queued behind a hand-over for this connection: [n] more (counted, but not in the socket's
  /// queue, so hand-overs are paced by what the socket holds alone). False where the connection is ended.
  bool behind(int n) {
    if (_gone) return false;
    final before = held;
    if (_out + _behind == 0) {
      _outMoved = budget._now();
      _outGone = 0;
    }
    _behind += n;
    _over();
    budget._changed(this, before);
    return budget._fit(budget._now(), this);
  }

  /// [n] bytes queued behind a hand-over have gone on to the socket's queue (where they are counted again).
  void unqueued(int n) {
    if (_gone) return;
    final before = held;
    _behind = max(0, _behind - n);
    _over();
    budget._changed(this, before);
  }

  bool get _hasRoom => !_gone && _out < WireBudget.paceBelow && budget._used < budget.most;

  /// Whether the hub may hand this connection more of what it keeps now ([whenRoom] otherwise).
  bool get hasRoom => _hasRoom;

  /// Calls [then] once there is room ([hasRoom]): when what waits for this connection has gone down, and the budget has
  /// room. One at a time; never once the connection is gone.
  void whenRoom(void Function() then) {
    if (_gone) return;
    _then = then;
    if (_out >= WireBudget.paceBelow) {
      _waitingOwn = true;
    } else if (budget._used >= budget.most) {
      budget._waitingForRoom.add(this);
    } else {
      _then = null;
      scheduleMicrotask(then);
    }
  }

  /// The connection is over: nothing of it is held.
  void close() => budget._drop(this);
}

/// The share of the budget each WebSocket made at these doors holds ([upgradeGuarded], [dialGuarded]): the hub hands a
/// connection what it keeps only as fast as that connection takes it.
final Expando<WireHold> wireHoldOf = Expando('wireHoldOf');

/// A socket whose every incoming byte passes a [FrameGuard] before anything else reads it; one past the guard's limit
/// destroys the socket, and what reads it is told it is done. What it holds counts against [budget] ([WireBudget]):
/// the part of a message that has come in, and everything written to it until the socket has taken it (nothing is
/// left waiting where it can't be counted). Everything else is the socket's own.
class GuardedSocket extends Stream<Uint8List> implements Socket {
  GuardedSocket(this._socket, this.guard, {Stream<Uint8List>? incoming, WireBudget? budget}) : _incoming = incoming ?? _socket {
    // Destroyed a moment after the budget ends it: never in the middle of the hub's loop over a room's members, which
    // the destroying would change under it (found in the third review, 2026-11-23).
    _hold = (budget ?? WireBudget.shared).open(() => scheduleMicrotask(_socket.destroy));
    _socket.done.then((_) => _hold.close(), onError: (_) => _hold.close());
  }

  final Socket _socket;
  final FrameGuard guard;
  final Stream<Uint8List> _incoming;
  late final WireHold _hold;

  /// Its share of the budget.
  WireHold get hold => _hold;

  /// The subscription to what comes in, and whether it is paused for the answers waiting to go out.
  StreamSubscription<Uint8List>? _reading;
  bool _readingHeld = false;

  /// What comes in, as the WebSocket's parser listens to it: each read goes through the guard and is counted against
  /// the budget first, and the first one refused by either destroys the socket and ends the stream.
  @override
  StreamSubscription<Uint8List> listen(void Function(Uint8List event)? onData, {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    var ended = false;
    late final StreamController<Uint8List> passed;
    passed = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        _reading = _incoming.listen(
          (data) {
            if (ended) return;
            final out = guard.pass(data);
            if (out != null && _hold.incoming(guard.holding)) {
              if (out.isNotEmpty) passed.add(out);
              return;
            }
            ended = true;
            _socket.destroy();
            passed.close();
          },
          onError: (Object e, StackTrace s) {
            if (!passed.isClosed) passed.addError(e, s);
          },
          onDone: () {
            // Nothing more comes in; what waits to go out is still counted until the socket is done.
            _hold.incoming(0);
            if (!passed.isClosed) passed.close();
          },
        );
      },
      onPause: () => _reading?.pause(),
      onResume: () => _reading?.resume(),
      onCancel: () => _reading?.cancel(),
    );
    return passed.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  /// Nothing more is read from it while its own answers wait past [WireBudget.readPauseAbove], and it is read from again
  /// below [WireBudget.readAgainBelow]: a peer flooding pings, or anything else that is answered, limits itself.
  void _readOrNot() {
    final waiting = _hold.queuedHere;
    if (!_readingHeld && waiting > WireBudget.readPauseAbove) {
      _readingHeld = true;
      _reading?.pause();
    } else if (_readingHeld && waiting < WireBudget.readAgainBelow) {
      _readingHeld = false;
      _reading?.resume();
    }
  }

  /// What the WebSocket writes (Dart's WebSocket gives its socket one stream of frames, pongs among them). It is read
  /// at once, never paused, so nothing waits where it isn't counted: what the socket hasn't taken yet waits here, each
  /// chunk counted until the socket takes it, and past the budget the connection is ended and what waited dropped.
  @override
  Future addStream(Stream<List<int>> stream) {
    final waiting = StreamController<List<int>>();
    late final StreamSubscription<List<int>> from;
    from = stream.listen(
      (chunk) {
        if (waiting.isClosed) return;
        if (_hold.queued(chunk.length)) {
          waiting.add(chunk);
          _readOrNot();
          return;
        }
        from.cancel();
        waiting.close();
      },
      onError: (Object e, StackTrace s) {
        if (!waiting.isClosed) waiting.addError(e, s);
      },
      onDone: () {
        if (!waiting.isClosed) waiting.close();
      },
    );
    return _socket.addStream(waiting.stream.map((chunk) {
      _hold.sent(chunk.length);
      _readOrNot();
      return chunk;
    }));
  }

  // Everything from here is the socket's own, handed straight through; destroying it lets go of its share first.
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);
  @override
  Future close() => _socket.close();
  @override
  Future get done => _socket.done;
  @override
  Future flush() => _socket.flush();
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) => _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  void destroy() {
    _hold.close();
    _socket.destroy();
  }
  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
}

/// Upgrades [request] to a WebSocket as Dart's own upgrade does (WebSocketTransformer.upgrade: the same answer,
/// without compression), with a [FrameGuard] holding each message to [most] bytes, the first to [first], before Dart's
/// parser reads it. Null where it is not a WebSocket's request (answered 400) or the socket could not be had.
Future<WebSocket?> upgradeGuarded(HttpRequest request, {required int most, int first = firstMost, WireBudget? budget}) async {
  // A key of printable ASCII, said once: a byte past ASCII made the answer throw before it was sent, and the connection
  // hung with nothing said (found in the second review, 2026-11-23); it is refused, as anything not a WebSocket's
  // request is.
  String? key;
  try {
    key = request.headers.value('sec-websocket-key')?.trim();
  } catch (_) {
    key = null;
  }
  final keyOk = key != null && key.isNotEmpty && key.length <= 64 && key.codeUnits.every((c) => c > 32 && c < 127);
  if (!WebSocketTransformer.isUpgradeRequest(request) || !keyOk) {
    try {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
    } catch (_) {}
    return null;
  }
  final Socket socket;
  try {
    request.response
      ..statusCode = HttpStatus.switchingProtocols
      ..headers.add(HttpHeaders.connectionHeader, 'Upgrade')
      ..headers.add(HttpHeaders.upgradeHeader, 'websocket')
      ..headers.add('Sec-WebSocket-Accept', acceptOf(key))
      ..headers.contentLength = 0;
    socket = await request.response.detachSocket();
  } catch (_) {
    return null;
  }
  final guarded = GuardedSocket(socket, FrameGuard(most: most, first: first), budget: budget);
  final ws = WebSocket.fromUpgradedSocket(guarded, serverSide: true, compression: CompressionOptions.compressionOff);
  wireHoldOf[ws] = guarded.hold;
  return ws;
}

/// Why a WebSocket this relay dialled was not made ([dialGuarded]).
class WsRefused implements Exception {
  const WsRefused(this.why);
  /// In words, for the keeper's log: what the answer to the handshake was, or what was wrong with it.
  final String why;
  @override
  String toString() => why;
}

/// The longest answer to a handshake read before it is given up on.
const _mostHead = 8192;

/// Makes a WebSocket to [url] over [socket], a connection made already (and secured, for `wss`): the handshake is
/// made here (RFC 6455, section 4.1), asking for no extension and no protocol, and taken only where the answer is
/// `101` with the accept the key asks for and neither of them; nothing else is followed anywhere (a redirect is a
/// refusal). Then each message is held to [most] bytes, the first to [first], before Dart's parser reads it.
Future<WebSocket> dialGuarded(Socket socket, Uri url, {required int most, int first = firstMost, Random? random, WireBudget? budget}) async {
  final r = random ?? Random.secure();
  final key = base64Encode([for (var i = 0; i < 16; i++) r.nextInt(256)]);
  final usual = url.scheme == 'wss' ? 443 : 80;
  final port = url.hasPort ? url.port : usual;
  final host = url.host.contains(':') ? '[${url.host}]' : url.host;
  final path = '${url.path.isEmpty ? '/' : url.path}${url.hasQuery ? '?${url.query}' : ''}';
  final ask = 'GET $path HTTP/1.1\r\nHost: $host${port == usual ? '' : ':$port'}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\n\r\n';

  // One listener on the socket for the whole of it: the answer's head is read here, and what follows it (the first of
  // the frames, it may be, in the same read) and everything after goes to the WebSocket.
  final rest = StreamController<Uint8List>(sync: true);
  final head = BytesBuilder(copy: true);
  final answered = Completer<Uint8List>();
  var upgraded = false;
  late final StreamSubscription<Uint8List> sub;
  sub = socket.listen((data) {
    if (upgraded) return rest.add(data);
    head.add(data);
    final bytes = head.toBytes();
    final end = _endOfHead(bytes);
    if (end < 0) {
      if (bytes.length > _mostHead && !answered.isCompleted) answered.completeError(const WsRefused('an answer too long to be a handshake\'s'));
      return;
    }
    upgraded = true;
    sub.pause();
    if (!answered.isCompleted) answered.complete(bytes);
  }, onError: (Object e, StackTrace s) {
    if (!answered.isCompleted) return answered.completeError(e, s);
    rest.addError(e, s);
  }, onDone: () {
    if (!answered.isCompleted) return answered.completeError(const WsRefused('closed before it answered'));
    rest.close();
  }, cancelOnError: false);
  rest
    ..onPause = sub.pause
    ..onResume = sub.resume
    ..onCancel = sub.cancel;

  try {
    socket.add(ascii.encode(ask));
    final bytes = await answered.future;
    final end = _endOfHead(bytes);
    final lines = latin1.decode(bytes.sublist(0, end)).split('\r\n');
    final status = RegExp(r'^HTTP/1\.1 (\d{3})(?: |$)').firstMatch(lines.first);
    if (status == null || status.group(1) != '101') throw WsRefused('answered ${status?.group(1) ?? 'with no status'}, not 101');
    final said = <String, List<String>>{};
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0) throw const WsRefused('a header that is not one');
      (said[line.substring(0, colon).trim().toLowerCase()] ??= []).add(line.substring(colon + 1).trim());
    }
    String? one(String name) => said[name]?.join(', ');
    if (one('upgrade')?.toLowerCase() != 'websocket') throw const WsRefused('not upgraded to a WebSocket');
    if (!(one('connection') ?? '').toLowerCase().split(',').map((t) => t.trim()).contains('upgrade')) throw const WsRefused('not upgraded to a WebSocket');
    if (one('sec-websocket-accept') != acceptOf(key)) throw const WsRefused('an accept that is not the key\'s');
    if ((one('sec-websocket-extensions') ?? '').isNotEmpty) throw const WsRefused('an extension nobody asked for');
    if ((one('sec-websocket-protocol') ?? '').isNotEmpty) throw const WsRefused('a protocol nobody asked for');
    // What came after the head goes first, through the guard like everything else.
    if (bytes.length > end + 4) rest.add(Uint8List.sublistView(bytes, end + 4));
    sub.resume();
    final guarded = GuardedSocket(socket, FrameGuard(most: most, first: first), incoming: rest.stream, budget: budget);
    final ws = WebSocket.fromUpgradedSocket(guarded, serverSide: false, compression: CompressionOptions.compressionOff);
    wireHoldOf[ws] = guarded.hold;
    return ws;
  } catch (_) {
    await sub.cancel();
    socket.destroy();
    rethrow;
  }
}

/// Where the head of an HTTP message ends (the index of its blank line's `\r\n\r\n`), or -1 where it hasn't yet.
int _endOfHead(List<int> b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return i;
  }
  return -1;
}
