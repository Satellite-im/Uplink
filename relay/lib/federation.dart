import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'fed_dial.dart';
import 'handles.dart';
import 'home_record.dart';
import 'hub.dart';
import 'p256.dart';
import 'sha256.dart';

/// Whether this relay links with other relays: its keeper's choice (`GHOST_FED`).
enum FedMode {
  /// With none: it is an island, as every relay was before. Nothing is dialled, no link is taken, no packet passed on,
  /// no key made, no record kept: the hub is exactly the one it was before any of it.
  off,

  /// With any relay that proves its key, but those blocked.
  open,

  /// Only with the relays its keeper listed (`GHOST_FED_ALLOW`).
  list,
}

/// What federation reads from the server's environment (bin/relay.dart); every one has a default, and the default is
/// off.
class FedConfig {
  const FedConfig({this.mode = FedMode.off, this.allow = const {}, this.block = const {}, this.publicHub = '', this.via = '', this.packetsAMinute = 1200, this.bytesADay = 512 << 20, this.lookupsAnHour = 600, this.ports = const {}, this.plain = false, this.standingOpen = false, this.standing = const {}, this.problems = const []});

  /// Reads `GHOST_FED`, the other `GHOST_FED_*` settings and `GHOST_PUBLIC_HUB` from [env]. Nothing typed wrong stops
  /// the relay: it is read as its default or passed over, and said in [problems].
  factory FedConfig.fromEnvironment(Map<String, String> env) {
    final problems = <String>[];
    String said(String name) => (env[name] ?? '').trim();
    final mode = switch (said('GHOST_FED').toLowerCase()) {
      'open' => FedMode.open,
      'list' => FedMode.list,
      '' || 'off' => FedMode.off,
      _ => () {
          problems.add('GHOST_FED is off, open or list: read as off');
          return FedMode.off;
        }(),
    };
    Set<String> names(String name) {
      final out = <String>{};
      for (final part in said(name).toLowerCase().split(',').map((p) => p.trim()).where((p) => p.isNotEmpty)) {
        if (_relayName.hasMatch(part) || _hostAndPort.hasMatch(part)) {
          out.add(part);
        } else {
          problems.add('$name: "$part" is neither a host nor a relay\'s name, and is passed over');
        }
      }
      return out;
    }

    String hub(String name) {
      final typed = said(name);
      if (typed.isEmpty) return '';
      final url = canonicalHub(typed);
      if (url == null || !url.endsWith('/hub')) {
        problems.add('$name is a hub\'s address, like wss://relay.example.com/hub: passed over');
        return '';
      }
      return url;
    }

    int number(String name, int fallback, int most) {
      final typed = said(name);
      if (typed.isEmpty) return fallback;
      final n = RegExp(r'^[0-9]{1,15}$').hasMatch(typed) ? int.parse(typed) : -1;
      if (n < 1) {
        problems.add('$name is a whole number above nothing: its default is used');
        return fallback;
      }
      return n > most ? most : n;
    }

    final ports = <int>{};
    for (final part in said('GHOST_FED_PORTS').split(',').map((p) => p.trim()).where((p) => p.isNotEmpty)) {
      final n = RegExp(r'^[0-9]{1,5}$').hasMatch(part) ? int.parse(part) : 0;
      if (n >= 1 && n <= 65535) {
        ports.add(n);
      } else {
        problems.add('GHOST_FED_PORTS: "$part" is not a port, and is passed over');
      }
    }
    // Standing links (a relay with no address that stays linked, and has its people's packets passed on by this one):
    // off unless the keeper says `open`, or names the relays that may.
    final standingSaid = said('GHOST_FED_STANDING').toLowerCase();
    final standing = <String>{};
    var standingOpen = false;
    if (standingSaid == 'open') {
      standingOpen = true;
    } else if (standingSaid.isNotEmpty && standingSaid != 'off') {
      for (final part in standingSaid.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty)) {
        if (_relayName.hasMatch(part)) {
          standing.add(part);
        } else {
          problems.add('GHOST_FED_STANDING: "$part" is not a relay\'s name (32 hex), and is passed over');
        }
      }
    }
    return FedConfig(
      mode: mode,
      allow: names('GHOST_FED_ALLOW'),
      block: names('GHOST_FED_BLOCK'),
      publicHub: hub('GHOST_PUBLIC_HUB'),
      via: hub('GHOST_FED_VIA'),
      packetsAMinute: number('GHOST_FED_PACKETS_A_MINUTE', 1200, 1000000),
      // (2^40, written out: a shift keeps 32 bits where an integer is a browser's number.)
      bytesADay: number('GHOST_FED_BYTES_A_DAY', 512 << 20, 1099511627776),
      lookupsAnHour: number('GHOST_FED_LOOKUPS_AN_HOUR', 600, 1000000),
      ports: ports,
      plain: said('GHOST_FED_PLAIN') == '1',
      standingOpen: standingOpen,
      standing: standing,
      problems: problems,
    );
  }

  /// A relay's name (32 hex digits), and a host with or without its port, as the keeper's lists and `whois` take them.
  static final _relayName = RegExp(r'^[0-9a-f]{32}$');
  static final _hostAndPort = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*(:[0-9]{1,5})?$');

  /// Whether it links at all, and with whom (`GHOST_FED`).
  final FedMode mode;

  /// With [FedMode.list], the only relays linked with: each a host (`relay.example.com`, or with its port) or a
  /// relay's name (32 hex digits). With [FedMode.open] it changes nothing.
  final Set<String> allow;

  /// Never linked with, whatever the mode: hosts or relays' names.
  final Set<String> block;

  /// This relay's own hub address as the world reaches it (`GHOST_PUBLIC_HUB`), as [canonicalHub] writes it. Empty,
  /// it claims none: it can dial out, and takes no other relay's hello (one dialled by another relay is dialled at
  /// this address, and says so in what it signs).
  final String publicHub;

  /// The public relay this one stays linked to (`GHOST_FED_VIA`): for a relay with no address of its own, as one
  /// hosted from an app is. Its people are reached through that link, and reach everyone else through it.
  final String via;

  /// What one linked relay may send here: packets a minute, bytes a day, and how many names it may ask after an hour.
  /// One relay is one address this relay has checked; every relay with no address shares one allowance.
  final int packetsAMinute;
  final int bytesADay;
  final int lookupsAnHour;

  /// Ports dialled besides 443, and whether `ws://` is (fed_dial.dart).
  final Set<int> ports;
  final bool plain;

  /// Which relays with no address may stay linked to this one and have their people's packets passed on to other
  /// relays under this one's name (`GHOST_FED_STANDING`): any where [standingOpen], else those named. Off by default:
  /// it is for relays hosted from the app, and switched on deliberately.
  final bool standingOpen;
  final Set<String> standing;

  /// What in the environment could not be read, in words, for the keeper to see as the relay starts.
  final List<String> problems;
}

/// Dials the hub at [url], which has passed [DialGuard.shape]: the default looks the name up, checks every answer and
/// connects to an address that passed ([DialGuard.dial]); a test hands back a connection held in memory. Whether a
/// dial may be made at all this minute is asked of the guard first ([DialGuard.take]).
typedef FedDial = Future<HubSocket> Function(Uri url);

/// A link another relay opened, as the hub hands it what that relay says ([Federation.incoming]).
abstract class FedEnd {
  /// Something that relay said on the link: a text frame or a binary one.
  void heard(Object? data);

  /// Its connection closed.
  void gone();
}

/// Relays that talk to each other (docs/OPEN_NETWORK.md, section 4; Matt, 2026-11-22: "I'd like the relays to be able
/// to talk to each other"): two people whose apps use different relays can be friends and talk, each through their
/// own relay, and the relays pass their sealed packets to each other.
///
/// - **Off does nothing.** With [FedMode.off] (the default) no key is made or read, no record kept or answered, and
///   the hub says and does exactly what it did before any of this (bin/relay.dart makes none at all).
/// - **A key of its own.** `relay-key.json` in the data folder, made on first start (in memory where there is no
///   folder). The relay's name is made from it as an install's is ([Hub.nameOf]), and the hub's hello to anything that
///   connects says so (`"relay": {"id", "key"}`, [card]).
/// - **Home records** ([HomeRecord], [HomeBook]). The one thing believed about where someone lives: their own
///   signature, good for thirty days. An app gives its own as it signs in and its friends' so this relay can route
///   to them (`{"dir":"home","rec":…}`), and may ask for its own back (`{"dir":"home?"}`); nobody is told anyone
///   else's but over a link, or with the username they chose to be found by.
/// - **Links.** One relay dials another's hub and, in place of an app's hello, says who it is ([dialBytes],
///   [answerBytes]): both prove their keys, each over a number the other made up, over **both** names, and over the
///   address that was dialled, which the answerer takes only where it is its own ([FedConfig.publicHub]); so what one
///   signs for this link is no use on another, nor passed on word for word by a relay in the middle. A relay that
///   claims an address is believed once this relay has dialled that address itself and seen the same key there
///   ([_keyAt], remembered for an hour). What is for an address goes only over a link this relay dialled there itself
///   ([_linkFor]). Whether it links at all is [FedConfig.mode], off unless its keeper says otherwise. A link is opened
///   when first needed, kept while used, closed after [idleFor], tried again with [backoff]; [maxLinks] at most.
/// - **Passing packets on** ([pass]). A packet from someone whose record this relay holds, for someone not connected
///   here whose record names another relay, goes over a link (`[5]`), and its sender is told it was taken. With that
///   relay unreachable it waits here ([queuePackets], [queueBytes], [queueFor]; for an address never once linked with,
///   a minute or two) and the sender is told it is kept.
/// - **A relay speaks only for its own people** ([_speaksFor]): what a relay passes on as from someone is taken only
///   where that someone's record names that relay. Refused for want of a record (`nak` `home`), the sender gives the
///   record and tries once more.
/// - **One hop.** What another relay passed here is handed to someone here or kept for them (only someone who has
///   signed in here), never passed to a third relay. The one exception is `via`, and only where this relay's keeper
///   lets relays stay ([FedConfig.standing]): a relay with no address of its own (hosted from an app) dials a public
///   relay and stays linked; its people's records say `ghost-relay://<its name>?…&via=<that relay>`, they are reached
///   over the standing link, and another relay reaches them by sending that relay a `[6]` naming the hosted one.
/// - **Names** ([_whoisFromApp]). `@maya@relay.example` is asked of that relay over a link.
/// - **Limits.** Everything someone else can grow is counted and capped, and every shared allowance is held so no one
///   party can use it up: records ([HomeBook]) and their checks (the shape first, then the giver's own count, then
///   everyone's), hellos (checked before they are counted; relays at an address seen already apart from strangers),
///   dials (each kind its own), relays waited on ([maxPeers]; each install may make this one dial only so many new
///   ones), what waits (each sender and each recipient a mailbox's worth at most; [queuedBytes] in all), what each
///   install sends across relays, and per linked relay [FedConfig.packetsAMinute], [FedConfig.bytesADay],
///   [FedConfig.lookupsAnHour] and record checks (generous only for a relay at an address this relay has checked:
///   keys are free).
///
/// What it adds to what a relay can see: which of its people talk to people on which other relay. Still never what.
class Federation {
  Federation({
    this.dataDir,
    this.config = const FedConfig(),
    FedDial? dial,
    DialGuard? guard,
    DateTime Function()? now,
    Random? random,
    this.verbose = false,
    this.maxLinks = 64,
    this.maxPeers = 256,
    this.queuePackets = 2000,
    this.queueBytes = 16 << 20,
    this.queuedBytes = 32 << 20,
    this.checksAnHour = 600,
    this.checksASecond = 20,
    this.hellosAMinute = 30,
    this.recordsAMinute = 240,
    this.newRelaysAnHour = 8,
    HomeBook? homes,
  })  : _now = now ?? DateTime.now,
        _random = random ?? Random.secure(),
        guard = guard ?? DialGuard(plain: config.plain, ports: config.ports, now: now),
        homes = homes ?? HomeBook(file: dataDir == null || config.mode == FedMode.off ? null : File('${dataDir.path}/homes.json'), now: now) {
    _dial = dial ?? this.guard.dial;
    // Off, nothing at all: no key is made or read, and no file is touched.
    if (!on) return;
    _loadKey();
    this.homes.load();
  }

  /// Where `relay-key.json` and `homes.json` are kept; null keeps the key in memory and nothing across restarts.
  final Directory? dataDir;
  final FedConfig config;
  final bool verbose;
  final DateTime Function() _now;
  final Random _random;

