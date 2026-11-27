import 'dart:async';
import 'dart:convert' show base64Decode;
import 'composer_box.dart' show ComposerBox, ComposerField;
import 'cosmetics_ui.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../app_state.dart';
import '../art/app_icon.dart';
import '../games/game_activity.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../friends/buddies.dart';
import '../inbox/inbox.dart';
import '../kit/settings_type.dart';
import '../me/cosmetics.dart';
import '../me/identity.dart';
import '../me/me.dart';
import '../me/own_links.dart';
import '../mentions.dart';
import '../me/pictures.dart';
import '../net/name_watch.dart';
import '../net/net.dart';
import '../sms.dart';
import '../standalone/chats.dart' show UsernameChats;
import '../voice/hangout.dart';
import 'common.dart';
import 'dialup/parts.dart' show PackOrb;
import 'report_sheet.dart' show ReportTarget, showReportSheet;
import 'emoji_suggestions.dart';
import 'inbox_ui.dart' show openInboxChat, inboxMark;
import 'profile.dart';
import 'shell.dart';
import 'thread.dart';
import 'special_badges.dart';
import 'username_friends.dart' show acceptRequest;
import 'identity_ui.dart' show theirDidWords, didWords;
import 'own_links_ui.dart';
import 'vouches_ui.dart';
import 'verified_badge.dart';
import 'name_watch_words.dart';
import 'nav_bar.dart' show HoverTip;
import 'plugins_page/plugin_art.dart' show PluginHues;
import '../me/verified_numbers.dart';
import '../kit/picture_decode.dart';

/// Who a profile card is about (Matt, 2026-11-19: "when clicking on a @mention anywhere including signal and telegram
/// chats show this profile popup with actions available for the user in context of where it's placed"): someone on
/// Uplink, by their id on the hub or their username, or someone on another network ([network]), by its own id or
/// username. [room] is the space it was opened in, for what makes sense there.
class ProfileSubject {
  const ProfileSubject.ghost({this.id = '', this.username = '', this.name = '', this.room, this.onMention, this.detail = ''}) : network = null;
  const ProfileSubject.on(InboxNetwork this.network, {this.id = '', this.username = '', this.name = '', this.onMention, this.detail = ''}) : room = null;

  final InboxNetwork? network;
  final String id;
  final String username;
  final String name;
  final HangoutRoom? room;

  /// Puts an "@Name" for them in the composer where the card was opened from, where that can be done.
  final VoidCallback? onMention;

  /// A line of what they are where the card was opened ("Admin · On now" in a circle's members).
  final String detail;
}

/// A mention's [id] as the message lines carry it, made a subject: an Uplink id in a space ([room]), `u:<name>` for a
/// username written in the words, `n:<id>` for someone a network named.
ProfileSubject subjectOfMention(String id, {String words = '', InboxNetwork? network, HangoutRoom? room, VoidCallback? onMention}) {
  final name = words.startsWith('@') ? words.substring(1) : words;
  if (network != null) {
    if (id.startsWith('n:')) return ProfileSubject.on(network, id: id.substring(2), name: name, onMention: onMention);
    return ProfileSubject.on(network, username: id.startsWith('u:') ? id.substring(2) : name, name: name, onMention: onMention);
  }
  if (id.startsWith('u:')) return ProfileSubject.ghost(username: id.substring(2), name: name, room: room, onMention: onMention);
  return ProfileSubject.ghost(id: id, name: name, room: room, onMention: onMention);
}

/// Opens [who]'s profile: their picture, name, username, status and line, what can be done with them from here, and
/// for someone on Uplink a small field to write to them straight away.
Future<void> showProfile(BuildContext context, ProfileSubject who, {List<Choice> more = const []}) {
  final ghost = who.network == null ? _ghostOf(who) : null;
  final choices = <Choice>[
    if (who.onMention != null) Choice('Mention ${_nameOf(who, ghost)}', Lucide.atSign, who.onMention!),
    ..._actions(context, who, ghost),
    ...more,
  ];
  return showChoices(context, header: _ProfileCard(who: who, ghost: ghost), choices: choices);
}

