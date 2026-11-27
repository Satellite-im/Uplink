/// Adding people to a space or a circle (Matt, 2026-11-17: "when adding people to the space we should have a suggested
/// list of our contacts to add if they're not on ghost yet it should send them a text saying they've been invited to
/// join a space in ghost with a link that eventually follows through after they setup their account sort the list by
/// friends on ghost first").
///
/// One sheet for both (showSpaceInvite, and the circle's showCircleInvite through [InviteTarget.circle]): a search,
/// then everyone who could be asked, friends on Uplink first with the app's mark beside them, then the
/// phone's contacts, each with a check to choose them. Friends by username are sent the place at once in the app, as
/// before; anyone else is texted from your own phone, one text each, with the link (on a paired computer, through the
/// phone; on an iPhone of its own, which has no texts, the share sheet opens with the words). Texts are asked about
/// before they go. A sealed copy of each text's invite is left on the relay for the day that person sets the app up
/// (lib/invites/). The link, its QR code and the share sheet stay at the top for anyone else.
library;

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../circles/circles.dart';
import '../desktop/ui/qr.dart';
import '../friends/buddies.dart';
import '../friends/friends.dart';
import '../inbox/inbox.dart';
import '../inbox/people.dart';
import '../invites/invite_seal.dart';
import '../invites/text_invites.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/voice.dart';
import 'circles/circle_face.dart';
import 'common.dart';
import 'add_friend_drawer.dart';
import 'dialup/bevel.dart';
import 'drawer_head.dart';
import 'ripple_avatar.dart';
import 'shell.dart';
import '../l10n/words.dart';

/// What people are being added to: a space or a circle, and how each kind of invite reaches them.
class InviteTarget {
  const InviteTarget({
    required this.kind,
    required this.name,
    required this.link,
    required this.words,
    required this.sendToFriends,
    this.inside,
    this.face,
    this.line,
    this.copied,
  });

  /// A space ([channel]): friends sent it by Voice.share, the link copied as the space's own is said.
  factory InviteTarget.space(VoiceChannel channel, {required Future<List<Buddy>> Function(VoiceChannel channel, List<Buddy> friends) send, Set<String> Function()? inside, required String words}) =>
      InviteTarget(
        kind: 'space',
        name: channel.name,
        link: channel.link,
        words: words,
        sendToFriends: (friends) => send(channel, friends),
        inside: inside,
        copied: 'Invite link copied. Anyone with it can join ${channel.name} from a browser.',
      );

  /// A circle ([c]): friends sent its invite envelope (Circles.share), and its face at the top.
  factory InviteTarget.circle(Circle c, {Future<List<Buddy>> Function(Circle circle, List<Buddy> friends)? send}) => InviteTarget(
        kind: 'circle',
        name: c.name,
        link: c.link,
        words: 'Join my circle ${c.name} on Uplink: ${c.link}',
        sendToFriends: (friends) => (send ?? Circles.instance.share)(c, friends),
        face: CircleFace.of(c, size: 40),
        line: 'Whoever has the link is in the circle.',
        copied: 'Invite link copied. Anyone with it can join ${c.name}.',
      );

  /// 'space' or 'circle': the word the sheet says.
  final String kind;
  final String name;
  final String link;

  /// What the share sheet is given.
  final String words;

  /// Sends the place to the friends chosen, in the app; gives back those it could not reach.
  final Future<List<Buddy>> Function(List<Buddy> friends) sendToFriends;

  /// Who is in it now, by id: shown as in it, not offered.
  final Set<String> Function()? inside;
  final Widget? face;
  final String? line;
  final String? copied;
}

/// Someone the sheet offers: a friend by username (invited in the app), or a contact with a number (texted).
@immutable
class InviteCandidate {
  const InviteCandidate({required this.key, required this.name, this.friend, this.number, this.photo, this.ghost = false, this.typed = false});

  final String key;
  final String name;

  /// A friend by username: sent the invite in the app.
  final Buddy? friend;

  /// The number a text goes to.
  final String? number;
  final String? photo;

