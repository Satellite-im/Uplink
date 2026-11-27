import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Directory;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;

import '../../platform_info.dart';
import 'node.dart';

/// The direct network's core (native/p2p: Rust on iroh, built by tool/build-p2p.sh), through its C interface: seven
/// functions, commands in as bytes and events out as messages to this isolate's port. native/p2p/README.md lays out
/// every one of them; this file is the other end of that page and nothing here is laid out twice.
///
/// How the two ends hold together:
/// - **events come as messages, never as calls**: the library posts each node's events to a port of this isolate
///   (through the Dart VM's own `Dart_PostCObject`), so it never calls into Dart. When the isolate ends its port
///   closes, the next post fails without harm, and the library lets go of every node made for that port. A native
///   finalizer on each node lets it go as the isolate ends besides, so a node that would never have said anything
///   more (one with no link) does not stay up either: a hot restart, a test that forgets [IrohNode.dispose], an
///   isolate that exits, a second engine;
/// - **nothing of the library runs before the first start**: making a node opens the library and looks up its
///   functions, no more. The library's own node, its threads, and on Android the app's context (handed over by
///   Kotlin, P2pCore.kt, through the platform channel) all come with the first [IrohNode.start];
/// - the app is shown what it asked for at once: a node it stopped is off, with every stream ended, when [stop]
///   returns, while the library closes its links in its own time; a start it has since called off never shows as
///   up; a node it disallowed has no stream left with it when [disallow] returns, and nothing it does not allow is
///   handed up, whatever was already on its way;
/// - **taking**: the library counts every frame it has read until it is told the frame was handed on (TAKEN), and
///   reads no more for a stream whose frames are not being taken. So a frame is said to be taken as it reaches
///   whoever listens to [P2pStream.frames], and not while they are paused or nobody listens yet: a slow listener
///   slows the other device down instead of filling this one up. What was taken of one batch of events is said once;
/// - a stream nobody is there to take ([opened] has no listener) is closed at once.

/// The library, opened once for this isolate.
class _Core {
  _Core._(DynamicLibrary lib)
    : abi = lib.lookupFunction<Uint32 Function(), int Function()>('ghost_p2p_abi', isLeaf: true),
      ready = lib.lookupFunction<Int32 Function(), int Function()>('ghost_p2p_ready', isLeaf: true),
      nodeId = lib.lookupFunction<Int32 Function(Pointer<Uint8>, Pointer<Uint8>), int Function(Pointer<Uint8>, Pointer<Uint8>)>('ghost_p2p_node_id', isLeaf: true),
      make = lib.lookupFunction<Uint64 Function(Int64, Pointer<Void>, Int64), int Function(int, Pointer<Void>, int)>('ghost_p2p_new'),
      command = lib.lookupFunction<Int32 Function(Uint64, Pointer<Uint8>, Size), int Function(int, Pointer<Uint8>, int)>('ghost_p2p_command', isLeaf: true),
      drop = lib.lookupFunction<Void Function(Uint64), void Function(int)>('ghost_p2p_drop'),
      finalizer = NativeFinalizer(lib.lookup<NativeFinalizerFunction>('ghost_p2p_finalize'));

  /// The library's functions (native/p2p/README.md): its interface's number; whether Android's part is in place (1);
  /// a node key's node id; a node made for a port; a command given to a node (0 where taken); a node let go.
  final int Function() abi;
  final int Function() ready;
  final int Function(Pointer<Uint8> secret, Pointer<Uint8> out) nodeId;
  final int Function(int port, Pointer<Void> post, int dartApiMajor) make;
  final int Function(int node, Pointer<Uint8> command, int len) command;
  final void Function(int node) drop;

  /// Lets a node go as the isolate ends, should it not have been let go before.
  final NativeFinalizer finalizer;

  /// Whether this is the library this file was written against; asked once, at the first thing the library is asked
  /// to do (making a node opens it and runs nothing of it). Null where it is; else why not, in words to show.
  late final String? problem = abi() == IrohNode.abi ? null : 'The direct network\'s core in this build is not the version the app was made for.';

  /// Where every node of this isolate is told what happens to it: the library posts to it, and it runs each batch in
  /// its turn like anything else here. It keeps nothing alive: an isolate that is done is done, and as it ends the
  /// port closes, which the library takes as every node of it gone.
  static final RawReceivePort port = RawReceivePort(IrohNode._heard, 'ghost_p2p')..keepIsolateAlive = false;

  /// The library as [open] found it, and whether it has looked: it looks once, found or not.
  static _Core? _opened;
  static bool _tried = false;

  /// The library, or null where this build has none. Only its functions are looked up: nothing of it runs.
  static _Core? open() {
    if (_tried) return _opened;
    _tried = true;
    for (final lib in _found()) {
      try {
        return _opened = _Core._(lib);
      } catch (_) {
        // Something by that name that is not this library (it lacks one of the functions).
      }
    }
    return null;
  }

  /// Each thing that opens at one of the places the library may be ([IrohNode.libraryPlaces]), in their order; on an
  /// iPhone, the program itself where it holds the library's functions.
  static Iterable<DynamicLibrary> _found() sync* {
    final tries = IrohNode.libraryPlaces(
      release: kReleaseMode,
      os: PlatformInfo.operatingSystem,
      program: PlatformInfo.resolvedExecutable,
      current: Directory.current.path,
      named: PlatformInfo.environment['GHOST_P2P_LIB'],
    );
    for (final path in tries) {
      DynamicLibrary? lib;
      try {
        lib = DynamicLibrary.open(path);
      } catch (_) {}
      if (lib != null) yield lib;
    }
    if (PlatformInfo.isIOS) {
      final self = DynamicLibrary.process();
      if (self.providesSymbol('ghost_p2p_abi')) yield self;
    }
  }

  /// Android's own part, before the first node is made: only Android's code can tell the library which DNS servers
  /// the phone uses, and that takes the app's context, which Kotlin hands over (P2pCore.kt) when it is asked here,
  /// and not before. The copy it hands it to is the one opened here (the library is named, so the system loads it
  /// once): asked afterwards, this copy says it has it. Null where all is in place; else why not.
  static Future<String?>? _platform;

