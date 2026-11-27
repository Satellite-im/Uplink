import '../platform_info.dart';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../desktop/ui/qr.dart';
import '../inbox/inbox.dart';
import '../inbox/whatsapp.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../net/pair_room.dart';
import '../sms.dart';
import 'common.dart';
import '../l10n/words.dart';

export '../inbox/whatsapp.dart' show whatsAppWarning;

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// Linking WhatsApp (Matt, 2026-11-17: "enable whatsapp but warn the user that it's unsupported by whatsapp"). First
/// the warning ([whatsAppWarning]), which has to be agreed to with "I understand, link WhatsApp" before anything is
/// asked of WhatsApp; then the QR code WhatsApp on the person's phone scans (Settings › Linked devices › Link a device),
/// or an eight-letter code to type there instead ("Link with phone number instead"). Looks as SignalLinkScreen does.
class WhatsAppLinkScreen extends StatefulWidget {
  const WhatsAppLinkScreen({super.key, required this.network});
  final WhatsApp network;

  @override
  State<WhatsAppLinkScreen> createState() => _WhatsAppLinkScreenState();
}

class _WhatsAppLinkScreenState extends State<WhatsAppLinkScreen> {
  /// The code on another screen, on the phone (lib/net/pair_room.dart).
  final _room = PairRoom();
  final _phone = TextEditingController();

  /// The warning agreed to: only then is WhatsApp asked for a code.
  bool _agreed = false;

  /// Linking by phone number rather than the QR code.
  bool _byNumber = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    widget.network.addListener(_changed);
  }

  void _agree() {
    setState(() => _agreed = true);
    widget.network.begin();
  }

  /// Shows the QR code on another screen: opens the pair room once, puts the code in it and shares the room's link.
  Future<void> _elsewhere() async {
    if (!_room.open) await _room.openRoom(onCame: () => _showCode());
    _showCode();
    final link = _room.link;
    if (link != null && mounted) await Sms.instance.shareText('Link WhatsApp to Uplink', link);
    if (mounted) setState(() {});
  }

  void _showCode() {
    final qr = widget.network.qr;
    if (qr != null && _room.open) _room.showCode(qr);
  }

  Future<void> _pair() async {
    if (_asking) return;
    setState(() => _asking = true);
    await widget.network.pairWithPhone(_phone.text);
    if (mounted) setState(() => _asking = false);
  }

  /// The network changed: a new code goes to the pair room too, and once linked the room is told and the screen leaves.
  void _changed() {
    _showCode();
    if (widget.network.state == InboxState.ready && _room.open) _room.done();
    if (widget.network.state == InboxState.ready && mounted) {
      toast(context, 'WhatsApp linked${widget.network.account == null ? '' : ' as ${widget.network.account}'}');
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.network.removeListener(_changed);
    _room.close();
    _phone.dispose();
    super.dispose();
  }

  Widget _warning(BuildContext context) {
    final t = context.tokens;
    return SettingRowBox(
      child: Padding(
        padding: EdgeInsets.all(t.space(3)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(Lucide.triangleAlert, size: 20, color: t.danger),
            SizedBox(width: t.space(3)),
            const Expanded(child: Text(whatsAppWarning)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final error = n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger));
        final sections = <Widget>[
          if (!_agreed)
            PaneSection(
              title: 'WhatsApp doesn\'t support this',
              description: const Tr('Read this before linking.'),
              children: [
                _warning(context),
                SettingRow(icon: _icon(Lucide.shieldCheck), label: 'I understand, link WhatsApp', onPress: _agree),
                SettingRow(icon: _icon(Lucide.arrowLeft), label: 'Not now', onPress: () => Navigator.of(context).maybePop()),
              ],
            )
          else if (!_byNumber)
            PaneSection(
              title: 'Scan this with WhatsApp',
              description: const Tr('In WhatsApp on your phone: Settings › Linked devices › Link a device, then point it at this code. Uplink becomes another of your devices, as WhatsApp Web is, and your recent chats come across.'),
              footer: error,
              children: [
                SettingRowBox(
                  child: Padding(
                    padding: EdgeInsets.all(t.space(3)),
                    child: Center(
                      child: n.qr == null
                          ? const GhostSpinner(size: 24, label: 'Asking WhatsApp for a code…')
                          : Container(color: const Color(0xFFFFFFFF), padding: EdgeInsets.all(t.space(2)), child: QrView(data: n.qr!, size: 220)),
                    ),
                  ),
                ),
                if (n.qr != null && PlatformInfo.isAndroid)
                  SettingRow(
                    icon: _icon(Lucide.share2),
                    label: 'Show it on another screen',
                    hint: Text(_room.open
                        ? 'Open ${_room.link} on a computer or tablet: the code is drawn there, and changes there as it does here.'
                        : 'This phone can\'t scan its own screen: a link opens the code on any other screen, sealed so only that page can read it. Or link with your phone number.'),
                    onPress: _elsewhere,
                  ),
                SettingRow(icon: _icon(Lucide.smartphone), label: 'Link with phone number instead', onPress: () => setState(() => _byNumber = true)),
                SettingRow(icon: _icon(Lucide.rotateCcw), label: 'A new code', onPress: n.begin),
              ],
            )
          else
            PaneSection(
              title: 'Link with your phone number',
              description: const Tr('Your WhatsApp number, with its country code. Uplink gets an eight-letter code from WhatsApp: in WhatsApp on your phone, Settings › Linked devices › Link a device › Link with phone number instead, then type it there.'),
              footer: error,
              children: [
                SettingRowBox(
                  child: GlacierInput(controller: _phone, type: GlacierInputType.tel, placeholder: '+1 555 010 0199'.t, ariaLabel: 'Your WhatsApp number', autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (_) => _pair()),
                ),
                SettingRow(icon: _icon(Lucide.arrowRight), label: _asking ? 'Asking WhatsApp…' : 'Get a code', disabled: _asking, onPress: _pair),
                if (n.pairCode != null)
                  SettingRowBox(
                    child: Padding(
                      padding: EdgeInsets.all(t.space(4)),
                      child: Center(child: Text(n.pairCode!, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 4))),
                    ),
                  ),
                if (n.pairCode != null)
                  SettingRow(
                    icon: _icon(Lucide.keyRound),
                    label: 'Copy the code',
                    onPress: () {
                      Clipboard.setData(ClipboardData(text: n.pairCode!.replaceAll('-', '')));
                      toast(context, 'Code copied');
                    },
                  ),
                SettingRow(icon: _icon(Lucide.arrowLeft), label: 'Scan a QR code instead', onPress: () => setState(() => _byNumber = false)),
              ],
            ),
        ];
        return GhostPage(
          title: 'Link WhatsApp',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                ...sections,
                SizedBox(height: t.space(4)),
                if (_agreed) const SettingsFootnote(child: Text('$whatsAppWarning Your messages go between this device and WhatsApp only, never through Uplink\'s servers.')),
              ],
            ),
          ),
        );
      },
    );
  }
}
