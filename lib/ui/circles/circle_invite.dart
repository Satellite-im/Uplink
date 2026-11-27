/// Inviting people into a circle, the way a space is (lib/ui/space_invite.dart): friends on Uplink chosen and
/// sent the circle at once (Circles.share: it reaches their phone as an invite), and anyone else by a text already
/// written, the link copied or shared, or its QR code shown for a camera across the table.
library;

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../circles/circles.dart';
import '../../circles/invite_word.dart';
import '../../desktop/ui/qr.dart';
import '../../friends/buddies.dart';
import '../../kit/settings_type.dart';
import '../../sms.dart';
import '../add_friend_drawer.dart';
import '../common.dart';
import '../dialup/bevel.dart';
import '../drawer_head.dart';
import '../invite_people.dart' show showCircleInvitePeople;
import '../ripple_avatar.dart';
import 'circle_face.dart';

/// The words an invite to [c] goes with, by a text or the share sheet.
String circleInviteWords(Circle c) => 'Join my circle ${c.name} on Uplink: ${circleInviteLink(c)}';

/// The link to share for [c]: its invite word's (gogho.st/c/…) where it has one, else its own long link.
String circleInviteLink(Circle c) => c.inviteWord == null ? c.link : inviteWordLink(c.inviteWord!);

/// Raises the invite drawer for [c] over everything: the one a space has (lib/ui/invite_people.dart), friends sent the
/// circle in the app, contacts texted its link with a copy waiting on the relay, the link and its QR code. Circles
/// and spaces invite the same way (Matt, 2026-11-17: "when adding people to the space we should have a suggested list
/// of our contacts to add"). [send], [compose] and [buddies] are for a test; the app's own otherwise.
Future<void> showCircleInvite(
  BuildContext context,
  Circle c, {
  Future<List<Buddy>> Function(Circle circle, List<Buddy> friends)? send,
  void Function(String words)? compose,
  Buddies? buddies,
}) =>
    showCircleInvitePeople(context, c, send: send, compose: compose, buddies: buddies);

/// The sheet: the circle's face and name, friends to choose and Send invites, then the ways to reach anyone else.
class CircleInviteSheet extends StatefulWidget {
  const CircleInviteSheet({super.key, required this.circle, required this.send, required this.compose, required this.buddies, this.qr = false});
  final Circle circle;

  /// Sends the circle to the friends chosen; gives back those it could not reach.
  final Future<List<Buddy>> Function(Circle circle, List<Buddy> friends) send;
  final void Function(String words) compose;
  final Buddies buddies;

  /// Opened with the QR code showing (a picture of it).
  final bool qr;

  @override
  State<CircleInviteSheet> createState() => _CircleInviteSheetState();
}

class _CircleInviteSheetState extends State<CircleInviteSheet> {
  final Set<String> _chosen = {};
  bool _sending = false;
  late bool _qr = widget.qr;