  Future<String?> platformReady() {
    if (!PlatformInfo.isAndroid || ready() == 1) return Future<String?>.value();
    return _platform ??= () async {
      const failed = 'The direct network could not be given the phone\'s network settings.';
      try {
        final installed = await const MethodChannel('ghost_messaging/p2p').invokeMethod<bool>('install').timeout(const Duration(seconds: 10));
        if (ready() == 1) return null;
        _platform = null;
        return installed == true ? '$failed (They went to another copy of its core.)' : failed;
      } catch (_) {
        // No channel here (an isolate of the app's own making), or Kotlin could not: a later start asks again.
        _platform = null;
        return failed;
      }
    }();
  }

  /// One buffer that commands are written into for the library to read, the same each time: the library has read
  /// it by the time it returns, and this isolate runs one command at a time.
  static Pointer<Uint8> _scratch = nullptr;
  static int _room = 0;

  /// The command buffer, with room for [len] bytes at least. One that is outgrown is wiped before it is freed: it may
  /// have held a node key.
  static Pointer<Uint8> scratch(int len) {
    if (len > _room) {
      if (_room > 0) {
        _scratch.asTypedList(_room).fillRange(0, _room, 0);
        malloc.free(_scratch);
      }
      _room = len < 4096 ? 4096 : len;
      _scratch = malloc<Uint8>(_room);
    }
    return _scratch;
  }

  /// What the command buffer holds now: a test's look that nothing of a node key is left in it.
  static Uint8List get scratchNow => _room == 0 ? Uint8List(0) : Uint8List.fromList(_scratch.asTypedList(_room));
}

/// Commands and events by their first byte (native/p2p/README.md).
abstract final class _Cmd {
  static const start = 0x01, stop = 0x02, allow = 0x03, disallow = 0x04, openToAll = 0x05, open = 0x06, send = 0x07, close = 0x08, taken = 0x09, done = 0x0a, networkChanged = 0x0b;
}

/// What the library says of a node, by an event's first byte.
abstract final class _Ev {
  static const up = 0x01, down = 0x02, off = 0x03, whereabouts = 0x04, path = 0x05, opened = 0x06, openFailed = 0x07, incoming = 0x08, frame = 0x09, sent = 0x0a, closed = 0x0b;
}

/// What `ghost_p2p_command` answers a SEND with, where it is not 0.
abstract final class _Answer {
  static const overflow = -4, tooLong = -5;
}

/// The most streams one TAKEN or DONE names (`MAX_LISTED` in native/p2p/src/wire.rs).
const _mostListed = 4096;

/// Why a stream closed, in words to show, by the number CLOSED gives.
const _closedBecause = [
  'The stream was closed.',
  'The other device closed the stream.',
  'The link to the other device was lost.',
  'The direct network was stopped.',
  'The other device is no longer allowed.',
  'More was sent than the stream holds waiting, so it was closed.',
  'The other device sent what is no frame.',
];

const _hexDigits = '0123456789abcdef';

/// The 32 bytes of [bytes] from [from], as 64 hex digits: a node id as the app writes it.
String _hex(Uint8List bytes, int from) {
  final out = StringBuffer();
  for (var i = from; i < from + 32; i++) {
    out
      ..write(_hexDigits[bytes[i] >> 4])
      ..write(_hexDigits[bytes[i] & 15]);
  }
  return out.toString();
}

/// A node id's 32 bytes. [id] is one ([isNodeId]).
Uint8List _unhex(String id) => Uint8List.fromList([for (var i = 0; i < 64; i += 2) int.parse(id.substring(i, i + 2), radix: 16)]);

/// A command, written from the front.
class _Writer {
  _Writer(int kind) {
    _out.addByte(kind);
  }
  final _out = BytesBuilder(copy: false);

  // Numbers go in big-endian, as the library reads them.
  void u8(int v) => _out.addByte(v & 0xff);
  void u16(int v) => _out.add([(v >> 8) & 0xff, v & 0xff]);
  void u32(int v) => _out.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  void u64(int v) => _out.add((ByteData(8)..setUint64(0, v)).buffer.asUint8List());
  void bytes(List<int> v) => _out.add(v);
  Uint8List take() => _out.takeBytes();
}

/// This device's node on the direct network, by the Rust core ([P2pNode] says what each member means).
class IrohNode implements P2pNode, Finalizable {
  IrohNode._(this._core);

  /// The number of the C interface this was written against (`ABI` in native/p2p/src/ffi.rs): a library that says
  /// another is not used.
  static const abi = 2;

  /// Whether this build has the library, and it is the one this file was written against. (Asks the library its
  /// number: for the tests, not for making a node.)
  static bool get available {
    final core = _Core.open();
    return core != null && core.problem == null;
  }

  /// A node, not started; null where this build has no library. Nothing of the library runs here: it is opened and
  /// its functions looked up, and the rest waits for the first [start].
  static IrohNode? make() {
    final core = _Core.open();
    if (core == null) return null;
    return IrohNode._(core);
  }

  /// Every node of this isolate that the library has made one for and that has not been let go of, by the library's
  /// number for it.
  static final _nodes = <int, IrohNode>{};

  /// Each place the library may be, in the order to try them: by name on Android (the APK's lib folder); inside the
  /// app on a Mac (Contents/Frameworks); beside the program on Windows; in its lib folder on Linux. In a debug or
  /// profile build also where GHOST_P2P_LIB names (first of all) and, on a Mac, the checkout's own build for
  /// `flutter run` and the tests: a release app opens the copy it carries and nothing else, whatever its process's
  /// environment or the folder it was started in. (On an iPhone the library would be in the program itself.)
  @visibleForTesting
  static List<String> libraryPlaces({required bool release, required String os, required String program, required String current, String? named}) {
    // The folder a path is in, by the last separator of either kind: the same answer on whatever machine asks.
    String up(String path) => path.substring(0, [path.lastIndexOf('/'), path.lastIndexOf('\\'), 0].reduce((a, b) => a > b ? a : b));
    final beside = up(program);
    return [
      if (!release && named != null && named.isNotEmpty) named,
      if (os == 'android') 'libghost_p2p.so',
      if (os == 'macos') '${up(beside)}/Frameworks/libghost_p2p.dylib',
      if (os == 'macos' && !release) '$current/build/p2p/mac/libghost_p2p.dylib',
      if (os == 'windows') '$beside\\ghost_p2p.dll',
      if (os == 'linux') '$beside/lib/libghost_p2p.so',
    ];
  }

