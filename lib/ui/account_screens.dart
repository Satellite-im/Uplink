/// An Uplink account's screens (lib/account; Matt, 2026-11-17: "We need to have a way to login to existing accounts. We
/// might need to add password based authentication as well as SMS verification for verified numbers"; "I like your
/// recommendation let's do it for now"; "i also want accounts to be generated based on ethereum type addresses with a
/// recovery seed we can back up"): making one (a password, then the recovery words written down and confirmed), signing
/// in to one (username and password, with the texted code where its number is verified; or the recovery words), and on
/// a signed-in device its address, a new password, the words again, and the devices signed in.
library;

import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../account/account.dart';
import '../app_state.dart';
import '../account/account_crypto.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../desktop/own_calls.dart' show DeskOwnCalls;
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart' show Me, tidyHandle;
import '../net/net.dart' show Net;
import '../net/relay_choice.dart' show relayInUseWords;
import '../platform_info.dart';
import '../relay_host/words.dart' show signOutHostWords;
import '../sms.dart';
import 'common.dart';
import 'computers.dart' show PairButton;
import 'handover_screens.dart';
import '../l10n/words.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// A password is at least this long: the backup's password copy can be tried offline by anyone who gets it, and only
/// Argon2id's cost and the password's length stand in the way.
const minPassword = 10;

/// The address cut short for a row: 0x1234…abcd.
String shortAddress(String a) => a.length < 14 ? a : '${a.substring(0, 6)}…${a.substring(a.length - 4)}';

/// Settings › Me's Account section: the address and what can be done with it, or the two ways in.
Widget accountSection(BuildContext context) => ListenableBuilder(listenable: Account.instance, builder: (context, _) => _accountSection(context));

/// The account the phone this computer is paired with is signed in to, as it last said; null anywhere else.
({String address, String username})? phoneAccountHere() {
  final calls = Sms.calls;
  return calls is DeskOwnCalls ? calls.phoneAccount : null;
}

Widget _accountSection(BuildContext context) {
  final account = Account.instance;
  final address = account.address;
  if (address == null) {
    // A computer paired with a phone, with the phone's identity (Matt, 2026-11-18: "On my fold vs on my desktop, both
    // with the same number linked but it seems i'm not logged in on desktop"): signing in to the phone's own account
    // keeps it the same you, and is offered first, by name, where the phone has said which it is.
    final paired = Sms.paired;
    final phones = paired ? phoneAccountHere() : null;
    return PaneSection(
        title: 'Account',
        description: Text(paired
            ? 'Sign in to the account your phone is in, so this computer is the same you as your phone, or make one for who you are now.'
            : 'Keep who you are on Uplink, your friends and circles, and sign in with them on another device.'),
        footer: account.removedHere ? const Tr('This device was signed out of your account from another device.') : null,
        children: [
          if (phones != null)
            SettingRow(
              icon: _icon(Lucide.smartphone),
              label: 'Sign in to your Uplink account',
              hint: Text(phones.username.isEmpty ? 'The account your phone is in, ${shortAddress(phones.address)}' : '@${phones.username}, the account your phone is in'),
              onPress: () => push(context, (_) => SignInScreen(username: phones.username)),
            ),
          SettingRow(
            icon: _icon(Lucide.userPlus),
            label: 'Create an account',
            hint: Text(paired ? 'Keeps who you are now, the same you as your phone' : 'A password and 12 recovery words'),
            onPress: () => push(context, (_) => const CreateAccountScreen()),
          ),
          if (phones == null || phones.username.isEmpty)
            SettingRow(icon: _icon(Lucide.keyRound), label: paired ? 'Sign in to your Uplink account' : 'Sign in to an account', hint: const Tr('With your username and password, or your recovery words'), onPress: () => push(context, (_) => const SignInScreen()))
          else
            SettingRow(icon: _icon(Lucide.keyRound), label: 'Sign in to another account', hint: const Tr('With your username and password, or your recovery words'), onPress: () => push(context, (_) => const SignInScreen())),
        ],
      );
  }
  return PaneSection(
      title: 'Account',
      // The relay doesn't hold the account at all (Account.unknownHere): nothing was deleted or forgotten; said, with what
      // to do.
      description: account.unknownHere
          ? Text(Sms.browser
              ? 'The relay server doesn\'t hold your account: it may have lost what it kept. Nothing has been deleted here. List this browser again to put your account back on it from here.'
              : 'The relay server doesn\'t hold your account: it may be another relay than the one your account is on, or it may have lost what it kept. Nothing has been deleted or forgotten here. List this device again to put your account on it from here, or go back to the relay your account is on (Settings › Routes).')
          : null,
      children: [
        if (account.unknownHere)
          SettingRow(
            key: const ValueKey('account-list-again'),
            icon: _icon(Lucide.keyRound),
            label: Sms.browser ? 'List this browser again' : 'List this device again',
            hint: Text(Account.keepsWords ? 'Your account put on this relay from here, your friends and circles as they are' : 'After your password: your account put back on this relay from here'),
            onPress: () => push(context, (_) => const ListHereAgainScreen()),
          ),
        SettingRow(
          icon: _icon(Lucide.shieldCheck),
          label: 'Address',
          hint: Text(shortAddress(address)),
          control: _CopyButton(text: address),
        ),
        SettingRow(icon: _icon(Lucide.lock), label: 'Change password', onPress: () => push(context, (_) => const ChangePasswordScreen())),
        SettingRow(icon: _icon(Lucide.eye), label: 'Show recovery words', hint: const Tr('After your password'), onPress: () => push(context, (_) => const ShowWordsScreen())),
        SettingRow(
          icon: _icon(Lucide.laptop),
          label: 'Signed in on these devices',
          hint: Account.keepsWords ? null : const Tr('After your password'),
          onPress: () => push(context, (_) => const DevicesScreen()),
        ),
        // Signing in a new device by scanning the code on its sign-in screen (GMFB-45). On Android only for now: the
        // app has a camera for codes there and nowhere else yet. Not on a computer paired with a phone, nor where no
        // words are kept to hand over.
        if (PlatformInfo.isAndroid && Account.keepsWords && !Sms.paired)
          SettingRow(
            key: const ValueKey('account-new-device'),
            icon: _icon(LucideMore.qrCode),
            label: 'Sign in a new device',
            hint: const Tr('Scan the code on its sign-in screen'),
            onPress: () => push(context, (_) => const HandoverApproveScreen()),
          ),
        // A browser keeps no words and no password key, so its backup is brought up to date only when asked, with the
        // password (Account.refreshWith); every other device does it by itself once a day.
        if (!Account.keepsWords)
          SettingRow(
            icon: _icon(Lucide.refreshCw),
            label: 'Update your backup',
            hint: const Tr('Your profile, friends and circles from this browser, after your password'),
            onPress: () => push(context, (_) => const UpdateBackupScreen()),
          ),
        SettingRow(
          icon: _icon(Lucide.logOut),
          label: Sms.browser ? 'Sign out of this browser' : 'Sign out of this device',
          onPress: () => askSignOut(context),
        ),
      ],
    );
}

