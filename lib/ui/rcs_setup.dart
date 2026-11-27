import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import 'common.dart';
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

/// Setting up RCS, step by step (Matt, 2026-11-15: "add a button under messages settings to setup RCS if on an
/// android phone and walk the user through how to enable the rcs sidecar"; and "we should have a way to make the app
/// work without needing to be the default sms app so it can work in tandem and I can turn off notifications from
/// google messages or hide them and proxy everything through ghost").
///
/// RCS runs only inside Google Messages, so it becomes the default SMS app again and Uplink works beside it
/// (android GmBridge.kt): texts read from Android, RCS chats from Google Messages' notifications, which Uplink hides and
/// shows its own in their place. Once Google Messages is the default, Android takes Uplink's SMS permissions back and
/// the app opens on its first screen; that screen carries on with these same steps (lib/ui/setup.dart, `rcs_setup`).
class RcsSetupScreen extends StatelessWidget {
  const RcsSetupScreen({super.key});

  @override
  Widget build(BuildContext context) => GhostPage(
        title: 'Set up RCS',
        body: ListView(padding: EdgeInsetsDirectional.fromSTEB(context.tokens.space(4), 0, context.tokens.space(4), context.tokens.space(10)), children: const [RcsSteps()]),
      );
}

/// The steps, each ticked as Android says it is done: read again whenever the app comes back to the front.
class RcsSteps extends StatefulWidget {
  const RcsSteps({super.key, this.onDone});

  /// Called once Uplink is beside Google Messages (the first screen opens the app then).
  final VoidCallback? onDone;

  @override
  State<RcsSteps> createState() => _RcsStepsState();
}

class _RcsStepsState extends State<RcsSteps> with WidgetsBindingObserver {
  SmsStatus? _s;
  Arriving _arriving = const Arriving();