/// What is known here of someone on Uplink: a friend's own profile, else what they said in the space, else their
/// username alone.
class _Ghost {
  _Ghost({required this.id, required this.username, required this.name, this.buddy, this.status = '', this.pictureHash = '', this.me = false, this.game, this.cosmetics = Cosmetics.none});
  final String id;
  final String username;
  final String name;
  final Buddy? buddy;
  final String status;
  final String pictureHash;
  final bool me;

  /// What they are playing, where they said so lately (lib/games/game_activity.dart): to this person as a friend, or
  /// to the space this was opened from.
  final GameActivity? game;

  /// What their profile wears (lib/me/cosmetics.dart): their own as a friend said, or as their greeting in the space did.
  final Cosmetics cosmetics;

  bool get friend => buddy?.state == 'yes';
}

/// Gathers what is known of [who]: found among friends by id or username, among those present in the space it was
/// opened from, or as oneself.
_Ghost _ghostOf(ProfileSubject who) {
  final buddies = Buddies.instance;
  final user = who.username.startsWith('@') ? who.username.substring(1) : who.username;
  final buddy = (who.id.isNotEmpty ? buddies.byId(who.id) : null) ?? (user.isNotEmpty ? buddies.all.where((b) => b.username == tidyHandle(user)).firstOrNull : null);
  final here = who.id.isNotEmpty ? who.room?.present[who.id] : null;
  final myName = Me.instance.username;
  final me = (who.id.isNotEmpty && (who.id == Net.instance.id || who.id == who.room?.me)) || (user.isNotEmpty && myName != null && tidyHandle(user) == myName);
  return _Ghost(
    id: who.id.isNotEmpty ? who.id : (buddy?.id ?? ''),
    username: buddy?.username ?? here?.username ?? (me ? (myName ?? '') : tidyHandle(user)),
    name: me ? Me.instance.shownName : (buddy?.shown ?? (here?.name.isNotEmpty == true ? here!.name : who.name)),
    buddy: buddy,
    status: me ? Me.instance.status : (buddy?.status.isNotEmpty == true ? buddy!.status : (here?.status ?? '')),
    pictureHash: here?.pictureHash ?? '',
    me: me,
    game: me ? GameActivities.instance.mine : (GameActivities.instance.of(buddy?.id ?? who.id) ?? here?.game),
    cosmetics: me ? Me.instance.cosmetics : (buddy != null && !buddy.cosmetics.isEmpty ? buddy.cosmetics : (here?.cosmetics ?? Cosmetics.none)),
  );
}

/// What a friend's card says of the relay they are on, where it isn't this app's.
/// A friend's relay, on their card: what reaches them, by whether this app's relay passes messages on ([talks]).
String friendRelayWords(String host, {bool talks = true}) => talks ? 'On $host, another relay than yours. What you write to each other goes through your relay to theirs, where both pass messages on.' : 'On $host, another relay than yours, and yours doesn\'t pass messages to other relays: what you write doesn\'t reach them from here.';

String _nameOf(ProfileSubject who, _Ghost? g) => (g?.name.isNotEmpty == true ? g!.name : (who.name.isNotEmpty ? who.name : (who.username.isNotEmpty ? who.username : 'them')));