/// What signing out does here, said plainly, and the choices it comes with (Account.signOut).
///
/// - **In a browser** everything of the account is deleted from it: the whole store, its key with it. Nothing kept
///   there is safe from the next person at the browser, nor from whatever runs in the page.
/// - **On an iPhone or a computer of its own** it becomes someone new, and its conversations, spaces and choices stay,
///   unless everything is deleted too: it is the person's own device, where the conversations are often wanted back.
/// - **On an Android phone** its texts and conversations stay, as they always have; **a computer paired with a phone**
///   goes back to being the same you as the phone.
Future<void> askSignOut(BuildContext context) {
  // Signs out; where the app did not start again by itself, the page that asks for a restart.
  Future<void> out({bool everything = false}) async {
    final again = await Account.instance.signOut(everything: everything);
    if (!again && context.mounted) await push<void>(context, (_) => const RestartScreen());
  }

  // The relay this device hosts (lib/relay_host) stops with it: said, where it is on.
  final hosting = Net.instance.relayHost?.on ?? false;
  if (Sms.browser) {
    return showChoices(
      context,
      title: 'Sign out of this browser? Everything of your account is deleted from it: your conversations here, your friends, circles and keys. Your friends and circles stay with your account and come back when you sign in again; your other devices keep their own conversations.',
      choices: [Choice('Sign out and delete', Lucide.logOut, out, danger: true)],
    );
  }
  if (Sms.standalone) {
    return showChoices(
      context,
      title: 'Sign out of this device? It becomes someone new here, and your friends and circles stay with your account, to come back when you sign in again. Your conversations, your spaces and your choices stay on this device, unless you delete everything here too, which also signs out of your other networks here (Telegram, Signal and the rest) and deletes its call recordings.${hosting ? ' ${signOutHostWords(everything: true)}' : ''}',
      choices: [
        Choice('Sign out', Lucide.logOut, out),
        Choice('Sign out and delete everything here', Lucide.trash2, () => out(everything: true), danger: true),
      ],
    );
  }
  return showChoices(
    context,
    title: Sms.paired
        ? 'Sign out of this computer? It goes back to being the same you as your phone. Your friends and circles stay with your account, and come back when you sign in again.'
        : 'Sign out of this phone? It becomes someone new here: your friends and circles stay with your account, and come back when you sign in again. Your texts and conversations stay on this phone.${hosting ? ' ${signOutHostWords(everything: false)}' : ''}',
    choices: [Choice('Sign out', Lucide.logOut, out, danger: true)],
  );
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => GlacierPressable(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: text));
          toast(context, 'Address copied');
        },
        semanticLabel: 'Copy address',
        builder: (context, state) => Padding(padding: EdgeInsets.all(context.tokens.space(2)), child: _icon(Lucide.copy)),
      );
}

/// The page every account screen is drawn on: a titled page, its sections, and the button at the end.
class _AccountPage extends StatelessWidget {
  const _AccountPage({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GhostPage(
      title: title,
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: children,
        ),
      ),
    );
  }
}

/// A text field as a settings row: never corrected or capitalised, dotted out when [secret], and with the autofill
/// hint that lets a password manager fill it.
Widget _field(TextEditingController c, String placeholder, String label, {bool secret = false, ValueChanged<String>? onSubmitted, TextInputType? keyboard, String? autofill}) => SettingRowBox(
      child: GlacierInput(
        controller: c,
        placeholder: placeholder,
        ariaLabel: label,
        type: secret ? GlacierInputType.password : GlacierInputType.text,
        autoCorrect: false,
        autoCapitalize: TextCapitalization.none,
        inputMode: keyboard,
        autoComplete: autofill,
        size: GlacierFieldSize.md,
        onSubmitted: onSubmitted,
      ),
    );

/// What went wrong, in the danger colour, for a section's footer; nothing where there is no problem.
Widget _problemText(BuildContext context, String? problem) => problem == null ? const SizedBox.shrink() : Text(problem, style: TextStyle(color: context.tokens.danger));

Widget _gap(BuildContext context, [int n = 6]) => SizedBox(height: context.tokens.space(n));

