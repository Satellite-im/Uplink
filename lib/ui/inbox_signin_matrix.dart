import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../inbox/inbox.dart';
import '../inbox/matrix.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../sms.dart';
import 'common.dart';
import '../l10n/words.dart';

/// Signing in to Matrix (Matt, 2026-11-17: "Let's add support for matrix, microsoft teams and google chat"): the
/// homeserver or the person's user id, then the browser (single sign-on, the way matrix.org signs people in since it
/// moved to Matrix Authentication Service) or a password where the server takes one. Once signed in, an optional step:
/// the recovery key, which lets this device read messages from before it was signed in.
class MatrixSignInScreen extends StatefulWidget {
  const MatrixSignInScreen({super.key, required this.network, this.openLink});
  final Matrix network;

  /// Opens the homeserver's sign-in page in the browser; the app's own by default (a test gives its own).
  final Future<bool> Function(String url)? openLink;

  @override
  State<MatrixSignInScreen> createState() => _MatrixSignInScreenState();
}

class _MatrixSignInScreenState extends State<MatrixSignInScreen> {
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  bool _browser = false, _unlocking = false;
  String? _keyError;
  bool _unlocked = false;

  @override
  void dispose() {
    widget.network.cancelBrowser();
    _server.dispose();
    _user.dispose();
    _password.dispose();
    _key.dispose();
    super.dispose();
  }

  void _signedIn() {
    if (!mounted || widget.network.state != InboxState.ready) return;
    _password.clear();
    toast(context, 'Signed in to Matrix as ${widget.network.userId ?? widget.network.account}');
  }

  Future<void> _withBrowser() async {
    setState(() => _browser = true);
    await widget.network.signInWithBrowser(_server.text, open: widget.openLink ?? Sms.instance.openLink);
    if (mounted) setState(() => _browser = false);
    _signedIn();
  }

  /// With no server typed, a whole user id (@you:server) stands in for it.
  Future<void> _withPassword() async {
    if (_user.text.trim().isEmpty || _password.text.isEmpty) return;
    await widget.network.signInWithPassword(_server.text.trim().isEmpty && _user.text.trim().startsWith('@') ? _user.text : _server.text, _user.text, _password.text);
    _signedIn();
  }

  /// Hands the recovery key to the network; what it refuses is shown under the field.
  Future<void> _unlock() async {
    if (_key.text.trim().isEmpty) return;
    setState(() {
      _unlocking = true;
      _keyError = null;
    });
    try {
      await widget.network.unlock(_key.text);
      _key.clear();
      _unlocked = true;
      if (mounted) toast(context, 'Older messages unlocked');
    } catch (e) {
      _keyError = '$e'.replaceFirst('Bad state: ', '');
    }
    if (mounted) setState(() => _unlocking = false);
  }

  Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final ready = n.state == InboxState.ready;
        final busy = n.state == InboxState.signingIn;
        return GhostPage(
          title: ready ? 'Matrix' : 'Sign in to Matrix',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                if (!ready) ...[
                  PaneSection(
                    title: 'Your server',
                    description: const Tr('The server your account is on, or your whole user id (@you:matrix.org). Left empty, it\'s matrix.org.'),
                    footer: n.error == null || _browser ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                    children: [
                      SettingRowBox(
                        child: GlacierInput(controller: _server, placeholder: 'matrix.org'.t, ariaLabel: 'Your server or user id', autoCorrect: false, autoFocus: true, size: GlacierFieldSize.md),
                      ),
                      SettingRow(
                        icon: _icon(Lucide.globe),
                        label: _browser ? 'Waiting for your browser…' : 'Sign in with your browser',
                        hint: Text(_browser
                            ? 'Sign in on the page that opened. It comes back here by itself once you\'re in.'
                            : 'Your server\'s own sign-in page opens. Uplink never sees your password.'),
                        disabled: busy && !_browser,
                        onPress: _browser ? null : _withBrowser,
                      ),
                      if (_browser) SettingRow(icon: _icon(Lucide.x), label: 'Stop waiting', onPress: n.cancelBrowser),
                    ],
                  ),
                  SizedBox(height: t.space(4)),
                  PaneSection(
                    title: 'Or with a password',
                    description: const Tr('For servers that still take one. matrix.org and others on Matrix Authentication Service sign in with the browser only.'),
                    children: [
                      SettingRowBox(
                        child: GlacierInput(controller: _user, placeholder: '@you:matrix.org'.t, ariaLabel: 'User name', autoCorrect: false, size: GlacierFieldSize.md),
                      ),
                      SettingRowBox(
                        child: GlacierInput(controller: _password, type: GlacierInputType.password, placeholder: 'Password'.t, ariaLabel: 'Password', autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (_) => _withPassword()),
                      ),
                      SettingRow(icon: _icon(Lucide.arrowRight), label: busy && !_browser ? 'Signing in…' : 'Sign in', disabled: busy, onPress: _withPassword),
                    ],
                  ),
                ] else ...[
                  PaneSection(
                    title: 'Unlock older messages',
                    description: const Tr(
                        'Most Matrix chats are end-to-end encrypted. New messages reach this device once your other devices share their keys with it. Your recovery key (Element calls it the Security Key) unlocks the rest: this device is verified as yours, and the keys to messages from before it was signed in come down from your server\'s key backup. It is used once and not kept.'),
                    footer: _keyError == null ? null : Text(_keyError!, style: TextStyle(color: t.danger)),
                    children: [
                      if (n.verified || _unlocked)
                        SettingRow(icon: _icon(Lucide.shieldCheck), label: 'This device is verified', hint: Text('Signed in as ${n.userId ?? n.account ?? ''}'))
                      else ...[
                        SettingRowBox(
                          child: GlacierInput(controller: _key, type: GlacierInputType.password, placeholder: 'EsTx xxxx xxxx …'.t, ariaLabel: 'Recovery key', autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (_) => _unlock()),
                        ),
                        SettingRow(icon: _icon(Lucide.keyRound), label: _unlocking ? 'Unlocking…' : 'Unlock', disabled: _unlocking, onPress: _unlock),
                      ],
                      SettingRow(icon: _icon(Lucide.check), label: n.verified || _unlocked ? 'Done' : 'Not now', onPress: () => Navigator.of(context).maybePop()),
                    ],
                  ),
                ],
                SizedBox(height: t.space(4)),
                const SettingsFootnote(child: Tr('Your messages go between this device and your Matrix server only. Uplink\'s servers never see them, and your password isn\'t kept: only the session your server gives back, and this device\'s encryption keys.')),
              ],
            ),
          ),
        );
      },
    );
  }
}
