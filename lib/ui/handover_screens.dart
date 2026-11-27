/// Signing in on a new device by scanning its code with a phone already signed in (GMFB-45, Matt: "It would be nice to
/// be able to scan a QR code on desktop with my mobile phone to login"; lib/account/handover.dart is how). Two
/// screens: the new device's code and digits ([HandoverCodePanel], a tab of the sign-in screen), and the phone's
/// ([HandoverApproveScreen]: scan, compare the six digits, pass the phone's own lock, hand the account over).
library;

import 'dart:async';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../account/account.dart';
import '../account/handover.dart';
import '../account/handover_hub.dart';
import '../app_lock/app_lock.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../desktop/ui/qr.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../net/net.dart' show Net;
import '../sms.dart';
import 'app_lock_ui.dart' show PinPad;
import 'common.dart';
import 'computers.dart' show PairButton, PairingCode, relayHost;
import '../l10n/words.dart';

/// A step's heading: an icon (or the spinner while something is waited for), what is happening, a sentence under it.
class _Lead extends StatelessWidget {
  const _Lead({required this.icon, required this.title, required this.body, this.busy = false});
  final LucideIcon icon;
  final String title;
  final String body;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(2)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: busy ? const GhostSpinner(size: 22) : AppIcon(icon, size: 22, color: t.color('app-ink'))),
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'), height: 1.25)),
            SizedBox(height: t.space(1)),
            Text(body, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45)),
          ]),
        ),
      ]),
    );
  }
}

List<Widget> _spaced(Tokens t, List<Widget> children) => [
      for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: t.space(4)), children[i]],
    ];

// --- the new device -------------------------------------------------------------------------------------------------------

/// The new device's side, on its sign-in screen: a code for the phone to scan, then the six digits to compare. The
/// code holds nothing of any account. It is made as this is shown and gone as it is left: the room is left, and the
/// key and the secret are let go. A code nobody scanned in two minutes is replaced by a new one.
class HandoverCodePanel extends StatefulWidget {
  const HandoverCodePanel({super.key, required this.onWords, this.onFresh, this.busy = false, this.problem, this.room, this.relay, this.now});

  /// A new code was asked for after a problem: [problem] is the caller's to clear.
  final VoidCallback? onFresh;

  /// Given the recovery words the phone handed over, once, to sign in with. Kept nowhere here.
  final void Function(List<String> words) onWords;

  /// The account is being opened with what came; and what went wrong with that, if anything did.
  final bool busy;
  final String? problem;

  /// For a test: the room in the relay's place, the relay's address, the clock.
  final HandoverRoom Function()? room;
  final String? relay;
  final DateTime Function()? now;

  @override
  State<HandoverCodePanel> createState() => _HandoverCodePanelState();
}

class _HandoverCodePanelState extends State<HandoverCodePanel> {
  HandoverNewDevice? _end;

  @override
  void initState() {
    super.initState();
    _fresh();
  }

  @override
  void dispose() {
    _end?.onChange = null;
    _end?.close();
    _end = null;
    super.dispose();
  }