/// The twelve words, numbered, as many to a row as fit whole (two on a phone, three or four on a wider window), in the
/// mono face so l and 1 are not confused. A word is never cut short: a word half shown is a word copied wrong.
class RecoveryWordsGrid extends StatelessWidget {
  const RecoveryWordsGrid({super.key, required this.words});
  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return LayoutBuilder(builder: (context, box) {
      final across = (box.maxWidth / t.lenOf('9rem')).floor().clamp(2, 4);
      final gap = t.space(2);
      final width = (box.maxWidth - gap * (across - 1)) / across;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (var i = 0; i < words.length; i++)
            Container(
              width: width,
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('md')), border: Border.all(color: t.color('app-rule'))),
              child: Row(children: [
                SizedBox(width: t.lenOf('1.6rem'), child: Text('${i + 1}', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-2'), mono: true))),
                Expanded(child: Text(words[i], style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'), mono: true), overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
      );
    });
  }
}

/// An address whole, in the mono face, in groups of ten so it can be read out and compared: 0x, then two lines.
class AddressBlock extends StatelessWidget {
  const AddressBlock({super.key, required this.address});
  final String address;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hex = address.startsWith('0x') ? address.substring(2) : address;
    final groups = [for (var i = 0; i < hex.length; i += 10) hex.substring(i, min(i + 10, hex.length))];
    final style = pageText(t, t.fontSize('lg'), weight: 'medium', color: t.color('app-ink'), mono: true, height: 1.5);
    return Semantics(
      label: 'Address $address',
      child: ExcludeSemantics(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Tr('0x ', style: style.copyWith(color: t.color('app-ink-2'))),
          Expanded(child: Text([for (var i = 0; i < groups.length; i += 2) groups.skip(i).take(2).join(' ')].join('\n'), style: style)),
        ]),
      ),
    );
  }
}

/// A word to tap, in confirming the words: pressed ones are greyed and can't be pressed again.
class _WordChip extends StatelessWidget {
  const _WordChip({required this.word, required this.onPressed, this.used = false});
  final String word;
  final VoidCallback? onPressed;
  final bool used;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: used ? null : onPressed,
      semanticLabel: word,
      builder: (context, state) => AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: used ? 0.3 : 1,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
          decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('full')), border: Border.all(color: t.color('app-rule'))),
          child: Text(word, style: pageText(t, t.fontSize('md'), color: t.color('app-ink'), mono: true)),
        ),
      ),
    );
  }
}

// --- making an account -------------------------------------------------------------------------------------------------

/// The pages of making an account, in the order they are walked.
enum CreateStep { password, words, confirm, working, done }

