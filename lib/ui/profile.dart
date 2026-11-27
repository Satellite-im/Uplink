import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/settings_kit.dart';
import '../inbox/inbox.dart' show InboxPresence;
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../me/picture_make.dart';
import '../me/pictures.dart';
import '../sms.dart' show Sms;
import 'circles/circle_picture.dart' show pickProfilePicture;
import 'add_me.dart';
import 'identity_ui.dart';
import 'own_links_ui.dart';
import 'vouches_ui.dart';
import 'common.dart';
import 'cosmetics_picker.dart';
import 'profile_card.dart' show ProfileFace;
import 'sign_up_from.dart';
import 'special_badges.dart';
import 'username_friends.dart' show acceptRequest, requestLine;
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

/// Your profile on Uplink (Matt, 2026-11-14: "create a profile and username under "me" to register a
/// username and add friends on the platform"): a username people find you by, held on the relay server's directory
/// (only its scrambled form is kept there), and a name and a line about you, which go to your friends alone.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final _username = TextEditingController(text: Me.instance.username ?? '');
  late final _name = TextEditingController(text: Me.instance.displayName);
  late final _bio = TextEditingController(text: Me.instance.bio);
  late final _status = TextEditingController(text: Me.instance.status);
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _username.dispose();
    _name.dispose();
    _bio.dispose();
    _status.dispose();
    super.dispose();
  }

  /// Claims the username typed on the relay server's directory; nothing is asked where it is already this one.
  Future<void> _claim() async {
    final want = tidyHandle(_username.text);
    if (!Me.goodUsername(want)) {
      setState(() => _problem = 'A username is 3 to 20 letters, numbers, dots or underscores.');
      return;
    }
    if (want == Me.instance.username) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await Me.instance.claimUsername(want);
      if (mounted) toast(context, 'You\'re @$want');
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fills the fields from a profile brought in from elsewhere; a line about you already written is kept.
  void _fill(SignUpProfile p) {
    setState(() {
      if (p.username.isNotEmpty) _username.text = p.username;
      if (p.name.isNotEmpty) _name.text = p.name;
      if (p.status.isNotEmpty) _status.text = p.status;
      if (p.bio.isNotEmpty && _bio.text.trim().isEmpty) _bio.text = p.bio;
    });
    if (p.picture != null) Me.instance.setPicture(p.picture);
    toast(context, 'Filled in from ${p.from}. Claim the username and save to keep it.');
  }

  void _saveProfile() {
    final me = Me.instance;
    if (_name.text.trim() == me.displayName && _bio.text.trim() == me.bio && _status.text.trim() == me.status) return;
    me.setProfile(displayName: _name.text, bio: _bio.text, status: _status.text);
    _status.text = me.status;
    Buddies.instance.shareProfile();
    toast(context, 'Saved. Your friends will see it.');
  }

  /// A picture chosen, made square and sharp (lib/me/picture_make.dart), kept and sent to friends at once.
  Future<void> _choosePicture() async {
    final picked = await pickProfilePicture(context);
    if (picked == null) return;
    Me.instance.setPicture(picked);
    Buddies.instance.shareProfile();
    if (mounted) toast(context, 'Your picture is set. Your friends will see it.');
  }

  void _removePicture() {
    Me.instance.setPicture(null);
    Buddies.instance.shareProfile();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = Me.instance;
    Widget field(TextEditingController c, String placeholder, String label, {ValueChanged<String>? onSubmitted, TextCapitalization caps = TextCapitalization.sentences}) => SettingRowBox(
          child: GlacierInput(
            controller: c,
            placeholder: placeholder,
            ariaLabel: label,
            autoCorrect: false,
            autoCapitalize: caps,
            size: GlacierFieldSize.md,
            onSubmitted: onSubmitted,
          ),
        );
    return GhostPage(
      title: 'Profile',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListenableBuilder(
          listenable: me,
          builder: (context, _) => ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              // Before a username is claimed, the profile can be filled in from an account the person has (Matt,
              // 2026-11-19: "add a sign up with discord sign up with telegram or signal option"): the username, name
              // and status put in the fields to look over, the picture set.
              if (me.username == null) ...[
                SignUpFromSection(onFilled: _fill),
                SizedBox(height: t.space(6)),
              ],
              PaneSection(
                title: 'Username',
                description: Text(usernameWords(me.username, taken: me.nameTaken)),
                footer: _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger)),
                children: [
                  field(_username, 'username', 'Username', onSubmitted: (_) => _claim(), caps: TextCapitalization.none),
                  SettingRow(
                    icon: AppIcon(Lucide.atSign, size: 18),
                    label: _busy ? 'Checking…' : me.username == null ? 'Claim this username' : 'Change my username',
                    disabled: _busy || !me.ready,
                    onPress: _claim,
                  ),
                  if (!me.ready) SettingRow(label: 'The relay server isn\'t connected (Settings › Routes).', disabled: true),
                ],
              ),
              SizedBox(height: t.space(6)),
              // Matt, 2026-11-19: "build a profile section in the app that allows us to set profile pictures and status
              // messages".
              // Not in a browser, which can't choose a picture yet (Sms.browser).
              if (!Sms.browser) PaneSection(
                title: 'Picture',
                description: const Tr('Shown to your friends, and to people in your spaces and circles who open your profile.'),
                children: [
                  SettingRow(
                    icon: ProfileFace(key: const ValueKey('profile-picture'), name: me.shownName, picture: me.pictureOwn, size: 40),
                    label: me.picture.isEmpty ? 'Choose a picture' : 'Change your picture',
                    onPress: () => _choosePicture(),
                  ),
                  if (me.picture.isNotEmpty) SettingRow(icon: AppIcon(Lucide.trash2, size: 18), label: 'Remove your picture', onPress: _removePicture),
                  // The pictures you had before, to go back to (Matt, 2026-11-25: "store previous profile pictures so
                  // you can roll back easily").
                  if (me.picturesPast.isNotEmpty) const SettingRowBox(child: PastPictures()),
                ],
              ),
              SizedBox(height: t.space(6)),
              // How you are shown (GMFB-34): Online, Away, Busy or Invisible, as Discord has them.
              PaneSection(
                title: 'Show me as',
                description: const Tr('What friends and contacts see on your picture. Invisible looks offline; you can still send and get messages.'),
                children: [
                  for (final (mode, label, hint) in const [
                    ('online', 'Online', 'Green while you use the app, away when you put it away'),
                    ('away', 'Away', 'Away all the time'),
                    ('busy', 'Busy', 'A red mark, so people know you\'re heads down'),
                    ('invisible', 'Invisible', 'Shown as offline'),
                  ])
                    SettingRow(
                      key: ValueKey('presence-mode-$mode'),
                      icon: ModeMark(mode: mode),
                      label: label,
                      hint: Text(hint),
                      control: me.presenceMode == mode ? AppIcon(Lucide.check, size: 18, color: t.color('app-ink')) : null,
                      onPress: () => me.setPresenceMode(mode),
                    ),
                ],
              ),
              SizedBox(height: t.space(6)),
              // What the profile wears (GMFB-34): a banner, ready-made or a picture of your own, and a name effect.
              const CosmeticsSection(),
              SizedBox(height: t.space(6)),
              const BadgeSection(),
              SizedBox(height: t.space(6)),
              PaneSection(
                title: 'What friends see',
                description: const Tr('Sent to your friends only, never to the relay server. Your status shows in spaces and circles too.'),
                children: [
                  field(_name, 'Your name', 'Name'),
                  field(_status, 'A status: what you\'re up to', 'Status'),
                  field(_bio, 'A line about you', 'About'),
                  SettingRow(
                    icon: AppIcon(Lucide.link, size: 18),
                    label: 'Show friends my number and linked accounts',
                    hint: Text(me.links.isEmpty ? 'None linked yet (Settings › Me).' : 'On your profile card, for friends only.'),
                    control: GlacierSwitch(
                      checked: me.shareLinks,
                      onCheckedChange: (v) {
                        me.setShareLinks(v);
                        Buddies.instance.shareProfile();
                      },
                      ariaLabel: 'Show friends my number and linked accounts',
                    ),
                  ),
                  SettingRow(icon: AppIcon(Lucide.check, size: 18), label: 'Save', onPress: _saveProfile),
                ],
              ),
              SizedBox(height: t.space(6)),
              // Links of your own, shown on your card to friends as what you say (GMFB-34).
              const OwnLinksSection(),
              SizedBox(height: t.space(6)),
              // The account's key as a did:key, and statements signed with it (GMFB-33).
              const AccountKeySection(),
              // Friends' vouches that this account is really this person, and whether friends are shown them.
              if (Buddies.instance.vouchesHere) ...[
                SizedBox(height: t.space(6)),
                const VouchesSection(),
              ],
              if (me.username != null) ...[
                SizedBox(height: t.space(6)),
                // A link and QR code that open a friend request to you (GMFB-34).
                AddMeSection(username: me.username!),
                SizedBox(height: t.space(6)),
                PaneSection(children: [
                  SettingRow(
                    icon: AppIcon(Lucide.trash2, size: 18),
                    label: 'Give up @${me.username}',
                    hint: const Tr('Anyone can take it after. Your friends stay your friends.'),
                    onPress: () => showChoices(context, title: 'Give up @${me.username}?', choices: [
                      Choice('Give it up', Lucide.trash2, () async {
                        try {
                          await me.releaseUsername();
                          _username.clear();
                        } catch (e) {
                          if (context.mounted) toast(context, '$e', tone: GlacierToastTone.danger);
                        }
                      }, danger: true),
                    ]),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Friends by username: add someone, answer who asked, and the friends you have.
class BuddiesScreen extends StatefulWidget {
  const BuddiesScreen({super.key});

  @override
  State<BuddiesScreen> createState() => _BuddiesScreenState();
}

class _BuddiesScreenState extends State<BuddiesScreen> {
  final _who = TextEditingController();
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _who.dispose();
    super.dispose();
  }

  /// Asks the username typed to be a friend, and says whether they are one now or were only asked.
  Future<void> _add() async {
    final name = tidyHandle(_who.text);
    if (!Me.goodUsername(name)) {
      setState(() => _problem = 'Type their username, like @maya.');
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final b = await Buddies.instance.add(name);
      _who.clear();
      if (mounted) toast(context, b.state == 'yes' ? 'You and @$name are friends' : 'Asked @$name');
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = Buddies.instance;
    return GhostPage(
      title: 'Friends',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListenableBuilder(
          listenable: Listenable.merge([b, Me.instance]),
          builder: (context, _) => ListView(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              if (Me.instance.username == null)
                SettingsCallout(child: const Tr('Choose a username first (Settings › Me › Profile), so friends know it\'s you.'))
              else
                PaneSection(
                  title: 'Add a friend',
                  footer: _problem == null ? null : Text(_problem!, style: TextStyle(color: t.danger)),
                  children: [
                    SettingRowBox(
                      child: GlacierInput(
                        controller: _who,
                        placeholder: '@username'.t,
                        ariaLabel: 'Their username',
                        autoCorrect: false,
                        autoCapitalize: TextCapitalization.none,
                        size: GlacierFieldSize.md,
                        onSubmitted: (_) => _add(),
                      ),
                    ),
                    SettingRow(icon: AppIcon(Lucide.userPlus, size: 18), label: _busy ? 'Asking…' : 'Send a friend request', disabled: _busy, onPress: _add),
                  ],
                ),
              if (b.requests.isNotEmpty) ...[
                SizedBox(height: t.space(6)),
                PaneSection(title: 'Asked you', children: [
                  for (final r in b.requests)
                    SettingRow(
                      icon: AppIcon(Lucide.userPlus, size: 18),
                      label: r.shown,
                      hint: Text(requestLine(r)),
                      onPress: () => showChoices(context, title: '${r.shown} wants to be friends.', choices: [
                        Choice('Accept', Lucide.check, () => acceptRequest(context, r, buddies: b)),
                        Choice('Decline', Lucide.x, () => b.decline(r), danger: true),
                      ]),
                    ),
                ]),
              ],
              if (b.friends.isNotEmpty) ...[
                SizedBox(height: t.space(6)),
                PaneSection(title: 'Friends', children: [
                  for (final f in b.friends)
                    SettingRow(
                      icon: AppIcon(Lucide.userRound, size: 18),
                      label: f.shown,
                      hint: Text(f.name.isEmpty ? (f.bio.isEmpty ? 'Friends' : f.bio) : '@${f.username}${f.bio.isEmpty ? '' : ' · ${f.bio}'}'),
                      onPress: () => showChoices(context, title: f.shown, choices: [
                        Choice('Remove friend', Lucide.userX, () => b.remove(f), danger: true),
                      ]),
                    ),
                ]),
              ],
              if (b.asked.isNotEmpty) ...[
                SizedBox(height: t.space(6)),
                PaneSection(title: 'Waiting for them', children: [
                  for (final a in b.asked)
                    SettingRow(
                      icon: AppIcon(Lucide.clock, size: 18),
                      label: a.shown,
                      hint: const Tr('Asked'),
                      onPress: () => showChoices(context, title: 'Take back your request to @${a.username}?', choices: [
                        Choice('Take it back', Lucide.x, () => b.remove(a), danger: true),
                      ]),
                    ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}


/// The pictures this person had before (Me.picturesPast), as faces in a row: a press makes one the picture again, and
/// the one it takes the place of joins them. A long press, or a press with the other button, forgets one.
/// The line under Username on the profile page: how people find you; and, where the app moved to a relay on which the
/// name you go by is someone else's (Me.nameTaken; GMFB-25), that you have none on this relay yet and still have yours
/// on the one you came from.
String usernameWords(String? username, {({String name, String relay})? taken}) {
  if (username != null) return 'People add you as @$username.';
  if (taken == null) return 'How people find you to add you as a friend. Nobody sees your number.';
  final u = Uri.tryParse(taken.relay);
  final host = u == null || u.host.isEmpty ? 'this relay' : u.host;
  return '@${taken.name} belongs to someone else on $host, so you have no username on this relay yet: choose one for it here. On the relay you came from you are still @${taken.name}.';
}

/// The badge shown beside your name, chosen on the profile page (Matt, 2026-11-25: "We're also missing the section in
/// the profile to be able to set the badge"): the badges you have, each with what it is for, the one shown ticked. It
/// was on the Souls page and the profile bubble's card only.
class BadgeSection extends StatelessWidget {
  const BadgeSection({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Listenable.merge([Me.instance, SpecialBadges.instance]),
      builder: (context, _) {
        final badges = SpecialBadges.instance.of('', me: true);
        final shown = SpecialBadges.instance.shownOf('', me: true);
        return PaneSection(
          title: 'Badge',
          description: Text(badges.isEmpty
              ? 'You have no badges yet. One you are given shows beside your name.'
              : badges.length == 1
                  ? 'Shown beside your name, everywhere.'
                  : 'Choose the one shown beside your name, everywhere.'),
          children: [
            for (final b in badges)
              SettingRow(
                key: ValueKey('profile-badge-${b.id}'),
                icon: AppIcon(b.icon, size: 18),
                label: b.name,
                hint: Text(b.about),
                control: shown?.id == b.id ? AppIcon(Lucide.check, size: 18, color: t.color('app-ink')) : null,
                onPress: shown?.id == b.id ? null : () => unawaited(Me.instance.setShowcase(b.id).catchError((_) {})),
              ),
          ],
        );
      },
    );
  }
}

class PastPictures extends StatelessWidget {
  const PastPictures({super.key});

  /// Makes [kept] the picture again, as it was kept.
  static Future<void> use(BuildContext context, String kept) async {
    ProfilePicture? made;
    try {
      made = await profilePictureOf(base64Decode(kept));
    } catch (_) {}
    if (made == null) {
      if (context.mounted) toast(context, 'Couldn\'t use that picture.', tone: GlacierToastTone.danger);
      return;
    }
    // What friends are sent is made from it again; this person's own screens keep it as it was.
    Me.instance.setPicture(ProfilePicture(sharp: made.sharp, small: made.small, full: kept.length <= ProfilePictures.fullMost ? kept : made.full));
    Buddies.instance.shareProfile();
    if (context.mounted) toast(context, 'Your earlier picture is back. Your friends will see it.');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final past = Me.instance.picturesPast;
    const size = 44.0;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: t.space(2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('Earlier pictures', style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink'))),
        Text('Press one to use it again. Press and hold one to forget it.', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        SizedBox(height: t.space(2)),
        Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
          for (final (i, kept) in past.indexed)
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onSecondaryTapUp: (_) => _forget(context, kept),
              child: GlacierPressable(
                key: ValueKey('past-picture-$i'),
                onPressed: () => unawaited(use(context, kept)),
                onLongPress: () => _forget(context, kept),
                semanticLabel: 'Earlier picture ${i + 1}. Use it again',
                builder: (context, state) => GlacierFocusRing(
                  visible: state.focused,
                  offset: 2,
                  child: AnimatedScale(
                    scale: state.pressed ? 0.94 : (state.hovered ? 1.06 : 1),
                    duration: t.duration('glacier-duration-fast'),
                    curve: t.curve('glacier-ease-out'),
                    child: ProfileFace(name: '', picture: kept, size: size),
                  ),
                ),
              ),
            ),
        ]),
      ]),
    );
  }

  static void _forget(BuildContext context, String kept) => showChoices(context, title: 'Forget this earlier picture?', choices: [
        Choice('Forget it', Lucide.trash2, () => Me.instance.forgetPast(kept), danger: true),
      ]);
}

/// The mark a mode shows on a face (PresenceDot), and Invisible's own: a hollow grey ring.
class ModeMark extends StatelessWidget {
  const ModeMark({super.key, required this.mode, this.size = 16});
  final String mode;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (mode == 'invisible') {
      return Container(width: size, height: size, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: t.color('app-ink-3'), width: size * 0.22)));
    }
    return PresenceDot(presence: InboxPresence(network: 'Uplink', online: mode == 'online', away: mode == 'away', busy: mode == 'busy'), size: size);
  }
}
