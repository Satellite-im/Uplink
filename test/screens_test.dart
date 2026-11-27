import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_messaging/ui/plugins_page/plugins_page.dart' show PluginsPage;
import 'package:ghost_messaging/ui/market/marketplace_screen.dart' show MarketplaceScreen;
import 'package:ghost_messaging/plugins/settings.dart' show marketPluginsScreen;
import 'package:ghost_messaging/ui/split_handle.dart';
import 'package:ghost_messaging/net/packet.dart';
import 'package:ghost_messaging/friends/buddies.dart';
import 'package:ghost_messaging/me/me.dart';
import 'package:ghost_messaging/ui/me.dart';
import 'package:ghost_messaging/accent.dart';
import 'package:ghost_messaging/app_state.dart';
import 'package:ghost_messaging/ui/nav_style.dart';
import 'package:ghost_messaging/art/app_icon.dart';
import 'package:ghost_messaging/art/lucide_more.dart';
import 'package:ghost_messaging/art/lucide.g.dart';
import 'package:ghost_messaging/effects.dart';
import 'package:ghost_messaging/friends/friends.dart';
import 'package:ghost_messaging/friends/groups.dart';
import 'package:ghost_messaging/main.dart' show InkOverrides, ghostTypography;
import 'package:ghost_messaging/kit/settings_css.dart';
import 'package:ghost_messaging/kit/settings_kit.dart' show settingsHue;
import 'package:ghost_messaging/kit/settings_type.dart';
import 'package:ghost_messaging/net/carrier.dart';
import 'package:ghost_messaging/net/net.dart';
import 'package:ghost_messaging/plugins/companies.dart';
import 'package:ghost_messaging/plugins/company_marks.g.dart';
import 'package:ghost_messaging/plugins/cleaner.dart';
import 'package:ghost_messaging/net/hub_carrier.dart' show RoomEvent, KeysSigner;
import 'package:ghost_messaging/net/crypto.dart' show NetKeys, NetCrypto;
import 'package:ghost_messaging/voice/hangout.dart';
import 'package:ghost_messaging/voice/roles.dart';
import 'package:ghost_messaging/ui/composer_box.dart';
import 'package:ghost_messaging/ui/hangout_screen.dart';
import 'package:ghost_messaging/ui/ripple_avatar.dart';
import 'package:ghost_messaging/ui/voice_screen.dart';
import 'package:ghost_messaging/voice/voice.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaDeviceInfo;
import 'package:ghost_messaging/voice/rtc.dart';
import 'package:ghost_messaging/voice/channels.dart';
import 'package:ghost_messaging/plugins/plugin.dart' show ListGroup, RowFace;
import 'package:ghost_messaging/plugins/embeds.dart' show Embeds, Fetched;
import 'package:ghost_messaging/plugins/ui.dart' show BrandFace, FilterButton, PluginRow, SectionTabs;
import 'package:ghost_messaging/sms.dart';
import 'package:ghost_messaging/summaries.dart';
import 'package:ghost_messaging/stickers.dart';
import 'package:ghost_messaging/ui/background_picker.dart';
import 'package:ghost_messaging/ui/chat_settings.dart';
import 'package:ghost_messaging/ui/common.dart' show GhostLogo, IconTap;
import 'package:ghost_messaging/ui/compose.dart';
import 'package:ghost_messaging/ui/computers.dart';
import 'package:ghost_messaging/ui/contacts.dart';
import 'package:ghost_messaging/ui/conversations.dart';
import 'package:ghost_messaging/ui/gm_guide_screen.dart';
import 'package:ghost_messaging/ui/gm_web_screen.dart';
import 'package:ghost_messaging/ui/rcs_setup.dart';
import 'package:ghost_messaging/ui/video_engine.dart';
import 'package:ghost_messaging/ui/video_screen.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_video.dart';
import 'package:ghost_messaging/ui/settings.dart';
import 'package:ghost_messaging/ui/nav_bar.dart';
import 'package:ghost_messaging/ui/new_group.dart';
import 'package:ghost_messaging/ui/network.dart' show inviteText;
import 'package:ghost_messaging/onboarding/onboarding.dart';
import 'package:ghost_messaging/standalone/welcome.dart';
import 'package:ghost_messaging/ui/shell.dart';
import 'package:ghost_messaging/ui/space_designs/space_design.dart' show SpaceCallPage;
import 'package:ghost_messaging/ui/sticker_picker.dart';
import 'package:ghost_messaging/ui/thread.dart';
import 'package:ghost_messaging/ui/video.dart' show shrunkNote;
import 'package:ghost_messaging/looks.dart';
import 'package:glacier/glacier.dart';

import 'support/fake_friends.dart';
import 'support/fake_groups.dart';

/// The screens drawn with made-up conversations, in light and dark, written to test/shots/ (run with
/// `flutter test --update-goldens test/screens_test.dart`). Nothing here talks to Android: the channel is answered
/// below.
Future<void> _fonts() async {
  Future<void> family(String name, String file) async {
    final loader = FontLoader(name)..addFont(File(file).readAsBytes().then((b) => ByteData.view(Uint8List.fromList(b).buffer)));
    await loader.load();
  }

  await family('Inter Variable', 'assets/fonts/InterVariable-latin.ttf');
  await family('JetBrains Mono Variable', 'assets/fonts/JetBrainsMonoVariable-latin.ttf');
  await family('Arimo', 'assets/fonts/ArimoVariable.ttf');
  await family('Ghost Emoji Noto', 'assets/emoji/NotoColor.ttf');
  await family('Ghost Emoji Twemoji', 'assets/emoji/Twemoji.ttf');
  await family('Ghost Emoji OpenMoji', 'assets/emoji/OpenMoji.ttf');
  await family('Ghost Emoji Outline', 'assets/emoji/NotoOutline.ttf');
}

final _now = DateTime.now();
int _ago({int days = 0, int hours = 0, int minutes = 0}) => _now.subtract(Duration(days: days, hours: hours, minutes: minutes)).millisecondsSinceEpoch;

Map<String, Object?> _p(String address, [String? name]) => {'address': address, 'name': name, 'photo': null};

final _conversations = [
  {'id': 1, 'date': _ago(minutes: 4), 'people': [_p('+15551230001', 'Maya Chen')], 'snippet': 'Sounds good, see you at 7! Bring the projector cable if you still have it', 'unread': true, 'error': false, 'archived': false},
  {'id': 2, 'date': _ago(minutes: 52), 'people': [_p('+15551230002', 'Jordan Park'), _p('+15551230003', 'Sam Rivera'), _p('+15551230004', 'Alex Kim')], 'snippet': 'Picture', 'unread': true, 'error': false, 'archived': false},
  {'id': 3, 'date': _ago(hours: 5), 'people': [_p('+15551230005', 'Dad')], 'snippet': 'Call me when you land', 'unread': false, 'error': false, 'archived': false, 'pinned': true},
  {'id': 4, 'date': _ago(days: 1, hours: 2), 'people': [_p('28849')], 'snippet': 'Your verification code is 482913. Don\'t share it with anyone.', 'unread': false, 'error': false, 'archived': false, 'muted': true},
  {'id': 5, 'date': _ago(days: 3), 'people': [_p('+15551230006', 'Priya Natarajan')], 'snippet': 'haha yes 😂', 'unread': false, 'error': true, 'archived': false},
  {'id': 6, 'date': _ago(days: 12), 'people': [_p('+15551230007')], 'snippet': 'Your package was delivered', 'unread': false, 'error': false, 'archived': false, 'draft': 'Thanks, I\'ll pick it up tom'},
  {'id': 7, 'date': _ago(days: 40), 'people': [_p('+15551230008', 'Old Thread')], 'snippet': 'ok', 'unread': false, 'error': false, 'archived': true},
  {'id': 8, 'date': _ago(minutes: 30), 'people': [_p('+15551230011', 'Riley Fox')], 'snippet': 'Only our two phones can read this now', 'unread': false, 'error': false, 'archived': false, 'encrypted': true},
  {'id': 9, 'date': _ago(hours: 2), 'people': [_p('+15551230012', 'Noor Haddad')], 'snippet': 'Encryption key', 'unread': false, 'error': false, 'archived': false},
];

/// The warning that Sam's texts are coming without encryption: put away, or encryption turned off with him.
bool _plainSeen = false;

/// The lines about a group of friends kept in conversation 2 (android Groups.note), for the groups' test alone.
final List<String> _groupNotes = [];

/// Where being friends with Maya stands (android E2e.friend), for the friends' test alone: '' everywhere else.
String _mayaFriend = '';
bool _plainOff = false;

/// What the plugins sort (lib/plugins), added to the list for their own pictures: sign-in codes from short numbers,
/// and two texts that look like spam.
final _sortable = <Map<String, Object>>[
  {'id': 101, 'date': _ago(minutes: 2), 'people': [_p('70220')], 'snippet': 'Coinbase: 771-204 is your login code. It expires in 10 minutes.', 'unread': true, 'error': false, 'archived': false},
  {'id': 102, 'date': _ago(hours: 3), 'people': [_p('+18005550142')], 'snippet': 'Use PIN 9041 to sign in to your Discover account', 'unread': false, 'error': false, 'archived': false},
  {'id': 103, 'date': _ago(minutes: 20), 'people': [_p('+15559870002')], 'snippet': 'Congratulations! You\'ve won a \$1,000 gift card. Claim now: http://prize.example/win', 'unread': true, 'error': false, 'archived': false},
  // A code from a company the app does not know by name: named as its text names it.
  {'id': 105, 'date': _ago(hours: 5), 'people': [_p('39200')], 'snippet': 'Brightwater Credit Union: your verification code is 330918.', 'unread': false, 'error': false, 'archived': false},
  {'id': 104, 'date': _ago(days: 2), 'people': [_p('+15559870004')], 'snippet': 'Your package could not be delivered. Reschedule here: bit.ly/3xYz', 'unread': false, 'error': false, 'archived': false},
  // Kinds of text (lib/plugins/kinds.dart): three hidden from Messages as the app ships, three shown.
  {'id': 106, 'date': _ago(hours: 1), 'people': [_p('+15559870006')], 'snippet': 'Election day is Tuesday! Chip in \$5 before midnight. Paid for by Friends of Pat Rivera', 'unread': true, 'error': false, 'archived': false},
  {'id': 107, 'date': _ago(hours: 2), 'people': [_p('+15559870007')], 'snippet': 'This is an attempt to collect a debt. Call us today to settle your balance.', 'unread': false, 'error': false, 'archived': false},
  {'id': 108, 'date': _ago(hours: 4), 'people': [_p('+15559870008')], 'snippet': 'Hi! Our crew is in your neighborhood this week. Tree trimming and gutter cleaning, free estimates!', 'unread': false, 'error': false, 'archived': false},
  {'id': 109, 'date': _ago(hours: 6), 'people': [_p('+15559870009')], 'snippet': 'Your package is out for delivery and will arrive by 8pm. Tracking number 1Z999AA10123456784', 'unread': false, 'error': false, 'archived': false},
  {'id': 110, 'date': _ago(hours: 7), 'people': [_p('+15559870010')], 'snippet': 'Reminder: your electric bill of \$84.12 is due on Nov 20. Autopay is off.', 'unread': false, 'error': false, 'archived': false},
  {'id': 111, 'date': _ago(hours: 8), 'people': [_p('+15559870011')], 'snippet': 'Appointment reminder: Dr. Lee tomorrow at 9:30am. Reply C to confirm.', 'unread': false, 'error': false, 'archived': false},
];

/// Where encryption stands with each person (android/.../E2e.kt): on and verified with Riley, Noor's key waiting
/// for a yes, nothing with anyone else.
Map<String, Object?> _e2e(String address) => switch (address) {
      '+15551230011' => {'address': address, 'state': 'on', 'verified': true, 'changed': false, 'safety': '04821 77310 59264 10388 92745 36601', 'person': _p(address, 'Riley Fox')},
      '+15551230012' => {'address': address, 'state': 'pending', 'verified': false, 'changed': false, 'safety': '61120 08347 55902 73418 20056 94471', 'person': _p(address, 'Noor Haddad')},
      // Encryption is on with Sam, whose last two texts came without it (or it was turned off, or the warning put away).
      '+15551230013' => {'address': address, 'state': _plainOff ? 'none' : 'on', 'verified': false, 'changed': false, 'person': _p(address, 'Sam Rivera'), 'plain': _plainOff || _plainSeen ? 0 : 2, 'declined': _plainOff},
      // Maya has the app too (its hello came from her), and nothing has been exchanged: the conversation offers it.
      // Adding her as a friend sends this phone's key ('want'), and being asked or being friends means keys are exchanged.
      '+15551230001' => {'address': address, 'state': switch (_mayaFriend) { '' => 'none', 'want' => 'offered', _ => 'on' }, 'verified': false, 'changed': false, 'hasGhost': true, 'declined': false, 'friend': _mayaFriend, 'person': _p(address, 'Maya Chen')},
      _ => {'address': address, 'state': 'none', 'verified': false, 'changed': false},
    };

/// For the picture of a summary (17-summary): the text waiting for the phone in Maya's conversation is left out.
bool _summaryPicture = false;

/// A newer version is waiting: only for the update card's pictures, since the card is part of the list and would
/// be in every picture of it.
bool _updateWaiting = false;