  /// A new code in the old one's place.
  void _fresh() {
    _end?.onChange = null;
    _end?.close();
    final end = _end = HandoverNewDevice(room: (widget.room ?? HubHandoverRoom.new)(), relay: widget.relay ?? Net.instance.hubUrl, onWords: widget.onWords, now: widget.now);
    var answered = false;
    end.onChange = () {
      if (!mounted || !identical(_end, end)) return;
      if (end.phase == HandoverPhase.compare) answered = true;
      // Nobody scanned it in time: a new one, so the screen can be left open while the phone is fetched.
      if (end.phase == HandoverPhase.expired && !answered) {
        _fresh();
        return;
      }
      setState(() {});
    };
    unawaited(end.start());
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final end = _end;
    final code = end?.codeText;
    final problem = widget.problem;
    final again = PairButton(
      label: 'Show a new code',
      icon: Lucide.rotateCcw,
      quiet: true,
      onPressed: () {
        widget.onFresh?.call();
        _fresh();
      },
    );
    final List<Widget> children;
    if (widget.busy) {
      children = [const _Lead(icon: Lucide.keyRound, title: 'Opening your account', body: 'Your phone handed it over. A moment.', busy: true)];
    } else if (problem != null) {
      children = [_Lead(icon: Lucide.triangleAlert, title: 'Not signed in', body: problem), again];
    } else {
      children = switch (end?.phase) {
        HandoverPhase.waiting when code != null => [
            const _Lead(
              icon: LucideMore.qrCode,
              title: 'Scan this with your phone',
              body: 'On an Android phone signed in to your account, open Uplink, then Settings › Me › Sign in a new device, and point it at this code. The code holds nothing of your account.',
            ),
            Center(child: QrView(key: const ValueKey('handover-qr'), data: code, size: 240, label: 'The sign-in code, as a QR code')),
          ],
        HandoverPhase.compare => [
            const _Lead(icon: Lucide.shieldCheck, title: 'Does your phone show the same six digits?', body: 'If it does, say so on the phone. If it doesn\'t, say no there: someone may be in the middle.'),
            PairingCode(code: end?.digits ?? ''),
            const _Lead(icon: Lucide.hourglass, title: 'Waiting for your phone', body: 'It asks for its lock, then signs this device in.', busy: true),
          ],
        HandoverPhase.done => [const _Lead(icon: Lucide.keyRound, title: 'Opening your account', body: 'Your phone handed it over. A moment.', busy: true)],
        HandoverPhase.expired => [const _Lead(icon: Lucide.hourglass, title: 'That code ran out', body: 'A code is good for two minutes.'), again],
        HandoverPhase.refused => [const _Lead(icon: Lucide.x, title: 'Your phone said no', body: 'Nothing was signed in.'), again],
        HandoverPhase.failed => [
            const _Lead(icon: Lucide.triangleAlert, title: 'That did not look right', body: 'More than one phone answered this code, or what came was changed on the way. Nothing was taken, and the code is good for nothing now.'),
            again,
          ],
        HandoverPhase.unreachable => [const _Lead(icon: Lucide.triangleAlert, title: 'The relay server can\'t be reached', body: 'Check this device is online, then try again. Your username and password, or your recovery words, work here too.'), again],
        _ => [const _Lead(icon: LucideMore.qrCode, title: 'Making a code', body: 'A moment.', busy: true)],
      };
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: _spaced(t, children));
  }
}

// --- the phone -----------------------------------------------------------------------------------------------------------

/// What a pairing code for a computer starts with (android/.../DeskCrypto.kt): the camera reads those too, and one
/// scanned here is said to belong in Settings › Computers.
bool _isPairingCode(String text) => text.trim().startsWith('GHOSTPAIR1:') || text.trim().toLowerCase().startsWith('ghostmsg://pair/');

/// The phone's side: scan the new device's code, compare the six digits, pass this phone's own lock, and hand the
/// account's recovery words to the new device, sealed to the key in its code.
///
/// The lock asked before anything is sent (Matt, 2026-11-23: "Words, behind phone lock"):
/// - the app's lock where one is set (GMFB-46): its fingerprint or face where that is switched on, otherwise, or where
///   that is put away, its PIN;
/// - with no app lock, the phone's fingerprint or face where it has one;
/// - with neither, or where the fingerprint was put away, the account's password, which opens the words as "Show
///   recovery words" does. Nothing is handed over by a phone that could ask nothing.
class HandoverApproveScreen extends StatefulWidget {
  const HandoverApproveScreen({super.key, this.code, this.room, this.lock, this.account, this.relay, this.scan, this.now});

  /// A code already read (the scanner in Settings › Computers read a sign-in code); null to scan one now.
  final String? code;

  /// For a test: the room in the relay's place, the lock, the account, the relay's address, the camera, the clock.
  final HandoverRoom Function()? room;
  final AppLock? lock;
  final Account? account;
  final String? relay;
  final Future<({String? text, bool denied})> Function()? scan;
  final DateTime Function()? now;

  @override
  State<HandoverApproveScreen> createState() => _HandoverApproveScreenState();
}

class _HandoverApproveScreenState extends State<HandoverApproveScreen> {
  HandoverPhone? _end;

  /// What is asked in the digits' place once the person said they match: nothing, the app's PIN, or the password.
  String _asking = '';
  bool _busy = false;
  String? _problem;
  final _password = TextEditingController();

  AppLock get _lock => widget.lock ?? AppLock.instance;
  Account get _account => widget.account ?? Account.instance;