  /// On Uplink: a friend by username, or a phone contact who is a friend by number (lib/friends/friends.dart).
  /// A friend by number with no username friend to send it to in the app is texted, and the text's link opens in the
  /// app they have.
  final bool ghost;

  /// A number typed into the search, not in the contacts.
  final bool typed;

  bool get byText => friend == null;
}

/// The phone's contacts, put together with the networks' as Contacts does (lib/inbox/people.dart), those with a number
/// alone: a text needs one. Friends by number are marked as on Uplink.
Future<List<Someone>> appInviteContacts() async {
  final found = await Sms.instance.searchContacts('');
  final phone = [
    for (final c in found)
      if ((c['address'] ?? '').isNotEmpty) PhoneContact(address: c['address']!, name: c['name'], photo: c['photo'], label: c['label'], friend: Friends.instance.isFriend(c['address']!)),
  ];
  var networks = const <InboxContact>[];
  try {
    networks = [for (final n in Inbox.instance.ready) ...n.contacts];
  } catch (_) {}
  return [for (final s in gather(phone, networks)) if (s.reaches.any((r) => r.address != null)) s];
}

/// The name your invites go out under: your name as friends see it, else your username; empty where you have neither.
String inviterName([Me? me]) {
  final m = me ?? Me.instance;
  if (m.displayName.trim().isNotEmpty) return m.displayName.trim();
  return m.username == null ? '' : '@${m.username}';
}

