import 'dart:async';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../account/account.dart';
import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../sms.dart' show Sms;
import '../ui/account_screens.dart';
import '../ui/common.dart' show push, toast;
import '../ui/computers.dart' show PairButton;
import '../kit/semantic_colors.dart';
import 'standalone.dart' show StandaloneCalls;
import '../l10n/words.dart';

/// The first thing a device of its own shows (lib/standalone; Matt, 2026-11-15: "roll a version of the app that works
/// without sms"). Since 2026-11-20 it asks for two things only (Matt: "rework the onboarding flow to be very simple and
/// just ask for a username and password"): the username, which is how anyone reaches someone here, claimed on the
/// relay server's directory (it keeps only the username's hash and this device's public key), and a password, which
/// makes the Uplink account at the same moment (lib/account), so the username can be signed in to on another device.
/// The recovery words come after, to write down and check, and the check can be skipped.
///
/// The username is claimed first, then the account is made with this install's own identity ("bound"): made the
/// other way round, a fresh install would take the words' identity and have to start again before it had a username.
///
/// Where the device has just deleted everything of an account (lib/account/account.dart: signed out with everything,
/// or removed from another device), or a browser found what it kept couldn't be opened, it says so here
/// ([welcomeNote]) until an account is made or signed in to.
class StandaloneWelcome extends StatefulWidget {
  const StandaloneWelcome({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  State<StandaloneWelcome> createState() => _StandaloneWelcomeState();
}

/// What the welcome says for the note a device started again with (StandaloneCalls.noteKey); null for none.
String? welcomeNote(String note) {
  final here = Sms.browser ? 'browser' : 'device';
  return switch (note) {
    'removed' => 'This $here was removed from your account from another device, so everything of the account on it was deleted. Sign in again, or start afresh.',
    'signed-out' => 'You\'re signed out, and everything of your account was deleted from this $here.',
    'lost' => 'What this browser kept for Uplink couldn\'t be opened, so it was cleared. Sign in again with your username and password.',
    _ => null,
  };
}

class _StandaloneWelcomeState extends State<StandaloneWelcome> {
  final _username = TextEditingController();
  final _password = TextEditingController();

  /// What is wrong with what was typed, or why the username could not be had; and what is being done now, in
  /// words, while something is.
  String? _problem;
  String? _busy;

  @override
  void initState() {
    super.initState();
    // The directory is the relay server's: dialled now, so it is answering by the time a username is typed.
    Me.instance.wake();
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Claims the username, then makes the account and shows its recovery words. A username that cannot be had stops
  /// here; an account that cannot be made does not, and the welcome is done all the same.
  Future<void> _go() async {
    final want = tidyHandle(_username.text);
    final password = _password.text;
    if (!Me.goodUsername(want)) return setState(() => _problem = 'A username is 3 to 20 letters, numbers, dots or underscores.');
    if (password.length < minPassword) return setState(() => _problem = 'A password is at least $minPassword characters.');
    setState(() {
      _busy = 'Checking…';
      _problem = null;
    });
    // Pushed from here, the words stay over whatever comes next once the username is in (the gate moves on by itself).
    final navigator = Navigator.of(context);
    try {
      await Me.instance.claimUsername(want);
    } catch (e) {
      if (mounted) setState(() => _problem = e is MeError ? e.message : '$e');
      if (mounted) setState(() => _busy = null);
      return;
    }
    try {
      if (mounted) setState(() => _busy = 'Creating your account…');
      final draft = Account.instance.draft();
      await Account.instance.create(draft, password);
      unawaited(navigator.push(PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, _, _) => CreateAccountScreen(step: CreateStep.words, draft: draft, made: true),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
      )));
    } catch (e) {
      // The username is this device's already. The account is made from Settings › Me; or, where it was made and this
      // device couldn't be added to it (Account.create says so), signed in to there.
      if (mounted) toast(context, e is AccountError ? e.message : 'Your account couldn\'t be made just now. Make it from Settings › Me.');
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = Me.instance;
    final pad = MediaQuery.paddingOf(context);
    final busy = _busy;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListenableBuilder(
          listenable: me,
          builder: (context, _) => ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(6), pad.top + t.space(8), t.space(6), pad.bottom + t.space(8)),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              // The app's mark on black, as the computer's first page has it (lib/desktop/ui/wizard.dart).
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  width: t.lenOf('4rem'),
                  height: t.lenOf('4rem'),
                  decoration: BoxDecoration(color: const Color(0xFF000000), borderRadius: BorderRadius.circular(t.lenOf('1rem')), border: Border.all(color: t.color('app-rule'))),
                  alignment: Alignment.center,
                  child: Image.asset('assets/art/ghost-mark.png', width: t.lenOf('3.2rem'), height: t.lenOf('3.2rem')),
                ),
              ),
              SizedBox(height: t.space(6)),
              Text('Uplink', style: pageText(t, t.fontSize('2xl'), weight: 'bold', color: t.color('app-ink'), height: 1.2)),
              SizedBox(height: t.space(2)),
              Text('Pick a username and a password.', style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.45)),
              // Why this device starts with nothing, where it was just made to (lib/account/account.dart).
              if (welcomeNote(AppState.maybeOf(context)?.choice(StandaloneCalls.noteKey, '') ?? '') case final note?) ...[
                SizedBox(height: t.space(4)),
                SettingsCallout(key: const ValueKey('welcome-note'), icon: const AppIcon(Lucide.info, size: 18), child: Text(note)),
              ],
              SizedBox(height: t.space(6)),
              PaneSection(
                footer: _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger)),
                children: [
                  SettingRowBox(
                    child: GlacierInput(
                      key: const ValueKey('welcome-username'),
                      controller: _username,
                      placeholder: 'Username'.t,
                      ariaLabel: 'Username',
                      autoCorrect: false,
                      autoCapitalize: TextCapitalization.none,
                      autoComplete: 'username',
                      size: GlacierFieldSize.md,
                      onSubmitted: (_) => _go(),
                    ),
                  ),
                  SettingRowBox(
                    child: GlacierInput(
                      key: const ValueKey('welcome-password'),
                      controller: _password,
                      placeholder: 'Password'.t,
                      ariaLabel: 'Password',
                      type: GlacierInputType.password,
                      autoCorrect: false,
                      autoCapitalize: TextCapitalization.none,
                      autoComplete: 'new-password',
                      size: GlacierFieldSize.md,
                      onSubmitted: (_) => _go(),
                    ),
                  ),
                ],
              ),
              SizedBox(height: t.space(6)),
              PairButton(
                key: const ValueKey('welcome-continue'),
                label: busy ?? (me.ready ? 'Continue' : 'Connecting…'),
                icon: Lucide.arrowRight,
                onPressed: busy != null || !me.ready ? null : _go,
              ),
              // Someone with an account becomes it instead (Matt, 2026-11-17: "We need to have a way to login to
              // existing accounts"), from a section of its own on this same page (Matt, 2026-11-20: "it should have an
              // 'already have an account' section on the first page").
              if (!Account.instance.signedIn) ...[
                SizedBox(height: t.space(8)),
                Container(height: 1, color: t.color('app-rule')),
                SizedBox(height: t.space(6)),
                Text('Already have an account?', style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'), height: 1.3)),
                SizedBox(height: t.space(1)),
                Text('Sign in with your username and password, or your recovery words.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.45)),
                SizedBox(height: t.space(4)),
                PairButton(
                  key: const ValueKey('welcome-sign-in'),
                  label: 'Sign in',
                  icon: Lucide.keyRound,
                  quiet: true,
                  onPressed: busy != null ? null : () => push(context, (_) => const SignInScreen()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
