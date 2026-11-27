import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../account/account.dart';
import '../app_lock/app_lock.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../platform_info.dart';
import '../sms.dart';
import '../voice/channels.dart';
import 'common.dart';
import 'computers.dart' show PairButton;
import 'window_chrome.dart';
import '../l10n/words.dart';

/// The app's lock on the screens (GMFB-46; lib/app_lock/app_lock.dart): [AppLockGate] stands over every page and draws
/// [AppLockScreen] in their place while the app is locked; [AppLockPane] is Settings › Lock the app.

/// Over the whole app (lib/main.dart, lib/desktop/main.dart): [child] as it is while the app is open, and while it is
/// locked the lock screen drawn over it, opaque, with [child] taking no touch, no key and no part in what a screen
/// reader says. [child] stays where it is in the tree, so a call going on goes on and the pages are as they were left.
///
/// It also tells [lock] when the app leaves the screen and comes back. With no PIN set (or [AppLock.load] never
/// called, as in a test of another screen) it is [child] and nothing else.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child, this.lock, this.dragStrip = false});
  final Widget child;

  /// The app's own ([AppLock.instance]) where not given.
  final AppLock? lock;

  /// A strip along the lock screen's top that moves the window: on a computer, where the pages' own are covered.
  final bool dragStrip;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  AppLock get _lock => widget.lock ?? AppLock.instance;
  late AppLock _heard;
  bool _was = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _heard = _lock..addListener(_changed);
    _was = _heard.locked;
  }

  @override
  void didUpdateWidget(AppLockGate old) {
    super.didUpdateWidget(old);
    if (identical(_heard, _lock)) return;
    _heard.removeListener(_changed);
    _heard.stopTimer();
    _heard = _lock..addListener(_changed);
    _was = _heard.locked;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heard.removeListener(_changed);
    _heard.stopTimer();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // Locked a moment ago: whatever was being typed into lets go, so the keyboard closes and keys go to the lock.
    if (_heard.locked && !_was) FocusManager.instance.primaryFocus?.unfocus();
    _was = _heard.locked;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final lock = _lock;
    switch (state) {
      case AppLifecycleState.resumed:
        lock.back();
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        lock.away();
      case AppLifecycleState.inactive:
        // A computer's window behind another one. On a phone this is the notification shade, a permission question or
        // the fingerprint prompt itself: the app is still what is on the screen.
        if (lock.desktop) lock.away(behind: true);
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _lock.locked;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        ExcludeFocus(
          excluding: locked,
          child: IgnorePointer(ignoring: locked, child: ExcludeSemantics(excluding: locked, child: widget.child)),
        ),
        if (locked) Positioned.fill(child: AppLockScreen(lock: _lock, dragStrip: widget.dragStrip)),
      ],
    );
  }
}

