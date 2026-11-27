/// The admin page (Matt, 2026-11-19: "create a simple admin page for me to login to in order to issue souls with a pre
/// generated username and password hidden behind developer mode with a admin page login or some other way to make sure
/// only my matt account can access it and allow me to see all users who signed up on the relay and issue special badges
/// and souls").
///
/// Settings › Admin, there only in developer mode and only for @matt. Signed in with the admin username and password
/// (made by tool/admin-password.mjs, the relay keeping only the password's hash), and the relay answers only Matt's
/// account signed in so (relay/lib/handles.dart): everyone who signed up, searched; each one's souls and badges given or
/// taken; and the last of what was given.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show Clipboard, ClipboardData, TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../market/market_api.dart';
import '../market/market_state.dart';
import '../me/me.dart';
import '../plugins/pack/pack.dart' show InstalledPlugins, isReviewKey, signRetirement;
import '../sms.dart';
import 'common.dart';
import 'market/market_forms.dart' show openSettingsMe;
import 'market/people_reports_page.dart';
import 'market/review_queue.dart';
import 'settings.dart';
import 'souls.dart';
import 'plugins_page/plugin_art.dart' show PluginHues;
import 'special_badges.dart';
import '../l10n/words.dart';

/// Whether the admin page is offered: developer mode on, and this is Matt's account.
bool adminOffered(SettingsModel m) => adminOfferedFor(m.app);

/// The same from the app's choices alone: the Marketplace's Review queue is offered by it, with no Settings round it.
bool adminOfferedFor(AppState app) => app.flag('dev_mode', fallback: false) && adminNames.contains(Me.instance.username);

/// The Uplink usernames the admin page is offered to (the relay's GHOST_ADMIN_NAMES says who it answers).
const adminNames = {'matt'};

/// Settings › Admin's pane, as Settings lists its panes.
List<Widget> adminPane(BuildContext context, SettingsModel m) => const [AdminPanel()];

/// Someone as the admin page lists them.
class AdminUser {
  AdminUser(Map j)
      : id = '${j['id']}',
        name = j['name'] is String ? j['name'] as String : null,
        named = j['named'] == true,
        since = j['at'] is String ? j['at'] as String : null,
        verified = j['verified'] == true,
        links = [for (final l in (j['links'] as List? ?? const [])) '$l'],
        souls = j['souls'] is int ? j['souls'] as int : 0,
        special = [for (final b in (j['special'] as List? ?? const [])) '$b'],
        here = j['here'] == true,
        account = j['account'] is String ? j['account'] as String : null,
        was = [for (final n in (j['was'] as List? ?? const [])) '$n'];
  final String id;
  final String? name;
  final bool named;
  final String? since;
  final bool verified;
  final List<String> links;
  int souls;
  List<String> special;
  final bool here;

  /// The Uplink account they signed up or signed back in with (0x…), the same on every device and after a reinstall
  /// (Matt, 2026-11-20: "tie users names to their accounts when they sign back in later or reconnect to the app so that we
  /// can give out bug bounties properly"); null where they have none.
  final String? account;

  /// The usernames they held before this one, newest last: a ticket filed under an old name still finds them.
  final List<String> was;

  /// Whether [q] (lower case, no @) finds them: a username now or before, the start of their id or of their account.
  bool matches(String q) => q.isEmpty || (name ?? '').contains(q) || was.any((n) => n.contains(q)) || id.startsWith(q) || (account?.toLowerCase().startsWith(q) ?? false);

  /// What they are called in a row: their username, or that they have none the relay has told.
  String get shown => name != null ? '@$name' : (named ? 'A username from before (not said yet)' : 'No username');
}

/// The admin sign-in (the admin username and password over this device's hub, only for @matt's account): Settings ›
/// Admin's, and the review queue's and a submission's when the relay has signed the admin out (it restarted, or the
/// sign-in is older than the half hour an approval needs), so the reviewer signs in where they are and loses nothing.
class AdminSignIn extends StatefulWidget {
  const AdminSignIn({super.key, required this.onDone, this.ask});