/// What can be done with [who] from here, under the card.
List<Choice> _actions(BuildContext context, ProfileSubject who, _Ghost? g) {
  final network = who.network;
  if (network != null) {
    final handle = who.username;
    return [
      Choice('Message on ${network.name}', Lucide.messageSquare, () => unawaited(_openNetworkChat(context, who)), mark: inboxMark(network, size: 20)),
      if (handle.isNotEmpty) Choice('Copy @$handle', Lucide.copy, () => _copy(context, '@$handle')),
    ];
  }
  final ghost = g!;
  if (ghost.me) {
    return [Choice('Edit your profile', Lucide.pencil, () => push<void>(context, (_) => const ProfileScreen()))];
  }
  final links = ghost.buddy?.links ?? const <String, String>{};
  final phone = links['phone'];
  return [
    if (ghost.friend) Choice('Open chat', Lucide.messageSquare, () => unawaited(_openGhostChat(context, ghost))),
    if (ghost.friend) ...vouchChoices(context, ghost.buddy!),
    if (phone != null && phone.isNotEmpty) Choice('Text $phone', Lucide.messageSquare, () => unawaited(_openNumber(context, phone, ghost.name)), hint: 'Their number, as they shared it'),
    for (final e in links.entries)
      if (e.key != 'phone' && Inbox.instance.named(e.key)?.state == InboxState.ready)
        Choice('Message on ${Inbox.instance.named(e.key)!.name}', Lucide.messageSquare, () => unawaited(_openNetworkChat(context, ProfileSubject.on(Inbox.instance.named(e.key)!, username: e.value.replaceFirst('@', ''), name: ghost.name))),
            mark: inboxMark(Inbox.instance.named(e.key)!, size: 20), hint: e.value),
    if (!ghost.friend && ghost.buddy == null && ghost.username.isNotEmpty && Me.instance.username != null)
      Choice('Add @${ghost.username} as a friend', Lucide.userPlus, () => unawaited(_addFriend(context, ghost.username)), hint: 'You can write to them once they say yes'),
    if (ghost.buddy?.state == 'invited') Choice('Accept friend request', Lucide.userCheck, () => unawaited(acceptRequest(context, ghost.buddy!))),
    if (ghost.username.isNotEmpty) Choice('Copy @${ghost.username}', Lucide.copy, () => _copy(context, '@${ghost.username}')),
    // Report (GMFB-40): the person, from their card, with Block offered on the sheet.
    if (ghost.id.isNotEmpty || ghost.username.isNotEmpty)
      Choice('Report ${ghost.username.isNotEmpty ? '@${ghost.username}' : ghost.name}', Lucide.flag, () => unawaited(showReportSheet(context, ReportTarget(id: ghost.id, username: ghost.username, name: ghost.name, place: who.room != null ? 'space' : 'profile', placeName: who.room?.channel.name ?? '')))),
  ];
}

void _copy(BuildContext context, String text) {
  unawaited(Clipboard.setData(ClipboardData(text: text)));
  toast(context, 'Copied $text');
}

Future<void> _addFriend(BuildContext context, String username) async {
  try {
    await Buddies.instance.add(username);
    if (context.mounted) toast(context, 'Asked @$username to be friends');
  } catch (e) {
    if (context.mounted) toast(context, '$e', tone: GlacierToastTone.danger);
  }
}

/// Opens the conversation with a friend on Uplink, addressed by their username.
Future<void> _openGhostChat(BuildContext context, _Ghost g) async {
  final address = UsernameChats.addressOf(g.username);
  final person = Person(address: address, name: g.name);
  final thread = await Sms.instance.threadFor([address]);
  if (!context.mounted) return;
  final shell = AppShell.maybeOf(context);
  if (shell != null) return shell.openThread(thread, [person]);
  push<void>(context, (_) => ThreadScreen(thread: thread, people: [person]));
}

/// Opens the conversation of texts with [number].
Future<void> _openNumber(BuildContext context, String number, String name) async {
  try {
    final person = Person(address: number, name: name);
    final thread = await Sms.instance.threadFor([number]);
    if (!context.mounted) return;
    final shell = AppShell.maybeOf(context);
    if (shell != null) return shell.openThread(thread, [person]);
    push<void>(context, (_) => ThreadScreen(thread: thread, people: [person]));
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t start that chat: $e', tone: GlacierToastTone.danger);
  }
}