  /// The command buffer's contents now, for a test.
  @visibleForTesting
  static Uint8List get debugCommandBuffer => _Core.scratchNow;

  /// How many batches of events this isolate has been handed, and how many TAKENs it has said: a test's look that a
  /// burst of frames costs a few of each, not one of each for every frame.
  @visibleForTesting
  static int debugBatches = 0, debugTakens = 0;

  /// Set, the making of a node's library half at its first start fails with these words (as on a phone whose
  /// context could not be handed over): a test's look at what a start that cannot be made comes to.
  @visibleForTesting
  static String? debugFailMaking;

  /// Leaves this node to be let go only by its port's closing, as its isolate ends, and not by its finalizer: a
  /// test's look at what the library does when a post to a port that is gone fails.
  @visibleForTesting
  void debugLeaveToPort() => _core.finalizer.detach(this);

  final _Core _core;

  /// The library's number for this node: none until the first start has made it.
  int? _number;

  /// The first start's making of the library's node, while it is under way; and the STARTs and STOPs asked of the
  /// library meanwhile, given it in order once it is made.
  Future<void>? _making;
  final _waiting = <Uint8List>[];
  bool _gone = false;

  // What [P2pNode]'s members answer from; then each node's path as last said, the streams open by the library's
  // number for them, the opens under way by the number each was asked with, and that number's next.
  final _state = ValueNotifier<P2pState>(P2pState.off);
  final _whereabouts = ValueNotifier<Whereabouts?>(null);
  final _opened = StreamController<P2pStream>.broadcast();
  final _paths = StreamController<P2pPath>.broadcast();
  final _pathNow = <String, P2pPath>{};
  final _streams = <int, _IrohStream>{};
  final _opening = <int, _Opening>{};
  int _nextRequest = 1;
  String? _nodeId, _problem;

  /// Who may open streams to this node, as the app last said: what the library is told, kept here as well, so that
  /// it is told again when its node is made, and so that nothing the app does not allow is handed up, whatever was
  /// already on its way when it said so.
  final _allowed = <String, Set<int>>{};
  Set<int> _open = const {};

  /// Whether [nodeId] may open a stream on [channel] to this node: the channel is open to all, or allowed to it.
  bool _permits(String nodeId, int channel) => _open.contains(channel) || (_allowed[nodeId]?.contains(channel) ?? false);

  /// What the app last asked for: the config to be up with, or null to be off. [state] follows it at once; the
  /// library follows in its own time.
  P2pConfig? _wanted;

  /// What the library was last told to be: the config of the last START it was given, or null (it was never
  /// started, it was stopped, or it said it could not start).
  P2pConfig? _told;

  /// The STARTs and STOPs the library was given and has not answered, oldest first. It answers each in the order it
  /// was given them (a START with UP or DOWN, a STOP with OFF), so an answer is always the oldest one's.
  final _asked = Queue<_Asked>();

  /// A library that answers nothing is not given more than this to answer.
  static const _mostAsked = 8;

  /// The start the app is waiting on, for when it asks for the same again.
  Future<void>? _starting;

  /// Counts what the app asks. Whoever listens to [state] may ask for something else from inside a change of it:
  /// what they asked then stands, and the rest of the change they interrupted is left unsaid.
  int _asks = 0;

  /// While a batch of events is handled: what was taken of each stream, and the streams whose end was handled, said
  /// to the library once at the batch's end.
  Map<int, (int, int)>? _takenNow;
  List<int>? _doneNow;

  @override
  String? get nodeId => _nodeId;

  @override
  ValueListenable<P2pState> get state => _state;

  @override
  String? get problem => _problem;

  @override
  ValueListenable<Whereabouts?> get whereabouts => _whereabouts;

  @override
  Stream<P2pStream> get opened => _opened.stream;

  @override
  Stream<P2pPath> get paths => _paths.stream;

  @override
  P2pPath? pathTo(String nodeId) => _pathNow[nodeId];

  @override
  Future<String> idOf(Uint8List secret) async => _idOf(secret);

  /// The node id [secret] makes, asked of the library with no node running. Throws [P2pError] where the key is not
  /// 32 bytes or the library is not the one this was written against.
  String _idOf(Uint8List secret) {
    if (secret.length != 32) throw P2pError('A node key is 32 bytes; this one is ${secret.length}.');
    final problem = _core.problem;
    if (problem != null) throw P2pError(problem);
    final both = malloc<Uint8>(64);
    try {
      both.asTypedList(32).setAll(0, secret);
      if (_core.nodeId(both, both + 32) != 0) throw P2pError('The direct network could not read the node key.');
      return _hex(both.asTypedList(64), 32);
    } finally {
      // The key does not stay in memory this side no longer holds.
      both.asTypedList(64).fillRange(0, 64, 0);
      malloc.free(both);
    }
  }

  /// Why [config] can't be started with, in words to show; null where it can.
  String? _wrong(P2pConfig config) {
    if (config.secret.length != 32) return 'A node key is 32 bytes; this one is ${config.secret.length}.';
    if (config.helpers.length > 8) return 'A node takes eight link helpers at most; it was given ${config.helpers.length}.';
    for (final helper in config.helpers) {
      if (!helper.startsWith('https://') || utf8.encode(helper).length > 200) return 'This is not a link helper\'s address: $helper';
    }
    if (config.helpersOnly && config.helpers.isEmpty) return 'Only through link helpers was chosen, and there is no link helper.';
    return null;
  }

  /// A future that has failed, for whoever awaits it; not an error with nobody to hear it for whoever does not.
  Future<T> _fails<T>(String why) {
    final failed = Future<T>.error(P2pError(why));
    failed.ignore();
    return failed;
  }