  /// Sends the circle to the friends ticked and says who was invited and who couldn't be reached. The sheet closes
  /// once at least one was reached, and stays open to try again where none was.
  Future<void> _send(List<Buddy> friends) async {
    final chosen = [for (final f in friends) if (_chosen.contains(f.id)) f];
    if (chosen.isEmpty || _sending) return;
    setState(() => _sending = true);
    final nav = Navigator.of(context);
    final shown = context;
    try {
      final missed = await widget.send(widget.circle, chosen);
      if (!shown.mounted) return;
      final reached = [for (final f in chosen) if (!missed.any((m) => m.id == f.id)) f];
      final away = missed.map((f) => f.shown).join(', ');
      if (reached.isEmpty) {
        toast(shown, 'Couldn\'t reach $away. Try again in a moment, or text them the link.', tone: GlacierToastTone.danger);
        setState(() => _sending = false);
        return;
      }
      final invited = reached.length == 1 ? 'Invited ${reached.first.shown}' : 'Invited ${reached.length}';
      toast(shown, missed.isEmpty ? invited : '$invited; couldn\'t reach $away', tone: missed.isEmpty ? GlacierToastTone.neutral : GlacierToastTone.warning);
      nav.pop();
    } catch (e) {
      if (shown.mounted) toast(shown, 'Couldn\'t send the invites: $e', tone: GlacierToastTone.danger);
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    final c = widget.circle;
    final bevel = isBevelChrome(t);
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
                  listenable: widget.buddies,
                  builder: (context, _) {
                    final friends = widget.buddies.roomFriends;
                    final n = _chosen.length;
                    return SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // The drawers' one head (lib/ui/drawer_head.dart), as Members and the space's invite drawer have it.
                        Padding(
                          padding: EdgeInsets.only(bottom: t.space(1)),
                          child: DrawerHead(title: 'Invite people', subtitle: c.name, face: CircleFace.of(c, size: 40), note: 'Whoever has the link is in the circle.'),
                        ),
                        _Heading('Friends on Uplink'),
                        if (friends.isEmpty) ...[
                          Padding(
                            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(1)),
                            child: Text('No friends here yet. Add someone by their username and you can invite them in one press.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
                          ),
                          _Row(
                            icon: Lucide.userPlus,
                            label: 'Add a friend',
                            onPress: () {
                              final root = Navigator.of(context, rootNavigator: true).context;
                              Navigator.of(context).pop();
                              unawaited(showAddFriendDrawer(root));
                            },
                          ),
                        ] else ...[
                          for (final f in friends)
                            CircleFriendRow(
                              key: ValueKey('circle-invite-friend-${f.id}'),
                              friend: f,
                              chosen: _chosen.contains(f.id),
                              onPress: () => setState(() => _chosen.contains(f.id) ? _chosen.remove(f.id) : _chosen.add(f.id)),
                            ),
                          Padding(
                            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(1)),
                            child: GlacierPressable(
                              key: const ValueKey('circle-invite-send'),
                              onPressed: n == 0 || _sending ? null : () => _send(friends),
                              semanticLabel: n == 1 ? 'Send invite' : 'Send invites',
                              builder: (context, state) {
                                // Nobody chosen yet: the kit's quiet disabled look (soft words on the paper's grey), not
                                // the dark button faded, which read as on but muddy on a dark page.
                                final off = n == 0;
                                final ink = bevel ? (off ? DialupColors.of(t).disabled : DialupColors.of(t).onChrome) : t.color(off ? 'app-ink-3' : 'app-paper');
                                final words = Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  AppIcon(Lucide.send, size: 16, wash: false, color: ink),
                                  SizedBox(width: t.space(2)),
                                  Text(n == 0 ? 'Send invites' : n == 1 ? 'Send invite' : 'Send $n invites', style: pageText(t, t.fontSize('md'), weight: 'bold', color: ink)),
                                ]);
                                // Dial-Up: a raised button that sinks while pressed.
                                if (bevel) return Bevel(style: state.pressed && !off ? BevelStyle.sunken : BevelStyle.raised, padding: EdgeInsets.symmetric(vertical: t.space(3)), child: words);
                                return Container(
                                  padding: EdgeInsets.symmetric(vertical: t.space(3)),
                                  decoration: BoxDecoration(color: t.color(off ? 'app-paper-3' : (state.pressed ? 'app-ink-2' : 'app-ink')), borderRadius: BorderRadius.circular(t.radius('full'))),
                                  child: words,
                                );
                              },
                            ),
                          ),
                        ],
                        SizedBox(height: t.space(2)),
                        Container(height: t.len('glacier-hairline'), color: t.color('app-rule')),
                        _Heading('Anyone else'),
                        _Row(
                          icon: Lucide.messageSquare,
                          label: 'Text an invite',
                          hint: 'To anyone in your contacts, by text',
                          onPress: () {
                            Navigator.of(context).pop();
                            widget.compose(circleInviteWords(c));
                          },
                        ),
                        _Row(
                          key: const ValueKey('circle-invite-copy'),
                          icon: Lucide.link,
                          label: 'Copy invite link',
                          hint: 'Anyone with it can join, from the app',
                          onPress: () {
                            final root = Navigator.of(context, rootNavigator: true).context;
                            Navigator.of(context).pop();
                            Clipboard.setData(ClipboardData(text: circleInviteLink(c)));
                            toast(root, 'Invite link copied. Anyone with it can join ${c.name}.');
                          },
                        ),
                        _Row(
                          icon: Lucide.share2,
                          label: 'Share link…',
                          hint: 'Send it with another app',
                          onPress: () {
                            Navigator.of(context).pop();
                            unawaited(Sms.instance.shareText(c.name, circleInviteWords(c)).catchError((_) {}));
                          },
                        ),
                        _Row(
                          key: const ValueKey('circle-invite-qr'),
                          icon: LucideMore.qrCode,
                          label: _qr ? 'Hide the QR code' : 'Show a QR code',
                          hint: 'For someone beside you to scan',
                          onPress: () => setState(() => _qr = !_qr),
                        ),
                        if (_qr)
                          Padding(
                            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(3)),
                            child: Center(
                              child: Semantics(
                                label: 'The invite link to ${c.name}, as a QR code',
                                child: ExcludeSemantics(child: QrView(data: c.link, size: 200, radius: bevel ? 0 : 14)),
                              ),
                            ),
                          ),
                        SizedBox(height: t.space(2)),
                      ]),
                    );
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

/// A small heading over a part of the sheet.
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

/// A friend to choose: their face, name and @username, and a check while chosen. The new circle's page uses it too.
class CircleFriendRow extends StatelessWidget {
  const CircleFriendRow({super.key, required this.friend, required this.chosen, required this.onPress});
  final Buddy friend;
  final bool chosen;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final size = t.lenOf('1.5rem');
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: '${friend.shown}${chosen ? ', chosen' : ''}',
      builder: (context, state) => ColoredBox(
        color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
          child: Row(children: [
            RippleAvatar(name: friend.shown, level: 0, size: 40),
            SizedBox(width: t.space(3)),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(friend.shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
                if (friend.name.isNotEmpty) Text('@${friend.username}', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              ]),
            ),
            SizedBox(width: t.space(2)),
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: chosen ? t.color('app-ink') : const Color(0x00000000),
                border: Border.all(color: t.color(chosen ? 'app-ink' : 'app-ink-3'), width: 2),
              ),
              alignment: Alignment.center,
              child: chosen ? AppIcon(Lucide.check, size: 14, strokeWidth: 3, wash: false, color: t.color('app-paper')) : null,
            ),
          ]),
        ),
      ),
    );
  }
}

/// One of the ways to reach anyone else: an icon, what it does, and a line under it.
class _Row extends StatelessWidget {
  const _Row({super.key, required this.icon, required this.label, this.hint, required this.onPress});
  final LucideIcon icon;
  final String label;
  final String? hint;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      builder: (context, state) => ColoredBox(
        color: state.pressed ? t.color('app-paper-3') : const Color(0x00000000),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(3)),
          child: Row(children: [
            AppIcon(icon, size: 20, color: t.color('app-ink')),
            SizedBox(width: t.space(3)),
            Flexible(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(label, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
                if (hint != null) Text(hint!, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
