import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../sms.dart';
import 'common.dart';

/// The line under a friend request: what they said of themselves, or what the relay's directory said of the username
/// they gave where it hasn't said it is theirs (Buddy.check; found in review, 2026-11-23), which is all a request not
/// checked can be taken at.
String requestLine(Buddy r) => switch (r.check) {
      'ok' => r.name.isEmpty ? (r.bio.isEmpty ? 'Wants to be friends' : r.bio) : '@${r.username}${r.bio.isEmpty ? '' : ' · ${r.bio}'}',
      'nobody' => '@${r.username}, a username this relay doesn\'t know',
      'other' => '@${r.username}, a username the relay gives to someone else',
      _ => '@${r.username}, not checked with the relay yet',
    };

/// Says yes to the friend request [r], and says why not where it can't be (the relay can't check the username yet, or
/// it is someone else's: Buddies.accept).
Future<void> acceptRequest(BuildContext context, Buddy r, {Buddies? buddies}) async {
  try {
    await (buddies ?? Buddies.instance).accept(r);
  } catch (e) {
    if (context.mounted) toast(context, '$e', tone: GlacierToastTone.danger);
  }
}

/// Friend requests at the top of Contacts (Matt, 2026-11-16: "We need a way to add friends on the network by username
/// on the contacts page and see friend requests"): the requests waiting for an answer with Accept and Decline on each,
/// and the ones you sent. The friends themselves are listed On Uplink with the friends by number (Matt,
/// 2026-11-19: "remove the Friends by username section on the contacts page"); Remove friend is in their chat's settings
/// and on Me. Asking someone, and choosing a username of your own,
/// is the drawer the Add button beside the search opens (lib/ui/add_friend_drawer.dart). Buddies
/// (lib/friends/buddies.dart) does the asking.
class UsernameFriends extends StatefulWidget {
  const UsernameFriends({super.key, this.buddies, this.me});

  /// For a test or a picture; the app's own otherwise.
  final Buddies? buddies;
  final Me? me;

  @override
  State<UsernameFriends> createState() => _UsernameFriendsState();
}

class _UsernameFriendsState extends State<UsernameFriends> {
  Buddies get _buddies => widget.buddies ?? Buddies.instance;
  Me get _me => widget.me ?? Me.instance;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Listenable.merge([_buddies, _me]),
      builder: (context, _) {
        final b = _buddies;
        Widget heading(String words) => Padding(
              padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(4), t.space(4), t.space(1)),
              child: Text(words, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'))),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          // Who asked: an answer on each, right there.
          if (b.requests.isNotEmpty) ...[
            heading(b.requests.length == 1 ? 'Friend request' : 'Friend requests · ${b.requests.length}'),
            for (final r in b.requests)
              _Row(
                key: ValueKey('request-${r.username}'),
                name: r.shown,
                title: r.shown,
                sub: requestLine(r),
                trailing: Row(mainAxisSize: MainAxisSize.min, spacing: t.space(2), children: [
                  _Pill(key: ValueKey('decline-${r.username}'), label: 'Decline', onPress: () => b.decline(r)),
                  _Pill(key: ValueKey('accept-${r.username}'), label: 'Accept', filled: true, onPress: () => acceptRequest(context, r, buddies: b)),
                ]),
              ),
          ],
          // The ones sent: a press takes one back.
          if (b.asked.isNotEmpty) ...[
            heading('Waiting for them'),
            for (final a in b.asked)
              _Row(
                icon: Lucide.clock,
                title: a.shown,
                sub: 'Friend request sent',
                onPress: () => showChoices(context, title: 'Take back your request to @${a.username}?', choices: [
                  Choice('Take it back', Lucide.x, () => b.remove(a), danger: true),
                ]),
              ),
          ],
        ]);
      },
    );
  }
}

/// A line as the Contacts list draws its people: a face (or a mark), a name and a line under it, and what goes at the
/// end.
class _Row extends StatelessWidget {
  const _Row({super.key, required this.title, required this.sub, this.name, this.icon, this.onPress, this.trailing});
  final String title;
  final String sub;

  /// Whose initials the face shows; [icon] stands in where there is nobody.
  final String? name;
  final LucideIcon? icon;
  final VoidCallback? onPress;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final face = name != null
        ? Avatar(people: [Person(address: '@$name', name: name)], size: t.lenOf('2.5rem'))
        : Container(
            width: t.lenOf('2.5rem'),
            height: t.lenOf('2.5rem'),
            decoration: BoxDecoration(shape: BoxShape.circle, color: t.color('app-paper-3')),
            child: Center(child: AppIcon(icon ?? Lucide.userPlus, size: 18, color: t.color('app-ink'))),
          );
    final body = Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2) + 2),
      child: Row(children: [
        face,
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium')),
            Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
        if (trailing != null) ...[SizedBox(width: t.space(2)), trailing!],
      ]),
    );
    if (onPress == null) return body;
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: '$title, $sub',
      builder: (context, state) => ColoredBox(color: state.pressed || state.hovered ? t.color('app-paper-2') : const Color(0x00000000), child: body),
    );
  }
}

/// A small capsule: Accept (filled, the page's ink) or Decline (a ring).
class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.onPress, this.filled = false});
  final String label;
  final VoidCallback? onPress;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ink = filled ? t.color('app-paper') : t.color('app-ink');
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      builder: (context, state) => AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: onPress == null ? 0.5 : (state.pressed ? 0.8 : 1),
        child: Container(
          height: t.lenOf('2.1rem'),
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          decoration: ShapeDecoration(
            color: filled ? t.color('app-ink') : const Color(0x00000000),
            shape: StadiumBorder(side: filled ? BorderSide.none : BorderSide(color: t.color('app-rule'))),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: ink)),
          ]),
        ),
      ),
    );
  }
}