/// Opens the chat with [who] on their network, asking the network who a username is where only that is known.
Future<void> _openNetworkChat(BuildContext context, ProfileSubject who) async {
  final network = who.network!;
  try {
    var id = who.id;
    var name = who.name;
    if (id.isEmpty) {
      final p = await network.profileOf(username: who.username);
      id = p?.id ?? '';
      if (p != null && p.name.isNotEmpty) name = p.name;
    }
    if (id.isEmpty) throw StateError('${network.name} didn\'t say who that is');
    // A username that is a channel or a group (Telegram's are below zero): the chat itself.
    final chat = id.startsWith('-') ? id : await network.chatWith(InboxContact(network: network.id, id: id, name: name));
    if (!context.mounted) return;
    if (chat == null) throw StateError('${network.name} didn\'t open a chat');
    openInboxChat(context, network, network.chats.where((x) => x.id == chat).firstOrNull ?? InboxChat(network: network.id, id: chat, title: name, date: DateTime.now()));
  } catch (e) {
    if (context.mounted) toast(context, 'Couldn\'t start that chat: $e', tone: GlacierToastTone.danger);
  }
}

/// The card at the top of the sheet: picture, name, username and status, the line about them, and on Uplink the field
/// to write to them.
class _ProfileCard extends StatefulWidget {
  const _ProfileCard({required this.who, this.ghost});
  final ProfileSubject who;
  final _Ghost? ghost;

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  InboxProfile? _network;
  String? _picture;

  /// This account's did:key, on its own card (asked of the routes as the card opens; GMFB-33).
  String? _myDid;
  bool _looking = true;
  final _dm = TextEditingController();