  /// START: whether only link helpers are used, the node key, then each link helper's address, its length first.
  Uint8List _startCommand(P2pConfig config) {
    final command = _Writer(_Cmd.start)
      ..u8(config.helpersOnly ? 1 : 0)
      ..bytes(config.secret)
      ..u8(config.helpers.length);
    for (final helper in config.helpers) {
      final text = utf8.encode(helper);
      command
        ..u16(text.length)
        ..bytes(text);
    }
    return command.take();
  }

  /// Gives the library a START or a STOP, and puts it in the line of those it has yet to answer. False where it
  /// would not take it: there is then nothing to wait for.
  bool _give(_Asked asked, Uint8List command, Duration patience, void Function() unanswered) {
    if (_command(command) != 0) return false;
    _asked.add(asked);
    // The library always answers. The wait is only so that a bug there is a node that is down, not one this side
    // waits on for ever; what was asked keeps its place in the line, so an answer that comes late is still its own.
    asked.guard = Timer(patience, unanswered);
    return true;
  }

  /// Whoever waits on a start the library has not answered yet is told nothing more is coming of it: something
  /// else was asked for since.
  void _callOff() {
    for (final asked in _asked) {
      if (asked.config != null) asked.say(null);
    }
  }

  /// The library never answered [start].
  void _neverStarted(_Asked start) {
    const why = 'The direct network did not start.';
    if (!start.said.isCompleted && _asked.isNotEmpty && identical(_asked.last, start) && _wanted == start.config && _state.value == P2pState.starting) {
      _problem = why;
      _state.value = P2pState.down;
    }
    start.say(why);
  }

  /// Done when the node is up with [config]. Throws [P2pError] where it could not start: [state] is then
  /// [P2pState.down] and [problem] says why. A start that a later [stop] or [start] calls off is done without a
  /// word, and no node is left up for it. Asked for again while it is under way, it is the same start.
  @override
  Future<void> start(P2pConfig config) {
    try {
      return _start(config);
    } catch (e) {
      return _fails('The direct network could not start: $e');
    }
  }

  Future<void> _start(P2pConfig config) {
    if (_gone) return _fails('This node was let go.');
    if (_wanted == config) {
      if (_state.value == P2pState.up) return Future<void>.value();
      final starting = _starting;
      if (_state.value == P2pState.starting && starting != null) return starting;
    }
    final asks = ++_asks;
    final was = _state.value;
    String? id;
    var wrong = _wrong(config);
    if (wrong == null) {
      try {
        id = _idOf(config.secret);
      } on P2pError catch (e) {
        wrong = e.message;
      }
    }

    // The library first, so that whatever a listener asks from inside what follows comes after this in its line.
    _callOff();
    _Asked? mine;
    final last = _asked.isEmpty ? null : _asked.last;
    if (wrong == null && _told == config && last != null && last.config == config) {
      // It was given this very start and has not answered it (this side stopped waiting): waited on again, not
      // asked a second time.
      mine = last
        ..said = Completer<String?>()
        ..guard = Timer(const Duration(seconds: 30), () => _neverStarted(last));
    } else {
      if (_told != null) {
        // What it has, or is making, is something else: stopped first.
        final stop = _Asked(null);
        _give(stop, Uint8List.fromList([_Cmd.stop]), const Duration(seconds: 20), () => stop.say(null));
        _told = null;
      }
      if (wrong == null && _asked.length >= _mostAsked) wrong = 'The direct network is not answering.';
      if (wrong == null) {
        final start = _Asked(config);
        if (_give(start, _startCommand(config), const Duration(seconds: 30), () => _neverStarted(start))) {
          mine = start;
          _told = config;
        } else {
          wrong = 'The direct network did not take the start.';
        }
      }
    }
    _wanted = mine == null ? null : config;
    Future<void>? done;
    if (mine != null) {
      done = mine.said.future.then<void>((problem) {
        if (problem != null) throw P2pError(problem);
      });
      // Failed for whoever awaits it; not an error with nobody to hear it for whoever does not.
      done.ignore();
    }
    _starting = done;

    // Then what the app sees, at once: what was up is off, and this is starting (or could not).
    if ((was == P2pState.up || was == P2pState.starting) && !_showOff(asks)) return done ?? _fails(wrong!);
    if (done == null) {
      _problem = wrong;
      _state.value = P2pState.down;
      return _fails(wrong!);
    }
    _nodeId = id;
    _problem = null;
    _state.value = P2pState.starting;
    return done;
  }

  /// Off at once, as far as the app can see: when this returns [state] is [P2pState.off], [whereabouts] is null,
  /// every stream has ended and nothing is handed up any more. Done when the library has closed everything (every
  /// link, the sockets). A start that was under way is called off: the library answers it, then the stop behind it,
  /// and no node is left up.
  @override
  Future<void> stop() {
    try {
      return _stop();
    } catch (e) {
      return _fails('The direct network could not stop: $e');
    }
  }

  Future<void> _stop() {
    if (_gone) return Future<void>.value();
    final asks = ++_asks;
    _wanted = null;
    _starting = null;
    _callOff();
    var done = Future<void>.value();
    if (_told != null) {
      final mine = _Asked(null);
      _told = null;
      if (_give(mine, Uint8List.fromList([_Cmd.stop]), const Duration(seconds: 20), () => mine.say(null))) done = mine.said.future.then<void>((_) {});
    } else if (_asked.isNotEmpty && _asked.last.config == null) {
      // Stopping already: done when that is.
      done = _asked.last.said.future.then<void>((_) {});
    }
    if (_state.value != P2pState.off) _showOff(asks);
    return done;
  }

  /// Shows the app a node that is off: nowhere to be found, every stream ended, every open failed. False where a
  /// listener asked for something else meanwhile, which then stands.
  bool _showOff(int asks) {
    _problem = null;
    _whereabouts.value = null;
    if (asks != _asks) return false;
    _endEverything('The direct network was stopped.');
    _state.value = P2pState.off;
    return asks == _asks;
  }

