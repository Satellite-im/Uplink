import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/forward_secrecy.dart' show MemoryFsStore;
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/p2p/node.dart';
import 'package:ghost_messaging/net/p2p/node_factory.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:integration_test/integration_test.dart';

/// Direct end to end, the phone's half (Matt's brief, 2026-11-23): this device is account B, on the Android emulator,
/// with the real core (native/p2p through lib/net/p2p/node_ffi.dart and P2pCore.kt) under the app's own routes
/// (lib/net/net.dart, a phone's), a relay on the Mac reached through `adb reverse`, and our live link helper
/// (https://gogho.st:7843), which the relay names. Its other half is tool/net/direct_e2e_mac_test.dart: account A on the
/// Mac, a computer of its own, and account C, nobody's friend. Each half goes on as the other does, by what it hears.
///
///     dart run relay/bin/relay.dart --port 18797 --data <scratch>       (GHOST_LINK_HELPERS=https://gogho.st:7843)
///     adb -s emulator-5584 reverse tcp:18797 tcp:18797
///     flutter test integration_test/direct_e2e_test.dart -d emulator-5584 --dart-define=E2E_HUB=ws://127.0.0.1:18797/hub \
///       --dart-define=E2E_KEYS=<a>,<b>,<c> [--dart-define=E2E_IDLE=5]
///
/// with the same three key scalars (64 hex digits each, made for the run) given to the Mac's half. With E2E_IDLE, it ends
/// with that many minutes put away with Direct on and as many with it off, for the app's CPU to be measured from the
/// Mac (`adb shell cat /proc/<pid>/stat`, and its UDP sockets by its user in `/proc/net/udp*`, which an app itself may
/// not read). Put away with nothing holding it (no bound service), Android freezes the app within a minute or two and
/// its timers wait with it: bring it back (`adb shell am start -n com.infamousvague.ghostmessaging/.MainActivity`) as each
/// window ends. What it sees is said in the log (`E2E …`): counts and kinds, never a key.
const _hub = String.fromEnvironment('E2E_HUB');
const _keys = String.fromEnvironment('E2E_KEYS');
const _idle = int.fromEnvironment('E2E_IDLE');

void _say(String what) => debugPrint('E2E phone ${DateTime.now().toIso8601String().substring(11, 19)}: $what');

/// Whether the core is loaded in this process: in its map of files, or to the system's linker (RTLD_NOLOAD loads nothing).
bool _coreLoaded() {
  if (File('/proc/self/maps').readAsLinesSync().any((line) => line.endsWith('libghost_p2p.so'))) return true;
  final dlopen = DynamicLibrary.process().lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Int32), Pointer<Void> Function(Pointer<Utf8>, int)>('dlopen');
  final name = 'libghost_p2p.so'.toNativeUtf8();
  try {
    return dlopen(name, 2 | 4) != nullptr;
  } finally {
    malloc.free(name);
  }
}

/// The sockets this process holds, of every kind: an app may not read the system's table of UDP sockets
/// (/proc/net/udp, refused by SELinux), so the Mac counts those from outside (`adb shell cat /proc/net/udp`, by the
/// app's user); here the core's come and go among the rest.
int _sockets() {
  var n = 0;
  for (final fd in Directory('/proc/self/fd').listSync(followLinks: false)) {
    try {
      if (Link(fd.path).targetSync().startsWith('socket:')) n++;
    } catch (_) {}
  }
  return n;
}

/// Waits for [ok], up to [most]; says [what] either way.
Future<bool> _until(bool Function() ok, String what, {Duration most = const Duration(minutes: 3)}) async {
  final began = DateTime.now();
  while (!ok() && DateTime.now().difference(began) < most) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  _say('${ok() ? 'saw' : 'NEVER SAW'} $what (${DateTime.now().difference(began).inSeconds} s)');
  return ok();
}