  /// What every address is held to before it is dialled, and the dials a minute of each kind (fed_dial.dart).
  final DialGuard guard;
  late final FedDial _dial;

  /// The home records held.
  final HomeBook homes;

  /// The most links open at once, to and from other relays together.
  final int maxLinks;

  /// The most other relays anything waits for at once.
  final int maxPeers;

  /// What waits here for one relay: so many packets, so many bytes, for so long (an address never once linked with,
  /// [neverLinkedFor]).
  final int queuePackets;
  final int queueBytes;
  static const queueFor = Duration(days: 7);

  /// What waits here for all of them together, in bytes: packets for relays not linked right now. A quarter of it at
  /// most is what other relays had this one keep (whether their relay is linked or not), so no other relay can use up
  /// the room this relay's own people's packets wait in. What is on its way over an open link is counted with it, held
  /// to twice this for everything together, so nothing that waits can stop what can go now. One sender, and one
  /// recipient, have a mailbox's worth of it at most ([Hub.mailboxFrames], [Hub.mailboxBytes]): no more is ever kept
  /// for one person at the far end.
  final int queuedBytes;

  /// What one packet costs held here besides its bytes, counted with them: the packet's own object, its sender's and
  /// recipient's names, when it came, the answer it carries, its place in the queue. About 290 bytes for a packet of
  /// one byte, measured in the review (146 MB for 512,000, when each was counted as 65); counted with room to spare.
  static const perPacket = 384;

  /// How many records one signed-in install may have checked in an hour (a check is several milliseconds of
  /// arithmetic), and how many this relay checks in any one second for everyone together. A linked relay at an address
  /// this relay has checked has ten times an install's; all the relays with none share one install's.
  final int checksAnHour;
  final int checksASecond;

  /// How many relays not yet seen at their address may say hello in a minute, together: each costs a look at that
  /// address. A relay whose address this relay has seen its key at has this many of its own.
  final int hellosAMinute;

  /// How many records one linked relay may give in a minute.
  final int recordsAMinute;

  /// How many relays an install may make this one dial for the first time in an hour: with a packet, or a name asked.
  final int newRelaysAnHour;

  /// A link nothing has crossed for this long is closed; it is opened again when next needed.
  static const idleFor = Duration(minutes: 10);

  /// How long a sender waits to hear what the other relay said before it is told its packet is kept.
  static const answerWithin = Duration(seconds: 4);

  /// How long a hello, a look at an address, or a name asked after may take.
  static const helloWithin = Duration(seconds: 10);
  static const whoisWithin = Duration(seconds: 8);

  /// A link whose relay has not answered a packet for this long is closed and made again.
  static const stuckAfter = Duration(seconds: 30);

  /// How long the key seen at an address is believed without looking again: a relay given a new key there is seen
  /// with it within the hour (sooner, where it dials this one: a key seen five minutes ago is looked at again).
  static const believedFor = Duration(hours: 1);

  /// An address never once linked with is tried this long (and four times) and then given up on, what waits for it
  /// told it can't be reached, and not dialled again for [deadFor].
  static const neverLinkedFor = Duration(minutes: 2);
  static const deadFor = Duration(minutes: 10);

  /// An address where a look at the key it shows came to nothing is not looked at again for this long.
  static const lookedNoFor = Duration(minutes: 10);

  /// How many packets are on a link at once waiting to be answered.
  static const window = 64;

  /// How many names may be waiting on one relay's answer.
  static const asksWaiting = 64;

  /// What a dialling relay signs: these words, the hub's number (32 bytes), its own name, the name of the relay it
  /// dialled (16 bytes each), the number it made up (32 bytes), whether it means to stay linked (a byte, 1 or 0), the
  /// address it dialled, and the address it claims (each a byte of its length, then it; empty for none).
  static const dialWords = 'ghost-fed-dial v2 ';

  /// What the relay dialled signs back: these words, the dialler's number, the dialler's name, its own, and the
  /// address it was dialled at (a byte of its length, then it).
  static const answerWords = 'ghost-fed v2 ';

  /// A packet one relay passes to another for someone there, and one for someone on a relay linked to it.
  static const toRelay = 5;
  static const toRelayVia = 6;

  /// [text] as it is signed: a byte of its length, then its bytes (255 at most).
  static List<int> _sized(String text) {
    final bytes = utf8.encode(text);
    return [bytes.length.clamp(0, 255), ...bytes.take(255)];
  }

  /// The bytes a dialling relay signs ([dialWords]), and those the relay it dialled signs back ([answerWords]). Names
  /// are 32 hex digits; [nonce] and [c] are the 32-byte numbers the hub and the dialler made up.
  static List<int> dialBytes({required List<int> nonce, required String dialler, required String answerer, required List<int> c, required String dialled, required String url, bool stay = false}) =>
      [...utf8.encode(dialWords), ...nonce, ..._unhex(dialler), ..._unhex(answerer), ...c, stay ? 1 : 0, ..._sized(dialled), ..._sized(url)];

  static List<int> answerBytes({required List<int> c, required String dialler, required String answerer, required String dialled}) => [...utf8.encode(answerWords), ...c, ..._unhex(dialler), ..._unhex(answerer), ..._sized(dialled)];

  /// How long before a relay that could not be reached is tried again, after so many failures in a row: five seconds,
  /// then twice as long each time, ten minutes at most.
  static Duration backoff(int failures) => Duration(seconds: (5 * (1 << (failures - 1).clamp(0, 10))).clamp(5, 600));

  /// How long a relay that said this one is over its limit is left alone, after so many such answers in a row: 15
  /// seconds, then twice as long each time, an hour at most; then one packet goes alone, to see.
  static Duration pauseAfter(int limits) => Duration(seconds: (15 * (1 << (limits - 1).clamp(0, 8))).clamp(15, 3600));

  /// A relay that answered no is not asked again for this long.
  static const refusedFor = Duration(minutes: 10);

  /// Whether [text] is exactly [length] lowercase hex digits, and the bytes such text writes.
  static final _hexOnly = RegExp(r'^[0-9a-f]+$');
  static bool _hex(Object? text, int length) => text is String && text.length == length && _hexOnly.hasMatch(text);
  static List<int> _unhex(String text) => [for (var i = 0; i + 1 < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)];

  // --- who this relay is ---------------------------------------------------------------------------------------------

  /// This relay's private key (32 bytes): read from `relay-key.json`, or made and written there.
  late List<int> _scalar;

  /// This relay's public key (33 bytes) and its name. Made only where federation is on.
  late final List<int> key;
  late final String id;

  File? get _keyFile => dataDir == null ? null : File('${dataDir!.path}/relay-key.json');

  /// Thirty-two bytes that are a private key: above nothing, below the curve's order.
  List<int> _freshScalar() {
    while (true) {
      final bytes = [for (var i = 0; i < 32; i++) _random.nextInt(256)];
      final v = bytes.fold(BigInt.zero, (BigInt v, b) => (v << 8) | BigInt.from(b));
      if (v > BigInt.zero && v < P256.n) return bytes;
    }
  }

  /// Reads the key kept in `relay-key.json`, or makes one and writes it there; sets [key] and [id] from it.
  void _loadKey() {
    final file = _keyFile;
    List<int>? scalar;
    if (file != null && file.existsSync()) {
      try {
        final kept = (jsonDecode(file.readAsStringSync()) as Map)['scalar'];
        if (_hex(kept, 64)) {
          final v = BigInt.parse(kept as String, radix: 16);
          if (v > BigInt.zero && v < P256.n) scalar = _unhex(kept);
        }
      } catch (_) {}
      if (scalar == null) {
        // A key file that can't be read is put aside, not written over: the relay gets a new name, and says so.
        final aside = '${file.path}.broken-${_now().millisecondsSinceEpoch}';
        try {
          file.renameSync(aside);
        } catch (_) {}
        stderr.writeln('relay: relay-key.json could not be read; kept as ${aside.split('/').last}, and a new key made (this relay has a new name)');
      }
    }
    final made = scalar == null;
    _scalar = scalar ?? _freshScalar();
    key = P256.publicOf(_scalar);
    id = Hub.nameOf(key);
    if (made && file != null) {
      try {
        file.parent.createSync(recursive: true);
        writePrivately(file, jsonEncode({'v': 1, 'id': id, 'key': base64Encode(key), 'scalar': hexOf(_scalar)}));
      } catch (e) {
        stderr.writeln('relay: relay-key.json could not be written (${'$e'.split('\n').first}); this relay\'s key lasts until it stops');
      }
    }
  }