  /// Every stream ends and every open under way fails: the node is not up to carry them.
  void _endEverything(String why) {
    for (final stream in _streams.values.toList()) {
      stream._ended(why);
    }
    _streams.clear();
    for (final opening in _opening.values.toList()) {
      opening.fail(why);
    }
    _opening.clear();
    for (final path in _pathNow.values.toList()) {
      if (!_paths.isClosed) _paths.add(P2pPath(path.nodeId, P2pPathKind.none));
    }
    _pathNow.clear();
  }

  /// Every stream with [nodeId] that [still] does not keep ends at once, as far as the app can see; the library
  /// closes them in its own time.
  void _endStreams(bool Function(_IrohStream stream) still, String why) {
    for (final stream in _streams.values.where((s) => !still(s)).toList()) {
      _streams.remove(stream._id);
      stream._ended(why);
    }
  }

  @override
  void networkChanged() {
    if (_number != null) _command(Uint8List.fromList([_Cmd.networkChanged]));
  }

  /// In force when this returns: a stream that comes after it is judged by it, and a stream it opened on a channel it
  /// no longer has has ended. Never throws: an id that is no node id lets nobody in, and a channel past 255 is none.
  @override
  void allow(String nodeId, Set<int> channels) {
    if (_gone || !isNodeId(nodeId)) return;
    final list = _channels(channels);
    if (list.isEmpty) {
      _allowed.remove(nodeId);
    } else {
      _allowed[nodeId] = list.toSet();
    }
    _endStreams((s) => !s.incoming || s.nodeId != nodeId || _permits(nodeId, s.channel), _closedBecause[4]);
    if (_number != null) _command(_allowCommand(nodeId, list));
  }

  /// ALLOW: the node id's 32 bytes, how many channels, and each channel's byte.
  Uint8List _allowCommand(String nodeId, List<int> channels) => (_Writer(_Cmd.allow)
        ..bytes(_unhex(nodeId))
        ..u8(channels.length)
        ..bytes(channels))
      .take();

  /// In force when this returns: every stream with [nodeId], whichever end opened it, has ended, and nothing more of
  /// it is taken. Never throws.
  @override
  void disallow(String nodeId) {
    if (_gone || !isNodeId(nodeId)) return;
    _allowed.remove(nodeId);
    _endStreams((s) => s.nodeId != nodeId, _closedBecause[4]);
    // An open to it that is under way fails now, and the stream it may still come to is closed as it comes (an OPENED
    // nobody waits on): it was handed up, frames and all, after this had returned.
    for (final entry in _opening.entries.where((e) => e.value.nodeId == nodeId).toList()) {
      _opening.remove(entry.key);
      entry.value.fail('This device no longer allows it.');
    }
    if (_number != null) _command((_Writer(_Cmd.disallow)..bytes(_unhex(nodeId))).take());
  }

  /// In force when this returns, as [allow] is. Never throws: a channel past 255 is none.
  @override
  void openToAll(Set<int> channels) {
    if (_gone) return;
    final list = _channels(channels);
    _open = list.toSet();
    _endStreams((s) => !s.incoming || _permits(s.nodeId, s.channel), _closedBecause[4]);
    if (_number != null) _command(_openCommand(list));
  }

  /// OPEN_TO_ALL: how many channels, and each channel's byte.
  Uint8List _openCommand(List<int> channels) => (_Writer(_Cmd.openToAll)
        ..u8(channels.length)
        ..bytes(channels))
      .take();

  /// A channel is one byte on the wire: one that is not is passed over.
  List<int> _channels(Set<int> channels) => channels.where((c) => c >= 0 && c <= 255).toList()..sort();

  @override
  Future<P2pStream> open(String nodeId, int channel, {Whereabouts? hint, Duration timeout = const Duration(seconds: 5)}) {
    try {
      return _openStream(nodeId, channel, hint, timeout);
    } catch (e) {
      return _fails('The stream could not be opened: $e');
    }
  }

  Future<P2pStream> _openStream(String nodeId, int channel, Whereabouts? hint, Duration timeout) {
    if (!isNodeId(nodeId)) return _fails('That is not a node id.');
    if (channel < 0 || channel > 255) return _fails('A channel is 0 to 255.');
    if (_gone || _state.value != P2pState.up || _number == null) return _fails('The direct network is not up.');
    final request = _nextRequest;
    _nextRequest = _nextRequest >= 0xffffffff ? 1 : _nextRequest + 1;
    final wait = timeout.inMilliseconds.clamp(0, 0xffffffff);
    // The library is given a moment less than the open's own wait, so that its answer, with its reason, comes first;
    // whatever it does, the open has ended by its timeout (the library itself waits no less than 100 ms).
    final libraryWait = (wait - 25).clamp(1, 0xffffffff);
    // What the other device last said of where it is, as far as the library takes it (a helper of 200 bytes, eight
    // addresses of 64); the library itself uses a helper only where it is one of this node's own, and an address only
    // where it is another device's.
    final helper = utf8.encode(hint?.helper ?? '');
    final addresses = [
      for (final a in hint?.addresses ?? const <String>[])
        if (a.isNotEmpty && utf8.encode(a).length <= 64) utf8.encode(a),
    ].take(Whereabouts.mostAddresses).toList();
    final command = _Writer(_Cmd.open)
      ..u32(request)
      ..bytes(_unhex(nodeId))
      ..u8(channel)
      ..u32(libraryWait)
      ..u16(helper.length <= 200 ? helper.length : 0)
      ..bytes(helper.length <= 200 ? helper : const [])
      ..u8(addresses.length);
    for (final a in addresses) {
      command
        ..u8(a.length)
        ..bytes(a);
    }
    final opening = _Opening(nodeId, channel);
    _opening[request] = opening;
    if (_command(command.take()) != 0) {
      _opening.remove(request);
      return _fails('The direct network is not up.');
    }
    // The open ends by its timeout, whether or not the library has answered: it fails, and a stream that turns up after
    // all is closed.
    opening.late = Timer(Duration(milliseconds: wait), () {
      if (_opening.remove(request) != null) opening.fail('It did not answer in time.');
    });
    // Failed for whoever awaits it; not an error with nobody to hear it for whoever has stopped waiting.
    return opening.done.future..ignore();
  }

