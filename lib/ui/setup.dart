import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_type.dart';
import '../app_state.dart';
import '../sms.dart';
import 'rcs_setup.dart';
import '../kit/semantic_colors.dart';

/// The walkthrough's "your texts" step (lib/onboarding/onboarding.dart): Android lets only the default SMS app send
/// and keep texts, so the one thing to do is choose Uplink, or use it beside Google Messages.
///
/// Before that, what catches people coming from Google Messages or Samsung Messages (android/.../Arriving.kt; Matt,
/// 2026-11-13, of a friend whose chats "didn't load" and whose texts stopped arriving: "can you detect this somehow
/// and then instruct the user how to fix it?"): their RCS chats stay in that app, and while RCS is on there, people
/// who use it go on sending chats that never arrive as texts. The screen names the app being left and leads to its
/// settings to turn RCS chats off first. And where Android refuses the switch to a copy from outside a store, it
/// leads to Android's page for the app, where "Allow restricted settings" is.
class TextsStep extends StatefulWidget {
  const TextsStep({super.key, required this.hue, required this.onDone});

  /// The page's colour, which its one filled button wears.
  final Color hue;

  /// Uplink can send and receive texts now: the default, or beside Google Messages.
  final VoidCallback onDone;

  @override
  State<TextsStep> createState() => _TextsStepState();
}

class _TextsStepState extends State<TextsStep> with WidgetsBindingObserver {
  bool _asking = false;
  bool _declined = false;
  Arriving _arriving = const Arriving();

  /// Beside Google Messages (android GmBridge.kt): what has been allowed so far.
  SmsStatus? _status;

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

  /// Back from the old app's settings, or Android's page for this one.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _look();
  }

  /// Asks the phone how texts arrive now and what has been allowed; done at the start and at every return to the app.
  Future<void> _look() async {
    try {
      final a = await Sms.instance.arriving();
      if (mounted) setState(() => _arriving = a);
    } catch (_) {}
    try {
      final s = await Sms.instance.status();
      if (!mounted) return;
      setState(() => _status = s);
      // Both allowed (back from Android's notification access page): the app opens beside Google Messages.
      if (s.beside) widget.onDone();
    } catch (_) {}
  }

  /// Beside Google Messages, step by step: texts first, then notification access, which Android's own page grants.
  Future<void> _beside() async {
    var s = _status ?? await Sms.instance.status();
    if (!s.sms) s = await Sms.instance.requestSms();
    if (!mounted) return;
    setState(() => _status = s);
    if (!s.sms) return;
    if (!s.bridge) {
      await Sms.instance.openBridgeAccess();
      return; // Back here when Android's page is left (_look).
    }
    await Sms.instance.requestPermissions();
    await _look();
    widget.onDone();
  }

  /// Asks Android to make Uplink the default texting app; a no is remembered so the page can say what to do next.
  Future<void> _go() async {
    setState(() => _asking = true);
    final ok = await Sms.instance.requestDefault();
    if (ok) {
      await _look();
      if (mounted) setState(() => _asking = false);
      widget.onDone();
    } else if (mounted) {
      setState(() { _asking = false; _declined = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final a = _arriving;
    final s = _status;
    // Done: what it is now, in the page's colour.
    if (s != null && s.usable) {
      return Row(children: [
        AppIcon(Lucide.circleCheck, size: 20, color: widget.hue),
        SizedBox(width: t.space(2)),
        Expanded(child: Text(s.isDefault ? 'Uplink is your texting app.' : 'Uplink is working beside Google Messages.', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink')))),
      ]);
    }
    // Setting up RCS from Settings, Google Messages made the default on the way: the same steps carried on here
    // (lib/ui/rcs_setup.dart), and this step is done once Uplink is beside it.
    if (AppState.of(context).flag('rcs_setup', fallback: false)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text('Finish setting up RCS', style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
        SizedBox(height: t.space(3)),
        RcsSteps(onDone: widget.onDone),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (a.rcsLikely) ...[
        _Card(
          icon: Lucide.triangleAlert,
          title: 'Coming from ${a.app}? Do this first',
          children: [
            _Step(number: '1', text: 'Turn off RCS chats in ${a.app}. In its settings, open RCS chats and switch it off. Leave it on, and texts from people who use RCS keep going there and won\'t reach you here.'),
            _Step(number: '2', text: 'Your RCS chats stay in ${a.app}. Android keeps them where no other app can read them, so they won\'t appear here. They are not deleted: they are there again if you switch back. Texts and picture messages (SMS and MMS) all appear here.'),
            SizedBox(height: t.space(2)),
            _Button(label: 'Open ${a.app} settings', onPressed: () => Sms.instance.openOldApp()),
          ],
        ),
        SizedBox(height: t.space(5)),
      ],
      // The one filled button: the switch itself, in the page's colour.
      GlacierPressable(
        onPressed: _asking ? null : _go,
        semanticLabel: 'Set as default SMS app',
        builder: (context, state) => AnimatedScale(
          scale: state.pressed ? 0.97 : 1,
          duration: const Duration(milliseconds: 120),
          child: Container(
            height: t.lenOf('2.9rem'),
            decoration: ShapeDecoration(color: widget.hue, shape: const StadiumBorder()),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const AppIcon(Lucide.messageSquare, size: 16, strokeWidth: 2.3, color: Color(0xFFFFFFFF), wash: false),
              SizedBox(width: t.space(2)),
              Text(_asking ? 'Waiting for Android…' : (_declined ? 'Try again' : 'Set as default SMS app'), style: pageText(t, t.fontSize('md'), weight: 'semibold', color: const Color(0xFFFFFFFF))),
            ]),
          ),
        ),
      ),
      SizedBox(height: t.space(3)),
      _Point(icon: Lucide.rotateCcw, text: 'Change your mind any time in Android\'s Settings › Apps › Default apps. Nothing is deleted either way.'),
      SizedBox(height: t.space(3)),
      // Or keep Google Messages, and its RCS (Matt, 2026-11-15: "I'd like to have a way that people can reliably
      // get text in and out of ghost without needing to switch the default messaging app").
      if (_status?.gmInstalled == true) ...[
        _Card(
          icon: Lucide.link,
          title: 'Or keep Google Messages, and RCS',
          children: [
            Text(
              'Uplink can work beside Google Messages instead. Your texts are read from Android, RCS chats come in through Google Messages\' notifications, and replies go back through it, as RCS where the chat is RCS.',
              style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45),
            ),
            SizedBox(height: t.space(3)),
            _Step(number: _status?.sms == true ? '✓' : '1', text: 'Allow Uplink to read and send texts.'),
            _Step(number: _status?.bridge == true ? '✓' : '2', text: 'Allow notification access, so Uplink can read Google Messages\' notifications. Only Google Messages\' are read; every other app\'s are ignored.'),
            Text(
              'What it can\'t do: chats muted in Google Messages, or open there when a message comes, aren\'t seen. RCS chats from before aren\'t brought over, and pictures in RCS chats stay in Google Messages.',
              style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.45),
            ),
            // A copy from outside a store: Android greys out notification access until it is allowed.
            if (a.sideloaded && _status?.bridge != true) ...[
              SizedBox(height: t.space(2)),
              Text(
                'If Android says notification access is a restricted setting, open Android\'s page for Uplink, tap ⋮ at the top, choose Allow restricted settings, then come back and try again.',
                style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.45),
              ),
              SizedBox(height: t.space(2)),
              _Button(label: 'Open Android\'s page for Uplink', onPressed: () => Sms.instance.openAppInfo()),
            ],
            SizedBox(height: t.space(3)),
            _Button(label: 'Use beside Google Messages', onPressed: _beside),
          ],
        ),
        SizedBox(height: t.space(5)),
      ],
      _Point(icon: Lucide.rotateCcw, text: 'Change your mind any time in Android\'s Settings › Apps › Default apps. Nothing is deleted either way.'),
      if (_declined) ...[
        SizedBox(height: t.space(3)),
        _Card(
          icon: Lucide.circleAlert,
          danger: true,
          title: 'Uplink isn\'t the default yet',
          children: [
            Text(
              a.sideloaded
                  ? 'If Android said the setting is restricted or unavailable, that is because this copy didn\'t come from the Play Store. Open Android\'s page for Uplink, tap ⋮ at the top, choose Allow restricted settings, then come back and try again.'
                  : 'Android only lets the default app send and receive texts. Try again, and choose Uplink when Android asks.',
              style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45),
            ),
            if (a.sideloaded) ...[
              SizedBox(height: t.space(3)),
              _Button(label: 'Open Android\'s page for Uplink', onPressed: () => Sms.instance.openAppInfo()),
            ],
          ],
        ),
      ],
    ]);
  }
}

