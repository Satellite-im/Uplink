import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/gm/rcs_share.dart';

/// GMFB-11 (@kevin, Android 0.11.4: "Syncing the rcs setting between connected devices would be really cool"): the
/// phone tells its paired computers how RCS stands, so a computer says "on through your phone" rather than asking to
/// be set up again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ghost_messaging/sms');
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('the phone answers from its Google Messages web session and its RCS setup', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'gmWebState') return {'paired': true, 'connected': true, 'phone': '+15550100'};
      return null;
    });
    final app = AppState()
      ..setFlag('rcs_setup', true)
      ..setFlag('rcs_on_chosen', true);
    final said = RcsState.fromJson((await RcsShare.answer(app))! as Map);
    expect((said.webPaired, said.webConnected, said.setUp, said.rcsOn, said.phone), (true, true, true, true, '+15550100'));
    expect(said.throughPhone, isTrue);
  });

  test('a phone with no web session: nothing comes through it, and the computer offers its own setup', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => call.method == 'gmWebState' ? {'paired': false} : null);
    final said = RcsState.fromJson((await RcsShare.answer(AppState()))! as Map);
    expect(said.throughPhone, isFalse);
  });

  test('the computer reads what its phone said; a phone that cannot say reads as nothing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'rcs') return {'webPaired': true, 'webConnected': false, 'setUp': true, 'rcsOn': false, 'phone': ''};
      return null;
    });
    final s = await RcsShare.ofPhone();
    expect((s?.throughPhone, s?.webConnected), (true, false));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'old', message: 'Update Uplink on your phone'));
    expect(await RcsShare.ofPhone(), isNull);
  });
}
