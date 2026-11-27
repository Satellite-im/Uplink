// Plugin sync across an Uplink account's devices (GMFB-9, lib/plugins/plugin_sync.dart): the list's merge rule, the
// sealed blob it shares with the cURL entries, and a device applying what another device chose.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/account/account_crypto.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/plugins/plugin_sync.dart';
import 'package:ghost_messaging/plugins/registry.dart';
import 'package:ghost_messaging/plugins/translate.dart';

SyncedPlugin on(int at, {String? v}) => SyncedPlugin(on: true, at: at, version: v);
SyncedPlugin off(int at, {String? v}) => SyncedPlugin(on: false, at: at, version: v);

/// The relay's one blob per account, kept sealed as the relay keeps it: it never sees the list.
class FakeRelay {
  FakeRelay(this.key);
  final Uint8List key;
  Uint8List? sealed;
  int writes = 0;
  bool unreadable = false;

  Map<String, Object?>? opened() {
    final s = sealed;
    if (s == null) return null;
    final clear = NetCrypto.open(key, s);
    expect(clear, isNotNull, reason: 'the blob opens with the account key');
    return (jsonDecode(utf8.decode(clear!)) as Map).cast<String, Object?>();
  }
}

/// A device: its plugins as a map, its preferences, its clock, and the account's relay.
class FakeDevice implements PluginSyncHost {
  FakeDevice(this.relay, {this.accountId = 'acct-1', this.packsAllowed = true});
  final FakeRelay relay;
  String accountId;
  final bool packsAllowed;
  bool hasAccount = true;

  /// id -> on, for the plugins this device has (built-ins and started networks; installed packs).
  final Map<String, bool> plugins = {};
  final Set<String> networks = {};
  final Set<String> signedIn = {};
  final Map<String, String> packVersions = {};

  /// Plugins switched by hand here (what seeding reads); the rest are at their defaults.
  final Set<String> explicit = {};

  /// The Marketplace's listings this device can see: pack id -> version.
  final Map<String, String> listings = {};
  final List<String> fetched = [];
  final Map<String, String> prefs = {};
  int clock = 1000;
  final List<String> turns = [];

  @override
  Future<bool> ready() async => hasAccount;

  @override
  Future<Map<String, Object?>?> kept() async {
    if (relay.unreadable) throw StateError('unreadable');
    return relay.opened();
  }

  @override
  Future<void> keep(Map<String, Object?> whole) async {
    relay.sealed = PluginSyncList.seal(relay.key, whole);
    relay.writes++;
  }

  @override
  String get account => accountId;

  @override
  PluginHere? here(String id) {
    final v = plugins[id];
    if (v == null) return null;
    return PluginHere(on: v, network: networks.contains(id), signedIn: signedIn.contains(id), version: packVersions[id]);
  }

  @override
  Future<void> turn(String id, bool on) async {
    turns.add('$id ${on ? 'on' : 'off'}');
    plugins[id] = on;
    // What a switch does in the app: the registry tells plugin sync, which must tell this from the person's.
    sync?.switched(id, on);
  }

  PluginSync? sync;

  @override
  Future<PackFetch> fetch(String packId, String? version) async {
    if (!packsAllowed) return PackFetch.never;
    final listed = listings[packId];
    if (listed == null || !PluginSync.listingWillDo(listed, version)) return PackFetch.later;
    fetched.add('$packId@$listed');
    plugins['x$packId'] = true;
    packVersions['x$packId'] = listed;
    sync?.switched('x$packId', true, version: listed);
    return PackFetch.done;
  }

  @override
  Map<String, ({bool on, String? version})> chosen() => {
        for (final e in plugins.entries)
          if (explicit.contains(e.key) || (networks.contains(e.key) && e.value) || packVersions.containsKey(e.key)) e.key: (on: e.value, version: packVersions[e.key]),
      };

  @override
  String read(String key) => prefs[key] ?? '';

  @override
  void write(String key, String value) => prefs[key] = value;

  @override
  int now() => clock;

  /// The person moves a switch here.
  void press(String id, bool on, {String? version}) {
    plugins[id] = on;
    explicit.add(id);
    sync!.switched(id, on, version: version);
  }
}