/// Raises the sheet for [target] over everything. The rest are for a test or a picture; the app's own otherwise.
Future<void> showInvitePeople(
  BuildContext context,
  InviteTarget target, {
  Buddies? buddies,
  Future<List<Someone>> Function()? contacts,
  TextInvites? texts,
  void Function(String words)? share,
  void Function(String words)? compose,
  String? me,
  bool? canText,
}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => InvitePeopleSheet(target: target, buddies: buddies, contacts: contacts, texts: texts, share: share, compose: compose, me: me, canText: canText),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The circle's sheet, as showCircleInvite (lib/ui/circles/circle_invite.dart) is to raise it: friends sent the circle
/// (Circles.share), contacts texted its link, the link and its QR code. [send], [compose], [buddies], [contacts],
/// [texts] and [canText] are for a test; the app's own otherwise.
Future<void> showCircleInvitePeople(
  BuildContext context,
  Circle c, {
  Future<List<Buddy>> Function(Circle circle, List<Buddy> friends)? send,
  void Function(String words)? compose,
  Buddies? buddies,
  Future<List<Someone>> Function()? contacts,
  TextInvites? texts,
  bool? canText,
}) {
  final shell = AppShell.maybeOf(context);
  final target = InviteTarget.circle(c, send: send);
  final write = compose ?? (shell == null ? (String words) => unawaited(Sms.instance.shareText(c.name, words)) : (String words) => shell.compose(body: words));
  return showInvitePeople(context, target, buddies: buddies, contacts: contacts, texts: texts, compose: write, canText: canText);
}

/// The sheet itself ([showInvitePeople] raises it): the link, its QR code and Share at the top, a search, then everyone
/// who could be asked, each with a check, and Send.
class InvitePeopleSheet extends StatefulWidget {
  const InvitePeopleSheet({super.key, required this.target, this.buddies, this.contacts, this.texts, this.share, this.compose, this.me, this.canText, this.buddyOf, this.chosen, this.asking = false, this.qr = false, this.query});
  final InviteTarget target;

  /// The username friend a number belongs to, where its install is one (the routes know each number's install, and a
  /// username friend's id is the same install's); the app's own otherwise.
  final Buddy? Function(String number)? buddyOf;
  final Buddies? buddies;
  final Future<List<Someone>> Function()? contacts;
  final TextInvites? texts;

  /// Opens the share sheet with words; the system's otherwise.
  final void Function(String words)? share;

  /// Starts a new text with words, to anyone (Text an invite); the share sheet where there is none.
  final void Function(String words)? compose;

  /// The inviter's name as the texts say it; [inviterName] otherwise.
  final String? me;

  /// Whether this device can send texts (a phone, or a computer through one); not on an iPhone of its own.
  final bool? canText;

  /// For a picture: who is chosen, by [InviteCandidate.key], whether the texts are being asked about, the QR code
  /// shown, and what is searched.
  final Set<String>? chosen;
  final bool asking;
  final bool qr;
  final String? query;

  @override
  State<InvitePeopleSheet> createState() => _InvitePeopleSheetState();
}

class _InvitePeopleSheetState extends State<InvitePeopleSheet> {
  late final Set<String> _chosen = {...?widget.chosen};
  late bool _asking = widget.asking;
  late bool _qr = widget.qr;
  late String _query = widget.query ?? '';
  bool _sending = false;

  /// Set at once on Send, before anything is awaited or built again: two presses in one frame send once.
  bool _went = false;
  List<Someone>? _contacts;
  bool _contactsFailed = false;

  Buddies get _buddies => widget.buddies ?? Buddies.instance;
  bool get _canText => widget.canText ?? !Sms.standalone;
  String get _me => widget.me ?? inviterName();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Reads the contacts that could be asked; until then, and where they can't be read, friends alone are offered.
  Future<void> _load() async {
    try {
      final found = await (widget.contacts ?? appInviteContacts)();
      if (mounted) setState(() => _contacts = found);
    } catch (_) {
      // No contacts to read (not allowed, or no phone to ask): friends and the link are still here.
      if (mounted) {
        setState(() {
          _contacts = const [];
          _contactsFailed = true;
        });
      }
    }
  }

  Set<String> get _inside => widget.target.inside?.call() ?? const {};

  /// The friend by username a friend by [number] also is: the one whose id the encryption record for that number names
  /// (Friends.idOf), never whoever the routes hold under the number (found in review, 2026-11-23).
  Buddy? _buddyOf(String number) {
    final pick = widget.buddyOf;
    if (pick != null) return pick(number);
    final id = Friends.instance.idOf(number);
    if (id == null) return null;
    return _buddies.friends.where((f) => f.id == id).firstOrNull;
  }

  /// Everyone offered, friends on Uplink first and by name, then the contacts in the phone's order; each
  /// narrowed by the search. A whole number typed that nobody has is offered too, to text.
  List<InviteCandidate> _candidates([String? search]) {
    final query = search ?? _query;
    final q = query.trim().toLowerCase();
    final ghost = <InviteCandidate>[];
    for (final f in _buddies.roomFriends) {
      if (q.isNotEmpty && !f.shown.toLowerCase().contains(q) && !f.username.toLowerCase().contains(q.replaceAll('@', ''))) continue;
      ghost.add(InviteCandidate(key: 'b:${f.id}', name: f.shown, friend: f, ghost: true));
    }
    final rest = <InviteCandidate>[];
    final numbers = <String>{};
    final listedFriends = {for (final f in _buddies.friends) f.id};
    for (final s in _contacts ?? const <Someone>[]) {
      final number = s.reaches.firstWhere((r) => r.address != null).address!;
      final k = numberKey(number);
      if (k.isNotEmpty && !numbers.add(k)) continue;
      // A friend by number who is also a username friend is listed once, as that friend, and sent it in the app:
      // listed twice, choosing both sent an invite in the app and a text.
      if (s.friend) {
        final buddy = _buddyOf(number);
        if (buddy != null && listedFriends.contains(buddy.id)) continue;
      }
      if (!answers(s, query)) continue;
      final c = InviteCandidate(key: 'n:${k.isEmpty ? number : k}', name: s.name, number: number, photo: s.photo, ghost: s.friend);
      (s.friend ? ghost : rest).add(c);
    }
    ghost.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final digits = query.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 7 && !numbers.contains(numberKey(query)) && RegExp(r'^[\d\s()+.\-]+$').hasMatch(query.trim())) {
      rest.insert(0, InviteCandidate(key: 'n:${numberKey(query)}', name: query.trim(), number: query.trim(), typed: true));
    }
    return [...ghost, ...rest];
  }

  void _toggle(InviteCandidate c) => setState(() => _chosen.contains(c.key) ? _chosen.remove(c.key) : _chosen.add(c.key));

  /// Who is chosen, as they are offered now (a choice hidden by the search stays chosen).
  List<InviteCandidate> _picked() {
    final all = {for (final c in _candidates('')) c.key: c};
    // A number typed and chosen, then the search changed: still the number it was.
    return [for (final k in _chosen) all[k] ?? (k.startsWith('n:') && _typedNumbers.containsKey(k) ? _typedNumbers[k]! : null)].whereType<InviteCandidate>().toList();
  }

  final Map<String, InviteCandidate> _typedNumbers = {};

  /// Send: friends not already inside are sent the place in the app, the rest are texted (asked about first), or the
  /// share sheet opens where this device has no texts. Says who was reached and who was not, and closes if anyone was.
  Future<void> _go() async {
    if (_sending || _went) return;
    final picked = _picked();
    final friends = [for (final c in picked) if (c.friend != null && !_inside.contains(c.friend!.id)) c.friend!];
    final byText = [for (final c in picked) if (c.byText) c];
    if (friends.isEmpty && byText.isEmpty) return;
    if (byText.isNotEmpty && !_asking) return setState(() => _asking = true);
    _went = true;
    setState(() => _sending = true);
    final nav = Navigator.of(context);
    final shown = context;
    final words = inviteText(me: _me, name: widget.target.name, link: widget.target.link);
    var reached = 0;
    final missed = <String>[];
    try {
      if (friends.isNotEmpty) {
        final away = await widget.target.sendToFriends(friends);
        reached += friends.length - away.length;
        missed.addAll(away.map((f) => f.shown));
      }
      if (byText.isNotEmpty) {
        final invite = WaitingInvite(kind: widget.target.kind, link: widget.target.link, name: widget.target.name, by: _me);
        if (_canText) {
          final texts = widget.texts ?? TextInvites();
          final failed = await texts.send([for (final c in byText) TextInvitee(c.name, c.number!, onGhost: c.ghost)], invite, words);
          reached += byText.length - failed.length;
          missed.addAll(failed.map((f) => f.name));
        } else {
          // No texts here (an iPhone of its own): the share sheet, with the words and the link written. No copies are
          // left on the relay: the share sheet does not say whether it went, or to whom, and a copy for someone never
          // sent the words would wait for them all the same. The link in the words does the work.
          (widget.share ?? (w) => unawaited(Sms.instance.shareText(widget.target.name, w).catchError((_) {})))(words);
          reached += byText.length;
        }
      }
      if (!shown.mounted) return;
      if (reached == 0) {
        toast(shown, 'Couldn\'t reach ${missed.join(', ')}. Try again in a moment, or share the link.', tone: GlacierToastTone.danger);
        setState(() {
          _sending = false;
          _went = false;
          _asking = false;
        });
        return;
      }
      final reachedNames = [for (final c in picked) if (!missed.contains(c.name)) c.name];
      final said = reached == 1 && reachedNames.length == 1 ? 'Invited ${reachedNames.first}' : 'Invited $reached';
      toast(shown, missed.isEmpty ? said : '$said; couldn\'t reach ${missed.join(', ')}', tone: missed.isEmpty ? GlacierToastTone.neutral : GlacierToastTone.warning);
      nav.pop();
    } catch (e) {
      if (shown.mounted) toast(shown, 'Couldn\'t send the invites: $e', tone: GlacierToastTone.danger);
      if (mounted) {
        setState(() {
          _sending = false;
          _went = false;
          _asking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final target = widget.target;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: GestureDetector(
          onTap: () {},
          child: Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: t.lenOf('30rem'), maxHeight: MediaQuery.sizeOf(context).height - pad.top - pad.bottom - t.space(8)),
              child: _Frame(
                child: ListenableBuilder(
                  listenable: Listenable.merge([_buddies, Voice.instance]),
                  builder: (context, _) {
                    final all = _candidates();
                    for (final c in all) {
                      if (c.typed) _typedNumbers[c.key] = c;
                    }
                    final inside = _inside;
                    final ghost = [for (final c in all) if (c.ghost) c];
                    final others = [for (final c in all) if (!c.ghost) c];
                    final friendless = _buddies.friends.isEmpty && _query.trim().isEmpty;
                    final rows = <Widget>[
                      if (ghost.isNotEmpty || friendless) const _Heading('On Uplink'),
                      if (friendless) ...[
                        Padding(
                          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(1)),
                          child: Text('No friends here yet. Add someone by their username and you can invite them in one press.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
                        ),
                        _AddFriend(onPress: () {
                          final root = Navigator.of(context, rootNavigator: true).context;
                          Navigator.of(context).pop();
                          unawaited(showAddFriendDrawer(root));
                        }),
                      ],
                      for (final c in ghost)
                        _PersonRow(
                          key: ValueKey('invite-${c.key}'),
                          candidate: c,
                          inside: c.friend != null && inside.contains(c.friend!.id),
                          insideWord: 'In the ${target.kind}',
                          chosen: _chosen.contains(c.key),
                          onPress: () => _toggle(c),
                        ),
                      if (others.isNotEmpty) _Heading(_canText ? 'Contacts · invited by text' : 'Contacts'),
                      for (final c in others) _PersonRow(key: ValueKey('invite-${c.key}'), candidate: c, chosen: _chosen.contains(c.key), onPress: () => _toggle(c)),
                      if (all.isEmpty && _contacts != null && !friendless) _Empty(query: _query, noContacts: _contactsFailed),
                      if (_contacts == null) const _Empty.loading(),
                    ];
                    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _Top(target: target),
                      _Ways(target: target, qr: _qr, onQr: () => setState(() => _qr = !_qr), share: widget.share, compose: widget.compose),
                      if (_qr)
                        Padding(
                          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
                          child: Center(
                            child: Semantics(
                              label: 'The invite link to ${target.name}, as a QR code',
                              child: ExcludeSemantics(child: QrView(data: target.link, size: 168, radius: isBevelChrome(t) ? 0 : 14)),
                            ),
                          ),
                        ),
                      Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(1)),
                        child: GlacierSearchField(
                          key: const ValueKey('invite-search'),
                          placeholder: 'Search friends and contacts'.t,
                          size: GlacierFieldSize.md,
                          onValueChange: (v) => setState(() => _query = v),
                        ),
                      ),
                      Flexible(
                        child: _FadedFoot(
                          child: ListView(
                            key: const ValueKey('invite-list'),
                            shrinkWrap: rows.length < 14,
                            padding: EdgeInsets.only(bottom: _FadedFoot.height(t)),
                            children: rows,
                          ),
                        ),
                      ),
                      // Nobody to choose at all (no friends, no contacts): no button to press for nobody.
                      if (all.isNotEmpty || _chosen.isNotEmpty || _contacts == null) ...[
                        Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
                        _asking ? _Ask(picked: _picked(), canText: _canText, words: inviteText(me: _me, name: target.name, link: target.link), sending: _sending, onBack: () => setState(() => _asking = false), onSend: _go) : _Send(picked: _picked(), inside: inside, sending: _sending, onSend: _go),
                      ] else
                        SizedBox(height: t.space(2)),
                    ]);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet's card: the page's raised paper, round-cornered; Dial-Up's a square raised window, as its dialogs are.
class _Frame extends StatelessWidget {
  const _Frame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    if (isBevelChrome(t)) return Bevel(child: child);
    return ClipRRect(borderRadius: BorderRadius.circular(t.radius('xl')), child: ColoredBox(color: t.color('app-paper-2'), child: child));
  }
}

/// The drawer's head, the members drawer's own (lib/ui/drawer_head.dart): the place's face where it has one, Invite
/// people, the space's or circle's name under it, and Close.
class _Top extends StatelessWidget {
  const _Top({required this.target});
  final InviteTarget target;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: DrawerHead(title: 'Invite people', subtitle: target.name, face: target.face, note: target.line, closeKey: const ValueKey('invite-close')),
    );
  }
}

/// The list's foot fading into the card, so a list cut off by the card's foot (the question before the texts, risen
/// under it) ends in a fade rather than through the middle of a row. Room as tall as the fade is left at the list's
/// end, so its last row comes clear of it when scrolled to.
class _FadedFoot extends StatelessWidget {
  const _FadedFoot({required this.child});
  final Widget child;

  static double height(Tokens t) => t.space(4);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ground = isBevelChrome(t) ? DialupColors.of(t).chrome : t.color('app-paper-2');
    return Stack(children: [
      child,
      PositionedDirectional(
        start: 0,
        end: 0,
        bottom: 0,
        height: height(t),
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [ground.withValues(alpha: 0), ground])),
          ),
        ),
      ),
    ]);
  }
}

