import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/shell.dart' show pillScrolledScale;
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/desktop/link/crypto.dart';
import 'package:ghost_messaging/desktop/link/link.dart';
import 'package:ghost_messaging/desktop/main.dart';
import 'package:ghost_messaging/desktop/remote.dart';
import 'package:ghost_messaging/desktop/store.dart';
import 'package:ghost_messaging/ui/nav_bar.dart';
import 'package:ghost_messaging/desktop/gm_web.dart';
import 'package:ghost_messaging/desktop/updates.dart';
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/ui/plugins_page/plugins_page.dart' show PluginsPage;
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/ui/common.dart';
import 'package:glacier/glacier.dart';

/// The Mac's screens, drawn at a window's size in light and dark and written to test/shots/mac-* (run with
/// `flutter test --update-goldens test/desk_screens_test.dart`): the wizard's steps, the conversations with one
/// open, and Settings. There is no phone here: the conversations are made up and answered below, where the app asks
/// the phone over the link (test/desk_link_test.dart is that).
final _now = DateTime.now();
int _ago({int days = 0, int hours = 0, int minutes = 0}) => _now.subtract(Duration(days: days, hours: hours, minutes: minutes)).millisecondsSinceEpoch;
Map<String, Object?> _p(String address, [String? name]) => {'address': address, 'name': name, 'photo': null};

final _conversations = <Map<String, Object?>>[
  {'id': 1, 'date': _ago(minutes: 4), 'people': [_p('+15551230001', 'Maya Chen')], 'snippet': 'Sounds good, see you at 7! Bring the projector cable if you still have it', 'unread': true, 'error': false, 'archived': false},
  {'id': 2, 'date': _ago(minutes: 52), 'people': [_p('+15551230002', 'Jordan Park'), _p('+15551230003', 'Sam Rivera')], 'snippet': 'Saturday works for me', 'unread': false, 'error': false, 'archived': false},
  {'id': 3, 'date': _ago(hours: 5), 'people': [_p('+15551230005', 'Dad')], 'snippet': 'Call me when you land', 'unread': false, 'error': false, 'archived': false, 'pinned': true},
  {'id': 4, 'date': _ago(days: 1, hours: 2), 'people': [_p('28849')], 'snippet': 'Your verification code is 482913.', 'unread': false, 'error': false, 'archived': false, 'muted': true},
  {'id': 8, 'date': _ago(days: 2), 'people': [_p('+15551230011', 'Riley Fox')], 'snippet': 'Only our two phones can read this now', 'unread': false, 'error': false, 'archived': false, 'encrypted': true},
  {'id': 7, 'date': _ago(days: 40), 'people': [_p('+15551230008', 'Old Thread')], 'snippet': 'ok', 'unread': false, 'error': false, 'archived': true},
];

final _messages = <Map<String, Object?>>[
  {'id': 12, 'kind': 'waiting', 'address': '', 'body': 'Leaving in ten', 'date': _ago(minutes: 1), 'outgoing': true, 'state': 'waiting', 'parts': const []},
  {'id': 6, 'kind': 'sms', 'address': '+15551230001', 'body': 'Sounds good, see you at 7! Bring the projector cable if you still have it', 'date': _ago(minutes: 4), 'outgoing': false, 'state': 'received'},
  {'id': 8, 'kind': 'sms', 'address': '+15551230001', 'body': '❤️ to “Dinner at mine first?”', 'date': _ago(minutes: 20), 'outgoing': false, 'state': 'received'},
  {'id': 5, 'kind': 'sms', 'address': '+15551230001', 'body': 'Dinner at mine first?', 'date': _ago(minutes: 30), 'outgoing': true, 'state': 'delivered'},
  {'id': 4, 'kind': 'sms', 'address': '+15551230001', 'body': 'Movie night is still on for tonight right?', 'date': _ago(minutes: 31), 'outgoing': true, 'state': 'delivered'},
  {'id': 3, 'kind': 'sms', 'address': '+15551230001', 'body': 'Here\'s the link https://example.com/tickets', 'date': _ago(days: 1, hours: 1), 'outgoing': false, 'state': 'received'},
  {'id': 1, 'kind': 'sms', 'address': '+15551230001', 'body': 'Hey! Long time 👋', 'date': _ago(days: 1, hours: 3), 'outgoing': false, 'state': 'received'},
];

