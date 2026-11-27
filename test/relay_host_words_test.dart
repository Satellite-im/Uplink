import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/relay_host/relay_host_io.dart';
import 'package:ghost_messaging/relay_host/words.dart';

import 'support/host_support.dart';

/// What the screens say of a relay hosted from the app, held to what is true (the second review, 2026-11-23): what a
/// friend sends waits on their relay, about 200 at most, for three days, and is lost if it restarts; what this app sends
/// to friends elsewhere doesn't reach them while the link is down; a hosted relay keeps no accounts; a closed Android
/// app can't check one. And the local network's door: listed and taken only at private addresses, never mobile data.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('moving onto it says what waits where, and for how long, and what doesn\'t work there', () {
    final w = moveHereWords('gogho.st');
    expect(w, contains('about 200 messages at most, for up to three days, and lost if that relay restarts'));
    expect(w, contains('what you send to friends elsewhere doesn\'t reach them until it is back'));
    expect(w, isNot(contains('a week')), reason: 'nothing waits a week');
    expect(w, contains(keepsNoAccountsWords));
    expect(keepsNoAccountsWords, allOf(contains('adding a device'), contains('backup'), contains('deleting your account'), contains('by username')));
  });

  test('a joiner is told it keeps no accounts, and that a closed Android app can\'t check it', () {
    expect(joinHostedWords, contains(keepsNoAccountsWords));
    expect(joinHostedWords, contains(closedPhoneWords));
  });

  test('the door\'s addresses: private ones on a network of the device\'s own, never mobile data', () {
    InternetAddress a(String s) => InternetAddress(s);
    expect(RelayHost.lanAddressOk('wlan0', a('192.168.1.20')), isTrue);
    expect(RelayHost.lanAddressOk('en0', a('10.0.0.4')), isTrue);
    expect(RelayHost.lanAddressOk('eth0', a('172.20.0.2')), isTrue);
    expect(RelayHost.lanAddressOk('rmnet_data0', a('10.120.4.9')), isFalse, reason: 'Android mobile data, a private address all the same');
    expect(RelayHost.lanAddressOk('ccmni1', a('10.1.2.3')), isFalse);
    expect(RelayHost.lanAddressOk('v4-rmnet_data0', a('192.0.0.4')), isFalse);
    expect(RelayHost.lanAddressOk('wlan0', a('100.72.1.5')), isFalse, reason: 'a carrier\'s shared range is not a local network');
    expect(RelayHost.lanAddressOk('en0', a('203.0.113.9')), isFalse, reason: 'a public address');
    expect(RelayHost.lanAddressOk('en0', a('169.254.3.3')), isFalse);
  });

  test('a connection that came in at an address the door doesn\'t list is closed at once', () async {
    // The door listens here at 127.0.0.1, but lists only an address on another network.
    final host = makeHost(Kept(), lan: true, addresses: () async => const ['192.168.77.7']);
    addTearDown(host.shutdown);
    await host.setOn(true);
    final port = Uri.parse(host.lanUrls.single).port;
    expect(host.lanUrls.single, 'ws://192.168.77.7:$port/hub');
    final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
    s.done.then((_) {}, onError: (Object _) {});
    var closed = false;
    s.listen((_) {}, onDone: () => closed = true, onError: (Object _) => closed = true);
    await waitFor(() => closed, 'a connection at an unlisted address was kept');
    expect(host.doorClosed, 1);
    expect(host.doorOpen, 0);
  });
}