  /// The emoji a ":jo" being written finds, over the box, and a whole ":joy:" put in as 😂 (lib/ui/emoji_suggestions.dart;
  /// GMFB-22, Matt, Mac 0.12.6: "typing :joy: or something should expand the emoji to the joy emoji and auto suggest
  /// with a popup"). Its list has the keys first while it is open, so Enter there picks rather than sends.
  late final EmojiShortcodeSuggester _shortcodes;
  late final _dmFocus = FocusNode(onKeyEvent: (node, e) => _shortcodes.key(e) ?? KeyEventResult.ignored);
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _shortcodes = EmojiShortcodeSuggester(_dm, app: () => mounted ? AppState.maybeOf(context) : null);
    unawaited(_look());
  }

  @override
  void dispose() {
    _shortcodes.dispose();
    _dm.dispose();
    _dmFocus.dispose();
    super.dispose();
  }

  /// Fetches what the card shows beyond what was handed in: a network's profile (ten seconds at most), or the
  /// picture of someone on Uplink.
  Future<void> _look() async {
    final who = widget.who, g = widget.ghost;
    try {
      if (who.network != null) {
        _network = await who.network!.profileOf(user: who.id, username: who.username).timeout(const Duration(seconds: 10));
      } else if (g != null) {
        if (g.me) {
          _picture = Me.instance.pictureOwn;
          try {
            _myDid = Did.ofKey((await Sms.instance.netIdentity()).key);
          } catch (_) {}
        } else if (g.buddy != null && g.buddy!.picture.isNotEmpty) {
          _picture = g.buddy!.picture;
        } else if (g.id.isNotEmpty) {
          _picture = ProfilePictures.instance.of(g.id, hash: g.pictureHash) ?? await who.room?.pictureOf(g.id);
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _looking = false);
  }

  Future<void> _send() async {
    final g = widget.ghost!;
    final words = _dm.text.trim();
    if (words.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await Sms.instance.send([UsernameChats.addressOf(g.username)], words);
      _dm.clear();
      if (mounted) toast(context, 'Sent to ${g.name.isNotEmpty ? g.name : '@${g.username}'}');
    } catch (e) {
      if (mounted) toast(context, 'Couldn\'t send: $e', tone: GlacierToastTone.danger);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final who = widget.who, g = widget.ghost, n = _network;
    final name = n?.name.isNotEmpty == true ? n!.name : (g?.name.isNotEmpty == true ? g!.name : (who.name.isNotEmpty ? who.name : who.username));
    final username = n?.username.isNotEmpty == true ? n!.username : (g?.username ?? who.username);
    final status = n?.status.isNotEmpty == true ? n!.status : (g?.status ?? '');
    final bio = n?.bio.isNotEmpty == true ? n!.bio : (g?.me == true ? Me.instance.bio : (g?.buddy?.bio ?? ''));
    final where = who.network?.name ?? 'Uplink';
    final sub = [if (username.isNotEmpty) '@$username', where, if (n != null && n.seen.isNotEmpty) n.seen, if (n != null && n.bot) 'bot'].join(' · ');
    // What they shared beyond Uplink: their number and the accounts they linked (Me.shareLinks), or a network's number.
    final links = <(String, String)>[
      for (final e in (g?.buddy?.links ?? const <String, String>{}).entries) (e.key == 'phone' ? 'Phone' : (Inbox.instance.named(e.key)?.name ?? _titled(e.key)), e.value),
      if (n != null && n.number.isNotEmpty) ('Phone', n.number),
    ];
    // The links they typed for their profile (GMFB-34; lib/me/own_links.dart): theirs by their word alone, so they are
    // set apart from the accounts above and say so.
    final own = g == null ? const <OwnLink>[] : (g.me ? Me.instance.ownLinks : (g.buddy?.state == 'yes' ? g.buddy!.own : const <OwnLink>[]));
    // On Uplink, by their id or, for an "@name" written in a message, their username: the verified mark and the badges
    // are asked of the relay either way (lib/me/verified_numbers.dart), so a mention by name shows them too.
    final known = g != null && (g.id.isNotEmpty || g.username.isNotEmpty);
    // Shaped as Discord's profile (Matt, 2026-11-20: "display badges on the users profile popup and redesign the
    // profile popup to be more like discords"): a banner in their colour, the face over its lower edge in a ring of the
    // card's own colour, their badges' marks in a small tray to its right, the name large, then a panel of what is
    // known of them, About me, Badges by name, Where (this circle) and their links, and the field to write to them.
    // What their profile wears (GMFB-34): only someone on Uplink has any.
    final dress = g?.cosmetics ?? Cosmetics.none;
    final face = t.lenOf('5rem');
    final ringW = t.lenOf('0.375rem');
    final bannerH = t.lenOf('5.5rem');
    final hues = PluginHues.of(t, hueFor(username.isNotEmpty ? username : (g?.id.isNotEmpty == true ? g!.id : name)));
    final card = t.color('app-paper-2');
    final heading = pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-2'), tracking: 0.4);
    Widget section(String title, Widget child, {Key? key}) => Padding(
          key: key,
          padding: EdgeInsets.only(top: t.space(3)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title.toUpperCase(), style: heading),
            SizedBox(height: t.space(1)),
            child,
          ]),
        );
    final badgeList = known
        ? ListenableBuilder(
            listenable: Listenable.merge([SpecialBadges.instance, Me.instance]),
            builder: (context, _) => _BadgeSection(badges: SpecialBadges.instance.of(g.id, username: g.username, me: g.me), section: section),
          )
        : const SizedBox.shrink();
    // The relay a friend is on, where it isn't this app's (docs/OPEN_NETWORK.md, section 4).
    final theirRelay = g?.buddy == null ? '' : Buddies.instance.relayOf(g!.buddy!);
    // The name watch (lib/net/name_watch.dart): the relay now gives this friend's username to another key. They are
    // still the key that was added; this only says so.
    final renamed = g == null || g.me || g.id.isEmpty ? null : NameWatch.instance?.changeFor(g.id);
    // Their account key as a did:key (GMFB-33; lib/me/identity.dart), with Copy and Share: a friend's from the key held
    // for them, this account's own as the routes know it.
    final did = g == null ? null : (g.me ? _myDid : _didOf(g.buddy));
    final panel = <Widget>[
      // In the card's own ink: the usual reason is an ordinary one (they changed or gave up the name, and someone took it).
      if (renamed != null)
        section('Their username', Text(friendNameChangedWords(renamed.username, name.isEmpty ? '@${renamed.username}' : name), key: const ValueKey('profile-name-watch'), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'), height: 1.4))),
      if (bio.isNotEmpty) section('About me', Text(bio, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'), height: 1.4))),
      if (theirRelay.isNotEmpty) section('Relay', Text(friendRelayWords(theirRelay, talks: Buddies.instance.relayTalks), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink'), height: 1.4)), key: const ValueKey('profile-relay')),
      badgeList,
      if (did != null)
        section(
          'Account key',
          key: const ValueKey('profile-did'),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Text(Did.short(did), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
              IconTap(key: const ValueKey('profile-did-copy'), icon: Lucide.copy, label: 'Copy the account key', size: 16, box: t.lenOf('2rem'), onPressed: () => _copy(context, did)),
              IconTap(key: const ValueKey('profile-did-share'), icon: Lucide.share2, label: 'Share the account key', size: 16, box: t.lenOf('2rem'), onPressed: () => unawaited(Sms.instance.shareText('An Uplink account key', did))),
            ]),
            Text(g!.me ? didWords : theirDidWords(name.isEmpty ? 'This person' : name), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.4)),
          ]),
        ),
      // How many of the viewer's own friends vouch for them (GMFB-33), their names on a tap.
      if (g != null && (g.me || g.buddy?.state == 'yes')) VouchesLine(buddy: g.me ? null : g.buddy, section: section),
      if (who.detail.isNotEmpty) section(who.room != null ? 'In this space' : 'Here', Text(who.detail, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
      if (links.isNotEmpty || own.isNotEmpty)
        section(
          'Elsewhere',
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            for (final (label, value) in links)
              Padding(
                padding: EdgeInsets.only(top: t.space(1) / 2),
                child: Row(children: [
                  SizedBox(width: t.lenOf('5.5rem'), child: Text(label, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
                  Expanded(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
                ]),
              ),
            if (own.isNotEmpty) OwnLinksList(links: own, name: name.isEmpty ? 'This person' : name, mine: g?.me ?? false),
          ]),
        ),
    ];
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      // The banner, with the face over its lower edge and the badges' tray under it at the right.
      SizedBox(
        height: bannerH + face / 2 + ringW,
        child: Stack(clipBehavior: Clip.none, children: [
          PositionedDirectional(
            key: const ValueKey('profile-banner'),
            start: 0,
            end: 0,
            top: 0,
            height: bannerH,
            // Their chosen banner (GMFB-34), else a band in their colour.
            child: CosmeticBanner(
              id: dress.banner,
              // Their own picture as the banner, where they set one (a friend's, or this person's own).
              picture: g == null ? '' : (g.me ? Me.instance.banner : (g.buddy?.banner ?? '')),
              fallback: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: [hues.start, hues.end]))),
            ),
          ),
          PositionedDirectional(
            start: t.space(4) - ringW,
            top: bannerH - face / 2 - ringW,
            child: Container(
              key: const ValueKey('profile-face'),
              padding: EdgeInsets.all(ringW),
              decoration: BoxDecoration(color: card, shape: BoxShape.circle),
              child: DressedFace(size: face, cosmetics: dress, face: ProfileFace(name: name, picture: _picture, file: n?.avatar, size: face)),
            ),
          ),
          if (known)
            PositionedDirectional(
              end: t.space(4),
              top: bannerH + t.space(2),
              child: _BadgeTray(id: g.id, username: g.username, me: g.me),
            ),
          if (_looking) PositionedDirectional(end: t.space(3), top: t.space(3), child: const GhostSpinner(size: 16)),
        ]),
      ),
      Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(2)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Flexible(
              child: NameEffectText(name.isEmpty ? 'Someone' : name, key: const ValueKey('profile-name'), id: dress.name, style: pageText(t, t.fontSize('xl'), weight: 'bold', color: t.color('app-ink'))),
            ),
            // The verified-number mark beside the name, as Discord's verified badge is (Matt, 2026-11-19); the special
            // badges are in the tray and the panel, not here twice.
            if (known) VerifiedBadge(id: g.id, username: g.username, me: g.me, size: 20, special: false),
            // A small check where at least one of the viewer's own friends vouches for them (GMFB-33); the count and
            // the names are in the panel.
            if (g != null && (g.me || g.buddy?.state == 'yes')) VouchMark(buddy: g.me ? null : g.buddy),
          ]),
          Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          if (status.isNotEmpty) ...[
            SizedBox(height: t.space(2)),
            // Their status as Discord's custom status: a bubble under the name.
            Container(
              key: const ValueKey('profile-status'),
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              child: Text(status, maxLines: 3, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink'))),
            ),
          ],
          if (g?.game != null) ...[
            SizedBox(height: t.space(2)),
            // What they are playing, as Discord shows it: the game and for how long (Matt, 2026-11-20: "game presence
            // sensing like discord has").
            Container(
              key: const ValueKey('profile-game'),
              padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
              decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AppIcon(LucideMore.gamepad, size: 16, color: t.colorOf('#2fb35a')),
                SizedBox(width: t.space(2)),
                Flexible(child: Text(g!.game!.words(), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
              ]),
            ),
          ],
          if (panel.isNotEmpty || known)
            Container(
              key: const ValueKey('profile-panel'),
              margin: EdgeInsets.only(top: t.space(3)),
              padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), t.space(3)),
              decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              // Empty where nothing is known beyond the name: the panel's own padding then is all there is, which
              // reads as a thin rule; so it is left out unless it has something.
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: panel),
            ),
          if (g != null && g.friend && !g.me) ...[
            SizedBox(height: t.space(3)),
            EmojiSuggestions(suggester: _shortcodes),
            // The box every conversation writes in, Send inside it at its end (Matt, 2026-11-19: "move the send message
            // button inside the input like we have on the rest of the app as well within that drawer").
            ListenableBuilder(
              listenable: _dm,
              builder: (context, _) => ComposerBox(
                key: const ValueKey('profile-dm'),
                typing: false,
                // Its edges on the card's, lined up with the choices under it (Matt, 2026-11-19).
                flush: true,
                ground: t.color('app-paper'),
                ends: [
                  IconTap(
                    key: const ValueKey('profile-dm-send'),
                    icon: Lucide.arrowUp,
                    label: 'Send',
                    filled: true,
                    size: 19,
                    box: t.lenOf('2.25rem'),
                    onPressed: _sending || _dm.text.trim().isEmpty ? null : () => unawaited(_send()),
                  ),
                ],
                field: ComposerField(controller: _dm, focusNode: _dmFocus, hint: 'Message ${g.name.isNotEmpty ? g.name : '@${g.username}'}', onSubmitted: () => unawaited(_send()), enterSends: true),
              ),
            ),
          ],
        ]),
      ),
    ]);
    // Their profile effect drifting over the whole card, never in the way of a touch.
    if (dress.effect.isEmpty) return body;
    return Stack(children: [body, Positioned.fill(child: ProfileEffectLayer(key: const ValueKey('profile-effect'), id: dress.effect))]);
  }
}