  /// Google Messages' channels as last seen: the ones still loud are listed in the last step.
  List<GmChannel> _channels = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _look();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _look();
  }

  /// Reads from Android how far the steps have got; once Uplink is beside Google Messages the setup is over.
  Future<void> _look() async {
    try {
      final s = await Sms.instance.status();
      final a = await Sms.instance.arriving();
      var channels = const <GmChannel>[];
      try {
        channels = await Sms.instance.gmChannels();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _s = s;
        _arriving = a;
        _channels = channels;
      });
      if (s.beside) {
        // Done: the first screen need not carry it on any more.
        AppState.of(context).setFlag('rcs_setup', false);
        widget.onDone?.call();
      }
    } catch (_) {}
  }

  Future<void> _texts() async {
    final s = await Sms.instance.requestSms();
    if (mounted) setState(() => _s = s);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.of(context);
    final s = _s;
    if (s == null) return const SizedBox.shrink();
    final rcsOn = app.flag('rcs_on_chosen', fallback: false);
    // Silent as far as Uplink has seen (every channel a notification came on is quiet), or said so by the person.
    final loud = [for (final c in _channels) if (c.loud) c];
    final silent = (_channels.isNotEmpty && loud.isEmpty) || (loud.isEmpty && app.flag('gm_silent_chosen', fallback: false));
    final done = [s.gmInstalled, s.gmDefault, rcsOn, s.sms, s.bridge, silent];
    final next = done.indexOf(false);
    Widget step(int i, String title, String what, {String? action, VoidCallback? onAction, String? also, VoidCallback? onAlso, Widget? more}) {
      final ok = done[i];
      final current = i == next;
      return Container(
        margin: EdgeInsets.only(bottom: t.space(3)),
        padding: EdgeInsets.all(t.space(4)),
        decoration: BoxDecoration(
          color: t.color('app-paper-2'),
          borderRadius: BorderRadius.circular(t.radius('lg')),
          border: Border.all(color: current ? t.color('app-ink') : t.color('app-rule'), width: current ? 1.5 : 1),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: t.lenOf('1.6rem'),
            height: t.lenOf('1.6rem'),
            decoration: BoxDecoration(shape: BoxShape.circle, color: ok ? t.online : (current ? t.color('app-ink') : t.color('app-paper-3'))),
            alignment: Alignment.center,
            child: ok
                ? const AppIcon(Lucide.check, size: 14, wash: false, color: Color(0xFFFFFFFF))
                : Text('${i + 1}', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: current ? t.color('app-paper') : t.color('app-ink-3'))),
          ),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ok ? t.color('app-ink-3') : t.color('app-ink'))),
              if (!ok || current) ...[
                SizedBox(height: t.space(1)),
                Text(what, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45)),
              ],
              ?more,
              if (!ok && (action != null || also != null)) ...[
                SizedBox(height: t.space(3)),
                Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                  if (action != null) _Pill(label: action, filled: current, onPressed: onAction!),
                  if (also != null) _Pill(label: also, filled: false, onPressed: onAlso!),
                ]),
              ],
            ]),
          ),
        ]),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.only(bottom: t.space(4)),
        child: Text(
          'RCS (typing dots, read receipts, full-size pictures, group chats over the internet) runs only inside Google Messages. Uplink works beside it: Google Messages stays the default and does the sending, and you use Uplink. Its notifications are hidden and Uplink shows its own.',
          style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45),
        ),
      ),
      step(0, 'Google Messages on this phone', 'Uplink uses it for RCS. It is free from the Play Store.', action: 'Get Google Messages', onAction: Sms.instance.openGm),
      step(1, 'Google Messages is the default SMS app', 'In Android\'s Default apps, open SMS app and choose Messages. Uplink opens on its first screen after this and carries on from here.',
          action: 'Open Default apps', onAction: () {
        app.setFlag('rcs_setup', true);
        Sms.instance.openDefaultApps();
      }),
      step(2, 'RCS chats are on in Google Messages', 'In Google Messages, tap your profile picture, then Messages settings, then RCS chats, and turn it on. It can take a few minutes to say Connected.',
          action: 'Open Google Messages', onAction: Sms.instance.openGm, also: 'It\'s on', onAlso: () => app.setFlag('rcs_on_chosen', true)),
      step(3, 'Uplink may read and send texts', 'Android asks. Uplink reads your texts from Android\'s own store and sends plain texts itself.', action: 'Allow', onAction: _texts),
      step(4, 'Uplink may read Google Messages\' notifications', 'That is how RCS chats reach Uplink. Only Google Messages\' are read; every other app\'s are ignored. Turn it on for Uplink.',
          action: 'Open notification access', onAction: Sms.instance.openBridgeAccess,
          more: _arriving.sideloaded && !s.bridge
              ? Padding(
                  padding: EdgeInsets.only(top: t.space(2)),
                  child: Text('If Android says it is a restricted setting: open Android\'s page for Uplink, tap ⋮, choose Allow restricted settings, then try again.',
                      style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.45)),
                )
              : null,
          also: _arriving.sideloaded && !s.bridge ? 'Android\'s page for Uplink' : null,
          onAlso: Sms.instance.openAppInfo),
      step(5, 'Google Messages\' notifications are silent', 'Leave them on, but set them to Silent: Uplink reads them, hides each one as it comes, and shows its own. Turned off completely, Uplink would see nothing. A conversation with its own sound in Google Messages needs silencing on its own too.',
          action: loud.isEmpty ? 'Open its notification settings' : null,
          onAction: Sms.instance.openGmNotifications,
          also: _channels.isEmpty ? 'They\'re silent' : null,
          onAlso: () => app.setFlag('gm_silent_chosen', true),
          more: loud.isEmpty
              ? null
              : Padding(
                  padding: EdgeInsets.only(top: t.space(3)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Still making a sound, as of their last message:', style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-2'))),
                    SizedBox(height: t.space(2)),
                    Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                      for (final c in loud) _Pill(label: 'Silence ${c.label}', filled: true, onPressed: () => Sms.instance.openGmChannel(c)),
                    ]),
                  ]),
                )),
      if (s.beside)
        SettingsCallout(child: const Tr('RCS is set up. Uplink shows every conversation, RCS and texts, and replies go through Google Messages.')),
      SizedBox(height: t.space(4)),
      Text('On your computer', style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
      SizedBox(height: t.space(1)),
      Text(
        'For full history, pictures and reactions on your Mac or Windows PC, open Uplink there, go to Settings › Google Messages, and scan the QR code it shows with Google Messages on this phone (profile picture › Device pairing › QR code scanner).',
        style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45),
      ),
    ]);
  }
}

/// A small rounded button on a step: [filled] for the one that carries the step on, outlined for a second choice.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.filled, required this.onPressed});
  final String label;
  final bool filled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
        decoration: BoxDecoration(
          color: filled ? t.color('app-ink').withValues(alpha: state.pressed ? 0.85 : 1) : (state.pressed ? t.color('app-paper-3') : const Color(0x00000000)),
          borderRadius: BorderRadius.circular(t.radius('full')),
          border: filled ? null : Border.all(color: t.color('app-ink-3')),
        ),
        child: Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: filled ? t.color('app-paper') : t.color('app-ink'))),
      ),
    );
  }
}