  /// Writes [text] to [file] so that only the relay's own user can read it (mode 600): the file is made empty, its mode
  /// set, and only then written. Nothing is changed for the rest of the process (inside the app, other threads' files
  /// are made as they always were). Where the mode can't be set it is written anyway and said loudly, for the keeper to
  /// set; on Windows a file has no such mode, and it is an ordinary file (docs/SELF_HOSTING.md says so).
  static void writePrivately(File file, String text) {
    final tmp = File('${file.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
    tmp.createSync();
    if (!Platform.isWindows && !onlyOwner(tmp.path)) {
      stderr.writeln('relay: WARNING: ${file.path} could not be made readable by this user alone (mode 600), and is written anyway: anyone who can read it can speak as this relay. Set its mode yourself (chmod 600).');
    }
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(file.path);
  }

  /// Makes [path] readable and writable by its owner alone (mode 600), with the C library's own chmod or else the
  /// program of that name; whether it is so now, by the file's own mode.
  static bool onlyOwner(String path) {
    bool done() {
      try {
        return FileStat.statSync(path).mode & 0x1ff == 0x180;
      } catch (_) {
        return false;
      }
    }

    try {
      final lib = ffi.DynamicLibrary.process();
      final malloc = lib.lookupFunction<ffi.Pointer<ffi.Uint8> Function(ffi.IntPtr), ffi.Pointer<ffi.Uint8> Function(int)>('malloc');
      final free = lib.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Uint8>), void Function(ffi.Pointer<ffi.Uint8>)>('free');
      final chmod = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<ffi.Uint8>, ffi.Uint32), int Function(ffi.Pointer<ffi.Uint8>, int)>('chmod');
      final bytes = utf8.encode(path);
      final p = malloc(bytes.length + 1);
      if (p.address != 0) {
        p.asTypedList(bytes.length + 1)
          ..setAll(0, bytes)
          ..[bytes.length] = 0;
        chmod(p, 0x180);
        free(p);
      }
    } catch (_) {}
    if (done()) return true;
    try {
      Process.runSync('chmod', ['600', path]);
    } catch (_) {}
    return done();
  }

  /// A signature of this relay's over [message], with a number of its own made for it and never used again.
  List<int> _sign(List<int> message) => P256.sign(_scalar, message, _freshScalar());

  /// What a hub's hello says to prove this relay holds the key its card names, for the connection with the hub's number
  /// [nonce], reached as [reachedAs] (the node id dialled over Direct, or the relay's name in memory): this relay's
  /// signature over the words `ghost-hub relay v1 `, the number and that ([reachedMessage]). An app dialling `ghost-relay://<name>?n=<node>` checks it
  /// against the key, the name and the node it dialled, so a node that copies another relay's public card is no
  /// better than a node that says nothing (found in the third review, 2026-11-23). Null where federation is off.
  List<int>? signReached(List<int> nonce, String reachedAs) => !on ? null : _sign(reachedMessage(nonce, reachedAs));

  /// What [signReached] signs.
  static List<int> reachedMessage(List<int> nonce, String reachedAs) => [...utf8.encode('ghost-hub relay v1 '), ...nonce, ...utf8.encode(reachedAs.toLowerCase())];

  /// Whether this relay links with others at all.
  bool get on => config.mode != FedMode.off;

  /// This relay has no address of its own and stays linked to a public one: everything not for its own people goes
  /// through that link.
  bool get _hosted => on && config.via.isNotEmpty && config.publicHub.isEmpty;

  /// What the hub's hello says of this relay: its name and key, its own address where it claims one, the relay it
  /// stays linked to where it does, and whether it talks to other relays (`fed`). Nothing where federation is off: the
  /// hello is the one it always was. A relay with no address of its own reaches others only through its link to via,
  /// so it says `fed` only while that link is up and via has said it may stay (found in the second review, 2026-11-23:
  /// it said so whatever via answered, and its people's apps said messages crossed to other relays when none could).
  Map<String, Object?>? get card => !on ? null : {'id': id, 'key': base64Encode(key), if (config.publicHub.isNotEmpty) 'url': config.publicHub, if (config.via.isNotEmpty) 'via': config.via, 'fed': !_hosted || (viaLink?.stays ?? false)};

  /// A line for the keeper's log, written only where the relay was started verbose.
  void _say(String what) {
    // Never an address of a person's, never a whole name.
    if (verbose) stdout.writeln('${_now().toIso8601String()} fed $what');
  }

  // --- what the hub gives it ------------------------------------------------------------------------------------------

  /// What the hub gave in [bind]. Until then nothing is handed over, nobody is here and no number is its own.
  bool? Function(String to, String from, List<int> packet) _deliver = (_, _, _) => null;
  bool Function(String id) _isHere = (_) => false;
  bool Function(String id) _knows = (_) => false;
  bool Function(String hello) _ownNumber = (_) => false;
  Handles? _handles;

  /// Told by the hub it serves ([Hub]) how a packet is handed to someone here ([Hub.deliver]), who is here, who has
  /// signed in here at all ([knows]: packets from other relays are kept only for them), whether a number is one its own
  /// hub made up for a hello it is still waiting on ([ownNumber]: how this relay knows itself when it dials itself), and
  /// who keeps the usernames.
  void bind({required bool? Function(String to, String from, List<int> packet) deliver, required bool Function(String id) isHere, bool Function(String id)? knows, bool Function(String hello)? ownNumber, Handles? handles}) {
    _deliver = deliver;
    _isHere = isHere;
    _knows = knows ?? isHere;
    _ownNumber = ownNumber ?? (_) => false;
    _handles = handles;
  }

  /// The once-a-second clock ([tick]), the write of the records that is due ([_changed]), and whether [stop] was called.
  Timer? _ticker;
  Timer? _saver;
  bool _stopped = false;

  /// Starts its clock: once a second it does what is due ([tick]), and a relay with a `via` dials it.
  void start() {
    for (final p in config.problems) {
      stderr.writeln('relay: $p');
    }
    if (!on) return;
    _stopped = false;
    if (config.publicHub.isEmpty && config.via.isEmpty) {
      stderr.writeln('relay: GHOST_FED is on, but GHOST_PUBLIC_HUB is not set: this relay can ask other relays who someone is, but can\'t pass its people\'s packets to them, and takes no other relay\'s hello');
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => tick());
    tick();
  }

  /// Stops: nothing more is dialled or taken, and every link, hello under way and look at an address is closed. A dial
  /// already under way is let go as soon as it is made.
  void stop() {
    _stopped = true;
    _ticker?.cancel();
    _ticker = null;
    _saver?.cancel();
    _saver = null;
    if (on) homes.saveNow();
    for (final hello in _hellosOut.toList()) {
      hello.done = true;
      hello.socket.close(WebSocketStatus.goingAway);
    }
    _hellosOut.clear();
    for (final look in _looks.toList()) {
      look.socket.close(WebSocketStatus.goingAway);
    }
    _looks.clear();
    for (final l in _links.toList()) {
      l.socket.close(WebSocketStatus.goingAway);
      _lost(l);
    }
    for (final peer in _peers.values) {
      peer.dialling = false;
    }
  }

  /// The records held may have changed: where they have, they are written to their file in two seconds, once for
  /// everything that changes meanwhile.
  void _changed() {
    if (homes.file == null || !homes.dirty) return;
    _saver ??= Timer(const Duration(seconds: 2), () {
      _saver = null;
      unawaited(homes.save());
    });
  }

  // --- who may link ---------------------------------------------------------------------------------------------------

  /// Whether [list] (the keeper's allow or block) names this relay: by its name, by its address's host or host and
  /// port, or by the name of the relay this one saw at that address.
  bool _listed(Set<String> list, {String? relay, Uri? url}) {
    if (relay != null && list.contains(relay)) return true;
    if (url == null) return false;
    final port = url.hasPort ? url.port : (url.scheme == 'wss' ? 443 : 80);
    if (list.contains(url.host) || list.contains('${url.host}:$port')) return true;
    // The relay this relay has seen at that address, by its key, where the list names it.
    final seen = _seenAt['$url'];
    if (seen != null && _now().difference(seen.at) < believedFor) {
      try {
        if (list.contains(Hub.nameOf(base64Decode(seen.key)))) return true;
      } catch (_) {}
    }
    return false;
  }

  /// Whether this relay links with the one named [relay] (where its name is known) at [url] (where it has one).
  /// [toLearn]: an address about to be dialled, whose relay's name is learnt only there; with a list that names
  /// relays by name it is dialled, and left at once where the relay there is not one of them.
  bool _mayLink({String? relay, Uri? url, bool toLearn = false}) {
    if (!on || _listed(config.block, relay: relay, url: url)) return false;
    if (url != null && config.via.isNotEmpty && '$url' == config.via) return true;
    if (config.mode == FedMode.open || _listed(config.allow, relay: relay, url: url)) return true;
    return toLearn && relay == null && config.allow.any(FedConfig._relayName.hasMatch);
  }

  /// Whether the relay named [relay] may stay linked to this one, its people reached and their packets passed on.
  bool _mayStand(String relay) => (config.standingOpen || config.standing.contains(relay)) && _mayLink(relay: relay);

  // --- limits ---------------------------------------------------------------------------------------------------------

  /// What is counted: for each linked relay (by [_whoOf]), record checks for each giver and for everyone this second,
  /// hellos from relays not yet seen at their address, and for each install signed in here. Each map is kept to so
  /// many, the one used longest ago let go first.
  final Map<String, _Meter> _meters = {};
  final Map<String, _Checks> _checks = {};
  final _Count _checksNow = _Count();
  final _Count _hellos = _Count();
  final Map<String, _Sender> _senders = {};

  /// Who a link's relay is, as allowances are counted: its address where this relay has checked one (`u:`), its name
  /// where its keeper listed it to stay (`r:`), else one of all the relays with no address (`*`), which share one
  /// allowance between them: a key is free to make.
  String _whoOf(_Link link) => link.url != null ? 'u:${link.url}' : (link.standing && config.standing.contains(link.id) ? 'r:${link.id}' : '*');

  /// The counts for one linked relay, by [_whoOf]; 1024 are kept.
  _Meter _meter(String who) {
    final m = _meters.remove(who) ?? _Meter();
    _meters[who] = m;
    while (_meters.length > 1024) {
      _meters.remove(_meters.keys.first);
    }
    return m;
  }

  /// The counts for one install signed in here; 50,000 are kept.
  _Sender _sender(String id) {
    final s = _senders.remove(id) ?? _Sender();
    _senders[id] = s;
    while (_senders.length > 50000) {
      _senders.remove(_senders.keys.first);
    }
    return s;
  }

  /// What one place has done across relays lately, all its installs together (a place: an IPv4 address, or an IPv6
  /// address's first 48 bits, as the hub counts it: hub.dart, placeOf; through the proxy in front, the address that
  /// proxy saw). Installs cost nothing to make, so a share kept per install alone was a share for however many installs
  /// one person made (found in the second review, 2026-11-23: four new installs a minute asking for names at hosts that
  /// don't exist used up the relay's dials, and eight a day of bytes at another relay). One place has twice one
  /// install's share; a connection made in this program (a test's, or none) has the place ''.
  final Map<String, _Sender> _origins = {};

  /// The counts for one place; null for a connection that has none.
  _Sender? _origin(String place) {
    if (place.isEmpty) return null;
    final o = _origins.remove(place) ?? _Sender();
    _origins[place] = o;
    while (_origins.length > 50000) {
      _origins.remove(_origins.keys.first);
    }
    return o;
  }

  /// What installs not yet established here ([established]) have used together: half at most of the new relays this
  /// relay dials in a minute, and of what may go to each relay in a minute and a day, so the rest is always there for
  /// those who are.
  final _Count _strangerRelays = _Count();

  /// How long an install must have held a username here, or given its own record here, to be established.
  static const establishedAfter = Duration(days: 2);

  /// Whether [id] is established here: it has held a username here, or kept its own record here, for
  /// [establishedAfter] (both as this relay saw them, never as the install says).
  bool established(String id) {
    final now = _now();
    final named = _handles?.nameHeldSince(id);
    if (named != null && now.difference(named) >= establishedAfter) return true;
    final since = homes.ownSince(id);
    return since != null && now.difference(since) >= establishedAfter;
  }

  /// Takes a record someone gave, where it checks out and is newer: `kept`, `held` (nothing newer in it), `busy` (too
  /// many checks just now: give it again later), or why it is not a record at all (`old` for one past its end). What
  /// costs nothing is looked at first: the very record held already, then its shape and time; then the giver's own
  /// count of checks ([perHour] an hour: an install's own, or a linked relay's; and a quarter of [checksASecond] in
  /// any second, half for a relay at a checked address, so no one giver can use up a second), then everyone's
  /// ([checksASecond]), and only then the signature.
  String _takeRecord(Object? json, {required String from, bool byOwner = false, int? perHour}) {
    if (json is! Map) return 'shape';
    final a = json['a'], n = json['n'], s = json['s'];
    // The very record held already needs no checking again: what an app says at every sign-in.
    if (a is String && n is int && s is String && s.length <= 128) {
      try {
        if (homes.holds(a, n, base64Decode(s))) {
          final held = homes.of(a)!;
          if (byOwner && a == from) {
            homes.keep(held, byOwner: true);
            _changed();
          }
          return 'held';
        }
      } catch (_) {}
    }
    final shape = HomeRecord.read(json, now: _now(), verify: false);
    if (shape.rec == null) return shape.err!;
    if (shape.rec!.t > _now().add(HomeRecord.ahead).millisecondsSinceEpoch) return 'future';
    final held = homes.of(shape.rec!.a);
    // Not newer than what is held: nothing to check.
    if (held != null && !shape.rec!.newerThan(held) && !(byOwner && shape.rec!.a == from)) return 'held';
    final now = _now();
    final own = _checks.remove(from) ?? _Checks();
    _checks[from] = own;
    while (_checks.length > 50000) {
      _checks.remove(_checks.keys.first);
    }
    final hourly = perHour ?? checksAnHour;
    if (!own.hour.take(now, const Duration(hours: 1), hourly)) return 'busy';
    if (!own.second.take(now, const Duration(seconds: 1), max(1, hourly > checksAnHour ? checksASecond ~/ 2 : checksASecond ~/ 4))) {
      own.hour.back();
      return 'busy';
    }
    if (!_checksNow.take(now, const Duration(seconds: 1), checksASecond)) {
      own.hour.back();
      own.second.back();
      return 'busy';
    }
    final read = HomeRecord.read(json, now: now);
    final rec = read.rec;
    if (rec == null) return read.err!;
    final kept = homes.keep(rec, byOwner: byOwner && rec.a == from);
    _changed();
    return kept ? 'kept' : 'held';
  }

  // --- what an app says -------------------------------------------------------------------------------------------------

  /// Whether what an app said is federation's to answer: a home record given or asked for, or a name on another relay.
  /// The hub asks only where federation is on; off, they are answered as a relay from before answers them.
  static bool takes(Map said) => said['dir'] == 'home' || said['dir'] == 'home?' || (said['dir'] == 'whois' && said['at'] is String);

  /// Something the signed-in install [id] said that [takes] is true of; the answer goes to [tell].
  void said(String id, Map said, void Function(Map<String, Object?>) tell, {String place = ''}) {
    switch (said['dir']) {
      case 'home':
        // Its own record, or a friend's so this relay can route to them: kept where it checks out and is newer.
        final rec = said['rec'];
        final a = rec is Map && rec['a'] is String ? rec['a'] as String : null;
        final took = _takeRecord(rec, from: id, byOwner: true);
        if (took == 'kept' || took == 'held') {
          final n = a == null ? null : homes.of(a)?.n;
          tell(n == null ? {'dir': 'home', 'a': ?a, 'ok': false, 'err': 'bad'} : {'dir': 'home', 'a': a, 'ok': true, 'n': n});
        } else {
          tell({'dir': 'home', 'a': ?a, 'ok': false, 'err': took == 'busy' || took == 'old' ? took : 'bad'});
        }
      case 'home?':
        // One's own record, as held here; nobody is told anyone else's (relays ask each other over links, and a
        // username's holder is told with the username).
        final a = said['a'];
        final rec = a == id ? homes.of(id) : null;
        tell({'dir': 'home?', 'a': a, if (rec == null) 'none': true else 'rec': rec.toJson()});
      case 'whois':
        _whoisFromApp(id, said, tell, place);
    }
  }

  /// [m], an answer to `whois` for a username here, with the holder's record where one is held: what someone on
  /// another relay needs to be friends with them, and what a linked relay is told already.
  Map<String, Object?> withHome(Map<String, Object?> m) {
    final id = m['id'];
    if (!on || m['dir'] != 'whois' || id is! String || m.containsKey('home')) return m;
    final rec = homes.of(id);
    return rec == null ? m : {...m, 'home': rec.toJson()};
  }

  /// Names asked after by each install, counted here only where there are no handles to count them.
  final Map<String, _Count> _lookups = {};

  /// The existing limit on lookups ([Handles.lookupsAnHour]), kept by the handles where there are any.
  bool _mayLookUp(String id) {
    final h = _handles;
    if (h != null) return h.mayLookUp(id);
    final c = _lookups.remove(id) ?? _Count();
    _lookups[id] = c;
    while (_lookups.length > 50000) {
      _lookups.remove(_lookups.keys.first);
    }
    return c.take(_now(), const Duration(hours: 1), Handles.lookupsAnHour);
  }

  /// Whether [id] (an install signed in here, from [place]) may make this relay dial one more relay for the first time,
  /// and that it has: [newRelaysAnHour] an hour for the install, twice that for its place, and where it is not
  /// established, half of the dials a minute for all such together. Counted only where all of them allow it.
  bool _mayAddRelay(String id, String place) {
    final now = _now(), hour = const Duration(hours: 1);
    final mine = _sender(id).relays, theirs = _origin(place)?.relays;
    if (!mine.take(now, hour, newRelaysAnHour)) return false;
    if (theirs != null && !theirs.take(now, hour, newRelaysAnHour * 2)) {
      mine.back();
      return false;
    }
    if (!established(id) && !_strangerRelays.take(now, const Duration(minutes: 1), max(1, guard.dialsAMinute ~/ 2))) {
      mine.back();
      theirs?.back();
      return false;
    }
    return true;
  }

  /// The hub's address `at` names (`relay.example`, or with a port): `wss://relay.example/hub`. Null where it is not
  /// a host.
  static String? hubAt(String at) {
    final host = at.trim().toLowerCase();
    if (host.isEmpty || host.length > 120 || !FedConfig._hostAndPort.hasMatch(host)) return null;
    return canonicalHub('wss://$host/hub');
  }

  /// The reasons an app is given with `none`; anything else another relay says for a reason is left out.
  static const _whys = {'off', 'refused', 'down', 'busy'};

  /// `{"dir":"whois","name":"maya","at":"relay.example"}`: who has that username on that relay. Asked of it over a
  /// link, and answered with what was asked (`name`, `at`) and `id`, `key`, and `home` where that relay holds their
  /// record; or `none`, with `why` where it is not that nobody has the name: `off` (this relay doesn't talk to that
  /// one), `refused` (that one won't talk to this), `down` (it couldn't be reached), `busy`.
  void _whoisFromApp(String asker, Map said, void Function(Map<String, Object?>) tell, String place) {
    final name = said['name'], at = said['at'];
    Map<String, Object?> none([Object? why]) => {'dir': 'whois', 'name': name is String ? Handles.tidyName(name) : name, 'at': at, 'none': true, if (_whys.contains(why)) 'why': why};
    final url = at is String ? hubAt(at) : null;
    if (name is! String || !Handles.goodName(name) || url == null) return tell(none());
    // This relay itself: an ordinary lookup, under its own limit, answered with what was asked.
    if (_isSelfUrl(url)) {
      final h = _handles;
      if (h == null) return tell(none());
      unawaited(h.said(asker, {'dir': 'whois', 'name': name}, (m) => tell(m['dir'] == 'whois' ? {...withHome(m), 'at': at, 'here': true} : (m['dir'] == 'err' ? {...m, 'at': at} : m))));
      return;
    }
    if (!_mayLookUp(asker)) return tell({'dir': 'err', 'about': 'whois', 'at': at, 'err': 'Too many lookups. Try again in a while.'});
    final uri = Uri.parse(url);
    if (_stopped || !_mayLink(url: uri, toLearn: true) || guard.shape(uri) != null) return tell(none('off'));
    if (_deadNow(url)) return tell(none('down'));
    var peer = _peers['u:$url'];
    if (peer == null) {
      if (!_mayAddRelay(asker, place)) return tell(none('busy'));
      peer = _peerAt(url);
      if (peer == null) return tell(none('busy'));
    }
    if (_refusedNow(peer)) return tell(none('refused'));
    // Not reachable a moment ago, and not due to be tried again yet: said now, not after a wait.
    if (_linkFor(peer) == null && !peer.dialling && peer.nextTry != null && _now().isBefore(peer.nextTry!)) return tell(none('down'));
    if (peer.asks.length >= asksWaiting) return tell(none('busy'));
    peer.asks.add(_Ask(Handles.tidyName(name), _now(), (m) {
      final id = m['id'], key = m['key'];
      if (m['none'] == true || id is! String || key is! String) return tell(none(m['why']));
      // Nothing is taken on that relay's say-so but which key holds the name: it must be a key, and the name its.
      try {
        final k = base64Decode(key);
        if (!P256.isKey(k) || Hub.nameOf(k) != id) return tell(none());
      } catch (_) {
        return tell(none());
      }
      // Their record, where that relay gave one that is theirs: kept here too, so a packet to them can be routed.
      Map<String, Object>? home;
      final rec = m['home'];
      if (rec is Map && rec['a'] == id && rec['k'] == key) {
        final took = _takeRecord(rec, from: 'relay:u:${peer!.url}', perHour: checksAnHour * 10);
        if (took == 'kept' || took == 'held') home = homes.of(id)?.toJson();
      }
      tell({'dir': 'whois', 'name': Handles.tidyName(name), 'at': at, 'id': id, 'key': key, 'home': ?home});
    }));
    peer.lastUsed = _now();
    _pump(peer);
  }

  // --- passing a packet on ----------------------------------------------------------------------------------------------

  /// The relays something waits for, by `u:<address>` or `r:<name>`; what waits from each sender, over all of them;
  /// and the bytes waiting in all (as counted), and those of them other relays had this one keep.
  final Map<String, _Peer> _peers = {};
  final Map<String, _Share> _waitingFrom = {};
  int _queued = 0;
  int _queuedForOthers = 0;

  /// How much waits here for other relays, in bytes as counted (each packet with [perPacket]), and for how many.
  int get waiting => _queued;
  int waitingFor(String url) => _peers['u:$url']?.queue.length ?? 0;
  int waitingForRelay(String relay) => _peers['r:$relay']?.queue.length ?? 0;

  /// How many links are open, and whether one is with the relay named [relay].
  int get links => _links.length;
  bool linkedWith(String relay) => _links.any((l) => l.id == relay && l.socket.isOpen);

  /// How it stands with the relay this one stays linked to ([FedConfig.via]), for whoever runs it to see (a relay hosted
  /// from the app shows it: the app's lib/relay_host): whether the link is up, and whether that relay said this one may
  /// stay, its people reached over the link (`stays`); where it is not up, why the last dial came to nothing (`why`:
  /// `down` where nothing answered, else what the relay that answered no said, as one with federation off answers "not a
  /// relay that talks to others") and when it is dialled next. Null where there is no via. Asking changes nothing.
  ({bool linked, bool stays, String? why, DateTime? next})? get viaLink {
    if (!on || config.via.isEmpty) return null;
    final peer = _peers['u:${config.via}'];
    final link = peer == null ? null : _linkFor(peer);
    if (link != null) return (linked: true, stays: peer!.stays, why: null, next: null);
    return (linked: false, stays: false, why: peer?.why, next: peer?.nextTry);
  }

  /// Addresses that turned out to be this relay's own when it dialled them ([_isMe]), and when: remembered for
  /// [believedFor].
  final Map<String, DateTime> _selfUrls = {};

  /// Whether [url], or the place [a] names (an address, or a relay's name where it has none), is this relay.
  bool _isSelfUrl(String url) => url == config.publicHub || _selfUrls.containsKey(url);
  bool _isSelf(HomeAddress a) => a.url != null ? _isSelfUrl(a.url!) : a.relay == id;

  /// The relay waited on at [url], made where there is room for one more.
  _Peer? _peerAt(String url) => _peer('u:$url', url: Uri.parse(url));

  /// A relay with no address, known by its name alone: one that dials this relay and stays linked.
  _Peer? _peerNamed(String relay) => _peer('r:$relay', relay: relay);

  /// The relay waited on under [key], made where there is none yet; null where [maxPeers] are waited on already and
  /// none of them can go.
  _Peer? _peer(String key, {Uri? url, String? relay}) {
    final had = _peers[key];
    if (had != null) return had;
    if (_peers.length >= maxPeers) {
      // Room is made by letting go of one nothing waits for and nothing is linked to.
      final idle = _peers.values.where((p) => p.idle && _linkFor(p) == null && p.key != 'u:${config.via}').toList()..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
      if (idle.isEmpty) return null;
      _peers.remove(idle.first.key);
    }
    final now = _now();
    return _peers[key] = _Peer(key, url: url, relay: relay, lastUsed: now, made: now, everLinked: url == null || _linkedOnce.containsKey('$url'));
  }

  /// Whether [peer] said no within [refusedFor].
  bool _refusedNow(_Peer peer) => peer.refusedUntil != null && _now().isBefore(peer.refusedUntil!);

  /// Whether [url] was given up on a moment ago: never once linked with, and nothing answered there.
  bool _deadNow(String url) {
    final until = _dead[url];
    return until != null && _now().isBefore(until);
  }

  /// Where a packet for the account [rec] would go: null for "here, as before" (the record names this relay), else the
  /// relay to pass it to (by its address, or by its name for one that stays linked to this one) and how;
  /// [_Target.nowhere] where it names nowhere this relay will pass it. Nothing is made by asking.
  _Target? _targetOf(HomeRecord rec, {bool forStanding = false}) {
    final addresses = rec.addresses;
    if (addresses.any(_isSelf)) return null;
    // A relay with no address of its own: everything else goes through the relay it stays linked to.
    if (_hosted) return _Target(url: config.via, kind: toRelay);
    for (final a in addresses) {
      final url = a.url ?? a.via;
      if (url == null) continue;
      if (a.url == null && _isSelfUrl(url)) {
        // Someone on a relay that stays linked to this one: over that link, or kept for it, where it may stay.
        if (!_mayStand(a.relay!)) continue;
        return _Target(named: a.relay, kind: toRelay);
      }
      // What a relay linked to this one sent is passed to the relay its person lives on, never to a relay linked to
      // that one: two links at most.
      if (a.url == null && forStanding) continue;
      final uri = Uri.parse(url);
      if (!_mayLink(url: uri, toLearn: true) || guard.shape(uri) != null) continue;
      return _Target(url: url, kind: a.url == null ? toRelayVia : toRelay, relay: a.url == null ? a.relay : null);
    }
    return _Target.nowhere;
  }

  /// Takes a packet from [from] (someone signed in here) for [to], whom nobody is connected as here, where [to]'s home
  /// record names another relay: it is passed to that relay, or waits here for it. False where it is not this one's
  /// to pass on (no record, or the record names this relay): the hub keeps it, as it always did.
  ///
  /// [answer] is told once what became of it: taken (`here` false: the other relay took it, and whether they are
  /// there is not said across relays), kept here for that relay (`here` null: it waits until that relay is reached), or
  /// with `err` why not: `home` (no record of
  /// the sender's naming this relay is held: their app gives it, and sends again), `busy` (the sender is past what one
  /// install may send across relays, or may make this relay dial), `full`, `far` (their relay is one this relay
  /// doesn't or can't pass to), `refused`.
  bool pass(String to, String from, List<int> packet, void Function(bool? here, [String? err]) answer, {String place = ''}) {
    if (!on || _stopped) return false;
    final rec = homes.of(to);
    if (rec == null) return false;
    final target = _targetOf(rec);
    if (target == null) return false;
    if (target.far) {
      answer(null, 'far');
      return true;
    }
    // A relay speaks only for its own people: without a record of the sender's that names this one, no other relay
    // would take it. Said now, not after it had waited for nothing.
    final theirs = homes.of(from);
    if (theirs == null || !theirs.addresses.any(_isSelf)) {
      answer(null, 'home');
      return true;
    }
    final now = _now(), minute = const Duration(minutes: 1), day = const Duration(days: 1);
    final size = packet.length + perPacket;
    final mine = _sender(from), origin = _origin(place);
    // The install's share of what this relay may send others, and its place's twice that: counted where both allow.
    if (!mine.packets.take(now, minute, max(1, config.packetsAMinute ~/ 4))) {
      answer(null, 'busy');
      return true;
    }
    if (!mine.bytes.take(now, day, max(1, config.bytesADay ~/ 8), by: size)) {
      mine.packets.back();
      answer(null, 'busy');
      return true;
    }
    if (origin != null) {
      final packetOk = origin.packets.take(now, minute, max(1, config.packetsAMinute ~/ 2));
      if (!packetOk || !origin.bytes.take(now, day, max(1, config.bytesADay ~/ 4), by: size)) {
        if (packetOk) origin.packets.back();
        mine.packets.back();
        mine.bytes.back(size);
        answer(null, 'busy');
        return true;
      }
    }
    return _send(target, to, from, packet, answer, by: from, place: place);
  }

  /// Sends a packet to where [target] says; [by] is the install signed in here it is from, where it is (packets other
  /// relays had this one pass on are [forStanding]).
  bool _send(_Target target, String to, String from, List<int> packet, void Function(bool? here, [String? err]) answer, {String? by, bool forStanding = false, String place = ''}) {
    if (target.far) {
      answer(null, 'far');
      return true;
    }
    final url = target.url;
    if (url != null && _deadNow(url)) {
      answer(null, 'far');
      return true;
    }
    final key = url != null ? 'u:$url' : 'r:${target.named}';
    var peer = _peers[key];
    if (peer == null) {
      if (by != null && url != null && !_mayAddRelay(by, place)) {
        answer(null, 'busy');
        return true;
      }
      peer = url != null ? _peerAt(url) : _peerNamed(target.named!);
      if (peer == null) {
        answer(null, 'full');
        return true;
      }
    }
    if (_refusedNow(peer)) {
      answer(null, 'far');
      return true;
    }
    // Installs not established here have half of what this relay may send that relay in a minute and in a day, all of
    // them together: the rest is there for those who are, whoever else makes installs.
    if (by != null && !established(by)) {
      final now = _now(), size = packet.length + perPacket;
      if (!peer.strangerPackets.take(now, const Duration(minutes: 1), max(1, config.packetsAMinute ~/ 2))) {
        answer(null, 'busy');
        return true;
      }
      if (!peer.strangerBytes.take(now, const Duration(days: 1), max(1, config.bytesADay ~/ 2), by: size)) {
        peer.strangerPackets.back();
        answer(null, 'busy');
        return true;
      }
    }
    final out = _Out(peer, target.kind, to, from, target.relay, Uint8List.fromList(packet), _now(), answer, forOthers: forStanding);
    final why = _enqueue(peer, out);
    if (why != null) {
      answer(null, why);
      return true;
    }
    _pump(peer);
    return true;
  }

  /// Puts [out] in its relay's queue where there is room; else why not (`full`, or `busy` where it is its sender who
  /// has a mailbox's worth waiting already).
  String? _enqueue(_Peer peer, _Out out) {
    final size = out.size;
    if (peer.queue.length >= queuePackets || peer.bytes + size > queueBytes || _queued + size > 2 * queuedBytes) return 'full';
    // What other relays had this one keep is a quarter of the room at most, linked or not.
    if (out.forOthers && _queuedForOthers + size > queuedBytes ~/ 4) return 'full';
    // With no link to its relay it will wait: held to what may wait.
    if (_linkFor(peer) == null && _queued + size > queuedBytes) return 'full';
    // No more for one recipient than their mailbox at the far end holds, and no more from one sender.
    final toThem = peer.byRecipient[out.to];
    if (toThem != null && (toThem.n >= Hub.mailboxFrames || toThem.bytes + size > Hub.mailboxBytes + Hub.mailboxFrames * perPacket)) return 'full';
    final fromThem = _waitingFrom[out.from];
    if (fromThem != null && (fromThem.n >= Hub.mailboxFrames || fromThem.bytes + size > Hub.mailboxBytes + Hub.mailboxFrames * perPacket)) return 'busy';
    peer.queue.add(out);
    peer.bytes += size;
    (peer.byRecipient[out.to] ??= _Share()).add(size);
    (_waitingFrom[out.from] ??= _Share()).add(size);
    _queued += size;
    if (out.forOthers) _queuedForOthers += size;
    peer.lastUsed = _now();
    return null;
  }

  /// Takes [out] from its relay's queue, from every count [_enqueue] put it in, and off the link it was sent on.
  void _dequeue(_Out out) {
    final peer = out.peer;
    if (!peer.queue.remove(out)) return;
    final size = out.size;
    peer.bytes -= size;
    if (peer.byRecipient[out.to]?.take(size) ?? false) peer.byRecipient.remove(out.to);
    if (_waitingFrom[out.from]?.take(size) ?? false) _waitingFrom.remove(out.from);
    _queued -= size;
    if (out.forOthers) _queuedForOthers -= size;
    out.flying?.flying.removeWhere((_, o) => identical(o, out));
    out.flying = null;
  }

  /// The open link to [peer]: for a relay at an address, the newest this relay dialled there itself (never one that
  /// came in claiming it); for one known by its name, the newest standing link it made.
  _Link? _linkFor(_Peer peer) {
    for (final l in _links.reversed) {
      if (!l.socket.isOpen) continue;
      if (peer.url != null ? (l.outbound && l.url == '${peer.url}') : (l.standing && l.id == peer.relay)) return l;
    }
    return null;
  }

  /// Sends what waits for [peer] over its link, as far as the window allows; with no link, one is asked for.
  void _pump(_Peer peer) {
    final now = _now();
    final link = _linkFor(peer);
    if (link == null) {
      _wantLink(peer);
      // A relay that can only dial this one, or one linked with before that could not be reached a moment ago and is
      // not being tried just now: what is for it is kept, and its sender told so at once, not after a wait that can
      // tell them nothing. (For an address never once linked with, nothing is said to be kept: it waits only a minute
      // or two, and then they are told it can't be reached.)
      if (peer.url == null || (peer.everLinked && peer.failures > 0 && !peer.dialling)) {
        for (final out in peer.queue) {
          out.tell(null);
        }
      }
      return;
    }
    for (final ask in peer.asks) {
      if (ask.sent) continue;
      ask.sent = true;
      ask.q = ++link.seq;
      link.asked[ask.q] = ask;
      _tell(link, {'fed': 'whois', 'q': ask.q, 'name': ask.name});
      link.used = now;
    }
    if (peer.pausedUntil != null && now.isBefore(peer.pausedUntil!)) return;
    for (final out in peer.queue) {
      if (link.flying.length >= window) break;
      // Told it is over its limit: one packet goes alone, to see, before the rest.
      if (peer.probing && link.flying.isNotEmpty) break;
      if (out.flying != null) continue;
      _fly(link, out);
      if (peer.probing) break;
    }
  }

  /// Says [a]'s record on [link] where it is held and has not been said there: so the other relay can see whom this
  /// one speaks for, or where someone lives, without having to refuse first.
  void _give(_Link link, String a, {bool again = false}) {
    final rec = homes.of(a);
    if (rec == null) return;
    final tag = '$a:${rec.n}:${rec.t}';
    if (!again && link.gave.contains(tag)) return;
    link.gave.add(tag);
    while (link.gave.length > 4000) {
      link.gave.remove(link.gave.first);
    }
    _tell(link, {'fed': 'home', 'rec': rec.toJson()});
  }

  /// Sends [out] on [link] under the link's next number: `[kind][number, 4 bytes][to][from]` (16 bytes each), the
  /// hosted relay's name for a `[6]`, then the packet. Its sender's record is said first where it has not been.
  void _fly(_Link link, _Out out) {
    _give(link, out.from);
    // To a relay that must itself find where they live (the relay this one stays linked to, or the one theirs does).
    if (out.kind == toRelayVia || link.isVia) _give(link, out.to);
    final n = link.seq = (link.seq + 1) & 0x7fffffff;
    final head = ByteData(5)
      ..setUint8(0, out.kind)
      ..setUint32(1, n);
    link.flying[n] = out;
    out.flying = link;
    out.sentAt = _now();
    link.used = out.sentAt!;
    try {
      link.socket.add(Uint8List.fromList([...head.buffer.asUint8List(), ..._unhex(out.to), ..._unhex(out.from), if (out.kind == toRelayVia) ..._unhex(out.relay!), ...out.packet]));
    } catch (_) {}
  }

  /// Says [what] on [link] as JSON, where it is still open.
  void _tell(_Link link, Map<String, Object?> what) {
    if (!link.socket.isOpen) return;
    try {
      link.socket.add(jsonEncode(what));
    } catch (_) {}
  }

  /// What the other relay said of a packet sent it.
  void _answered(_Link link, Map m) {
    final acked = m.containsKey('ack');
    final n = acked ? m['ack'] : m['nak'];
    final out = link.flying.remove(n);
    if (out == null) return;
    out.flying = null;
    final peer = out.peer;
    final now = _now();
    if (acked) {
      if (peer.probing) {
        // The packet sent to see went: the rest go again.
        peer.probing = false;
        peer.limits = 0;
      }
      // Taken. Whether they are connected there is not said across relays, whatever that relay says.
      _dequeue(out);
      out.tell(false);
      _pump(peer);
      return;
    }
    switch (m['err']) {
      case 'home' || 'to' || 'moved':
        // Refused for want of a record: of the sender's, naming this relay (`home`); of where the other lives
        // (`to`); or the other relay holds one that says they live elsewhere (`moved`, and it has just said which).
        final about = m['err'] == 'home' ? out.from : out.to;
        if (m['err'] == 'moved' && !out.rerouted) {
          // Routed again by what is held now (the other relay has just said where they live), held to what it was
          // held to the first time: what a relay linked to this one sent goes no further than its person's relay.
          out.rerouted = true;
          final rec = homes.of(out.to);
          final target = rec == null ? null : _targetOf(rec, forStanding: out.forOthers);
          if (rec != null && target == null) {
            // Here, by the newer record: handed over or kept as any packet for someone here.
            _dequeue(out);
            final did = _deliver(out.to, out.from, out.packet);
            out.tell(did, did == null ? 'full' : null);
            _pump(peer);
            return;
          }
          if (target != null && !target.far) {
            final key = target.url != null ? 'u:${target.url}' : 'r:${target.named}';
            if (key != peer.key) {
              _dequeue(out);
              final moved = _Out(peer, target.kind, out.to, out.from, target.relay, out.packet, out.at, out.answer, forOthers: out.forOthers)
                ..rerouted = true
                ..answered = out.answered;
              final sent = _send(target, out.to, out.from, out.packet, (here, [err]) => moved.tell(here, err), by: out.forOthers ? null : out.from, forStanding: out.forOthers);
              if (!sent) moved.tell(null, 'refused');
              _pump(peer);
              return;
            }
          }
        }
        if (!out.again) {
          out.again = true;
          if (homes.of(about) != null) {
            _give(link, about, again: true);
            _fly(link, out);
            return;
          }
        }
        _dequeue(out);
        out.tell(null, m['err'] == 'home' && homes.of(out.from) == null ? 'home' : 'refused');
      case 'limit' || 'busy':
        // Over what that relay takes from this one (`limit`), or too busy to check the sender's record (`busy`): it
        // waits here in its place, the relay is left alone a while (longer each time), and then one packet goes alone
        // to see. The sender's record is said again with it.
        if (m['err'] == 'busy') link.gave.removeWhere((tag) => tag.startsWith('${out.from}:'));
        if (peer.pausedUntil == null || !now.isBefore(peer.pausedUntil!)) {
          peer.limits++;
          peer.pausedUntil = now.add(pauseAfter(peer.limits));
        }
        peer.probing = true;
        return;
      case 'full':
        _dequeue(out);
        out.tell(null, 'full');
      default:
        _dequeue(out);
        out.tell(null, 'refused');
    }
    _pump(peer);
  }

  // --- links ------------------------------------------------------------------------------------------------------------

  /// The links open, the hellos under way with relays this one dialled, and the key last seen at each address (base64)
  /// with when.
  final List<_Link> _links = [];
  final List<_Hello> _hellosOut = [];
  final LinkedHashMap<String, ({String key, DateTime at})> _seenAt = LinkedHashMap();

  /// The addresses this relay has linked with, and when last: what waits for one of them waits [queueFor]; for any
  /// other, [neverLinkedFor]. Those given up on, until when; and the addresses a look at came to nothing at.
  final LinkedHashMap<String, DateTime> _linkedOnce = LinkedHashMap();
  final LinkedHashMap<String, DateTime> _dead = LinkedHashMap();
  final LinkedHashMap<String, DateTime> _lookedNo = LinkedHashMap();

  /// Puts [key] in [map] as its newest, and lets the oldest go past [most].
  static void _remember(LinkedHashMap<String, DateTime> map, String key, DateTime at, int most) {
    map.remove(key);
    map[key] = at;
    while (map.length > most) {
      map.remove(map.keys.first);
    }
  }

  /// [key] (base64) was seen at [url] just now; 1024 addresses are remembered.
  void _believe(String url, String key) {
    _seenAt.remove(url);
    _seenAt[url] = (key: key, at: _now());
    while (_seenAt.length > 1024) {
      _seenAt.remove(_seenAt.keys.first);
    }
  }

  /// Whether [key] (base64) is the key this relay saw at [url] within [believedFor].
  bool _believed(String url, String key) {
    final seen = _seenAt[url];
    return seen != null && seen.key == key && _now().difference(seen.at) < believedFor;
  }

  /// Makes room for one more link: at the most, the one used longest ago that nothing is waiting on goes.
  bool _room() {
    if (_links.length < maxLinks) return true;
    final idle = _links.where((l) => l.flying.isEmpty && l.asked.isEmpty && !l.isVia).toList()..sort((a, b) => a.used.compareTo(b.used));
    if (idle.isEmpty) return false;
    idle.first.socket.close(1000, 'room');
    _lost(idle.first);
    return _links.length < maxLinks;
  }

  /// Asks for a link to [peer]: dialled now where it has an address, is not being dialled, and is due, and the dials
  /// of its kind this minute allow (a first dial, or a try again).
  void _wantLink(_Peer peer) {
    final url = peer.url;
    if (url == null || peer.dialling || _stopped) return;
    final now = _now();
    if (peer.nextTry != null && now.isBefore(peer.nextTry!)) return;
    if (!_mayLink(url: url, toLearn: true) || guard.shape(url) != null) return _failed(peer, 'off', refused: true);
    if (!_room()) return _failed(peer, 'busy');
    if (!guard.take(peer.failures == 0 ? DialKind.own : DialKind.retry)) {
      // No dial left of its kind this minute: not a failure of that relay's, tried again in a few seconds.
      peer.nextTry = now.add(const Duration(seconds: 5));
      for (final ask in peer.asks.toList()) {
        ask.answer({'none': true, 'why': 'busy'});
      }
      peer.asks.clear();
      return;
    }
    peer.dialling = true;
    unawaited(_open(peer, url));
  }

  /// Dials [peer] and listens for its hub's hello ([_helloHeard]); a dial that comes to nothing is [_failed].
  Future<void> _open(_Peer peer, Uri url) async {
    final HubSocket socket;
    try {
      socket = await _dial(url);
    } catch (e) {
      _say('could not dial ${url.host}: ${'$e'.split('\n').first}');
      if (_stopped) return;
      return _failed(peer, 'down');
    }
    if (_stopped) {
      // Stopped while it was being made: let go, and nothing comes of it.
      unawaited(socket.close(WebSocketStatus.goingAway).catchError((_) {}));
      return;
    }
    final hello = _Hello(peer, socket, _now().add(helloWithin));
    _hellosOut.add(hello);
    socket.incoming.listen((data) => _helloHeard(hello, data), onDone: () => _helloGone(hello), onError: (_) => _helloGone(hello), cancelOnError: true);
  }

  /// A dialled connection closed: the link it had become is lost, or the hello it never finished has failed.
  void _helloGone(_Hello hello) {
    _hellosOut.remove(hello);
    final link = hello.link;
    if (link != null) return _lost(link);
    if (!hello.done) {
      hello.done = true;
      if (!_stopped) _failed(hello.peer, 'down');
    }
  }

  /// A dial that came to nothing: tried again later, later each time; what was asked of that relay is answered. An
  /// address never once linked with is given up on after four tries or [neverLinkedFor].
  void _failed(_Peer peer, String why, {bool refused = false}) {
    final now = _now();
    peer.dialling = false;
    peer.why = why;
    peer.failures++;
    peer.nextTry = now.add(backoff(peer.failures));
    if (refused) peer.refusedUntil = now.add(refusedFor);
    for (final ask in peer.asks.toList()) {
      ask.answer({'none': true, 'why': refused ? (why == 'off' ? 'off' : 'refused') : why});
    }
    peer.asks.clear();
    if (!refused && !peer.everLinked && peer.url != null && (peer.failures >= 4 || now.difference(peer.made) >= neverLinkedFor)) return _giveUp(peer);
    for (final out in peer.queue.toList()) {
      if (out.answered && !refused) continue;
      if (refused) {
        // What waits for a relay that said no is not kept as though it were only away.
        _dequeue(out);
        out.tell(null, 'far');
      } else if (peer.everLinked) {
        // Unreachable: it waits here, and its sender is told it is kept.
        out.tell(null);
      }
    }
  }

  /// [peer], an address never once linked with, has not answered: what waits for it is told it can't be reached, and
  /// the address is not dialled again for [deadFor].
  void _giveUp(_Peer peer) {
    for (final out in peer.queue.toList()) {
      _dequeue(out);
      out.tell(null, 'far');
    }
    for (final ask in peer.asks.toList()) {
      ask.answer({'none': true, 'why': 'down'});
    }
    peer.asks.clear();
    _peers.remove(peer.key);
    _remember(_dead, '${peer.url}', _now().add(deadFor), 1024);
    _say('gave up on ${peer.url?.host}');
  }

  /// What the relay dialled says before the link is made: its hub's hello, then its answer to this relay's.
  void _helloHeard(_Hello hello, Object? data) {
    final link = hello.link;
    if (link != null) return _heard(link, data);
    if (hello.done) return;
    void no(String why, {bool refused = true}) {
      hello.done = true;
      _hellosOut.remove(hello);
      hello.socket.close(1000, 'no');
      _failed(hello.peer, why, refused: refused);
    }

    Map? m;
    try {
      if (data is String && data.length <= 4096) m = jsonDecode(data) as Map;
    } catch (_) {}
    if (m == null) return no('not a relay');
    final peer = hello.peer;
    final url = '${peer.url}';
    if (hello.nonce == null) {
      // The hub's hello, as any app is given it: its number, and who the relay is.
      final card = m['relay'];
      final theirs = card is Map ? card['id'] : null, theirKey = card is Map ? card['key'] : null;
      if (!_hex(m['hello'], 64) || !_hex(theirs, 32) || theirKey is! String) return no('not a relay that talks to others');
      final List<int> k;
      try {
        k = base64Decode(theirKey);
      } catch (_) {
        return no('not a relay that talks to others');
      }
      if (k.length != 33 || Hub.nameOf(k) != theirs) return no('not a relay that talks to others');
      if (theirs == id) {
        // This relay's own name: it is this relay only where the number is one its own hub made up for a hello it is
        // waiting on (anyone can say this relay's name and key; only this relay's hub makes its numbers).
        if (!_ownNumber(m['hello'] as String)) return no('not a relay that talks to others');
        hello.done = true;
        _hellosOut.remove(hello);
        hello.socket.close(1000, 'self');
        return _isMe(peer);
      }
      if (!_mayLink(relay: theirs as String, url: peer.url)) return no('off');
      hello
        ..nonce = _unhex(m['hello'] as String)
        ..id = theirs
        ..key = k
        ..c = [for (var i = 0; i < 32; i++) _random.nextInt(256)];
      final stay = url == config.via;
      final sig = _sign(dialBytes(nonce: hello.nonce!, dialler: id, answerer: theirs, c: hello.c!, dialled: url, url: config.publicHub, stay: stay));
      try {
        hello.socket.add(jsonEncode({'fed': 1, 'id': id, 'key': base64Encode(key), 'sig': base64Encode(sig), if (config.publicHub.isNotEmpty) 'url': config.publicHub, 'c': hexOf(hello.c!), if (stay) 'stay': true}));
      } catch (_) {}
      return;
    }
    // Its answer: yes, signed over this relay's number, both names and the address dialled, by the key its hello
    // named; or no.
    if (m['ok'] != true) return no('${m['err'] ?? 'refused'}', refused: m['err'] != 'busy');
    List<int>? sig;
    try {
      sig = base64Decode(m['sig'] as String);
    } catch (_) {}
    if (m['fed'] != 1 || m['id'] != hello.id || sig == null || !P256.verify(hello.key!, answerBytes(c: hello.c!, dialler: id, answerer: hello.id!, dialled: url), sig)) return no('bad answer');
    hello.done = true;
    _hellosOut.remove(hello);
    _believe(url, base64Encode(hello.key!));
    _remember(_linkedOnce, url, _now(), 4096);
    final made = hello.link = _Link(hello.socket, hello.id!, hello.key!, url, _now(), outbound: true, isVia: url == config.via);
    _links.add(made);
    peer
      ..dialling = false
      ..failures = 0
      ..nextTry = null
      ..refusedUntil = null
      ..everLinked = true
      ..why = null
      ..stays = m['stay'] == true
      ..relay ??= made.id;
    _say('linked with ${made.id.substring(0, 6)} (dialled)');
    _linked(made);
  }

  /// [peer]'s address turned out to be this relay's own: remembered, and what waited for it is handed over here.
  void _isMe(_Peer peer) {
    final url = '${peer.url}';
    _selfUrls.remove(url);
    _selfUrls[url] = _now();
    while (_selfUrls.length > 256) {
      _selfUrls.remove(_selfUrls.keys.first);
    }
    peer.dialling = false;
    for (final out in peer.queue.toList()) {
      _dequeue(out);
      final did = _deliver(out.to, out.from, out.packet);
      out.tell(did, did == null ? 'full' : null);
    }
    for (final ask in peer.asks.toList()) {
      final found = _handles?.holder(ask.name);
      ask.answer(found == null ? {'none': true} : {'id': found.id, 'key': found.key, 'home': ?homes.of(found.id)?.toJson()});
    }
    peer.asks.clear();
    _peers.remove(peer.key);
  }

  /// A link is made: whatever waits for its relay goes.
  void _linked(_Link link) {
    for (final peer in _peers.values.toList()) {
      if (identical(_linkFor(peer), link)) _pump(peer);
    }
  }

  /// [link] is closed: what was on it unanswered waits for the next, and names asked on it are answered `down`.
  void _lost(_Link link) {
    if (!_links.remove(link)) return;
    _say('link with ${link.id.substring(0, 6)} closed');
    // What was on it unanswered waits again, and goes by the next link.
    for (final out in link.flying.values) {
      out.flying = null;
    }
    link.flying.clear();
    for (final ask in link.asked.values.toList()) {
      ask.answer({'none': true, 'why': 'down'});
    }
    link.asked.clear();
    for (final peer in _peers.values) {
      peer.asks.removeWhere((a) => a.done);
    }
  }

  /// The key the hub at [url] says is its relay's, as this relay sees it by dialling there itself; null where it
  /// can't be dialled, is not a relay, says none, or was looked at a moment ago and was none of those ([lookedNoFor]).
  /// Believed for [believedFor]. Each look is one of the dials a minute kept for looks ([DialKind.lookBack]); with
  /// none left, [busy] is told so and nothing is dialled.
  Future<String?> _keyAt(String url, {bool again = false, void Function()? busy}) async {
    final seen = _seenAt[url];
    if (!again && seen != null && _now().difference(seen.at) < believedFor) return seen.key;
    final failed = _lookedNo[url];
    if (failed != null && _now().difference(failed) < lookedNoFor) return null;
    final uri = Uri.parse(url);
    if (guard.shape(uri) != null || _stopped) return null;
    if (!guard.take(DialKind.lookBack)) {
      busy?.call();
      return null;
    }
    final HubSocket socket;
    try {
      socket = await _dial(uri);
    } catch (_) {
      _remember(_lookedNo, url, _now(), 1024);
      return null;
    }
    if (_stopped) {
      unawaited(socket.close(WebSocketStatus.goingAway).catchError((_) {}));
      return null;
    }
    final found = Completer<String?>();
    final look = _Look(socket, _now().add(helloWithin));
    _looks.add(look);
    socket.incoming.listen((data) {
      if (found.isCompleted) return;
      String? key;
      try {
        final m = data is String && data.length <= 4096 ? jsonDecode(data) as Map : null;
        final card = m?['relay'];
        if (_hex(m?['hello'], 64) && card is Map && card['key'] is String && base64Decode(card['key'] as String).length == 33) key = card['key'] as String;
      } catch (_) {}
      found.complete(key);
    }, onDone: () => found.isCompleted ? null : found.complete(null), onError: (_) => found.isCompleted ? null : found.complete(null), cancelOnError: true);
    final key = await found.future;
    _looks.remove(look);
    unawaited(socket.close(1000, 'looked').catchError((_) {}));
    if (key != null) {
      _believe(url, key);
      _lookedNo.remove(url);
    } else {
      _remember(_lookedNo, url, _now(), 1024);
    }
    return key;
  }

  /// The looks under way ([_keyAt]), so that [tick] can close a slow one and [stop] all of them.
  final List<_Look> _looks = [];

  /// Another relay's hello, said in place of an app's ([Hub.attach] hands it over): the link is made where it proves
  /// its key over this relay's own address, may link with this relay, and the address it claims is its own.
  FedEnd incoming(HubSocket socket, Map hello, List<int> nonce) {
    final end = _In(this, socket);
    unawaited(_admit(end, hello, nonce));
    return end;
  }

  /// Checks the hello of a relay that dialled this one, what costs least first, and answers yes (signed, and the link
  /// is made) or `{"ok":false,"err":…}` and closes with 4403.
  Future<void> _admit(_In end, Map hello, List<int> nonce) async {
    final socket = end.socket;
    void no(String why) {
      try {
        if (socket.isOpen) socket.add(jsonEncode({'ok': false, 'err': why}));
      } catch (_) {}
      socket.close(4403, why);
    }

    if (!on || _stopped) return no('fed off');
    // A relay is dialled at its own address, which it signs: one with none is dialled by nobody.
    if (config.publicHub.isEmpty) return no('no address');
    // What costs nothing first: the shape of it.
    final theirs = hello['id'], said = hello['url'];
    List<int>? k, sig;
    try {
      k = base64Decode(hello['key'] as String);
      sig = base64Decode(hello['sig'] as String);
    } catch (_) {}
    if (k == null || sig == null || k.length != 33 || sig.length != 64 || !_hex(theirs, 32) || !_hex(hello['c'], 64) || Hub.nameOf(k) != theirs || (said != null && (said is! String || said.length > HomeRecord.maxAddress)) || (hello.containsKey('stay') && hello['stay'] is! bool)) return no('bad hello');
    if (theirs == id) return no('self');
    // The address it claims, where it claims one: a hub's, written as hubs' addresses are compared.
    final url = said is String ? canonicalHub(said) : null;
    if (said is String && (url == null || url != said)) return no('bad address');
    final uri = url == null ? null : Uri.parse(url);
    if (uri != null && guard.shape(uri) != null) return no('bad address');
    // Its keeper's lists, before anything is checked or dialled for it.
    if (!_mayLink(relay: theirs as String, url: uri)) return no(_listed(config.block, relay: theirs, url: uri) ? 'blocked' : 'not listed');
    final stay = hello['stay'] == true;
    final c = _unhex(hello['c'] as String);
    if (!P256.verify(k, dialBytes(nonce: nonce, dialler: theirs, answerer: id, c: c, dialled: config.publicHub, url: said is String ? said : '', stay: stay), sig)) return no('bad hello');
    // Counted once it is known to be a relay's: at an address this relay has seen its key at already, against that
    // address's own; anyone else's, against what strangers share.
    final now = _now();
    final known = url != null && _believed(url, base64Encode(k));
    if (known ? !_meter('u:$url').hellos.take(now, const Duration(minutes: 1), hellosAMinute) : !_hellos.take(now, const Duration(minutes: 1), hellosAMinute)) return no('busy');
    if (url != null && !known) {
      // Believed only once this relay has dialled that address itself and seen the same key there.
      var busy = false;
      var seen = await _keyAt(url, busy: () => busy = true);
      // Another key was seen there a while ago: looked at once more, since a relay may have been given a new key.
      final at = _seenAt[url]?.at;
      if (seen != null && seen != base64Encode(k) && at != null && _now().difference(at) >= const Duration(minutes: 5)) seen = await _keyAt(url, again: true, busy: () => busy = true);
      if (end.left || !socket.isOpen) return;
      if (_stopped) return no('fed off');
      if (busy) return no('busy');
      if (seen != base64Encode(k)) return no('address');
    }
    if (!_room()) return no('busy');
    final sign = _sign(answerBytes(c: c, dialler: theirs, answerer: id, dialled: config.publicHub));
    // A relay with no address that asked to stay is told whether it may (`"stay": true`): its people are reached over
    // this link only where it may, and its keeper's app says so either way. Nothing is said to anyone else.
    final standing = url == null && stay && _mayStand(theirs);
    try {
      socket.add(jsonEncode({'ok': true, 'fed': 1, 'id': id, 'key': base64Encode(key), 'sig': base64Encode(sign), if (standing) 'stay': true}));
    } catch (_) {}
    final link = _Link(socket, theirs, k, url, _now(), outbound: false, standing: standing);
    _links.add(link);
    end.link = link;
    _say('linked with ${link.id.substring(0, 6)} (it dialled${link.standing ? ', and stays' : ''})');
    _linked(link);
  }

  // --- what a linked relay says ---------------------------------------------------------------------------------------

  /// Whether [link]'s relay speaks for [from]: their home record names it. A relay's own address ([_Link.url], which
  /// this relay has seen its key at), its name where it is one hosted from an app, or the relay such a one stays
  /// linked to. The relay this one itself stays linked to is believed as an app believes its relay.
  bool _speaksFor(_Link link, String from) {
    if (link.isVia && _hosted) return true;
    final rec = homes.of(from);
    if (rec == null) return false;
    for (final a in rec.addresses) {
      if (a.url != null) {
        if (link.url != null && a.url == link.url) return true;
      } else if (a.relay == link.id || (a.via != null && link.url != null && a.via == link.url)) {
        return true;
      }
    }
    return false;
  }

  /// Something a linked relay said: a packet passed here (binary, [_took]), its answer to one sent it (`ack` or `nak`,
  /// [_answered]), a ping, a record it gives (`fed: home`), or a username asked or answered (`fed: whois`).
  void _heard(_Link link, Object? data) {
    // Far past anything a link carries: not a relay that keeps the rules, and nothing more is read from it.
    if ((data is List<int> && data.length > Hub.maxPacket + 256) || (data is String && data.length > 65536)) {
      link.socket.close(WebSocketStatus.messageTooBig, 'too big');
      return _lost(link);
    }
    if (data is List<int>) {
      if (data.isEmpty) return;
      // Before the packet: the kind (1 byte), its number (4), who it is for and from (16 each), 37 in all; a `[6]`
      // has the name of the relay linked to this one (16) after them.
      if (data[0] == toRelay) return _took(link, data, 37, null);
      if (data[0] == toRelayVia && data.length > 53) return _took(link, data, 53, hexOf(data.sublist(37, 53)));
      return;
    }
    Map? m;
    try {
      if (data is String && data.length <= 8192) m = jsonDecode(data) as Map;
    } catch (_) {}
    if (m == null) return;
    if (m.containsKey('ack') || m.containsKey('nak')) return _answered(link, m);
    if (m.containsKey('ping')) {
      // A link kept open says so now and then: answered where it is a small number and not too often.
      final p = m['ping'];
      if ((p is int || (p is String && p.length <= 32)) && link.pings.take(_now(), const Duration(minutes: 1), 60)) _tell(link, {'pong': p});
      return;
    }
    final who = _whoOf(link);
    switch (m['fed']) {
      case 'home':
        // A record it gives: to show whom it speaks for, or where someone lives. Checked like any other, under that
        // relay's own counts; one too many to check just now is remembered, so a packet from them is answered busy.
        final meter = _meter(who);
        if (!meter.records.take(_now(), const Duration(minutes: 1), recordsAMinute)) return;
        final rec = m['rec'];
        final took = _takeRecord(rec, from: 'relay:$who', perHour: link.url != null ? checksAnHour * 10 : checksAnHour);
        if (took == 'busy' && rec is Map && rec['a'] is String) {
          link.busyFor.add(rec['a'] as String);
          while (link.busyFor.length > 1000) {
            link.busyFor.remove(link.busyFor.first);
          }
        } else if (rec is Map) {
          link.busyFor.remove(rec['a']);
        }
      case 'whois':
        final q = m['q'];
        if (m['name'] is String) {
          // It asks who has a username here.
          if (q is! int) return;
          if (!_meter(who).lookups.take(_now(), const Duration(hours: 1), config.lookupsAnHour)) return _tell(link, {'fed': 'whois', 'q': q, 'none': true, 'why': 'busy'});
          final found = _handles?.holder(m['name'] as String);
          link.used = _now();
          _tell(link, found == null ? {'fed': 'whois', 'q': q, 'none': true} : {'fed': 'whois', 'q': q, 'id': found.id, 'key': found.key, 'home': ?homes.of(found.id)?.toJson()});
        } else {
          // It answers one this relay asked: only on a link this relay dialled, as it was asked.
          link.asked.remove(q)?.answer(m);
          for (final peer in _peers.values) {
            peer.asks.removeWhere((a) => a.done);
          }
        }
    }
  }

  /// A packet another relay passed here: `[5][number][to][from][packet]`, or `[6]` with the name of a relay linked
  /// to this one before the packet ([relay]).
  void _took(_Link link, List<int> data, int head, String? relay) {
    if (data.length <= head) return;
    final n = ByteData.sublistView(Uint8List.fromList(data.sublist(1, 5))).getUint32(0);
    void nak(String why) => _tell(link, {'nak': n, 'err': why});
    final now = _now();
    final meter = _meter(_whoOf(link));
    if (!meter.packets.take(now, const Duration(minutes: 1), config.packetsAMinute) || !meter.bytes.take(now, const Duration(days: 1), config.bytesADay, by: data.length)) return nak('limit');
    if (data.length - head > Hub.maxPacket + 32) return nak('big');
    final to = hexOf(data.sublist(5, 21)), from = hexOf(data.sublist(21, 37));
    // A relay speaks only for its own people; where this relay was too busy to check the record it gave a moment ago,
    // it is told to wait and send again.
    if (!_speaksFor(link, from)) return nak(link.busyFor.contains(from) ? 'busy' : 'home');
    link.used = now;
    final packet = data.sublist(head);
    // Taken, or why not: whether they are connected here is not told to another relay (someone may have chosen not to
    // be seen, and a stranger anywhere can send them a packet).
    void answer(bool? here, [String? err]) => err != null ? nak(err) : _tell(link, {'ack': n});
    if (relay != null) {
      // For someone on a relay linked to this one, as their record must say, where that relay may stay: over that
      // link, or kept for it. Never to a relay this one would have to dial.
      if (!_mayStand(relay)) return nak('far');
      final rec = homes.of(to);
      if (rec == null || !rec.addresses.any((a) => a.relay == relay && a.via != null && _isSelfUrl(a.via!))) return nak('to');
      // No more than a quarter of the relays this one waits on are ones another relay named.
      if (!_peers.containsKey('r:$relay') && _peers.keys.where((k) => k.startsWith('r:')).length >= maxPeers ~/ 4) return nak('full');
      final peer = _peerNamed(relay);
      if (peer == null) return nak('full');
      final out = _Out(peer, toRelay, to, from, null, Uint8List.fromList(packet), now, answer, forOthers: true);
      final why = _enqueue(peer, out);
      if (why != null) return nak(why == 'busy' ? 'full' : why);
      return _pump(peer);
    }
    if (!_isHere(to)) {
      final rec = homes.of(to);
      if (rec != null && !rec.addresses.any(_isSelf)) {
        // They live elsewhere, by the record held here. From a relay that stays linked to this one, for its own
        // people who name this relay as their way out: passed on, as for someone signed in here.
        final theirs = homes.of(from);
        if (link.standing && theirs != null && theirs.addresses.any((a) => a.relay == link.id && a.via != null && _isSelfUrl(a.via!))) {
          final target = _targetOf(rec, forStanding: true);
          if (target != null && _send(target, to, from, packet, answer, forStanding: true)) return;
        } else if (!(link.isVia && _hosted)) {
          // From any other relay it goes no further: that relay is told where they live now, and routes it itself.
          _give(link, to, again: true);
          return nak('moved');
        }
      } else if (!_knows(to)) {
        // Nobody of that name has signed in here: nothing is kept for a name a stranger made up.
        return nak('to');
      }
    }
    // Handed to their devices here or kept for them, exactly as one from a connection here.
    final did = _deliver(to, from, packet);
    answer(did, did == null ? 'full' : null);
  }

  // --- what is due --------------------------------------------------------------------------------------------------

  /// Does what the clock says is due: tells senders whose packets have waited [answerWithin] that they are kept (for a
  /// relay linked with before), lets go of what waited [queueFor], gives up on an address never linked with after
  /// [neverLinkedFor], closes links nothing has crossed for [idleFor] and hellos that never finished, and dials again
  /// the relays that are due. The relay calls it once a second ([start]); a test calls it itself.
  void tick() {
    final now = _now();
    for (final hello in _hellosOut.toList()) {
      if (!hello.done && !now.isBefore(hello.deadline)) hello.socket.close(1000, 'slow');
    }
    for (final look in _looks.toList()) {
      if (!now.isBefore(look.deadline)) look.socket.close(1000, 'slow');
    }
    for (final link in _links.toList()) {
      if (!link.socket.isOpen) {
        _lost(link);
        continue;
      }
      final stuck = link.flying.values.any((o) => o.sentAt != null && now.difference(o.sentAt!) >= stuckAfter);
      final idle = !link.standing && !link.isVia && link.flying.isEmpty && link.asked.isEmpty && now.difference(link.used) >= idleFor;
      if (stuck || idle) {
        link.socket.close(1000, stuck ? 'stuck' : 'idle');
        _lost(link);
      }
      for (final ask in link.asked.values.toList()) {
        if (now.difference(ask.at) >= whoisWithin) {
          link.asked.remove(ask.q);
          ask.answer({'none': true, 'why': 'down'});
        }
      }
    }
    for (final peer in _peers.values.toList()) {
      if (!peer.everLinked && peer.url != null && !peer.dialling && _linkFor(peer) == null && (peer.queue.isNotEmpty || peer.asks.isNotEmpty) && now.difference(peer.made) >= neverLinkedFor) {
        _giveUp(peer);
        continue;
      }
      for (final out in peer.queue.toList()) {
        if (now.difference(out.at) >= queueFor) {
          _dequeue(out);
          out.tell(false);
        } else if (!out.answered && peer.everLinked && now.difference(out.at) >= answerWithin) {
          out.tell(null);
        }
      }
      for (final ask in peer.asks.toList()) {
        if (!ask.done && now.difference(ask.at) >= whoisWithin) ask.answer({'none': true, 'why': 'down'});
      }
      peer.asks.removeWhere((a) => a.done);
      if (peer.queue.isNotEmpty || peer.asks.isNotEmpty) {
        _pump(peer);
      } else if (peer.key != 'u:${config.via}' && !peer.dialling && _linkFor(peer) == null && now.difference(peer.lastUsed) >= const Duration(hours: 1)) {
        _peers.remove(peer.key);
      }
    }
    // The relay this one stays linked to: dialled whenever the link is not up.
    if (on && config.via.isNotEmpty && !_stopped) {
      final via = _peerAt(config.via);
      if (via != null && _linkFor(via) == null) _wantLink(via);
    }
    _selfUrls.removeWhere((_, at) => now.difference(at) >= believedFor);
    _seenAt.removeWhere((_, seen) => now.difference(seen.at) >= believedFor);
    _dead.removeWhere((_, until) => !now.isBefore(until));
    _lookedNo.removeWhere((_, at) => now.difference(at) >= lookedNoFor);
    _linkedOnce.removeWhere((_, at) => now.difference(at) >= const Duration(days: 30));
    _checks.removeWhere((_, c) => c.hour.over(now, const Duration(hours: 1)));
    _lookups.removeWhere((_, c) => c.over(now, const Duration(hours: 1)));
    _meters.removeWhere((_, m) => m.over(now));
    _senders.removeWhere((_, s) => s.over(now));
  }
}