/// The badges' marks in a small rounded tray beside the face, each named in a tip, as Discord's profile has them.
class _BadgeTray extends StatelessWidget {
  const _BadgeTray({required this.id, required this.username, required this.me});
  final String id;
  final String username;
  final bool me;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([SpecialBadges.instance, VerifiedNumbers.instance, Me.instance]),
      builder: (context, _) {
        final t = context.tokens;
        final badges = SpecialBadges.instance.of(id, username: username, me: me);
        if (badges.isEmpty) return const SizedBox.shrink();
        return Container(
          key: const ValueKey('profile-badge-tray'),
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1) + 2),
          decoration: BoxDecoration(color: t.color('app-paper'), borderRadius: BorderRadius.circular(t.radius('md'))),
          child: Row(mainAxisSize: MainAxisSize.min, spacing: t.space(2), children: [
            for (final b in badges)
              HoverTip(
                key: ValueKey('profile-badge-${b.id}'),
                message: b.name,
                child: Semantics(label: b.name, child: AppIcon(b.icon, size: 18, color: PluginHues.of(t, b.hue).accent)),
              ),
          ]),
        );
      },
    );
  }
}

/// The panel's Badges: each by name, with what it is for, where the tray has only their marks.
class _BadgeSection extends StatelessWidget {
  const _BadgeSection({required this.badges, required this.section});
  final List<SpecialBadge> badges;
  final Widget Function(String title, Widget child, {Key? key}) section;

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) return const SizedBox.shrink();
    final t = context.tokens;
    return section(
      badges.length == 1 ? 'Badge' : 'Badges',
      key: const ValueKey('profile-special'),
      Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [for (final b in badges) SpecialBadgeChip(badge: b)]),
    );
  }
}

