/// Settings › Me and Settings › Friends joining (Matt, 2026-11-14: "Add a 'me' section to settings and allow linking
/// popular social like telegram, discord, x, etc to be notified when one of your friends or followers joins ghost
/// messaging"). What they show is lib/me/me.dart's; docs/me.md says what the relay server keeps of it.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/svg_path.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../me/network_marks.g.dart';
import '../plugins/company_marks.g.dart' show companyMarks;
import '../sms.dart';
import '../friends/buddies.dart';
import '../friends/handover.dart' show DeskHandover;
import 'account_screens.dart';
import 'common.dart';
import 'profile.dart';
import 'settings.dart';
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

Widget _icon(LucideIcon icon) => AppIcon(icon, size: 18);

/// A network's logo on the row's chip, in the chip's own colour (Matt, 2026-11-14: "use the real brandicons on the
/// icons for discord telegram and X and bluesky and github etc"): Simple Icons' mark (lib/me/network_marks.g.dart),
/// or its letter where the pack has none.
class NetworkMark extends StatelessWidget {
  const NetworkMark(this.network, {super.key, this.size = 18, this.badge = false, this.tint});

  /// The colour it is drawn in, in place of the network's own: white on a plugin's tile (lib/ui/plugins_page).
  final Color? tint;
  final Network network;
  final double size;

  /// Drawn as a badge on a face's corner (Matt, 2026-11-15: "Use the real brand icon for telegram chat indicators make
  /// it a bit larger and make the icon white"): the brand's disc with its mark in white. A mark that is a disc with
  /// the mark cut out of it (Telegram's) has white behind it; any other stands white on a disc of its colour.
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = IconTheme.of(context).color ?? t.color('app-ink');
    // Messenger, Instagram and LinkedIn: the marks the Codes tab already carries (lib/plugins/company_marks.g.dart).
    final logo = networkMarks[network.id] ?? inboxOnlyMarks[network.id] ?? companyMarks[_companyOf[network.id]];
    // In the network's own colour (Simple Icons' for each), where it has one that is not black: X and GitHub are
    // the page's ink, so they read on the dark page too. Dimmed with the row where it is not to be pressed.
    final brand = _brand[network.id];
    final color = tint ?? (brand ?? t.color('app-ink')).withValues(alpha: ink.a);
    if (logo == null) return Text(network.mark, style: pageText(t, size, weight: 'bold', color: tint ?? ink, height: 1.1));
    if (badge) {
      const white = Color(0xFFFFFFFF);
      final disc = _discs.contains(network.id);
      return Semantics(
        label: network.name,
        child: SizedBox.square(
          dimension: size,
          child: disc
              ? Stack(children: [
                  Positioned.fill(child: Padding(padding: EdgeInsets.all(size * 0.12), child: const DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: white)))),
                  CustomPaint(size: Size.square(size), painter: _LogoPainter(logo, color)),
                ])
              : DecoratedBox(
                  decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                  child: Padding(padding: EdgeInsets.all(size * 0.2), child: CustomPaint(painter: _LogoPainter(logo, white))),
                ),
        ),
      );
    }
    return Semantics(label: network.name, child: CustomPaint(size: Size.square(size), painter: _LogoPainter(logo, color)));
  }

  /// Marks that are a disc with the mark cut out of it.
  static const _discs = {'telegram'};

  static const _companyOf = {'messenger': 'messenger.com', 'instagram': 'instagram.com', 'linkedin': 'linkedin.com', 'discord': 'discord.com', 'twitter': 'x.com', 'slack': 'slack.com'};

  static const _brand = {
    'messenger': Color(0xFF0866FF),
    'instagram': Color(0xFFE4405F),
    'linkedin': Color(0xFF0A66C2),
    'signal': Color(0xFF3A76F0),
    'discord': Color(0xFF5865F2),
    'slack': Color(0xFF4A154B),
    'telegram': Color(0xFF26A5E4),
    'bluesky': Color(0xFF1185FE),
    'mastodon': Color(0xFF6364FF),
  };
}

/// One filled path on a 24 by 24 square, drawn to fit.
class _LogoPainter extends CustomPainter {
  const _LogoPainter(this.logo, this.color);
  final String logo;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(svgPath(logo), Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.logo != logo || old.color != color;
}

/// Speaks to the relay server as the page opens, where this install never has: nothing is said to it about handles
/// until someone comes here.
class _Wake extends StatefulWidget {
  const _Wake({this.seen = false});

  /// The page shows who joined: they are no longer new once it has been looked at and left.
  final bool seen;

  @override
  State<_Wake> createState() => _WakeState();
}

class _WakeState extends State<_Wake> {
  @override
  void initState() {
    super.initState();
    // On a computer, Settings › Me is the phone's: asked of it as the page opens (Me.followPhone).
    WidgetsBinding.instance.addPostFrameCallback((_) => Sms.followsPhone ? Me.instance.followPhone(Sms.instance.me) : Me.instance.wake());
  }