/// So many in a stretch of time, counted from the first: [take] says whether there is room for one more.
class _Count {
  DateTime? _since;
  int _n = 0;

  /// Counts [by] more where that keeps it to [most] in [every]; a stretch that has ended starts again from [now].
  bool take(DateTime now, Duration every, int most, {int by = 1}) {
    if (over(now, every)) {
      _since = now;
      _n = 0;
    }
    if (_n + by > most) return false;
    _n += by;
    return true;
  }

  /// Gives back the one just taken (it was refused elsewhere, and cost nothing).
  void back([int by = 1]) => _n = max(0, _n - by);

  /// Whether the stretch it was counting in has ended.
  bool over(DateTime now, Duration every) => _since == null || now.difference(_since!) >= every;
}

/// The record checks one giver has had: this hour, and this second.
class _Checks {
  final hour = _Count();
  final second = _Count();
}

/// What one linked relay (by [Federation._whoOf]) has sent lately.
class _Meter {
  final packets = _Count();
  final bytes = _Count();
  final lookups = _Count();
  final records = _Count();
  final hellos = _Count();

  /// Whether nothing is being counted for it any more.
  bool over(DateTime now) => packets.over(now, const Duration(minutes: 1)) && bytes.over(now, const Duration(days: 1)) && lookups.over(now, const Duration(hours: 1)) && records.over(now, const Duration(minutes: 1)) && hellos.over(now, const Duration(minutes: 1));
}