/// The ways to anyone not listed, small, under the title: a new text with the invite written, the link copied, given
/// to another app, or shown as a QR code.
class _Ways extends StatelessWidget {
  const _Ways({required this.target, required this.qr, required this.onQr, this.share, this.compose});
  final InviteTarget target;
  final bool qr;
  final VoidCallback onQr;
  final void Function(String words)? share, compose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
      child: Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
        // A text is a phone's to send, and the share sheet a phone's or a computer's: neither in a browser (Sms.browser),
        // where the link is copied or shown as its QR code.
        if (compose != null && !Sms.browser)
          _Pill(
            key: const ValueKey('invite-text'),
            icon: Lucide.messageSquare,
            label: 'Text an invite',
            onPress: () {
              Navigator.of(context).pop();
              compose!(target.words);
            },
          ),
        _Pill(
          key: const ValueKey('invite-copy'),
          icon: Lucide.link,
          label: 'Copy invite link',
          onPress: () {
            final root = Navigator.of(context, rootNavigator: true).context;
            Navigator.of(context).pop();
            Clipboard.setData(ClipboardData(text: target.link));
            toast(root, target.copied ?? 'Invite link copied.');
          },
        ),
        if (!Sms.browser) _Pill(
          key: const ValueKey('invite-share'),
          icon: Lucide.share2,
          label: 'Share link…',
          onPress: () {
            Navigator.of(context).pop();
            (share ?? (w) => unawaited(Sms.instance.shareText(target.name, w).catchError((_) {})))(target.words);
          },
        ),
        _Pill(key: const ValueKey('invite-qr'), icon: LucideMore.qrCode, label: qr ? 'Hide QR code' : 'QR code', on: qr, onPress: onQr),
      ]),
    );
  }
}