  @override
  void dispose() {
    // As the page is left, not as it opens: who is new is marked New while it is being looked at.
    if (widget.seen) Future.microtask(Me.instance.markSeen);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The line under Me in Settings' list: what is linked so far.
String meSummary(SettingsModel m) {
  final me = Me.instance;
  final have = [if (me.number != null) 'Number verified', for (final n in networks) if (me.links.containsKey(n.id)) n.name];
  return have.isEmpty ? 'Link your accounts' : have.join(', ');
}

/// The line under Friends joining in Settings' list: who is new, else how many handles are watched and how many came.
String friendsSummary(SettingsModel m) {
  final me = Me.instance;
  if (me.unseen > 0) return '${me.unseen} new';
  if (me.watch.isEmpty) return 'Hear when people you know join';
  return 'Watching for ${me.watch.length}${me.joined.isEmpty ? '' : ' · ${me.joined.length} here'}';
}

/// Settings › Me: the profile, the number, and each network's account to link.
List<Widget> mePane(BuildContext context, SettingsModel m) {
  final me = Me.instance;
  return [
    const _Wake(),
    // A username and a profile, and friends by username (lib/ui/profile.dart; Matt, 2026-11-14: "create a profile
    // and username under "me" to register a username and add friends on the platform").
    if (!Sms.followsPhone)
      PaneSection(
        title: 'Profile',
        children: [
          SettingRow(
            icon: _icon(Lucide.atSign),
            label: me.username == null ? 'Choose a username' : '@${me.username}',
            hint: Text(me.username == null ? 'So friends can find and add you' : (me.displayName.isEmpty ? 'Add your name and a line about you' : me.displayName)),
            onPress: () => push(context, (_) => const ProfileScreen()),
          ),
          SettingRow(
            icon: _icon(Lucide.users),
            label: 'Friends',
            hint: Text(Buddies.instance.requests.isNotEmpty
                ? '${Buddies.instance.requests.length} asked you'
                : Buddies.instance.shownFriends.isEmpty
                    ? 'Add friends by username'
                    : '${Buddies.instance.shownFriends.length} friend${Buddies.instance.shownFriends.length == 1 ? '' : 's'}'),
            onPress: () => push(context, (_) => const BuddiesScreen()),
          ),
        ],
      ),
    // An Uplink account (Matt, 2026-11-17: "We need to have a way to login to existing accounts"): made, signed in to,
    // and looked after wherever friends and circles run under this install's identity, a computer paired with a phone
    // that has taken on the phone's identity among them (Matt, 2026-11-18: "there doesn't seem to be a way to login on
    // desktop just to claim a username, i would like to be able to link a session to a new account"). A paired
    // computer that has not taken it on yet says where that stands, and asks again.
    if (Sms.ownNetwork) accountSection(context) else if (Sms.followsPhone) const _SameYou(),
    PaneSection(
      title: 'You',
      children: [
        _NumberRow(own: m.ownNumber),
        SettingRow(icon: _icon(Lucide.keyRound), label: 'Encryption key', value: Text(m.myKey ?? 'Made when first used')),
      ],
    ),
    if (Sms.followsPhone)
      SettingsCallout(child: Text(me.ready ? 'Accounts are linked on your phone. Your number can be verified from here: the code is texted to your phone.' : me.phoneSaid ?? 'Asking your phone…'))
    else if (!me.ready)
      SettingsCallout(child: Text(me.reachable ? 'Asking the relay server…' : 'Linking an account needs the relay server, which isn\'t connected right now (Settings › Routes).')),
    PaneSection(
      title: 'Linked accounts',
      description: const Tr('Show that an account is yours. Friends who asked to hear about that account are then told you\'re on Uplink, if you turn that on below.'),
      children: [for (final n in networks) _LinkRow(network: n)],
    ),
    PaneSection(
      title: 'Being found',
      footer: const Tr(
          'Off, nobody is told anything. On, someone who already knows one of your linked handles, and asked to hear about it, is told that it is on Uplink. They are not given your number, your name or your other accounts, and nobody is told about your number, verified or not. The relay server keeps a scrambled form of each linked handle, never the handle itself.'),
      children: [
        SettingRow(
          icon: _icon(Lucide.megaphone),
          label: 'Tell friends I\'m here',
          hint: Text(me.accounts.isEmpty ? 'Link an account first.' : 'People watching for ${me.accounts.length == 1 ? 'your account' : 'one of your accounts'} hear that you joined.'),
          control: GlacierSwitch(checked: me.listed, onCheckedChange: me.setListed, ariaLabel: 'Tell friends I\'m here', disabled: Sms.followsPhone && !me.ready),
        ),
      ],
    ),
    PaneSection(
      title: 'Your data',
      children: [
        SettingRow(
          icon: _icon(Lucide.trash2),
          label: 'Remove everything about me',
          hint: const Tr('Unlinks every account and your number, and clears the people you watch for, on this phone and on the relay server.'),
          disabled: !me.ready || (me.links.isEmpty && me.watch.isEmpty && !me.listed),
          onPress: () => showChoices(context, title: 'Unlink every account and clear your watch list? Friends will no longer be told you\'re here.', choices: [
            Choice('Remove everything', Lucide.trash2, () async {
              try {
                await me.forgetEverything();
                if (context.mounted) toast(context, 'Removed');
              } catch (e) {
                if (context.mounted) toast(context, 'Cleared on this phone. The relay server will be told when it next answers.', tone: GlacierToastTone.danger);
              }
            }, danger: true),
          ]),
        ),
      ],
    ),
  ];
}

/// This phone's number on the Me page: what the phone says it is, and whether a code texted to it has shown it to
/// be (Matt, 2026-11-14: "send the text code to a number to verify so it can't be spoofed").
class _NumberRow extends StatelessWidget implements PaneRow {
  const _NumberRow({required this.own});

  /// What Android, or the person, says this phone's number is.
  final String? own;

  @override
  Widget build(BuildContext context) {
    final me = Me.instance;
    final icon = _icon(Lucide.phone);
    final verified = me.number;
    if (verified != null) {
      final shown = showNumber(verified);
      return SettingRow(
        icon: icon,
        label: 'Number',
        hint: const Tr('Verified'),
        value: Text(shown),
        onPress: () => showChoices(context, title: '$shown is verified: a code texted to it reached this phone.', choices: [
          Choice('Copy number', Lucide.copy, () {
            Clipboard.setData(ClipboardData(text: verified));
            toast(context, 'Copied');
          }),
          Choice('Remove verification', Lucide.unlink, () async {
            await me.unlink('phone');
            if (context.mounted) toast(context, 'Number no longer verified');
          }, danger: true),
        ]),
      );
    }
    final tidy = tidyNumber(own ?? '');
    final shown = Text(own == null || own!.isEmpty ? 'Not known' : (numberFits(tidy) ? showNumber(tidy) : own!));
    // On a computer it is verified through the phone (Me.followPhone), as on the phone itself.
    // Short words here, beside the number; the page it opens has room for why and how.
    return SettingRow(icon: icon, label: 'Number', hint: const Tr('Not verified'), value: shown, onPress: me.ready ? () => push<void>(context, (_) => NumberScreen(own: own)) : null);
  }
}

/// Showing a number is this phone's: the number, a code texted to it by the relay server's texting service, and
/// the code back. The code is read from the text as it arrives, so most of the time nothing is typed.
class NumberScreen extends StatefulWidget {
  const NumberScreen({super.key, this.own});
  final String? own;

  @override
  State<NumberScreen> createState() => _NumberScreenState();
}

class _NumberScreenState extends State<NumberScreen> {
  late final TextEditingController _number;
  final _code = TextEditingController();
  StreamSubscription<int>? _arrivals;

  /// The number a code was texted to, and when it was asked for.
  String? _sentTo;
  DateTime? _askedAt;

  /// A code that arrived before the server said it was sent: a text can be the quicker of the two.
  String? _early;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final own = tidyNumber(widget.own ?? '');
    _number = TextEditingController(text: numberFits(own) ? showNumber(own) : '');
    _arrivals = Sms.instance.changes.stream.listen(_arrived);
    Me.instance.addListener(_meChanged);
  }

  /// Whether the server can text a code is its to say, and it may say so after this page opens.
  void _meChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    Me.instance.removeListener(_meChanged);
    _arrivals?.cancel();
    _number.dispose();
    _code.dispose();
    super.dispose();
  }