/// A boxed note with a heading: what to do before switching, or why the switch did not happen.
class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.children, this.danger = false});
  final LucideIcon icon;
  final String title;
  final List<Widget> children;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = danger ? t.danger : t.color('app-ink');
    return Container(
      padding: EdgeInsets.all(t.space(4)),
      decoration: BoxDecoration(
        color: t.color('app-paper-2'),
        borderRadius: BorderRadius.circular(t.radius('lg')),
        border: Border.all(color: danger ? ink : t.color('app-rule')),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AppIcon(icon, size: 18, color: ink)),
          SizedBox(width: t.space(2)),
          Expanded(child: Text(title, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: ink))),
        ]),
        SizedBox(height: t.space(3)),
        ...children,
      ]),
    );
  }
}

/// One numbered instruction: the number in a filled circle, the words beside it.
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});
  final String number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(3)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: t.lenOf('1.4rem'),
          height: t.lenOf('1.4rem'),
          decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('app-ink')),
          alignment: Alignment.center,
          child: Text(number, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-paper'))),
        ),
        SizedBox(width: t.space(3)),
        Expanded(child: Text(text, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45))),
      ]),
    );
  }
}

/// A second-rank button: an outline, where the screen's one filled button is the switch itself.
class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        constraints: BoxConstraints(minHeight: t.lenOf('2.75rem')),
        padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
        decoration: BoxDecoration(
          color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
          borderRadius: BorderRadius.circular(t.radius('md')),
          border: Border.all(color: t.color('app-ink-3')),
        ),
        alignment: Alignment.center,
        child: Text(label, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
      ),
    );
  }
}

/// One point made with an icon in place of a number.
class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.text});
  final LucideIcon icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(3)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: AppIcon(icon, size: 18, color: t.color('app-ink-2'))),
        SizedBox(width: t.space(3)),
        Expanded(child: Text(text, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45))),
      ]),
    );
  }
}
