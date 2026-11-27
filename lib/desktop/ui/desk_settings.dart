import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import '../../ui/whats_new.dart' show showWhatsNew;
import 'package:flutter/widgets.dart';

import '../platform.dart';
import 'package:glacier/glacier.dart';

import '../../app_state.dart';
import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_kit.dart';
import '../../ui/common.dart';
import '../../ui/computers.dart';
import '../../ui/gm_guide_screen.dart';
import '../../ui/jump_to_latest.dart' show ScrollMemory;
import '../../ui/settings.dart';
import '../../ui/settings_panes.dart' show aboutLicences, versionTapped;
import '../../gm/google_signin.dart';
import '../../gm/google_signin_flow.dart';
import '../../gm/rcs_share.dart';
import '../../sms.dart' show Sms;
import '../gm_web.dart';
import '../private_browser.dart';
import '../link/link.dart';
import '../remote.dart';
import '../updates.dart';
import 'qr.dart';
import 'update_bar.dart';
import 'wizard.dart';
import '../../l10n/words.dart';

/// What a computer adds to Settings. A computer has the phone's Settings and its pages (Matt, 2026-11-14: "desktop
/// and mobile should also share the same settings pages", and "a full features settings page like the ghost
/// markdown app ... instead of the one small settings panel we have now"); these are the sections that are the
/// computer's alone, which stand where the phone has its own (Computers, Updates, About): the phone it is paired
/// with and how the two connect, what is kept on this Mac, the Mac app's updates, and what it is.
///
/// The frame makes one while a phone is paired (lib/desktop/ui/shell.dart) and hands its sections to Settings
/// (SettingsSources), which is drawn again as the link, the updates or this change.
class DeskSettings extends ChangeNotifier {
  DeskSettings({required this.link, required this.calls, this.updates, this.envPeers = const []});

  final PhoneLink link;
  final LinkCalls calls;
  final MacUpdates? updates;
  final List<Peer> envPeers;

  /// How much of what was read is kept on this Mac (lib/desktop/cache.dart); null until it has been counted.
  ({int conversations, int bytes})? kept;

  /// When it was last counted; and this has been disposed of, so a count that comes late tells nobody.
  DateTime _counted = DateTime.fromMillisecondsSinceEpoch(0);
  bool _gone = false;

  /// Counts what is kept. Asked each time its row or its page is drawn, so it is counted no oftener than every few
  /// seconds unless [now].
  void countKept({bool now = false}) {
    final at = DateTime.now();
    if (!now && at.difference(_counted) < const Duration(seconds: 3)) return;
    _counted = at;
    calls.cache.size().then((k) {
      if (_gone || k == kept) return;
      kept = k;
      notifyListeners();
    });
  }

  /// What Settings is drawn again for.
  List<Listenable> get watch => [this, link, ?updates];

  /// Before the app's own sections: the phone.
  List<SettingsSection> first() => [
        SettingsSection(
          id: 'phone',
          where: SettingsWhere.computer,
          label: 'Your phone',
          icon: const AppIcon(LucideMore.smartphone, size: 18),
          hue: 'blue',
          group: 'computer',
          summary: (m) => link.phone == null ? 'Optional · not linked' : '${link.phone!.name} · ${_linkShort(link)}',
          page: (context, m) => _phonePage(context, this),
        ),
        // Google Messages on this computer (lib/desktop/gm_web.dart), where this copy carries its helper.
        SettingsSection(
          id: 'gmessages',
          where: SettingsWhere.computer,
          label: 'Google Messages',
          icon: const AppIcon(Lucide.link, size: 18),
          hue: 'green',
          group: 'computer',
          when: (m) => GmWeb.instance.available,
          summary: (m) => GmWeb.instance.paired ? (GmWeb.instance.connected ? 'Connected' : 'Paired') : 'Not paired',
          page: (context, m) => [const _GmPage()],
        ),
      ];

