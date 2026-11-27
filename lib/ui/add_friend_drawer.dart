import 'dart:async';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../sms.dart';
import 'common.dart';
import '../kit/semantic_colors.dart';
import '../l10n/words.dart';

/// Adding a friend by username, in a drawer from the Add button beside Contacts' search (Matt, 2026-11-16: "move the
/// Add button to the side of search and have it open a drawer to search and add users as well as setup username if
/// hasn't been done already").
///
/// Without a username of your own the drawer asks for one first, there and then. With one, it looks up what is typed
/// as it is typed: someone who has that username shows with Add (or with where you already stand with them). The
/// server finds a username whole, not by its start: nobody can be listed by guessing letters.
Future<void> showAddFriendDrawer(BuildContext context, {Buddies? buddies, Me? me}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => AddFriendDrawer(buddies: buddies, me: me),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The round Add beside Contacts' search, as tall as the field.
class AddFriendButton extends StatelessWidget {
  const AddFriendButton({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('2.5rem');
    return GlacierPressable(
      key: const ValueKey('add-friend'),
      onPressed: () => showAddFriendDrawer(context),
      semanticLabel: 'Add a friend',
      builder: (context, state) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2')),
        alignment: Alignment.center,
        child: AppIcon(Lucide.userPlus, size: 18, color: t.color('app-ink')),
      ),
    );
  }
}

/// The drawer itself: choosing a username where you have none, and otherwise the search and what it found.
class AddFriendDrawer extends StatefulWidget {
  const AddFriendDrawer({super.key, this.buddies, this.me});

  /// For a test or a picture; the app's own otherwise.
  final Buddies? buddies;
  final Me? me;

  @override
  State<AddFriendDrawer> createState() => _AddFriendDrawerState();
}

class _AddFriendDrawerState extends State<AddFriendDrawer> {
  final _field = TextEditingController();
  Timer? _wait;
  String? _problem;
  bool _busy = false;

  /// The username looked up, and what was found; null while nothing whole is typed or the answer is coming.
  String? _looked;
  BuddyLookup? _found;
  // Counts the lookups begun, so an answer that comes after a newer one was asked is dropped.
  int _asked = 0;

  Buddies get _buddies => widget.buddies ?? Buddies.instance;
  Me get _me => widget.me ?? Me.instance;

  @override
  void dispose() {
    _wait?.cancel();
    _field.dispose();
    super.dispose();
  }

  /// The search field changed: a whole, well-formed username is looked up once typing has paused for 350 ms.
  void _typed(String _) {
    _wait?.cancel();
    setState(() => _problem = null);
    if (_me.username == null) return;
    final name = tidyHandle(_field.text);
    // A username here, or name@relay for someone on another relay (lib/net/home_record.dart).
    if (!Buddies.goodAddress(name)) {
      setState(() {
        _looked = null;
        _found = null;
      });
      return;
    }
    // A name on another relay is not asked of anyone as it is typed (lib/friends/buddies.dart lookup says so at once):
    // only when Add is pressed.
    _wait = Timer(const Duration(milliseconds: 350), () => _look(name));
  }

  Future<void> _look(String name) async {
    final asked = ++_asked;
    setState(() {
      _looked = name;
      _found = null;
    });
    try {
      final found = await _buddies.lookup(name);
      if (mounted && asked == _asked) setState(() => _found = found);
    } catch (e) {
      if (mounted && asked == _asked) setState(() => _problem = '$e');
    }
  }

  /// Takes the username typed as your own; the drawer turns to the search once it is yours.
  Future<void> _claim() async {
    final want = tidyHandle(_field.text);
    if (!Me.goodUsername(want)) {
      setState(() => _problem = '3 to 20 letters, digits or _, starting with a letter.');
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await _me.claimUsername(want);
      _field.clear();
      if (mounted) toast(context, 'You\'re @$want');
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks [name] to be a friend, or accepts where they asked first, and says which happened.
  Future<void> _add(String name) async {
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final b = await _buddies.add(name);
      if (!mounted) return;
      if (_buddies.unreached(b)) {
        // Found on their relay, but this app's relay couldn't pass the request to it.
        setState(() => _problem = addUnreachedWords(b.username, _buddies.unreachedWhy(b)));
      } else {
        toast(context, b.state == 'yes' ? 'You and @${b.username} are friends' : 'Friend request sent to @${b.username}');
      }
    } catch (e) {
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), (keyboard > 0 ? keyboard : pad.bottom) + t.space(3)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.lenOf('30rem')),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(t.radius('xl')),
            child: ColoredBox(
              color: t.color('app-paper-2'),
              child: ListenableBuilder(
                listenable: Listenable.merge([_buddies, _me]),
                builder: (context, _) => Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(4), t.space(4), t.space(4)),
                  child: _me.username == null ? _username(t) : _search(t),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(Tokens t, String title, String about) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: pageText(t, t.fontSize('lg'), weight: 'semibold')),
        SizedBox(height: t.space(1)),
        Text(about, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4)),
        SizedBox(height: t.space(3)),
      ]);

  Widget? _problemLine(Tokens t) => _problem == null
      ? null
      : Padding(
          padding: EdgeInsets.only(top: t.space(2)),
          child: Text(_problem!, style: pageText(t, t.fontSize('sm'), color: t.danger)),
        );

  /// First, a username of your own: friends find you by it, and know a request is yours.
  Widget _username(Tokens t) => Column(key: const ValueKey('choose-username'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title(t, 'Choose your username', 'Friends find you by it, and it shows on the requests you send. You can change it later in Settings › Me.'),
        Row(children: [
          Expanded(
            child: GlacierInput(
              key: const ValueKey('username-field'),
              controller: _field,
              placeholder: '@yourname'.t,
              ariaLabel: 'Your username',
              autoFocus: true,
              autoCorrect: false,
              autoCapitalize: TextCapitalization.none,
              size: GlacierFieldSize.md,
              onSubmitted: (_) => _claim(),
            ),
          ),
          SizedBox(width: t.space(2)),
          _Button(key: const ValueKey('claim-username'), label: _busy ? 'Saving…' : 'Save', filled: true, onPress: _busy || Sms.followsPhone ? null : _claim),
        ]),
        ?_problemLine(t),
      ]);

  /// Then, looking someone up by theirs.
  Widget _search(Tokens t) {
    final name = _looked;
    final known = name == null ? null : _buddies.all.where((b) => b.username == name).firstOrNull;
    Widget? result;
    if (name != null) {
      final (sub, action) = switch (_found) {
        null => ('Looking…', null),
        BuddyLookup.nobody => ('Nobody has this username', null),
        BuddyLookup.you => ('That\'s you', null),
        // On another relay: nobody there is asked until Add is pressed, so nothing is known of them yet.
        BuddyLookup.elsewhere => switch (known?.state) {
            'yes' => ('Friends already', null),
            'asked' => ('Friend request sent', null),
            _ => ('On ${name.substring(name.indexOf('@') + 1)}: Add asks that relay', _Button(key: const ValueKey('add-found'), label: _busy ? 'Asking…' : 'Add', icon: Lucide.userPlus, filled: true, onPress: _busy ? null : () => _add(name))),
          },
        BuddyLookup.someone => switch (known?.state) {
            'yes' => ('Friends already', null),
            'asked' => ('Friend request sent', null),
            'invited' => ('Asked to be your friend', _Button(key: const ValueKey('add-found'), label: 'Accept', filled: true, onPress: _busy ? null : () => _add(name))),
            _ => (name.contains('@') ? 'On ${name.substring(name.indexOf('@') + 1)}' : 'On Uplink', _Button(key: const ValueKey('add-found'), label: _busy ? 'Asking…' : 'Add', icon: Lucide.userPlus, filled: true, onPress: _busy ? null : () => _add(name))),
          },
      };
      result = Padding(
        padding: EdgeInsets.only(top: t.space(3)),
        child: Row(children: [
          Avatar(people: [Person(address: '@$name', name: _found == BuddyLookup.someone ? name : null)], size: t.lenOf('2.5rem')),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(bareName(name), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium')),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            ]),
          ),
          if (action != null) ...[SizedBox(width: t.space(2)), action],
        ]),
      );
    }
    return Column(key: const ValueKey('find-friend'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _title(t, 'Add a friend', addFriendWords(_me.username ?? '')),
      GlacierSearchField(
        key: const ValueKey('find-friend-field'),
        controller: _field,
        placeholder: 'Search by @username'.t,
        size: GlacierFieldSize.md,
        autoFocus: true,
        autoCorrect: false,
        autoCapitalize: TextCapitalization.none,
        onValueChange: _typed,
      ),
      ?result,
      ?_problemLine(t),
    ]);
  }
}

