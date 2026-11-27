import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../inbox/google_chat.dart';
import '../inbox/inbox.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../sms.dart';
import 'common.dart';
import '../l10n/words.dart';

/// Signing in to Google Chat (lib/inbox/google_chat.dart): Google's own page opens in the browser, and Uplink waits for
/// the browser to come back to it on this device (a listener on 127.0.0.1, closed as soon as it has).
class GoogleChatSignInScreen extends StatefulWidget {
  const GoogleChatSignInScreen({super.key, required this.network});
  final GoogleChat network;

  @override
  State<GoogleChatSignInScreen> createState() => _GoogleChatSignInScreenState();
}

class _GoogleChatSignInScreenState extends State<GoogleChatSignInScreen> {
  /// Google's sign-in page, while this screen waits for the browser to come back from it.
  String? _page;

  @override
  void initState() {
    super.initState();
    widget.network.addListener(_changed);
  }

  @override
  void dispose() {
    widget.network.removeListener(_changed);
    // Left without finishing: stop listening for the browser.
    if (widget.network.state == InboxState.signingIn) widget.network.cancel();
    super.dispose();
  }

  /// The sign-in this screen started went through: says so and leaves.
  void _changed() {
    if (!mounted || _page == null || widget.network.state != InboxState.ready) return;
    _page = null;
    toast(context, 'Signed in to Google Chat as ${widget.network.account}');
    Navigator.of(context).maybePop();
  }

  Future<void> _begin() async {
    final page = await widget.network.begin();
    if (page == null || !mounted) return;
    setState(() => _page = page);
    await Sms.instance.openLink(page);
  }

  Future<void> _cancel() async {
    await widget.network.cancel();
    if (mounted) setState(() => _page = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = widget.network;
    return ListenableBuilder(
      listenable: n,
      builder: (context, _) {
        final waiting = n.state == InboxState.signingIn && _page != null;
        return GhostPage(
          title: 'Sign in to Google Chat',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
              children: [
                PaneSection(
                  title: waiting ? 'Waiting for Google' : 'Your Google account',
                  description: Text(waiting
                      ? 'Allow Uplink on Google\'s page in your browser. Uplink carries on here by itself once you have.'
                      : 'Google Chat works here with Google Workspace accounts (work or school), not personal Gmail accounts. Google\'s own page opens in your browser to let Uplink read and send your chats. Your organisation\'s admin may need to allow Uplink first.'),
                  footer: n.error == null ? null : Text(n.error!, style: TextStyle(color: t.danger)),
                  children: [
                    if (n.state == InboxState.unavailable)
                      const SettingRow(label: 'Not available in this build', disabled: true)
                    else if (!waiting)
                      SettingRow(icon: AppIcon(Lucide.arrowRight, size: 18), label: 'Sign in with Google', onPress: _begin)
                    else ...[
                      SettingRow(icon: AppIcon(Lucide.externalLink, size: 18), label: 'Open Google\'s page again', onPress: () => Sms.instance.openLink(_page!)),
                      SettingRow(icon: AppIcon(Lucide.x, size: 18), label: 'Cancel', onPress: _cancel),
                    ],
                  ],
                ),
                SizedBox(height: t.space(4)),
                const SettingsFootnote(child: Tr('Your messages go between this device and Google only. Uplink\'s servers never see them; only the sign-in Google gives back is kept on this device.')),
              ],
            ),
          ),
        );
      },
    );
  }
}
