import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/looks.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides;
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/lan/lan_carrier.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/ui/network.dart';
import 'package:ghost_messaging/ui/settings.dart' show SettingsModel;
import 'package:glacier/glacier.dart';

import 'support/direct_world.dart' show PlainCarrier;
import 'support/fake_lan.dart';

/// The local network route as the app holds it (lib/net/net.dart; GMFB-24): there only where the build has the ground
/// for one, made with the other routes and left off until the person switches it on, after the relay and the direct
/// route in the order, linking with friends and nobody else the routes reach, kept in step with how the person chose to
/// be shown and the app being put away, and closed at sign-out. And what Settings › Routes shows of it. The phone under
/// it is a stand-in channel, as test/p2p_net_test.dart's; the network is test/support/fake_lan.dart's.

Future<void> _until(bool Function() ok, String what) async {
  for (var i = 0; i < 1000 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(ok(), isTrue, reason: what);
}

/// Every piece of text drawn in the row keyed [key].
List<String> _words(WidgetTester tester, String key) => [for (final t in tester.widgetList<Text>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Text)))) ?t.data];

Future<void> _pump(WidgetTester tester, AppState state, Listenable listenable, List<Widget> Function(BuildContext) rows) async {
  tester.view.physicalSize = const Size(412, 4200) * 2.0;
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
  installSettingsStyles(sheet);
  await tester.pumpWidget(AppScope(
    state: state,
    child: WidgetsApp(
      color: const Color(0xFF000000),
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(sheet: sheet, attrs: ghostAttrs(state, 'mobile'), child: InkOverrides(child: GlacierToastProvider(child: child!))),
      home: ListenableBuilder(listenable: listenable, builder: (context, _) => ListView(children: rows(context))),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final me = NetKeys.generate();
  // A friend by username, and a member of a group this phone is in, who is no friend.
  final sam = NetKeys.generate(), member = NetKeys.generate();
  Uint8List keyWith(NetKeys them) => NetCrypto.netKey(NetCrypto.conversationKey(me, them.public)!);
  late Map<String, String> secrets;
  late List<String> asked;
  late FakeLan lan;
  late FakeLanGround ground;
  final others = <LanCarrier>[];

  /// Another person's device on the network, which says it is here to this account and links with it.
  LanCarrier deviceOf(NetKeys who, String address) {
    final c = LanCarrier(
      me: who.id,
      ground: lan.join(address),
      people: () => [Peer(id: me.id, key: keyWith(who))],
      policy: const LanPolicy(beatEvery: Duration(milliseconds: 40), yieldFor: Duration(milliseconds: 30), sleepsAway: false),
      random: Random(others.length + 7),
    );
    others.add(c);
    return c;
  }

  setUp(() {
    HttpOverrides.global = null;
    secrets = {};
    asked = [];
    lan = FakeLan();
    ground = lan.join('192.168.1.10');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
      final a = call.arguments is Map ? call.arguments as Map : const {};
      asked.add(call.method);
      switch (call.method) {
        case 'netIdentity':
          return {'id': me.id, 'key': base64Encode(me.public)};
        case 'netSign':
          return NetCrypto.sign(me, (a['message'] as List).cast<int>());
        case 'netPeers':
          return [
            {'id': sam.id, 'address': '@sam', 'key': keyWith(sam)},
            {'id': member.id, 'address': '+15550000002', 'key': keyWith(member)},
          ];
        case 'e2eList':
          return [
            {'address': '+15550000002', 'state': 'on', 'friend': '', 'id': member.id},
          ];
        case 'buddiesKept':
          return jsonEncode([
            {'u': 'sam', 'i': sam.id, 'k': base64Encode(sam.public), 's': 'yes'},
          ]);
        case 'netSmsDrain':
          return const <Object>[];
        case 'secretKeep':
          final value = '${a['value'] ?? ''}';
          value.isEmpty ? secrets.remove('${a['name']}') : secrets['${a['name']}'] = value;
          return null;
        case 'secretRead':
          return secrets['${a['name']}'];
      }
      return null;
    });
  });
  tearDown(() async {
    for (final c in others) {
      await c.dispose();
    }
    others.clear();
    await Net.instance.shutdown();
    Net.lanGround = Net.defaultLanGround;
    Net.lanSayEvery = const Duration(seconds: 20);
  });

  test('under a test, and in a build with no ground for one, there is no local network route', () async {
    expect(Net.lanGround(), isNull, reason: 'never this machine\'s own sockets under a test unless it says so');
    await Net.instance.start(AppState()..set(Net.lanName, 'on'), carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
    expect([Net.instance.lan, Net.instance.lanOn], [null, false]);
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'sms']);
    await Net.instance.setRoute('lan', true);
    expect([Net.instance.lan, Net.instance.lanOn], [null, false]);
  });

  test('it starts off: made with the routes and after the relay\'s, opening nothing and asking nobody who is a friend, its choice its own', () async {
    Net.lanGround = () => ground;
    final app = AppState();
    await Net.instance.start(app, carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
    expect([Net.lanByDefault, Net.instance.lanOn], [false, false]);
    expect(Net.instance.board!.carriers.map((c) => c.id), ['hub', 'lan', 'sms']);
    expect(Net.instance.board!.off, {'p2p', 'lan'}, reason: 'Direct, which this build has none of, and the local network, which nobody switched on');
    expect(Net.instance.lan!.state.value, CarrierState.off);
    expect([ground.airs, ground.doors], [0, 0], reason: 'no port is opened');
    expect(lan.beacons, isEmpty, reason: 'and nothing said on the network');
    expect(asked, isNot(anyOf(contains('buddiesKept'), contains('e2eList'))), reason: 'nobody was asked who is a friend');
    // Another route switched off is kept as ever, and the local network's is never written among them.
    await Net.instance.setRoute('sms', false);
    expect([app.choice('net_off', ''), app.choice(Net.lanName, '')], ['sms', '']);
  });

  test('switched on: friends are asked, it links with a friend\'s device and not a group member\'s, carries to them, and follows how the person is shown and the app being put away', () async {
    Net.lanGround = () => ground;
    final app = AppState();
    await Net.instance.start(app, carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
    var changes = 0;
    Net.instance.addListener(() => changes++);
    await Net.instance.setRoute('lan', true);
    expect([app.choice(Net.lanName, ''), app.choice('net_off', ''), Net.instance.lanOn], ['on', '', true]);
    expect(Net.instance.board!.off, {'p2p'});
    expect(asked, containsAll(['buddiesKept', 'e2eList']));
    expect(Net.instance.friends.map((p) => p.id), [sam.id]);
    final mine = Net.instance.lan!;
    await _until(() => mine.state.value == CarrierState.up, 'it opened');
    expect([ground.airs, ground.doors], [1, 1]);
    // Sam's device and the group member's are both on the network, and both say they are here to this account.
    final sams = deviceOf(sam, '192.168.1.20'), members = deviceOf(member, '192.168.1.30');
    final atSams = <Arrived>[];
    sams.arrived.listen(atSams.add);
    await sams.start();
    await members.start();
    final before = changes;
    await mine.beat();
    await _until(() => mine.links.length == 1 && sams.links.length == 1, 'linked with Sam\'s device');
    await _until(() => changes > before, 'and the routes are said to have changed, so what waits for an answer goes again');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(mine.links.map((l) => l.peer), [sam.id], reason: 'never the group member\'s, who is no friend');
    expect(members.links, isEmpty);
    // Sam's device goes and comes back four times in a moment. Each link made said the routes had changed, and each
    // time everything unanswered was sent again: whoever could make a link come and go had that done at will. Now a
    // link lost says nothing, and links made within the quiet time are said once, when it is up.
    Net.lanSayEvery = const Duration(seconds: 3);
    final quiet = changes;
    for (var i = 0; i < 4; i++) {
      await sams.stop();
      await _until(() => mine.links.isEmpty, 'gone');
      await sams.start();
      await mine.beat();
      await _until(() => mine.links.length == 1 && sams.links.length == 1, 'back');
    }
    expect(changes - quiet, lessThanOrEqualTo(1));
    await _until(() => changes > quiet, 'said once the quiet time is up, not lost');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(changes - quiet, inInclusiveRange(1, 2), reason: 'never once for each');
    // By the local network alone, as Settings › Routes' test sends it.
    final d = await Net.instance.send(Net.instance.byId(sam.id)!, Envelope(kind: 'text', ack: false), only: {'lan'});
    expect([d.via, d.handed], ['lan', Handed.passed]);
    await _until(() => atSams.length == 1, 'it came to Sam\'s device');
    expect(Packet.parse(atSams.single.bytes)!.from, me.id);
    expect(Net.instance.board!.used[sam.id]!.sentBy, 'lan');
    // The group member is not reached by it at all.
    final m = await Net.instance.send(Net.instance.byId(member.id)!, Envelope(kind: 'text', ack: false), only: {'lan'});
    expect(m.sent, isFalse);
    // Invisible: let go of, and found again when shown.
    Net.instance.setMode('invisible');
    await _until(() => mine.links.isEmpty && sams.links.isEmpty, 'Invisible lets go of a friend\'s device');
    Net.instance.setMode('online');
    await _until(() => mine.links.length == 1, 'shown again, linked again');
    // A phone put away closes everything; back, it opens again.
    Net.instance.setAway(true);
    await _until(() => mine.links.isEmpty && sams.links.isEmpty, 'put away, it closes');
    Net.instance.setAway(false);
    await _until(() => mine.links.length == 1, 'and opens again as the app comes back');
    // Switched off: closed, and said nowhere.
    await Net.instance.setRoute('lan', false);
    expect([app.choice(Net.lanName, ''), Net.instance.lanOn, mine.state.value, mine.links], ['off', false, CarrierState.off, isEmpty]);
    expect(Net.instance.board!.off, {'p2p', 'lan'});
    final said = lan.beacons.where((b) => b.from == '192.168.1.10').length;
    await mine.beat();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(lan.beacons.where((b) => b.from == '192.168.1.10').length, said);
  });

  test('switched on before the app starts, it is on from the start, whatever net_off says of it; signing out closes it', () async {
    Net.lanGround = () => ground;
    final app = AppState()
      ..set(Net.lanName, 'on')
      ..set('net_off', 'lan');
    await Net.instance.start(app, carriers: [PlainCarrier('hub'), PlainCarrier('sms')]);
    expect([Net.instance.lanOn, Net.instance.board!.off], [true, {'p2p'}]);
    final mine = Net.instance.lan!;
    await _until(() => mine.state.value == CarrierState.up, 'it opened');
    expect(Net.instance.friends.map((p) => p.id), [sam.id], reason: 'who is a friend was asked for it, with Direct off');
    final sams = deviceOf(sam, '192.168.1.20');
    await sams.start();
    await mine.beat();
    await _until(() => mine.links.length == 1, 'linked');
    await Net.instance.shutdown();
    expect([Net.instance.lan, mine.state.value, mine.links], [null, CarrierState.off, isEmpty]);
    await _until(() => sams.links.isEmpty, 'the other end saw it go');
  });

  group('Settings › Routes', () {
    test('what the rows say', () {
      expect([lanFoundWords(0), lanFoundWords(1), lanFoundWords(3)], ['Nobody\'s device found on this network yet', 'Found 1 device on this network', 'Found 3 devices on this network']);
      expect([lanLinkedWords(0), lanLinkedWords(1), lanLinkedWords(2)], ['Not linked to any now', 'Linked to 1 device now', 'Linked to 2 devices now']);
      expect(LanCarrier.aboutWords, startsWith('Straight between your devices and your friends\' while they are on the same Wi-Fi or wired network as this one, with no server and no internet.'));
      expect(routesFooter(directOffered: true, lanOffered: true), isNull);
      expect(routesFooter(directOffered: false, lanOffered: true), 'A direct route between devices, with no server, isn\'t in this build yet.');
      expect(routesFooter(directOffered: true, lanOffered: false, lanMissing: 'A browser can\'t reach other devices on the network by itself.'), 'No local network route here: A browser can\'t reach other devices on the network by itself.');
    });

    testWidgets('the local network is listed with the routes, off; switched on, its own section says what is found and linked', (tester) async {
      Net.lanGround = () => ground;
      final state = AppState();
      await tester.runAsync(() => Net.instance.start(state, carriers: [PlainCarrier('hub'), PlainCarrier('sms')]));
      final model = SettingsModel(state);
      addTearDown(model.dispose);
      await _pump(tester, state, Listenable.merge([Net.instance, Net.instance.direct]), (context) => networkPane(context, model));
      expect(_words(tester, 'route-lan'), ['Local network', 'Off\n${LanCarrier.aboutWords}']);
      expect(tester.widget<GlacierSwitch>(find.descendant(of: find.byKey(const ValueKey('route-lan')), matching: find.byType(GlacierSwitch))).checked, isFalse);
      expect(find.text('LOCAL NETWORK'), findsNothing, reason: 'no section of its own while it is off');
      expect(find.byKey(const ValueKey('lan-seen')), findsNothing);
      // Its row comes after the relay's and before SMS, as the routes are tried.
      final ys = [for (final id in ['hub', 'lan', 'sms']) tester.getTopLeft(find.byKey(ValueKey('route-$id'))).dy];
      expect(ys, orderedEquals([...ys]..sort()));
      // Switched on by its switch.
      final change = tester.widget<GlacierSwitch>(find.descendant(of: find.byKey(const ValueKey('route-lan')), matching: find.byType(GlacierSwitch))).onCheckedChange!;
      await tester.runAsync(() async {
        change(true);
        await _until(() => Net.instance.lan!.state.value == CarrierState.up, 'it opened');
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.choice(Net.lanName, ''), 'on');
      expect(_words(tester, 'route-lan').last, 'Ready\n${LanCarrier.aboutWords}');
      expect(find.text('LOCAL NETWORK'), findsOneWidget);
      expect(_words(tester, 'lan-seen').first, 'Nobody\'s device found on this network yet');
      expect(_words(tester, 'lan-linked'), ['Not linked to any now']);
      // Sam's device joins the network.
      await tester.runAsync(() async {
        final sams = deviceOf(sam, '192.168.1.20');
        await sams.start();
        await Net.instance.lan!.beat();
        await _until(() => Net.instance.lan!.links.length == 1, 'linked');
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(_words(tester, 'lan-seen').first, 'Found 1 device on this network');
      expect(_words(tester, 'lan-linked'), ['Linked to 1 device now', '@sam at 192.168.1.20']);
      await tester.runAsync(() async {
        for (final c in others) {
          await c.dispose();
        }
        others.clear();
        await Net.instance.shutdown();
      });
      await tester.pumpWidget(const SizedBox());
    });
  });
}