/// What one install signed in here has sent across relays lately, and how many relays it has made this one dial.
class _Sender {
  final packets = _Count();
  final bytes = _Count();
  final relays = _Count();

  /// Whether nothing is being counted for it any more.
  bool over(DateTime now) => packets.over(now, const Duration(minutes: 1)) && bytes.over(now, const Duration(days: 1)) && relays.over(now, const Duration(hours: 1));
}

/// So many packets and bytes of a queue that are one person's.
class _Share {
  int n = 0;
  int bytes = 0;

  void add(int size) {
    n++;
    bytes += size;
  }

  /// Takes one of [size] off; true where nothing is left.
  bool take(int size) {
    n--;
    bytes -= size;
    return n <= 0;
  }
}

/// Where a packet goes ([Federation._targetOf]): a relay's address, or a relay that stays linked to this one by its
/// name; or nowhere this relay passes to ([far]).
class _Target {
  const _Target({this.url, this.named, this.kind = Federation.toRelay, this.relay}) : far = false;
  const _Target._far()
      : url = null,
        named = null,
        kind = 0,
        relay = null,
        far = true;
  static const nowhere = _Target._far();

  /// The address to pass it to, or ([named]) the name of a relay that stays linked here; [kind] is the frame's first
  /// byte, and [relay] the hosted relay a `[6]` names.
  final String? url;
  final String? named;
  final int kind;
  final String? relay;
  final bool far;
}