List<Map<String, Object?>> _messages(int thread) {
  if (thread == 6) {
    // Encryption is on with Sam: one text of his came sealed, then two came without it.
    return [
      {'id': 73, 'kind': 'sms', 'address': '+15551230013', 'body': 'You there?', 'date': _ago(minutes: 1), 'outgoing': false, 'state': 'received', 'read': false},
      {'id': 72, 'kind': 'sms', 'address': '+15551230013', 'body': 'New phone, who dis', 'date': _ago(minutes: 3), 'outgoing': false, 'state': 'received', 'read': true},
      {'id': 71, 'kind': 'sms', 'address': '+15551230013', 'body': 'See you Friday', 'date': _ago(days: 1), 'outgoing': false, 'state': 'received', 'read': true, 'encrypted': true},
    ];
  }
  if (thread == 5) {
    // Videos: one that came, which a picture can be made of, and one sent of a kind the phone cannot read.
    return [
      {'id': 63, 'kind': 'mms', 'address': '', 'body': 'You and Trin in that game', 'date': _ago(minutes: 2), 'outgoing': true, 'state': 'sent', 'read': true, 'parts': [{'id': 922, 'type': 'video/webm', 'name': '9864ade8-2512-4c3f-83b2-8d46dbb76b14.webm'}]},
      {'id': 62, 'kind': 'mms', 'address': '+15551230001', 'body': '', 'date': _ago(minutes: 4), 'outgoing': false, 'state': 'received', 'read': true, 'parts': [{'id': 921, 'type': 'video/mp4', 'name': 'clip.mp4'}]},
      {'id': 61, 'kind': 'sms', 'address': '+15551230001', 'body': 'Look at this', 'date': _ago(minutes: 5), 'outgoing': false, 'state': 'received', 'read': true},
    ];
  }
  if (thread == 4) {
    // Voice messages (android Voice.kt): one that came, one sent, each a picture message with sound in it.
    return [
      if (_voiceMore) {'id': 54, 'kind': 'mms', 'address': '+15551230001', 'body': '', 'date': _ago(minutes: 1), 'outgoing': false, 'state': 'received', 'read': true, 'parts': [{'id': 913, 'type': 'audio/mp4', 'name': 'voice-20261113-194730.m4a'}]},
      {'id': 53, 'kind': 'mms', 'address': '', 'body': '', 'date': _ago(minutes: 3), 'outgoing': true, 'state': 'sent', 'read': true, 'parts': [{'id': 912, 'type': 'audio/mp4', 'name': 'voice-20261113-194502.m4a'}]},
      {'id': 52, 'kind': 'mms', 'address': '+15551230001', 'body': '', 'date': _ago(minutes: 5), 'outgoing': false, 'state': 'received', 'read': true, 'parts': [{'id': 911, 'type': 'audio/amr', 'name': 'recording.amr'}]},
      {'id': 51, 'kind': 'sms', 'address': '+15551230001', 'body': 'Too much to type, one sec', 'date': _ago(minutes: 6), 'outgoing': false, 'state': 'received', 'read': true},
    ];
  }
  if (thread == 3) {
    // Two picture messages the carrier announced: one that could not be brought down, one coming down now.
    return [
      {'id': 43, 'kind': 'mms', 'address': '+15551230005', 'body': '', 'date': _ago(minutes: 2), 'outgoing': false, 'state': 'downloading', 'read': true, 'parts': []},
      {'id': 42, 'kind': 'mms', 'address': '+15551230005', 'body': '', 'date': _ago(hours: 4), 'outgoing': false, 'state': 'pending_download', 'read': true, 'parts': []},
      {'id': 41, 'kind': 'sms', 'address': '+15551230005', 'body': 'Call me when you land', 'date': _ago(hours: 5), 'outgoing': false, 'state': 'received', 'read': true},
    ];
  }
  if (thread == 2) {
    return [
      // Two of the app's stickers (android Stickers.kt names them): one sent, one from someone else with the app.
      // One that did not go, with why (android MmsWhy.kt).
      {'id': 16, 'kind': 'mms', 'address': '', 'body': 'Trailhead at 9', 'date': _ago(minutes: 47), 'outgoing': true, 'state': 'failed', 'read': true, 'parts': [], 'why': 'mobile data is off. Picture messages need it, even on Wi-Fi'},
      {'id': 15, 'kind': 'mms', 'address': '', 'body': '', 'date': _ago(minutes: 48), 'outgoing': true, 'state': 'sent', 'read': true, 'parts': [{'id': 902, 'type': 'image/png', 'name': 'ghost-sticker-party-03.png'}]},
      {'id': 14, 'kind': 'mms', 'address': '+15551230002', 'body': '', 'date': _ago(minutes: 49), 'outgoing': false, 'state': 'received', 'read': false, 'parts': [{'id': 901, 'type': 'image/png', 'name': 'ghost-sticker-sweet-01.png'}]},
      {'id': 13, 'kind': 'mms', 'address': '+15551230004', 'body': '👍 to "Hike this weekend?"', 'date': _ago(minutes: 50), 'outgoing': false, 'state': 'received', 'read': false, 'parts': []},
      {'id': 12, 'kind': 'mms', 'address': '+15551230003', 'body': 'Liked “Hike this weekend?”', 'date': _ago(minutes: 51), 'outgoing': false, 'state': 'received', 'read': false, 'parts': []},
      {'id': 11, 'kind': 'mms', 'address': '+15551230003', 'body': 'Look at this view 🏔️', 'date': _ago(minutes: 52), 'outgoing': false, 'state': 'received', 'read': false, 'parts': []},
      {'id': 10, 'kind': 'mms', 'address': '', 'body': 'Saturday works for me', 'date': _ago(hours: 1), 'outgoing': true, 'state': 'read', 'read': true, 'parts': []},
      {'id': 9, 'kind': 'mms', 'address': '+15551230004', 'body': 'Same, any time after noon', 'date': _ago(hours: 1, minutes: 5), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
      {'id': 8, 'kind': 'mms', 'address': '+15551230002', 'body': 'Hike this weekend?', 'date': _ago(hours: 1, minutes: 8), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
      {'id': 7, 'kind': 'mms', 'address': '+15551230002', 'body': 'Who\'s around Saturday', 'date': _ago(hours: 1, minutes: 9), 'outgoing': false, 'state': 'received', 'read': true, 'parts': []},
    ];
  }
  if (thread == 8) {
    // An encrypted conversation: the two keys as lines, sealed texts opened with their locks, and one from before a
    // reinstall that this phone can no longer open.
    return [
      {'id': 27, 'kind': 'sms', 'address': '+15551230011', 'body': '', 'date': _ago(minutes: 29), 'outgoing': false, 'state': 'received', 'read': true, 'encrypted': true, 'notice': 'background'},
      {'id': 26, 'kind': 'sms', 'address': '+15551230011', 'body': 'Only our two phones can read this now', 'date': _ago(minutes: 30), 'outgoing': false, 'state': 'received', 'read': true, 'encrypted': true},
      {'id': 25, 'kind': 'sms', 'address': '', 'body': 'Door code is 4417, don\'t tell anyone 🤫', 'date': _ago(minutes: 31), 'outgoing': true, 'state': 'delivered', 'read': true, 'encrypted': true},
      {'id': 24, 'kind': 'sms', 'address': '+15551230011', 'body': '', 'date': _ago(minutes: 33), 'outgoing': false, 'state': 'received', 'read': true, 'notice': 'undecryptable'},
      {'id': 23, 'kind': 'sms', 'address': '+15551230011', 'body': '', 'date': _ago(minutes: 40), 'outgoing': false, 'state': 'received', 'read': true, 'notice': 'key'},
      {'id': 22, 'kind': 'sms', 'address': '', 'body': '', 'date': _ago(minutes: 41), 'outgoing': true, 'state': 'delivered', 'read': true, 'notice': 'key'},
      {'id': 21, 'kind': 'sms', 'address': '+15551230011', 'body': 'Did you get the app?', 'date': _ago(minutes: 50), 'outgoing': false, 'state': 'received', 'read': true},
    ];
  }
  if (thread == 9) {
    return [
      {'id': 31, 'kind': 'sms', 'address': '+15551230012', 'body': '', 'date': _ago(hours: 2), 'outgoing': false, 'state': 'received', 'read': true, 'notice': 'key'},
      {'id': 30, 'kind': 'sms', 'address': '+15551230012', 'body': 'Sending you my key, one sec', 'date': _ago(hours: 2, minutes: 1), 'outgoing': false, 'state': 'received', 'read': true},
    ];
  }
  return [
    {'id': 10, 'kind': 'sms', 'address': '+15551230001', 'body': '🎉🍿', 'date': _ago(minutes: 1), 'outgoing': false, 'state': 'received', 'read': true},
    {'id': 9, 'kind': 'sms', 'address': '', 'body': 'Laughed at “Sounds good, see you at 7! Bring the projector…”', 'date': _ago(minutes: 2), 'outgoing': true, 'state': 'delivered', 'read': true},
    {'id': 6, 'kind': 'sms', 'address': '+15551230001', 'body': 'Sounds good, see you at 7! Bring the projector cable if you still have it', 'date': _ago(minutes: 4), 'outgoing': false, 'state': 'received', 'read': true},
    {'id': 8, 'kind': 'sms', 'address': '+15551230001', 'body': '❤️ to “Dinner at mine first?”', 'date': _ago(minutes: 20), 'outgoing': false, 'state': 'received', 'read': true},
    {'id': 7, 'kind': 'sms', 'address': '', 'body': 'Correction: Dinner at mine first?', 'date': _ago(minutes: 29), 'outgoing': true, 'state': 'delivered', 'read': true},
    {'id': 5, 'kind': 'sms', 'address': '+15551230001', 'body': 'Dinner at mine first?', 'date': _ago(minutes: 30), 'outgoing': true, 'state': 'delivered', 'read': true, 'edited': true, 'original': 'Diner at mine frist?'},
    {'id': 4, 'kind': 'sms', 'address': '+15551230001', 'body': 'Movie night is still on for tonight right?', 'date': _ago(minutes: 31), 'outgoing': true, 'state': 'delivered', 'read': true},
    {'id': 3, 'kind': 'sms', 'address': '+15551230001', 'body': 'Here\'s the link https://example.com/tickets', 'date': _ago(days: 1, hours: 1), 'outgoing': false, 'state': 'received', 'read': true},
    {'id': 2, 'kind': 'sms', 'address': '+15551230001', 'body': 'Did you get the tickets?', 'date': _ago(days: 1, hours: 1, minutes: 2), 'outgoing': true, 'state': 'sent', 'read': true},
    {'id': 1, 'kind': 'sms', 'address': '+15551230001', 'body': 'Hey! Long time 👋', 'date': _ago(days: 1, hours: 3), 'outgoing': false, 'state': 'received', 'read': true},
  ];
}

/// The pairing with a computer being made, as Android would say it stands (android/.../Desk.kt): set before the
/// pairing screen is drawn at each of its steps.
Map<String, Object?> _pairing = {'phase': 'none'};

int _voiceBeat = 0;

/// The videos asked to be played, by their parts.
final _videosPlayed = <int>[];

/// A third voice message has arrived in the voice conversation.
bool _voiceMore = false;

/// What the screens asked the phone to do, and the ticks they asked of it: looked at after a row is dragged.
final _asked = <String>[];
final _ticks = <String>[];

void _answerChannel() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') _ticks.add('${call.arguments}');
    return null;
  });
  messenger.setMockMethodCallHandler(const MethodChannel('ghost_messaging/sms'), (call) async {
    final args = (call.arguments as Map?) ?? const {};
    if (call.method == 'archive' || call.method == 'threadFlag' || call.method == 'deleteThread' || call.method == 'openLink') _asked.add('${call.method} $args');
    switch (call.method) {
      case 'status':
        return _statusSaid;
      case 'gmChannels':
        return _gmChannels;
      case 'gmWebState':
        return _gmWeb;
      case 'conversations':
        return _conversations;
      case 'conversationsPage':
        // A lot at a time, as the phone hands them over: the archived ones alone, or from a row on.
        if (args['archived'] == true) return {'items': _conversations.where((c) => c['archived'] == true).toList(), 'next': null};
        final from = (args['offset'] as num?)?.toInt() ?? 0;
        final limit = (args['limit'] as num?)?.toInt() ?? 0;
        final to = limit == 0 ? _conversations.length : (from + limit).clamp(0, _conversations.length);
        return {'items': _conversations.sublist(from.clamp(0, _conversations.length), to), 'next': to < _conversations.length ? to : null};
      case 'conversation':
        return _conversations.where((c) => c['id'] == args['thread']).firstOrNull;
      case 'threadName':
        // android Store.setThreadName: kept trimmed, and an empty one takes the name away.
        final name = (args['name'] as String).trim();
        final named = _conversations.firstWhere((c) => c['id'] == args['thread']);
        if (name.isEmpty) {
          named.remove('name');
        } else {
          named['name'] = name;
        }
        return null;
      case 'archivedCount':
        return _conversations.where((c) => c['archived'] == true).length;
      case 'messages':
        final thread = (args['thread'] as num).toInt();
        // Between friends the last things said went by the internet, sealed.
        if (thread == 1 && _mayaFriend == 'yes') {
          final all = _messages(thread);
          return [for (final m in all) (m['id'] as int) >= 6 ? {...m, 'via': 'net', 'encrypted': true} : m];
        }
        // A group of friends' conversation holds lines about the group itself, newest first like the rest.
        if (thread == 2 && _groupNotes.isNotEmpty) {
          return [
            for (var i = _groupNotes.length - 1; i >= 0; i--)
              {'id': 900 + i, 'kind': 'mms', 'address': '', 'body': _groupNotes[i], 'notice': 'group', 'date': DateTime.now().millisecondsSinceEpoch - (_groupNotes.length - i), 'outgoing': true, 'state': 'sent', 'read': true},
            ..._messages(thread),
          ];
        }
        // The picture of a summary: Maya's newest are hers, the text waiting for the phone set aside.
        if (_summaryPicture && thread == 1) {
          return [
            {'id': 41, 'kind': 'sms', 'address': '+15551230001', 'body': 'Bring the projector cable if you still have it', 'date': _ago(minutes: 4), 'outgoing': false, 'state': 'received'},
            {'id': 40, 'kind': 'sms', 'address': '+15551230001', 'body': 'Sounds good, see you at 7!', 'date': _ago(minutes: 5), 'outgoing': false, 'state': 'received'},
            {'id': 39, 'kind': 'sms', 'address': '', 'body': 'Dinner at mine first?', 'date': _ago(minutes: 30), 'outgoing': true, 'state': 'delivered'},
          ];
        }
        return _messages(thread);
      case 'people':
        return (_conversations.firstWhere((c) => c['id'] == args['thread'])['people']);
      case 'searchContacts':
        return [
          {'name': 'Maya Chen', 'address': '+1 555-123-0001', 'photo': null, 'label': 'Mobile'},
          {'name': 'Mark Ortiz', 'address': '+1 555-123-0099', 'photo': null, 'label': 'Work'},
          {'name': 'Mom', 'address': '+1 555-123-0010', 'photo': null, 'label': 'Mobile'},
        ];
      case 'update':
        return _updateWaiting
            ? {'phase': 'available', 'current': '0.6.1', 'available': '0.6.2', 'auto': true, 'canInstall': true, 'source': 'https://gogho.st'}
            : {'phase': 'idle', 'current': '0.6.1', 'auto': true, 'canInstall': true, 'source': 'https://gogho.st'};
      case 'ownNumber':
        return '+15551239999';
      // A link pressed in a message: the browser took it.
      case 'openLink':
        return true;
      // The app's routes (lib/net): who this phone is, and the two people encryption is on with or waiting.
      case 'netIdentity':
        return {'id': '0f' * 16, 'key': 'AlFcPW655Ja5BNP+yn9U/c0MwemXvzddylFa0KbDtANf'};
      case 'netPeers':
        return [
          {'id': 'a1' * 16, 'address': '+15551230011', 'key': Uint8List.fromList(List.filled(32, 7))},
          {'id': 'b2' * 16, 'address': '+15551230012', 'key': Uint8List.fromList(List.filled(32, 9))},
        ];
      case 'contact':
        return _conversations.expand((c) => c['people'] as List).cast<Map>().firstWhere((p) => p['address'] == args['address'], orElse: () => _p(args['address'] as String));
      // A new chat's people have a conversation: the first one, here.
      case 'threadFor':
        return 1;
      // The phone's own model for summaries (lib/summaries.dart), standing in.
      case 'summaryStatus':
        return 'available';
      case 'summarize':
        return 'Maya confirms 7pm and asks you to bring the projector cable.';
      case 'netSmsAvailable':
        return false;
      case 'netSmsDrain':
        return const <Object>[];
      case 'e2e':
        return _e2e(args['address'] as String);
      case 'e2ePlainSeen':
        _plainSeen = true;
        return null;
      case 'e2eOff':
        _plainOff = true;
        return null;
      case 'e2eList':
        return [_e2e('+15551230011'), _e2e('+15551230012')];
      case 'e2eMine':
        return '9C41 D07A';
      case 'blockedNumbers':
        return [_p('+15551230090', 'Spam Likely'), _p('+18005550199')];
      case 'keyboardHere':
        return true;
      case 'arriving':
        // Coming from Google Messages, still on the phone; a copy from a file, on Android 16.
        return {'old': 'com.google.android.apps.messaging', 'oldLabel': 'Google Messages', 'oldInstalled': true, 'oldHasRcs': true, 'texts': 1204, 'recentTexts': 38, 'pictures': 56, 'lastReceived': _ago(minutes: 4), 'samsungChats': null, 'sideloaded': true, 'android': 36};
      case 'ghostPeers':
        // Riley is known to have the app (keys were exchanged); nobody else is.
        return (args['addresses'] as List).every((a) => a == '+15551230011');
      case 'prefs':
        return <String, String>{};
      // Paired computers: one connected over the local network, one last seen yesterday through the relay.
      case 'deskList':
        return [
          {'id': 'd387c0690aec58b7', 'name': 'Matt\'s MacBook Pro', 'mode': 'both', 'relay': 'wss://gogho.st/relay', 'since': _ago(days: 9), 'seen': _ago(minutes: 1), 'via': 'local'},
          {'id': '0f1e2d3c4b5a6978', 'name': 'Studio iMac', 'mode': 'relay', 'relay': 'wss://gogho.st/relay', 'since': _ago(days: 30), 'seen': _ago(days: 1, hours: 3), 'via': null},
        ];
      case 'deskState':
        return _pairing;
      case 'deskPeek':
        return {'name': 'Matt\'s MacBook Pro', 'mode': 'both', 'relay': 'wss://gogho.st/relay'};
      case 'deskUnrestricted':
        return false;
      case 'deskAddresses':
        return ['192.168.1.20:47811'];
      // Videos: a picture of where one starts and how long it runs; none for the kind that cannot be read.
      case 'videoPreview':
        return (args['part'] as num).toInt() == 921
            // As a video comes from an iPhone as a picture message: 320 by 240, under a megabyte.
            ? {'picture': File('assets/stickers/party/03.webp').readAsBytesSync(), 'millis': 12400, 'width': 640, 'height': 360, 'videoWidth': 320, 'videoHeight': 240, 'bytes': 912384}
            : {'picture': null, 'millis': 0, 'width': 0, 'height': 0};
      // A text sent: the phone's thread for it.
      case 'send':
        return 1;
      // The phone's own player (lib/ui/video_screen.dart) opens the video as a file.
      case 'videoFile':
        _videosPlayed.add((args['part'] as num).toInt());
        return '/tmp/video-${args['part']}.mp4';
      // Voice messages: how long each runs, and a recording that hears a voice rise and fall.
      case 'voiceLength':
        return switch ((args['part'] as num).toInt()) { 911 => 7400, 913 => 41000, _ => 23000 };
      case 'voiceStart':
        _voiceBeat = 0;
        return {'ok': true, 'seconds': 91};
      case 'voiceLevel':
        _voiceBeat++;
        return 0.04 + 0.5 * ((_voiceBeat * 37) % 17) / 17 * (_voiceBeat % 9 < 6 ? 1 : 0.15);
      case 'devLogRead':
        // The app's own log, as Settings › Developer reads it: a photo that went, and one the carrier refused.
        const lines = [
          '11-13 19:05:02 mms   send to 1: 4000x3000 2143 KB image/jpeg -> 1200x1600 q85 302 KB (HDR left off), words 0, carrier\'s limit 1024 KB',
          '11-13 19:05:04 mms   sent, 310 KB, the carrier\'s id for it fake-1@mmsc',
          '11-13 19:12:40 mms   send to 3: 8160x6120 5210 KB image/heic -> 1600x1200 q85 412 KB, words 14, carrier\'s limit 1024 KB',
          '11-13 19:12:43 mms   not sent, 420 KB: the carrier\'s server refused it (HTTP 413) (result 4, HTTP 413)',
          '11-13 19:13:10 call  send: IllegalStateException: that picture couldn\'t be read (Android no longer lets this app read it; choose it again)',
        ];
        return {'lines': lines, 'report': 'Uplink 0.6.2\nsamsung SM-F966U, Android 16 (API 36)\n\n${lines.join('\n')}'};
      case 'mmsStatus':
        // Picture messages as the phone reports them: nothing in the way, one sent, one that could not be fetched.
        return {
          'dataOn': true, 'carrier': 'T-Mobile', 'sim': true, 'allowed': true, 'maxBytes': 1048576, 'waiting': 1,
          'lastSend': {'at': _ago(minutes: 12), 'ok': true, 'detail': 'sent, 294 KB'},
          'lastDownload': {'at': _ago(hours: 3), 'ok': false, 'detail': 'the carrier\'s server couldn\'t be reached. Check mobile data'},
        };
      case 'part':
        // The two stickers in the group conversation, as the phone would hand a picture message's part over.
        return switch ((args['id'] as num).toInt()) {
          901 => File('assets/stickers/sweet/01.webp').readAsBytesSync(),
          902 => File('assets/stickers/party/03.webp').readAsBytesSync(),
          _ => null,
        };
      default:
        return null;
    }
  });
}

Future<void> _shoot(WidgetTester tester, TokenSheet sheet, Widget screen, String name, {required bool dark, Map<String, String> prefs = const {}}) async {
  final state = AppState()
    ..setTheme(dark ? 'dark' : 'light')
    ..set(NavStyle.pref, NavStyle.classic.name);
  for (final e in prefs.entries) {
    state.set(e.key, e.value);
  }
  await tester.pumpWidget(AppScope(
    state: state,
    child: WidgetsApp(
      color: const Color(0xFF4F5BD5),
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
      builder: (context, child) => GlacierTheme(
        sheet: sheet,
        attrs: ghostAttrs(state, 'mobile'),
        typography: ghostTypography('noto'),
        child: InkOverrides(child: GlacierToastProvider(child: child!)),
      ),
      home: KeyedSubtree(key: ValueKey(name), child: screen),
    ),
  ));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump(const Duration(milliseconds: 500));
  // The pictures hold the time of day, so they are written (--update-goldens), never compared: a plain run only
  // builds every screen and fails on an exception.
  if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/$name-${dark ? 'dark' : 'light'}.png'));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _shootAgain(WidgetTester tester, String name, {required bool dark}) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  // The pictures hold the time of day, so they are written (--update-goldens), never compared: a plain run only
  // builds every screen and fails on an exception.
  if (autoUpdateGoldenFiles) await expectLater(find.byType(WidgetsApp), matchesGoldenFile('shots/$name-${dark ? 'dark' : 'light'}.png'));
}

/// The sites the link previews ask (lib/plugins/embeds.dart), standing in: a YouTube video, and a page of tickets.
Future<Fetched> _fakeSites(Uri url) async {
  if (url.host == 'www.youtube.com') return (status: 200, body: '{"title": "Interstellar (2014) Official Trailer", "author_name": "Warner Bros.", "thumbnail_url": "https://i.ytimg.com/vi/x/hq.jpg"}');
  if (url.host == 'example.com') return (status: 200, body: '<meta property="og:site_name" content="Hickory Premier"><meta property="og:title" content="Movie night: 7:00 PM, Theatre 2">');
  return (status: 404, body: '');
}

/// The on-phone Google Messages connection as it stands (android GmWeb.state): there, not paired, unless a test says.
Map<String, Object?> _gmWeb = const {'available': true, 'running': true, 'paired': false, 'connected': false};

/// Google Messages' notification channels as Uplink saw them (android GmBridge.channelList): none, unless a test says.
List<Map<String, Object?>> _gmChannels = const [];

/// What the phone says of itself (SmsStatus): the default SMS app, unless a test says otherwise.
Map<String, Object> _statusSaid = const {'isDefault': true, 'contacts': true, 'notifications': false, 'phone': true};