  /// After them: what is the Mac app's own.
  List<SettingsSection> after() => [
        SettingsSection(
          id: 'kept',
          where: SettingsWhere.computer,
          // What is kept is the phone's conversations: nothing to keep without one.
          when: (m) => link.phone != null,
          label: 'Kept on this $computerWord',
          icon: const AppIcon(Lucide.hardDrive, size: 18),
          hue: 'slate',
          group: 'app',
          summary: (m) {
            countKept();
            final k = kept;
            return k == null || k.bytes == 0 ? 'Nothing yet' : '${_conversations(k.conversations)} · ${keptSize(k.bytes)}';
          },
          page: (context, m) => _keptPage(context, this),
        ),
        SettingsSection(
          id: 'mac-updates',
          where: SettingsWhere.computer,
          label: 'Updates',
          icon: const AppIcon(Lucide.download, size: 18),
          hue: 'mint',
          group: 'app',
          // A copy that looks for none (a test, one run from the build folder) has nothing to say here.
          when: (m) => updates?.installed != null,
          summary: (m) => _updateShort(updates!),
          page: (context, m) => _updatesPage(context, this),
        ),
        SettingsSection(
          id: 'mac-about',
          where: SettingsWhere.computer,
          label: 'About',
          icon: const AppIcon(Lucide.info, size: 18),
          hue: 'graphite',
          group: 'app',
          summary: (m) => 'Uplink for $desktopName ${link.app}',
          page: (context, m) => _aboutPage(context, this, m.app),
        ),
      ];

  @override
  void dispose() {
    _gone = true;
    super.dispose();
  }
}

Widget _icon(LucideIcon i) => AppIcon(i, size: 18);

String _conversations(int n) => '$n ${n == 1 ? 'conversation' : 'conversations'}';

/// A size on disk, as a person reads it.
String keptSize(int bytes) => bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';

/// How the phone is connected, in a word or two, for the row on Settings' list.
String _linkShort(PhoneLink link) {
  if (link.refused) return 'no longer paired';
  return switch (link.via) { 'local' => 'local network', 'relay' => 'through the relay', _ => 'not connected' };
}

/// Where the Mac app's update stands, short, for the row on Settings' list.
String _updateShort(MacUpdates u) {
  final version = u.release?.version ?? '';
  return switch (u.phase) {
    MacUpdatePhase.idle => u.checked == null ? 'Not looked for yet' : 'Up to date',
    MacUpdatePhase.checking => 'Looking…',
    MacUpdatePhase.downloading => 'Getting $version',
    MacUpdatePhase.ready => '$version is ready',
    MacUpdatePhase.restarting => 'Restarting…',
    MacUpdatePhase.manual => '$version is out',
    MacUpdatePhase.failed => 'Couldn\'t update',
  };
}

// --- Google Messages --------------------------------------------------------------------------------------------------

/// Pairing with Google Messages, as messages.google.com is paired (Matt, 2026-11-15: "Yes, mautrix sidecar"): a QR
/// code to scan in Google Messages on the phone, and how it stands once paired.
class _GmPage extends StatefulWidget {
  const _GmPage();

  @override
  State<_GmPage> createState() => _GmPageState();
}

class _GmPageState extends State<_GmPage> {
  /// How RCS stands on the paired phone (GMFB-11, lib/gm/rcs_share.dart); null until it answers, or where it can't.
  RcsState? _phone;

  /// Set up here as well, though the phone already carries RCS.
  bool _here = false;