  /// Stops the node and lets go of it: nothing can be asked of it again. (Not part of [P2pNode]: the app keeps its
  /// node for as long as it runs; a test lets go of the ones it made. One that is never let go of is let go as its
  /// isolate ends.)
  void dispose() {
    if (_gone) return;
    _gone = true;
    final number = _number;
    if (number != null) {
      _nodes.remove(number);
      _core.finalizer.detach(this);
      // Once this returns the library posts nothing more of this node.
      _core.drop(number);
    }
    _wipeWaiting();
    _asks++;
    _wanted = null;
    _told = null;
    _starting = null;
    for (final asked in _asked) {
      asked.say(null);
    }
    _asked.clear();
    _problem = null;
    _whereabouts.value = null;
    _endEverything('The direct network was stopped.');
    _state.value = P2pState.off;
    _opened.close();
    _paths.close();
  }

  /// Hands the library a command. Until the first start has made the library's node, a START or a STOP waits in line
  /// for it (and the first sets the making going), and who is allowed is told it once it is made; anything else
  /// cannot come before then. A START carries the node key: what held it is written over once it has been read.
  int _command(Uint8List bytes) {
    if (_gone || bytes.isEmpty) return -1;
    final number = _number;
    if (number == null) {
      if (bytes[0] != _Cmd.start && bytes[0] != _Cmd.stop) return 0;
      _waiting.add(bytes);
      _making ??= _make();
      return 0;
    }
    final at = _Core.scratch(bytes.length);
    final there = at.asTypedList(bytes.length);
    try {
      there.setAll(0, bytes);
      return _core.command(number, at, bytes.length);
    } finally {
      if (bytes[0] == _Cmd.start) {
        there.fillRange(0, bytes.length, 0);
        bytes.fillRange(0, bytes.length, 0);
      }
    }
  }

  /// The first start: the platform's part (Android's context), then the library's node, told who is allowed, then
  /// given what was asked of it meanwhile, in order. Where it cannot be made, each START waiting is answered as the
  /// library would answer one that could not start, and each STOP as one that has stopped; a later start tries again.
  Future<void> _make() async {
    // Once what asked for it is in the line of what the library is to answer (it is put there as this returns).
    await Future<void>.value();
    String? problem = _core.problem ?? debugFailMaking;
    if (problem == null) {
      try {
        problem = await _core.platformReady();
      } catch (e) {
        problem = 'The direct network could not start: $e';
      }
    }
    _making = null;
    if (_gone) return _wipeWaiting();
    if (problem == null) {
      final number = _core.make(_Core.port.sendPort.nativePort, NativeApi.postCObject.cast<Void>(), NativeApi.majorVersion);
      if (number == 0) {
        problem = 'The direct network\'s core could not make a node.';
      } else {
        _number = number;
        _nodes[number] = this;
        _core.finalizer.attach(this, Pointer<Void>.fromAddress(number), detach: this);
        for (final e in _allowed.entries) {
          _command(_allowCommand(e.key, e.value.toList()..sort()));
        }
        if (_open.isNotEmpty) _command(_openCommand(_open.toList()..sort()));
        final waiting = List.of(_waiting);
        _waiting.clear();
        for (final command in waiting) {
          _command(command);
        }
        return;
      }
    }
    final starts = [for (final command in _waiting) command[0] == _Cmd.start];
    _wipeWaiting();
    for (final start in starts) {
      _on(start ? Uint8List.fromList([_Ev.down, ...utf8.encode(problem)]) : Uint8List.fromList([_Ev.off]), null);
    }
  }

  /// Drops the commands that waited for the node to be made, each wiped first: a START holds the node key.
  void _wipeWaiting() {
    for (final command in _waiting) {
      command.fillRange(0, command.length, 0);
    }
    _waiting.clear();
  }

  /// SEND, written straight into what the library reads from: a frame of the most is copied once this side.
  int _sendFrame(int stream, Uint8List frame) {
    final number = _number;
    if (_gone || number == null) return -1;
    final len = 9 + frame.length;
    final at = _Core.scratch(len);
    final bytes = at.asTypedList(len);
    bytes[0] = _Cmd.send;
    ByteData.sublistView(bytes).setUint64(1, stream);
    bytes.setRange(9, len, frame);
    return _core.command(number, at, len);
  }

  /// [frames] frames of [bytes] bytes in all of [stream] were handed on: said at the end of the batch of events being
  /// handled, together with the rest of what it took, or at once outside one.
  void _taken(int stream, int frames, int bytes) {
    final now = _takenNow;
    if (now != null) {
      final had = now[stream];
      now[stream] = had == null ? (frames, bytes) : (had.$1 + frames, had.$2 + bytes);
      return;
    }
    _sayTaken({stream: (frames, bytes)});
  }

  /// TAKEN: for each stream, how many frames and bytes of it were handed on; [_mostListed] streams to a command.
  void _sayTaken(Map<int, (int, int)> taken) {
    final list = taken.entries.toList();
    for (var from = 0; from < list.length; from += _mostListed) {
      debugTakens++;
      final part = list.sublist(from, from + _mostListed < list.length ? from + _mostListed : list.length);
      final command = _Writer(_Cmd.taken)..u16(part.length);
      for (final e in part) {
        command
          ..u64(e.key)
          ..u32(e.value.$1 > 0xffffffff ? 0xffffffff : e.value.$1)
          ..u32(e.value.$2 > 0xffffffff ? 0xffffffff : e.value.$2);
      }
      _command(command.take());
    }
  }

  /// CLOSE: this side ends [stream].
  void _close(int stream) => _command((_Writer(_Cmd.close)..u64(stream)).take());

  /// [stream]'s end has been handled here: said at the end of the batch of events being handled, with the rest of
  /// them, or at once outside one.
  void _done(int stream) {
    final now = _doneNow;
    if (now != null) return now.add(stream);
    _sayDone([stream]);
  }

  /// DONE: the streams whose CLOSED the app has handled; [_mostListed] to a command.
  void _sayDone(List<int> streams) {
    for (var from = 0; from < streams.length; from += _mostListed) {
      final part = streams.sublist(from, from + _mostListed < streams.length ? from + _mostListed : streams.length);
      final command = _Writer(_Cmd.done)..u16(part.length);
      for (final stream in part) {
        command.u64(stream);
      }
      _command(command.take());
    }
  }