/// The app put away and back, told to the routes as main.dart tells them.
class _Away with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Net.instance.setAway(state != AppLifecycleState.resumed);
    _say('the app is ${state.name}');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Direct between this phone and a Mac, through our link helper', (tester) async {
    expect([_hub, _keys], everyElement(isNotEmpty), reason: 'say where the relay is and the keys: --dart-define=E2E_HUB=… --dart-define=E2E_KEYS=…');
    final scalars = _keys.split(',');
    final a = NetKeys.fromScalar(NetCrypto.unhex(scalars[0])), me = NetKeys.fromScalar(NetCrypto.unhex(scalars[1])), c = NetKeys.fromScalar(NetCrypto.unhex(scalars[2]));
    Uint8List keyWith(NetKeys them) => NetCrypto.netKey(NetCrypto.conversationKey(me, them.public)!);
    final secrets = <String, String>{};
    final asked = <String>[];
    // This phone's own records, as Android keeps them: A a friend by username, C someone who has only asked.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final args = call.arguments is Map ? call.arguments as Map : const {};
      asked.add(call.method);
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (args['message'] as List).cast<int>());
        case 'netPeers':
          return [
            {'id': a.id, 'address': '@a', 'key': keyWith(a)},
            {'id': c.id, 'address': '@c', 'key': keyWith(c)},
          ];
        case 'buddiesKept':
          return jsonEncode([
            {'u': 'a', 'i': a.id, 'k': base64Encode(a.public), 's': 'yes'},
            {'u': 'c', 'i': c.id, 'k': base64Encode(c.public), 's': 'asked'},
          ]);
        case 'e2eList':
          return const <Object>[];
        case 'netSmsDrain':
          return const <Object>[];
        case 'secretKeep':
          final value = '${args['value'] ?? ''}';
          value.isEmpty ? secrets.remove('${args['name']}') : secrets['${args['name']}'] = value;
          return null;
        case 'secretRead':
          return secrets['${args['name']}'];
      }
      return null;
    });
    Net.ledgerStore = () => MemoryFsStore();
    var made = 0;
    Net.p2pNode = () {
      made++;
      return makeP2pNode();
    };
    final away = _Away();
    WidgetsBinding.instance.addObserver(away);
    final got = <String>[];
    Net.instance.listen((r) {
      if (r.envelope.kind == 'text') got.add('${r.envelope.body['t']} by ${r.via}');
    });
    bool came(String words, {String? via}) => got.contains('$words by ${via ?? 'hub'}') || (via == null && got.any((g) => g.startsWith('$words by ')));

    // The app starts with Direct as it starts for everyone: off. Nothing of the core is loaded, and none is asked for.
    expect(_coreLoaded(), isFalse, reason: 'the core was loaded before anything');
    final app = AppState()..set('net_hub', _hub);
    await Net.instance.start(app);
    await _until(() => Net.instance.hub?.state.value == CarrierState.up, 'the relay signed in to');
    _say('started: Direct offered ${Net.instance.directOffered}, on ${Net.instance.directOn}; the core asked for a node $made times; loaded ${_coreLoaded()}; asked who is a friend ${asked.contains('buddiesKept')}; routes ${Net.instance.board!.carriers.map((r) => r.id).toList()}, off ${Net.instance.board!.off}');
    expect([made, _coreLoaded(), Net.instance.p2p, asked.contains('buddiesKept')], [0, false, null, false]);
    _say('the relay names the link helpers ${Net.instance.relayHelpers}');

    // Switched on, as Settings › Routes' switch does it: the node is made (the library opened), not yet started.
    await Net.instance.setRoute('p2p', true);
    final p2p = Net.instance.p2p!;
    _say('switched on: asked for a node $made times, the core loaded ${_coreLoaded()}, routes ${Net.instance.board!.carriers.map((r) => r.id).toList()}, the node ${p2p.nodeState.name}, link helpers ${p2p.helpers}');
    expect([made, _coreLoaded()], [1, true]);
    await _until(() => p2p.loaded && p2p.card != null, 'this device\'s card made');
    // A's card comes through the relay, with where the Mac is (a computer's node is up whenever Direct is on).
    expect(await _until(() => p2p.devicesOf(a.id).isNotEmpty, 'the Mac\'s card', most: const Duration(minutes: 5)), isTrue);
    final theirs = p2p.devicesOf(a.id).single;
    _say('the Mac\'s device: on our link helper ${theirs.where?.helper == p2p.helpers.firstOrNull}, ${theirs.where?.addresses.length ?? 0} addresses of its own');

    // Two texts through the relay, which the ledger lists.
    final peer = Net.instance.byId(a.id)!;
    var d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'hub from B'}), only: const {'hub'});
    _say('"hub from B": by ${d.via}, answered ${d.acked}');
    expect(await _until(() => came('hub from A', via: 'hub'), '"hub from A" by the relay', most: const Duration(minutes: 3)), isTrue);

    // The Mac says when what went by the relay has settled (two minutes), and both switch the relay off.
    expect(await _until(() => came('go', via: 'hub'), '"go" by the relay', most: const Duration(minutes: 5)), isTrue);
    await Net.instance.setRoute('hub', false);
    _say('the relay\'s route switched off here: off ${Net.instance.board!.off}');
    await Future<void>.delayed(const Duration(seconds: 3));
    final began = DateTime.now();
    d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'direct from B'}));
    _say('"direct from B": by ${d.via}, answered ${d.acked}, in ${DateTime.now().difference(began).inMilliseconds} ms; tried ${d.tried}');
    expect(d.via, 'p2p');
    String links() => [for (final l in p2p.carrier.links) '${l.account == a.id ? 'the Mac' : 'someone else'} ${l.kind.name}'].join(', ');
    _say('links: ${links()}; Settings › Routes says "${directLinkedWords({for (final l in p2p.carrier.links) l.nodeId: l.kind}.length)}", "${directLinkedHint({for (final l in p2p.carrier.links) l.nodeId: l.kind}.values)}"');
    expect(await _until(() => came('direct from A', via: 'p2p'), '"direct from A" over Direct'), isTrue);

    // The ledger compared over the link, and what Settings › Routes then shows.
    final ledger = Net.instance.ledger!;
    expect(await _until(() => (ledger.relays[_hub]?.lastChecked ?? 0) > 0, 'the ledger compared over the link', most: const Duration(minutes: 2)), isTrue);
    final r = ledger.relays[_hub]!, now = DateTime.now().millisecondsSinceEpoch;
    _say('Checking the relay shows: "${relayCheckedWords(r.lastChecked, r.devices, now: now)}"; "${relayMatchedWords(r.matched(now))}"; "${relayMadeUpWords(r.madeUp(now), restarts: r.restarts(now))}"; ${r.wrong.isEmpty ? '"It got nothing wrong"' : [for (final w in r.wrong) relayWrongWords(w, 'A')].join('; ')}');

    // "Only through link helpers": the node starts again with it, and the next link is made through the helper.
    await Net.instance.setHelpersOnly(true);
    await _until(() => p2p.carrier.links.isEmpty, 'the links let go as the node started again', most: const Duration(seconds: 20));
    d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'through the helper only'}));
    _say('"through the helper only": by ${d.via}, answered ${d.acked}; links: ${links()}');
    expect(await _until(() => came('helper back', via: 'p2p'), '"helper back" over Direct'), isTrue);
    _say('links now: ${links()}');

    // C, nobody's friend, asked for this device's card and to meet: nothing of it was taken, and nothing told it.
    _say('C: a device known ${p2p.devicesOf(c.id).length}, linked with ${p2p.mayLink(c.id)}');
    expect([p2p.devicesOf(c.id), p2p.mayLink(c.id)], [isEmpty, false]);

    if (_idle > 0) {
      // Put away with Direct on, as a phone is most of the day: the relay's route on again, as it usually is, and the
      // node up from a send of this device's own a moment before (it stops two minutes after: P2pPolicy.idle).
      await Net.instance.setRoute('hub', true);
      await Net.instance.setHelpersOnly(false);
      await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'going away'}));
      _say('IDLE-ON begins (pid $pid): press Home now. The node ${p2p.nodeState.name}, ${_sockets()} sockets, links: ${links()}');
      await Future<void>.delayed(Duration(minutes: _idle, seconds: 30));
      _say('IDLE-ON ends: the node ${p2p.nodeState.name}, ${_sockets()} sockets');
    }

    // Switched off while the node is up: every link closed, the node stopped and its sockets let go, the route gone;
    // the core loaded still, and idle.
    await Net.instance.setRoute('hub', false);
    d = await Net.instance.send(peer, Envelope(kind: 'text', body: {'t': 'last one'}));
    _say('"last one": by ${d.via}; the node ${p2p.nodeState.name}, links: ${links()}, ${_sockets()} sockets: SAMPLE-UP');
    await Future<void>.delayed(const Duration(seconds: 15));
    final before = _sockets();
    await Net.instance.setRoute('p2p', false);
    await Net.instance.setRoute('hub', true);
    _say('switched off: the direct network ${Net.instance.p2p}, routes ${Net.instance.board!.carriers.map((r) => r.id).toList()}, the node ${p2p.nodeState.name}; sockets $before before, ${_sockets()} after; the core loaded ${_coreLoaded()}: SAMPLE-OFF');
    expect([Net.instance.p2p, Net.instance.board!.carrier('p2p'), p2p.nodeState], [null, null, P2pState.off]);
    await Future<void>.delayed(const Duration(minutes: 1));
    _say('a minute on: ${_sockets()} sockets');
    if (_idle > 0) {
      _say('IDLE-OFF begins (pid $pid)');
      await Future<void>.delayed(Duration(minutes: _idle, seconds: 30));
      _say('IDLE-OFF ends: ${_sockets()} sockets');
    }
    WidgetsBinding.instance.removeObserver(away);
    await Net.instance.shutdown();
    Net.p2pNode = null;
  }, timeout: const Timeout(Duration(minutes: 40)));
}