/// A row of dots for the digits typed and a number pad under it, with the keyboard's digits, Backspace and Enter
/// taken too. Nothing typed is ever drawn as a digit.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onSubmit, this.enabled = true, this.submitLabel = 'Unlock', this.submitIcon = Lucide.lock, this.corner});

  /// Given the digits when the button under the pad (or Enter) is pressed with four to eight typed; the pad is
  /// cleared first.
  final ValueChanged<String> onSubmit;

  /// False while a PIN is being checked or a wait runs: the keys take nothing.
  final bool enabled;
  final String submitLabel;
  final LucideIcon submitIcon;

  /// What stands at the pad's bottom left, beside the 0: the fingerprint's key on the lock screen.
  final Widget? corner;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  final _focus = FocusNode(debugLabel: 'pin pad');
  String _digits = '';

  @override
  void initState() {
    super.initState();
    // Asked for, not left to autofocus: over the app the pages under the lock hold the focus already, and autofocus
    // gives way to them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _digit(String d) {
    if (!widget.enabled || _digits.length >= 8) return;
    setState(() => _digits += d);
  }

  void _back() {
    if (!widget.enabled || _digits.isEmpty) return;
    setState(() => _digits = _digits.substring(0, _digits.length - 1));
  }

  void _submit() {
    if (!widget.enabled || !PinHash.valid(_digits)) return;
    final pin = _digits;
    setState(() => _digits = '');
    widget.onSubmit(pin);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.backspace) {
      _back();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    final c = event.character;
    if (c != null && c.length == 1 && '0123456789'.contains(c)) {
      _digit(c);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _keyOf(Tokens t, String label, {required Key key, required VoidCallback onPressed, Widget? face}) {
    final side = t.lenOf('4rem');
    return GlacierPressable(
      key: key,
      onPressed: widget.enabled ? onPressed : null,
      semanticLabel: label,
      // The pad's own focus keeps the keyboard: a key pressed takes none, or Enter would press it again.
      canRequestFocus: false,
      builder: (context, state) => Container(
        width: side,
        height: side,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: face != null ? const Color(0x00000000) : (state.pressed ? t.color('app-paper-3') : t.color('app-paper-2')),
          border: face != null ? null : Border.all(color: t.color('app-rule')),
        ),
        child: face ?? Text(label, style: pageText(t, t.fontSize('xl'), weight: 'medium', color: t.color('app-ink'))),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = SizedBox(width: t.space(4), height: t.space(3));
    final side = t.lenOf('4rem');
    Widget row(List<Widget> keys) => Row(mainAxisSize: MainAxisSize.min, children: [keys[0], gap, keys[1], gap, keys[2]]);
    Widget digit(String d) => _keyOf(t, d, key: ValueKey('pin-key-$d'), onPressed: () => _digit(d));
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.45,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Semantics(
            label: '${_digits.length} ${_digits.length == 1 ? 'digit' : 'digits'} typed',
            child: SizedBox(
              key: const ValueKey('pin-dots'),
              height: t.lenOf('1.5rem'),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                // Four to start with, since four are always asked for; more as more are typed.
                for (var i = 0; i < (_digits.length < 4 ? 4 : _digits.length); i++)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: t.space(1)),
                    child: Container(
                      width: t.lenOf('0.75rem'),
                      height: t.lenOf('0.75rem'),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _digits.length ? t.color('app-ink') : const Color(0x00000000),
                        border: Border.all(color: i < _digits.length ? t.color('app-ink') : t.color('app-ink-4')),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          SizedBox(height: t.space(5)),
          row([digit('1'), digit('2'), digit('3')]),
          gap,
          row([digit('4'), digit('5'), digit('6')]),
          gap,
          row([digit('7'), digit('8'), digit('9')]),
          gap,
          row([
            widget.corner ?? SizedBox(width: side, height: side),
            digit('0'),
            _keyOf(t, 'Delete the last digit', key: const ValueKey('pin-key-back'), onPressed: _back, face: AppIcon(Lucide.arrowLeft, size: 22, wash: false, color: t.color('app-ink-2'))),
          ]),
          SizedBox(height: t.space(5)),
          SizedBox(
            width: side * 3 + t.space(4) * 2,
            child: PairButton(key: const ValueKey('pin-submit'), label: widget.submitLabel, icon: widget.submitIcon, onPressed: widget.enabled && PinHash.valid(_digits) ? _submit : null),
          ),
        ]),
      ),
    );
  }
}