  /// A conversation changed: where its newest text is the code asked for, the code is put in and checked. Only a
  /// text that arrived after the asking is read: a text's time is this phone's clock as it arrived (Messaging.kt),
  /// the clock [_askedAt] is read from.
  Future<void> _arrived(int thread) async {
    final since = _askedAt;
    if (since == null || thread < 0) return;
    try {
      // On a computer a text's time is the phone's clock and [since] this computer's: two minutes either way allowed.
      final from = Sms.paired ? since.subtract(const Duration(minutes: 2)) : since;
      final newest = (await Sms.instance.messages(thread, limit: 3)).where((m) => !m.outgoing && !m.date.isBefore(from));
      for (final m in newest) {
        final code = ownCodeIn(m.body);
        if (code == null || !mounted) continue;
        if (_sentTo == null || _busy) {
          _early = code;
        } else {
          _code.text = code;
          await _check();
        }
        return;
      }
    } catch (_) {
      // Not read: the code can still be typed.
    }
  }

  /// Asks for a code to be texted to the number typed; one that arrived before the server answered is checked at once.
  Future<void> _send() async {
    final number = tidyNumber(_number.text);
    if (!numberFits(number)) {
      setState(() => _problem = 'That doesn\'t look like a whole phone number. Write it with its country code, like +1 555 010 0199.');
      return;
    }
    setState(() { _busy = true; _problem = null; });
    // To the millisecond, as a text's time is kept.
    _askedAt = DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch);
    _early = null;
    try {
      final to = await Me.instance.textCode(number);
      if (mounted) setState(() { _sentTo = to; _code.clear(); });
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    final early = _early;
    _early = null;
    if (early != null && mounted && _sentTo != null) {
      _code.text = early;
      await _check();
    }
  }