/// A small button with an icon and a word, held down while [on]; a bevel under Dial-Up's chrome.
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.icon, required this.label, required this.onPress, this.on = false});
  final LucideIcon icon;
  final String label;
  final VoidCallback onPress;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      builder: (context, state) {
        final ink = bevel ? DialupColors.of(t).onChrome : t.color('app-ink');
        final words = Row(mainAxisSize: MainAxisSize.min, children: [
          AppIcon(icon, size: 15, wash: false, color: ink),
          SizedBox(width: t.space(1) * 1.5),
          Text(label, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: ink)),
        ]);
        final inner = EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) * 1.5);
        if (bevel) return Bevel(style: state.pressed || on ? BevelStyle.pressed : BevelStyle.raised, kind: BevelKind.button, padding: inner, child: words);
        return Container(
          padding: inner,
          decoration: BoxDecoration(
            color: t.color(state.pressed || on ? 'app-paper-3' : 'app-paper'),
            borderRadius: BorderRadius.circular(t.radius('full')),
            border: Border.all(color: t.color('app-rule')),
          ),
          child: words,
        );
      },
    );
  }
}

/// Add a friend, where there are none yet: the add-friend drawer, in the sheet's place.
class _AddFriend extends StatelessWidget {
  const _AddFriend({required this.onPress});
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: 'Add a friend',
      builder: (context, state) => ColoredBox(
        color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(3)),
          child: Row(children: [
            AppIcon(Lucide.userPlus, size: 20, color: t.color('app-ink')),
            SizedBox(width: t.space(3)),
            Text('Add a friend', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
          ]),
        ),
      ),
    );
  }
}