/// Making an account: a password, the words to write down, the words confirmed (tapped in order, or three of them
/// typed), then the backup sealed and kept, and the address shown.
class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key, this.step = CreateStep.password, this.draft, this.typed = false, this.made = false});

  /// Where it starts, and with which words: for the pictures (test/account_shots.dart).
  final CreateStep step;
  final AccountDraft? draft;
  final bool typed;

  /// The account is made already, from the first page's username and password (lib/standalone/welcome.dart): its
  /// words shown and checked, and the screen closed after.
  final bool made;

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _password = TextEditingController();
  final _again = TextEditingController();
  late CreateStep _step = widget.step;
  late final AccountDraft _draft = widget.draft ?? Account.instance.draft();
  late bool _typed = widget.typed;
  // The words in a mixed order to tap from, and the places in [_shuffled] tapped so far, in the order tapped.
  late final List<String> _shuffled = [..._draft.words]..shuffle(Random());
  final List<int> _tapped = [];
  // For the typed check: three places among the twelve, in rising order, and a field for each.
  late final List<int> _asked = (List.generate(12, (i) => i)..shuffle(Random())).take(3).toList()..sort();
  late final _three = [for (var i = 0; i < 3; i++) TextEditingController()];
  String? _problem;
  // What making the account answered: the app has to start again to become the account.
  bool _restart = false;

  @override
  void dispose() {
    _password.dispose();
    _again.dispose();
    for (final c in _three) {
      c.dispose();
    }
    super.dispose();
  }

  /// From the password page to the words: only with a password long enough, typed the same twice.
  void _toWords() {
    if (_password.text.length < minPassword) return setState(() => _problem = 'A password is at least $minPassword characters.');
    if (_password.text != _again.text) return setState(() => _problem = 'The two passwords are not the same.');
    setState(() {
      _problem = null;
      _step = CreateStep.words;
    });
  }

  /// The words are shown to be written down: the three asked for typed right, or all twelve tapped in order.
  bool get _confirmed {
    if (_typed) return [for (var i = 0; i < 3; i++) _three[i].text.trim().toLowerCase() == _draft.words[_asked[i]]].every((ok) => ok);
    return _tapped.length == 12 && [for (var i = 0; i < 12; i++) _shuffled[_tapped[i]] == _draft.words[i]].every((ok) => ok);
  }

  /// A word tapped: kept if it is the next of the twelve, and otherwise said to be wrong and not counted.
  void _tap(int i) {
    setState(() {
      _problem = null;
      _tapped.add(i);
      final n = _tapped.length;
      if (_shuffled[i] != _draft.words[n - 1]) {
        _problem = 'Word $n isn\'t ${_shuffled[i]}. Start again from there.';
        _tapped.removeLast();
      }
    });
  }

  /// The check passed by (Matt, 2026-11-20: "add a button to skip verifying the seed phrase"): the words can be seen
  /// again any time in Settings › Me, after the password.
  void _skipCheck() => widget.made ? Navigator.of(context).pop() : _make(checked: false);

  /// Makes the account from the draft and the password, then shows its address; a failure goes back to the check
  /// with what went wrong. Where the account is made already this only closes the screen.
  Future<void> _make({bool checked = true}) async {
    if (widget.made) {
      // Seen and checked: nothing to remind of (GMFB-3).
      AppState.of(context).setFlag(wordsLater, false);
      return Navigator.of(context).pop();
    }
    if (checked && !_confirmed) return setState(() => _problem = _typed ? 'Those aren\'t the words in those places. Look at what you wrote down.' : 'Tap all twelve in order.');
    setState(() {
      _problem = null;
      _step = CreateStep.working;
    });
    try {
      _restart = await Account.instance.create(_draft, _password.text);
      if (mounted) setState(() => _step = CreateStep.done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _step = CreateStep.confirm;
          _problem = e is AccountError ? e.message : 'The account could not be made just now. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final words = _draft.words;
    switch (_step) {
      case CreateStep.password:
        return _AccountPage(title: 'Create an account', children: [
          PaneSection(
            title: 'Choose a password',
            description: const Tr('With your username and this password you can sign in on another device. Make it long: anyone who got hold of your backup could try passwords against it.'),
            footer: _problem == null ? Text('At least $minPassword characters.') : _problemText(context, _problem),
            children: [
              _field(_password, 'Password', 'Password', secret: true, autofill: 'new-password'),
              _field(_again, 'The same again', 'The same password again', secret: true, autofill: 'new-password', onSubmitted: (_) => _toWords()),
            ],
          ),
          _gap(context, 8),
          PairButton(label: 'Next', icon: Lucide.arrowRight, onPressed: _toWords),
        ]);
      case CreateStep.words:
        return _AccountPage(title: 'Your recovery words', children: [
          PaneSection(
            title: 'Write these down',
            description: const Tr('On paper, in this order, and keep it somewhere safe. These 12 words are your account: with them you can sign in without your password, and nobody can give them back to you if they are lost.'),
            children: [Padding(padding: EdgeInsets.all(t.space(3)), child: RecoveryWordsGrid(words: words))],
          ),
          _gap(context),
          SettingsCallout(icon: _icon(Lucide.shieldCheck), child: const Tr('Never type them into a website or tell them to anyone. Uplink will never ask for them except here, to sign in.')),
          _gap(context, 8),
          PairButton(label: 'I\'ve written them down', icon: Lucide.arrowRight, onPressed: () => setState(() => _step = CreateStep.confirm)),
          // Just made at sign-up (GMFB-3, @kevin: "We need to find a way to reduce friction when onboarding new users. I
          // find the seed phrase to be a frustrating hurdle"): the account is made and sealed with the password already,
          // so the words can wait. The conversations list reminds until they are seen (Settings › Me shows them).
          if (widget.made) ...[
            _gap(context, 2),
            PairButton(
              key: const ValueKey('words-later'),
              label: 'Later',
              icon: Lucide.clock,
              quiet: true,
              onPressed: () {
                AppState.of(context).setFlag(wordsLater, true);
                Navigator.of(context).pop();
              },
            ),
          ],
        ]);
      case CreateStep.confirm:
        return _AccountPage(title: 'Check your words', children: [
          if (!_typed)
            PaneSection(
              title: 'Tap them in order',
              footer: _problem == null ? Text('${_tapped.length} of 12') : _problemText(context, _problem),
              children: [
                Padding(
                  padding: EdgeInsets.all(t.space(3)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    RecoveryWordsGrid(words: [for (var i = 0; i < 12; i++) i < _tapped.length ? _shuffled[_tapped[i]] : '']),
                    _gap(context, 4),
                    Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                      for (var i = 0; i < _shuffled.length; i++) _WordChip(word: _shuffled[i], used: _tapped.contains(i), onPressed: () => _tap(i)),
                    ]),
                  ]),
                ),
              ],
            )
          else
            PaneSection(
              title: 'Type three of them',
              footer: _problemText(context, _problem),
              children: [for (var i = 0; i < 3; i++) _field(_three[i], 'Word ${_asked[i] + 1}', 'Word ${_asked[i] + 1}')],
            ),
          _gap(context, 3),
          PaneSection(children: [
            SettingRow(
              icon: _icon(_typed ? Lucide.pencil : Lucide.pencilLine),
              label: _typed ? 'Tap all twelve instead' : 'Type three of them instead',
              onPress: () => setState(() {
                _typed = !_typed;
                _problem = null;
              }),
            ),
            SettingRow(icon: _icon(Lucide.rotateCcw), label: 'See the words again', onPress: () => setState(() => _step = CreateStep.words)),
            SettingRow(
              key: const ValueKey('skip-word-check'),
              icon: _icon(Lucide.chevronRight),
              label: 'Skip this check',
              hint: const Tr('See your words again any time in Settings › Me'),
              onPress: _skipCheck,
            ),
          ]),
          _gap(context, 8),
          PairButton(label: widget.made ? 'Done' : 'Create my account', icon: Lucide.check, onPressed: _confirmed ? _make : null),
        ]);
      case CreateStep.working:
        return _AccountPage(title: 'Create an account', children: [
          _gap(context, 10),
          Center(child: Text('Sealing your backup…', style: pageText(t, t.fontSize('lg'), weight: 'medium', color: t.color('app-ink')))),
          _gap(context, 2),
          Center(child: Text('Your password is stretched on this device first; it takes a moment.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')))),
        ]);
      case CreateStep.done:
        return _AccountPage(title: 'Your account', children: [
          PaneSection(
            title: 'Your account is ready',
            description: const Tr('This is its address. It is yours alone, and it is the same in any wallet that takes your recovery words.'),
            children: [
              Padding(padding: EdgeInsets.all(t.space(4)), child: AddressBlock(address: _draft.address)),
              SettingRow(icon: _icon(Lucide.copy), label: 'Copy address', onPress: () {
                Clipboard.setData(ClipboardData(text: _draft.address));
                toast(context, 'Address copied');
              }),
            ],
          ),
          _gap(context, 8),
          PairButton(
            label: _restart ? 'Start Uplink as your account' : 'Done',
            icon: _restart ? Lucide.rotateCcw : Lucide.check,
            onPressed: () async {
              if (!_restart) return Navigator.of(context).pop();
              final again = await Account.instance.restart();
              if (!again && context.mounted) await push<void>(context, (_) => const RestartScreen());
            },
          ),
        ]);
    }
  }
}

// --- signing in --------------------------------------------------------------------------------------------------------

/// Signing in on this device: username and password (and the code texted to the account's number, where it has a
/// verified one), or the recovery words. What is found replaces this install's identity and the app starts again.
/// The relay's host as a line names it: `relay.example.com`, with its port where it has one of its own.
String _relayHost(String hubUrl) {
  final u = Uri.tryParse(hubUrl);
  return u == null || u.host.isEmpty ? hubUrl : '${u.host}${u.hasPort ? ':${u.port}' : ''}';
}