  /// Signed in: what follows (Settings › Admin's lists, the queue read again, a decision sent again). What it throws is
  /// said under the fields.
  final Future<void> Function() onDone;

  /// For a test: the relay's answers, in place of Me.admin.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask;

  @override
  State<AdminSignIn> createState() => _AdminSignInState();
}

class _AdminSignInState extends State<AdminSignIn> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  /// Sends the admin username and password; once the relay says yes the password is cleared and [onDone] runs.
  Future<void> _signIn() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final got = await (widget.ask ?? Me.instance.admin)({'dir': 'admin-login', 'user': _user.text.trim(), 'pass': _pass.text});
      if (got['ok'] != true) throw MeError('${got['err'] ?? 'That isn\'t right.'}');
      _pass.clear();
      await widget.onDone();
    } catch (e) {
      if (mounted) setState(() => _problem = e is MeError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return PaneSection(
      title: 'Admin sign-in',
      description: const Tr('The admin username and password. Only your account (@matt) can sign in, and only while this device is connected.'),
      footer: _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger)),
      children: [
        SettingRowBox(
          child: GlacierInput(key: const ValueKey('admin-user'), controller: _user, placeholder: 'Admin username'.t, ariaLabel: 'Admin username', autoCorrect: false, autoCapitalize: TextCapitalization.none, size: GlacierFieldSize.md),
        ),
        SettingRowBox(
          child: GlacierInput(
            key: const ValueKey('admin-pass'),
            controller: _pass,
            placeholder: 'Password'.t,
            ariaLabel: 'Admin password',
            type: GlacierInputType.password,
            autoCorrect: false,
            size: GlacierFieldSize.md,
            onSubmitted: (_) => _signIn(),
          ),
        ),
        SettingRow(key: const ValueKey('admin-sign-in'), icon: AppIcon(Lucide.keyRound, size: 18), label: _busy ? 'Signing in…' : 'Sign in', disabled: _busy, onPress: _signIn),
      ],
    );
  }
}

/// Where a computer follows its phone, the admin dirs are refused (Me.forComputer): reviewing is signed with this
/// device's own key, and an admin session is its own connection's.
Widget adminSameYou(BuildContext context) => PaneSection(
      title: 'Admin sign-in',
      children: [
        const SettingRow(icon: AppIcon(Lucide.keyRound, size: 18), label: 'Reviewing needs your Uplink identity on this computer. Become the same you as your phone in Settings › Me.'),
        SettingRow(key: const ValueKey('admin-same-you'), icon: const AppIcon(Lucide.userCheck, size: 18), label: 'Open Settings › Me', onPress: () => openSettingsMe(context, 'Become the same you as your phone')),
      ],
    );

/// Settings › Admin: the sign-in, and once signed in the review rows, everyone who signed up (searched), and the last
/// of what was given.
class AdminPanel extends StatefulWidget {
  const AdminPanel({super.key, this.ask, this.market});

  /// For a test: the relay's answers, in place of Me.admin.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what)? ask;

  /// The Marketplace the review rows ask (Matt, 2026-11-20: "I'd like to be able to verify them for the store through a
  /// review process"): MarketState.instance.api where null, Uplink's own (MarketApi.live) in the app.
  final MarketApi? market;

  @override
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
  final _search = TextEditingController();
  bool _in = false;
  List<AdminUser>? _users;
  List<Map>? _log;
  // MarketState's api where none is given: MarketApi.live() in the app, a test's Marketplace in a test.
  late final MarketApi _market = widget.market ?? MarketState.instance.api;

  /// The Review queue row's second line, from route 14 read once signed in; null while it is asked.
  String? _queue;

  /// The Reports of people row's second line (GMFB-40), from the same read.
  String? _people;

  Future<Map<String, dynamic>> _ask(Map<String, Object?> what) => (widget.ask ?? Me.instance.admin)(what);

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _signedIn() async {
    _in = true;
    await _load();
    unawaited(_readQueue());
  }