/// A link with another relay, proven: whichever of the two dialled.
class _Link {
  _Link(this.socket, this.id, this.key, this.url, this.used, {required this.outbound, this.standing = false, this.isVia = false});
  final HubSocket socket;

  /// The other relay's name and key, as it proved them.
  final String id;
  final List<int> key;

  /// Its hub's address, where this relay has seen that key there itself; null for a relay with none.
  final String? url;

  /// Whether this relay dialled it: only such a link carries what is for an address ([Federation._linkFor]).
  final bool outbound;

  /// It dialled this relay with no address of its own, to stay, and may: its people are reached over this link.
  final bool standing;

  /// The relay this one stays linked to (`GHOST_FED_VIA`).
  final bool isVia;

  /// When something last crossed it, and the last number given to a packet or a question on it.
  DateTime used;
  int seq = 0;

  /// What was sent on it and is not answered yet, by its number.
  final Map<int, _Out> flying = {};

  /// The names asked on it and not answered yet, by their number.
  final Map<int, _Ask> asked = {};

  /// The records said on it, as `name:count:time`.
  final LinkedHashSet<String> gave = LinkedHashSet();

  /// Those whose record it gave when this relay was too busy to check it: a packet from them is answered `busy`.
  final LinkedHashSet<String> busyFor = LinkedHashSet();