  @override
  void initState() {
    super.initState();
    if (Sms.remote) {
      RcsShare.ofPhone().then((s) {
        if (mounted) setState(() => _phone = s);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final gm = GmWeb.instance;
    final phone = _phone;
    return ListenableBuilder(
      listenable: gm,
      builder: (context, _) {
        final t = context.tokens;
        final qr = gm.qr;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (qr != null)
            PaneSection(
              title: 'Scan this in Google Messages',
              description: const Tr('On your phone, open Google Messages, tap your profile picture, then Device pairing, then QR code scanner, and point it at this code.'),
              children: [
                SettingRowBox(child: Center(child: Padding(padding: EdgeInsets.all(t.space(3)), child: QrView(data: qr, size: 240)))),
              ],
            )
          else if (gm.paired)
            PaneSection(
              title: 'Paired with Google Messages',
              footer: const Tr('Every conversation in Google Messages shows here, RCS and texts, with their history and pictures. Your phone needs to be on and online: the messages go through it.'),
              children: [
                if (gm.inactive)
                  SettingRow(
                    icon: _icon(LucideMore.smartphone),
                    label: 'Your phone has Google Messages for now',
                    hint: const Tr('Google Messages keeps one web session at a time, and Uplink on your phone holds it. This computer shows the same conversations through your phone.'),
                  ),
                SettingRow(
                  icon: _icon(gm.connected ? Lucide.circleCheck : Lucide.triangleAlert),
                  label: gm.connected ? 'Connected' : 'Connecting…',
                  hint: Text([if (gm.phone.isNotEmpty) gm.phone, ?gm.problem].join(' · ').ifEmpty('Google Messages answers this computer directly')),
                ),
                SettingRow(icon: _icon(Lucide.bookOpen), label: 'Keep it running', hint: const Tr('Open at login, and staying awake: the guide.'), onPress: () => push(context, (_) => const GmGuideScreen())),
                SettingRow(
                  icon: _icon(Lucide.unlink),
                  label: 'Unpair Google Messages',
                  hint: const Tr('This computer stops showing Google Messages\' conversations. Google Messages lists it under Device pairing until then.'),
                  onPress: () => showChoices(context, title: 'Unpair Google Messages from this computer?', choices: [
                    // Where each conversation was left goes too (lib/ui/jump_to_latest.dart): paired again, perhaps with another phone,
                    // the same thread numbers name other conversations.
                    Choice('Unpair', Lucide.unlink, () {
                      ScrollMemory.forgetAll('sms:');
                      gm.unpair();
                    }, danger: true),
                  ]),
                ),
              ],
            )
          else if (phone != null && phone.throughPhone && !_here) ...[
            // RCS already comes through the phone (GMFB-11, @kevin: "Syncing the rcs setting between connected devices
            // would be really cool"): said, rather than asking for this computer to be set up again.
            PaneSection(
              title: 'RCS through your phone',
              description: const Tr('Your phone has Google Messages set up in Uplink, so every conversation there, RCS and texts, already shows on this computer through it.'),
              footer: const Tr('Your phone needs to be on and online for them to arrive. Set up this computer as well if you want it to reach Google Messages without your phone being on.'),
              children: [
                SettingRow(
                  key: const ValueKey('rcs-through-phone'),
                  icon: _icon(phone.webConnected ? Lucide.circleCheck : Lucide.triangleAlert),
                  label: phone.webConnected ? 'On, through your phone' : 'Set up on your phone, connecting',
                  hint: Text([if (phone.phone.isNotEmpty) phone.phone, if (phone.rcsOn) 'RCS chats on in Google Messages'].join(' · ').ifEmpty('Google Messages answers your phone')),
                ),
                SettingRow(icon: _icon(Lucide.laptop), label: 'Set up this computer as well', onPress: () => setState(() => _here = true)),
              ],
            ),
          ]
          else ...[
            // Google-account pairing, all in one place (lib/gm/google_signin_flow.dart; Matt, 2026-11-15: "Please make
            // setting up google messages a onboarding flow that is all in one place"): QR pairing is gone from Google
            // Messages signed in to an account.
            PaneSection(
              title: 'Set up Google Messages on this computer',
              description: const Tr('Every conversation in Google Messages shows here, RCS and texts, with their history, pictures and reactions. It takes a couple of minutes, once.'),
              footer: const Tr('The connection is this computer\'s alone: messages go between it and Google, never through Uplink\'s servers. The helper is open source, built on mautrix-gmessages (GNU AGPL).'),
              children: [
                SettingRowBox(child: Padding(
                  padding: EdgeInsets.symmetric(vertical: t.space(2)),
                  child: GoogleSignInFlow(onPair: gm.pairGoogle, onOpenPrivate: () => openPrivately(googleSignInUrl), emoji: gm.emoji, problem: gm.problem),
                )),
              ],
            ),
            PaneSection(children: [
              SettingRow(icon: _icon(Lucide.bookOpen), label: 'Keep it running', hint: const Tr('Open at login, staying awake, and using it with your phone.'), onPress: () => push(context, (_) => const GmGuideScreen())),
              SettingRow(icon: _icon(LucideMore.qrCode), label: 'Pair with a QR code instead', hint: const Tr('For Google Messages not signed in to a Google account, where Device pairing still has a QR code scanner.'), onPress: () async {
                try {
                  await gm.pair();
                } catch (e) {
                  if (context.mounted) toast(context, '$e');
                }
              }),
            ]),
          ],
        ]);
      },
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// --- Your phone -------------------------------------------------------------------------------------------------------

/// The Your phone page: linking one where none is, else the phone paired with and how the two connect.
List<Widget> _phonePage(BuildContext context, DeskSettings d) {
  final link = d.link;
  final phone = link.phone;
  // None linked: linking one is offered, never needed (Matt, 2026-11-18: "make setting up SMS and such and linking to a
  // phone an optional step"). Once it is, the app opens again on it (lib/desktop/main.dart, DeskHome).
  if (phone == null) {
    return [
      PaneSection(
        title: 'Texts from an Android phone',
        description: Text('Optional. Link Uplink on your Android phone and this $computerWord shows your texts and sends through it. Friends, circles, Telegram and Signal work without one.'),
        children: [
          SettingRow(
            key: const ValueKey('link-phone'),
            icon: _icon(LucideMore.qrCode),
            label: 'Link an Android phone',
            hint: const Tr('Scan a code with the phone. Uplink opens again once it is linked.'),
            onPress: () => push<void>(context, (_) => const GhostPage(title: 'Link an Android phone', body: PairWizard())),
          ),
        ],
      ),
    ];
  }
  return [
    PaneSection(title: 'Paired with', children: [
      SettingRow(
        icon: _icon(LucideMore.smartphone),
        label: phone.name,
        // How the two are connected lives here alone (Matt, 2026-11-14: "move the "connected to the relay" into the
        // settings only we don't need to show it on the sidebar"), with any texts waiting for the phone.
        hint: Text('${linkLine(link)}${d.calls.waiting > 0 ? ' · ${d.calls.waiting} ${d.calls.waiting == 1 ? 'text' : 'texts'} waiting' : ''} · paired ${listWhen(phone.since)}'),
      ),
    ]),
    ConnectionChoice(value: phone.mode, relay: phone.relay, onChanged: (m) => link.setMode(m)),
    PaneSection(
      title: 'If the phone isn\'t found',
      footer: Text('The phone announces itself on the network and this $computerWord looks for it. Where a network keeps the two from finding each other, give the phone\'s address: it is on the phone under Settings › Computers.'),
      children: [SettingRowBox(child: _AddressField(settings: d))],
    ),
    PaneSection(children: [
      SettingRow(
        icon: _icon(Lucide.unlink),
        label: 'Unpair this phone',
        hint: Text('This $computerWord stops showing the phone\'s texts, and the key is deleted from both.'),
        onPress: () => showChoices(context, title: 'Unpair ${phone.name}? Its conversations leave this $computerWord, and the key the two share is deleted.', choices: [
          Choice('Unpair', Lucide.unlink, () async {
            d.calls.forget();
            // And where each of its conversations was left: another phone paired later numbers its threads afresh.
            ScrollMemory.forgetAll('sms:');
            await link.unpair();
          }, danger: true),
        ]),
      ),
    ]),
  ];
}

/// The phone's address, given by hand for a network where it is not found by itself.
class _AddressField extends StatefulWidget {
  const _AddressField({required this.settings});
  final DeskSettings settings;

  @override
  State<_AddressField> createState() => _AddressFieldState();
}

class _AddressFieldState extends State<_AddressField> {
  final _address = TextEditingController();

  /// The address kept has been put in the field: once, so what is typed is not written over.
  bool _read = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_read) return;
    _read = true;
    _address.text = AppState.of(context).choice('peer', '');
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  /// Keeps the address typed (the 'peer' choice) and has the link try it at once; emptied, the phone is looked for
  /// by itself again. Something that is no address and port is said to be so, and not kept.
  void _save() {
    final d = widget.settings;
    final app = AppState.of(context);
    final text = _address.text.trim();
    // Left as it was (the field is left each time another row is pressed): nothing to say.
    if (text == app.choice('peer', '')) return;
    final peer = Peer.parse(text);
    if (text.isNotEmpty && peer == null) {
      toast(context, 'That isn\'t an address and a port, like 192.168.1.20:47811', tone: GlacierToastTone.danger);
      return;
    }
    app.set('peer', text);
    d.link.given = [...d.envPeers, ?peer];
    d.link.look();
    toast(context, text.isEmpty ? 'The phone is looked for by itself' : 'Saved. Trying it now.');
  }

  @override
  Widget build(BuildContext context) {
    return GlacierInput(
      controller: _address,
      placeholder: '192.168.1.20:47811'.t,
      ariaLabel: 'The phone\'s address and port',
      autoCorrect: false,
      autoCapitalize: TextCapitalization.none,
      size: GlacierFieldSize.md,
      onSubmitted: (_) => _save(),
      onBlur: _save,
    );
  }
}

// --- Kept on this Mac -------------------------------------------------------------------------------------------------

/// What was read from the phone is kept here (Matt, 2026-11-14: "cache messages on the desktop app so that we don't
/// need to fetch them all from the phone every time"): how much, and a way to clear it.
List<Widget> _keptPage(BuildContext context, DeskSettings d) {
  d.countKept();
  final k = d.kept;
  final nothing = k == null || k.bytes == 0;
  return [
    PaneSection(
      title: 'Conversations and messages',
      description: Text('The list and the conversations you open are kept on this $computerWord, sealed with your pairing\'s key, so they open at once and are there while your phone is away. Only what is new is fetched from your phone.'),
      children: [
        SettingRow(icon: _icon(Lucide.messageSquare), label: 'Conversations kept', value: Text(k == null ? '' : '${k.conversations}')),
        SettingRow(icon: _icon(Lucide.hardDrive), label: 'Space used', value: Text(k == null ? '' : (k.bytes == 0 ? 'None' : keptSize(k.bytes)))),
      ],
    ),
    PaneSection(
      footer: const Tr('They are read from your phone again as you open them. Unpairing clears them too.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.trash2),
          label: 'Clear what is kept',
          disabled: nothing,
          onPress: nothing
              ? null
              : () => showChoices(context, title: 'Clear the conversations and messages kept on this $computerWord? They are read from your phone again as you open them.', choices: [
                    Choice('Clear what is kept', Lucide.trash2, () async {
                      await d.calls.clearKept();
                      d.countKept(now: true);
                      if (context.mounted) toast(context, 'Cleared');
                    }, danger: true),
                  ]),
        ),
      ],
    ),
  ];
}

// --- Updates ----------------------------------------------------------------------------------------------------------

/// The Mac app's own updates (lib/desktop/updates.dart): where they stand, and a look for one when asked.
List<Widget> _updatesPage(BuildContext context, DeskSettings d) {
  final u = d.updates;
  final here = u?.installed;
  if (u == null || here == null) return const [];
  final ready = u.phase == MacUpdatePhase.ready;
  final busy = u.phase == MacUpdatePhase.checking || u.phase == MacUpdatePhase.downloading || u.phase == MacUpdatePhase.restarting;
  return [
    PaneSection(
      title: 'Uplink for $desktopName',
      footer: const Tr('It updates itself from gogho.st: a newer version is fetched behind the screens and put in place when you restart, or the next time you quit.'),
      children: [
        SettingRow(icon: _icon(Lucide.ghost), label: 'This version', value: Text('${here.version} (${here.build})')),
        SettingRow(
          icon: _icon(ready ? Lucide.rotateCcw : Lucide.download),
          // Linux from the .deb (GMFB-32): putting it in place is root's, so the desktop asks for the password first.
          label: ready ? (u.asksPassword ? 'Install and restart' : 'Restart to update') : 'Look for an update',
          hint: Text(u.asksPassword ? '${updateLine(u)}. Your computer asks for your password to install it.' : updateLine(u)),
          disabled: busy,
          onPress: busy ? null : (ready ? u.restart : u.check),
        ),
        if (u.phase == MacUpdatePhase.downloading) SettingRowBox(child: GlacierProgressBar(value: u.progress * 100, ariaLabel: 'Getting the update')),
        // Linux from the .deb (GMFB-32) where the desktop couldn't be asked to install it, or the password wasn't
        // given: the new one is here and checked, and the command is offered to paste into a terminal.
        if (u.installCommand != null)
          SettingRow(
            icon: _icon(Lucide.copy),
            label: 'Copy the install command',
            hint: Text(u.installCommand!),
            onPress: () {
              Clipboard.setData(ClipboardData(text: u.installCommand!));
              toast(context, 'Copied. Paste it into a terminal, then open Uplink again.');
            },
          ),
      ],
    ),
  ];
}

// --- About ------------------------------------------------------------------------------------------------------------

List<Widget> _aboutPage(BuildContext context, DeskSettings d, AppState app) {
  return [
    PaneSection(title: 'Uplink for $desktopName', children: [
      SettingRow(icon: _icon(Lucide.ghost), label: 'Version', value: Text(d.link.app), onPress: () => versionTapped(context, app)),
      // The release notes again (lib/ui/whats_new.dart).
      SettingRow(icon: _icon(Lucide.sparkles), label: 'What\'s new', hint: const Tr('What the last update brought.'), onPress: () => showWhatsNew(context)),
      SettingRow(icon: _icon(Lucide.bookOpen), label: 'Help and docs', hint: const Tr('How everything works, step by step, at gogho.st/docs.'), onPress: openDocs),
      SettingRow(
        icon: _icon(LucideMore.smartphone),
        label: 'Your phone sends and receives',
        hint: Text('This $computerWord shows what your phone has and sends through it, sealed between the two. A relay, where one is used, only ever carries sealed data.'),
      ),
      SettingRow(
        icon: _icon(Lucide.lock),
        label: 'What this $computerWord keeps',
        hint: Text('The pairing, your choices here, and the conversations you have read, sealed with the pairing\'s key so nothing else on it can read them. Settings › Kept on this $computerWord clears them.'),
      ),
    ]),
    aboutLicences(),
  ];
}