/// Someone's face: their picture (a base64 [picture], or a [file] a network fetched), else their initial on a disc.
class ProfileFace extends StatelessWidget {
  const ProfileFace({super.key, required this.name, this.picture, this.file, this.size = 44});
  final String name;
  final String? picture;
  final String? file;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    Widget? image;
    final p = picture;
    if (p != null && p.isNotEmpty) {
      final bytes = pictureBytes(p);
      if (bytes != null) image = Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: faceDecodeWidth(context, size));
    }
    final f = file;
    if (image == null && f != null && f.isNotEmpty && File(f).existsSync()) image = Image.file(File(f), width: size, height: size, fit: BoxFit.cover, cacheWidth: faceDecodeWidth(context, size));
    // Inside a resource pack's orb where the look draws with one (lib/ui/dialup/parts.dart's PackOrb).
    if (image != null) return PackOrb(size: size, child: ClipOval(child: SizedBox(width: size, height: size, child: image)));
    final letter = name.trim().isEmpty ? '?' : String.fromCharCodes(name.trim().runes.take(1)).toUpperCase();
    return PackOrb(size: size, child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('app-paper-2'), border: Border.all(color: t.color('app-rule'))),
      child: name.trim().isEmpty ? AppIcon(Lucide.circleUser, size: size * 0.45, color: t.color('app-ink-3')) : Text(letter, style: pageText(t, size * 0.4, weight: 'bold', color: t.color('app-ink-2'))),
    ));
  }
}