  /// A batch of a node's events, as the library posted it: the node's number, then each event's bytes, with a
  /// frame's own bytes beside its event's (a list of its own, which is what a listener is handed).
  static void _heard(Object? message) {
    if (message is! List || message.length < 2) return;
    final number = message[0];
    if (number is! int) return;
    _nodes[number]?._batch(message);
  }

  /// Handles each event of a batch in order, and says once at its end what was taken and which streams are done.
  void _batch(List<Object?> message) {
    debugBatches++;
    final taken = _takenNow = <int, (int, int)>{};
    final done = _doneNow = <int>[];
    try {
      for (var i = 1; i < message.length && !_gone; i++) {
        final event = message[i];
        if (event is! Uint8List || event.isEmpty) continue;
        Uint8List? frame;
        if (event[0] == _Ev.frame) {
          if (i + 1 >= message.length) break;
          final next = message[++i];
          if (next is! Uint8List) continue;
          frame = next;
        }
        try {
          _on(event, frame);
        } catch (error, stack) {
          // One event that could not be read does not stop the ones after it.
          FlutterError.reportError(FlutterErrorDetails(exception: error, stack: stack, library: 'the direct network', context: ErrorDescription('while reading what the core said')));
        }
      }
    } finally {
      _takenNow = null;
      _doneNow = null;
      if (taken.isNotEmpty) _sayTaken(taken);
      if (done.isNotEmpty) _sayDone(done);
    }
  }

  /// One event: [b] is its bytes, the kind first ([_Ev]); [frame] is a FRAME's own bytes.
  void _on(Uint8List b, Uint8List? frame) {
    final d = ByteData.sublistView(b);
    switch (b[0]) {
      case _Ev.up:
        if (b.length < 33) return;
        // The answer to the oldest START this side is waiting on; with none, not this side's to follow.
        final asked = _asked.isEmpty ? null : _asked.first;
        if (asked == null || asked.config == null) return;
        _asked.removeFirst();
        if (_asked.isEmpty && _wanted == asked.config) {
          // It is what the app last asked for, and nothing was asked since: the node is up. (One the app has since
          // called off is not shown: the stop behind it in the line ends it.)
          _nodeId = _hex(b, 1);
          _problem = null;
          _state.value = P2pState.up;
        }
        asked.say(null);
      case _Ev.down:
        final why = b.length > 1 ? utf8.decode(Uint8List.sublistView(b, 1), allowMalformed: true) : 'The direct network could not start.';
        final asked = _asked.isEmpty ? null : _asked.first;
        if (asked != null && asked.config != null) {
          // It could not start.
          _asked.removeFirst();
          if (_asked.isEmpty) {
            _told = null;
            if (_wanted == asked.config) {
              _problem = why;
              _state.value = P2pState.down;
            }
          }
          asked.say(why);
        } else if (asked == null) {
          // It stopped by itself (a bug in the library, caught): nothing is running.
          _told = null;
          if (_wanted != null) {
            _problem = why;
            _whereabouts.value = null;
            _endEverything('The direct network is down.');
            _state.value = P2pState.down;
          }
        }
      case _Ev.off:
        // The answer to the oldest STOP. What the app sees was changed when it asked.
        final asked = _asked.isEmpty ? null : _asked.first;
        if (asked != null && asked.config == null) {
          _asked.removeFirst();
          asked.say(null);
        }
      case _Ev.whereabouts:
        if (b.length < 4) return;
        final helperLen = d.getUint16(1);
        var at = 3 + helperLen;
        if (b.length < at + 1) return;
        final helper = helperLen == 0 ? null : utf8.decode(Uint8List.sublistView(b, 3, at), allowMalformed: true);
        final addresses = <String>[];
        final count = b[at++];
        for (var i = 0; i < count; i++) {
          if (b.length < at + 1) return;
          final n = b[at++];
          if (b.length < at + n) return;
          addresses.add(utf8.decode(Uint8List.sublistView(b, at, at + n), allowMalformed: true));
          at += n;
        }
        if (_state.value == P2pState.up) _whereabouts.value = Whereabouts(helper: helper, addresses: List.unmodifiable(addresses), at: DateTime.now().millisecondsSinceEpoch);
      case _Ev.path:
        // (Of a run the app was already told is over: unsaid, like everything below.)
        if (b.length < 38 || _state.value != P2pState.up) return;
        final node = _hex(b, 1);
        final kind = switch (b[33]) { 1 => P2pPathKind.helper, 2 => P2pPathKind.direct, _ => P2pPathKind.none };
        final rtt = d.getUint32(34);
        final path = P2pPath(node, kind, rttMs: rtt == 0xffffffff ? null : rtt);
        if (kind == P2pPathKind.none) {
          _pathNow.remove(node);
        } else {
          _pathNow[node] = path;
        }
        _paths.add(path);
      case _Ev.opened:
        if (b.length < 13) return;
        final opening = _opening.remove(d.getUint32(1));
        final id = d.getUint64(5);
        if (opening == null) {
          // Nobody is waiting for it any longer.
          _close(id);
          _done(id);
          return;
        }
        final stream = _streams[id] = _IrohStream(this, id, opening.nodeId, opening.channel, incoming: false);
        opening.late?.cancel();
        opening.done.complete(stream);
      case _Ev.openFailed:
        if (b.length < 6) return;
        _opening.remove(d.getUint32(1))?.fail(b.length > 6 ? utf8.decode(Uint8List.sublistView(b, 6), allowMalformed: true) : 'It could not be reached.');
      case _Ev.incoming:
        if (b.length < 42) return;
        final id = d.getUint64(1);
        final from = _hex(b, 9), channel = b[41];
        // A stream of a run the app was told is over is not handed up (the library closes it with the rest), nor one
        // the app no longer allows, which was on its way when it said so.
        if (_state.value != P2pState.up || !_permits(from, channel)) {
          _close(id);
          return;
        }
        final stream = _streams[id] = _IrohStream(this, id, from, channel, incoming: true);
        if (_opened.hasListener) {
          _opened.add(stream);
        } else {
          // Nobody is there to take it.
          stream.close();
        }
      case _Ev.frame:
        if (frame == null || b.length < 9) return;
        final id = d.getUint64(1);
        final stream = _streams[id];
        if (stream == null) {
          _taken(id, 1, frame.length);
        } else {
          stream._frame(frame);
        }
      case _Ev.sent:
        if (b.length < 17) return;
        _streams[d.getUint64(1)]?._sent(d.getUint64(9));
      case _Ev.closed:
        if (b.length < 10) return;
        final id = d.getUint64(1);
        _streams.remove(id)?._ended(b[9] < _closedBecause.length ? _closedBecause[b[9]] : 'The stream was closed.');
        // Its end is handled: whatever the library still counted for it is let go.
        _done(id);
    }
  }
}