/// On the sign-in screen while the app uses a relay other than Uplink's own (GMFB-25: "Sign-in works only on
/// the relay the account was made on", and nothing said which relay was asked): which relay is asked, and where an
/// account made elsewhere is signed in to. Null on Uplink's relay, where there is nothing to say.
String? signInRelayWords(String hubUrl) => hubUrl == Net.defaultHub
    ? null
    : 'You are signing in on ${relayInUseWords(hubUrl).replaceFirst('Your own relay: ', 'your own relay, ')}. An account is kept on the relay it was made on: to sign in to one made on Uplink\'s relay, go back to it first in Settings › Routes.';

/// "No account has that username", saying which relay was asked where it is not Uplink's own.
String noAccountWords(String hubUrl) => hubUrl == Net.defaultHub
    ? 'No account has that username.'
    : 'No account has that username on ${_relayHost(hubUrl)}. If yours was made on Uplink\'s relay or another, sign in there: go back to it first in Settings › Routes.';

/// What follows "no backup of it was found on the server" where the server is a relay other than Uplink's:
/// which one, and that the account may be on another.
String noBackupHereWords(String hubUrl) => hubUrl == Net.defaultHub ? '' : ' (${_relayHost(hubUrl)}; if your account was made on another relay, go back and change the relay in Settings › Routes first, or it is made anew here without its friends and circles)';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.words = false, this.phone = false, this.needsCode = false, this.needsPassword = false, this.username = ''});

  /// Starting on the tab that shows a code for a phone to scan (GMFB-45).
  final bool phone;

  /// The username typed in to start with: the phone's account's, on a computer paired with it.
  final String username;

  /// Starting on the words' tab, or at the texted code, or at a new password: for the pictures.
  final bool words;
  final bool needsCode;
  final bool needsPassword;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  late bool _words = widget.words;
  // The tab with a code for a phone signed in to the account to scan (GMFB-45; HandoverCodePanel).
  late bool _phone = widget.phone;
  late final _username = TextEditingController(text: widget.username);
  final _password = TextEditingController();
  final _number = TextEditingController();
  final _code = TextEditingController();
  final _typedWords = TextEditingController();
  // The account has a verified number, so a texted code is asked for too; and whether one has been sent yet.
  late bool _needsCode = widget.needsCode;
  bool _sent = false;
  // An account opened by its words with no backup on the server: held here while a new password is chosen.
  AccountRestore? _restored;
  late bool _needsPassword = widget.needsPassword;
  final _newPassword = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_username, _password, _number, _code, _typedWords, _newPassword]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Runs one step of signing in with the buttons off: what it throws is shown as the problem, and an account that
  /// wants a texted code opens the number's section instead.
  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await work();
    } on AccountNeedsCode {
      if (mounted) setState(() => _needsCode = true);
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountNotFound ? noAccountWords(Net.instance.hubUrl) : e is AccountError ? e.message : 'That did not work. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Username and password, with the number and its code once they have been asked for.
  Future<void> _withPassword() => _run(() async {
        final name = tidyHandle(_username.text);
        if (!Me.goodUsername(name)) throw AccountError('That isn\'t a username.');
        if (_password.text.isEmpty) throw AccountError('Type your password.');
        if (_needsCode && _code.text.trim().isEmpty) throw AccountError('Type the code from the text.');
        final restore = await Account.instance.signInWithPassword(name, _password.text, number: _needsCode ? _number.text : null, code: _needsCode ? _code.text.trim() : null);
        await _finish(restore);
      });

  /// Asks for a code to be texted to the number typed.
  Future<void> _text() => _run(() async {
        await Account.instance.textCode(tidyHandle(_username.text), _number.text);
        if (mounted) setState(() => _sent = true);
      });

  /// The recovery words: each checked against the word list before anything is asked of the server. An account with
  /// no backup kept goes on to choosing a password, so one is kept again.
  /// [handed]: the words a phone handed over after scanning this device's code (GMFB-45), in the typed ones' place.
  /// They are used here and kept nowhere but where signing in keeps them.
  Future<void> _withWords([List<String>? handed]) => _run(() async {
        final words = handed ?? AccountCrypto.tidyWords(_typedWords.text);
        final strange = words.where((w) => !AccountCrypto.isWord(w)).toList();
        if (strange.isNotEmpty) throw AccountError('"${strange.first}" isn\'t one of the recovery words. Check its spelling.');
        if (words.length != 12 && words.length != 24) throw AccountError('That is ${words.length} words. There are 12.');
        final restore = await Account.instance.signInWithWords(words);
        if (!restore.backedUp) {
          setState(() {
            _restored = restore;
            _needsPassword = true;
          });
          return;
        }
        await _finish(restore);
      });

  Future<void> _withNewPassword() => _run(() async {
        if (_newPassword.text.length < minPassword) throw AccountError('A password is at least $minPassword characters.');
        await _finish(_restored!, password: _newPassword.text);
      });

  /// Makes this device the account found, and starts the app again (or shows how to, where it can't itself).
  Future<void> _finish(AccountRestore restore, {String? password}) async {
    // On a computer paired with a phone this computer is the phone's identity; an account with another one splits
    // them, to everyone who writes, into two people (Matt, 2026-11-18: "messages from desktop are coming through
    // differently than messages on mobile even though they're both me"). Asked first.
    if (Sms.paired && await Account.instance.wouldChangeIdentity(restore)) {
      if (!mounted) return;
      final phones = phoneAccountHere();
      var go = false;
      await showChoices(
        context,
        title: phones != null && phones.address.toLowerCase() != restore.address.toLowerCase()
            ? 'This isn\'t the account your phone is in. Signed in to it, this computer and your phone are different people to your friends: messages from each come from someone else.'
            : 'This account is someone other than your phone. Signed in to it, this computer and your phone are different people to your friends: messages from each come from someone else.',
        choices: [Choice('Sign in anyway', Lucide.keyRound, () => go = true, danger: true)],
      );
      if (!go) return;
    }
    final again = await Account.instance.finish(restore, password: password);
    if (!again && mounted) await Navigator.of(context).pushReplacement(PageRouteBuilder<void>(pageBuilder: (_, _, _) => const RestartScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _busy;
    final tabs = Padding(
      padding: EdgeInsets.only(bottom: context.tokens.space(4)),
      child: GlacierSegmentedControl(
        fullWidth: true,
        value: _phone ? 'phone' : _words ? 'words' : 'password',
        ariaLabel: 'How to sign in',
        onValueChange: (v) => setState(() {
          _words = v == 'words';
          _phone = v == 'phone';
          _problem = null;
        }),
        options: const [
          GlacierSegmentedOption(value: 'password', label: Tr('Username')),
          GlacierSegmentedOption(value: 'words', label: Tr('Recovery words')),
          GlacierSegmentedOption(value: 'phone', label: Tr('Phone')),
        ],
      ),
    );
    final warning = SettingsCallout(
      icon: _icon(Lucide.smartphone),
      // A browser is a device of its own on the account's list each time it signs in, and a private window is a new
      // browser each time: it keeps nothing once closed, so its place on the list stays until it is removed.
      child: Text(Sms.browser
          ? 'Signing in makes this browser one of your account\'s devices, listed under it until you sign out here or remove it from another. A private window is a new device each time, and keeps nothing once it is closed: sign out before closing it, or remove it later.'
          : 'Signing in makes this device your account. Anything on it from before, as someone else, is replaced, and the app starts again.'),
    );
    // On a relay of one's own: which relay is asked, since an account is found only on the relay it was made on.
    final elsewhere = signInRelayWords(Net.instance.hubUrl);
    final relay = elsewhere == null ? const <Widget>[] : [SettingsCallout(key: const ValueKey('sign-in-relay'), icon: _icon(Lucide.globe), child: Text(elsewhere)), _gap(context)];
    if (_needsPassword) {
      return _AccountPage(title: 'Sign in', children: [
        PaneSection(
          title: 'Choose a password',
          description: Text('Your words opened your account, but no backup of it was found on the server${noBackupHereWords(Net.instance.hubUrl)}. Choose a password to keep one again, so you can sign in with your username next time.'),
          footer: _problemText(context, _problem),
          children: [_field(_newPassword, 'New password', 'New password', secret: true, autofill: 'new-password', onSubmitted: (_) => _withNewPassword())],
        ),
        _gap(context, 8),
        PairButton(label: busy ? 'Signing in…' : 'Sign in', icon: Lucide.arrowRight, onPressed: busy ? null : _withNewPassword),
      ]);
    }
    if (_phone) {
      // Leaving this tab, or the screen, takes the panel down, and its code with it. While the account is opened the
      // tabs are off, so the panel is not taken down half way.
      return _AccountPage(title: 'Sign in', children: [
        IgnorePointer(ignoring: busy, child: tabs),
        HandoverCodePanel(busy: busy, problem: _problem, onWords: (words) => _withWords(words), onFresh: () => setState(() => _problem = null)),
        _gap(context),
        warning,
      ]);
    }
    if (_words) {
      return _AccountPage(title: 'Sign in', children: [
        tabs,
        PaneSection(
          title: 'Your recovery words',
          description: const Tr('The 12 words you wrote down, in order, with spaces between. No password or code is needed.'),
          footer: _problemText(context, _problem),
          children: [
            SettingRowBox(
              child: GlacierInput(controller: _typedWords, placeholder: 'word word word …'.t, ariaLabel: 'Recovery words', autoCorrect: false, spellCheck: false, autoCapitalize: TextCapitalization.none, size: GlacierFieldSize.md, onSubmitted: (_) => _withWords()),
            ),
          ],
        ),
        _gap(context),
        ...relay,
        warning,
        _gap(context, 8),
        PairButton(label: busy ? 'Opening your account…' : 'Sign in', icon: Lucide.arrowRight, onPressed: busy ? null : _withWords),
      ]);
    }
    return _AccountPage(title: 'Sign in', children: [
      tabs,
      PaneSection(
        title: 'Your account',
        footer: _needsCode ? null : _problemText(context, _problem),
        children: [
          _field(_username, 'username', 'Username', autofill: 'username'),
          _field(_password, 'Password', 'Password', secret: true, autofill: 'current-password', onSubmitted: (_) => _withPassword()),
        ],
      ),
      if (_needsCode) ...[
        _gap(context),
        PaneSection(
          title: 'Your number',
          description: const Tr('This account has a verified number. Type it, and a code is texted to it to show it\'s you.'),
          footer: _problemText(context, _problem),
          children: [
            _field(_number, '+1 555 010 0199', 'Phone number', keyboard: TextInputType.phone, autofill: 'tel'),
            SettingRow(icon: _icon(Lucide.messageSquare), label: _sent ? 'Text me another code' : 'Text me a code', disabled: busy, onPress: _text),
            if (_sent) _field(_code, 'Code', 'Code from the text', keyboard: TextInputType.number, autofill: 'one-time-code', onSubmitted: (_) => _withPassword()),
          ],
        ),
      ],
      _gap(context),
      ...relay,
      warning,
      _gap(context, 8),
      PairButton(label: busy ? 'Signing in…' : 'Sign in', icon: Lucide.arrowRight, onPressed: busy || (_needsCode && !_sent) ? null : _withPassword),
    ]);
  }
}

/// Shown where the app cannot start itself again (an iPhone, a computer that can't open itself again): the person
/// closes it and opens it again.
class RestartScreen extends StatelessWidget {
  const RestartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final how = PlatformInfo.isIOS || PlatformInfo.isAndroid ? 'Swipe it away from the app switcher and open it again to finish.' : 'Quit Uplink and open it again to finish.';
    // Everything of the account here was deleted (signed out with everything, or removed from another device).
    final gone = Account.instance.ended;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(t.space(8)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _icon(Lucide.rotateCcw),
            _gap(context, 4),
            Text('Open Uplink again', textAlign: TextAlign.center, style: pageText(t, t.fontSize('xl'), weight: 'bold', color: t.color('app-ink'))),
            _gap(context, 2),
            Text(
              gone
                  ? '${Account.instance.removedHere ? 'This device was removed from your account from another device, so everything of the account on it was deleted.' : 'Everything of your account was deleted from this device.'} $how Until then it stays offline.'
                  : '$how Until then it stays offline, so nothing is sent as the device you were before.',
              textAlign: TextAlign.center,
              style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.45),
            ),
          ]),
        ),
      ),
    );
  }
}