/// The "@username"s written in [text] as plain words (an Uplink username's shape: three to twenty letters, numbers, dots
/// or underscores, not inside an email address), as mentions whose id is `u:<username>` ([subjectOfMention]): in a
/// conversation, where nothing says who an "@" means, the name written is who is meant.
List<Mention> handleMentions(String text) {
  if (!text.contains('@')) return const [];
  final out = <Mention>[];
  for (final m in _handle.allMatches(text)) {
    final at = m.start + m.group(1)!.length;
    var name = m.group(2)!;
    while (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    if (name.length < 3) continue;
    out.add(Mention(at, name.length + 1, 'u:${name.toLowerCase()}'));
    if (out.length >= Mention.most) break;
  }
  return Mention.checked(out, text);
}

/// An "@username" written in a message: 3 to 20 letters, numbers, dots or underscores, not inside a word or an email
/// address.
final _handle = RegExp(r'(^|[^A-Za-z0-9_.@])@([A-Za-z0-9][A-Za-z0-9._]{2,19})(?![A-Za-z0-9_@])');

/// [m]'s mentions as the message lines carry them: `n:<id>` where the network named the person, `u:<username>` where
/// only their username was written.
List<Mention> inboxMentions(InboxMessage m) => Mention.checked([
      for (final x in m.mentions)
        if (x.user.isNotEmpty || x.username.isNotEmpty) Mention(x.start, x.length, x.user.isNotEmpty ? 'n:${x.user}' : 'u:${x.username}'),
    ], m.text);

/// [b]'s did:key, from the key held for them; null where none is, or it isn't a key.
String? _didOf(Buddy? b) {
  if (b == null || b.key.isEmpty) return null;
  try {
    return Did.ofKey(base64Decode(b.key));
  } catch (_) {
    return null;
  }
}

String _titled(String network) => network.isEmpty ? network : network[0].toUpperCase() + network.substring(1);