FakeDevice device(FakeRelay relay, {String account = 'acct-1', bool packs = true}) {
  final d = FakeDevice(relay, accountId: account, packsAllowed: packs);
  d.sync = PluginSync(host: d);
  return d;
}

void main() {
  group('merge rule', () {
    test('the newer line wins, whichever side it is on', () {
      final a = {'spam': on(10), 'codes': off(30)};
      final b = {'spam': off(20), 'codes': on(5)};
      final m = PluginSyncList.merge(a, b);
      expect(m['spam'], off(20));
      expect(m['codes'], off(30));
      expect(PluginSyncList.merge(b, a), m, reason: 'joining is the same either way round');
    });

    test('at the same time on wins, then the higher version', () {
      expect(PluginSyncList.merge({'x': off(7)}, {'x': on(7)})['x'], on(7));
      expect(PluginSyncList.merge({'x': on(7)}, {'x': off(7)})['x'], on(7));
      expect(PluginSyncList.merge({'xa': on(7, v: '1.2.0')}, {'xa': on(7, v: '1.10.0')})['xa']!.version, '1.10.0');
      expect(PluginSyncList.merge({'xa': on(7, v: '1.10.0')}, {'xa': on(7, v: '1.2.0')})['xa']!.version, '1.10.0');
    });

    test('a plugin either side names is kept', () {
      final m = PluginSyncList.merge({'a': on(1)}, {'b': off(2)});
      expect(m.keys, unorderedEquals(['a', 'b']));
    });

    test('a list that isn\'t ours reads as nothing; a bad line or id is left out', () {
      expect(PluginSyncList.parse(null), isEmpty);
      expect(PluginSyncList.parse({'v': 2, 'list': {'a': on(1).toJson()}}), isEmpty);
      final got = PluginSyncList.parse({
        'v': 1,
        'list': {
          'spam': {'on': true, 'at': 4},
          'Bad Id': {'on': true, 'at': 4},
          'codes': {'on': 'yes', 'at': 4},
          'xpack': {'on': false, 'at': 9, 'ver': '2.0.0'},
        },
      });
      expect(got, {'spam': on(4), 'xpack': off(9, v: '2.0.0')});
      expect(PluginSyncList.parse(PluginSyncList.encode(got)), got, reason: 'encode and parse round trip');
    });
  });

  group('the sealed blob', () {
    final words = AccountCrypto.wordsOf(List.filled(16, 7));
    final key = Me.curlKeyOf(words);

    test('the list rides beside the cURL entries, sealed with the account key, and opens on another device', () {
      final kept = <String, Object?>{
        'v': 1,
        'entries': {'instagram': {'cookies': {'sessionid': 's'}, 'at': 5, 'from': 'chrome'}},
      };
      final list = {'netwhatsapp': on(100), 'spam': off(90)};
      final whole = PluginSyncList.blobWith(kept, list);
      expect(whole['entries'], kept['entries'], reason: 'the extension\'s entries are kept as they were');
      expect(whole['v'], 1);
      final sealed = PluginSyncList.seal(key, whole);
      expect(utf8.decode(sealed, allowMalformed: true).contains('netwhatsapp'), isFalse, reason: 'the relay can\'t read it');

      // Another device of the same account derives the same key from the same words.
      final again = Me.curlKeyOf(AccountCrypto.tidyWords(words.join(' ')));
      expect(PluginSyncList.open(again, sealed), list);
    });

    test('another account\'s key opens nothing', () {
      final sealed = PluginSyncList.seal(key, PluginSyncList.blobWith(null, {'spam': on(1)}));
      final other = Me.curlKeyOf(AccountCrypto.wordsOf(List.filled(16, 9)));
      expect(PluginSyncList.open(other, sealed), isNull);
    });

    test('a blob with no list yet (only the cURL entries) reads as an empty list', () {
      final sealed = PluginSyncList.seal(key, {'v': 1, 'entries': <String, Object?>{}});
      expect(PluginSyncList.open(key, sealed), isEmpty);
    });
  });

  group('applying a synced list', () {
    late FakeRelay relay;
    setUp(() => relay = FakeRelay(Me.curlKeyOf(AccountCrypto.wordsOf(List.filled(16, 3)))));

    test('on: built-ins switched on, a network started to offer its sign-in, a pack fetched from the Marketplace', () async {
      final a = device(relay);
      a.plugins.addAll({'translate': false, 'netwhatsapp': false});
      a.networks.add('netwhatsapp');
      await a.sync!.sync();
      a.clock = 2000;
      a.press('translate', true);
      a.press('netwhatsapp', true);
      a.plugins['xweather'] = true;
      a.packVersions['xweather'] = '1.2.0';
      a.press('xweather', true, version: '1.2.0');
      await a.sync!.sync();

      final b = device(relay);
      b.plugins.addAll({'translate': false, 'netwhatsapp': false});
      b.networks.add('netwhatsapp');
      b.listings['weather'] = '1.3.0';
      await b.sync!.sync();
      expect(b.plugins['translate'], isTrue);
      expect(b.plugins['netwhatsapp'], isTrue);
      expect(b.signedIn, isEmpty, reason: 'never a session: only switched on, to offer its sign-in');
      expect(b.fetched, ['weather@1.3.0'], reason: 'the listing\'s version, as new as the one synced or newer');

      // What B applied isn't a change of B's own: the list stands as A wrote it, nothing newer.
      expect(b.sync!.list['translate'], a.sync!.list['translate']);
    });

    test('a pack whose listing isn\'t here yet waits, and is added once it is', () async {
      final a = device(relay);
      a.plugins['xweather'] = true;
      a.packVersions['xweather'] = '1.2.0';
      await a.sync!.sync();

      final b = device(relay);
      await b.sync!.sync();
      expect(b.fetched, isEmpty);
      b.listings['weather'] = '1.1.0';
      await b.sync!.applyPending();
      expect(b.fetched, isEmpty, reason: 'an older listing than the version synced is not taken');
      b.listings['weather'] = '1.2.0';
      await b.sync!.applyPending();
      expect(b.fetched, ['weather@1.2.0']);
      await b.sync!.applyPending();
      expect(b.fetched, ['weather@1.2.0'], reason: 'applied once');
    });

    test('an iPhone (no packs) gives up on a pack quietly', () async {
      final a = device(relay);
      a.plugins['xweather'] = true;
      a.packVersions['xweather'] = '1.2.0';
      await a.sync!.sync();
      final phone = device(relay, packs: false);
      await phone.sync!.sync();
      expect(phone.fetched, isEmpty);
      expect(jsonDecode(phone.prefs[PluginSync.stateKey]!)['applied'], contains('xweather'));
    });

    test('off: switched off where the person switched it off, but a network signed in here stays signed in', () async {
      final a = device(relay);
      final b = device(relay);
      for (final d in [a, b]) {
        d.plugins.addAll({'translate': true, 'netmatrix': true, 'netteams': true});
        d.networks.addAll({'netmatrix', 'netteams'});
        d.explicit.add('translate');
      }
      b.signedIn.add('netmatrix');
      await a.sync!.sync();
      await b.sync!.sync();
      expect(b.turns, isEmpty, reason: 'both devices had the same: nothing to do');

      a.clock = 5000;
      a.press('translate', false);
      a.press('netmatrix', false);
      a.press('netteams', false);
      await a.sync!.sync();
      await b.sync!.sync();
      expect(b.plugins['translate'], isFalse);
      expect(b.plugins['netteams'], isFalse, reason: 'not signed in here: switched off');
      expect(b.plugins['netmatrix'], isTrue, reason: 'signed in here: sync never ends a session');
    });

    test('a plugin no line names is left alone; a default is never pushed onto another device', () async {
      final a = device(relay);
      a.plugins['spam'] = true; // on by default, never switched
      await a.sync!.sync();
      final b = device(relay);
      b.plugins['spam'] = false;
      b.explicit.add('spam'); // switched off by hand on B
      await b.sync!.sync();
      expect(b.plugins['spam'], isFalse, reason: 'A\'s default isn\'t a choice');
      await a.sync!.sync();
      expect(a.plugins['spam'], isFalse, reason: 'B\'s explicit off is the person\'s choice, and syncs as off');
    });

    test('first syncs join what each device had: on beats off when both were chosen before syncing', () async {
      final a = device(relay);
      a.plugins['translate'] = false;
      a.explicit.add('translate');
      final b = device(relay);
      b.plugins['translate'] = true;
      b.explicit.add('translate');
      await a.sync!.sync();
      await b.sync!.sync();
      await a.sync!.sync();
      expect(a.plugins['translate'], isTrue);
      expect(b.plugins['translate'], isTrue);
    });

    test('switching back afterwards is a newer line, not undone by the old one', () async {
      final a = device(relay);
      final b = device(relay);
      for (final d in [a, b]) {
        d.plugins['translate'] = false;
      }
      await a.sync!.sync();
      await b.sync!.sync();
      a.clock = 3000;
      a.press('translate', true);
      await a.sync!.sync();
      await b.sync!.sync();
      expect(b.plugins['translate'], isTrue);
      b.clock = 2000; // B's clock is behind A's: still later than the line it replaces
      b.press('translate', false);
      expect(b.sync!.list['translate']!.at, greaterThan(3000));
      await b.sync!.sync();
      await a.sync!.sync();
      expect(a.plugins['translate'], isFalse);
      await b.sync!.sync();
      expect(b.plugins['translate'], isFalse);
    });

    test('a switch moved through the registry is a line; moved by the sync itself it is not', () async {
      final a = device(relay);
      a.sync!.attachHooks();
      addTearDown(() => PluginRegistry.switched = null);
      final registry = PluginRegistry([const TranslatePlugin()]);
      final store = MemoryStore();
      a.clock = 4000;
      registry.setOn(const TranslatePlugin(), store, true);
      expect(a.sync!.list['translate'], on(4000));

      // B applies A's line: the switch it moves (FakeDevice.turn tells the sync, as the registry does) adds nothing.
      await a.sync!.sync();
      final b = device(relay);
      b.plugins['translate'] = false;
      b.clock = 9000;
      await b.sync!.sync();
      expect(b.turns, ['translate on']);
      expect(b.sync!.list['translate'], on(4000));
    });

    test('nothing happens without an account, or with sync switched off', () async {
      final a = device(relay);
      a.hasAccount = false;
      a.plugins['translate'] = true;
      a.explicit.add('translate');
      await a.sync!.sync();
      expect(relay.writes, 0);

      final b = device(relay);
      b.prefs[PluginSync.onKey] = 'off';
      b.plugins['translate'] = true;
      b.press('translate', true);
      await b.sync!.sync();
      expect(relay.writes, 0);
      expect(b.prefs[PluginSync.stateKey], isNull, reason: 'switched off, nothing is even noted');
    });

    test('a blob that can\'t be read is never written over', () async {
      final a = device(relay);
      a.plugins['translate'] = true;
      a.explicit.add('translate');
      relay.unreadable = true;
      await a.sync!.sync();
      expect(relay.writes, 0);
    });

    test('a list kept for another account is not carried into this one', () async {
      final a = device(relay);
      a.plugins['translate'] = true;
      a.press('translate', true);
      await a.sync!.sync();
      expect(relay.opened()!['plugins'], isNotNull);

      final other = FakeRelay(Me.curlKeyOf(AccountCrypto.wordsOf(List.filled(16, 5))));
      final moved = FakeDevice(other, accountId: 'acct-2')
        ..prefs.addAll(a.prefs)
        ..plugins['translate'] = false;
      moved.sync = PluginSync(host: moved);
      await moved.sync!.sync();
      expect(PluginSyncList.parse(other.opened()?['plugins']), isEmpty, reason: 'acct-1\'s line stays acct-1\'s');
    });

    test('a sync writes only where the list changed, and keeps the cURL entries', () async {
      relay.sealed = PluginSyncList.seal(relay.key, {'v': 1, 'entries': {'messenger': {'cookies': {'c_user': '1'}, 'at': 3}}});
      final a = device(relay);
      a.plugins['translate'] = true;
      a.press('translate', true);
      await a.sync!.sync();
      expect(relay.writes, 1);
      expect((relay.opened()!['entries'] as Map).keys, ['messenger']);
      await a.sync!.sync();
      expect(relay.writes, 1, reason: 'nothing new: nothing written');
    });
  });
}