/// The phone's answers, made up. What is the Mac's own (its choices) is still the Mac's ([LinkCalls]).
class _Calls extends LinkCalls {
  _Calls(super.link, super.store);

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    final a = (arguments as Map?) ?? const {};
    final Object? answer = switch (method) {
      'conversations' => _conversations,
      'conversationsPage' => {'items': [for (final c in _conversations) if ((c['archived'] == true) == (a['archived'] == true)) c], 'next': null},
      'conversation' => _conversations.where((c) => c['id'] == a['thread']).firstOrNull,
      'archivedCount' => 1,
      'messages' => a['thread'] == 1 ? _messages : const [],
      'people' => _conversations.firstWhere((c) => c['id'] == a['thread'])['people'],
      'e2e' => {'address': a['address'], 'state': a['address'] == '+15551230011' ? 'on' : 'none'},
      'draft' || 'markRead' || 'setDraft' || 'photo' || 'part' => null,
      // The Mac's choices, kept here and not in a file: a test's clock does not wait on a disk.
      'prefs' => Map<String, String>.of(_prefs),
      'setPref' => _prefs['${a['key']}'] = '${a['value']}',
      'searchContacts' => [
          {'name': 'Maya Chen', 'address': '+1 555-123-0001', 'photo': null, 'label': 'Mobile'},
          {'name': 'Mom', 'address': '+1 555-123-0010', 'photo': null, 'label': 'Mobile'},
        ],
      _ => await super.invokeMethod<Object>(method, arguments),
    };
    return answer as T?;
  }

  final _prefs = <String, String>{'enter_sends': 'on'};

  /// The phone at the other end has the app that does everything for a computer (android DeskCalls.CAPS).
  @override
  Set<String> get caps => const {'deleteMessage', 'deleteThread', 'deleteThreads', 'editMessage', 'resendMms', 'setBlocked', 'blockedNumbers', 'e2eOffer', 'e2eOff', 'e2eVerify', 'e2ePlainSeen', 'e2eList', 'mmsStatus', 'voiceLimit', 'put', 'drop', 'sendPictures', 'sendVoice', 'sendSticker'};

  @override
  int get waiting => 1;
}

/// The Mac's half of an update, standing in: it counts the restarts asked for.
class _Mac implements UpdateHost {
  int restarts = 0;
  @override
  Future<InstalledMac?> installed() async => null;
  @override
  Future<String> install(String path, {required String sha256, required int bytes}) async => 'ready';
  @override
  Future<String> restart() async {
    restarts++;
    return 'restarting';
  }
}

/// An item of the navigation bar at the sidebar's foot, by its label.
Finder _nav(String label) => find.byWidgetPredicate((w) => w is GlacierPressable && w.semanticLabel == label);

Finder _button(String label) => find.byWidgetPredicate((w) => w is IconTap && w.label == label);

class _Store implements LinkStore {
  PairedPhone? kept;
  @override
  Future<PairedPhone?> load() async => kept;
  @override
  Future<void> save(PairedPhone phone) async => kept = phone;
  @override
  Future<void> clear() async => kept = null;
}

Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
  await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
}