/// A small heading over a part of the list.
class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(1)),
      child: Text(text, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink-3'))),
    );
  }
}

/// Someone to choose: their face, name, the Uplink mark where they are on the app, how they would be reached, and a
/// check while chosen. A friend already in the place says so instead.
class _PersonRow extends StatelessWidget {
  const _PersonRow({super.key, required this.candidate, required this.chosen, required this.onPress, this.inside = false, this.insideWord = ''});
  final InviteCandidate candidate;
  final bool chosen, inside;
  final String insideWord;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = candidate;
    final f = c.friend;
    // A friend by number is drawn as a friend is (round, plain initials) and says how it reaches them: a text whose
    // link opens in the app they have. "By text" alone is for the contacts not on the app.
    final under = f != null
        ? (f.name.isNotEmpty ? '@${f.username} · in the app' : 'In the app')
        : c.typed
            ? 'Not in your contacts · by text'
            : c.ghost
                ? '${c.number} · text, opens in the app'
                : '${c.number} · by text';
    return GlacierPressable(
      onPressed: inside ? null : onPress,
      semanticLabel: inside ? '${c.name}, ${insideWord.toLowerCase()}' : '${c.name}${c.ghost ? ', on Uplink' : ''}${chosen ? ', chosen' : ''}',
      builder: (context, state) => ColoredBox(
        color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
          child: Row(children: [
            if (f != null || c.typed || c.ghost)
              RippleAvatar(name: c.name, level: 0, size: 40)
            else
              Avatar(people: [Person(address: c.number!, name: c.name, photo: c.photo)], size: 40, presence: false),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Flexible(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink')))),
                  if (c.ghost) ...[
                    SizedBox(width: t.space(1) * 1.5),
                    Semantics(label: 'On Uplink', child: const ExcludeSemantics(child: GhostLogo(size: 16))),
                  ],
                ]),
                Text(under, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              ]),
            ),
            SizedBox(width: t.space(2)),
            if (inside) Text(insideWord, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.online)) else _Check(on: chosen),
          ]),
        ),
      ),
    );
  }
}

