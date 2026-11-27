import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../gm/google_signin_flow.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../net/crypto.dart';
import '../net/net.dart';
import '../sms.dart';
import 'common.dart';
import '../invites/link_relay.dart';
import '../l10n/words.dart';

/// Google Messages' web connection on this phone (android GmWeb.kt; Matt, 2026-11-15: "Can you build the on phone
/// google messages connection too?"): Google Messages' conversations whole in Uplink, with pictures, reactions and
/// delivered and read marks, and no need for its notifications.
///
/// Paired by a QR code Google Messages on this phone scans; the phone cannot scan its own screen, so the code is
/// shown on another: a link (gogho.st/pair) shared from here whose secret, after the #, gives a room on Uplink's relay
/// and the key for it. Each new code (one about every half minute) is said there sealed, and the page draws it.
class GmWebScreen extends StatefulWidget {
  const GmWebScreen({super.key});

  @override
  State<GmWebScreen> createState() => _GmWebScreenState();
}

class _GmWebScreenState extends State<GmWebScreen> {
  Map<String, Object?> _s = const {};
  Timer? _poll;

  // The pairing room, while pairing: its secret (in the link), name, token and key.
  Uint8List? _secret;
  String? _room;
  Uint8List? _key;
  // The code last said in the room, so the same one is not said again each second.
  String? _sentQr;
  StreamSubscription<Object?>? _came;