/// The lock screen: the PIN on a number pad, the fingerprint or face where that is on, how long to wait after wrong
/// tries, a call that is ringing or going on, and the way back in for someone who forgot the PIN. It shows nothing of
/// what is behind it.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.lock, this.dragStrip = false});
  final AppLock lock;
  final bool dragStrip;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  bool _busy = false;
  bool _wrong = false;

  /// The page for someone who forgot the PIN, in the pad's place; then its second question.
  bool _forgot = false;
  bool _sure = false;
  bool _deleting = false;
  String? _problem;

  /// Draws the wait's line again each second while one runs.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _watchWait();
    // The fingerprint or face is asked for as the lock comes up, once: put away, its key on the pad asks again.
    final state = WidgetsBinding.instance.lifecycleState;
    if (widget.lock.biometric && widget.lock.canBiometric && (state == null || state == AppLifecycleState.resumed)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_biometric()));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _watchWait() {
    if (widget.lock.wait <= Duration.zero || _tick != null) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.lock.wait <= Duration.zero) {
        _tick?.cancel();
        _tick = null;
      }
      setState(() {});
    });
  }

  Future<void> _try(String pin) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _wrong = false;
    });
    final right = await widget.lock.unlockWith(pin);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _wrong = !right;
    });
    _watchWait();
  }

  Future<void> _biometric() async {
    if (!mounted || _busy) return;
    await widget.lock.unlockWithBiometric();
  }

  /// Signs out and deletes everything this device keeps (Account.signOut with everything), where the app can: the
  /// lock goes with what it guarded. Where the app starts again by itself this never comes back.
  Future<void> _deleteAll() async {
    if (_deleting) return;
    setState(() {
      _deleting = true;
      _problem = null;
    });
    try {
      final again = await Account.instance.signOut(everything: true);
      // Still here (an iPhone, a computer that can't open itself again): the lock is gone with everything else, and
      // the page under it says to open the app again.
      if (!again) await widget.lock.remove();
    } catch (_) {
      if (mounted) {
        setState(() {
          _deleting = false;
          _problem = 'That didn\'t work. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final ground = t.color('glacier-bg').withValues(alpha: 1);
    return ColoredBox(
      color: ground,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: 'Uplink is locked',
        child: Stack(children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                padding: EdgeInsetsDirectional.fromSTEB(t.space(6), pad.top + t.space(6), t.space(6), pad.bottom + t.space(6)),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: (box.maxHeight - pad.vertical - t.space(6) * 2).clamp(0, double.infinity)),
                  child: Center(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: t.lenOf('24rem')), child: _forgot ? _forgotPage(t) : _padPage(t))),
                ),
              ),
            ),
          ),
          if (widget.dragStrip) const PositionedDirectional(start: 0, end: 0, top: 0, height: 40, child: WindowDragArea(child: SizedBox.expand())),
          PositionedDirectional(start: 0, end: 0, top: 0, child: _CallStrip(top: pad.top)),
        ]),
      ),
    );
  }

  Widget _padPage(Tokens t) {
    final lock = widget.lock;
    final wait = lock.wait;
    final waiting = wait > Duration.zero;
    final line = waiting
        ? 'Too many wrong tries. Try again in ${AppLock.waitWords(wait)}.'
        : _busy
            ? 'Checking…'
            : _wrong
                ? 'Wrong PIN. Try again.'
                : 'Enter your PIN';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AppIcon(Lucide.lock, size: 28, wash: false, color: t.color('app-ink')),
      SizedBox(height: t.space(3)),
      Text('Uplink is locked', textAlign: TextAlign.center, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
      SizedBox(height: t.space(2)),
      Text(line, key: const ValueKey('lock-line'), textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: waiting || _wrong ? t.danger : t.color('app-ink-2'), height: 1.4)),
      SizedBox(height: t.space(5)),
      PinPad(
        enabled: !_busy && !waiting,
        onSubmit: _try,
        corner: lock.biometric && lock.canBiometric
            ? GlacierPressable(
                key: const ValueKey('lock-biometric'),
                onPressed: _biometric,
                semanticLabel: 'Unlock with fingerprint or face',
                canRequestFocus: false,
                builder: (context, state) => SizedBox(
                  width: t.lenOf('4rem'),
                  height: t.lenOf('4rem'),
                  child: Center(child: AppIcon(Lucide.shieldCheck, size: 24, wash: false, color: t.color('app-ink-2'))),
                ),
              )
            : null,
      ),
      SizedBox(height: t.space(4)),
      GlacierPressable(
        key: const ValueKey('lock-forgot'),
        onPressed: () => setState(() => _forgot = true),
        semanticLabel: 'Forgot your PIN?',
        canRequestFocus: false,
        builder: (context, state) => Padding(
          padding: EdgeInsets.all(t.space(2)),
          child: Text('Forgot your PIN?', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')).copyWith(decoration: TextDecoration.underline)),
        ),
      ),
    ]);
  }

  Widget _forgotPage(Tokens t) {
    Widget words(String s) => Padding(
          padding: EdgeInsets.only(bottom: t.space(3)),
          child: Text(s, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45)),
        );
    final folder = widget.lock.store.folder;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, key: const ValueKey('lock-forgot-page'), children: [
      Text('Forgot your PIN?', style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
      SizedBox(height: t.space(3)),
      words('The app keeps only a scrambled check of your PIN, so nobody can read it back or reset it, not even Uplink.'),
      if (Sms.standalone) ...[
        // What signing out with everything deleted says where it is asked in Settings › Me (lib/ui/account_screens.dart).
        words('The way back in is to sign out and delete everything on this device: your conversations here, your spaces and your choices, your sign-ins to other networks here (Telegram, Signal and the rest) and its call recordings. Your friends and circles stay with your account, and come back when you sign in again.'),
        if (_problem != null) words(_problem!),
        if (!_sure)
          PairButton(key: const ValueKey('lock-forgot-delete'), label: 'Sign out and delete everything here', icon: Lucide.trash2, onPressed: () => setState(() => _sure = true))
        else ...[
          words('Delete everything on this device now? This can\'t be undone.'),
          PairButton(key: const ValueKey('lock-forgot-sure'), label: _deleting ? 'Deleting…' : 'Yes, delete everything here', icon: Lucide.trash2, onPressed: _deleting ? null : _deleteAll),
        ],
      ] else if (!kIsWeb && PlatformInfo.isAndroid)
        words('The way back in is to delete what the app keeps on this phone: open Android\'s Settings, then Apps, Uplink, Storage, and clear its storage. That signs this phone out and deletes its conversations with friends and other networks, its spaces and its choices. Your texts are kept by Android and stay. Your friends and circles stay with your account, and come back when you sign in again.')
      else if (!kIsWeb && PlatformInfo.isIOS)
        words('The way back in is to delete Uplink from this iPhone and install it again, then pair it with your phone again. Your phone keeps everything of its own.')
      else
        words('The way back in is to close Uplink and delete its folder on this computer${folder == null ? '' : ' ($folder)'}, then open it and pair it with your phone again. That deletes everything the app keeps here. Your phone keeps everything of its own.'),
      SizedBox(height: t.space(2)),
      PairButton(
        key: const ValueKey('lock-forgot-back'),
        label: 'Back',
        icon: Lucide.arrowLeft,
        quiet: true,
        onPressed: _deleting
            ? null
            : () => setState(() {
                  _forgot = false;
                  _sure = false;
                  _problem = null;
                }),
      ),
    ]);
  }
}

