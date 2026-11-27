import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/inbox/inbox.dart';
import 'package:ghost_messaging/kit/settings_kit.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/me/pictures.dart';
import 'package:ghost_messaging/ui/sign_up_from.dart';

import 'support/space_call_harness.dart';

/// Signing up from an account someone already has (Matt, 2026-11-19: "add a sign up with discord sign up with telegram
/// or signal option where it pre populates your connection, loads your picture and username and status as well as
/// other details during signup so users don't need to fill everything in manually").
Future<Uint8List> _png(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF5865F2));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (_) async => null));

  test('a handle is made an Uplink username where it can be one; a status is cut to fit', () {
    expect(usernameFrom('@Maya.Chen'), 'maya.chen');
    expect(usernameFrom('maya-chen_99'), 'mayachen_99');
    expect(usernameFrom('ab'), '', reason: 'too short to be one');
    expect(usernameFrom('a_very_long_handle_indeed_yes'), 'a_very_long_handle_i');
    expect(statusFrom('  out\nfor   lunch '), 'out for lunch');
    expect(statusFrom('x' * 200).length, Me.statusMost);
  });

  test('Discord: its username, name and picture', () async {
    final png = await _png(512, 300);
    final asked = <String>[];
    fetchPicture = (url) async {
      asked.add(url);
      return png;
    };
    final got = await signUpFromDiscord('Maya', {'name': 'Maya Chen', 'picture': 'https://cdn.discordapp.com/avatars/1/a.png?size=256'});
    expect((got.from, got.username, got.name, got.status), ('Discord', 'maya', 'Maya Chen', ''));
    expect(asked, ['https://cdn.discordapp.com/avatars/1/a.png?size=256']);
    expect(got.picture, isNotNull, reason: 'made square, as a profile keeps it');
    expect(got.picture!.sharp.length, lessThanOrEqualTo(ProfilePictures.sharpMost));
    expect(got.picture!.small.length, lessThanOrEqualTo(ProfilePictures.oldMost), reason: 'what builds from before take');
  });

  test('Telegram: the bio is the status (and the bio); Signal: its About line and emoji', () async {
    final dir = await Directory.systemTemp.createTemp('signup');
    final file = File('${dir.path}/me.png')..writeAsBytesSync(await _png(200, 200));
    final tg = await signUpFromInbox('Telegram', InboxProfile(network: 'telegram', id: '42', name: 'Maya Chen', username: 'mayac', bio: 'Building things', avatar: file.path));
    expect((tg.username, tg.name, tg.status, tg.bio), ('mayac', 'Maya Chen', 'Building things', 'Building things'));
    expect(tg.picture, isNotNull);
    final sig = await signUpFromInbox('Signal', const InboxProfile(network: 'signal', id: 'aci', name: 'Maya', bio: 'On holiday', status: '🌴'));
    expect((sig.username, sig.name, sig.status, sig.bio, sig.picture), ('', 'Maya', '🌴 On holiday', '', null));
    await dir.delete(recursive: true);
  });

  test('Discord\'s sign-in is waited for, and what the relay heard of the account comes back', () async {
    final me = Me.forTest()..asking = (what) async => {'dir': 'link', 'p': what['p'], 'url': 'https://gogho.st/link/discord?s=abc'};
    String? opened;
    final pending = me.signInWith('discord', (url) async {
      opened = url;
      return true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(opened, 'https://gogho.st/link/discord?s=abc');
    me.hear({'dir': 'linked', 'p': 'discord', 'handle': 'maya', 'k': 'x', 'about': {'name': 'Maya Chen', 'picture': 'https://cdn/p.png'}});
    final got = await pending;
    expect(got!.handle, 'maya');
    expect(got.about, {'name': 'Maya Chen', 'picture': 'https://cdn/p.png'});
    expect(me.links['discord'], 'maya', reason: 'linked, as Settings › Me links it');
  });

  testWidgets('the choices and what was filled in, drawn', (tester) async {
    final h = await SpaceHarness.load(tester);
    Me.instance.seed(ways: {'discord': 'signin'});
    final picture = await tester.runAsync(() async => signUpFromInbox('Telegram', InboxProfile(network: 'telegram', id: '1', name: 'Maya Chen', username: 'maya', bio: 'Building things')));
    await h.shoot(
      tester,
      Builder(
        builder: (context) => ColoredBox(
          color: const Color(0xFFFFFFFF),
          child: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(padding: const EdgeInsets.all(24), children: [
              SignUpFromSection(onFilled: (_) {}),
              const SizedBox(height: 24),
              SignUpFilled(profile: picture!, onClear: () {}),
            ]),
          ),
        ),
      ),
      'sign-up-from',
    );
    expect(find.text('Sign up with Discord'), findsOneWidget);
    expect(find.text('Maya Chen'), findsOneWidget);
    expect(find.text('From Telegram'), findsOneWidget);
  });
}
