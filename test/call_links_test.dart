import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/voice_screen.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/voice/rtc.dart';

import 'support/list_harness.dart';

/// GMFB-4 (@kevin, Windows 0.11.3: "It would be great to show when users are connected to the call so they and others
/// know if they are having audio issues or if they are just not connected to the call"): each face in a call says how
/// this device's connection to that person stands, where it isn't simply through.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  test('a slow way through reads as poor', () {
    expect(RtcMedia.linkFor(0.08), PeerLink.connected);
    expect(RtcMedia.linkFor(0.4), PeerLink.connected);
    expect(RtcMedia.linkFor(0.75), PeerLink.poor);
    expect(PeerLink.connected.words, isNull, reason: 'nothing said while all is well');
    expect(PeerLink.failed.words, 'Can\'t connect');
  });

  testWidgets('a face and its row say connecting, poor or can\'t connect, and nothing once through', (tester) async {
    ListPhone(const []).install();
    final media = RtcMedia();
    Voice.instance.media = media;
    addTearDown(() => Voice.instance.media = null);
    final sheet = await loadSheet(tester);
    Widget person(String id) => Row(children: [
          LinkBadge(id: id, child: const SizedBox.square(dimension: 40)),
          LinkWords(id: id),
        ]);
    await pumpScreen(tester, sheet, Column(children: [person('maya'), person('sam'), person('me')]), AppState());

    media.links.value = {'maya': PeerLink.connecting, 'sam': PeerLink.failed};
    await settle(tester);
    expect(find.byKey(const ValueKey('link-maya-connecting')), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byKey(const ValueKey('link-sam-failed')), findsOneWidget);
    expect(find.text('Can\'t connect'), findsOneWidget);
    expect(find.byKey(const ValueKey('link-words-me')), findsNothing, reason: 'this device has no connection to itself');

    media.links.value = {'maya': PeerLink.poor, 'sam': PeerLink.connected};
    await settle(tester);
    expect(find.text('Poor connection'), findsOneWidget);
    expect(find.text('Can\'t connect'), findsNothing);
    expect(find.byKey(const ValueKey('link-sam-connected')), findsNothing, reason: 'connected: no badge, no words');
    expect(tester.takeException(), isNull);
  });
}
