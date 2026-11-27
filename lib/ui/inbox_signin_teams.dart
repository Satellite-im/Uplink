import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../inbox/inbox.dart';
import '../inbox/teams.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

/// Signing in to Microsoft Teams (lib/inbox/teams.dart): Microsoft's device code. Uplink shows a short code, opens
/// microsoft.com/devicelogin in the browser, and waits there while the person types the code and approves.
class TeamsSignInScreen extends StatefulWidget {
  const TeamsSignInScreen({super.key, required this.network});
  final Teams network;

  @override
  State<TeamsSignInScreen> createState() => _TeamsSignInScreenState();
}

class _TeamsSignInScreenState extends State<TeamsSignInScreen> {
  bool _done = false;

  @override
  void initState() {
    super.initState();
    widget.network.addListener(_changed);
  }

  @override
  void dispose() {
    widget.network.removeListener(_changed);
    // Leaving before approving stops the wait; a sign-in that went through stays.
    if (widget.network.state == InboxState.signingIn) widget.network.cancel();
    super.dispose();
  }

  void _changed() {
    final n = widget.network;
    if (!_done && n.state == InboxState.ready && mounted) {
      _done = true;
      toast(context, 'Signed in to Microsoft Teams as ${n.account}');
      Navigator.of(context).maybePop();
    }
  }

  /// Asks Microsoft for a device code, copies it, and opens the page it is typed on.
  Future<void> _begin() async {
    final code = await widget.network.begin();
    if (code == null || !mounted) return;
    await Clipboard.setData(ClipboardData(text: code.user));
    await Sms.instance.openLink(code.page);
  }

  void _copy(String code) {
    Clipboard.setData(ClipboardData(text: code));
    toast(context, 'Code copied');
  }

  static Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final code = n.code;
        final waiting = n.state == InboxState.signingIn;
        final unavailable = n.state == InboxState.unavailable;
        return GhostPage(
          title: 'Sign in to Microsoft Teams',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              children: [
                PaneSection(
                  title: code == null ? 'Your work or school account' : 'Your code',
                  description: Text(code == null
                      ? 'Teams chats can be read here with a work or school account only: personal Microsoft accounts (Teams free) aren\'t supported by Microsoft. Some organisations need their IT admin to approve Uplink first.'
                      : 'Microsoft\'s page has opened. Type this code there (it\'s copied already), choose your work or school account and approve. This screen carries on by itself.'),
                  footer: n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                  children: [
                    if (code == null)
                      SettingRow(
                        icon: _icon(Lucide.arrowRight),
                        label: waiting ? 'Asking Microsoft…' : 'Sign in with Microsoft',
                        disabled: waiting || unavailable,
                        onPress: _begin,
                      )
                    else ...[
                      SettingRowBox(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: t.space(4)),
                          child: Center(
                            child: Text(
                              code.user,
                              textAlign: TextAlign.center,
                              style: pageText(t, t.fontSize('md') * 2, weight: 'semibold', color: t.color('app-ink'), tracking: 4, mono: true),
                            ),
                          ),
                        ),
                      ),
                      SettingRow(icon: _icon(Lucide.copy), label: 'Copy the code', onPress: () => _copy(code.user)),
                      SettingRow(icon: _icon(Lucide.externalLink), label: 'Open microsoft.com/devicelogin', onPress: () => Sms.instance.openLink(code.page)),
                      SettingRow(icon: _icon(Lucide.refreshCw), label: 'Get a new code', onPress: _begin),
                    ],
                  ],
                ),
                if (code != null) ...[
                  SizedBox(height: t.space(2)),
                  const SettingsFootnote(child: Tr('Waiting for you to approve on Microsoft\'s page…')),
                ],
                SizedBox(height: t.space(4)),
                const SettingsFootnote(
                  child: Tr('Your messages go between this device and Microsoft only. Uplink\'s servers never see them; only the sign-in Microsoft gives back is kept on this device.'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