void main() {
  setUpAll(_fonts);
  testWidgets('the Mac\'s screens', (tester) async {
    tester.view.physicalSize = const Size(1100 * 2.0, 740 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final dir = Directory.systemTemp.createTempSync('ghost-desk-shots');
    addTearDown(() => dir.deleteSync(recursive: true));

    Future<void> shoot(String name, PhoneLink link, {required bool dark, Future<void> Function()? then, MacUpdates? updates}) async {
      final store = DeskStore(dir, keychain: false);
      final calls = _Calls(link, store);
      Sms.calls = calls;
      // The app's own updates are told to the phone's screens, as the app itself does it (desktop/main.dart).
      if (updates != null) calls.attachUpdates(updates);
      final state = AppState()
        ..setTheme(dark ? 'dark' : 'light')
        ..set('emoji', 'noto')
        ..set(NavStyle.pref, NavStyle.classic.name);
      await tester.pumpWidget(KeyedSubtree(key: ValueKey('$name$dark'), child: DesktopApp(sheet: sheet, state: state, link: link, calls: calls, store: store, updates: updates)));
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      if (then != null) await then();
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      // Written, never compared: the conversations hold the time of day. A plain run builds every screen.
      if (autoUpdateGoldenFiles) await expectLater(find.byType(DesktopApp), matchesGoldenFile('shots/mac-$name-${dark ? 'dark' : 'light'}.png'));
    }

    PhoneLink fresh() => PhoneLink(store: _Store(), name: "Matt's MacBook Pro", app: '0.6.0');

    for (final dark in [false, true]) {
      // The wizard: how to connect, the code to scan, the six digits.
      await shoot('1-wizard', fresh(), dark: dark);
      final showing = fresh()..beginPairing(mode: 'both', relay: 'wss://gogho.st/relay');
      // The code as the examples have it, so the picture is the same from one run to the next.
      await shoot('2-code', showing, dark: dark);
      expect(find.text('Scan this with your phone'), findsOneWidget);
      final comparing = fresh();
      comparing.beginPairing(mode: 'both', relay: 'wss://gogho.st/relay')
        ..phase = 'code'
        ..code = '874151'
        ..phoneName = 'Galaxy Z Fold8';
      await shoot('3-digits', comparing, dark: dark);
      expect(find.text('874 151'), findsOneWidget);
      expect(find.text('They match'), findsOneWidget);

      // Paired: the conversations, one of them open, a text waiting for the phone.
      PhoneLink paired(String? via) => fresh()
        ..phone = PairedPhone(id: 'd387c0690aec58b7', name: 'Galaxy Z Fold8', key: DeskCrypto.randomBytes(32), mode: 'both', relay: 'wss://gogho.st/relay', since: DateTime.now().subtract(const Duration(days: 9)))
        ..shownVia = via;
      await shoot('4-conversations', paired('local'), dark: dark, then: () async {
        await tester.tap(find.text('Maya Chen'));
      });
      expect(find.text('Waiting for your phone'), findsOneWidget); // under the text typed while it was away
      // How the phone is connected is in Settings alone, not under the list's search (Matt, 2026-11-14: "move the
      // "connected to the relay" into the settings only we don't need to show it on the sidebar").
      expect(find.textContaining('Connected over the local network'), findsNothing);
      // What only the phone does is not offered here.
      // What the phone does for a computer is offered here as on the phone (Matt: "the desktop app should get all
      // featues its missing from mobile"; "an emoji picker, file upload, voice memo and sticker selector"): a
      // picture to add, the Mac's emoji, stickers, and a voice message where Send would be with nothing written.
      expect(_button('Add an attachment'), findsOneWidget);
      expect(_button('Emoji'), findsOneWidget);
      expect(_button('Stickers'), findsOneWidget);
      expect(_button('Record a voice message'), findsOneWidget);
      expect(_button('Conversation settings'), findsOneWidget, reason: 'a conversation has its own settings on a computer too');
      // Calling is the phone's alone; and beside the list there is nowhere to go back to.
      expect(_button('Call'), findsNothing);

      // A picture on the clipboard is pasted into the message field as an attachment; with none, words paste as ever
      // (Matt, 2026-11-16: "add the ability to paste images into the chatbar on desktop").
      if (!dark) {
        final picture = File('${dir.path}/pasted.png')..writeAsBytesSync(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
        String? onClipboard = picture.path;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(const MethodChannel('ghost_desktop/system'), (call) async => call.method == 'pasteImage' ? onClipboard : null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => call.method == 'Clipboard.getData' ? {'text': 'pasted words'} : null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(const MethodChannel('ghost_desktop/system'), null);
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        });
        Future<void> paste() async {
          final modifier = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
          await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
          await tester.sendKeyUpEvent(modifier);
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 40));
          }
        }

        final field = find.byType(EditableText).last;
        await tester.showKeyboard(field);
        await tester.pump();
        await paste();
        expect(find.bySemanticsLabel('Remove picture'), findsOneWidget, reason: 'the copied picture is attached');
        expect(tester.widget<EditableText>(field).controller.text, isNot(contains('pasted words')));
        onClipboard = null;
        await paste();
        expect(tester.widget<EditableText>(field).controller.text, contains('pasted words'), reason: 'with no picture, words paste');
        expect(find.bySemanticsLabel('Remove picture'), findsOneWidget);
      }
      expect(_button('Back'), findsNothing);
      // The navigation pill at the sidebar's foot (Ghost.md's dock, laid along): a new chat, the messages, the
      // archive with how many are in it, the Marketplace (Matt, 2026-11-20: "Move plugins out of settings into a
      // marketplace button on the navigation rail"), Settings. Messages is the one shown; a ring has no words but its tip.
      for (final label in ['New', 'Messages', 'Contacts', 'Archive', 'Marketplace', 'Settings']) {
        expect(_nav(label), findsOneWidget, reason: label);
      }
      expect(tester.widget<NavPill>(find.byType(NavPill)).active, 'messages');
      // A computer keeps the pill laid along its sidebar's foot: stood up at the right is a wide phone's.
      expect(tester.widget<NavPill>(find.byType(NavPill)).upright, isFalse);
      expect(find.byKey(const ValueKey('shell-rail')), findsNothing);
      // The sidebar's width, with the same room on its left, its right and under it (Matt, 2026-11-16: "make the
      // navbar width fit the full sidebar ... make the space on the left and right even to the space on the bottom").
      final glass = tester.getRect(find.descendant(of: find.byType(NavPill), matching: find.byType(ClipRRect)).first);
      final column = tester.getRect(find.byKey(const ValueKey('shell-side')));
      final under = column.bottom - glass.bottom;
      expect(glass.left - column.left, closeTo(under, 0.5));
      expect(column.right - glass.right, closeTo(under, 0.5));
      // Archive shows the archived ones, and Messages the others again.
      await tester.tap(_nav('Archive'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<NavPill>(find.byType(NavPill)).active, 'archive');
      expect(find.text('Archived'), findsOneWidget);
      await tester.tap(_nav('Messages'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<NavPill>(find.byType(NavPill)).active, 'messages');
      // The address book: the phone's contacts beside the list, and a press on one opens its conversation.
      await tester.tap(_nav('Contacts'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(tester.widget<NavPill>(find.byType(NavPill)).active, 'contacts');
      expect(find.text('Search contacts'), findsOneWidget);
      expect(find.text('Mom'), findsOneWidget);
      if (autoUpdateGoldenFiles) await expectLater(find.byType(DesktopApp), matchesGoldenFile('shots/mac-10-contacts-${dark ? 'dark' : 'light'}.png'));
      // The rings stand evenly along the sidebar's foot: the first by its start, the last by its end.
      // Six rings: calls are the list's Voice tab, not a ring (Matt, 2026-11-15: "lets remove the calls icon in the
      // dock"); the Marketplace's is one (2026-11-20). The middle of the six is halfway between the third and fourth.
      final first = tester.getCenter(_nav('New')).dx, last = tester.getCenter(_nav('Settings')).dx;
      final middle = (tester.getCenter(_nav('Contacts')).dx + tester.getCenter(_nav('Archive')).dx) / 2;
      // On a computer the pill rests at the smaller size, as Ghost.md's desktop dock does (Matt, 2026-11-15: "just like
      // ghost markdown does match the sizes"), held to the foot's middle.
      expect(tester.widget<Transform>(find.descendant(of: find.byKey(const ValueKey('pill-scale')), matching: find.byType(Transform)).first).transform.storage[0], closeTo(pillScrolledScale, 0.001));
      expect(first, lessThan(90));
      expect(last, greaterThan(250));
      expect(middle, closeTo((first + last) / 2, 0.6));
      await tester.tap(_nav('Messages'));
      await tester.pump(const Duration(milliseconds: 400));
      // The new ring asks: a new chat, a group or a voice call (Matt, 2026-11-15: "The new button should also ask for
      // new chat, group or voice call"). A new chat opens beside the list and is the one shown; Messages puts it away.
      await tester.tap(_nav('New'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('New group'), findsOneWidget);
      expect(find.text('New space'), findsOneWidget);
      // The sheet slides up from the foot.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('New chat').hitTestable().last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<NavPill>(find.byType(NavPill)).active, 'new');
      await tester.tap(_nav('Messages'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<NavPill>(find.byType(NavPill)).active, 'messages');

      // A conversation's own settings, on a computer too (Matt: "There needs to be chat settings on desktop as
      // well"): who is in it, how it looks here, where its encryption stands, mute, pin and archive.
      await shoot('9-chat-settings', paired('local'), dark: dark, then: () async {
        await tester.tap(find.text('Maya Chen'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tester.tap(_button('Conversation settings'));
      });
      expect(find.text('Conversation settings'), findsOneWidget);
      expect(find.text('Chat background'), findsOneWidget);
      expect(find.text('Your bubbles here'), findsOneWidget);
      expect(find.textContaining('on this computer'), findsOneWidget, reason: 'its look is this computer\'s own');
      await tester.scrollUntilVisible(find.text('Encryption'), 200, scrollable: find.byType(Scrollable).last);
      expect(find.text('Encryption'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Pin to top'), 200, scrollable: find.byType(Scrollable).last);
      expect(find.text('Mute notifications'), findsOneWidget);
      expect(find.textContaining('On the phone'), findsOneWidget);

      // Settings is the phone's own, whole (Matt, 2026-11-14: "a full features settings page like the ghost
      // markdown app ... instead of the one small settings panel we have now"; "desktop and mobile should also
      // share the same settings pages"): its sections where the conversations were and the one chosen beside them
      // ("when the settings is open on desktop replace the normal sidebar so it's only a two pane layout not a
      // three pane"), the Mac's own among them, and what is the phone's alone left to the phone.
      // Me heads the list since plugins left Settings for the Marketplace (Matt, 2026-11-20: "Move plugins out of settings
      // into a marketplace button on the navigation rail"), so it is what opens first; the phone's own section is pressed
      // to see it.
      await shoot('5-settings', paired('relay'), dark: dark, then: () async {
        await tester.tap(_nav('Settings'));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.tap(find.descendant(of: find.byType(SettingsList), matching: find.text('Your phone')).first);
      });
      // Codes is no longer a row of its own: a plugin's settings are on its page in Plugins since 2026-11-17, and Plugins
      // are the Marketplace's since 2026-11-20.
      for (final label in ['Your phone', 'Me', 'Appearance', 'Chat background', 'Emoji', 'Effects', 'Messages', 'Encryption', 'Blocked', 'Archived', 'Kept on this Mac', 'About']) {
        expect(find.text(label), findsWidgets, reason: '$label is a section of a computer\'s Settings');
      }
      expect(find.text('Plugins'), findsNothing, reason: 'the Marketplace has them');
      for (final label in ['Your number', 'Android', 'Notifications', 'Receipts', 'Computers', 'Ghost Keyboard', 'Routes', 'Developer']) {
        expect(find.text(label), findsNothing, reason: '$label is the phone\'s alone');
      }
      // The phone's section beside the list: the phone, how the two connect, and unpairing.
      expect(find.text('Unpair this phone'), findsOneWidget);
      expect(find.textContaining('Connected through the relay'), findsWidgets);
      expect(find.text('Galaxy Z Fold8 · through the relay'), findsOneWidget);
      final listRight = tester.getRect(find.text('Appearance')).right, pageLeft = tester.getRect(find.text('Unpair this phone')).left;
      expect(pageLeft, greaterThan(listRight), reason: 'the page is beside the list of sections');
      expect(tester.getRect(find.text('Settings')).top, closeTo(tester.getRect(find.text('Your phone').last).top, 1), reason: 'the two pages\' names are level');
      expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Back'), findsWidgets, reason: 'Settings has a way back beside its page');
      expect(tester.getRect(find.byType(SettingsScreen)).left, 0, reason: 'Settings\' list is where the conversations were');
      expect(find.text('Maya Chen').hitTestable(), findsNothing, reason: 'two panes, not three');
      expect(_nav('Settings').hitTestable(), findsOneWidget);

      // A shared page, as the phone has it: pressing a section puts its page beside the list.
      Future<void> section(String label) async {
        // The last so called, where a page beside the list says the same word.
        final row = find.descendant(of: find.byType(SettingsList), matching: find.text(label)).last;
        await tester.ensureVisible(row);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(row);
      }

      await shoot('5-settings-appearance', paired('local'), dark: dark, then: () async {
        await tester.tap(_nav('Settings'));
        await tester.pump(const Duration(milliseconds: 120));
        await section('Appearance');
      });
      expect(find.text('Text size'), findsOneWidget);
      expect(find.text('Unpair this phone'), findsNothing);
      // A plugin's own settings (Matt: "the plugins and all being able to make their own setting sections"), on its
      // page in Plugins since 2026-11-17, and in the Marketplace since 2026-11-20: its ring, Discover beside its list,
      // then Codes' card.
      await shoot('5-settings-plugin', paired('local'), dark: dark, then: () async {
        await tester.tap(_nav('Marketplace'));
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 400));
        final codes = find.descendant(of: find.byType(PluginsPage), matching: find.text('Codes')).last;
        await tester.ensureVisible(codes);
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(codes);
      });
      expect(find.text('Mark as read when copied'), findsOneWidget);
      // What is kept on this Mac, and a way to clear it.
      await shoot('5-settings-kept', paired('local'), dark: dark, then: () async {
        await tester.tap(_nav('Settings'));
        await tester.pump(const Duration(milliseconds: 120));
        await section('Kept on this Mac');
      });
      expect(find.text('Clear what is kept'), findsOneWidget);
      // The Settings ring's own menu, with the other button: every section by name, to open Settings there (Matt,
      // 2026-11-14: "settings to quick jump to settings sections").
      await shoot('5-settings-ring-menu', paired('local'), dark: dark, then: () async {
        await tester.tap(find.byKey(const ValueKey('nav-settings')), buttons: kSecondaryButton);
      });
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.text('Kept on this Mac'), findsOneWidget);
      // A small list hung over the ring, in the sidebar (Matt: "too large and way too wide", of the sheet across
      // the window it first was), with the Mac's own sections under "This Mac".
      expect(tester.getRect(find.byType(GlacierMenuItem).first).right, lessThan(390), reason: 'in the sidebar, at most 380 wide');
      expect(tester.getRect(find.byType(GlacierMenuItem).first).width, lessThan(250));
      expect(find.descendant(of: find.byType(GlacierMenuLabel), matching: find.text('THIS MAC')), findsOneWidget);
      // It stands clear of the pill, a gap between the two: nothing of it lies on the bar or under it (Matt,
      // 2026-11-14: "the context menu is rendering behind the navbar", of a menu whose foot lay on the pill's edge).
      final pillTop = tester.getRect(find.descendant(of: find.byType(NavPill), matching: find.byType(ClipRRect)).first).top;
      final menuRows = find.byType(GlacierMenuItem).hitTestable();
      expect(menuRows, findsWidgets);
      expect(tester.getRect(menuRows.last).bottom, lessThanOrEqualTo(pillTop - 4), reason: 'the menu ends above the pill');
      // A long list of sections scrolls inside the menu.
      await tester.ensureVisible(find.text('Kept on this Mac'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.text('Kept on this Mac'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Clear what is kept'), findsOneWidget);
      // Its row in Settings' list, far down it, has been brought into view.
      expect(find.descendant(of: find.byType(SettingsList), matching: find.text('Kept on this Mac')).hitTestable(), findsOneWidget);
      // In the smallest window the Mac allows, the two are still side by side.
      tester.view.physicalSize = const Size(760 * 2.0, 520 * 2.0);
      await shoot('5-settings-small', paired('local'), dark: dark, then: () async {
        await tester.tap(_nav('Settings'));
        await tester.pump(const Duration(milliseconds: 120));
        await section('Your phone'); // Me opens first now
      });
      expect(find.text('Unpair this phone'), findsOneWidget);
      // Messages, at the list's foot, puts Settings away: the conversations are back, with nothing open.
      // (By its key: Settings has a section called Messages too.)
      await tester.tap(find.byKey(const ValueKey('nav-messages')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.text('Maya Chen').hitTestable(), findsOneWidget);
      expect(find.text('Choose a conversation'), findsOneWidget);
      tester.view.physicalSize = const Size(1100 * 2.0, 740 * 2.0);

      await shoot('6-waiting', paired(null), dark: dark);
      expect(find.textContaining('Waiting for your phone'), findsOneWidget);
      expect(find.textContaining('is ready to install'), findsNothing);

      // A newer version is in place beside this one: the banner the phone has says so over the page, and Update now
      // swaps it in and opens it (Matt: "bring the same update banner we have on mobile to the desktop app").
      final mac = _Mac();
      final ready = MacUpdates.standing(
        installed: const InstalledMac(version: '0.6.2', build: 456601, dir: '/tmp/none'),
        phase: MacUpdatePhase.ready,
        release: MacRelease(version: '0.7.0', build: 470000, sha256: 'ab' * 32, bytes: 35000000, url: Uri.parse('https://gogho.st/ghost-messaging-mac.zip')),
        host: mac,
      );
      await shoot('7-update-ready', paired('local'), dark: dark, updates: ready);
      // In the sidebar, above its title and search field, as wide as the list and no wider (Matt, 2026-11-14: "the
      // banner shows up in the middle of the page instead of in the sidebar", then "move the update banner ... to show
      // at the top of the sidebar above where it says messages"); in a column that narrow the app's name is left out.
      expect(find.text('0.7.0 is ready to install'), findsOneWidget);
      expect(tester.getRect(find.text('Update now')).right, lessThan(390), reason: 'in the sidebar, at most 380 wide');
      expect(tester.getRect(find.text('0.7.0 is ready to install')).bottom, lessThan(tester.getRect(find.byType(GlacierSearchField).first).top));
      await tester.tap(find.text('Update now'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(mac.restarts, 1);
      expect(find.text('Installing 0.7.0…'), findsOneWidget);
      expect(find.text('Update now'), findsNothing);
      // And in Settings: where the updates stand, and a look for one when asked.
      final idle = MacUpdates.standing(installed: const InstalledMac(version: '0.6.2', build: 456601, dir: '/tmp/none'), phase: MacUpdatePhase.idle, host: mac);
      await shoot('8-settings-updates', paired('local'), dark: dark, updates: idle, then: () async {
        await tester.tap(_nav('Settings'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await section('Updates');
      });
      expect(find.text('Look for an update'), findsOneWidget);
      expect(find.text('0.6.2 (456601)'), findsOneWidget);
      expect(find.text('Up to date'), findsWidgets);
      // Google Messages on the computer (lib/desktop/gm_web.dart; Matt, 2026-11-15: "Yes, mautrix sidecar"): its
      // QR code to scan, while pairing.
      final gm = GmWeb.instance..carried = true;
      // Not paired: Google-account pairing, all in one place (Matt, 2026-11-15: "Please make setting up google messages
      // a onboarding flow that is all in one place. It should also needs to if possible prompt to open the link
      // incognito").
      await shoot('8-settings-gmessages-setup', paired('local'), dark: dark, then: () async {
        await tester.tap(_nav('Settings'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await section('Google Messages');
      });
      expect(find.text('Open in a private window'), findsOneWidget);
      expect(find.text('Pair with a QR code instead'), findsOneWidget);
      gm.qr = 'https://support.google.com/messages/?p=web_computer#?c=CjQKIGV4YW1wbGUtcGFpcmluZy1rZXktZm9yLWEtcGljdHVyZQ';
      await shoot('8-settings-gmessages', paired('local'), dark: dark, then: () async {
        await tester.tap(_nav('Settings'));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        await section('Google Messages');
      });
      expect(find.textContaining('then Device pairing, then QR code scanner'), findsOneWidget);
      gm
        ..carried = false
        ..qr = null;
    }
    // Leave nothing running: the wizard's question to the relay, a toast.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}