/// What the add-friend drawer says above its field: how someone is found, here and on another relay.
String addFriendWords(String mine) => 'Type their username. For someone on another relay, add the relay after it: @name@their.relay. You\'re @$mine.';

/// What is said when someone was found on another relay but this app's relay could not pass the request to theirs.
/// What is said where a request to someone on another relay could not be passed on: [why] as the relay said it where
/// it said (their relay refused it, or is holding too much), else that the two relays don't talk; and that the request
/// is kept and sent again by itself for two weeks.
String addUnreachedWords(String username, [String? why]) => 'Found @$username, but ${why ?? 'your relay doesn\'t pass messages to theirs yet'}. The request is kept, and sent again by itself for two weeks.';

class _Button extends StatelessWidget {
  const _Button({super.key, required this.label, this.icon, this.filled = false, this.onPress});
  final String label;
  final LucideIcon? icon;
  final bool filled;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final off = onPress == null;
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      builder: (context, state) {
        final ground = filled ? t.color('app-ink') : t.color('app-paper-3');
        final ink = filled ? t.color('app-paper') : t.color('app-ink');
        return Opacity(
          opacity: off ? 0.5 : (state.pressed ? 0.8 : 1),
          child: Container(
            height: t.lenOf('2.5rem'),
            padding: EdgeInsets.symmetric(horizontal: t.space(4)),
            decoration: BoxDecoration(color: ground, borderRadius: BorderRadius.circular(t.lenOf('2.5rem'))),
            alignment: Alignment.center,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[AppIcon(icon!, size: 16, color: ink), SizedBox(width: t.space(1) + 2)],
              Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
            ]),
          ),
        );
      },
    );
  }
}