// --- on a signed-in device -----------------------------------------------------------------------------------------------

/// The recovery words again, after the password.
class ShowWordsScreen extends StatefulWidget {
  const ShowWordsScreen({super.key, this.words});
  final List<String>? words;

  @override
  State<ShowWordsScreen> createState() => _ShowWordsScreenState();
}

class _ShowWordsScreenState extends State<ShowWordsScreen> {
  final _password = TextEditingController();
  late List<String>? _words = widget.words;
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final words = await Account.instance.revealWords(_password.text);
      if (mounted) {
        setState(() => _words = words);
        // Seen: the list's reminder goes (GMFB-3).
        AppState.of(context).setFlag(wordsLater, false);
      }
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'That did not work.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final words = _words;
    if (words != null) {
      return _AccountPage(title: 'Recovery words', children: [
        PaneSection(
          title: 'Your recovery words',
          description: const Tr('Make sure nobody can see your screen. Write them down in this order.'),
          children: [Padding(padding: EdgeInsets.all(context.tokens.space(3)), child: RecoveryWordsGrid(words: words))],
        ),
      ]);
    }
    return _AccountPage(title: 'Recovery words', children: [
      PaneSection(
        title: 'Your password first',
        footer: _problemText(context, _problem),
        children: [_field(_password, 'Password', 'Password', secret: true, autofill: 'current-password', onSubmitted: (_) => _open())],
      ),
      _gap(context, 8),
      PairButton(label: _busy ? 'Opening…' : 'Show my words', icon: Lucide.eye, onPressed: _busy ? null : _open),
    ]);
  }
}