  /// Route 14 in a try of its own: it sets the Review queue row's line and nothing else, so a Marketplace that can't be
  /// reached never signs the admin page out.
  Future<void> _readQueue() async {
    String line;
    try {
      final q = await _market.reviewQueue();
      MarketState.instance.reviewQueueRead(q.waiting);
      line = '${q.waiting} waiting · ${q.reports} ${q.reports == 1 ? 'report' : 'reports'}';
      if (mounted) setState(() => _people = q.abuse == 0 ? 'None open' : '${q.abuse} open');
    } on MarketError catch (e) {
      line = switch (e.code) {
        'no_identity' => 'This device has no Uplink identity of its own: review from your phone.',
        'not_admin' => 'Sign in on Settings › Admin again to see it.',
        _ => 'Couldn\'t reach the Marketplace',
      };
    } catch (_) {
      line = 'Couldn\'t reach the Marketplace';
    }
    if (mounted) setState(() => _queue = line);
  }

  /// Reads everyone who signed up and the log of what was given. Throws, and shows the sign-in again, where the relay
  /// no longer counts this connection as signed in.
  Future<void> _load() async {
    final users = await _ask({'dir': 'admin-users'});
    if (users['ok'] != true) {
      // Signed out by the relay (it was restarted, or the connection went): sign in again.
      if (mounted) setState(() => _in = false);
      throw MeError('${users['err'] ?? 'Sign in again.'}');
    }
    final log = await _ask({'dir': 'admin-log'});
    if (!mounted) return;
    setState(() {
      _users = [for (final u in (users['users'] as List? ?? const [])) if (u is Map) AdminUser(u)];
      _log = [for (final g in (log['grants'] as List? ?? const [])) if (g is Map) g];
    });
  }

  Future<void> _refresh() async {
    try {
      await _load();
      unawaited(_readQueue());
    } catch (e) {
      if (mounted) toast(context, e is MeError ? e.message : '$e');
    }
  }

  /// Opens one person's page, and reads the lists again when it closes: their souls and badges may have changed.
  Future<void> _open(AdminUser u) async {
    await push<void>(context, (_) => AdminPersonScreen(user: u, ask: _ask));
    if (mounted) setState(() {});
    unawaited(_refresh());
  }

