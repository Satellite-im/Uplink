import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/hub_carrier.dart';
import 'package:ghost_messaging/net/net.dart' show Net;
import 'package:ghost_messaging/ui/profile.dart' show usernameWords;
import 'package:ghost_relay/handles.dart';
import 'package:ghost_relay/hub.dart';
import 'package:ghost_relay/relay.dart';

/// A username on each relay (GMFB-25: "The app works fully against a self-hosted hub"). A username is a name on one
/// relay; the app kept one, wherever it was claimed, and went on showing it after moving to another relay, where nobody
/// could find this person by it and it might be someone else's. Now, greeted by another relay than the last, it is
/// settled for that relay (Me, lib/me/me.dart): claimed there where it is free, none where it is someone else's, and
/// the one it had on the relay it left kept for when it goes back. Against two real relays on this machine.

Future<void> _until(bool Function() done, {String? reason}) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: reason);
}

/// An install that can move from one relay to another, as Settings › Routes moves the app (Net.setHub): the route to
/// the old one stopped, one to the new one in its place, and the routes said to have changed.
class _Install {
  _Install(this.keys);
  final NetKeys keys;
  final store = MemoryMeStore();
  final routes = ChangeNotifier();
  late final Me me = Me.forTest();
  HubCarrier? hub;
  bool _started = false;

  Future<void> on(String url) async {
    await hub?.stop();
    final next = hub = HubCarrier(url: url, signer: KeysSigner(keys));
    await next.start();
    await _until(() => next.state.value == CarrierState.up, reason: next.problem);
    if (!_started) {
      _started = true;
      // Spoken to the relay before (it has claimed a name, say): greeted at every sign-in.
      store.setFlag('me_used', true);
      await me.start(store, routes, () => hub);
    } else {
      routes.notifyListeners();
    }
    await _until(() => store.choice(Me.relayName, '') == url, reason: 'the username was settled for $url');
  }

  Future<void> close() async => hub?.stop();
}