/// A round check, filled while chosen; Dial-Up's a square sunken box, as its checkboxes are.
class _Check extends StatelessWidget {
  const _Check({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('1.5rem');
    if (isBevelChrome(t)) {
      final d = DialupColors.of(t);
      return SizedBox(
        width: size,
        height: size,
        child: Bevel(style: BevelStyle.sunken, color: d.paper, child: Center(child: on ? AppIcon(Lucide.check, size: 14, strokeWidth: 3, wash: false, color: d.ink) : null)),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? t.color('app-ink') : const Color(0x00000000),
        border: Border.all(color: t.color(on ? 'app-ink' : 'app-ink-3'), width: 2),
      ),
      alignment: Alignment.center,
      child: on ? AppIcon(Lucide.check, size: 14, strokeWidth: 3, wash: false, color: t.color('app-paper')) : null,
    );
  }
}

/// Said where the list has nobody: contacts still coming, nobody matching, or nobody at all.
class _Empty extends StatelessWidget {
  const _Empty({required this.query, required this.noContacts}) : loading = false;
  const _Empty.loading()
      : query = '',
        noContacts = false,
        loading = true;
  final String query;
  final bool noContacts, loading;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final words = loading
        ? 'Looking through your contacts…'
        : query.trim().isNotEmpty
            ? 'Nobody called "${query.trim()}". Type a whole number to text an invite to it.'
            : noContacts
                ? 'Your contacts can\'t be read here. Share the link, or add a friend by their username.'
                : 'No friends or contacts yet. Share the link with anyone.';
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(2)),
      child: Text(words, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
    );
  }
}

/// The foot: who is chosen and the one button that invites them.
class _Send extends StatelessWidget {
  const _Send({required this.picked, required this.inside, required this.sending, required this.onSend});
  final List<InviteCandidate> picked;
  final Set<String> inside;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = picked.length;
    final texts = picked.where((c) => c.byText).length;
    final label = n == 0 ? 'Send invites' : n == 1 ? 'Send invite' : 'Send $n invites';
    final hint = texts == 0 ? null : texts == n ? (texts == 1 ? 'By text' : 'By text, one each') : '${n - texts} in the app, $texts by text';
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(3)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Primary(key: const ValueKey('invite-send'), label: label, icon: Lucide.send, enabled: n > 0 && !sending, onPress: onSend),
        if (hint != null) ...[
          SizedBox(height: t.space(1) * 1.5),
          Text(hint, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
        ],
      ]),
    );
  }
}