  @override
  void initState() {
    super.initState();
    final code = widget.code;
    if (code != null) {
      _begin(code);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_scan()));
    }
  }

  @override
  void dispose() {
    _drop();
    _password.dispose();
    super.dispose();
  }

  // Left before the words went: the new device is told no.
  void _drop() {
    _end?.onChange = null;
    _end?.close();
    _end = null;
  }

  Future<void> _scan() async {
    _drop();
    setState(() {
      _asking = '';
      _problem = null;
    });
    final ({String? text, bool denied}) r;
    try {
      r = await (widget.scan ?? Sms.instance.scanPairingCode)();
    } catch (_) {
      if (mounted) setState(() => _problem = 'The camera could not be opened.');
      return;
    }
    if (!mounted) return;
    if (r.denied) {
      setState(() => _problem = 'The camera was refused. Allow it on Android\'s page for the app, then try again.');
      return;
    }
    final text = r.text;
    if (text == null) {
      // The camera was left with nothing read: back to where this was opened from, unless something is to be said.
      if (_problem == null && _end == null) Navigator.of(context).maybePop();
      return;
    }
    _begin(text);
  }

  void _begin(String text) {
    // A phone signed in to nothing has no account to hand over (the scanner in Settings › Computers is there for it too).
    if (!_account.signedIn) {
      _problem = 'This phone isn\'t signed in to an Uplink account, so it has none to sign a new device in to.';
      if (mounted) setState(() {});
      return;
    }
    final code = HandoverCode.parse(text);
    if (code == null) {
      _problem = _isPairingCode(text) ? 'That code pairs a computer with this phone\'s texts. Scan it from Settings › Computers instead.' : 'That isn\'t a sign-in code from Uplink.';
      if (mounted) setState(() {});
      return;
    }
    final end = _end = HandoverPhone(room: (widget.room ?? HubHandoverRoom.new)(), code: code, relay: widget.relay ?? Net.instance.hubUrl, now: widget.now);
    end.onChange = () {
      if (mounted && identical(_end, end)) setState(() {});
    };
    unawaited(end.start());
  }

  /// "They match": the phone's lock, then the words.
  Future<void> _yes() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final lock = _lock;
      // The fingerprint or face: the app lock's where it is switched on there, the phone's where no app lock is set.
      if ((lock.isSet ? lock.biometric : true) && await lock.askCanBiometric()) {
        if (await lock.askBiometric('Sign in your new device')) {
          await _hand();
          return;
        }
      }
      if (mounted) setState(() => _asking = lock.isSet ? 'pin' : 'password');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pin(String pin) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      if (await _lock.check(pin)) {
        await _hand();
      } else if (mounted) {
        final wait = _lock.wait;
        setState(() => _problem = wait > Duration.zero ? 'That PIN isn\'t right. Try again in ${AppLock.waitWords(wait)}.' : 'That PIN isn\'t right.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withPassword() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final words = await _account.revealWords(_password.text);
      _password.clear();
      _send(words);
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'That did not work.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The lock was passed: the words kept on this phone go to the new device. Where none are kept here, the password
  /// opens them.
  Future<void> _hand() async {
    final words = await _account.wordsForNewDevice();
    if (!mounted) return;
    if (words == null) {
      setState(() => _asking = 'password');
      return;
    }
    _send(words);
  }

  void _send(List<String> words) {
    final end = _end;
    if (end == null || !mounted) return;
    if (!end.approve(words)) {
      setState(() => _problem = end.phase == HandoverPhase.expired ? null : 'That did not go. Show a new code on the new device and scan it again.');
      return;
    }
    setState(() => _asking = '');
  }

  void _no() {
    _end?.refuse();
    if (mounted) setState(() => _asking = '');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final end = _end;
    final problem = _problem;
    final scanAgain = PairButton(label: 'Scan again', icon: LucideMore.qrCode, onPressed: _scan);
    final done = PairButton(label: 'Done', icon: Lucide.check, onPressed: () => Navigator.of(context).maybePop());
    final List<Widget> children;
    if (end == null) {
      children = problem != null
          ? [_Lead(icon: Lucide.triangleAlert, title: 'That can\'t be used here', body: problem), scanAgain]
          : [const _Lead(icon: LucideMore.qrCode, title: 'Scan the code on the new device', body: 'It is on its sign-in screen, under Phone.', busy: true)];
    } else {
      children = switch (end.phase) {
        HandoverPhase.starting || HandoverPhase.waiting => [
            const _Lead(icon: Lucide.laptop, title: 'Reaching the new device', body: 'Keep its sign-in screen open.', busy: true),
            PairButton(label: 'Cancel', icon: Lucide.x, quiet: true, onPressed: () => Navigator.of(context).maybePop()),
          ],
        HandoverPhase.compare when _asking == 'pin' => [
            const _Lead(icon: Lucide.lock, title: 'Your PIN first', body: 'The one that unlocks Uplink on this phone.'),
            if (problem != null) Text(problem, style: TextStyle(color: t.danger)),
            PinPad(onSubmit: _pin, enabled: !_busy && _lock.wait <= Duration.zero, submitLabel: 'Sign it in', submitIcon: Lucide.check),
            PairButton(label: 'Cancel', icon: Lucide.x, quiet: true, onPressed: _no),
          ],
        HandoverPhase.compare when _asking == 'password' => [
            const _Lead(icon: Lucide.lock, title: 'Your password first', body: 'This phone has no lock to ask, so your account\'s password shows it is you.'),
            PaneSection(
              title: 'Your password',
              footer: problem == null ? const SizedBox.shrink() : Text(problem, style: TextStyle(color: t.danger)),
              children: [
                SettingRowBox(
                  child: GlacierInput(controller: _password, placeholder: 'Password'.t, ariaLabel: 'Password', type: GlacierInputType.password, autoCorrect: false, autoCapitalize: TextCapitalization.none, autoComplete: 'current-password', size: GlacierFieldSize.md, onSubmitted: (_) => _withPassword()),
                ),
              ],
            ),
            PairButton(label: _busy ? 'Checking…' : 'Sign it in', icon: Lucide.check, onPressed: _busy ? null : _withPassword),
            PairButton(label: 'Cancel', icon: Lucide.x, quiet: true, onPressed: _no),
          ],
        HandoverPhase.compare => [
            const _Lead(icon: Lucide.shieldCheck, title: 'Does the new device show the same six digits?', body: 'They are made from the key the two just agreed on. The same on both means nobody is in the middle.'),
            PairingCode(code: end.digits ?? ''),
            SettingsCallout(
              icon: const AppIcon(Lucide.triangleAlert, size: 18),
              child: const Tr('Saying yes signs that device in as you, with everything of your account. Only do it for a device in front of you that you are setting up yourself. Never for a code someone else shows you or sends you, whoever they say they are.'),
            ),
            if (problem != null) Text(problem, style: TextStyle(color: t.danger)),
            PairButton(key: const ValueKey('handover-yes'), label: 'They match, sign it in', icon: Lucide.check, onPressed: _busy ? null : _yes),
            PairButton(key: const ValueKey('handover-no'), label: 'They don\'t match', icon: Lucide.x, quiet: true, onPressed: _no),
          ],
        HandoverPhase.sent || HandoverPhase.done => [
            _Lead(
              icon: Lucide.circleCheck,
              title: end.phase == HandoverPhase.done ? 'Handed over' : 'Sent',
              body: 'The new device is signing in to your account. It is listed under Settings › Me › Signed in on these devices, where you can remove it.',
            ),
            done,
          ],
        HandoverPhase.expired => [const _Lead(icon: Lucide.hourglass, title: 'That code ran out', body: 'A code is good for two minutes. Nothing was sent. The new device shows a new one.'), scanAgain],
        HandoverPhase.refused => [const _Lead(icon: Lucide.x, title: 'Nothing was sent', body: 'The new device was not signed in. If the digits were different, show a new code on it and scan again.'), scanAgain, done],
        HandoverPhase.failed => [const _Lead(icon: Lucide.triangleAlert, title: 'That code could not be used', body: 'Nothing was sent. Show a new code on the new device and scan it again.'), scanAgain],
        HandoverPhase.unreachable => [
            _Lead(
              icon: Lucide.triangleAlert,
              title: end.otherRelay != null ? 'That device is on another relay' : 'The relay server can\'t be reached',
              body: end.otherRelay != null
                  ? 'It uses ${relayHost(end.otherRelay!)}, and your account is on ${relayHost(widget.relay ?? Net.instance.hubUrl)}. Choose your relay on the new device first (Settings › Routes), then scan its new code.'
                  : 'Check this phone is online, then scan again.',
            ),
            scanAgain,
          ],
      };
    }
    return GhostPage(
      title: 'Sign in a new device',
      actions: [docsButton('account')],
      body: ListView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: _spaced(t, children),
      ),
    );
  }
}