  @override
  void initState() {
    super.initState();
    _look();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _look());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _endRoom();
    super.dispose();
  }

  bool get _paired => _s['paired'] == true;

  /// Asks the helper how it stands (each second while the page is open): a new code is said in the pairing room, and
  /// once paired the room is told and left.
  Future<void> _look() async {
    try {
      final s = await Sms.instance.gmWebState();
      if (!mounted) return;
      setState(() => _s = s);
      final qr = s['qr'] as String?;
      if (qr != null && qr != _sentQr) _say({'t': 'qr', 'url': qr});
      if (_paired && _room != null) {
        _say({'t': 'paired'});
        _endRoom();
      }
    } catch (_) {}
  }

  /// Opens the pairing room on the relay and asks the helper for a code.
  Future<void> _pair() async {
    final r = Random.secure();
    final secret = Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
    _secret = secret;
    _room = NetCrypto.hex(NetCrypto.derive(secret, 'gmpair room').sublist(0, 16));
    _key = NetCrypto.derive(secret, 'gmpair key');
    final token = NetCrypto.hex(NetCrypto.derive(secret, 'gmpair token'));
    await Net.instance.want('gmpair', true);
    // The hub may take a moment to connect: asked again for a few seconds.
    for (var i = 0; i < 20; i++) {
      final hub = Net.instance.hub;
      if (hub != null) {
        try {
          await hub.join(_room!, token);
          break;
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    // Someone came into the room (the page opened): the code as it is now, at once.
    _came = Net.instance.hub?.roomEvents.where((e) => e.room == _room && (e.came?.isNotEmpty ?? false)).listen((_) {
      _sentQr = null;
      _look();
    });
    setState(() {});
    final s = await Sms.instance.gmWebPair();
    if (mounted) setState(() => _s = s);
  }

  /// Says [m] in the pairing room, sealed with the room's key; nothing where there is no room or no connection.
  void _say(Map<String, Object?> m) {
    final room = _room, key = _key, hub = Net.instance.hub;
    if (room == null || key == null || hub == null) return;
    try {
      hub.sendRoom(room, NetCrypto.seal(key, utf8.encode(jsonEncode(m))));
      if (m['t'] == 'qr') _sentQr = m['url'] as String?;
    } catch (_) {}
  }

  /// Leaves the pairing room and no longer asks the relay connection to stay up for it.
  void _endRoom() {
    _came?.cancel();
    final room = _room;
    if (room != null) Net.instance.hub?.leave(room);
    _room = null;
    _key = null;
    unawaited(Net.instance.want('gmpair', false));
  }

  /// The page to open on a computer to see the code: the room's secret is after the #, which is never sent to the
  /// server.
  String? get _link => _secret == null ? null : LinkRelay.mark('https://gogho.st/pair/#${NetCrypto.hex(_secret!)}');

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget icon(LucideIcon i) => AppIcon(i, size: 18);
    final s = _s;
    final problem = s['problem'] as String?;
    final children = <Widget>[];
    if (s['available'] != true) {
      children.add(SettingsCallout(child: const Tr('This copy of Uplink has no Google Messages helper. Update Uplink to get it.')));
    } else if (_paired) {
      final inactive = s['inactive'] == true;
      children.add(PaneSection(
        title: 'Connected to Google Messages',
        footer: const Tr('Uplink now has Google Messages\' conversations whole: RCS and texts, pictures, reactions, and when your messages are delivered and read. Google Messages\' own notifications can be turned off altogether; Uplink shows its own. Google Messages has one web session at a time: if a computer or messages.google.com takes it, this phone takes it back.'),
        children: [
          SettingRow(
            icon: icon(s['connected'] == true && !inactive ? Lucide.circleCheck : Lucide.triangleAlert),
            label: s['connected'] == true ? (inactive ? 'Another device has it for now' : 'Connected') : 'Connecting…',
            hint: Text([if ('${s['phone'] ?? ''}'.isNotEmpty) '${s['phone']}', ?problem].join(' · ').ifEmpty('Through Google\'s servers, as messages.google.com is')),
          ),
          SettingRow(
            icon: icon(Lucide.unlink),
            label: 'Unpair',
            hint: const Tr('Uplink goes back to reading Google Messages\' notifications.'),
            onPress: () => showChoices(context, title: 'Unpair Google Messages from Uplink on this phone?', choices: [
              Choice('Unpair', Lucide.unlink, () async {
                final s = await Sms.instance.gmWebUnpair();
                if (mounted) setState(() => _s = s);
              }, danger: true),
            ]),
          ),
        ],
      ));
    } else if (_room == null) {
      // Google-account pairing, all in one place (lib/gm/google_signin_flow.dart; Matt, 2026-11-15: "Please make setting
      // up google messages a onboarding flow that is all in one place"): QR pairing is gone where Google Messages is
      // signed in to an account.
      children.add(PaneSection(
        title: 'Set up Google Messages in Uplink',
        description: const Tr('Uplink then has every conversation, with pictures, reactions, and when your messages are delivered and read, without needing Google Messages\' notifications.'),
        footer: const Tr('It is done by an open-source helper built on mautrix-gmessages (GNU AGPL), talking to Google directly, never through Uplink\'s servers.'),
        children: [
          SettingRowBox(child: Padding(
            padding: EdgeInsets.symmetric(vertical: t.space(2)),
            child: GoogleSignInFlow(
              onPhone: true,
              emoji: s['emoji'] as String?,
              problem: problem,
              onPair: (cookies) async {
                final r = await Sms.instance.gmWebPairGoogle(cookies);
                if (mounted) setState(() => _s = r);
                return r['error'] as String?;
              },
            ),
          )),
        ],
      ));
      children.add(PaneSection(children: [
        SettingRow(icon: icon(LucideMore.qrCode), label: 'Pair with a QR code instead', hint: const Tr('For Google Messages not signed in to a Google account, where Device pairing still has a QR code scanner: shows the code on another screen.'), onPress: _pair),
      ]));
    } else {
      final link = _link!;
      children.add(PaneSection(
        title: 'Open this link on another screen',
        description: const Tr('Share it to your computer (or anything with a browser) and open it there. Then on this phone open Google Messages, tap your profile picture, then Device pairing, then QR code scanner, and scan the code it shows.'),
        footer: Text(s['qr'] == null ? 'Getting a code from Google…' : 'A fresh code goes to the page about every half minute, for five minutes.'),
        children: [
          SettingRowBox(child: Padding(padding: EdgeInsets.all(t.space(2)), child: Text(link, style: pageText(t, t.fontSize('sm'), mono: true, color: t.color('app-ink-2'))))),
          SettingRow(icon: icon(Lucide.share2), label: 'Share the link', onPress: () => Sms.instance.shareText('Pair Uplink with Google Messages', link)),
          if (problem != null) SettingRow(icon: icon(Lucide.triangleAlert), label: 'It stopped', hint: Text(problem), onPress: _pair),
        ],
      ));
    }
    return GhostPage(
      title: 'Google Messages connection',
      body: ListView(padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(10)), children: children),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