  /// This device's review key, as Settings › Admin says it: whether this build trusts its approvals. Never a null
  /// check that throws while drawing: a computer that follows its phone has no signer.
  String _keyHint() {
    final signer = _market.signer;
    if (signer == null) return 'This device has no Uplink identity of its own: review from your phone.';
    final key = base64Encode(signer.publicKey);
    final here = InstalledPlugins.instance;
    final trusted = isReviewKey(signer.publicKey, keys: here.reviewKeys, retired: here.retiredKeys);
    return '${key.substring(0, 12)}… · ${trusted ? 'trusted by this build' : 'not trusted by this build: its approvals wouldn\'t install'}';
  }

  Future<void> _copyKey() async {
    final signer = _market.signer;
    if (signer == null) return;
    await Clipboard.setData(ClipboardData(text: base64Encode(signer.publicKey)));
    if (mounted) toast(context, 'Key copied');
  }

  /// A retirement of this device's review key, signed by it and copied: kept offline, and sent only if the key is ever
  /// lost or taken (SPEC G.4). Nothing is sent from here.
  Future<void> _retire() async {
    final signer = _market.signer;
    if (signer == null) return;
    final t = context.tokens;
    var go = false;
    await showChoices(context, title: 'Make a retirement for this key?', header: Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
      child: Text('Keep it offline. Sending it later makes every build stop trusting this key, for good.', key: const ValueKey('admin-market-retire-words'), style: pageText(t, t.fontSize('md'), height: 1.4, color: t.color('app-ink-2'))),
    ), choices: [
      Choice('Make the retirement', Lucide.keyRound, () => go = true),
      Choice('Not now', Lucide.x, () {}),
    ]);
    if (!go || !mounted) return;
    final retirement = await signRetirement(signer);
    await Clipboard.setData(ClipboardData(text: jsonEncode(retirement.toJson())));
    if (mounted) toast(context, 'Retirement copied: keep it somewhere safe');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (!_in) return Sms.followsPhone ? adminSameYou(context) : AdminSignIn(ask: widget.ask, onDone: _signedIn);
    final users = _users;
    final q = _search.text.trim().toLowerCase().replaceFirst('@', '');
    final shown = users == null ? null : [for (final u in users) if (u.matches(q)) u];
    final total = users?.fold<int>(0, (n, u) => n + u.souls) ?? 0;
    final signer = _market.signer;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      // The Marketplace's review (Matt, 2026-11-20: "I'd like to be able to verify them for the store through a review
      // process"): the queue, the key this device signs approvals with, and that key's retirement, made to keep.
      PaneSection(
        key: const ValueKey('admin-plugin-review'),
        title: 'Plugin review',
        children: [
          SettingRow(
            key: const ValueKey('admin-market'),
            icon: AppIcon(Lucide.shieldCheck, size: 18),
            label: 'Review queue',
            hint: Text(_queue ?? 'Asking the Marketplace…'),
            onPress: () async {
              await push<void>(context, (_) => ReviewQueueScreen(api: _market, ask: widget.ask));
              if (mounted) unawaited(_readQueue());
            },
          ),
          // Reports of people and messages (GMFB-40): sealed to this device's review key, opened here.
          SettingRow(
            key: const ValueKey('admin-people-reports'),
            icon: AppIcon(Lucide.flag, size: 18),
            label: 'Reports of people',
            hint: Text(_people ?? 'Sealed for this device\'s review key'),
            onPress: () async {
              await push<void>(context, (_) => PeopleReportsScreen(api: _market, ask: widget.ask));
              if (mounted) unawaited(_readQueue());
            },
          ),
          SettingRow(key: const ValueKey('admin-market-key'), icon: AppIcon(Lucide.keyRound, size: 18), label: 'This device\'s review key', hint: Text(_keyHint()), onPress: signer == null ? null : () => unawaited(_copyKey())),
          if (signer != null) SettingRow(key: const ValueKey('admin-market-retire'), icon: AppIcon(Lucide.archive, size: 18), label: 'Make a retirement for this key', hint: const Tr('Signed by this key, copied to keep offline. Nothing is sent.'), onPress: () => unawaited(_retire())),
        ],
      ),
      SizedBox(height: t.space(6)),
      PaneSection(
        title: 'Everyone',
        description: Text(users == null
            ? 'Asking the relay…'
            : '${users.length} ${users.length == 1 ? 'person' : 'people'} · ${users.where((u) => u.here).length} connected now · ${soulsCount(total)} souls given out'),
        children: [
          SettingRowBox(child: GlacierInput(key: const ValueKey('admin-search'), controller: _search, placeholder: 'Search by username, old username, Uplink id or account'.t, ariaLabel: 'Search people', autoCorrect: false, autoCapitalize: TextCapitalization.none, size: GlacierFieldSize.md)),
          SettingRow(icon: AppIcon(Lucide.refreshCw, size: 18), label: 'Refresh', onPress: _refresh),
          if (shown != null)
            for (final u in shown.take(300))
              SettingRow(
                key: ValueKey('admin-user-${u.id}'),
                icon: AppIcon(u.here ? Lucide.circleDot : Lucide.circle, size: 16, color: u.here ? t.color('app-accent') : t.color('app-ink-3')),
                label: u.shown,
                hint: Text([
                  if (u.since != null) 'Joined ${u.since}',
                  if (u.was.isNotEmpty) 'was ${u.was.reversed.map((n) => '@$n').join(', ')}',
                  if (u.account != null) 'account ${u.account!.substring(0, 6)}…${u.account!.substring(u.account!.length - 4)}',
                  if (u.verified) 'number verified',
                  if (u.links.isNotEmpty) u.links.join(', '),
                  for (final b in specialBadgesOf(u.special)) b.name,
                ].join(' · ').ifEmpty('${u.id.substring(0, u.id.length.clamp(0, 12))}…')),
                value: Row(mainAxisSize: MainAxisSize.min, children: [
                  const SoulFlame(size: 14),
                  SizedBox(width: t.space(1)),
                  Text(soulsCount(u.souls)),
                ]),
                onPress: () => _open(u),
              ),
        ],
      ),
      if (_log != null && _log!.isNotEmpty) ...[
        SizedBox(height: t.space(6)),
        PaneSection(
          title: 'Given lately',
          children: [
            for (final g in _log!.take(20))
              SettingRow(
                icon: AppIcon(g['badge'] != null ? Lucide.sparkles : Lucide.flame, size: 16, color: g['badge'] != null ? null : soulsFlame(t)),
                label: _grantLine(g),
                hint: Text('${'${g['at'] ?? ''}'.replaceFirst('T', ' ').split('.').first} UTC${'${g['why'] ?? ''}'.isEmpty ? '' : ' · ${g['why']}'}'),
              ),
          ],
        ),
      ],
    ]);
  }

  /// One line of the log in words: a badge given or taken, or souls given or taken (a negative count), and to whom.
  String _grantLine(Map g) {
    final who = _users?.where((u) => u.id == g['to']).firstOrNull?.shown ?? '${g['to']}'.substring(0, 8);
    final badge = g['badge'] is String ? specialBadge(g['badge'] as String)?.name ?? '${g['badge']}' : null;
    if (badge != null) return g['on'] == true ? '$badge to $who' : '$badge taken from $who';
    final n = g['souls'] is int ? g['souls'] as int : 0;
    return n >= 0 ? '${soulsCount(n)} souls to $who' : '${soulsCount(-n)} souls taken from $who';
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// One person on the admin page: their souls given or taken, with why, and their badges switched on and off.
class AdminPersonScreen extends StatefulWidget {
  const AdminPersonScreen({super.key, required this.user, required this.ask});
  final AdminUser user;
  final Future<Map<String, dynamic>> Function(Map<String, Object?> what) ask;

  @override
  State<AdminPersonScreen> createState() => _AdminPersonScreenState();
}

class _AdminPersonScreenState extends State<AdminPersonScreen> {
  final _amount = TextEditingController(text: '10');
  final _why = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _why.dispose();
    super.dispose();
  }

  /// Gives ([sign] 1) or takes ([sign] -1) the souls typed, with the reason typed; the relay answers with their new
  /// count.
  Future<void> _give(int sign) async {
    final n = int.tryParse(_amount.text.trim());
    if (n == null || n <= 0) return toast(context, 'Say how many souls');
    setState(() => _busy = true);
    try {
      final got = await widget.ask({'dir': 'admin-give', 'to': widget.user.id, 'souls': sign * n, 'why': _why.text.trim()});
      if (got['ok'] != true) throw MeError('${got['err'] ?? 'The relay said no.'}');
      setState(() => widget.user.souls = got['n'] is int ? got['n'] as int : widget.user.souls);
      if (mounted) toast(context, sign > 0 ? 'Gave ${soulsCount(n)} souls to ${widget.user.shown}' : 'Took ${soulsCount(n)} souls from ${widget.user.shown}');
      _why.clear();
    } catch (e) {
      if (mounted) toast(context, e is MeError ? e.message : '$e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Switches one special badge on or off for them; the relay answers with the badges they now hold.
  Future<void> _badge(SpecialBadge b, bool on) async {
    setState(() => _busy = true);
    try {
      final got = await widget.ask({'dir': 'admin-badge', 'to': widget.user.id, 'badge': b.id, 'on': on});
      if (got['ok'] != true) throw MeError('${got['err'] ?? 'The relay said no.'}');
      setState(() => widget.user.special = [for (final x in (got['special'] as List? ?? const [])) '$x']);
    } catch (e) {
      if (mounted) toast(context, e is MeError ? e.message : '$e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final u = widget.user;
    return GhostPage(
      title: u.name != null ? '@${u.name}' : 'Someone',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
          children: [
            Row(children: [
              const SoulFlame(size: 26),
              SizedBox(width: t.space(2)),
              Text(soulsCount(u.souls), key: const ValueKey('admin-person-souls'), style: pageText(t, t.fontSize('2xl'), weight: 'bold', color: t.color('app-ink'))),
              SizedBox(width: t.space(2)),
              Text(u.souls == 1 ? 'soul' : 'souls', style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'))),
            ]),
            SizedBox(height: t.space(1)),
            Text([if (u.since != null) 'Joined ${u.since}', if (u.verified) 'number verified', if (u.here) 'connected now'].join(' · '), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            SizedBox(height: t.space(6)),
            // Who they are, by what stays theirs: the id a ticket's "Reporter" line names, their account, and their names
            // before (Matt, 2026-11-20: "tie users names to their accounts ... so that we can give out bug bounties").
            PaneSection(
              title: 'Who',
              children: [
                SettingRow(
                  key: const ValueKey('admin-person-id'),
                  icon: AppIcon(Lucide.keyRound, size: 18),
                  label: 'Uplink id',
                  hint: Text(u.id),
                  value: const Tr('Copy'),
                  onPress: () {
                    Clipboard.setData(ClipboardData(text: u.id));
                    toast(context, 'Uplink id copied');
                  },
                ),
                SettingRow(
                  key: const ValueKey('admin-person-account'),
                  icon: AppIcon(Lucide.userCheck, size: 18),
                  label: 'Account',
                  hint: Text(u.account ?? 'None: a new install without signing in would be someone new.'),
                  value: u.account == null ? null : const Tr('Copy'),
                  onPress: u.account == null
                      ? null
                      : () {
                          Clipboard.setData(ClipboardData(text: u.account!));
                          toast(context, 'Account copied');
                        },
                ),
                if (u.was.isNotEmpty) SettingRow(key: const ValueKey('admin-person-was'), icon: AppIcon(Lucide.history, size: 18), label: 'Before', hint: Text(u.was.reversed.map((n) => '@$n').join(', '))),
              ],
            ),
            SizedBox(height: t.space(6)),
            PaneSection(
              title: 'Souls',
              description: const Tr('Told to them as soon as they are given, with why, if they are connected; otherwise the next time they are.'),
              children: [
                SettingRowBox(child: GlacierInput(key: const ValueKey('admin-amount'), controller: _amount, placeholder: 'How many'.t, ariaLabel: 'How many souls', autoCorrect: false, size: GlacierFieldSize.md)),
                SettingRowBox(child: GlacierInput(key: const ValueKey('admin-why'), controller: _why, placeholder: 'Why (they see it): "Found the Windows crash"'.t, ariaLabel: 'Why', size: GlacierFieldSize.md)),
                SettingRow(key: const ValueKey('admin-give'), icon: const SoulFlame(size: 18), label: 'Give souls', disabled: _busy, onPress: () => _give(1)),
                SettingRow(key: const ValueKey('admin-take'), icon: AppIcon(Lucide.minus, size: 18), label: 'Take souls back', disabled: _busy, onPress: () => _give(-1)),
              ],
            ),
            SizedBox(height: t.space(6)),
            PaneSection(
              title: 'Badges',
              description: const Tr('Shown beside their name in spaces, circles and on their profile.'),
              children: [
                for (final b in specialBadges)
                  SettingRow(
                    key: ValueKey('admin-badge-${b.id}'),
                    icon: AppIcon(b.icon, size: 18, color: PluginHues.of(t, b.hue).accent),
                    label: b.name,
                    hint: Text(b.about),
                    control: GlacierSwitch(checked: u.special.contains(b.id), ariaLabel: b.name, onCheckedChange: _busy ? null : (on) => _badge(b, on)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