/// A START or a STOP the library was given and has not answered.
class _Asked {
  _Asked(this.config);

  /// What a START asked to be up with; null for a STOP.
  final P2pConfig? config;

  /// How it went, for whoever asked: null where it went (or was called off), else why it did not.
  Completer<String?> said = Completer<String?>();

  /// Ends the waiting where the library never answers.
  Timer? guard;

  /// Answers whoever asked, once, and ends the wait.
  void say(String? problem) {
    guard?.cancel();
    guard = null;
    if (!said.isCompleted) said.complete(problem);
  }
}

/// An [IrohNode.open] under way.
class _Opening {
  _Opening(this.nodeId, this.channel);
  final String nodeId;
  final int channel;
  final done = Completer<P2pStream>();

  /// Ends the open at its timeout, whatever the library does.
  Timer? late;

  /// Fails the open for whoever awaits it, once.
  void fail(String why) {
    late?.cancel();
    if (!done.isCompleted) done.completeError(P2pError(why));
  }
}

/// One stream with another node, by the library's number for it: frames in as the library hands them up, frames out
/// as SENDs, each done when the library says it was written.
class _IrohStream implements P2pStream {
  _IrohStream(this._node, this._id, this.nodeId, this.channel, {required this.incoming});

  final IrohNode _node;
  final int _id;

  @override
  final String nodeId;
  @override
  final int channel;
  @override
  final bool incoming;

  /// Frames wait here until someone listens, and while whoever listens is paused: the library is told they were
  /// taken only as they go on from here, so it reads no more than a stream's worth ahead of a listener.
  late final StreamController<Uint8List> _frames = StreamController<Uint8List>(onListen: _flow, onResume: _flow, onCancel: _unheard);

  /// Frames that are in [_frames] and not yet said to be taken, and their bytes.
  int _heldFrames = 0, _heldBytes = 0;

  /// The listener went away: what comes is taken and dropped.
  bool _deaf = false;

  /// Closed here ([close] was called), and over (the library said so, or the node stopped).
  bool _closing = false, _over = false;
  String _why = 'The stream has closed.';
  Completer<void>? _closed;

  /// One for each frame queued and not yet written, oldest first; and how many the library has said it wrote.
  final _sending = Queue<Completer<void>>();
  int _written = 0;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  /// Someone listens, or listens again: the frames that waited go on to them, and are said to be taken.
  void _flow() {
    if (_heldFrames == 0 || _over) return;
    _node._taken(_id, _heldFrames, _heldBytes);
    _heldFrames = 0;
    _heldBytes = 0;
  }

  /// The listener went away: what waited is said to be taken, so the library is not held back by a stream nobody reads.
  void _unheard() {
    _deaf = true;
    _flow();
  }

  /// A frame came: handed to whoever listens and said to be taken, or held (and not said) until someone does.
  void _frame(Uint8List frame) {
    if (_closing || _deaf || _frames.isClosed) {
      _node._taken(_id, 1, frame.length);
      return;
    }
    _frames.add(frame);
    if (_frames.hasListener && !_frames.isPaused) {
      _node._taken(_id, 1, frame.length);
    } else {
      _heldFrames++;
      _heldBytes += frame.length;
    }
  }

  /// The library has written [written] frames of this stream in all: the adds up to there are done.
  void _sent(int written) {
    while (_written < written && _sending.isNotEmpty) {
      _sending.removeFirst().complete();
      _written++;
    }
  }

  /// The stream is over, and [why]: what was not yet written fails, the frames end, and a [close] waiting is done.
  void _ended(String why) {
    if (_over) return;
    _over = true;
    if (!_closing) _why = why;
    for (final waiting in _sending) {
      waiting.completeError(P2pError(_why));
    }
    _sending.clear();
    if (!_frames.isClosed) _frames.close();
    _closed?.complete();
  }

  Future<void> _no(String why) {
    // Failed for whoever awaits it; not an error with nobody to hear it for whoever does not.
    final failed = Future<void>.error(P2pError(why));
    failed.ignore();
    return failed;
  }

  /// Done when the frame has been written to the link (QUIC has it, in its turn after the ones before it), not when
  /// the other device has read it: a frame that is done can still be lost with the link, and one the other end is
  /// slow to take holds the next back. Fails where the stream has closed, or the frame is longer than a stream carries.
  @override
  Future<void> add(Uint8List frame) {
    if (_closing || _over) return _no(_why);
    if (frame.length > P2pNode.maxFrame) return _no('A frame is ${P2pNode.maxFrame} bytes at most; this one is ${frame.length}.');
    switch (_node._sendFrame(_id, frame)) {
      case 0:
        final written = Completer<void>();
        written.future.ignore();
        _sending.add(written);
        return written.future;
      case _Answer.overflow:
        _why = _closedBecause[5];
        return _no(_why);
      case _Answer.tooLong:
        return _no('A frame is ${P2pNode.maxFrame} bytes at most; this one is ${frame.length}.');
      default:
        return _no(_why);
    }
  }

  /// Done when the other end has seen the end (or was given a few seconds to), after everything added before.
  @override
  Future<void> close() {
    if (_over) return Future.value();
    if (!_closing) {
      _closing = true;
      _closed = Completer<void>();
      _node._close(_id);
      // What had come is still there for whoever listens; nothing more is.
      _frames.close();
    }
    return _closed!.future;
  }
}
