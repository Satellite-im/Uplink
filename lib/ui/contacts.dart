import 'blocking.dart';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../friends/friends.dart';
import '../inbox/inbox.dart';
import '../inbox/people.dart';
import '../sms.dart';
import 'common.dart';
import 'dialup/dialup.dart' show DialupColors, RetroButton, isBevelChrome;
import 'inbox_ui.dart' show inboxMark, openInboxChat;
import 'shell.dart';
import 'skeleton.dart';
import 'thread.dart';
import 'add_friend_drawer.dart';
import 'username_friends.dart';
import '../friends/buddies.dart';
import '../l10n/words.dart';

/// The address book (Matt, 2026-11-14: "add an address book icon"): the phone's contacts, searched by name or
/// number, and a press on one opens the conversation with them. It is the phone's own list, asked of the phone: with
/// nothing typed it shows the people texted most, and typing finds anyone.
///
/// Telegram's and Signal's contacts are here too once they are linked (Matt, 2026-11-16: "Show telegram and signal
/// contacts when linked with icons to show which each is and filters, where contacts can be messages on multiple
/// platforms as which you like to use when stating a conversation"): one row a person however many places they are
/// (lib/inbox/people.dart), each place's mark at the row's end, filters for each, and a press on someone reachable more
/// than one way asks which to write on.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<Map<String, String?>>? _found;
  String? _error;
  String _query = '';
  Timer? _debounce;
  // Counts the searches begun, so an answer that comes after a newer search was asked is dropped.
  int _asked = 0;
  bool _opening = false;

  /// 'all', 'friends', 'phone', or a network's id.
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _look('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Asks the phone for the contacts that match [query] (all of them for an empty one).
  Future<void> _look(String query) async {
    final asked = ++_asked;
    try {
      final found = await Sms.instance.searchContacts(query);
      if (mounted && asked == _asked) {
        setState(() {
          _found = found;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted && asked == _asked) setState(() => _error = '$e');
    }
  }

  void _typed(String query) {
    _query = query.trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () => _look(_query));
  }

  /// The conversation with [person], opened in place of this page.
  Future<void> _open(Person person) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final thread = await Sms.instance.threadFor([person.address]);
      if (!mounted) return;
      // In the app's frame the conversation takes this page's place in the pane, and the list marks it.
      final shell = AppShell.maybeOf(context);
      if (shell != null) return shell.openThread(thread, [person]);
      Navigator.of(context).pushReplacement(PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 140),
        pageBuilder: (context, _, _) => ThreadScreen(thread: thread, people: [person]),
        transitionsBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: child),
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _opening = false);
        toast(context, 'Couldn\'t open that conversation: $e', tone: GlacierToastTone.danger);
      }
    }
  }

  /// The chat with [contact] on its network, made there where there is none yet.
  Future<void> _openOn(InboxContact contact) async {
    final network = Inbox.instance.named(contact.network);
    if (network == null || _opening) return;
    setState(() => _opening = true);
    try {
      final chat = await network.chatWith(contact);
      if (!mounted) return;
      setState(() => _opening = false);
      if (chat == null) {
        toast(context, 'Couldn\'t start a chat with ${contact.name} on ${network.name}', tone: GlacierToastTone.danger);
        return;
      }
      openInboxChat(context, network, network.chats.where((c) => c.id == chat).firstOrNull ?? InboxChat(network: network.id, id: chat, title: contact.name, date: DateTime.now(), avatar: contact.avatar));
    } catch (e) {
      if (mounted) {
        setState(() => _opening = false);
        toast(context, 'Couldn\'t start that chat: $e', tone: GlacierToastTone.danger);
      }
    }
  }

  /// Writes to [s] by the way [r]: their chat on a network, or the conversation with their number or username.
  void _reach(Someone s, Reach r) {
    final c = r.contact;
    if (c != null) {
      unawaited(_openOn(c));
    } else {
      // A friend by username's name is theirs, not a contact's, and goes with them.
      unawaited(_open(Person(address: r.address!, name: s.inPhone || r.address!.startsWith('@') ? s.name : null, photo: s.photo)));
    }
  }

  /// A press on someone: straight to them where there is one way to write, else which way, each with its mark.
  void _pressed(Someone s) {
    if (s.reaches.length == 1) return _reach(s, s.reaches.single);
    // No way to write to them is known: said, not a choice of nothing.
    if (s.reaches.isEmpty) {
      toast(context, 'There\'s no way to message ${s.name} from here yet');
      return;
    }
    showChoices(context, title: 'Message ${s.name} with', choices: [
      for (final r in s.reaches)
        if (r.contact == null)
          Choice(s.friend ? 'Uplink' : 'Text message', s.friend ? Lucide.userCheck : Lucide.messageSquare, () => _reach(s, r), hint: s.friend ? '${r.address} · over the internet' : r.address)
        else
          Choice(
            Inbox.instance.named(r.contact!.network)?.name ?? r.contact!.network,
            Lucide.messageSquare,
            () => _reach(s, r),
            mark: _mark(r.contact!.network, 20),
            hint: r.contact!.handle ?? r.contact!.number ?? r.contact!.name,
          ),
    ]);
  }

  /// A network's own mark by its id; the plain message icon for one not known here (texts).
  Widget _mark(String network, double size) {
    final n = Inbox.instance.named(network);
    return n == null ? AppIcon(Lucide.messageSquare, size: size) : inboxMark(n, size: size);
  }

  /// The networks whose contacts the list has, signed in now: each is a filter.
  List<InboxNetwork> get _networks => [for (final n in Inbox.instance.ready) if (n.contacts.isNotEmpty) n];

  /// What the list shows: the people added on Uplink (friends) first, under their own heading, then everyone
  /// else (Matt, 2026-11-15: "Contacts added on Ghost Messaging should render at the top instead of the normal
  /// contacts"), the phone's contacts and Telegram's and Signal's put together, narrowed by the filter and a search.
  List<_Row> _rows(List<Map<String, String?>> found) {
    final byDigits = {for (final c in found) Friends.digits(c['address'] ?? ''): c};
    final q = _query.toLowerCase();
    final qDigits = Friends.digits(_query);
    final phone = <PhoneContact>[];
    final friendKeys = <String>{};
    for (final s in Friends.instance.friends) {
      final contact = byDigits[Friends.digits(s.address)];
      final address = s.person?.address ?? contact?['address'] ?? s.address;
      final name = s.person?.name ?? contact?['name'];
      if (q.isNotEmpty) {
        final named = name != null && name.toLowerCase().contains(q);
        final numbered = qDigits.isNotEmpty && Friends.digits(address).contains(qDigits);
        if (!named && !numbered) continue;
      }
      friendKeys.add(numberKey(address));
      phone.add(PhoneContact(address: address, name: name, photo: s.person?.photo ?? contact?['photo'], label: contact?['label'], friend: true));
    }
    for (final c in found) {
      if (Friends.instance.isFriend(c['address'] ?? '')) continue;
      phone.add(PhoneContact(address: c['address'] ?? '', name: c['name'], photo: c['photo'], label: c['label']));
    }
    final contacts = [for (final n in _networks) ...n.contacts];
    // The phone answered the search itself; the networks' contacts are searched here.
    var people = [for (final s in gather(phone, contacts)) if (s.inPhone || s.friend || answers(s, _query)) s];
    // Friends by username are on Uplink as much as friends by number are, so they are among them under the
    // one heading, not a section of their own (Matt, 2026-11-19: "friends by username and friends on ghost messaging
    // are about equal, just show the On Ghost Messaging and remove the Friends by username section on the contacts
    // page"). A press opens their chat, as one from Messages does.
    // Each once (Buddies.shownFriends), and not again where the list has them already by their @username.
    final listed = {for (final s in people) if (s.number != null && s.number!.startsWith('@')) s.number!.toLowerCase()};
    for (final b in Buddies.instance.shownFriends) {
      if (q.isNotEmpty && !b.shown.toLowerCase().contains(q) && !b.username.toLowerCase().contains(q.replaceFirst('@', ''))) continue;
      if (!listed.add('@${b.username}'.toLowerCase())) continue;
      people.add(Someone(name: b.shown, number: '@${b.username}', friend: true, reaches: [Reach.phone('@${b.username}')]));
    }
    people = friendsFirst(narrowed(people, _filter));
    final friends = [for (final s in people) if (s.friend) s];
    final rest = [for (final s in people) if (!s.friend) s];
    // Under Friends everyone is one, so no heading says so.
    if (friends.isEmpty || _filter == 'friends') return [for (final s in people) _Row(someone: s)];
    return [
      const _Row(heading: 'On Uplink'),
      for (final s in friends) _Row(someone: s),
      if (rest.isNotEmpty) const _Row(heading: 'Contacts'),
      for (final s in rest) _Row(someone: s),
    ];
  }

  /// Whether the filters are offered: with a network linked, or anyone added on Uplink to narrow to (with
  /// neither, All and Phone would be the same list).
  bool _filtersShown(List<InboxNetwork> networks) => networks.isNotEmpty || Friends.instance.friends.isNotEmpty || Buddies.instance.friends.isNotEmpty;

  /// The filters: everyone, friends on Uplink (Matt, 2026-11-17: "add the ability to sort contacts by friends
  /// in ghost"), the phone's contacts, and each linked network's, with its mark.
  Widget _filters(Tokens t, List<InboxNetwork> networks) {
    final dialup = isBevelChrome(t);
    Widget chip(String id, String label, Widget? mark) {
      final on = _filter == id;
      // Under Dial-Up the filters are a row of push buttons, the one shown held in, as every segmented toggle there is
      // (Matt, 2026-11-18: "make sure every segmented toggle also has beveled button like apperances").
      if (dialup) {
        return RetroButton(
          onPressed: () => setState(() => _filter = id),
          toggled: on,
          face: on ? DialupColors.of(t).lo : null,
          faceHeight: 32,
          semanticLabel: '$label${on ? ', shown' : ''}',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (mark != null) ...[mark, SizedBox(width: t.space(1) + 2)],
            Text(label, maxLines: 1, style: pageText(t, t.fontSize('sm'), weight: on ? 'bold' : 'regular', color: DialupColors.of(t).onChrome)),
          ]),
        );
      }
      return GlacierPressable(
        onPressed: () => setState(() => _filter = id),
        semanticLabel: '$label${on ? ', shown' : ''}',
        builder: (context, state) => AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1) + 3),
          decoration: BoxDecoration(
            color: on ? t.color('app-ink') : (state.pressed || state.hovered ? t.color('app-paper-3') : t.color('app-paper-2')),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (mark != null) ...[mark, SizedBox(width: t.space(1) + 2)],
            Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: on ? t.color('app-paper') : t.color('app-ink'))),
          ]),
        ),
      );
    }

    // A mark's ink: the chosen chip's paper on its filled face, or the bevel's ink on Dial-Up's silver buttons.
    Color markInk(String id) => dialup ? DialupColors.of(t).onChrome : (_filter == id ? t.color('app-paper') : t.color('app-ink'));

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
      child: Row(spacing: dialup ? t.space(1) : t.space(2), children: [
        chip('all', 'All', null),
        chip('friends', 'Friends', AppIcon(Lucide.userCheck, size: 15, wash: false, color: markInk('friends'))),
        // A page in a browser has no phone's contacts to show.
        if (!Sms.browser) chip('phone', 'Phone', AppIcon(Lucide.smartphone, size: 15, wash: false, color: markInk('phone'))),
        for (final n in networks) chip(n.id, n.name, inboxMark(n, size: 16, badge: true)),
      ]),
    );
  }

  /// The list of everyone blocked: in the pane in the app's frame, else a page over this one.
  void _openBlocked() {
    final shell = AppShell.maybeOf(context);
    if (shell != null) {
      shell.show(BlockedScreen(onBack: shell.contacts), showing: 'contacts');
    } else {
      push<void>(context, (_) => const BlockedScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final found = _found;
    return GhostPage(
      title: 'Contacts',
      back: true,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
          // Add, beside the search, opens the drawer that finds friends by username, and has a username chosen first
          // where there is none (lib/ui/add_friend_drawer.dart; Matt, 2026-11-16: "move the Add button to the side of
          // search and have it open a drawer"). On the phone, whose friends they are.
          child: Row(children: [
            Expanded(child: GlacierSearchField(placeholder: 'Search contacts'.t, size: GlacierFieldSize.md, onValueChange: _typed)),
            // On a computer too, through its phone (Matt, 2026-11-18: "I don't see the ability to add friends on desktop").
            ...[SizedBox(width: t.space(2)), const AddFriendButton()],
            // Blocked, to the right of Add (Matt, 2026-11-19: "move blocked to the right of the add friend button
            // instead of making it it's whole own rown"): everyone blocked, numbers and Telegram and Signal people
            // alike (lib/ui/blocking.dart).
            SizedBox(width: t.space(2)),
            _RoundButton(key: const ValueKey('contacts-blocked'), icon: Lucide.ban, label: 'Blocked', onPressed: _openBlocked),
          ]),
        ),
        // A filter for each linked network with contacts, beside All, Friends and Phone; none until a network is linked
        // or someone is added on Uplink. A filter whose chip has gone goes back to All.
        ListenableBuilder(
          listenable: Listenable.merge([Inbox.instance.changes, Friends.instance]),
          builder: (context, _) {
            final networks = _networks;
            final shown = _filtersShown(networks);
            final offered = {'all', if (shown) ...['friends', 'phone'], for (final n in networks) n.id};
            if (!offered.contains(_filter)) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() => _filter = 'all') : null);
            return shown ? _filters(t, networks) : const SizedBox.shrink();
          },
        ),
        // New group is not here: it is under the + of the list (Matt, 2026-11-17: "remove the new group from the
        // contacts page since it's already under the plus button").
        Expanded(
          child: found == null && _error == null
              // The people in bones while they are read (lib/ui/skeleton.dart).
              ? const SkeletonPeople(label: 'Reading your contacts…')
              : found == null
              ? Center(
                  child: Padding(
                          padding: EdgeInsets.all(t.space(6)),
                          child: SettingsEmpty(
                            icon: AppIcon(Lucide.contactRound, size: 28, color: t.color('app-ink-3')),
                            title: 'Your contacts couldn\'t be read',
                            body: Text(Sms.followsPhone ? 'They are on the phone, which isn\'t reachable just now.' : _error!),
                            action: SettingsEmptyAction('Try again', () => _look(_query)),
                          ),
                        ),
                )
              : ListenableBuilder(
                  listenable: Listenable.merge([Friends.instance, Buddies.instance, Inbox.instance.changes]),
                  builder: (context, _) {
                    final rows = _rows(found);
                    // Friend requests and the ones sent first (lib/ui/username_friends.dart; Matt, 2026-11-16: "We need a
                    // way to add friends on the network by username on the contacts page and see friend requests"), while
                    // nothing is searched for; the friends themselves are On Uplink below.
                    final friends = _query.isEmpty;
                    return rows.isEmpty
                  ? ListView(padding: EdgeInsets.only(bottom: t.space(6)), children: [
                      if (friends) const UsernameFriends(),
                      Padding(
                      padding: EdgeInsets.all(t.space(6)),
                      child: SettingsEmpty(
                        icon: AppIcon(Lucide.contactRound, size: 28, color: t.color('app-ink-3')),
                        title: _query.isEmpty ? (_filter == 'friends' ? 'No friends yet' : 'No contacts') : 'Nobody found',
                        body: Text(_query.isEmpty
                            ? (_filter == 'friends'
                                ? 'People you add on Uplink appear here.'
                                : _filter == 'all' || _filter == 'phone'
                                    ? (Sms.browser ? 'People you add on Uplink appear here.' : 'People in the phone\'s contacts appear here.')
                                    : 'Nobody in your ${Inbox.instance.named(_filter)?.name ?? ''} contacts yet.')
                            : 'No name or number in your contacts matches "$_query".'),
                      ),
                    ),
                    ])
                  : ListView.builder(
                      padding: EdgeInsets.only(bottom: t.space(6)),
                      // The line about the people texted most is the phone's list, not Friends'.
                      itemCount: (friends ? 1 : 0) + rows.length + (_query.isEmpty && _filter != 'friends' ? 1 : 0),
                      itemBuilder: (context, at) {
                        if (friends && at == 0) return const UsernameFriends();
                        final i = friends ? at - 1 : at;
                        if (i == rows.length) {
                          return Padding(
                            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), 0),
                            child: Text(Sms.browser ? 'Your friends on Uplink. Add another by their username.' : 'The people you text most. Search to find anyone else.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                          );
                        }
                        final row = rows[i];
                        if (row.heading != null) {
                          return Padding(
                            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(i == 0 ? 1 : 4), t.space(4), t.space(1)),
                            child: Text(row.heading!, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'))),
                          );
                        }
                        final someone = row.someone!;
                        // Someone on a network with no number: named by their id there, so their presence is found (Avatar).
                        final onNetwork = someone.reaches.map((r) => r.contact).whereType<InboxContact>().firstOrNull;
                        final person = Person(address: someone.number ?? (onNetwork != null ? '${onNetwork.network}:${onNetwork.id}' : '${someone.reaches.first.kind}:${someone.name}'), name: someone.name, photo: someone.photo);
                        final handle = someone.reaches.map((r) => r.contact?.handle).whereType<String>().firstOrNull;
                        final sub = [
                          if (someone.number != null) someone.number! else ?handle,
                          if (someone.label != null && someone.label!.isNotEmpty) someone.label!,
                        ].join(' · ');
                        return GlacierPressable(
                          onPressed: () => _pressed(someone),
                          semanticLabel: '${someone.name}, ${[for (final k in someone.kinds) k == 'phone' ? (someone.friend ? 'Uplink' : 'text') : Inbox.instance.named(k)?.name ?? k].join(', ')}',
                          builder: (context, state) => ColoredBox(
                            color: state.pressed || state.hovered ? t.color('app-paper-2') : const Color(0x00000000),
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2) + 2),
                              child: Row(children: [
                                Avatar(people: [person], size: t.lenOf('2.5rem')),
                                SizedBox(width: t.space(3)),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(someone.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium')),
                                    if (sub.isNotEmpty && sub != someone.name)
                                      Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
                                  ]),
                                ),
                                SizedBox(width: t.space(2)),
                                // Where they can be written to: a friend's Uplink tick or the phone, then each network's mark.
                                Row(mainAxisSize: MainAxisSize.min, spacing: t.space(1) + 2, children: [
                                  for (final k in someone.kinds)
                                    if (k == 'phone')
                                      Semantics(label: someone.friend ? 'On Uplink' : 'Text message', child: AppIcon(someone.friend ? Lucide.userCheck : Lucide.messageSquare, size: 16, wash: false, color: t.color('app-ink-3')))
                                    else
                                      _mark(k, 18),
                                ]),
                              ]),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// A line of the list: a heading, or someone in it.
class _Row {
  const _Row({this.heading, this.someone});
  final String? heading;
  final Someone? someone;
}


class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.label, required this.onPressed});
  final LucideIcon icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('2.5rem');
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2')),
        alignment: Alignment.center,
        child: AppIcon(icon, size: 18, color: t.color('app-ink')),
      ),
    );
  }
}