  /// The pings it has had answered lately.
  final pings = _Count();
}

/// A relay something waits for: by its hub's address, or for one with no address by its name.
class _Peer {
  _Peer(this.key, {this.url, this.relay, required this.lastUsed, required this.made, this.everLinked = false});
  /// `u:<address>` or `r:<name>`, as [Federation._peers] holds it; its hub's address, and its name once known.
  final String key;
  final Uri? url;
  String? relay;

  /// The packets and the names asked that wait for it, and the queue's bytes as counted ([_Out.size]).
  final Queue<_Out> queue = Queue();
  final List<_Ask> asks = [];
  int bytes = 0;

  /// What waits for it, by whom it is for.
  final Map<String, _Share> byRecipient = {};

  /// A dial is under way; the dials that failed in a row and when it is next tried ([Federation.backoff]); and until
  /// when it is left alone, because it said no or because it said this relay is over its limit.
  bool dialling = false;
  int failures = 0;
  DateTime? nextTry;
  DateTime? refusedUntil;
  DateTime? pausedUntil;

  /// How many times in a row it said this relay was over its limit, and whether one packet goes alone to see.
  int limits = 0;
  bool probing = false;

  /// When something was last sent or asked for it: one nothing has used for an hour is forgotten.
  DateTime lastUsed;