/// A new password, after the one now: the backup is sealed again with it and the recovery words stay as they are.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _old = TextEditingController();
  final _next = TextEditingController();
  final _again = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _old.dispose();
    _next.dispose();
    _again.dispose();
    super.dispose();
  }

  Future<void> _change() async {
    if (_next.text.length < minPassword) return setState(() => _problem = 'A password is at least $minPassword characters.');
    if (_next.text != _again.text) return setState(() => _problem = 'The two new passwords are not the same.');
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await Account.instance.changePassword(_old.text, _next.text);
      if (mounted) {
        toast(context, 'Password changed');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'That did not work.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AccountPage(title: 'Change password', children: [
        PaneSection(
          title: 'Your password now',
          children: [_field(_old, 'Password', 'Password now', secret: true, autofill: 'current-password')],
        ),
        _gap(context),
        PaneSection(
          title: 'A new one',
          description: const Tr('Your backup is sealed again with it. Your recovery words stay the same.'),
          footer: _problemText(context, _problem),
          children: [
            _field(_next, 'New password', 'New password', secret: true, autofill: 'new-password'),
            _field(_again, 'The same again', 'The new password again', secret: true, autofill: 'new-password', onSubmitted: (_) => _change()),
          ],
        ),
        _gap(context, 8),
        PairButton(label: _busy ? 'Sealing…' : 'Change password', icon: Lucide.lock, onPressed: _busy ? null : _change),
      ]);
}

/// The devices signed in to the account, this one first; any other can be removed. In a browser, which keeps nothing
/// that can change the account (Account.keepsWords), the password comes first, and the account it opens is held by
/// this page while it is open, never kept.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, this.devices});

  /// The list to start from, for the pictures; otherwise it is asked of the relay.
  final List<AccountDevice>? devices;

  /// A day the relay keeps (YYYY-MM-DD, its own time's), as a person says it: today, yesterday, or 3 Nov 2026.
  static String dayOf(String ymd, {DateTime? now}) {
    final d = DateTime.tryParse(ymd);
    if (d == null) return ymd;
    final today = (now ?? DateTime.now()).toUtc();
    final days = DateTime.utc(today.year, today.month, today.day).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  /// What a device's row says under its name: this one, or when it was last seen; for a browser, when it signed in too,
  /// so one long forgotten (a private window closed without signing out) is found and removed.
  static String hintOf(AccountDevice d, {DateTime? now}) {
    if (d.here) return 'This device';
    final seen = 'Last seen ${dayOf(d.seen, now: now)}';
    return d.platform == 'web' && d.since.isNotEmpty ? 'A browser. $seen, signed in ${dayOf(d.since, now: now)}' : seen;
  }

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late List<AccountDevice>? _list = widget.devices;
  String? _problem;
  final _password = TextEditingController();
  AccountKeys? _keys;
  bool _busy = false;

  /// The password is wanted before anything can be asked.
  bool get _locked => _list == null && !Account.keepsWords && _keys == null;

  @override
  void initState() {
    super.initState();
    if (_list == null && Account.keepsWords) _load(Account.instance.devices);
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// The password typed: the account's keys are made from it and the devices asked for with them.
  Future<void> _open() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final keys = await Account.instance.keysWith(_password.text);
      if (!mounted) return;
      setState(() => _keys = keys);
      await _load(() => Account.instance.devices(keys: keys));
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'That did not work.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Shows the list [ask] answers with: the account's devices as asked for, or as left after removing one.
  Future<void> _load(Future<List<AccountDevice>> Function() ask) async {
    try {
      final list = await ask();
      if (mounted) setState(() => _list = list);
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'The list could not be read.');
    }
  }

  // A page in a browser ("web", lib/account/account.dart) is neither a phone nor a computer: a globe.
  static LucideIcon _iconOf(String platform) => platform == 'android' || platform == 'ios' ? Lucide.smartphone : platform == 'web' ? Lucide.globe : Lucide.laptop;

  @override
  Widget build(BuildContext context) {
    if (_locked) {
      return _AccountPage(title: 'Devices', children: [
        PaneSection(
          title: 'Your password first',
          description: const Tr('This browser keeps nothing that can change your account, so your password opens it for this page.'),
          footer: _problemText(context, _problem),
          children: [_field(_password, 'Password', 'Password', secret: true, autofill: 'current-password', onSubmitted: (_) => _open())],
        ),
        _gap(context, 8),
        PairButton(label: _busy ? 'Opening…' : 'Show my devices', icon: Lucide.laptop, onPressed: _busy ? null : _open),
      ]);
    }
    final list = [...?_list]..sort((a, b) => a.here == b.here ? 0 : (a.here ? -1 : 1));
    final keys = _keys;
    return _AccountPage(title: 'Devices', children: [
      PaneSection(
        title: 'Signed in on these devices',
        description: const Tr('Each one is your account. Remove one you no longer have. A browser is signed out within a few minutes, or as soon as it is next opened; a phone or a computer the next time it starts. A browser, an iPhone or a computer of its own then deletes everything of your account from itself, its other networks\' sign-ins and call recordings included. An Android phone, or a computer linked to one, is signed out and forgets your recovery words and its keys for circles and forward secrecy, and keeps its username, friends and conversations.'),
        footer: _problem != null ? _problemText(context, _problem) : _list == null ? const Tr('Asking the relay server…') : null,
        children: [
          for (final d in list)
            SettingRow(
              icon: _icon(_iconOf(d.platform)),
              label: d.name.isEmpty ? 'A device' : d.name,
              hint: Text(DevicesScreen.hintOf(d)),
              onPress: d.here
                  ? null
                  : () => showChoices(context, title: 'Remove ${d.name.isEmpty ? 'this device' : d.name} from your account?', choices: [
                        Choice('Remove', Lucide.trash2, () => _load(() => Account.instance.removeDevice(d.id, keys: keys)), danger: true),
                      ]),
            ),
        ],
      ),
      // The last time this device handed its conversations to another of the account (GMFB-53; Friends.historyKind):
      // said here, so a handover the person didn't make is seen, and the device it went to can be removed above.
      if (Account.instance.store.choice('history_note', '').isNotEmpty) ...[
        _gap(context),
        SettingsCallout(child: Text('${Account.instance.store.choice('history_note', '')}. Your conversations with friends go to each device signed in on your account, once. If you don\'t know that device, remove it and change your password.')),
      ],
      _gap(context),
      // Every device signed in is connected at once since the hub keeps each of a name's devices (relay/lib/hub.dart).
      const SettingsCallout(child: Tr('Every device signed in is connected as your account at once, and each gets what is sent to you. Each browser you sign in on, and each private window, is a device of its own here until it signs out or you remove it; an account has room for 20.')),
    ]);
  }
}

