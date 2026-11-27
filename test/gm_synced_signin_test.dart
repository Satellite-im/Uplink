import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/gm/google_signin_flow.dart';

import 'support/list_harness.dart';

/// GMFB-10 (@kevin, Android 0.11.4: "Getting rcs is annoying due to the workaround we are using so maybe making a
/// chrome extension to automate is a better solution"): the browser extension signs in to Google in a private window
/// and syncs that sign-in to the account; Google Messages' setup pairs with it in one press, no copying.
Future<void> _fonts() async {
  final loader = FontLoader('Inter Variable')..addFont(File('assets/fonts/InterVariable-latin.ttf').readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
  await loader.load();
}

const _google = {'SID': 's', 'HSID': 'h', 'SSID': 'ss', 'OSID': 'o', 'APISID': 'a', 'SAPISID': 'sa', '__Secure-1PSIDTS': 't'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  testWidgets('a synced sign-in pairs in one press, with exactly its cookies', (tester) async {
    ListPhone(const []).install();
    final sheet = await loadSheet(tester);
    Map<String, String>? paired;
    await pumpScreen(
      tester,
      sheet,
      SingleChildScrollView(
        child: GoogleSignInFlow(
          onPair: (c) async {
            paired = c;
            return null;
          },
          synced: () async => (cookies: _google, at: 1),
        ),
      ),
      AppState(),
    );
    await settle(tester);
    expect(find.text('Your browser has signed in for you'), findsOneWidget);
    await tester.tap(find.text('Use the Google sign-in from your browser'));
    await settle(tester);
    expect(paired, _google);
    expect(tester.takeException(), isNull);
  });

  testWidgets('with none synced (or one missing a cookie), it says where to get the extension, and the steps stay', (tester) async {
    ListPhone(const []).install();
    final sheet = await loadSheet(tester);
    await pumpScreen(
      tester,
      sheet,
      SingleChildScrollView(child: GoogleSignInFlow(onPair: (_) async => null, synced: () async => (cookies: const {'SID': 's'}, at: 1))),
      AppState(),
    );
    await settle(tester);
    expect(find.text('Or let your browser do steps 1 to 3'), findsOneWidget);
    expect(find.text('Use the Google sign-in from your browser'), findsNothing);
    expect(find.text('Sign in to Google in a private window'), findsOneWidget, reason: 'the steps by hand are still there');
  });
}