/// A friend's call ringing, or the call this device is in, on the lock screen: answered, declined or ended without the
/// PIN, as a phone's own lock screen lets a call be. Who is calling is said, as the call's notification says it; no
/// message is.
class _CallStrip extends StatelessWidget {
  const _CallStrip({required this.top});
  final double top;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final v = Voice.instance;
    return ListenableBuilder(
      listenable: v,
      builder: (context, _) {
        final r = v.ringing;
        final ring = r != null && r.call != null ? r : null;
        final inCall = v.session != null;
        if (ring == null && !inCall) return const SizedBox.shrink();
        Widget button(String label, Color color, VoidCallback onPressed, Key key) => GlacierPressable(
              key: key,
              onPressed: onPressed,
              semanticLabel: label,
              canRequestFocus: false,
              builder: (context, state) => Container(
                padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
                decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(t.radius('full'))),
                child: Text(label, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: const Color(0xFFFFFFFF))),
              ),
            );
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), top + t.space(2), t.space(3), 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: t.lenOf('30rem')),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(t.radius('xl')),
                child: ColoredBox(
                  color: t.color('app-ink'),
                  child: Padding(
                    padding: EdgeInsets.all(t.space(3)),
                    child: Row(children: [
                      AppIcon(ring != null && ring.video ? Lucide.video : LucideMore.phoneCall, size: 22, wash: false, color: t.color('app-paper')),
                      SizedBox(width: t.space(3)),
                      Expanded(
                        child: Text(
                          ring != null ? '${ring.from} is calling' : 'On a call',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: pageText(t, t.fontSize('md'), weight: 'bold', color: t.color('app-paper')),
                        ),
                      ),
                      if (ring != null) ...[
                        button('Decline', t.danger, v.dismissRing, const ValueKey('lock-call-decline')),
                        SizedBox(width: t.space(2)),
                        button('Answer', t.online, () => unawaited(v.join(ring.channel, video: ring.video).then<void>((_) {}, onError: (Object _) {})), const ValueKey('lock-call-answer')),
                      ] else
                        button('Hang up', t.danger, () => unawaited(v.leave()), const ValueKey('lock-call-leave')),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// --- Settings › Lock the app ------------------------------------------------------------------------------------------

/// The line under "Lock the app" in Settings' list.
String appLockSummary() {
  final lock = AppLock.instance;
  return lock.isSet ? 'On · ${_afterWords(lock.after)}' : 'Off';
}

String _afterWords(int seconds) => switch (seconds) {
      0 => 'at once',
      60 => 'after 1 minute',
      300 => 'after 5 minutes',
      _ => 'after 1 hour',
    };

/// Settings › Lock the app: a PIN set and confirmed, then how long away locks the app, the fingerprint or face where
/// the device has one, and the lock now. Changing the PIN or setting it aside asks for it first.
class AppLockPane extends StatefulWidget {
  const AppLockPane({super.key, this.lock});

  /// The app's own ([AppLock.instance]) where not given.
  final AppLock? lock;

  @override
  State<AppLockPane> createState() => _AppLockPaneState();
}

class _AppLockPaneState extends State<AppLockPane> {
  AppLock get _lock => widget.lock ?? AppLock.instance;

  @override
  void initState() {
    super.initState();
    // Whether this device has a fingerprint or a face to ask for, asked as the page opens: one may have been added
    // since the app started.
    unawaited(_lock.askCanBiometric().then((_) {
      if (mounted) setState(() {});
    }));
  }

  Future<void> _setBiometric(bool on) async {
    final lock = _lock;
    // Switched on only once the device has taken a fingerprint or a face, so it is known to work here.
    if (on && !await lock.askBiometric('Unlock Uplink with your fingerprint or face')) {
      if (mounted) toast(context, 'Your fingerprint or face wasn\'t taken, so this stays off.');
      return;
    }
    await lock.setBiometric(on);
  }

  @override
  Widget build(BuildContext context) {
    final lock = _lock;
    Widget icon(LucideIcon i) => AppIcon(i, size: 18);
    const limits = Tr(
        'The lock keeps people out of the app on this device. It does not scramble what the app keeps: someone who can read this device\'s files is not stopped by it. Notifications still arrive. The PIN is kept only as a scrambled check that can\'t be read back, so a forgotten one can\'t be reset: the way back in is to delete what the app keeps on this device.');
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        if (!lock.isSet) {
          return PaneSection(
            title: 'Lock the app',
            footer: limits,
            children: [
              SettingRow(
                key: const ValueKey('lock-set'),
                icon: icon(Lucide.lock),
                label: 'Set a PIN',
                hint: const Tr('4 to 8 digits, asked for when you open the app and when you come back to it.'),
                onPress: () => push(context, (_) => PinSetScreen(lock: lock, mode: PinSetMode.set)),
              ),
            ],
          );
        }
        final phone = !kIsWeb && PlatformInfo.isAndroid;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          PaneSection(
            title: 'Lock the app',
            footer: limits,
            children: [
              SettingRow(
                icon: icon(Lucide.lock),
                label: 'Lock the app',
                hint: Text(phone ? 'On. While a PIN is set the app switcher shows nothing of the app and screenshots of it are off; while it is locked, notifications say "New message" without the words.' : 'On.'),
                control: GlacierSwitch(
                  checked: true,
                  onCheckedChange: (v) {
                    if (!v) push(context, (_) => PinSetScreen(lock: lock, mode: PinSetMode.off));
                  },
                  ariaLabel: 'Lock the app',
                ),
              ),
              SettingRow(
                key: const ValueKey('lock-change'),
                icon: icon(Lucide.keyRound),
                label: 'Change PIN',
                hint: const Tr('After your PIN now'),
                onPress: () => push(context, (_) => PinSetScreen(lock: lock, mode: PinSetMode.change)),
              ),
              SettingRow(
                icon: icon(Lucide.clock),
                label: 'Lock after',
                hint: Text(lock.desktop ? 'How long the app is hidden, or behind another window, before it locks. Behind another window it takes at least ten seconds.' : 'How long you are away from the app before it locks.'),
                layout: SettingRowLayout.stacked,
                control: GlacierSegmentedControl(
                  key: const ValueKey('lock-after'),
                  fullWidth: true,
                  value: '${lock.after}',
                  onValueChange: (v) => unawaited(lock.setAfter(int.tryParse(v) ?? 60)),
                  ariaLabel: 'Lock after',
                  options: const [
                    GlacierSegmentedOption(value: '0', label: Tr('At once')),
                    GlacierSegmentedOption(value: '60', label: Tr('1 minute')),
                    GlacierSegmentedOption(value: '300', label: Tr('5 minutes')),
                    GlacierSegmentedOption(value: '3600', label: Tr('1 hour')),
                  ],
                ),
              ),
              if (lock.canBiometric)
                SettingRow(
                  icon: icon(Lucide.shieldCheck),
                  label: 'Unlock with fingerprint or face',
                  hint: const Tr('The one this device already knows. Your PIN always works too.'),
                  control: GlacierSwitch(checked: lock.biometric, onCheckedChange: (v) => unawaited(_setBiometric(v)), ariaLabel: 'Unlock with fingerprint or face'),
                ),
              SettingRow(
                key: const ValueKey('lock-now'),
                icon: icon(Lucide.logOut),
                label: 'Lock now',
                onPress: lock.lockNow,
              ),
            ],
          ),
        ]);
      },
    );
  }
}