/// Asked before any text goes (Matt's brief: "Send 3 invites by text?"): how many, the words each gets, Back and Send.
class _Ask extends StatelessWidget {
  const _Ask({required this.picked, required this.canText, required this.words, required this.sending, required this.onBack, required this.onSend});
  final List<InviteCandidate> picked;
  final bool canText;
  final String words;
  final bool sending;
  final VoidCallback onBack, onSend;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final texts = picked.where((c) => c.byText).length;
    final friends = picked.length - texts;
    final question = canText ? 'Send ${texts == 1 ? 'an invite' : '$texts invites'} by text?' : 'Share the invite with ${texts == 1 ? picked.firstWhere((c) => c.byText).name : '$texts people'}?';
    final how = canText
        ? '${Sms.paired ? 'Sent from your phone' : 'From your number'}, one text each${friends > 0 ? ', and $friends ${friends == 1 ? 'friend' : 'friends'} invited in the app' : ''}. Once they set up Uplink, the invite will be waiting.'
        : 'This phone can\'t send texts: the share sheet opens with the invite written, for you to send.';
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(3)),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(question, key: const ValueKey('invite-ask'), style: pageText(t, t.fontSize('md'), weight: 'bold', color: t.color('app-ink'))),
        SizedBox(height: t.space(1)),
        Text(how, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
        SizedBox(height: t.space(2)),
        // The words as they will arrive.
        Container(
          padding: EdgeInsets.all(t.space(3)),
          decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(isBevelChrome(t) ? 0 : t.radius('lg')), border: Border.all(color: t.color('app-rule'))),
          child: Text(words, maxLines: 4, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'), height: 1.4)),
        ),
        SizedBox(height: t.space(3)),
        Row(children: [
          Expanded(child: _Primary(key: const ValueKey('invite-back'), label: 'Back', quiet: true, enabled: !sending, onPress: onBack)),
          SizedBox(width: t.space(2)),
          Expanded(
            flex: 2,
            child: _Primary(key: const ValueKey('invite-confirm'), label: canText ? (texts == 1 ? 'Send text' : 'Send $texts texts') : 'Share invite', icon: canText ? Lucide.send : Lucide.share2, enabled: !sending, onPress: onSend),
          ),
        ]),
      ]),
    );
  }
}

/// The sheet's button: the page's ink, or quiet; Dial-Up's raised, sinking while pressed.
class _Primary extends StatelessWidget {
  const _Primary({super.key, required this.label, required this.enabled, required this.onPress, this.icon, this.quiet = false});
  final String label;
  final LucideIcon? icon;
  final bool enabled, quiet;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return GlacierPressable(
      onPressed: enabled ? onPress : null,
      semanticLabel: label,
      builder: (context, state) {
        final off = !enabled;
        // Off: the kit's quiet disabled look (soft words on the paper's grey), not the dark button faded, which read as
        // on but muddy on a dark page (as the circle's invite sheet does).
        final ink = bevel ? (off ? DialupColors.of(t).disabled : DialupColors.of(t).onChrome) : t.color(off ? 'app-ink-3' : (quiet ? 'app-ink' : 'app-paper'));
        final words = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[AppIcon(icon!, size: 16, wash: false, color: ink), SizedBox(width: t.space(2))],
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'bold', color: ink))),
        ]);
        final inner = EdgeInsets.symmetric(vertical: t.space(3), horizontal: t.space(3));
        if (bevel) return Bevel(style: state.pressed && !off ? BevelStyle.sunken : BevelStyle.raised, kind: BevelKind.button, padding: inner, child: words);
        final fill = off ? 'app-paper-3' : quiet ? (state.pressed ? 'app-paper-3' : 'app-paper') : (state.pressed ? 'app-ink-2' : 'app-ink');
        return Container(
          padding: inner,
          decoration: BoxDecoration(
            color: t.color(fill),
            borderRadius: BorderRadius.circular(t.radius('full')),
            border: quiet && !off ? Border.all(color: t.color('app-rule')) : null,
          ),
          child: words,
        );
      },
    );
  }
}