  Future<void> _check() async {
    final number = _sentTo;
    final code = _code.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (number == null) return;
    if (code.length < 4) {
      setState(() => _problem = 'Type the code from the text.');
      return;
    }
    setState(() { _busy = true; _problem = null; });
    try {
      await Me.instance.tryCode(number, code);
      if (!mounted) return;
      toast(context, '${showNumber(number)} is verified');
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final sent = _sentTo;
    final problem = _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger));
    return GlacierScope(
      attrs: const {'hue': 'green'},
      child: GhostPage(
        title: 'Verify your number',
        body: SettingsPaneScope(
          finder: SettingsFinder(),
          child: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              PaneSection(
                title: 'Your number',
                description: const Tr('A code is texted to this number, and coming back it shows the number is this phone\'s. The relay server and the texting service it uses see the number. Nobody else is told it.'),
                footer: sent == null ? problem : null,
                children: [
                  SettingRowBox(
                    child: GlacierInput(
                      controller: _number,
                      type: GlacierInputType.tel,
                      placeholder: '+1 555 010 0199'.t,
                      ariaLabel: 'Your phone number',
                      autoFocus: _number.text.isEmpty,
                      autoCorrect: false,
                      size: GlacierFieldSize.md,
                      onChange: (_) {
                        if (_sentTo != null) setState(() { _sentTo = null; _askedAt = null; _problem = null; });
                      },
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  if (sent == null)
                    Me.instance.texts
                        ? SettingRow(icon: _icon(Lucide.messageSquare), label: _busy ? 'Sending…' : 'Text me a code', disabled: _busy, onPress: _send)
                        : SettingRow(
                            icon: _icon(Lucide.messageSquare),
                            label: 'Text me a code',
                            hint: Text(Me.instance.ready ? 'Verifying a number by text isn\'t set up on the relay server yet.' : 'This needs the relay server, which isn\'t connected right now (Settings › Routes).'),
                            disabled: true,
                          ),
                ],
              ),
              if (sent != null) ...[
                SizedBox(height: t.space(6)),
                PaneSection(
                  title: 'The code',
                  description: Text('Texted to ${showNumber(sent)}. It is read from the text as it arrives; you can type it too. It lasts ten minutes.'),
                  footer: problem,
                  children: [
                    SettingRowBox(
                      child: GlacierInput(
                        controller: _code,
                        type: GlacierInputType.number,
                        placeholder: '482913'.t,
                        ariaLabel: 'The code from the text',
                        autoCorrect: false,
                        maxLength: 10,
                        size: GlacierFieldSize.md,
                        onSubmitted: (_) => _check(),
                      ),
                    ),
                    SettingRow(icon: _icon(Lucide.check), label: _busy ? 'Checking…' : 'Check the code', disabled: _busy, onPress: _check),
                    SettingRow(icon: _icon(Lucide.refreshCw), label: 'Send it again', disabled: _busy, onPress: _send),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One network on the Me page: linked with its handle, or how it is linked.
class _LinkRow extends StatelessWidget implements PaneRow {
  const _LinkRow({required this.network});
  final Network network;

  Future<void> _signIn(BuildContext context) async {
    try {
      final address = await Me.instance.signInAddress(network.id);
      final opened = await Sms.instance.openLink(address);
      if (!context.mounted) return;
      toast(context, opened ? 'Sign in with ${network.name} in your browser. This page updates when it\'s done.' : 'No browser could be opened.', tone: opened ? GlacierToastTone.neutral : GlacierToastTone.danger);
    } catch (e) {
      if (context.mounted) toast(context, '$e', tone: GlacierToastTone.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = Me.instance;
    final n = network;
    final handle = me.links[n.id];
    final mark = NetworkMark(n);
    if (handle != null) {
      final page = n.profile(handle);
      return SettingRow(
        icon: mark,
        label: n.name,
        value: Text('@$handle'),
        onPress: () => showChoices(context, title: '@$handle on ${n.name}', choices: [
          if (page != null) Choice('Open profile', Lucide.externalLink, () => Sms.instance.openLink(page)),
          Choice('Copy handle', Lucide.copy, () {
            Clipboard.setData(ClipboardData(text: handle));
            toast(context, 'Copied');
          }),
          Choice('Unlink', Lucide.unlink, () async {
            await me.unlink(n.id);
            if (context.mounted) toast(context, '${n.name} unlinked');
          }, danger: true),
        ]),
      );
    }
    if (n.soon) return SettingRow(icon: mark, label: n.name, hint: const Tr('Coming soon'), disabled: true);
    if (Sms.followsPhone || !me.ready) return SettingRow(icon: mark, label: n.name, hint: const Tr('Not linked'), disabled: true);
    if (n.signIn && me.ways[n.id] != 'signin') {
      return SettingRow(icon: mark, label: n.name, hint: Text('Signing in with ${n.name} isn\'t set up on the relay server yet.'), disabled: true);
    }
    return SettingRow(
      icon: mark,
      label: n.name,
      hint: Text(n.signIn ? 'Sign in with ${n.name} to link it' : 'Link with a code in your profile'),
      onPress: n.signIn ? () => _signIn(context) : () => push<void>(context, (_) => ProofScreen(network: n)),
    );
  }
}

/// Linking an account by a code in its public profile (Bluesky, Mastodon, GitHub): the handle, the code the relay
/// server makes for it, and the check.
class ProofScreen extends StatefulWidget {
  const ProofScreen({super.key, required this.network});
  final Network network;

  @override
  State<ProofScreen> createState() => _ProofScreenState();
}

class _ProofScreenState extends State<ProofScreen> {
  final _handle = TextEditingController();
  String? _code;
  String? _for;
  String? _problem;
  bool _busy = false;

  Network get n => widget.network;

  @override
  void dispose() {
    _handle.dispose();
    super.dispose();
  }

  /// Asks the relay server for the code to put in the profile of the handle typed.
  Future<void> _getCode() async {
    final handle = tidyHandle(_handle.text);
    if (!handleFits(n.id, handle)) {
      setState(() => _problem = 'That doesn\'t look like a ${n.name} handle. It looks like ${n.example}.');
      return;
    }
    setState(() { _busy = true; _problem = null; });
    try {
      final code = await Me.instance.proofCode(n.id, handle);
      if (mounted) setState(() { _code = code; _for = handle; });
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Has the relay server look for the code in the profile; found, the account is linked and the screen leaves.
  Future<void> _check() async {
    final handle = _for;
    if (handle == null) return;
    setState(() { _busy = true; _problem = null; });
    try {
      await Me.instance.check(n.id, handle);
      if (!mounted) return;
      toast(context, '@$handle on ${n.name} is linked');
      Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final code = _code;
    return GlacierScope(
      attrs: {'hue': n.hue},
      child: GhostPage(
        title: 'Link ${n.name}',
        body: SettingsPaneScope(
          finder: SettingsFinder(),
          child: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              PaneSection(
                title: 'Your handle',
                footer: _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger)),
                children: [
                  SettingRowBox(
                    child: GlacierInput(
                      controller: _handle,
                      placeholder: n.example,
                      ariaLabel: 'Your ${n.name} handle',
                      autoFocus: true,
                      autoCorrect: false,
                      autoCapitalize: TextCapitalization.none,
                      size: GlacierFieldSize.md,
                      onChange: (_) {
                        if (_code != null) setState(() { _code = null; _for = null; });
                      },
                      onSubmitted: (_) => _getCode(),
                    ),
                  ),
                  if (code == null) SettingRow(icon: _icon(Lucide.keyRound), label: _busy ? 'Asking…' : 'Get my code', disabled: _busy, onPress: _getCode),
                ],
              ),
              if (code != null) ...[
                SizedBox(height: t.space(6)),
                PaneSection(
                  title: 'Your code',
                  description: Text('Put this code anywhere in ${n.where} and save. That shows the account is yours: only its owner can change its profile. You can take the code out again once it\'s linked.'),
                  children: [
                    SettingRow(
                      icon: _icon(Lucide.copy),
                      label: code,
                      value: const Tr('Copy'),
                      onPress: () {
                        Clipboard.setData(ClipboardData(text: code));
                        toast(context, 'Code copied');
                      },
                    ),
                    if (n.profile(_for!) != null) SettingRow(icon: _icon(Lucide.externalLink), label: 'Open my ${n.name} profile', onPress: () => Sms.instance.openLink(n.profile(_for!)!)),
                    SettingRow(icon: _icon(Lucide.check), label: _busy ? 'Checking…' : 'I\'ve added it: check', disabled: _busy, onPress: _check),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _when(DateTime at) => listWhen(at);

/// Settings › Friends joining: who of the watched has come, the handles watched for, and ways to add more.
List<Widget> friendsPane(BuildContext context, SettingsModel m) {
  final me = Me.instance;
  final importable = [for (final n in networks) if (n.follows && me.links.containsKey(n.id)) n];
  return [
    const _Wake(seen: true),
    PaneSection(
      title: 'On Uplink',
      children: [
        if (me.joined.isEmpty)
          const SettingRow(label: 'Nobody yet', hint: Tr('When someone you watch for links their account and chooses to be found, they show here.'))
        else
          for (final j in me.joined) _JoinedRow(joined: j),
      ],
    ),
    PaneSection(
      title: 'Watching for',
      description: const Tr('The handles you want to hear about. Discord, Telegram and X don\'t let an app read your friends or followers, so add those yourself.'),
      footer: Text(me.watch.isEmpty
          ? 'The relay server is given a scrambled form of each handle, never the handle itself.'
          : '${me.watch.length} ${me.watch.length == 1 ? 'handle' : 'handles'}. The relay server holds a scrambled form of each, never the handle itself.'),
      children: [
        SettingRow(icon: _icon(Lucide.plus), label: 'Add handles', hint: const Tr('Type or paste as many as you like.'), disabled: Sms.followsPhone, onPress: () => push<void>(context, (_) => const AddWatchScreen())),
        for (final n in importable) _ImportRow(network: n),
        for (final n in networks)
          if (me.watch.any((w) => w.network == n.id))
            SettingRow(
              icon: NetworkMark(n),
              label: n.name,
              value: Text('${me.watch.where((w) => w.network == n.id).length}'),
              onPress: () => push<void>(context, (_) => WatchListScreen(network: n)),
            ),
      ],
    ),
  ];
}

/// Someone watched for who has joined: their handle and network, New until the page has been looked at and left.
class _JoinedRow extends StatelessWidget implements PaneRow {
  const _JoinedRow({required this.joined});
  final Joined joined;

  @override
  Widget build(BuildContext context) {
    final n = networkOf(joined.network);
    final page = n.profile(joined.handle);
    return SettingRow(
      icon: NetworkMark(n),
      label: '@${joined.handle}',
      labelAfter: joined.seen ? null : Padding(padding: const EdgeInsetsDirectional.only(start: 8), child: const GlacierPill(size: GlacierPillSize.sm, child: Tr('New'))),
      hint: Text('${n.name} · joined ${_when(joined.at)}'),
      onPress: () => showChoices(context, title: '@${joined.handle} from ${n.name} is on Uplink. Ask them for their number there to start a conversation here.', choices: [
        if (page != null) Choice('Open their ${n.name} profile', Lucide.externalLink, () => Sms.instance.openLink(page)),
        Choice('Copy handle', Lucide.copy, () {
          Clipboard.setData(ClipboardData(text: joined.handle));
          toast(context, 'Copied');
        }),
        Choice('Stop watching for them', Lucide.eyeOff, () => Me.instance.removeWatch(Watched(joined.network, joined.handle)), danger: true),
      ]),
    );
  }
}

/// Brings in everyone the linked account follows on [network], to watch for.
class _ImportRow extends StatefulWidget implements PaneRow {
  const _ImportRow({required this.network});
  final Network network;

  @override
  State<_ImportRow> createState() => _ImportRowState();
}

class _ImportRowState extends State<_ImportRow> {
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    try {
      final added = await Me.instance.importFollows(widget.network.id);
      if (mounted) toast(context, added == 0 ? 'Nobody new to add' : 'Watching for $added more from ${widget.network.name}');
    } catch (e) {
      if (mounted) toast(context, '$e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingRow(
        icon: _icon(Lucide.download),
        label: _busy ? 'Reading who you follow…' : 'Bring in who I follow on ${widget.network.name}',
        hint: Text('@${Me.instance.links[widget.network.id]}'),
        disabled: _busy || !Me.instance.ready,
        onPress: _go,
      );
}

/// Adding handles to watch for: a network, and as many handles as are typed or pasted.
class AddWatchScreen extends StatefulWidget {
  const AddWatchScreen({super.key});

  @override
  State<AddWatchScreen> createState() => _AddWatchScreenState();
}

class _AddWatchScreenState extends State<AddWatchScreen> {
  String _network = openNetworks.first.id;
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Watches for every handle typed that fits the network, and says how many were added and how many didn't fit.
  void _add() {
    final all = Me.split(_text.text);
    final fits = all.where((h) => handleFits(_network, h)).toList();
    final added = Me.instance.addWatch(_network, fits);
    final skipped = all.length - fits.length;
    final n = networkOf(_network);
    toast(
      context,
      [
        added == 0 ? 'Nothing new to add' : 'Watching for $added on ${n.name}',
        if (skipped > 0) '$skipped didn\'t look like ${n.name} handles',
      ].join('. '),
    );
    if (added > 0) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = networkOf(_network);
    final count = Me.split(_text.text).length;
    final ink = pageText(t, t.fontSize('md'), color: t.color('app-ink'), height: 1.4);
    return GlacierScope(
      attrs: {'hue': n.hue},
      child: GhostPage(
        title: 'Add handles',
        body: SettingsPaneScope(
          finder: SettingsFinder(),
          child: ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              PaneSection(
                title: 'Where',
                children: [
                  for (final net in openNetworks)
                    SettingRow(
                      icon: NetworkMark(net),
                      label: net.name,
                      control: Pick(checked: net.id == _network, label: 'On ${net.name}', onPress: () => setState(() => _network = net.id)),
                    ),
                ],
              ),
              SizedBox(height: t.space(6)),
              PaneSection(
                title: 'Handles',
                description: Text('One or many, separated by spaces, commas or new lines. On ${n.name} a handle looks like ${n.example}.'),
                children: [
                  SettingRowBox(
                    child: GestureDetector(
                      onTap: _focus.requestFocus,
                      child: Container(
                        constraints: BoxConstraints(minHeight: t.lenOf('6rem')),
                        padding: EdgeInsets.all(t.space(3)),
                        decoration: BoxDecoration(color: t.color('app-paper-3'), borderRadius: BorderRadius.circular(t.radius('md'))),
                        child: Stack(children: [
                          if (_text.text.isEmpty) IgnorePointer(child: Tr('@maya  @jordan  @sam', style: ink.copyWith(color: t.color('app-ink-3')))),
                          EditableText(
                            controller: _text,
                            focusNode: _focus,
                            style: ink,
                            cursorColor: t.color('app-ink'),
                            backgroundCursorColor: t.color('app-ink-3'),
                            selectionColor: t.textSelection,
                            minLines: 3,
                            maxLines: 10,
                            keyboardType: TextInputType.multiline,
                            autocorrect: false,
                            enableSuggestions: false,
                            textCapitalization: TextCapitalization.none,
                          ),
                        ]),
                      ),
                    ),
                  ),
                  SettingRow(
                    icon: _icon(Lucide.plus),
                    label: count == 0 ? 'Watch for them' : 'Watch for $count on ${n.name}',
                    disabled: count == 0,
                    onPress: _add,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The handles watched for on one network, each taken off by a press.
class WatchListScreen extends StatelessWidget {
  const WatchListScreen({super.key, required this.network});
  final Network network;

  @override
  Widget build(BuildContext context) {
    final n = network;
    return GlacierScope(
      attrs: {'hue': n.hue},
      child: ListenableBuilder(
        listenable: Me.instance,
        builder: (context, _) {
          final t = context.tokens;
          final me = Me.instance;
          final mine = me.watch.where((w) => w.network == n.id).toList();
          final here = {for (final j in me.joined) if (j.network == n.id) j.handle};
          return GhostPage(
            title: '${n.name} · ${mine.length}',
            body: SettingsPaneScope(
              finder: SettingsFinder(),
              child: ListView(
                padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
                children: [
                  PaneSection(
                    children: [
                      if (mine.isEmpty) const SettingRow(label: 'Nobody', hint: Tr('Add handles from Friends joining.')),
                      for (final w in mine.take(400))
                        SettingRow(
                          label: '@${w.handle}',
                          value: here.contains(w.handle) ? const Tr('Here') : null,
                          onPress: () => showChoices(context, title: '@${w.handle} on ${n.name}', choices: [
                            if (n.profile(w.handle) != null) Choice('Open profile', Lucide.externalLink, () => Sms.instance.openLink(n.profile(w.handle)!)),
                            Choice('Stop watching for them', Lucide.eyeOff, () => me.removeWatch(w), danger: true),
                          ]),
                        ),
                    ],
                  ),
                  if (mine.length > 400)
                    Padding(
                      padding: EdgeInsets.all(t.space(4)),
                      child: Text('And ${mine.length - 400} more.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Logos of the networks whose chats are in Messages but which Settings › Me does not link (lib/inbox): from Simple
/// Icons 16.37.0 (CC0 1.0; simpleicons.org), one path on a 24 by 24 square. The marks are trademarks of their owners.
/// Simple Icons carries no Microsoft marks, so Microsoft Teams shows its letter.
const Map<String, String> inboxOnlyMarks = {
  // Signal
  'signal': 'M12 0q-.934 0-1.83.139l.17 1.111a11 11 0 0 1 3.32 0l.172-1.111A12 12 0 0 0 12 0M9.152.34A12 12 0 0 0 5.77 1.742l.584.961a10.8 10.8 0 0 1 3.066-1.27zm5.696 0-.268 1.094a10.8 10.8 0 0 1 3.066 1.27l.584-.962A12 12 0 0 0 14.848.34M12 2.25a9.75 9.75 0 0 0-8.539 14.459c.074.134.1.292.064.441l-1.013 4.338 4.338-1.013a.62.62 0 0 1 .441.064A9.7 9.7 0 0 0 12 21.75c5.385 0 9.75-4.365 9.75-9.75S17.385 2.25 12 2.25m-7.092.068a12 12 0 0 0-2.59 2.59l.909.664a11 11 0 0 1 2.345-2.345zm14.184 0-.664.909a11 11 0 0 1 2.345 2.345l.909-.664a12 12 0 0 0-2.59-2.59M1.742 5.77A12 12 0 0 0 .34 9.152l1.094.268a10.8 10.8 0 0 1 1.269-3.066zm20.516 0-.961.584a10.8 10.8 0 0 1 1.27 3.066l1.093-.268a12 12 0 0 0-1.402-3.383M.138 10.168A12 12 0 0 0 0 12q0 .934.139 1.83l1.111-.17A11 11 0 0 1 1.125 12q0-.848.125-1.66zm23.723.002-1.111.17q.125.812.125 1.66c0 .848-.042 1.12-.125 1.66l1.111.172a12.1 12.1 0 0 0 0-3.662M1.434 14.58l-1.094.268a12 12 0 0 0 .96 2.591l-.265 1.14 1.096.255.36-1.539-.188-.365a10.8 10.8 0 0 1-.87-2.35m21.133 0a10.8 10.8 0 0 1-1.27 3.067l.962.584a12 12 0 0 0 1.402-3.383zm-1.793 3.848a11 11 0 0 1-2.345 2.345l.664.909a12 12 0 0 0 2.59-2.59zm-19.959 1.1L.357 21.48a1.8 1.8 0 0 0 2.162 2.161l1.954-.455-.256-1.095-1.953.455a.675.675 0 0 1-.81-.81l.454-1.954zm16.832 1.769a10.8 10.8 0 0 1-3.066 1.27l.268 1.093a12 12 0 0 0 3.382-1.402zm-10.94.213-1.54.36.256 1.095 1.139-.266c.814.415 1.683.74 2.591.961l.268-1.094a10.8 10.8 0 0 1-2.35-.869zm3.634 1.24-.172 1.111a12.1 12.1 0 0 0 3.662 0l-.17-1.111q-.812.125-1.66.125a11 11 0 0 1-1.66-.125',
  // Matrix
  'matrix': 'M.632.55v22.9H2.28V24H0V0h2.28v.55zm7.043 7.26v1.157h.033c.309-.443.683-.784 1.117-1.024.433-.245.936-.365 1.5-.365.54 0 1.033.107 1.481.314.448.208.785.582 1.02 1.108.254-.374.6-.706 1.034-.992.434-.287.95-.43 1.546-.43.453 0 .872.056 1.26.167.388.11.716.286.993.53.276.245.489.559.646.951.152.392.23.863.23 1.417v5.728h-2.349V11.52c0-.286-.01-.559-.032-.812a1.755 1.755 0 0 0-.18-.66 1.106 1.106 0 0 0-.438-.448c-.194-.11-.457-.166-.785-.166-.332 0-.6.064-.803.189a1.38 1.38 0 0 0-.48.499 1.946 1.946 0 0 0-.231.696 5.56 5.56 0 0 0-.06.785v4.768h-2.35v-4.8c0-.254-.004-.503-.018-.752a2.074 2.074 0 0 0-.143-.688 1.052 1.052 0 0 0-.415-.503c-.194-.125-.476-.19-.854-.19-.111 0-.259.024-.439.074-.18.051-.36.143-.53.282-.171.138-.319.337-.439.595-.12.259-.18.6-.18 1.02v4.966H5.46V7.81zm15.693 15.64V.55H21.72V0H24v24h-2.28v-.55z',
  // WhatsApp
  'whatsapp': 'M17.472 14.382c-.297-.149-1.758-.867-2.03-.967-.273-.099-.471-.148-.67.15-.197.297-.767.966-.94 1.164-.173.199-.347.223-.644.075-.297-.15-1.255-.463-2.39-1.475-.883-.788-1.48-1.761-1.653-2.059-.173-.297-.018-.458.13-.606.134-.133.298-.347.446-.52.149-.174.198-.298.298-.497.099-.198.05-.371-.025-.52-.075-.149-.669-1.612-.916-2.207-.242-.579-.487-.5-.669-.51-.173-.008-.371-.01-.57-.01-.198 0-.52.074-.792.372-.272.297-1.04 1.016-1.04 2.479 0 1.462 1.065 2.875 1.213 3.074.149.198 2.096 3.2 5.077 4.487.709.306 1.262.489 1.694.625.712.227 1.36.195 1.871.118.571-.085 1.758-.719 2.006-1.413.248-.694.248-1.289.173-1.413-.074-.124-.272-.198-.57-.347m-5.421 7.403h-.004a9.87 9.87 0 01-5.031-1.378l-.361-.214-3.741.982.998-3.648-.235-.374a9.86 9.86 0 01-1.51-5.26c.001-5.45 4.436-9.884 9.888-9.884 2.64 0 5.122 1.03 6.988 2.898a9.825 9.825 0 012.893 6.994c-.003 5.45-4.437 9.884-9.885 9.884m8.413-18.297A11.815 11.815 0 0012.05 0C5.495 0 .16 5.335.157 11.892c0 2.096.547 4.142 1.588 5.945L.057 24l6.305-1.654a11.882 11.882 0 005.683 1.448h.005c6.554 0 11.89-5.335 11.893-11.893a11.821 11.821 0 00-3.48-8.413Z',
  // Google Chat
  'googlechat': 'M1.637 0C.733 0 0 .733 0 1.637v16.5c0 .904.733 1.636 1.637 1.636h3.955v3.323c0 .804.97 1.207 1.539.638l3.963-3.96h11.27c.903 0 1.636-.733 1.636-1.637V5.592L18.408 0Zm3.955 5.592h12.816v8.59H8.455l-2.863 2.863Z',
};

/// On a paired computer that has not yet taken on the phone's identity (lib/desktop/main.dart's handover): why not,
/// and a way to ask again. Until then friends, the profile and the account are the phone's, and nothing can be signed
/// in to here (Matt, 2026-11-18: "it seems i'm not logged in on desktop").
class _SameYou extends StatelessWidget {
  const _SameYou();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
        valueListenable: DeskHandover.state,
        builder: (context, s, _) {
          final (hint, canAsk) = switch (s.phase) {
            'old' => ('Update Uplink on your phone, then this computer can have your friends, circles and account itself.', false),
            'asking' => ('Asking your phone…', false),
            'done' => ('Done. Uplink opens again.', false),
            'failed' => (s.problem == null || s.problem!.isEmpty ? 'Your phone didn\'t answer. Open Uplink on it, then try again.' : s.problem!, true),
            _ => ('Waiting for your phone to connect.', true),
          };
          return PaneSection(
            title: 'Account',
            description: const Tr('Your phone hands over who you are, your friends and your conversations with them, so this computer is the same you, with your phone switched off too. Then you can sign in to your Uplink account here.'),
            children: [
              SettingRow(
                icon: _icon(Lucide.refreshCw),
                label: 'Become the same you as your phone',
                hint: Text(hint),
                disabled: !canAsk || DeskHandover.retry == null,
                onPress: () => DeskHandover.retry?.call(),
              ),
            ],
          );
        },
      );
}