/// What [PinSetScreen] is opened for.
enum PinSetMode { set, change, off }

/// A page with the number pad: a new PIN typed and typed again ([PinSetMode.set]); the PIN now, then a new one twice
/// ([PinSetMode.change]); or the PIN now, and the lock set aside ([PinSetMode.off]).
class PinSetScreen extends StatefulWidget {
  const PinSetScreen({super.key, required this.lock, required this.mode});
  final AppLock lock;
  final PinSetMode mode;

  @override
  State<PinSetScreen> createState() => _PinSetScreenState();
}

class _PinSetScreenState extends State<PinSetScreen> {
  /// Whether the PIN now has been given, where it is asked for.
  late bool _known = widget.mode == PinSetMode.set;

  /// The new PIN as first typed, until it is typed again.
  String? _first;
  String? _problem;
  bool _busy = false;
  Timer? _tick;

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Draws the wait's line again each second while one runs.
  void _watchWait() {
    if (widget.lock.wait <= Duration.zero || _tick != null) return;
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.lock.wait <= Duration.zero) {
        _tick?.cancel();
        _tick = null;
      }
      setState(() {});
    });
  }

  Future<void> _typed(String pin) async {
    if (_busy) return;
    final lock = widget.lock;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      if (!_known) {
        if (!await lock.check(pin)) {
          _problem = 'Wrong PIN. Try again.';
          _watchWait();
          return;
        }
        if (widget.mode == PinSetMode.off) {
          await lock.remove();
          if (mounted) {
            toast(context, 'The app is no longer locked');
            Navigator.of(context).maybePop();
          }
          return;
        }
        _known = true;
        return;
      }
      if (_first == null) {
        _first = pin;
        return;
      }
      if (_first != pin) {
        _first = null;
        _problem = 'Those two weren\'t the same. Start again.';
        return;
      }
      await lock.setPin(pin);
      if (mounted) {
        toast(context, widget.mode == PinSetMode.change ? 'Your PIN is changed' : 'The app is locked with your PIN');
        Navigator.of(context).maybePop();
      }
    } catch (_) {
      _first = null;
      _problem = 'The PIN couldn\'t be kept on this device. Nothing changed.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final lock = widget.lock;
    final wait = !_known ? lock.wait : Duration.zero;
    final waiting = wait > Duration.zero;
    final line = waiting
        ? 'Too many wrong tries. Try again in ${AppLock.waitWords(wait)}.'
        : _busy
            ? 'One moment…'
            : _problem ?? (!_known ? 'Enter your PIN now' : (_first == null ? 'Choose a PIN of 4 to 8 digits' : 'Type it again'));
    return GhostPage(
      title: switch (widget.mode) { PinSetMode.set => 'Set a PIN', PinSetMode.change => 'Change PIN', PinSetMode.off => 'Turn off the lock' },
      body: SingleChildScrollView(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(6), t.space(6), t.space(6), t.space(8) + MediaQuery.paddingOf(context).bottom),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(line, key: const ValueKey('pin-set-line'), textAlign: TextAlign.center, style: pageText(t, t.fontSize('md'), color: waiting || _problem != null ? t.danger : t.color('app-ink'), height: 1.4)),
            SizedBox(height: t.space(5)),
            PinPad(
              enabled: !_busy && !waiting,
              onSubmit: _typed,
              submitLabel: !_known ? 'Next' : (_first == null ? 'Next' : 'Set this PIN'),
              submitIcon: !_known || _first == null ? Lucide.check : Lucide.lock,
            ),
          ]),
        ),
      ),
    );
  }
}