/// Where the relay doesn't hold the account (Account.unknownHere): the account put on it from this device and the device
/// listed under it (Account.listHereAgain), without signing in again, which would put the backup's friends and circles
/// in place of this device's. A browser asks the password first.
class ListHereAgainScreen extends StatefulWidget {
  const ListHereAgainScreen({super.key});

  @override
  State<ListHereAgainScreen> createState() => _ListHereAgainScreenState();
}

class _ListHereAgainScreenState extends State<ListHereAgainScreen> {
  final _password = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await Account.instance.listHereAgain(password: Account.keepsWords ? null : _password.text);
      if (!mounted) return;
      toast(context, Sms.browser ? 'This browser is listed under your account again' : 'This device is listed under your account again');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'That did not work.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final here = Sms.browser ? 'browser' : 'device';
    final what = Text('Your account is put on this relay server from this $here, with your profile, friends and circles as they are here, and this $here is listed under it. Nothing here changes.');
    return _AccountPage(title: Sms.browser ? 'List this browser again' : 'List this device again', children: [
      if (Account.keepsWords)
        PaneSection(title: 'On this relay', description: what, footer: _problemText(context, _problem), children: [
          SettingRow(icon: _icon(Lucide.shieldCheck), label: 'Your account', hint: Text(shortAddress(Account.instance.address ?? ''))),
        ])
      else
        PaneSection(
          title: 'Your password first',
          description: what,
          footer: _problemText(context, _problem),
          children: [_field(_password, 'Password', 'Password', secret: true, autofill: 'current-password', onSubmitted: (_) => _go())],
        ),
      _gap(context, 8),
      PairButton(label: _busy ? 'Listing…' : (Sms.browser ? 'List this browser' : 'List this device'), icon: Lucide.refreshCw, onPressed: _busy ? null : _go),
    ]);
  }
}

/// The backup brought up to date from a browser, after the password (Account.refreshWith): the profile, friends and
/// circles as they are here, put together with what the backup has, and sealed again both ways. Every other device
/// does this by itself once a day; a browser keeps nothing that could.
class UpdateBackupScreen extends StatefulWidget {
  const UpdateBackupScreen({super.key});

  @override
  State<UpdateBackupScreen> createState() => _UpdateBackupScreenState();
}

class _UpdateBackupScreenState extends State<UpdateBackupScreen> {
  final _password = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final done = await Account.instance.refreshWith(_password.text);
      if (!mounted) return;
      if (!done) return setState(() => _problem = 'The backup could not be sealed just now. Try again in a while.');
      toast(context, 'Backup up to date');
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _problem = e is AccountError ? e.message : 'That did not work.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AccountPage(title: 'Update your backup', children: [
        PaneSection(
          title: 'Your password first',
          description: const Tr('Your profile, friends and circles from this browser go into your backup beside what is there, so a device signing in next has them. It is sealed again with your password and your recovery words.'),
          footer: _problemText(context, _problem),
          children: [_field(_password, 'Password', 'Password', secret: true, autofill: 'current-password', onSubmitted: (_) => _go())],
        ),
        _gap(context, 8),
        PairButton(label: _busy ? 'Sealing…' : 'Update my backup', icon: Lucide.refreshCw, onPressed: _busy ? null : _go),
      ]);
}


/// The pref that says the recovery words were put off at sign-up ("Later"), so the conversations list reminds of them
/// until they are seen in Settings › Me (GMFB-3).
const wordsLater = 'words_later';