  /// What installs not established here have sent it lately, all together ([Federation.established]).
  final strangerPackets = _Count(), strangerBytes = _Count();

  /// When it was first wanted, and whether this relay has ever linked with that address (lately).
  final DateTime made;
  bool everLinked;

  /// Why the last dial came to nothing, where it did: `down`, or what the relay that answered no said; and whether, at
  /// the last link this relay dialled there to stay, it was told it may ([Federation.viaLink]).
  String? why;
  bool stays = false;

  /// Nothing waits for it and it is not being dialled.
  bool get idle => queue.isEmpty && asks.isEmpty && !dialling;
}

/// A packet on its way to another relay.
class _Out {
  _Out(this.peer, this.kind, this.to, this.from, this.relay, this.packet, this.at, this.answer, {this.forOthers = false});
  final _Peer peer;

  /// Another relay passed it here to be passed on (a `[6]`, or from a relay that stays linked to this one): not from
  /// someone signed in here.
  final bool forOthers;

  /// The frame's first byte ([Federation.toRelay] or [Federation.toRelayVia]), who it is for and from, the hosted
  /// relay a `[6]` names, when it was taken, who is told what became of it, and whether they have been.
  final int kind;
  final String to;
  final String from;
  final String? relay;
  final Uint8List packet;
  final DateTime at;
  final void Function(bool? here, [String? err]) answer;
  bool answered = false;

  /// The link it was sent on, while it waits for that relay's answer, and when.
  _Link? flying;
  DateTime? sentAt;

  /// Refused once for want of a record and sent again with it; and sent to another relay once because the one it went
  /// to said they live elsewhere.
  bool again = false;
  bool rerouted = false;

  /// What it costs held here: its bytes, and what holding any packet costs ([Federation.perPacket]).
  int get size => packet.length + Federation.perPacket;

  /// Tells whoever sent it, once.
  void tell(bool? here, [String? err]) {
    if (answered) return;
    answered = true;
    answer(here, err);
  }
}

/// A username asked of another relay.
class _Ask {
  _Ask(this.name, this.at, this._answer);
  final String name;
  final DateTime at;
  final void Function(Map) _answer;

  /// Its number on the link it was sent on, whether it has been sent, and whether it has been answered.
  int q = 0;
  bool sent = false;
  bool done = false;

  /// Answers whoever asked, once.
  void answer(Map m) {
    if (done) return;
    done = true;
    _answer(m);
  }
}

/// A hello under way with a relay this one dialled.
class _Hello {
  _Hello(this.peer, this.socket, this.deadline);
  final _Peer peer;
  final HubSocket socket;
  final DateTime deadline;

  /// The number in its hub's hello, the relay's name and key as that hello said them, and the number this relay made
  /// up for it to sign: all null until the hub's hello is heard.
  List<int>? nonce;
  String? id;
  List<int>? key;
  List<int>? c;

  /// It is finished, one way or the other; and the link it became.
  bool done = false;
  _Link? link;
}

/// A look at what key an address shows ([Federation._keyAt]).
class _Look {
  _Look(this.socket, this.deadline);
  final HubSocket socket;
  final DateTime deadline;
}

/// The hub's end of a link another relay dialled. Nothing it says is heard until [Federation._admit] has made the link.
class _In implements FedEnd {
  _In(this._fed, this.socket);
  final Federation _fed;
  final HubSocket socket;
  _Link? link;
  bool left = false;

  @override
  void heard(Object? data) {
    final l = link;
    if (l != null) _fed._heard(l, data);
  }

  @override
  void gone() {
    left = true;
    final l = link;
    if (l != null) _fed._lost(l);
  }
}