void main() {
  setUp(() {
    Embeds.forget();
    Embeds.fetch = _fakeSites;
  });
  setUpAll(_fonts);
  // Delete, and don't ask again (Matt, 2026-11-16: "Add a "don't ask again" on the confirmation for sliding to delete
  // message groups"): chosen once, a conversation slid all the way is deleted with no question.
  testWidgets('a slide to delete asks, until Don\'t ask again', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    await _shoot(tester, sheet, const AppShell(), 'x-delete-ask', dark: false);
    Future<void> slideAway(String who) async {
      final g = await tester.startGesture(tester.getCenter(find.text(who)));
      await g.moveBy(const Offset(-30, 0));
      await g.moveBy(const Offset(-330, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await g.up();
      await _settle(tester);
    }

    _asked.clear();
    await slideAway('Dad');
    expect(find.textContaining('Delete every message with Dad'), findsOneWidget);
    expect(find.text('Delete, and don\'t ask again'), findsOneWidget);
    await tester.tap(find.text('Delete, and don\'t ask again'));
    await _settle(tester);
    expect(_asked.where((a) => a.startsWith('deleteThread')), hasLength(1));
    final app = AppState.of(tester.element(find.byType(ConversationRow).first));
    expect(app.flag('delete_ask', fallback: true), isFalse);
    await tester.pump(const Duration(seconds: 6));
    await _settle(tester);
    _asked.clear();
    await slideAway('Priya Natarajan');
    expect(find.textContaining('Delete every message with'), findsNothing, reason: 'no question once told not to ask');
    expect(_asked.where((a) => a.startsWith('deleteThread')), hasLength(1));
  });

  testWidgets('screens', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    for (final dark in [false, true]) {
      // The list as the app shows it: in its frame (lib/ui/shell.dart), the pill at its foot.
      await _shoot(tester, sheet, const AppShell(), '1-conversations', dark: dark);
      expect(find.byType(NavPill), findsOneWidget);
      // A newer version is waiting: the card at the top of the list, above its title and search (Matt, 2026-11-14:
      // "move the update banner on desktop and mobile to show at the top of the sidebar above where it says messages
      // and has the search bar").
      _updateWaiting = true;
      await _shoot(tester, sheet, const AppShell(), '1-update-banner', dark: dark);
      expect(find.textContaining('is out'), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);
      expect(tester.getRect(find.textContaining('is out')).bottom, lessThan(tester.getRect(find.byType(GlacierSearchField).first).top));
      _updateWaiting = false;
      // A row dragged sideways (lib/ui/swipe_actions.dart): to the left past Archive, on past Delete, back to
      // Archive and let go; then to the right past Pin. The phone ticks at each detent it passes into.
      _asked.clear();
      _ticks.clear();
      final left = await tester.startGesture(tester.getCenter(find.text('Dad')));
      await left.moveBy(const Offset(-30, 0));
      await left.moveBy(const Offset(-80, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await _shootAgain(tester, '1-conversations-swipe-archive', dark: dark);
      await left.moveBy(const Offset(-180, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await _shootAgain(tester, '1-conversations-swipe-delete', dark: dark);
      await left.moveBy(const Offset(180, 0));
      await left.up();
      await _settle(tester);
      expect(_ticks, ['HapticFeedbackType.mediumImpact', 'HapticFeedbackType.heavyImpact', 'HapticFeedbackType.mediumImpact'], reason: 'a tick into Archive, a knock into Delete, a tick back into Archive');
      expect(_asked.single, startsWith('archive'), reason: 'let go at Archive, it archives and nothing else');
      _asked.clear();
      _ticks.clear();
      // The archive's toast is let pass before the next drag.
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      final right = await tester.startGesture(tester.getCenter(find.text('Dad')));
      await right.moveBy(const Offset(30, 0));
      await right.moveBy(const Offset(90, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await _shootAgain(tester, '1-conversations-swipe-pin', dark: dark);
      await right.up();
      await _settle(tester);
      expect(_ticks, ['HapticFeedbackType.mediumImpact']);
      expect(_asked.single, startsWith('threadFlag'), reason: 'let go at Pin, it changes the pin');
      // A short drag comes to nothing: no tick, nothing asked.
      _asked.clear();
      _ticks.clear();
      final short = await tester.startGesture(tester.getCenter(find.text('Dad')));
      await short.moveBy(const Offset(-30, 0));
      await short.moveBy(const Offset(-20, 0));
      await short.up();
      await _settle(tester);
      expect(_ticks, isEmpty);
      expect(_asked, isEmpty);
      // Several chosen at once: a long press's Select, then a tap on another.
      await tester.longPress(find.text('Dad'));
      await _settle(tester);
      await tester.tap(find.text('Select'));
      await _settle(tester);
      await tester.tap(find.text('Priya Natarajan'));
      await _shootAgain(tester, '1-conversations-selecting', dark: dark);
      await _shoot(tester, sheet, const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '2-thread', dark: dark);
      // A link in a message opens in the browser when pressed (lib/links.dart): the address, and nothing else of
      // the message's words.
      _asked.clear();
      await tester.tapOnText(find.textRange.ofSubstring('https://example.com/tickets'));
      await _settle(tester);
      expect(_asked, ['openLink {url: https://example.com/tickets}']);
      _asked.clear();
      // A message held: its reactions under it, then what else can be done, the screen effects one item of that.
      await tester.longPress(find.text('Movie night is still on for tonight right?'));
      await _shootAgain(tester, '2-thread-held', dark: dark);
      // In the reactions' row (and among the replies to choose from over the composer, lib/plugins/replies.dart).
      expect(find.text('👍'), findsWidgets);
      expect(find.text('🎈'), findsNothing, reason: 'the effects are behind Effects, not a row of their pictures');
      expect(find.text('Copy text'), findsOneWidget);
      // One message snoozed from its menu (GMFB-36).
      expect(find.text('Snooze…'), findsOneWidget);
      // Effects opens them in the menu's own place, each by its name, with the way back at the top.
      await tester.tap(find.text('Effects'));
      await _settle(tester);
      await _shootAgain(tester, '2-thread-held-effects', dark: dark);
      expect(find.text('Copy text'), findsNothing);
      expect(find.text('Confetti'), findsOneWidget);
      expect(find.text('🎈'), findsOneWidget);
      await tester.tap(find.text('Effects'));
      await _settle(tester);
      expect(find.text('Copy text'), findsOneWidget, reason: 'the way back is the sub-menu\'s own first row');
      // An incoming one near the top: the same, on its own side.
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      expect(find.text('Copy text'), findsNothing);
      // Further up now that the plugins put things under messages and over the composer.
      await tester.dragUntilVisible(find.text('Hey! Long time 👋'), find.ancestor(of: find.text('Dinner at mine first?'), matching: find.byType(Scrollable)).first, const Offset(0, 200));
      await _settle(tester);
      await tester.longPress(find.text('Hey! Long time 👋'));
      await _shootAgain(tester, '2-thread-held-theirs', dark: dark);
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      // A picture that could not be downloaded, shown where it would be with a way to ask for it again; and one
      // being brought down.
      await _shoot(tester, sheet, const ThreadScreen(thread: 3, people: [Person(address: '+15551230005', name: 'Dad')]), '2-thread-picture-failed', dark: dark);
      expect(find.text('This picture couldn\'t be downloaded'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Downloading picture…'), findsOneWidget);
      // Encryption is on with someone whose texts have started coming without it: the conversation says so, with
      // Turn off beside it (Matt: "detect if a user is sending us unencrypted messages and let us know so we can
      // disable it"). Put away, it goes; turned off, the conversation is plain again.
      _plainSeen = false;
      _plainOff = false;
      const sam = [Person(address: '+15551230013', name: 'Sam Rivera')];
      await _shoot(tester, sheet, const ThreadScreen(thread: 6, people: sam), '2-thread-plain-warning', dark: dark);
      expect(find.byKey(const ValueKey('new-messages')), findsNothing, reason: 'a chat with one person has no divider');
      expect(find.textContaining('last 2 texts came without encryption'), findsOneWidget);
      final turnOff = find.byWidgetPredicate((w) => w is GlacierPressable && w.semanticLabel == 'Turn off');
      expect(turnOff, findsOneWidget);
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Not now'));
      await _settle(tester);
      expect(_plainSeen, isTrue);
      expect(find.textContaining('came without encryption'), findsNothing);
      _plainSeen = false;
      await _shoot(tester, sheet, const ThreadScreen(key: ValueKey('again'), thread: 6, people: sam), '2-thread-plain-warning', dark: dark);
      await tester.tap(turnOff);
      await _settle(tester);
      expect(_plainOff, isTrue);
      expect(find.textContaining('came without encryption'), findsNothing);
      // Videos: a picture of where each starts with Play over it and its length, where it was the file's name
      // and no more (Matt: "mp4 files are not loading it just shows up as a string of text for the filename").
      _videosPlayed.clear();
      await _shoot(tester, sheet, const ThreadScreen(thread: 5, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '2-thread-video', dark: dark);
      final players = find.byWidgetPredicate((w) => w is GlacierPressable && w.semanticLabel == 'Play video');
      expect(players, findsNWidgets(2));
      expect(find.text('0:12'), findsOneWidget);
      expect(find.text('clip.mp4'), findsNothing, reason: 'one with a picture is not named');
      // Under it, how large it came, and, it having come small from someone else, why (Matt: "the videos sent from
      // iphone are extremely low quality"). One nothing is known of says nothing.
      expect(find.text('320 × 240 · 913 KB'), findsOneWidget);
      expect(find.text(shrunkNote), findsOneWidget);
      // One no picture can be made of is still named, and can still be tried.
      expect(find.text('9864ade8-2512-4c3f-83b2-8d46dbb76b14.webm'), findsOneWidget);
      // Each opens Uplink's own player (Matt: "id like a video player built with glacier UI"), closed again by its back button.
      VideoPlayerPlatform.instance = FakeVideoPlayer();
      for (final p in [players.first, players.last]) {
        await tester.tap(p);
        await _settle(tester);
        expect(find.byType(VideoScreen), findsOneWidget);
        await tester.tap(find.byWidgetPredicate((w) => w is GlacierPressable && w.semanticLabel == 'Back').last);
        await _settle(tester);
        expect(find.byType(VideoScreen), findsNothing);
      }
      expect(_videosPlayed.toSet(), {921, 922});
      // Voice messages: each drawn as a player that says how long it runs; the microphone stands where Send would.
      await _shoot(tester, sheet, const ThreadScreen(thread: 4, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '2-thread-voice', dark: dark);
      expect(find.text('0:07'), findsOneWidget);
      expect(find.text('0:23'), findsOneWidget);
      final mic = find.byWidgetPredicate((w) => w is IconTap && w.label == 'Record a voice message');
      expect(mic, findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send'), findsNothing);
      // One playing: where it has got to, and Pause where Play was.
      Sms.instance.voice.add(const VoicePlayback(part: 911, position: Duration(seconds: 3), length: Duration(milliseconds: 7400), playing: true));
      await _settle(tester);
      expect(find.text('0:03'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is GlacierPressable && w.semanticLabel == 'Pause voice message'), findsOneWidget);
      // Another starts: the first is back at its start.
      Sms.instance.voice.add(const VoicePlayback(part: 912, position: Duration(seconds: 1), length: Duration(seconds: 23), playing: true));
      await _settle(tester);
      expect(find.text('0:07'), findsOneWidget);
      expect(find.text('0:01'), findsOneWidget);
      Sms.instance.voice.add(const VoicePlayback(part: 912, position: Duration.zero, length: Duration(seconds: 23), playing: false));
      // Another arrives: each still says its own length (the list hands a player's place to another message, and
      // every one once wore the length of the first drawn there).
      _voiceMore = true;
      Sms.instance.changes.add(4);
      await _settle(tester);
      expect(find.text('0:41'), findsOneWidget);
      expect(find.text('0:23'), findsOneWidget);
      expect(find.text('0:07'), findsOneWidget);
      _voiceMore = false;
      // The microphone tapped: the composer is the recording, with its clock, how loud it is, and Send.
      await tester.tap(mic);
      for (var i = 0; i < 44; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _shootAgain(tester, '2-thread-voice-recording', dark: dark);
      expect(find.text('0:04'), findsOneWidget, reason: 'the clock counts while it records');
      expect(find.text('1:31'), findsOneWidget, reason: 'how long one may run on this carrier');
      expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send voice message'), findsOneWidget);
      expect(mic, findsNothing);
      // Thrown away: the composer is as it was.
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Discard the recording'));
      await _settle(tester);
      expect(mic, findsOneWidget);
      // Words written: Send at the end of the row under them, the microphone beside it.
      await tester.enterText(find.byType(EditableText), 'On my way');
      await _settle(tester);
      expect(mic, findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send'), findsOneWidget);
      await _shoot(tester, sheet, ThreadScreen(thread: 2, people: [for (final p in _conversations[1]['people'] as List) Person.from(p as Map)]), '3-group', dark: dark);
      // Where the unread began as the group was opened (Matt, 2026-11-16: "Add a "new messages" divider like discord has
      // for all group chats"): above the oldest of the four not read, under what came before.
      expect(find.byKey(const ValueKey('new-messages')), findsOneWidget);
      final divider = tester.getRect(find.byKey(const ValueKey('new-messages')));
      expect(divider.bottom, lessThanOrEqualTo(tester.getTopLeft(find.textContaining('Look at this view')).dy));
      expect(divider.top, greaterThanOrEqualTo(tester.getBottomLeft(find.text('Saturday works for me')).dy));
      await _shoot(tester, sheet, const ComposeScreen(), '4-compose', dark: dark);
      // A conversation keeps all its room: the card is the list's alone.
      _updateWaiting = true;
      await _shoot(tester, sheet, const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '1-update-banner-thread', dark: dark);
      expect(find.text('Update now'), findsNothing);
      _updateWaiting = false;
      // Nothing to show (here, nothing a search finds): the app's logo stands where the list would be.
      await _shoot(tester, sheet, const ConversationsScreen(), '1-conversations-none', dark: dark);
      await tester.enterText(find.byType(EditableText).first, 'zzzz');
      // The empty screen is built, then its picture is given the real time it takes to be read.
      await _settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
      await _shootAgain(tester, '1-conversations-none', dark: dark);
      expect(find.byType(GhostLogo), findsOneWidget);
      // The stickers' sheet over a conversation: the first pack, then the pastel one, in an encrypted conversation.
      final packs = (await tester.runAsync(stickerPacks))!;
      expect(packs.map((p) => p.name), ['Ghost', 'Love', 'Party', 'Sweet', 'Mischief']);
      for (final (pack, encrypted) in [('ghost', false), ('sweet', true), ('mischief', false)]) {
        await _shoot(
          tester,
          sheet,
          Stack(children: [
            const Positioned.fill(child: ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')])),
            const Positioned.fill(child: ColoredBox(color: Color(0x66000000))),
            Positioned.fill(child: StickerSheet(packs: packs, encrypted: encrypted)),
          ]),
          '4-stickers-$pack',
          dark: dark,
          prefs: {'sticker_pack': pack},
        );
        // The pictures are decoded off the fake clock.
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await _shootAgain(tester, '4-stickers-$pack', dark: dark);
      }
      // Settings: its home, a search over it, and a few of its sections' pages.
      await _shoot(tester, sheet, const SettingsScreen(), '5-settings', dark: dark);
      await tester.enterText(find.byType(EditableText).first, 'read');
      await _shootAgain(tester, '5-settings-search', dark: dark);
      for (final id in ['appearance', 'encryption', 'notifications', 'effects', 'keyboard', 'shortcuts', 'android', 'updates', 'computers', 'developer']) {
        await _shoot(tester, sheet, SettingsSectionScreen(id), '5-settings-$id', dark: dark);
      }
      // Settings › Me and Friends joining: the number verified by a code texted to it, two accounts linked, X's
      // sign-in not set up on the server, a watch list, and one of them here and new.
      Me.instance.seed(
        ready: true,
        listed: true,
        ways: const {'discord': 'signin', 'telegram': 'signin', 'x': 'off', 'bluesky': 'proof', 'mastodon': 'proof', 'github': 'proof', 'phone': 'text'},
        links: {'discord': 'matt', 'telegram': 'mattsoftware', 'phone': '+15550100199'},
        watch: const [Watched('discord', 'maya'), Watched('discord', 'jordan.p'), Watched('telegram', 'samrivera'), Watched('x', 'alexkim'), Watched('bluesky', 'priya.bsky.social'), Watched('bluesky', 'noor.bsky.social')],
        joined: [Joined('discord', 'maya', DateTime.now().subtract(const Duration(minutes: 12))), Joined('bluesky', 'priya.bsky.social', DateTime.now().subtract(const Duration(days: 2)), seen: true)],
      );
      await _shoot(tester, sheet, const SettingsSectionScreen('me'), '5-settings-me', dark: dark);
      expect(find.text('@matt'), findsOneWidget);
      expect(find.textContaining('isn\'t set up on the relay server yet'), findsOneWidget);
      // Bluesky, Mastodon and GitHub: not yet (Matt: "remove mastadon and the other options to link or mark them as
      // 'coming soon'").
      expect(find.text('Coming soon'), findsNWidgets(3));
      // The number, as a code texted to it showed it to be: said so under it, and not counted among what friends
      // are told.
      expect(find.text('+1 (555) 010-0199'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.textContaining('People watching for one of your accounts'), findsOneWidget);
      await _shoot(tester, sheet, const SettingsSectionScreen('friends-joining'), '5-settings-friends-joining', dark: dark);
      // New beside her handle, in the label's own line.
      expect(find.textContaining('@maya', findRichText: true), findsOneWidget);
      expect(find.text('New'), findsOneWidget);
      await _shoot(tester, sheet, ProofScreen(network: networkOf('bluesky')), '5-settings-me-proof', dark: dark);
      // Verifying a number: the phone's own, filled in, before a code is asked for.
      await _shoot(tester, sheet, const NumberScreen(own: '5550100142'), '5-settings-me-number', dark: dark);
      expect(find.text('Text me a code'), findsOneWidget);
      // Not verified, on a server that has no texting service: the Me page says so in two words, and the page it
      // opens says why nothing can be sent.
      Me.instance.seed(links: {'discord': 'matt'}, ways: const {'discord': 'signin', 'telegram': 'signin', 'x': 'off', 'bluesky': 'proof', 'mastodon': 'proof', 'github': 'proof'});
      await _shoot(tester, sheet, const SettingsSectionScreen('me'), '5-settings-me-unverified', dark: dark);
      expect(find.text('Not verified'), findsOneWidget);
      await _shoot(tester, sheet, const NumberScreen(own: '5550100142'), '5-settings-me-number-off', dark: dark);
      expect(find.textContaining('Verifying a number by text isn\'t set up'), findsOneWidget);
      await _shoot(tester, sheet, const AddWatchScreen(), '5-settings-me-add', dark: dark);
      Me.instance.seed(ready: false, listed: false, links: {}, watch: [], joined: [], ways: {});
      // Settings › Network: the app's routes, with two people to reach, the relay server ready and SMS not allowed,
      // and a test sent to one of them.
      final hub = _Route('hub', 'Relay server', 'Through a server on the internet. Works between any two networks; the server sees who talks to whom, never what is said.');
      final sms = _Route('sms', 'SMS', 'As data texts over the phone network. Needs no internet and reaches a phone whose app is closed.', up: false, metered: true)
        ..problem = 'This phone cannot send data texts now: no SIM, or SMS is not allowed for this app';
      await tester.runAsync(() => Net.instance.start(AppState(), carriers: [hub, sms]));
      expect(Net.instance.people.map((p) => p.name), ['Riley Fox', 'Noor Haddad']);
      await tester.runAsync(() => Net.instance.test(Net.instance.people.first));
      await _shoot(tester, sheet, const SettingsSectionScreen('network'), '5-settings-network', dark: dark);
      expect(find.text('Relay server'), findsWidgets);
      expect(find.textContaining('Ready'), findsOneWidget);
      expect(find.textContaining('cannot send data texts'), findsOneWidget);
      expect(find.textContaining('A test was sent to Riley Fox'), findsOneWidget);
      expect(find.text('Invite someone by text'), findsOneWidget);
      expect(inviteText, contains('https://gogho.st'));
      expect(hub.carried, 1, reason: 'the test went by the route that is up');
      expect(sms.carried, 0);
      await tester.runAsync(Net.instance.shutdown);
      // Pairing with a computer, step by step: before a code is scanned, while the computer is looked for, the six
      // digits to compare, and paired.
      const mac = {'name': 'Matt\'s MacBook Pro', 'mode': 'both', 'offered': 'both', 'relay': 'wss://gogho.st/relay'};
      for (final (name, state) in <(String, Map<String, Object?>)>[
        ('start', {'phase': 'none'}),
        ('waiting', {...mac, 'phase': 'waiting'}),
        ('code', {...mac, 'phase': 'code', 'code': '874151'}),
        ('done', {...mac, 'phase': 'done', 'code': '874151', 'mine': true, 'theirs': true}),
      ]) {
        _pairing = state;
        await _shoot(tester, sheet, const PairComputerScreen(), '10-pair-$name', dark: dark);
      }
      _pairing = {'phase': 'none'};
      // The phone's camera opened a computer's pairing link: asked first, before anything is done with it.
      await _shoot(tester, sheet, const PairComputerScreen(offered: 'ghostmsg://pair/abc'), '10-pair-asked', dark: dark);
      expect(find.text('Pair with Matt\'s MacBook Pro?'), findsOneWidget);
      // Encryption in a conversation: on and verified, and a key waiting for a yes.
      await _shoot(tester, sheet, const ThreadScreen(thread: 8, people: [Person(address: '+15551230011', name: 'Riley Fox')]), '8-encrypted', dark: dark);
      await _shoot(tester, sheet, const ThreadScreen(thread: 9, people: [Person(address: '+15551230012', name: 'Noor Haddad')]), '8-encryption-asked', dark: dark);
      // A conversation's own settings, from its cog: its background and bubbles, encryption, mute and pin.
      await _shoot(tester, sheet, const ChatSettingsScreen(thread: 8, people: [Person(address: '+15551230011', name: 'Riley Fox')]), '9-chat-settings', dark: dark, prefs: const {'chat_bg_8': 'preset:rose', 'bubble_8': 'white'});
      // Your bubbles in white, with the line the light page needs round them.
      await _shoot(tester, sheet, const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '9-bubbles-white', dark: dark, prefs: const {'bubble': 'white'});
      // Chat backgrounds: the picker, and a conversation wearing a wash.
      await _shoot(tester, sheet, const BackgroundPicker(), '9-background-picker', dark: dark);
      // A conversation's own, synced with someone who has the app: the shared one worn, and the switch on.
      await _shoot(tester, sheet, const BackgroundPicker(thread: 8, who: 'Riley Fox', people: [Person(address: '+15551230011', name: 'Riley Fox')]), '9-background-sync', dark: dark, prefs: const {'chat_bg_8': 'preset:rose', 'chat_bg_synced_8': 'preset:rose'});
      await _shoot(tester, sheet, const ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '9-background-dusk', dark: dark, prefs: const {'chat_bg': 'preset:dusk'});
      // The walkthrough (Matt, 2026-11-15: "Look at how we do onboarding on Ghost KBD and Ghost Markdown with the
      // optional voice guide through the elevenlabs key and the vibrant colors and iconography for each step, mimick
      // this on the setup of Ghost Messaging"): since 2026-11-20 the texts page alone, which holds Continue until Uplink
      // can send (Matt: "rework the onboarding flow to be very simple").
      _statusSaid = const {'isDefault': false, 'contacts': false, 'notifications': false, 'phone': true};
      await _shoot(tester, sheet, const Onboarding(), '0-guide-2-texts', dark: dark);
      expect(find.text('Set as default SMS app'), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-skip')), findsNothing, reason: 'nothing to skip to before Uplink can send texts');
      await tester.tap(find.byKey(const ValueKey('guide-next')));
      await _settle(tester);
      expect(find.text('Start with your texts'), findsOneWidget, reason: 'Continue waits until Uplink can send texts');
      // Google Messages on the phone and texts allowed, notification access not yet: the way to keep it, and RCS
      // (Matt, 2026-11-15: "I'd like to have a way that people can reliably get text in and out of ghost without
      // needing to switch the default messaging app").
      _statusSaid = const {'isDefault': false, 'contacts': true, 'notifications': true, 'phone': true, 'gmInstalled': true, 'sms': true, 'bridge': false};
      await _shoot(tester, sheet, const Onboarding(), '0-guide-2-texts-beside', dark: dark);
      expect(find.text('Or keep Google Messages, and RCS'), findsOneWidget);
      expect(find.text('Use beside Google Messages'), findsOneWidget);
      // Setting up RCS from Settings › Messages (lib/ui/rcs_setup.dart; Matt, 2026-11-15: "add a button under messages
      // settings to setup RCS if on an android phone and walk the user through how to enable the rcs sidecar"): from
      // Uplink the default, Google Messages the next thing to make so; and part way, Google Messages the default.
      _statusSaid = const {'isDefault': true, 'contacts': true, 'notifications': true, 'phone': true, 'gmInstalled': true, 'sms': true, 'bridge': false, 'gmDefault': false};
      await _shoot(tester, sheet, const RcsSetupScreen(), '19-rcs-setup', dark: dark);
      expect(find.text('Open Default apps'), findsOneWidget);
      expect(find.text('Google Messages is the default SMS app'), findsOneWidget);
      _statusSaid = const {'isDefault': false, 'contacts': true, 'notifications': true, 'phone': true, 'gmInstalled': true, 'sms': true, 'bridge': false, 'gmDefault': true};
      await _shoot(tester, sheet, const RcsSetupScreen(), '19-rcs-setup-partway', dark: dark, prefs: const {'rcs_on_chosen': 'on'});
      expect(find.text('Open notification access'), findsOneWidget);
      // The last step, Google Messages' "Incoming messages" and one conversation of its own still loud (Matt,
      // 2026-11-15: "investigate silencing google messages notifications so we only see thr ones coming through
      // ghost instead").
      _statusSaid = const {'isDefault': false, 'contacts': true, 'notifications': true, 'phone': true, 'gmInstalled': true, 'sms': true, 'bridge': true, 'gmDefault': true};
      _gmChannels = const [
        {'id': 'bugle_default_channel', 'name': 'Incoming messages', 'importance': 4, 'loud': true, 'popup': true, 'conversation': null, 'title': null},
        {'id': 'c-437', 'name': 'Mo', 'importance': 4, 'loud': true, 'popup': true, 'conversation': '437', 'title': 'Mo'},
        {'id': 'bugle_misc_channel', 'name': 'Other notifications', 'importance': 2, 'loud': false, 'popup': false, 'conversation': null, 'title': null},
      ];
      await _shoot(tester, sheet, const RcsSetupScreen(), '19-rcs-setup-loud', dark: dark, prefs: const {'rcs_on_chosen': 'on'});
      await tester.scrollUntilVisible(find.text('Silence Mo'), 200, scrollable: find.byType(Scrollable).first);
      await _shootAgain(tester, '19-rcs-setup-loud', dark: dark);
      expect(find.text('Silence Incoming messages'), findsOneWidget);
      expect(find.text('Silence Other notifications'), findsNothing, reason: 'quiet already');
      _gmChannels = const [];
      // The on-phone Google Messages connection (lib/ui/gm_web_screen.dart; Matt, 2026-11-15: "Can you build the on
      // phone google messages connection too?"): not paired, then paired and connected.
      _gmWeb = const {'available': true, 'running': true, 'paired': false, 'connected': false};
      await _shoot(tester, sheet, const GmWebScreen(), '19-gm-web', dark: dark);
      // Google-account pairing, all in one place (Matt, 2026-11-15: "Please make setting up google messages a
      // onboarding flow that is all in one place"): the steps, the paste box, and the QR way kept below.
      expect(find.text('Sign in to Google in a private window'), findsOneWidget);
      expect(find.text('Copy the link'), findsOneWidget);
      // The emoji, once Google has it: the last step alone.
      _gmWeb = const {'available': true, 'running': true, 'paired': false, 'connected': false, 'emoji': '🦊'};
      await _shoot(tester, sheet, const GmWebScreen(), '19-gm-web-emoji', dark: dark);
      expect(find.text('🦊'), findsOneWidget);
      _gmWeb = const {'available': true, 'running': true, 'paired': true, 'connected': true, 'phone': '+1 555-123-0000'};
      await _shoot(tester, sheet, const GmWebScreen(), '19-gm-web-paired', dark: dark);
      expect(find.text('Connected'), findsOneWidget);
      // The guide to running it on a Mac or PC (Matt, 2026-11-15: "Tell me how to setup the sidecar on mac and PC in a
      // guide found in settings").
      await _shoot(tester, sheet, const GmGuideScreen(), '19-gm-guide', dark: dark);
      expect(find.text('1. Get the app'), findsOneWidget);
      // The app's own video player (lib/ui/video_screen.dart; Matt, 2026-11-15: "id like a video player built with
      // glacier UI right now it looks like a very old android core system player"), the stand-in engine at 0:42 of 2:40.
      // The stand-in plays through video_player, so the engine is pinned to it: on a computer (this test's host) the app
      // would pick media_kit (lib/ui/video_engine.dart), which the stand-in doesn't reach.
      VideoPlayerPlatform.instance = FakeVideoPlayer();
      VideoEngine.make = VideoPlayerEngine.new;
      await _shoot(tester, sheet, const VideoScreen(path: '/tmp/none.mp4', title: 'Maya Chen'), '21-video', dark: dark);
      expect(find.text('2:40'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
      VideoEngine.make = VideoEngine.defaultEngine;
      _gmWeb = const {'available': true, 'running': true, 'paired': false, 'connected': false};
      // Uplink is the texting app: the texts page says so, and Continue (the walkthrough is that page alone since
      // 2026-11-20).
      _statusSaid = const {'isDefault': true, 'contacts': false, 'notifications': false, 'phone': true};
      await _shoot(tester, sheet, const Onboarding(), '0-guide-2-texts-done', dark: dark);
      expect(find.byKey(const ValueKey('guide-skip')), findsOneWidget);
      expect(find.text('Uplink is your texting app.'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      _statusSaid = const {'isDefault': true, 'contacts': true, 'notifications': false, 'phone': true};
      // Then the first page of one's own: a username and a password, and signing in to an account one has as a section
      // on the same page (Matt, 2026-11-20).
      await _shoot(tester, sheet, StandaloneWelcome(onDone: () {}), '0-welcome', dark: dark);
      expect(find.text('Already have an account?'), findsOneWidget);
      expect(find.byKey(const ValueKey('welcome-sign-in')), findsOneWidget);
      // Each effect at a moment of its run, over the conversation.
      const night = {ScreenEffect.fireworks, ScreenEffect.celebration, ScreenEffect.lasers, ScreenEffect.snow, ScreenEffect.goodNight, ScreenEffect.party, ScreenEffect.spotlight};
      for (final effect in ScreenEffect.values) {
        final at = switch (effect) { ScreenEffect.fireworks || ScreenEffect.celebration => 0.3, ScreenEffect.lasers => 0.4, ScreenEffect.wow => 0.35, _ => 0.5 };
        if (dark != night.contains(effect)) continue;
        // The effect's own pictures (assets/effects/, cut by tool/effect_sprites.py), decoded off the fake clock.
        final sprites = await tester.runAsync(() => EffectSprites.of(effect));
        expect(sprites, isNotNull, reason: '${effect.name} has no pictures in assets/effects/');
        expect(sprites!.heroes, isNotEmpty, reason: '${effect.name} has no characters');
        expect(sprites.props, isNotEmpty, reason: '${effect.name} has no props');
        // Its characters move (tool/effect_anims.py): all four, but for the two Matt has not drawn yet.
        expect(sprites.animated, effect == ScreenEffect.balloons || effect == ScreenEffect.confetti ? 3 : 4, reason: '${effect.name} has ${sprites.animated} moving characters');
        await _shoot(
          tester,
          sheet,
          Stack(children: [
            const Positioned.fill(child: ThreadScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')])),
            Positioned.fill(
              child: IgnorePointer(
                child: Builder(
                  builder: (context) => CustomPaint(
                    painter: EffectPainter(effect, AlwaysStoppedAnimation(at), 7, style: context.tokens.textAt(26, color: context.tokens.color('app-ink')), text: 'See you at 7!', sprites: sprites),
                  ),
                ),
              ),
            ),
          ]),
          '6-effect-${effect.name}',
          dark: dark,
        );
      }
    }
  });

  // The plugins (lib/plugins): the list with its sections' chips, the Codes section, and Settings › Plugins.
  // Pictures 12-plugins-*.
  testWidgets('plugins: the list\'s sections and Settings › Plugins', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    // More of what the plugins sort than the list above holds, for this test alone.
    _conversations.addAll(_sortable);
    addTearDown(() => _conversations.removeWhere((c) => (c['id'] as int) >= 100));
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    // Icons alone since 2026-11-15, each tab named for a screen reader.
    Finder chip(String label) => find.descendant(
          of: find.byType(SectionTabs),
          matching: find.byWidgetPredicate((w) => (w is Semantics && (w.properties.label == label || (w.properties.label ?? '').startsWith('$label, '))) || (w is Text && w.data == label)),
        );
    for (final dark in [false, true]) {
      // The list as it opens: the codes have left it for their chip, which counts them. Spam, the political text,
      // the debt collector and the sales pitch are hidden by the filter beside the tabs, which says how many, as
      // the list's foot does; the delivery, the bill and the appointment stay (Matt, 2026-11-14: "a filter dropdown
      // where showing spam, political messages, and debt collectors are filtered out by default", "also add in
      // blocking of door to door sales").
      await _shoot(tester, sheet, const ConversationsScreen(), '12-plugins-list', dark: dark);
      expect(chip('Messages'), findsOneWidget);
      expect(chip('Codes'), findsOneWidget);
      expect(chip('Spam'), findsNothing, reason: 'the kinds are the filter\'s, not tabs');
      expect(find.textContaining('482913'), findsNothing);
      expect(find.textContaining('Paid for by'), findsNothing);
      expect(find.textContaining('collect a debt'), findsNothing);
      expect(find.textContaining('Tree trimming'), findsNothing);
      expect(find.textContaining('You\'ve won'), findsNothing);
      expect(tester.widget<FilterButton>(find.byType(FilterButton)).hidden, 5);
      // The filter's menu: each kind to show or hide, with how many, and each to show alone.
      await tester.tap(find.byType(FilterButton));
      await _shootAgain(tester, '12-plugins-filter', dark: dark);
      for (final kind in ['Spam', 'Political', 'Debt collectors', 'Sales & solicitors', 'Payment reminders', 'Deliveries & tracking', 'Appointments']) {
        expect(find.descendant(of: find.byType(GlacierMenuItem), matching: find.text(kind)), findsWidgets, reason: kind);
      }
      expect(find.descendant(of: find.byType(GlacierMenuItem).first, matching: find.text('All')), findsOneWidget);
      // Everything hidden, from the list's foot: each saying what it is, with the way to put it back.
      // Closed by its own button, as it was opened.
      await tester.tap(find.byType(FilterButton));
      await _settle(tester);
      expect(find.byType(GlacierMenuItem), findsNothing);
      await tester.scrollUntilVisible(find.text('5 hidden · Show'), 300, scrollable: find.ancestor(of: find.byType(ConversationRow).first, matching: find.byType(Scrollable)).first);
      await tester.tap(find.text('5 hidden · Show'));
      await _shootAgain(tester, '12-plugins-hidden', dark: dark);
      expect(find.byType(PluginRow), findsNWidgets(5));
      expect(find.text('Not political'), findsOneWidget);
      expect(find.text('Not a debt collector'), findsOneWidget);
      expect(find.text('Not sales'), findsOneWidget);
      expect(find.text('Not spam'), findsNWidgets(2));
      await tester.tap(find.text('Show all'));
      await _settle(tester);
      // Codes: the newest first, each code large over the words it came in, with Copy at the row's end.
      await tester.tap(chip('Codes'));
      await _shootAgain(tester, '12-plugins-codes', dark: dark);
      expect(find.byType(PluginRow), findsNWidgets(4));
      expect(find.text('482913'), findsOneWidget);
      // Each is named by the company its words are from, where they say (Matt: "have the codes section try to
      // parse the company that's sending the code and show their company logo as the code profile picture like
      // coinbase discover etc"): two the app knows, with a face of their own; one it does not, by the name its
      // text gives; and one whose text names nobody, left with its number.
      expect(find.text('Coinbase'), findsOneWidget);
      expect(find.text('Discover'), findsOneWidget);
      expect(find.text('Brightwater Credit Union'), findsOneWidget);
      expect(find.text('28849'), findsOneWidget);
      expect(find.text('70220'), findsNothing);
      expect(find.byType(BrandFace), findsNWidgets(2));
      // A tap copies, and says so.
      await tester.tap(find.text('771204'));
      await _shootAgain(tester, '12-plugins-codes-copied', dark: dark);
      expect(find.text('Copied 771204'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      // The Marketplace, where plugins are since 2026-11-20 (Matt: "Move plugins out of settings into a marketplace
      // button on the navigation rail with a marketplace icon"): its list on a phone, the band leading to Discover and
      // its sections under it; and Discover, the Plugins page of 2026-11-17 (Matt: "redo how the plugins look with
      // their own dedicated plugins page with a marketplace like look how ghostmd has"), a card for each plugin (Codes
      // and the Spam filter featured too), and a plugin's settings on its own page.
      await _shoot(tester, sheet, const MarketplaceScreen(), '12-plugins-marketplace', dark: dark);
      expect(find.byKey(const ValueKey('plugins-entry')), findsOneWidget, reason: 'the band, on a phone\'s list');
      expect(find.byKey(const ValueKey('market-row-discover')), findsOneWidget);
      expect(find.byKey(const ValueKey('market-row-added')), findsOneWidget);
      await _shoot(tester, sheet, marketPluginsScreen(), '12-plugins-settings', dark: dark);
      expect(find.text('Codes'), findsWidgets);
      expect(find.text('Spam filter'), findsWidgets);
      expect(find.text('Mark as read when copied'), findsNothing);
      await _shoot(tester, sheet, const SettingsSectionScreen('plugin-codes'), '12-plugins-settings-codes', dark: dark);
      expect(find.text('Mark as read when copied'), findsOneWidget);
      // Settings' list: no band and no Plugins row since the Marketplace has them; a plugin's own section is opened from
      // its page there, or by its id, and is not a row of the list.
      await _shoot(tester, sheet, const SettingsScreen(), '12-plugins-settings-list', dark: dark);
      expect(find.byKey(const ValueKey('plugins-entry')), findsNothing);
      expect(find.text('Spam filter'), findsNothing);
      expect(find.text('Kinds of text'), findsNothing);
      await _shoot(tester, sheet, const SettingsScreen(), '12-plugins-settings-list-off', dark: dark, prefs: const {'plugin_spam': 'off'});
      expect(find.byKey(const ValueKey('plugins-entry')), findsNothing);
      // A plugin's page, from the Plugins page since 2026-11-17: off, it offers to add it, and its settings wait
      // until it is added (in place of the switch at the top it had from 2026-11-14).
      await _shoot(tester, sheet, const SettingsSectionScreen('plugin-spam'), '12-plugins-settings-off', dark: dark, prefs: const {'plugin_spam': 'off'});
      expect(find.textContaining('Add to Uplink'), findsOneWidget);
      expect(find.text('Mute conversations in Spam'), findsNothing);
      // Kinds of text's own page: each kind, said in a line.
      await _shoot(tester, sheet, const SettingsSectionScreen('plugin-kinds'), '12-plugins-settings-kinds', dark: dark);
      expect(find.text('Sales & solicitors'), findsOneWidget);
      // And the Spam filter's, with what counts as spam said rule by rule.
      await _shoot(tester, sheet, const SettingsSectionScreen('plugin-spam'), '12-plugins-settings-spam', dark: dark);
      expect(find.text('Mute conversations in Spam'), findsOneWidget);
      await tester.drag(find.text('Mute conversations in Spam'), const Offset(0, -520));
      await _shootAgain(tester, '12-plugins-settings-spam-rules', dark: dark);
    }
  });

  // The app's frame (lib/ui/shell.dart): the list beside what is opened from it where the window is wide, under it
  // where it is narrow, and the same pages kept as the window changes. Pictures 11-frame-*.
  testWidgets('companies: every face the Codes section can draw', (tester) async {
    // Each company lib/plugins/companies.dart knows, as its code's row shows it: its mark on its colour where the
    // open pack of brand icons has one, its letter where it has not. A picture to look them all over by.
    tester.view.physicalSize = const Size(412 * 2.0, 1500 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    for (final dark in [false, true]) {
      await _shoot(
        tester,
        sheet,
        Builder(builder: (context) {
          final t = context.tokens;
          return ColoredBox(
            color: t.color('glacier-bg'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 10, 16),
              child: Wrap(spacing: 6, runSpacing: 10, children: [
                for (final c in companies)
                  SizedBox(
                    width: 50,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      BrandFace(face: RowFace(name: c.name, color: c.color, domain: c.domain, mark: companyMarks[c.domain]), size: 40),
                      const SizedBox(height: 3),
                      Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: pageText(t, 8, color: t.color('app-ink-2'))),
                    ]),
                  ),
              ]),
            ),
          );
        }),
        '12-plugins-company-faces',
        dark: dark,
      );
      expect(find.byType(BrandFace), findsNWidgets(companies.length));
    }
  });

  testWidgets('a group is given a name', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    const group = [Person(address: '+15551230002', name: 'Jordan Park'), Person(address: '+15551230003', name: 'Sam Rivera'), Person(address: '+15551230004', name: 'Alex Kim')];
    addTearDown(() => _conversations.firstWhere((c) => c['id'] == 2).remove('name'));
    for (final dark in [false, true]) {
      _conversations.firstWhere((c) => c['id'] == 2).remove('name');
      // The group's settings have a field for its name (Matt: "expand on the ability to create, name and manage
      // groups like telegram"), which shows what it goes by until one is given: its people's first names.
      await _shoot(tester, sheet, ChatSettingsScreen(key: ValueKey('group-$dark'), thread: 2, people: group), '14-group-name-settings', dark: dark);
      expect(find.textContaining(RegExp('group name', caseSensitive: false)), findsOneWidget);
      expect(find.text('Jordan, Sam, Alex'), findsWidgets);
      await tester.enterText(find.byType(EditableText).first, '  Weekend crew ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _shootAgain(tester, '14-group-name-settings', dark: dark);
      expect(_conversations.firstWhere((c) => c['id'] == 2)['name'], 'Weekend crew');
      // The page's own heading, the list and the conversation go by it from then on.
      expect(find.text('Weekend crew'), findsWidgets);
      await tester.pump(const Duration(seconds: 6));
      await _shoot(tester, sheet, ConversationsScreen(key: ValueKey('list-$dark')), '14-group-name-list', dark: dark);
      expect(find.text('Weekend crew'), findsOneWidget);
      expect(find.text('Jordan, Sam, Alex'), findsNothing);
      await _shoot(tester, sheet, ThreadScreen(key: ValueKey('named-$dark'), thread: 2, people: group), '14-group-name-thread', dark: dark);
      expect(find.text('Weekend crew'), findsOneWidget);
      // Emptied, the group goes by its people again. One person's conversation has no such field.
      await _shoot(tester, sheet, ChatSettingsScreen(key: ValueKey('group-again-$dark'), thread: 2, people: group), '14-group-name-settings', dark: dark);
      await tester.enterText(find.byType(EditableText).first, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _settle(tester);
      expect(_conversations.firstWhere((c) => c['id'] == 2)['name'], isNull);
      await tester.pump(const Duration(seconds: 6));
      await _shoot(tester, sheet, const ChatSettingsScreen(thread: 1, people: [Person(address: '+15551230001', name: 'Maya Chen')]), '9-chat-settings-one', dark: dark);
      expect(find.textContaining(RegExp('group name', caseSensitive: false)), findsNothing);
    }
  });

  testWidgets('groups of friends: made, written in, managed, left', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    const jordan = Person(address: '+15551230002', name: 'Jordan Park'), sam = Person(address: '+15551230003', name: 'Sam Rivera'), alex = Person(address: '+15551230004', name: 'Alex Kim');
    addTearDown(() {
      Friends.instance = null;
      Groups.instance = null;
      _groupNotes.clear();
    });
    for (final dark in [false, true]) {
      // This phone and three others, each a friend of this one; a relay server answers.
      final world = World();
      final mine = _GroupsPort(world, '+15550000000');
      for (final p in [jordan, sam, alex]) {
        FakeGroupsPort(world, p.address).friends.add(mine.number);
        mine.friends.add(p.address);
        mine.names[p.address] = p.name!;
      }
      _groupNotes.clear();
      final friends = Friends(_ThreeFriends('+15550000000', [jordan, sam, alex]));
      Friends.instance = friends;
      final groups = Groups(mine);
      Groups.instance = groups;
      await friends.start();
      await groups.start();
      // The address book: New group is under the list's + now, not here.
      await _shoot(tester, sheet, ContactsScreen(key: ValueKey('contacts-$dark')), '15-groups-contacts', dark: dark);
      // Friends by username at the top: the field to add one, a request to answer, one sent, and a friend (Matt,
      // 2026-11-16: "We need a way to add friends on the network by username on the contacts page and see friend
      // requests").
      final meStore = MemoryMeStore()..set('me_username', 'matt');
      await tester.runAsync(() => Me.instance.start(meStore, ValueNotifier(0), () => null));
      final buddies = Buddies(_KeptBuddies([
        const Buddy(username: 'riley', id: 'r1', key: 'k', name: 'Riley Fox', bio: 'Climbing on Saturdays', state: 'invited'),
        const Buddy(username: 'noor', id: 'n1', key: 'k', state: 'asked'),
        const Buddy(username: 'jamie', id: 'j1', key: 'k', name: 'Jamie Lee', state: 'yes'),
        // Jamie again under another id (a reinstall of theirs, or a phone's and a computer's lists put together): shown
        // once (Matt, 2026-11-19: "my friends are duplicated I have two copies of all my friends on the app").
        const Buddy(username: 'jamie', id: 'j2', key: 'k2', name: 'Jamie Lee', state: 'yes', at: 2),
      ]));
      Buddies.instance = buddies;
      await tester.runAsync(buddies.start);
      await _shoot(tester, sheet, ContactsScreen(key: ValueKey('contacts-friends-$dark')), '15-contacts-friends', dark: dark);
      expect(find.text('Friend request'), findsOneWidget);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Waiting for them'), findsOneWidget);
      // Jamie, a friend by username, is On Uplink with the friends by number: no section of their own (Matt,
      // 2026-11-19: "just show the On Ghost Messaging and remove the Friends by username section on the contacts page").
      expect(find.text('Friends by username'), findsNothing);
      expect(find.text('On Uplink'), findsOneWidget);
      expect(find.text('Jamie Lee'), findsOneWidget);
      expect(find.text('@jamie'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Jamie Lee')).dy, lessThan(tester.getTopLeft(find.text('Contacts').last).dy));
      Buddies.instance = null;
      await tester.runAsync(() => Me.instance.start(MemoryMeStore(), ValueNotifier(0), () => null));
      expect(find.text('New group'), findsNothing);
      // The people added on Uplink come first, under their own heading, and the phone's contacts after.
      expect(find.text('On Uplink'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Alex Kim')).dy, lessThan(tester.getTopLeft(find.text('Contacts').last).dy));
      expect(tester.getTopLeft(find.text('Sam Rivera')).dy, lessThan(tester.getTopLeft(find.text('Maya Chen')).dy));
      // Its name, and who is in it; Create waits for someone to be chosen.
      await _shoot(tester, sheet, NewGroupScreen(key: ValueKey('new-$dark')), '15-groups-new', dark: dark);
      await tester.tap(find.text('Create'));
      await _settle(tester);
      expect(groups.all, isEmpty);
      await tester.enterText(find.byType(EditableText).first, 'Weekend crew');
      await tester.tap(find.text('Jordan Park'));
      await tester.tap(find.text('Sam Rivera'));
      await _shootAgain(tester, '15-groups-new', dark: dark);
      expect(find.text('2 chosen. You will be its admin.'), findsOneWidget);
      await tester.tap(find.text('Create'));
      await _settle(tester);
      final made = groups.all.single;
      expect(made.name, 'Weekend crew');
      expect(made.members.length, 3);
      expect(made.amAdmin, isTrue);
      // Its conversation: its name, how many are in it, the line that says it was made, and words alone to write.
      mine.threads[made.id] = 2;
      await groups.refresh();
      await _shoot(tester, sheet, ThreadScreen(key: ValueKey('group-$dark'), thread: 2, people: const [jordan, sam]), '15-groups-thread', dark: dark);
      expect(find.text('Weekend crew'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.text('You made the group "Weekend crew"'), findsOneWidget);
      expect(find.text('Message'), findsOneWidget);
      // Words alone here, so Add an attachment is there but greyed out, where every conversation has it (Matt,
      // 2026-11-17: "if it's not avilable on a given chat just disable the button but still show it").
      expect(tester.widget<IconTap>(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Add an attachment')).onPressed, isNull);
      await tester.enterText(find.byType(EditableText).first, 'Hike on Saturday?');
      // Send slides in under the words as they are typed.
      await _settle(tester);
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send'));
      await _settle(tester);
      expect(mine.rows.values.single, (group: made.id, words: 'Hike on Saturday?', state: 'sent'));
      // Its settings, for its admin: the name everyone sees, the members, adding a friend, making another admin,
      // taking someone out.
      await tester.pump(const Duration(seconds: 6));
      await _shoot(tester, sheet, ChatSettingsScreen(key: ValueKey('gs-$dark'), thread: 2, people: const [jordan, sam]), '15-groups-settings', dark: dark);
      expect(find.text('Everyone in the group sees this name.'), findsOneWidget);
      // Far enough down for the last of the members' rows, and no further.
      Scrollable.ensureVisible(tester.element(find.text('Leave group')), alignment: 0.85);
      await _settle(tester);
      await _shootAgain(tester, '15-groups-settings', dark: dark);
      expect(find.text('Admin'), findsWidgets);
      await tester.tap(find.text('Add people'));
      await _settle(tester);
      await tester.tap(find.text('Alex Kim'));
      await _settle(tester);
      expect(groups.of(made.id)!.members.length, 4);
      expect(_groupNotes.last, 'You added Alex Kim');
      await tester.pump(const Duration(seconds: 6));
      await tester.tap(find.text('Sam Rivera'));
      await _shootAgain(tester, '15-groups-member', dark: dark);
      await tester.tap(find.text('Make admin'));
      await _settle(tester);
      expect(groups.of(made.id)!.members.where((m) => m.admin).length, 2);
      await tester.tap(find.text('Jordan Park'));
      await _settle(tester);
      await tester.tap(find.text('Remove from group'));
      await _settle(tester);
      expect(groups.of(made.id)!.members.map((m) => m.label), ['You', 'Sam Rivera', 'Alex Kim']);
      // Leaving: the conversation stays, and says nothing more can be written in it.
      await tester.tap(find.text('Leave group'));
      await _settle(tester);
      await tester.tap(find.text('Leave group').last);
      await _settle(tester);
      expect(groups.of(made.id)!.gone, isTrue);
      expect(find.text('You are no longer in this group.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await _shoot(tester, sheet, ThreadScreen(key: ValueKey('left-$dark'), thread: 2, people: const [sam, alex]), '15-groups-left', dark: dark);
      expect(find.text('You are no longer in this group.'), findsOneWidget);
      expect(find.text('You left the group'), findsOneWidget);
    }
  });

  testWidgets('friends: the offer, a request each way, friends', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    const maya = [Person(address: '+15551230001', name: 'Maya Chen')];
    // The routes and the phone under Friends, standing in: what it is told about Maya is what the phone then says.
    final port = _FriendsPort('+15550000000');
    port.other = FakePort('+15551230001')..other = port;
    addTearDown(() {
      Friends.instance = null;
      _mayaFriend = '';
    });
    for (final dark in [false, true]) {
      // No relay server is known to answer (a phone that has never reached one: once one has answered, friends
      // stay offered): the conversation offers encryption as it always did, and no friend.
      Friends.instance = Friends(port);
      _mayaFriend = '';
      port.up = false;
      await _shoot(tester, sheet, ThreadScreen(key: ValueKey('none-$dark'), thread: 1, people: maya), '13-friends-none', dark: dark);
      expect(find.text('Add friend'), findsNothing);
      expect(find.text('Turn on'), findsOneWidget);
      // One answers (Matt: "If both users chatting are on ghost messenger show an 'add friend' button"): Add friend
      // stands where the offer of encryption stood.
      port.up = true;
      await _shoot(tester, sheet, ThreadScreen(key: ValueKey('offer-$dark'), thread: 1, people: maya), '13-friends-offer', dark: dark);
      expect(find.text('Add friend'), findsOneWidget);
      expect(find.text('Turn on'), findsNothing);
      // Pressed: this phone's key goes to her first, and the asking waits for hers.
      port.keysSent.clear();
      await tester.tap(find.text('Add friend'));
      await _shootAgain(tester, '13-friends-asked', dark: dark);
      expect(port.keysSent, ['+15551230001']);
      expect(_mayaFriend, 'want');
      expect(find.text('Friend request sent. Waiting for Maya Chen to accept.'), findsOneWidget);
      expect(find.text('Add friend'), findsNothing);
      // She asked: said until it is answered. Accepted, the two are friends and the conversation says so; what was
      // last said went by the internet.
      _mayaFriend = 'invited';
      await _shoot(tester, sheet, ThreadScreen(key: ValueKey('invited-$dark'), thread: 1, people: maya), '13-friends-invited', dark: dark);
      expect(find.textContaining('wants to add you as a friend'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await _shootAgain(tester, '13-friends', dark: dark);
      expect(_mayaFriend, 'yes');
      expect(find.text('Friend · encrypted'), findsOneWidget);
      expect(find.textContaining('wants to add you as a friend'), findsNothing);
      // The conversation's settings say it, with the way to stop. (The words that said they are friends have gone
      // by then: they stand over the foot of the screen for a few seconds.)
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      await _shoot(tester, sheet, const ChatSettingsScreen(thread: 1, people: maya), '13-friends-settings', dark: dark);
      expect(find.text('Friend · encrypted'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Friends'), 300, scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -160));
      await _shootAgain(tester, '13-friends-settings', dark: dark);
      expect(find.text('Friends'), findsOneWidget);
      await tester.tap(find.text('Friends'));
      await _settle(tester);
      await tester.tap(find.text('Remove friend'));
      await _settle(tester);
      expect(_mayaFriend, '');
      expect(find.text('Add friend'), findsOneWidget);
    }
  });

  testWidgets('the bubble colour chosen everywhere is the app\'s accent', (tester) async {
    // Matt, 2026-11-14: "make the bubble color the accent color for the app so the send button, segmented toggles,
    // etc all get the same color as the bubbles if set globally and only settings inside a chat soley change the
    // bubble color". Blue bubbles: Send, the list's chosen tab and the page shown in the pill are blue too.
    tester.view.physicalSize = const Size(750 * 2.0, 832 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final accents = (await tester.runAsync(AccentSheets.load))!;
    installSettingsStyles(accents.base);
    for (final dark in [false, true]) {
      final sheet = accents.of(AppState()..setBubble('blue'));
      await _shoot(tester, sheet, const AppShell(), '16-accent-blue', dark: dark, prefs: const {'bubble': 'blue'});
      await tester.tap(find.text('Maya Chen').first);
      await _settle(tester);
      await tester.enterText(find.byType(EditableText).last, 'On my way');
      await _shootAgain(tester, '16-accent-blue', dark: dark);
      final send = find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send');
      expect(send, findsOneWidget);
      final disc = find.descendant(of: send, matching: find.byType(Container)).evaluate().map((e) => (e.widget as Container).decoration).whereType<BoxDecoration>().map((d) => d.color?.toARGB32()).toList();
      expect(disc, contains(0xFF0A84FF), reason: 'Send wears the bubble colour');
      // Sent, it is drawn at once as sending, before the phone has answered (Matt, 2026-11-15: "optimistically render a
      // sent message bubble so it appears instantly").
      await tester.tap(send);
      await tester.pump();
      expect(find.text('On my way', findRichText: true), findsOneWidget, reason: 'the bubble, the composer emptied');
      expect(find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'sending'), findsWidgets);
      await _settle(tester);
      // And every other colour is as it was (Matt, of 0.7.15: "make sure this next update brings back all the
      // colors to the app, they're missing from virtually every place where we had colors before on all the message
      // avatars and settings sections"): a face keeps its own colour, and so does each section of Settings.
      // The colours worn under a `hue` (each face, each section's chip), as drawn now.
      Set<int> hues() => {
            for (final e in find.byType(GlacierScope).evaluate())
              if ((e.widget as GlacierScope).attrs['hue'] != null)
                settingsHue(tester.element(find.descendant(of: find.byWidget(e.widget), matching: find.byType(Builder)).first).tokens).toARGB32(),
          };
      expect(hues().length, greaterThan(2), reason: 'faces are in several colours, not one grey');
      await _shoot(tester, sheet, const SettingsScreen(), '16-accent-blue-settings', dark: dark, prefs: const {'bubble': 'blue'});
      expect(hues().length, greaterThan(4), reason: 'Settings\' sections are in their colours, not the ink');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    }
  });

  // Voice channels (lib/ui/voice_screen.dart; Matt, 2026-11-14: "always open voice channels that you can jump in and
  // out at any time and you can see who's connected and also toggle video on and off").
  testWidgets('the Voice page: in a channel, and the channels with who is in them', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 1100 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final hangout = VoiceChannel.make('Friday space'), study = VoiceChannel.make('Study room');
    final v = Voice.instance;
    v.own = [hangout, study];
    // In a group's call, which the Voice page draws itself: the list of who is in it and the dock (a space's call is
    // its own page, lib/ui/space_designs). Maya is talking, and so, a little, is this phone.
    final s = VoiceSession(channel: VoiceChannel.ofGroup('friday', 'Friday space'), route: _NoRoute(), media: _NoMedia({'a': 0.45, 'me': 0.12}), name: 'Me')
      ..members['a'] = const VoiceMember('a', name: 'Maya Chen', username: 'maya')
      ..members['b'] = const VoiceMember('b', name: 'Sam', muted: true)
      ..members['c'] = const VoiceMember('c', name: 'Riley', guest: true);
    v.session = s;
    // The Mac's devices, as macOS names them.
    RtcMedia.enumerate = () async => [
          MediaDeviceInfo(kind: 'audioinput', label: 'MacBook Air Microphone', deviceId: 'mic-1'),
          MediaDeviceInfo(kind: 'audioinput', label: 'AirPods Pro', deviceId: 'mic-2'),
          MediaDeviceInfo(kind: 'audiooutput', label: 'MacBook Air Speakers', deviceId: 'out-1'),
          MediaDeviceInfo(kind: 'audiooutput', label: 'AirPods Pro', deviceId: 'out-2'),
        ];
    addTearDown(() => RtcMedia.enumerate = null);
    addTearDown(() {
      v.session = null;
      v.own = [];
    });
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, const VoiceScreen(), '19-voice', dark: dark);
      expect(find.text('Friday space'), findsWidgets);
      // In a call the page is the call alone: who is in it and the dock (Matt, 2026-11-15: "I want the call screen to
      // be super simple too just a list of chatters and the call controls").
      expect(find.text('Spaces'.toUpperCase()), findsNothing);
      expect(find.text('Study room'), findsNothing);
      // A list of who is there, faces rippling while they talk, and no squares: nobody has video on (Matt,
      // 2026-11-15: "make the voice chats a list of participants don't show the squares unless someone turns on
      // video"); the buttons in a dock at the foot.
      expect(find.byType(RippleAvatar), findsNWidgets(4));
      expect(find.byType(StreamView), findsNothing);
      expect(find.byType(CallDock), findsOneWidget);
      expect(find.bySemanticsLabel('Mute'), findsOneWidget);
      expect(find.bySemanticsLabel('Turn video on'), findsOneWidget);
      // Press and hold someone: mute them for you, their volume, add them as a friend (Matt, 2026-11-15: "add the
      // ability to press and hold on a user to habe options like muting changing volume levels for that user and
      // more").
      await tester.longPress(find.text('Maya Chen'));
      await _settle(tester);
      await _shootAgain(tester, '19-voice-person', dark: dark);
      expect(find.text('Mute for me'), findsOneWidget);
      expect(find.byType(VolumeSlider), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Add @maya as a friend'), findsOneWidget);
      await tester.tapAt(tester.getCenter(find.byType(VolumeSlider)) + const Offset(60, 0));
      await _settle(tester);
      expect(find.text('100%'), findsNothing, reason: 'louder than as sent');
      expect(v.volumeOf('a'), greaterThan(1.0));
      v.setVolume('a', 1.0);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);
      // The microphone and the speaker as pills, each with a chevron to its devices (Matt, 2026-11-15: "on the
      // microphone icon and the deafen icon make them pill shaped with a little chevron facing up that opens a popover
      // to select input and output devices respectively").
      // And the camera a third, on a computer (GMFB-68).
      expect(find.byType(DevicePill), findsNWidgets(3));
      await tester.tap(find.bySemanticsLabel('Choose a microphone'));
      await _settle(tester);
      await _shootAgain(tester, '19-voice-devices', dark: dark);
      expect(find.text('Microphone'.toUpperCase()), findsOneWidget);
      expect(find.text('Voice settings…'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);
      // Settings › Voice and video.
      await _shoot(tester, sheet, const SettingsSectionScreen('voice'), '19-voice-settings', dark: dark);
      expect(find.text('Bit rate'), findsOneWidget);
      expect(find.text('510 kb/s'), findsOneWidget);
      expect(find.text('Echo cancellation'), findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  // Matt, 2026-11-15: "Implement a permissions system similar to discord for hangouts and add a chat to hangouts so the
  // whole group can send messages to the hangout as well as voice and video, make default roles such as admin,
  // moderator, member".
  testWidgets('a hangout: its chat, roles beside names, moderation on press and hold, and its roles page', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    // This phone owns the hangout; Maya is a moderator, Sam a member (muted), Riley a guest from the link.
    final keys = NetKeys.generate();
    final channel = VoiceChannel.make('Friday hang', owner: NetCrypto.hex(keys.public));
    final route = _IdRoute(keys.id);
    final store = MemoryHangoutStore();
    final now = DateTime(2026, 11, 15, 19, 40).millisecondsSinceEpoch;
    store.keepMessages(channel.chatRoom, [
      HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Starting the movie in 10, hop in', at: now),
      HangoutMessage(id: '2', from: 'a', name: 'Maya Chen', text: 'Bring snacks 🍿', at: now + 20000),
      HangoutMessage(id: '3', from: 'c', name: 'Riley', text: 'On my way!', at: now + 60000),
      HangoutMessage(id: '4', from: keys.id, name: 'Me', text: 'Saving you a seat', at: now + 90000),
    ]);
    store.keepRoster(channel.chatRoom, Roster.first(channel.owner).next(assigned: {'a': Role.moderator}));
    final seeded = store.messages(channel.chatRoom);
    final room = HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store);
    room.present.addAll({'a': const HangoutPerson('a', name: 'Maya Chen', inVoice: true), 'c': const HangoutPerson('c', name: 'Riley', guest: true, inVoice: true)});
    final v = Voice.instance;
    v.own = [channel];
    v.putHangout(room);
    final s = VoiceSession(channel: channel, route: route, media: _NoMedia({'a': 0.45}), name: 'Me')
      ..members['a'] = const VoiceMember('a', name: 'Maya Chen', username: 'maya')
      ..members['b'] = const VoiceMember('b', name: 'Sam', muted: true)
      ..members['c'] = const VoiceMember('c', name: 'Riley', guest: true);
    v.session = s;
    addTearDown(() {
      v.session = null;
      v.own = [];
      v.clearHangouts();
    });
    for (final dark in [false, true]) {
      // In the call: the people, names in their role's colour and no badges; the owner's crown (Matt, 2026-11-17:
      // "Don't show the badges for owner moderator etc, instead assign role colors like discord does and for the owner
      // just show a singlular crown icon").
      await _shoot(tester, sheet, const VoiceScreen(), '21-hangout', dark: dark);
      expect(find.byType(SpaceCallPage), findsOneWidget, reason: 'a space\'s call on a phone is the call\'s own page');
      expect(find.text('Owner'), findsNothing);
      // No crown: the owner shows by their role's colour alone (Matt, 2026-11-18: "Remove the crown icon").
      expect(find.bySemanticsLabel('Owner'), findsNothing);
      // The chat, opened from the call's own button: the run of Maya's two, Riley's, this phone's.
      await tester.tap(find.bySemanticsLabel('Chat'));
      await _settle(tester);
      await _shootAgain(tester, '21-hangout-chat', dark: dark);
      expect(find.text('Bring snacks 🍿'), findsOneWidget);
      // The same composer as every conversation (Matt, 2026-11-15: "Use the same compose input on spaces").
      expect(find.byType(ComposerBox), findsOneWidget);
      // Writing one.
      await tester.enterText(find.byType(EditableText), 'Two minutes');
      await _settle(tester);
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Send'));
      await _settle(tester);
      expect(room.messages.map((m) => m.text), contains('Two minutes'));
      expect(find.text('Two minutes'), findsOneWidget);
      // The chat put away again: the people, and the call's buttons.
      await tester.tap(find.bySemanticsLabel('Close chat'));
      await _settle(tester);
      expect(find.byType(ComposerBox), findsNothing);
      expect(find.bySemanticsLabel('Leave'), findsWidgets);
      // Press and hold Sam: as owner, his role, mute for everyone, remove, ban.
      await tester.longPress(find.textContaining('Sam').first);
      await _settle(tester);
      await _shootAgain(tester, '21-hangout-person', dark: dark);
      expect(find.text('Mute for everyone'), findsOneWidget);
      expect(find.text('Remove from space'), findsOneWidget);
      expect(find.text('Ban'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Mute Sam for everyone'));
      await _settle(tester);
      expect(room.roster.muted, contains('b'));
      expect(room.heard('b'), isFalse);
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);
      // The roles page: who has which, the three roles, the role new people get. (Who is here as the hub would say.)
      room.present.addAll({'a': const HangoutPerson('a', name: 'Maya Chen', inVoice: true), 'b': const HangoutPerson('b', name: 'Sam', inVoice: true), 'c': const HangoutPerson('c', name: 'Riley', guest: true, inVoice: true)});
      await _shoot(tester, sheet, RolesScreen(room: room), '21-hangout-roles', dark: dark);
      expect(find.text('Admin'), findsWidgets);
      expect(find.text('Member'), findsWidgets, reason: 'the role, and the one new people join as');
      expect(find.text('Join as'), findsOneWidget);
      await _shoot(tester, sheet, RoleScreen(room: room, roleId: Role.moderator), '21-hangout-role', dark: dark);
      expect(find.text('Mute others'), findsOneWidget);
      expect(find.text('Ban'), findsOneWidget);
      // Out of the call: the chat with a way into voice at its top.
      v.session = null;
      await _shoot(tester, sheet, HangoutScreen(channel: channel), '21-hangout-out', dark: dark);
      expect(find.text('Join voice'), findsOneWidget);
      expect(find.text('Saving you a seat'), findsOneWidget);
      // The members in a drawer over the chat, Add people at its top, and closed again (Matt, 2026-11-17: "the member
      // list should show up as a drawer like the add user, it should include a button to switch to add user at the
      // top"; it had put them in the chat's place).
      await tester.tap(find.byWidgetPredicate((w) => w is IconTap && w.label == 'Members'));
      await _settle(tester);
      await _shootAgain(tester, '21-hangout-members', dark: dark);
      expect(find.byType(SpaceMembers), findsOneWidget);
      expect(find.byKey(const ValueKey('members-add-people')), findsOneWidget);
      expect(find.text('Maya Chen'), findsWidgets);
      expect(find.text('Saving you a seat'), findsOneWidget, reason: 'the chat stays under the drawer');
      await tester.tap(find.byKey(const ValueKey('members-close')));
      await _settle(tester);
      expect(find.byType(SpaceMembers), findsNothing);
      expect(find.text('Saving you a seat'), findsOneWidget);
      // The space's settings, each section in its colour (Matt, 2026-11-17: "add colors to the spaces settings").
      await _shoot(tester, sheet, RolesScreen(room: room, settings: true), '21-hangout-settings', dark: dark);
      expect(find.text('Owner'), findsWidgets);
      expect(find.byType(GlacierScope), findsWidgets, reason: 'each section in its colour');
      v.session = s;
      room.roster = Roster.first(channel.owner).next(assigned: {'a': Role.moderator});
      room.messages = seeded;
      store.keepMessages(channel.chatRoom, seeded);
      await tester.pumpWidget(const SizedBox());
    }
  });

  // Matt, 2026-11-15: "When opening a hangout the left side should show the chat with some space below reserved for the
  // navbar controls, the voice on desktop should show up on the left side with the right side reserved for chat, when a
  // video starts split the right side 50/50 showing the videos above the chat".
  testWidgets('a hangout\'s layout: room for the pill under its chat; wide, the call over its chat in the pane', (tester) async {
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final keys = NetKeys.generate();
    final channel = VoiceChannel.make('Friday hang', owner: NetCrypto.hex(keys.public));
    final route = _IdRoute(keys.id);
    final store = MemoryHangoutStore();
    final now = DateTime(2026, 11, 15, 19, 40).millisecondsSinceEpoch;
    store.keepMessages(channel.chatRoom, [
      HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Starting the movie in 10, hop in', at: now),
      HangoutMessage(id: '2', from: keys.id, name: 'Me', text: 'Saving you a seat', at: now + 90000),
    ]);
    final room = HangoutRoom(channel: channel, route: route, name: 'Me', signer: KeysSigner(keys), store: store);
    final v = Voice.instance;
    v.own = [channel];
    v.putHangout(room);
    addTearDown(() {
      v.session = null;
      v.own = [];
      v.clearHangouts();
    });
    for (final dark in [false, true]) {
      // A phone: the hangout opened where a conversation opens (over the list, no pill under it), its composer at the
      // foot, who is connected and Join at its top.
      tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
      v.view(channel);
      await _shoot(tester, sheet, const VoiceScreen(), '22-hangout-open', dark: dark);
      expect(find.byType(HangoutScreen), findsOneWidget);
      expect(find.text('Join voice'), findsOneWidget);
      final composer = tester.getRect(find.byType(ComposerBox));
      expect(892 - composer.bottom, lessThan(32 + 40), reason: 'no room kept for a pill that isn\'t there');
      v.view(null);

      // Wide, in the call: the list left as it is, and in the pane the call (its people and its buttons) on top and
      // the chat under it (SpaceSplit; Matt, 2026-11-23).
      tester.view.physicalSize = const Size(1280 * 2.0, 800 * 2.0);
      v.session = VoiceSession(channel: channel, route: route, media: _NoMedia({'a': 0.4}), name: 'Me')
        ..members['a'] = const VoiceMember('a', name: 'Maya Chen', username: 'maya')
        ..members['b'] = const VoiceMember('b', name: 'Sam', muted: true);
      await _shoot(tester, sheet, const AppShell(), '22-hangout-wide', dark: dark);
      final shell = tester.state<AppShellState>(find.byType(AppShell));
      shell.go('voice');
      await _settle(tester);
      await _shootAgain(tester, '22-hangout-wide', dark: dark);
      expect(find.byType(SpaceSplit), findsOneWidget, reason: 'the pane is the call over the chat');
      final call = tester.getRect(find.byType(SpaceCallPage)), chat = tester.getRect(find.byType(HangoutChat));
      expect(call.bottom, lessThanOrEqualTo(chat.top + 1), reason: 'the call on top, the chat under it');
      expect(find.text('Saving you a seat'), findsOneWidget);
      expect(find.bySemanticsLabel('Leave'), findsOneWidget, reason: 'the call\'s buttons once, over the call');
      expect(tester.getRect(find.bySemanticsLabel('Leave')).bottom, lessThanOrEqualTo(chat.top + 1));
      v.session = null;
      // A hangout's menu (Matt, 2026-11-15: "there also needs to be a context menu to open settings for hangouts and
      // manage permissions and such as well as delete the hangouts on desktop"): its settings, link, sharing, delete.
      tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
      await _shoot(tester, sheet, const VoiceScreen(), '22-hangout-menu', dark: dark);
      await tester.tap(find.bySemanticsLabel('Space options'));
      await _settle(tester);
      await _shootAgain(tester, '22-hangout-menu', dark: dark);
      expect(find.text('Settings and permissions'), findsOneWidget);
      expect(find.text('Invite people'), findsOneWidget);
      expect(find.text('Delete space'), findsOneWidget);
      await tester.tap(find.text('Settings and permissions'));
      await _settle(tester);
      await _shootAgain(tester, '22-hangout-settings', dark: dark);
      expect(find.byType(RolesScreen), findsOneWidget);
      expect(find.text('Invite people'), findsOneWidget);
      // Further down: the role new people get, and deleting it.
      await tester.scrollUntilVisible(find.text('Delete space'), 300, scrollable: find.byType(Scrollable).last);
      expect(find.text('Join as'), findsOneWidget);
      expect(find.text('Delete space'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  // Matt, 2026-11-15: "use an icon only segmented toggle for the messages codes and add voice chats to the list as well,
  // try a few different layouts for switching between the few including a mixed view that shows them all intertwined
  // sorted by recency, also id like you to rework the active call indicator".
  testWidgets('the list\'s three tabs with circles, and the call as a banner above the dock', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final hangout = VoiceChannel.make('Friday hang'), study = VoiceChannel.make('Study room');
    final v = Voice.instance;
    v.own = [hangout, study];
    v.session = VoiceSession(channel: hangout, route: _NoRoute(), media: _NoMedia({'a': 0.4, 'me': 0.3}), name: 'Me')
      ..members['a'] = const VoiceMember('a', name: 'Maya Chen')
      ..members['b'] = const VoiceMember('b', name: 'Sam', muted: true)
      ..since = DateTime.now().subtract(const Duration(minutes: 12, seconds: 5));
    addTearDown(() {
      v.session = null;
      v.own = [];
    });
    for (final dark in [false, true]) {
      // Tabs: icons alone, voice among them.
      await _shoot(tester, sheet, const AppShell(), '20-layout-tabs', dark: dark);
      expect(find.byType(SectionTabs), findsOneWidget);
      // Circles where Spaces was (Matt, 2026-11-17: "Let's do a circle for now ... with it's own sidebar full of spaces").
      final circlesTab = find.descendant(of: find.byType(SectionTabs), matching: find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.circleDot));
      expect(circlesTab, findsOneWidget);
      // The call: a banner just above the dock, the people talking rippling in it (Matt, 2026-11-15: "switch the
      // active call to be a banner again in the sidebar just above the navigation bar").
      expect(find.byType(CallBanner), findsOneWidget);
      expect(find.text('Friday hang'), findsWidgets);
      expect(find.descendant(of: find.byType(CallBanner), matching: find.byType(RippleAvatar)), findsNWidgets(2));
      final banner = tester.getRect(find.byType(CallBanner)), pill = tester.getRect(find.byType(NavPill));
      if (pill.height > pill.width) {
        // A dock stood up at the right: the banner keeps clear of it, at the same foot.
        expect(banner.right, lessThanOrEqualTo(pill.left), reason: 'beside the dock, not over it');
      } else {
        expect(banner.bottom, lessThanOrEqualTo(pill.top), reason: 'above the dock, not over it');
        expect(pill.top - banner.bottom, lessThan(40), reason: 'just above it');
      }
      // No Voice ring: calls are the Voice tab.
      expect(find.byKey(const ValueKey('nav-voice')), findsNothing);
      await tester.tap(circlesTab);
      await _settle(tester);
      await _shootAgain(tester, '20-layout-tabs-circles', dark: dark);
      // No circles here: the Circles tab lists circles alone (spaces of one's own are in Messages), and says so.
      expect(find.text('No circles yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });

  // Matt, 2026-11-17: "I'd also like spaces to show up in the main chats list with a preview of the last message sent in
  // the space and the ability to open it as a normal chat window when there are no people online and chatting and then
  // have the join call button still".
  testWidgets('spaces in Messages: the newest message, unread, who is in voice; opened as a chat, or on its call', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final keys = NetKeys.generate();
    final channel = VoiceChannel.make('Book club', owner: NetCrypto.hex(keys.public));
    final store = MemoryHangoutStore();
    final now = DateTime.now().millisecondsSinceEpoch;
    store.keepMessages(channel.chatRoom, [
      HangoutMessage(id: '1', from: 'a', name: 'Maya Chen', text: 'Chapter 4 tonight?', at: now - 60000),
      HangoutMessage(id: '2', from: 'c', name: 'Riley', text: 'Yes! Bring your notes', at: now - 30000),
    ]);
    final room = HangoutRoom(channel: channel, route: _IdRoute(keys.id), name: 'Me', signer: KeysSigner(keys), store: store);
    room.present.addAll({'a': const HangoutPerson('a', name: 'Maya Chen', inVoice: true), 'c': const HangoutPerson('c', name: 'Riley', inVoice: true)});
    final v = Voice.instance;
    v.own = [channel];
    v.putHangout(room);
    v.clearRead();
    addTearDown(() {
      v.putLook(channel.room, const []);
      v.own = [];
      v.clearHangouts();
      v.clearRead();
    });
    for (final dark in [false, true]) {
      v.putLook(channel.room, const []);
      v.clearRead();
      await _shoot(tester, sheet, const AppShell(), '20-space-in-messages', dark: dark);
      // In Messages as a conversation is: its name, who said its newest message and what, and unread.
      final row = find.byKey(ValueKey('space-row-${channel.room}'));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Book club')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Riley: Yes! Bring your notes')), findsOneWidget);
      expect(tester.widget<ConversationRow>(row).conversation.unread, isTrue);
      expect(v.unreadIn(channel), 2);
      // Nobody in voice: it opens as a chat, Join voice at its top; reading it puts the unread mark away.
      await tester.tap(row);
      await _settle(tester);
      expect(find.byType(HangoutChat), findsOneWidget);
      expect(find.text('Join voice'), findsOneWidget);
      expect(find.text('Chapter 4 tonight?'), findsOneWidget);
      expect(v.unreadIn(channel), 0);
      await tester.pumpWidget(const SizedBox());

      // Two people talking in it: the row says so in green, and it opens on its call with a way to the chat.
      v.putLook(channel.room, const ['a', 'c']);
      await _shoot(tester, sheet, const AppShell(), '20-space-in-messages-live', dark: dark);
      expect(tester.widget<ConversationRow>(find.byKey(ValueKey('space-row-${channel.room}'))).live, 2);
      expect(find.descendant(of: find.byKey(ValueKey('space-row-${channel.room}')), matching: find.byWidgetPredicate((w) => w is AppIcon && w.icon == LucideMore.headphones)), findsNWidgets(2), reason: 'the badge and the live mark');
      await tester.tap(find.byKey(ValueKey('space-row-${channel.room}')));
      await _settle(tester);
      // What each said of themselves on coming into the room (its "hi").
      room.present.addAll({'a': const HangoutPerson('a', name: 'Maya Chen', inVoice: true), 'c': const HangoutPerson('c', name: 'Riley', inVoice: true)});
      v.putLook(channel.room, const ['a', 'c']);
      await _settle(tester);
      await _shootAgain(tester, '20-space-live-call', dark: dark);
      expect(find.text('2 in voice'), findsOneWidget);
      expect(find.text('Maya Chen'), findsOneWidget, reason: 'by the names they gave the room');
      expect(find.text('Join voice'), findsNothing, reason: 'the people themselves are pressed to join');
      expect(find.bySemanticsLabel('Join the call with 2 in it'), findsOneWidget);
      expect(find.byType(HangoutChat), findsNothing);
      await tester.tap(find.bySemanticsLabel('Chat'));
      await _settle(tester);
      expect(find.byType(HangoutChat), findsOneWidget);
      expect(find.text('Join voice'), findsOneWidget, reason: 'the chat keeps its way into the call');
      await tester.pumpWidget(const SizedBox());
    }

    // Beside the list (an open Fold, a computer), the space is drawn as open only while the pane shows it: another
    // conversation opened after it takes that from it (Matt, 2026-11-17: "the only ghosts chat is always highlighted
    // even when it's not active in the front").
    v.putLook(channel.room, const []);
    tester.view.physicalSize = const Size(750 * 2.0, 832 * 2.0);
    await _shoot(tester, sheet, const AppShell(), '20-space-in-messages-wide', dark: false);
    bool chosen() => tester.widget<ConversationRow>(find.byKey(ValueKey('space-row-${channel.room}'))).selected;
    expect(chosen(), isFalse);
    await tester.tap(find.byKey(ValueKey('space-row-${channel.room}')));
    await _settle(tester);
    expect(chosen(), isTrue, reason: 'open in the pane');
    await tester.tap(find.text('Maya Chen').first);
    await _settle(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(chosen(), isFalse, reason: 'another conversation is in the pane now');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
    v.view(null);
  });

  // Matt, 2026-11-17: "each group should come with a space": a group's call, while others are in it, floats over its
  // conversation with Join.
  testWidgets('a group\'s call floats over its conversation while others are in it', (tester) async {
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    final channel = VoiceChannel.ofGroup('0123456789abcdef0123456789abcdef', 'Climbing');
    var joined = 0;
    final v = Voice.instance;
    addTearDown(() => v.putLook(channel.room, const []));
    final bar = SpaceLiveBar(channel: channel, onJoin: () => joined++);
    await _shoot(tester, sheet, Center(child: bar), '20-group-live-bar-empty', dark: false);
    expect(find.text('Join'), findsNothing, reason: 'nothing while nobody is in it');
    await tester.pumpWidget(const SizedBox());
    v.putLook(channel.room, const ['a', 'b', 'c']);
    await _shoot(tester, sheet, Center(child: bar), '20-group-live-bar', dark: false);
    expect(find.text('3 in voice'), findsOneWidget);
    await tester.tap(find.text('Join'));
    expect(joined, 1);
    await tester.pumpWidget(const SizedBox());
  });

  // Matt, 2026-11-15: "Make the dock slightly larger when scrolled to the top of the page and make it get smaller when
  // we scroll down just like ghost markdown does match the sizes".
  testWidgets('the pill: whole at the list\'s top, four fifths once scrolled down, whole again back at the top', (tester) async {
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    await _shoot(tester, sheet, const AppShell(), '1-conversations', dark: false);
    // Laid along the foot it is a Transform kept the list's width (shell.dart), stood up a ScaleTransition.
    double scale() {
      final w = tester.widget(find.byKey(const ValueKey('pill-scale')));
      if (w is ScaleTransition) return w.scale.value;
      return tester.widget<Transform>(find.descendant(of: find.byKey(const ValueKey('pill-scale')), matching: find.byType(Transform)).first).transform.storage[0];
    }
    expect(scale(), 1.0);
    final ringWhole = tester.getSize(find.byKey(const ValueKey('nav-messages')));
    // The person scrolls down: the pill grows smaller, and stays so while the list is still.
    await tester.drag(find.byType(ConversationRow).first, const Offset(0, -300));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(scale(), closeTo(pillScrolledScale, 0.001));
    expect(tester.getRect(find.byKey(const ValueKey('nav-messages'))).width, closeTo(ringWhole.width * pillScrolledScale, 0.5));
    // Back at the top: whole again.
    await tester.drag(find.byType(ConversationRow).first, const Offset(0, 600));
    await _settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(scale(), 1.0);
  });

  // The Cleaner (lib/plugins/cleaner.dart; Matt, 2026-11-14: "add a "Cleaner" plugin that allows us to bulk delete
  // messages by category and shows deletion progress in real time"): kinds ticked, and part way through.
  testWidgets('the Cleaner: choosing, and deleting', (tester) async {
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    const groups = [
      ListGroup(id: 'codes', label: 'Codes', icon: Lucide.keyRound, threads: [1, 2, 3, 4]),
      ListGroup(id: 'spam', label: 'Spam', icon: Lucide.triangleAlert, threads: [5, 6, 7, 8, 9, 10, 11]),
      ListGroup(id: 'sales', label: 'Sales & solicitors', icon: Lucide.megaphone, threads: [12, 13, 14]),
      ListGroup(id: ListGroup.othersId, label: 'Personal & other', icon: Lucide.messageSquare, threads: [15, 16]),
    ];
    for (final dark in [false, true]) {
      final hold = Completer<void>();
      await _shoot(tester, sheet, CleanerSheet(groups: groups, delete: (t) => t < 7 ? Future.value() : hold.future, reload: () async {}), '18-cleaner', dark: dark);
      await tester.tap(find.text('Spam'));
      await tester.tap(find.text('Sales & solicitors'));
      await _settle(tester);
      await _shootAgain(tester, '18-cleaner', dark: dark);
      await tester.tap(find.text('Delete 10 conversations'));
      await _settle(tester);
      await tester.tap(find.text('Delete'));
      await _settle(tester);
      await _shootAgain(tester, '18-cleaner-deleting', dark: dark);
      expect(find.text('Deleting 3 of 10'), findsOneWidget);
      hold.complete();
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('an unread conversation summed up in its row', (tester) async {
    // Matt, 2026-11-14: "Use a local AI to summarize unread message conversations like apple does".
    tester.view.physicalSize = const Size(412 * 2.0, 892 * 2.0);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    await tester.runAsync(() => Summaries.instance.start(AppState()));
    // Maya's newest are hers, unread: the text the person had waiting for the phone is set aside for this picture.
    _summaryPicture = true;
    addTearDown(() => _summaryPicture = false);
    for (final dark in [false, true]) {
      await _shoot(tester, sheet, const ConversationsScreen(), '17-summary', dark: dark);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _shootAgain(tester, '17-summary', dark: dark);
      expect(find.textContaining('Maya confirms 7pm'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is AppIcon && w.icon == Lucide.sparkles), findsOneWidget, reason: 'marked as a summary');
      // In Settings › Messages: the switch, and that it is made on this phone.
      await _shoot(tester, sheet, const SettingsSectionScreen('messages'), '17-summary-settings', dark: dark);
      expect(find.text('Summarize unread conversations'), findsOneWidget);
      expect(find.textContaining('nothing is sent anywhere'), findsOneWidget);
    }
  });

  testWidgets('the frame, wide and narrow', (tester) async {
    // A folding phone opened out, then its cover.
    const open = Size(750 * 2.0, 832 * 2.0);
    const cover = Size(412 * 2.0, 892 * 2.0);
    tester.view.physicalSize = open;
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
    addTearDown(tester.view.reset);
    _answerChannel();
    final sheet = (await tester.runAsync(() => loadTokenSheet(more: const ['assets/css/ink.css', 'assets/css/app.css'])))!;
    installSettingsStyles(sheet);
    Finder seen(Finder f) => f.hitTestable();
    Finder icon(String label) => find.byWidgetPredicate((w) => w is IconTap && w.label == label);
    // One ring of the pill at the list's foot (lib/ui/nav_bar.dart).
    Finder ring(String id) => find.byKey(ValueKey('nav-$id'));
    String shown() => tester.widget<NavPill>(find.byType(NavPill)).active;
    for (final dark in [false, true]) {
      tester.view.physicalSize = open;
      await _shoot(tester, sheet, const AppShell(), '11-frame-wide', dark: dark);
      final side = AppShell.sideWidth(750);
      // Wide: the list down the side, the pane saying to choose, and the pill (a new chat, the messages, the
      // contacts, the archive with its number, Settings) floating along the list's foot, as on the Mac (Matt,
      // 2026-11-14: "there is a reserved spot for the navbar instead of the nav floating over the left sidebar"). It
      // had stood up in a strip of its own at the window's right.
      expect(find.text('Choose a conversation'), findsOneWidget);
      expect(find.text('Or start a new chat from the bar under the list.'), findsOneWidget);
      final pill = tester.getRect(find.byType(NavPill));
      expect(tester.widget<NavPill>(find.byType(NavPill)).upright, isFalse);
      expect(pill.right, lessThanOrEqualTo(side));
      expect(pill.bottom, lessThanOrEqualTo(832 - 16), reason: 'clear of the bar at the foot of the screen');
      expect(tester.getCenter(ring('new')).dy, tester.getCenter(ring('settings')).dy);
      expect(find.byKey(const ValueKey('shell-rail')), findsNothing);
      // The pane runs to the window's edge: nothing is kept for the pill there.
      expect(tester.getRect(find.byKey(const ValueKey('shell-pane'))).right, 750);
      expect(tester.getRect(find.byKey(const ValueKey('shell-side'))).right, side);
      // The sidebar is at least wide enough for the toggle and the filter ("the sidebar needs to be at least wide
      // enough to show the segmented toggles and the filter").
      expect(side, greaterThanOrEqualTo(320));
      // The line between them is dragged to make the list wider, kept, and put back with a double tap (Matt,
      // 2026-11-17: "add a handle to resize the sidebar and the main chat page ... like claude has").
      if (!dark) {
        final split = find.byKey(const ValueKey('shell-split'));
        expect(split, findsOneWidget);
        await tester.drag(split, const Offset(60, 0));
        await tester.pump();
        expect(tester.getRect(find.byKey(const ValueKey('shell-side'))).right, closeTo(side + 60, 1));
        expect(PaneWidth.of(tester.widget<AppScope>(find.byType(AppScope)).state, 'list'), closeTo(side + 60, 1));
        // No wider than leaves the pane 360.
        await tester.drag(split, const Offset(400, 0));
        await tester.pump();
        expect(tester.getRect(find.byKey(const ValueKey('shell-side'))).right, closeTo(750 - 360, 1));
        await tester.tap(split);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(split);
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.getRect(find.byKey(const ValueKey('shell-side'))).right, side);
        expect(PaneWidth.of(tester.widget<AppScope>(find.byType(AppScope)).state, 'list'), isNull);
      }
      for (final id in ['new', 'messages', 'contacts', 'archive', 'settings']) {
        expect(ring(id), findsOneWidget, reason: 'the pill has $id');
      }
      expect(shown(), 'messages');
      // The keyboard's commands go where they say, from anywhere in the frame (lib/keys.dart; Matt, 2026-11-20: "add
      // push to talk and full keyboard commands with a keyboard shortcuts setting in settings").
      if (!dark) {
        final primary = Platform.isMacOS ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
        Future<void> keys(LogicalKeyboardKey key) async {
          await tester.sendKeyDownEvent(primary);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(primary);
          await _settle(tester);
        }

        await keys(LogicalKeyboardKey.digit2);
        expect(shown(), 'contacts');
        await keys(LogicalKeyboardKey.digit3);
        expect(shown(), 'archive');
        await keys(LogicalKeyboardKey.digit1);
        expect(shown(), 'messages');
        await keys(LogicalKeyboardKey.slash);
        expect(find.text('Push to talk'), findsWidgets, reason: 'the shortcuts page itself');
        await keys(LogicalKeyboardKey.digit1);
        expect(shown(), 'messages');
      }
      // The one archived conversation is read, so the Archive ring has no number (GMFB-14: it counts the unread).
      expect(tester.widget<NavPill>(find.byType(NavPill)).items.firstWhere((i) => i.id == 'archive').count, 0);
      expect(icon('New'), findsNothing, reason: 'the header holds nothing the pill does');
      expect(tester.getTopRight(find.byType(ConversationsScreen)).dx, side);
      // A conversation opens beside the list, which stays, with no way back drawn: there is nowhere to go back to.
      await tester.tap(find.text('Maya Chen'));
      await _settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _shootAgain(tester, '11-frame-wide-thread', dark: dark);
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(tester.getTopLeft(find.byType(ThreadScreen)).dx, side + 1);
      expect(seen(find.text('Dad')), findsOneWidget);
      expect(icon('Back'), findsNothing);
      expect(find.text('Choose a conversation'), findsNothing);
      // A message held: what it brings up is beside its bubble, in the pane, not the list's width further over.
      final held = find.text('Movie night is still on for tonight right?');
      await tester.longPress(held);
      await _shootAgain(tester, '11-frame-wide-held', dark: dark);
      final copy = find.text('Copy text');
      expect(copy, findsOneWidget);
      final words = tester.getRect(held.first);
      expect(tester.getTopLeft(copy).dx, inInclusiveRange(words.left, words.right), reason: 'the menu is under the bubble it is for');
      await tester.tapAt(Offset(side + 20, 400));
      await _settle(tester);
      // Something half written in it.
      await tester.enterText(find.byType(EditableText).last, 'On my way');
      await _settle(tester);
      // The phone is folded: the conversation is still open, with what was written, and now covers the list and
      // has its way back.
      tester.view.physicalSize = cover;
      await _settle(tester);
      await _shootAgain(tester, '11-frame-narrow-thread', dark: dark);
      expect(find.text('On my way'), findsOneWidget);
      expect(tester.getTopLeft(find.byType(ThreadScreen)).dx, 0);
      expect(seen(find.text('Dad')), findsNothing);
      expect(icon('Back'), findsWidgets);
      // And opened out again: beside the list once more, still with what was written.
      tester.view.physicalSize = open;
      await _settle(tester);
      expect(find.text('On my way'), findsOneWidget);
      expect(seen(find.text('Dad')), findsOneWidget);
      expect(icon('Back'), findsNothing);
      tester.view.physicalSize = cover;
      await _settle(tester);
      // Its way back closes it: the list alone.
      await tester.tap(icon('Back').first);
      await _settle(tester);
      await _shootAgain(tester, '11-frame-narrow', dark: dark);
      expect(find.byType(ThreadScreen), findsNothing);
      expect(seen(find.text('Dad')), findsOneWidget);
      expect(find.text('Choose a conversation'), findsNothing);
      // Folded, the pill stands up too, floating in the list's bottom right corner as Ghost.md's dock does (Matt,
      // 2026-11-14: "Folded: make it vertical"), with no strip: the list keeps the screen's whole width.
      expect(tester.widget<NavPill>(find.byType(NavPill)).upright, isTrue);
      expect(tester.getCenter(ring('new')).dx, tester.getCenter(ring('settings')).dx);
      expect(tester.getCenter(ring('new')).dy, lessThan(tester.getCenter(ring('settings')).dy));
      expect(tester.getRect(find.byType(NavPill)).right, 412);
      expect(tester.getRect(find.byType(NavPill)).bottom, 892 - 16);
      expect(tester.getRect(find.byKey(const ValueKey('shell-pane'))).right, 412);
      expect(find.byKey(const ValueKey('shell-rail')), findsNothing);
      expect(tester.getRect(find.byType(ConversationsScreen)).width, 412);
      // Matt's Galaxy Z Fold 8 opened out (2448 by 1848 at 420 dpi: 932 by 704), its bars as One UI has them: the
      // pill floats over the list there too.
      tester.view.physicalSize = const Size(932 * 2.0, 704 * 2.0);
      tester.view.padding = const FakeViewPadding(top: 40 * 2.0, bottom: 48 * 2.0);
      await _settle(tester);
      expect(tester.widget<NavPill>(find.byType(NavPill)).upright, isFalse, reason: 'the Fold 8 opened out');
      expect(tester.getRect(find.byType(NavPill)).right, lessThanOrEqualTo(AppShell.sideWidth(932)));
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 32);
      // A small phone on its side is wide, and too short for five rings head to foot: the pill stays under the list.
      tester.view.physicalSize = const Size(800 * 2.0, 320 * 2.0);
      await _settle(tester);
      expect(find.text('Choose a conversation'), findsOneWidget);
      expect(tester.widget<NavPill>(find.byType(NavPill)).upright, isFalse);
      expect(find.byKey(const ValueKey('shell-rail')), findsNothing);
      tester.view.physicalSize = cover;
      await _settle(tester);
      // A new chat, from the pill (which asks: a chat, a group or a voice call), slides over the list; Android's back
      // closes it.
      await tester.tap(ring('new'));
      await _settle(tester);
      expect(find.text('New space'), findsOneWidget);
      await tester.tap(find.text('New chat').hitTestable().last);
      await _settle(tester);
      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(seen(find.text('Dad')), findsNothing);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.byType(ComposeScreen), findsNothing);
      expect(seen(find.text('Dad')), findsOneWidget);
      // The pill's Archive opens the archive in the list's place; a conversation from it opens over it; back
      // closes the conversation first, then leaves the archive.
      expect(find.textContaining('Archived ('), findsNothing, reason: 'the way to the archive is the pill');
      await tester.tap(ring('archive'));
      await _settle(tester);
      await _shootAgain(tester, '11-frame-narrow-archive', dark: dark);
      expect(shown(), 'archive');
      expect(seen(find.text('Old Thread')), findsOneWidget);
      await tester.tap(find.text('Old Thread'));
      await _settle(tester);
      expect(find.byType(ThreadScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(find.byType(ThreadScreen), findsNothing);
      expect(seen(find.text('Old Thread')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await _settle(tester);
      expect(seen(find.text('Old Thread')), findsNothing);
      expect(seen(find.text('Dad')), findsOneWidget);
      expect(shown(), 'messages');
      // The archive again, and the pill's Messages leaves it.
      await tester.tap(ring('archive'));
      await _settle(tester);
      expect(seen(find.text('Old Thread')), findsOneWidget);
      await tester.tap(ring('messages'));
      await _settle(tester);
      expect(seen(find.text('Old Thread')), findsNothing);
      expect(shown(), 'messages');
      // Wide again: the contacts open beside the list, and someone in them opens their conversation there.
      tester.view.physicalSize = open;
      await _settle(tester);
      await tester.tap(ring('contacts'));
      await _settle(tester);
      await _shootAgain(tester, '11-frame-wide-contacts', dark: dark);
      expect(find.byType(ContactsScreen), findsOneWidget);
      expect(shown(), 'contacts');
      expect(seen(find.text('Dad')), findsOneWidget);
      // Settings takes the list's place: its sections where the conversations were, and the first one's page
      // beside them. Two panes, not three (Matt, 2026-11-14: "when the settings is open on desktop replace the
      // normal sidebar so it's only a two pane layout not a three pane").
      Finder row(String label) => find.descendant(of: find.byType(SettingsList), matching: find.text(label));
      await tester.tap(ring('settings'));
      await _settle(tester);
      await _shootAgain(tester, '11-frame-wide-settings', dark: dark);
      expect(find.byType(ContactsScreen), findsNothing);
      expect(shown(), 'settings');
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(tester.getRect(find.byType(SettingsScreen)).right, closeTo(side, 1), reason: 'Settings\' list is the list\'s column');
      expect(seen(find.text('Dad')), findsNothing, reason: 'the conversations have given way to Settings\' sections');
      // The first section is Me since plugins left Settings for the Marketplace (Matt, 2026-11-20: "Move plugins out of
      // settings into a marketplace button on the navigation rail"): its page open beside them, and no Plugins page.
      expect(find.byType(PluginsPage), findsNothing, reason: 'the Marketplace has the plugins');
      expect(tester.state<AppShellState>(find.byType(AppShell)).settingsSection.value, 'me');
      // Beside its page too, Settings has a back arrow by its big title (Matt, 2026-11-18: "add a back arrow to the settings
      // page"), which takes it away (AppShellState.closeSettings).
      expect(seen(icon('Back')), findsOneWidget);
      expect(seen(ring('settings')), findsOneWidget, reason: 'the way round is still at the list\'s foot');
      // A press on a section puts its page in the pane, in place of the last.
      await tester.tap(row('Appearance'));
      await _settle(tester);
      await _shootAgain(tester, '11-frame-wide-settings-appearance', dark: dark);
      // Its first section is the looks (lib/ui/look_picker.dart), which pushed Text size below the window's foot.
      expect(seen(find.text('Runestone')), findsOneWidget);
      expect(find.byType(SectionPage), findsOneWidget);
      expect(tester.state<AppShellState>(find.byType(AppShell)).settingsSection.value, 'appearance');
      // Only Settings' own back arrow, none on the section's page beside it.
      expect(seen(icon('Back')), findsOneWidget);
      // Folded shut with a section open: its page is over Settings' list, with its way back; back from it is the
      // list of sections, as a phone has it (its own way back, no bar under it); back again, the conversations.
      tester.view.physicalSize = cover;
      await _settle(tester);
      await _shootAgain(tester, '11-frame-narrow-settings-section', dark: dark);
      expect(seen(find.text('Runestone')), findsOneWidget);
      expect(seen(icon('Back')), findsOneWidget);
      await tester.tap(seen(icon('Back')));
      await _settle(tester);
      await _shootAgain(tester, '11-frame-narrow-settings', dark: dark);
      expect(seen(row('Appearance')), findsOneWidget);
      expect(seen(find.text('Runestone')), findsNothing);
      expect(seen(ring('settings')), findsNothing, reason: 'on a phone Settings is a page with its own way back');
      await tester.tap(seen(icon('Back')));
      await _settle(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(seen(find.text('Dad')), findsOneWidget);
      expect(seen(ring('settings')), findsOneWidget);
      expect(shown(), 'messages');
      // On the cover Settings opens as its list, and a section over it; opened out, the two are side by side.
      await tester.tap(ring('settings'));
      await _settle(tester);
      expect(find.byType(SectionPage), findsNothing);
      await tester.tap(row('Appearance'));
      await _settle(tester);
      expect(seen(find.text('Runestone')), findsOneWidget);
      tester.view.physicalSize = open;
      await _settle(tester);
      expect(seen(find.text('Runestone')), findsOneWidget);
      expect(seen(row('Appearance')), findsOneWidget);
      // The Messages ring puts Settings away, list and page both.
      await tester.tap(ring('messages'));
      await _settle(tester);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(SectionPage), findsNothing);
      expect(shown(), 'messages');
      // The Settings and Archive rings have menus of their own, as the list's tabs have (Matt, 2026-11-14: "add a
      // right click context menu to archive as well and settings to quick jump to settings sections"): a press with
      // the other button, or a long press. Settings' is its sections by name, and a press on one opens Settings
      // there. It is a small list hung over the ring it came from (Matt, of the sheet it first was: "too large and
      // way too wide"): in the list's column, a few rems across, its sections in named groups, scrolling inside
      // itself where there are more than it has room for.
      final frame = tester.state<AppShellState>(find.byType(AppShell));
      Finder inMenu(String label) => find.descendant(of: find.byType(GlacierMenuItem), matching: find.text(label));
      Future<void> choose(String label) async {
        await tester.ensureVisible(inMenu(label));
        await _settle(tester);
        await tester.tap(inMenu(label));
        await _settle(tester);
      }

      await tester.tap(ring('settings'), buttons: kSecondaryButton);
      await _settle(tester);
      await _shootAgain(tester, '11-frame-wide-settings-menu', dark: dark);
      expect(find.byType(SettingsScreen), findsNothing, reason: 'the menu is over the conversations: Settings is not open yet');
      for (final label in ['Me', 'Appearance', 'Emoji', 'Messages', 'Notifications', 'Encryption', 'Blocked', 'Android', 'About']) {
        expect(inMenu(label), findsOneWidget, reason: '$label is a section to jump to');
      }
      // Plugins are the Marketplace ring's since 2026-11-20, not a section of Settings' menu.
      expect(inMenu('Plugins'), findsNothing);
      expect(inMenu('Marketplace'), findsNothing);
      // Its groups are named, in the kit's small capitals.
      for (final group in ['YOU', 'LOOK', 'CONVERSATIONS', 'PRIVACY', 'THIS PHONE', 'APP']) {
        expect(find.descendant(of: find.byType(GlacierMenuLabel), matching: find.text(group)), findsOneWidget, reason: group);
      }
      // Small, and by its ring: no wider than fifteen rems, hung over the pill as on a computer, in the list's
      // column. It stands clear of the pill, a gap between the two: nothing of it lies on the bar or under it (Matt,
      // 2026-11-14: "the context menu is rendering behind the navbar", of a menu whose edge lay on the pill's).
      final first = tester.getRect(find.byType(GlacierMenuItem).first);
      final pillTop = tester.getRect(find.descendant(of: find.byType(NavPill), matching: find.byType(ClipRRect)).first).top;
      expect(first.width, lessThan(250));
      expect(first.right, lessThanOrEqualTo(AppShell.sideWidth(750)));
      expect(first.bottom, lessThanOrEqualTo(pillTop - 4), reason: 'the menu is over the pill, not on it');
      await choose('Blocked');
      expect(shown(), 'settings');
      expect(frame.settingsSection.value, 'blocked');
      expect(seen(row('Blocked')), findsOneWidget);
      expect(find.byType(SectionPage), findsOneWidget);
      expect(find.byType(GlacierMenuItem), findsNothing, reason: 'choosing closes the menu');
      // Asked for again with Settings open, another section takes the pane.
      await tester.longPress(ring('settings'));
      await _settle(tester);
      await choose('Effects');
      expect(frame.settingsSection.value, 'effects');
      await tester.tap(ring('messages'));
      await _settle(tester);
      // Archive's is the tabs' own two choices, for the conversations put away. Nothing there is unread, and
      // Mark all as read says so, leaving the archive closed.
      await tester.tap(ring('archive'), buttons: kSecondaryButton);
      await _settle(tester);
      await _shootAgain(tester, '11-frame-wide-archive-menu', dark: dark);
      expect(find.descendant(of: find.byType(GlacierMenuLabel), matching: find.byType(Text)), findsOneWidget);
      expect(tester.widget<Text>(find.descendant(of: find.byType(GlacierMenuLabel), matching: find.byType(Text))).data!.toLowerCase(), 'archive · 1 conversation');
      await choose('Mark all as read');
      expect(find.text('Nothing is unread in the archive'), findsOneWidget);
      expect(shown(), 'messages');
      // Select all opens the archive with every conversation in it chosen, for the bar at the top.
      await tester.tap(ring('archive'), buttons: kSecondaryButton);
      await _settle(tester);
      await choose('Select all');
      await _shootAgain(tester, '11-frame-wide-archive-selected', dark: dark);
      expect(shown(), 'archive');
      expect(seen(find.text('1 selected')), findsOneWidget);
      expect(seen(find.text('Old Thread')), findsOneWidget);
      // A ring without a menu has none: the other button on Contacts brings nothing up.
      await tester.tap(ring('contacts'), buttons: kSecondaryButton);
      await _settle(tester);
      expect(find.byType(GlacierMenuItem), findsNothing);
      await tester.tap(ring('messages'));
      await _settle(tester);
      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      // Choosing a conversation opens it beside the list.
      await tester.tap(find.text('Dad'));
      await _settle(tester);
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(shown(), 'messages');
      // Settings › Network's invitation opens a new chat beside the list; choosing who opens the conversation with
      // the invitation written in its message field, to send as any text.
      tester.state<AppShellState>(find.byType(AppShell)).settings('network');
      await _settle(tester);
      await tester.tap(find.text('Invite someone by text'));
      await _settle(tester);
      expect(find.byType(ComposeScreen), findsOneWidget);
      expect(shown(), 'new');
      expect(find.byType(SettingsScreen), findsNothing, reason: 'a new chat is kept with the conversations, not with Settings');
      await tester.enterText(find.byType(EditableText).last, 'Mom');
      await _settle(tester);
      await tester.tap(find.text('Mom').last);
      await _settle(tester);
      await tester.tap(find.text('Next'));
      await _settle(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await _settle(tester);
      await _shootAgain(tester, '11-frame-wide-invite', dark: dark);
      expect(find.byType(ThreadScreen), findsOneWidget);
      expect(find.textContaining('Join me on Uplink'), findsOneWidget);
      // A newer version waiting: beside a pane the card is in the list's column, above its title and search, with
      // the app's name left out so its words and its button fit; on a narrow screen it runs the screen's width and
      // says the name.
      tester.view.physicalSize = open;
      _updateWaiting = true;
      await _shoot(tester, sheet, const AppShell(), '11-frame-wide-banner', dark: dark);
      final button = tester.getRect(find.text('Update now'));
      expect(button.right, lessThan(side), reason: 'the banner is in the list\'s column, not across the window');
      expect(tester.getRect(find.textContaining('is out')).left, greaterThan(0));
      expect(find.text('0.6.2 is out'), findsOneWidget);
      expect(tester.getRect(find.text('0.6.2 is out')).bottom, lessThan(tester.getRect(find.byType(GlacierSearchField).first).top));
      tester.view.physicalSize = cover;
      await _settle(tester);
      expect(find.text('Uplink 0.6.2 is out'), findsOneWidget);
      expect(tester.getRect(find.text('Update now')).right, greaterThan(300));
      _updateWaiting = false;
      // The next round starts with a frame of its own.
      await tester.pumpWidget(const SizedBox());
    }
  });
}

/// A route that carries nothing anywhere: for the picture of Settings › Network.
class _Route implements Carrier {
  _Route(this.id, this.name, this.about, {bool up = true, bool metered = false})
      : state = ValueNotifier(up ? CarrierState.up : CarrierState.down),
        traits = CarrierTraits(maxPacket: 4096, metered: metered, live: false);
  @override
  final String id;
  @override
  final String name;
  @override
  final String about;
  @override
  final CarrierTraits traits;
  @override
  final ValueNotifier<CarrierState> state;
  @override
  String? problem;
  int carried = 0;
  @override
  Stream<Arrived> get arrived => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  bool reaches(Peer peer) => state.value == CarrierState.up;
  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    carried++;
    return Handed.passed;
  }
}

/// The routes and the phone under Friends for the friends' pictures: what Friends tells the phone about Maya is
/// what the phone's answers (`_e2e`) then say.
class _FriendsPort extends FakePort {
  _FriendsPort(super.me);

  @override
  Future<void> setFriend(String address, String state) async => _mayaFriend = state;

  @override
  Future<void> offerKeys(String address) async => keysSent.add(address);

  @override
  Future<List<E2eState>> states() async => [E2eState.from(_e2e('+15551230001'))];
}

/// The routes and the phone under Groups for the groups' pictures: the lines about a group go into conversation 2.
class _GroupsPort extends FakeGroupsPort {
  _GroupsPort(super.world, super.number);

  @override
  Future<void> note(String id, String words) async => _groupNotes.add(words);
}

/// The routes and the phone under Friends for the groups' pictures: three people, each a friend.
class _ThreeFriends extends FakePort {
  _ThreeFriends(super.me, this.people);
  final List<Person> people;

  @override
  Future<List<E2eState>> states() async => [for (final p in people) E2eState(address: p.address, state: 'on', friend: 'yes', hasGhost: true, person: p)];
}

/// A route that goes nowhere, for an install whose id is [me] (a hangout's owner, in a picture).
class _IdRoute extends _NoRoute {
  _IdRoute(this._me);
  final String _me;
  @override
  String get me => _me;
}

class _NoRoute implements VoiceRoute {
  @override
  String get me => 'me';
  @override
  Future<List<String>> join(String room, String token) async => const [];
  @override
  void leave(String room) {}
  @override
  void send(String room, Uint8List bytes) {}
  @override
  void look(String room, String token) {}
  @override
  void unlook(String room) {}
  @override
  Stream<RoomEvent> get events => const Stream.empty();
  @override
  Stream<({String room, String from, Uint8List bytes})> get packets => const Stream.empty();
  @override
  Stream<({String room, List<String> members})> get looks => const Stream.empty();
}

class _NoMedia implements VoiceMedia {
  _NoMedia([Map<String, double> loud = const {}]) : levels = ValueNotifier(loud);
  @override
  final ValueNotifier<Map<String, double>> levels;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  set muted(bool on) {}
  @override
  set deafened(bool on) {}
  @override
  Future<void> setVideo(bool on) async {}
  @override
  VoicePeer peer(String id, {required void Function(Map<String, dynamic> candidate) onCandidate}) => throw UnimplementedError();
  @override
  void setPeerVolume(String id, double volume) {}
  @override
  void setPeerMuted(String id, bool muted) {}
}

/// The tokens the screen on show is drawn with.
Tokens _tokensOf(WidgetTester tester) => tester.element(find.byType(HangoutChat).first).tokens;

/// Friends by username as kept, for a picture: nothing reaches anyone.
class _KeptBuddies implements BuddiesPort {
  _KeptBuddies(this.list);
  final List<Buddy> list;

  @override
  Future<({String id, String key})> me() async => (id: 'me', key: 'k');
  @override
  String? get username => 'matt';
  @override
  String get displayName => 'Matt';
  @override
  String get bio => '';
  @override
  Future<({String id, String key})?> whois(String username) async => null;
  @override
  Future<void> keep(String json) async {}
  @override
  Future<String> kept() async => jsonEncode([for (final b in list) b.toJson()]);
  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async => true;
  @override
  Stream<({String from, Envelope envelope})> get received => const Stream.empty();
  @override
  Stream<({String from, Envelope envelope})> get greetings => const Stream.empty();
}