void main() {
  late Relay a, b;
  late String urlA, urlB;
  late Directory dirA, dirB;
  final made = <_Install>[];

  _Install install([NetKeys? keys]) {
    final i = _Install(keys ?? NetKeys.generate());
    made.add(i);
    return i;
  }

  setUp(() async {
    dirA = Directory.systemTemp.createTempSync('names-a');
    dirB = Directory.systemTemp.createTempSync('names-b');
    a = Relay(hub: Hub(handles: Handles(dataDir: dirA, config: const HandlesConfig(publicUrl: 'http://127.0.0.1'))));
    b = Relay(hub: Hub(handles: Handles(dataDir: dirB, config: const HandlesConfig(publicUrl: 'http://127.0.0.1'))));
    urlA = 'ws://127.0.0.1:${await a.start(port: 0)}/hub';
    urlB = 'ws://127.0.0.1:${await b.start(port: 0)}/hub';
  });
  tearDown(() async {
    for (final i in made) {
      await i.close();
    }
    made.clear();
    await a.stop();
    await b.stop();
    dirA.deleteSync(recursive: true);
    dirB.deleteSync(recursive: true);
  });

  test('moved to a relay where the name is free, it is claimed there too: found by it on both, and still its own when it goes back', () async {
    final maya = install(), asker = install();
    await maya.on(urlA);
    await maya.me.claimUsername('maya');
    await maya.on(urlB);
    expect([maya.me.username, maya.me.nameTaken], ['maya', null]);
    await asker.on(urlB);
    expect((await asker.me.whois('maya'))?.id, maya.keys.id, reason: 'people on the new relay find her by it');
    expect(await maya.me.heldName(), Me.nameKeyOf('maya'));
    expect(jsonDecode(maya.store.choice(Me.namesName, '{}')), {urlA: 'maya', urlB: 'maya'});
    await maya.on(urlA);
    expect(maya.me.username, 'maya');
    await asker.on(urlA);
    expect((await asker.me.whois('maya'))?.id, maya.keys.id);
  });

  test('where someone else holds the name on the new relay, it has none there and says so; one chosen there is its name there, and the first is its name again back on the first relay', () async {
    final maya = install(), other = install();
    await other.on(urlB);
    await other.me.claimUsername('maya');
    await maya.on(urlA);
    await maya.me.claimUsername('maya');
    var told = 0;
    maya.me.addListener(() => told++);
    await maya.on(urlB);
    expect(maya.me.username, isNull, reason: 'never shown a name that is someone else\'s here');
    expect(maya.me.nameTaken, (name: 'maya', relay: urlB));
    expect(told, greaterThan(0));
    expect((await maya.me.whois('maya'))?.id, other.keys.id, reason: 'and the other person keeps it');
    // She chooses one for this relay.
    await maya.me.claimUsername('maya_c');
    expect([maya.me.username, maya.me.nameTaken], ['maya_c', null]);
    // Back where she came from, she is @maya; and @maya_c again on the second, with nothing claimed anew.
    await maya.on(urlA);
    expect(maya.me.username, 'maya');
    expect(await maya.me.heldName(), Me.nameKeyOf('maya'));
    await maya.on(urlB);
    expect([maya.me.username, maya.me.nameTaken], ['maya_c', null]);
    expect(await maya.me.heldName(), Me.nameKeyOf('maya_c'));
  });

  test('a name the account claimed on the new relay from another device is the one shown there, as the relay spells it', () async {
    final keys = NetKeys.generate();
    final phone = install(keys), mac = install(keys);
    await phone.on(urlA);
    await phone.me.claimUsername('maya');
    // Her Mac, already on the second relay, claimed another name there.
    await mac.on(urlB);
    await mac.me.claimUsername('maya_at_home');
    await mac.close();
    await phone.on(urlB);
    expect([phone.me.username, phone.me.nameTaken], ['maya_at_home', null]);
    expect(jsonDecode(phone.store.choice(Me.namesName, '{}')), {urlA: 'maya', urlB: 'maya_at_home'});
  });

  test('given up on a relay, a name is not claimed again by itself when the app comes back to that relay', () async {
    final maya = install(), other = install();
    await maya.on(urlA);
    await maya.me.claimUsername('maya');
    await maya.on(urlB);
    expect(maya.me.username, 'maya');
    await maya.me.releaseUsername();
    expect(maya.me.username, isNull);
    await maya.on(urlA);
    expect(maya.me.username, 'maya');
    await maya.on(urlB);
    expect(maya.me.username, isNull, reason: 'she gave it up here: not claimed for her again, though she goes by it elsewhere');
    await other.on(urlB);
    expect(await other.me.whois('maya'), isNull);
    // She claims one here herself again: hers here from then on, as before.
    await maya.me.claimUsername('maya');
    await maya.on(urlA);
    await maya.on(urlB);
    expect(maya.me.username, 'maya');
    expect(await maya.me.heldName(), Me.nameKeyOf('maya'));
  });

  test('someone who used a relay of their own before this was kept keeps the name they hold there; on Uplink\'s relay nothing is asked or changed at all', () async {
    // Their choices from before: a username, and no word of which relay it was claimed on.
    final sam = install();
    await sam.on(urlB);
    await sam.me.claimUsername('sam');
    sam.store
      ..set(Me.relayName, '')
      ..set(Me.namesName, '');
    await sam.on(urlB);
    expect([sam.me.username, sam.me.nameTaken], ['sam', null]);
    expect(jsonDecode(sam.store.choice(Me.namesName, '{}'))[urlB], 'sam');
    // On Uplink's own relay the first greeting only notes which relay it is.
    final me = Me.forTest();
    final store = MemoryMeStore()..set('me_username', 'matt');
    await me.start(store, ChangeNotifier(), () => null);
    var asked = 0;
    me.asking = (what) async {
      asked++;
      return const {};
    };
    await me.relayGreeted(Net.defaultHub);
    expect([asked, me.username, store.choice(Me.relayName, ''), store.choice(Me.namesName, '')], [0, 'matt', Net.defaultHub, '']);
    await me.relayGreeted(Net.defaultHub);
    expect(asked, 0);
  });

  test('what the profile page says under Username', () {
    expect(usernameWords('maya'), 'People add you as @maya.');
    expect(usernameWords(null), 'How people find you to add you as a friend. Nobody sees your number.');
    expect(usernameWords(null, taken: (name: 'maya', relay: 'wss://relay.example.com/hub')),
        '@maya belongs to someone else on relay.example.com, so you have no username on this relay yet: choose one for it here. On the relay you came from you are still @maya.');
    expect(usernameWords('maya_c', taken: (name: 'maya', relay: 'wss://relay.example.com/hub')), 'People add you as @maya_c.');
  });

  test('the relay says which name a key holds with its letters, and only to that key\'s holder', () async {
    final maya = install(), other = install();
    await maya.on(urlA);
    await other.on(urlA);
    await maya.me.claimUsername('Maya.K');
    final said = <Map<String, dynamic>>[];
    final sub = maya.hub!.handles.listen(said.add);
    maya.hub!.sayHandles({'dir': 'name'});
    await _until(() => said.any((m) => m['dir'] == 'name'));
    expect(said.lastWhere((m) => m['dir'] == 'name'), containsPair('n', 'maya.k'));
    final theirs = <Map<String, dynamic>>[];
    final sub2 = other.hub!.handles.listen(theirs.add);
    other.hub!.sayHandles({'dir': 'name'});
    await _until(() => theirs.any((m) => m['dir'] == 'name'));
    expect(theirs.lastWhere((m) => m['dir'] == 'name')['k'], isNull);
    expect(theirs.lastWhere((m) => m['dir'] == 'name').containsKey('n'), isFalse);
    await sub.cancel();
    await sub2.cancel();
  });
}
