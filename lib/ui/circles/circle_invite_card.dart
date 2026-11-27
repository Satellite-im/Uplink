/// A circle offered to this device, shown the way the app shows a friend's invite into a space (RingCard,
/// lib/ui/voice_screen.dart): a banner over everything when it comes, and a card at the top of the Circles tab, each
/// with the circle's face (its colour, icon or picture, and name), who invited you, how many spaces it has, and Join and
/// Not now. Join opens the circle; Not now keeps it under Invites in the Circles tab until it is dismissed (Matt,
/// 2026-11-17: "Finish the missing pieces that went unfinished", of Circles: an invite used to join at once, unseen).
///
/// It draws in every look (lib/looks.dart) through the app's tokens, Dial-Up's bevels among them.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/lucide.g.dart';
import '../../circles/circles.dart';
import '../../invites/link_relay.dart';
import '../../net/net.dart' show Net;
import '../../net/relay_choice.dart' show relayHostForLinks, relayInUseWords;
import '../../circles/invite_word.dart';
import '../../invites/invite_relay.dart' show InviteRelayError;
import '../../kit/settings_kit.dart' show settingsHue;
import '../../kit/settings_type.dart';
import '../../voice/channels.dart';
import '../common.dart';
import '../conversations.dart' show ConversationsScreen;
import '../dialup/bevel.dart';
import '../shell.dart';
import 'circle_list.dart' show CircleSectionHeading;
import 'circle_screen.dart' show CircleRowFace, CircleScreen;

/// Who offered [i] and what it holds, in a line: "Maya Chen invited you · 3 spaces", or for a link opened from outside
/// the app "From a link you opened".
String circleInviteLine(CircleInvite i) {
  final n = i.spaceCount;
  return [
    if (i.from.isNotEmpty) '${i.from} invited you' else 'From a link you opened',
    if (n != null) '$n ${n == 1 ? 'space' : 'spaces'}',
  ].join(' · ');
}

/// Joins [i]'s circle and opens it in the list's place, as a press on its row would.
void joinCircleInvite(BuildContext context, CircleInvite i) {
  final shell = AppShell.maybeOf(context) ?? AppShellState.live;
  final c = Circles.instance.acceptInvite(i.seed);
  if (c == null) return;
  if (shell != null) {
    // On its welcome space, where it has one (lib/circles/welcome.dart).
    shell.openCircle(c, land: true);
  } else {
    push<void>(context, (_) => CircleScreen(seed: c.seed));
  }
}

/// Where the circle [link] is an invite to is on another relay than this app's (it names one, and it is not the one in
/// use), what to say in place of joining; null where it names none or this one (lib/invites/link_relay.dart).
String? circleLinkElsewhere(String link, {bool space = false}) {
  final net = Net.instance;
  final theirs = LinkRelay.elsewhere(link, mine: relayHostForLinks(net.hubUrl), isHere: (host) => net.homes?.isHere(host) ?? false);
  return theirs == null ? null : LinkRelay.elsewhereWords(theirs, mine: relayInUseWords(net.hubUrl).replaceFirst('Your own relay: ', 'your own relay, '), space: space);
}

/// A circle's link that came from outside the app, as [text] (the link alone, or words with it, as an invite's text or
/// a share has them): the circle opened where it is held already, else its invite raised, as a friend's is, and the
/// Circles tab shown where its card is. False where [text] holds no circle's link.
bool openCircleLink(AppShellState shell, String text) {
  final link = Circles.linkIn(text);
  if (link == null) {
    // A circle's invite word (gogho.st/c/bookclub; lib/circles/invite_word.dart): the relay is asked for the link it is.
    final word = inviteWordIn(text);
    if (word == null) return false;
    unawaited(_openWord(shell, word));
    return true;
  }
  // On another relay than this app's (the link says which, GMFB-25): said, in place of an invite to rooms nobody is in.
  final away = circleLinkElsewhere(link);
  if (away != null && Circles.instance.bySeed(Circle.fromLink(link)?.seed ?? '') == null) {
    toast(shell.context, away, tone: GlacierToastTone.danger);
    return true;
  }
  final got = Circles.instance.offerLink(link);
  if (got == null) return false;
  if (got.held != null) {
    shell.openCircle(got.held!);
  } else {
    showCirclesTab(shell);
  }
  return true;
}

/// Asks the relay which circle's link the invite word [word] stands for and opens it as a link; says so where the
/// relay can't be asked or no circle has the word.
Future<void> _openWord(AppShellState shell, String word) async {
  String? link;
  try {
    link = await InviteWords().resolve(word);
  } catch (e) {
    if (shell.mounted) toast(shell.context, 'Couldn\'t look up gogho.st/c/$word: ${e is InviteRelayError ? e.message : e}', tone: GlacierToastTone.danger);
    return;
  }
  if (!shell.mounted) return;
  if (link == null) return toast(shell.context, 'No circle has the invite word "$word".', tone: GlacierToastTone.danger);
  openCircleLink(shell, link);
}

/// The conversations list on its Circles tab, where waiting invites are at the top.
void showCirclesTab(AppShellState? shell) {
  shell?.home();
  ConversationsScreen.wantTab.value = ConversationsScreen.circlesTab;
}

/// The banner over everything for the newest invite that came since the app started: hidden while a group is calling
/// (that is the more pressing) and while the Circles tab, which has the invite's card, is on screen. A press on it shows
/// that tab.
class CircleInviteBanner extends StatelessWidget {
  const CircleInviteBanner({super.key, this.circles});

  /// For a test: the circles to show the invite of; the app's own otherwise.
  final Circles? circles;

  @override
  Widget build(BuildContext context) {
    final circles = this.circles ?? Circles.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([circles, Voice.instance, ConversationsScreen.shownTab]),
      builder: (context, _) {
        final i = circles.invite;
        final shell = AppShell.maybeOf(context);
        // The Circles tab itself on screen: its card says it already.
        final tabUp = ConversationsScreen.shownTab.value == ConversationsScreen.circlesTab && shell != null && !shell.settingsOpen && shell.openCircleSeed == null;
        if (i == null || Voice.instance.ringing != null || tabUp) return const SizedBox.shrink();
        final t = context.tokens;
        return Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(3), MediaQuery.paddingOf(context).top + t.space(2), t.space(3), 0),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: t.lenOf('30rem')),
              child: CircleInviteBannerCard(
                key: ValueKey('circle-invite-banner-${i.seed}'),
                invite: i,
                onOpen: () {
                  circles.seenInvite(i.seed);
                  showCirclesTab(AppShell.maybeOf(context) ?? AppShellState.live);
                },
                onLater: () => circles.laterInvite(i.seed),
                onJoin: () => joinCircleInvite(context, i),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The banner itself, drawn as a notification is: the circle's face, "Maya Chen invited you to Night Owls", a line of
/// how many spaces, Not now and Join. Dial-Up's is a raised silver panel with raised buttons.
class CircleInviteBannerCard extends StatelessWidget {
  const CircleInviteBannerCard({super.key, required this.invite, required this.onOpen, required this.onLater, required this.onJoin});
  final CircleInvite invite;
  final VoidCallback onOpen, onLater, onJoin;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    final c = invite.circle;
    final ink = d?.onChrome ?? t.color('app-ink');
    final soft = d?.inkSoft ?? t.color('app-ink-2');
    final title = invite.from.isNotEmpty ? '${invite.from} invited you to ${c.name}' : 'Join ${c.name}?';
    final n = invite.spaceCount;
    final line = ['A circle', if (n != null) '$n ${n == 1 ? 'space' : 'spaces'}', if (invite.from.isEmpty) 'from a link you opened'].join(' · ');
    // Who and which circle above, the two answers under them at the right, as a notification lays them out: the
    // whole sentence fits on a phone, which it did not beside the buttons.
    final row = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      GlacierPressable(
        key: const ValueKey('circle-invite-banner-open'),
        onPressed: onOpen,
        semanticLabel: '$title. $line. Show it in Circles',
        builder: (context, _) => Row(children: [
          CircleRowFace(circle: c, size: 40),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'bold', color: ink)),
              Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: soft)),
            ]),
          ),
        ]),
      ),
      SizedBox(height: t.space(2)),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        CircleInviteButton(key: const ValueKey('circle-invite-banner-later'), label: 'Not now', onPress: onLater),
        SizedBox(width: t.space(2)),
        CircleInviteButton(key: const ValueKey('circle-invite-banner-join'), label: 'Join', primary: true, onPress: onJoin),
      ]),
    ]);
    if (d != null) return Bevel(padding: EdgeInsets.all(t.space(3)), child: row);
    // A card standing over the page, as a notification does: the page's own paper with a shadow, the circle's colour
    // along its top edge.
    return Container(
      decoration: BoxDecoration(
        // Lifted off a dark page, where the page's own paper would sink into it.
        color: t.color(t.isDark ? 'app-paper-2' : 'app-paper'),
        borderRadius: BorderRadius.circular(t.radius('xl')),
        border: Border.all(color: t.color('app-rule'), width: t.len('glacier-hairline')),
        boxShadow: t.shadow('glacier-shadow-2'),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _HueStrip(hue: c.hue),
        Padding(padding: EdgeInsets.all(t.space(3)), child: row),
      ]),
    );
  }
}

/// What the Circles tab shows of [invites] at its top: each new one as a card ([CircleInviteCard]), then those put off
/// with Not now under Invites ([CircleInviteRow]), until each is joined or dismissed.
///
/// Where [circlesFollow] (circles and spaces of one's own are listed under them), a heading, Yours, says where the
/// invites end.
List<Widget> circleInviteRows(BuildContext context, List<CircleInvite> invites, {Circles? circles, bool circlesFollow = false}) {
  final cs = circles ?? Circles.instance;
  final now = [for (final i in invites) if (!i.later) i];
  final later = [for (final i in invites) if (i.later) i];
  return [
    for (final i in now)
      CircleInviteCard(
        key: ValueKey('circle-invite-card-${i.seed}'),
        invite: i,
        onJoin: () => joinCircleInvite(context, i),
        onLater: () => cs.laterInvite(i.seed),
      ),
    if (later.isNotEmpty) const CircleSectionHeading(key: ValueKey('circle-invites-heading'), name: 'Invites'),
    for (final i in later)
      CircleInviteRow(
        key: ValueKey('circle-invite-row-${i.seed}'),
        invite: i,
        onJoin: () => joinCircleInvite(context, i),
        onDismiss: () => cs.dismissInvite(i.seed),
      ),
    if (invites.isNotEmpty && circlesFollow) const CircleSectionHeading(key: ValueKey('circle-invites-yours'), name: 'Yours'),
  ];
}

/// A new invite at the top of the Circles tab: the circle's face large, its name, who invited you and how many spaces,
/// then Not now and Join across its foot. Card-shaped as the list's rows are; Dial-Up's a raised panel in the well.
class CircleInviteCard extends StatelessWidget {
  const CircleInviteCard({super.key, required this.invite, required this.onJoin, required this.onLater});
  final CircleInvite invite;
  final VoidCallback onJoin, onLater;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    final c = invite.circle;
    final ink = d?.onChrome ?? t.color('app-ink');
    final soft = d?.inkSoft ?? t.color('app-ink-3');
    final body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        CircleRowFace(circle: c, size: 52),
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            _Overline(hue: c.hue, text: 'Circle invite'),
            Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: ink)),
            Text(circleInviteLine(invite), maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: soft)),
          ]),
        ),
      ]),
      SizedBox(height: t.space(3)),
      Row(children: [
        Expanded(child: CircleInviteButton(key: ValueKey('circle-invite-later-${invite.seed}'), label: 'Not now', onPress: onLater, wide: true)),
        SizedBox(width: t.space(2)),
        Expanded(child: CircleInviteButton(key: ValueKey('circle-invite-join-${invite.seed}'), label: 'Join', primary: true, onPress: onJoin, wide: true)),
      ]),
    ]);
    return Semantics(
      container: true,
      label: '${c.name}, circle invite, ${circleInviteLine(invite)}',
      child: d != null
          ? Padding(padding: EdgeInsets.all(t.space(2)), child: Bevel(padding: EdgeInsets.all(t.space(3)), child: body))
          : Padding(
              padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
              child: Container(
                decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.lenOf('1rem'))),
                clipBehavior: Clip.antiAlias,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  _HueStrip(hue: c.hue),
                  Padding(padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(3), t.space(3), t.space(3)), child: body),
                ]),
              ),
            ),
    );
  }
}

/// An invite put off with Not now, under Invites: the circle's face, its name, who invited you, Join, and a cross that
/// dismisses it.
class CircleInviteRow extends StatelessWidget {
  const CircleInviteRow({super.key, required this.invite, required this.onJoin, required this.onDismiss});
  final CircleInvite invite;
  final VoidCallback onJoin, onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = invite.circle;
    final bevel = isBevelChrome(t);
    final row = Row(children: [
      CircleRowFace(circle: c, size: 36),
      SizedBox(width: t.space(3)),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'semibold', color: t.color('app-ink'))),
          Text(circleInviteLine(invite), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
        ]),
      ),
      SizedBox(width: t.space(2)),
      CircleInviteButton(key: ValueKey('circle-invite-row-join-${invite.seed}'), label: 'Join', primary: true, onPress: onJoin),
      IconTap(key: ValueKey('circle-invite-dismiss-${invite.seed}'), icon: Lucide.x, label: 'Dismiss the invite to ${c.name}', size: 18, onPressed: onDismiss),
    ]);
    // The list's own row shape: a card, or Dial-Up's transcript line with its rule under it.
    if (bevel) {
      return Container(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(1), t.space(2)),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.color('app-rule'), width: 1))),
        child: row,
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.lenOf('0.1875rem')),
      child: Container(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), t.space(2), t.space(1), t.space(2)),
        decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.lenOf('1rem'))),
        child: row,
      ),
    );
  }
}

/// Join or Not now. Join is the page's ink with paper words, Not now the paper's grey with ink words; both pills. In
/// Dial-Up both are raised silver buttons that sink while pressed, Join's words bold.
class CircleInviteButton extends StatelessWidget {
  const CircleInviteButton({super.key, required this.label, required this.onPress, this.primary = false, this.wide = false});
  final String label;
  final VoidCallback onPress;
  final bool primary;

  /// As wide as it is given, its words in the middle.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      builder: (context, state) {
        final pad = EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2));
        if (bevel) {
          final d = DialupColors.of(t);
          return Bevel(
            style: state.pressed ? BevelStyle.sunken : BevelStyle.raised,
            padding: pad,
            child: Text(label, textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), weight: primary ? 'bold' : 'regular', color: d.onChrome)),
          );
        }
        final fill = primary ? t.color(state.pressed ? 'app-ink-2' : 'app-ink') : t.color(state.pressed || state.hovered ? 'app-rule' : 'app-paper-3');
        return Container(
          padding: pad,
          alignment: wide ? Alignment.center : null,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(t.radius('full'))),
          child: Text(label, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color(primary ? 'app-paper' : 'app-ink'))),
        );
      },
    );
  }
}

/// A thin band in the circle's colour along a card's top: where a look settles every hue into its ink (Dial-Up), none.
class _HueStrip extends StatelessWidget {
  const _HueStrip({required this.hue});
  final String hue;

  @override
  Widget build(BuildContext context) => GlacierScope(
        attrs: {'hue': hue},
        child: Builder(builder: (context) => Container(height: 4, color: settingsHue(context.tokens))),
      );
}

/// "CIRCLE INVITE", small, in the circle's colour.
class _Overline extends StatelessWidget {
  const _Overline({required this.hue, required this.text});
  final String hue;
  final String text;

  @override
  Widget build(BuildContext context) => GlacierScope(
        attrs: {'hue': hue},
        child: Builder(builder: (context) {
          final t = context.tokens;
          final colour = isBevelChrome(t) ? DialupColors.of(t).inkSoft : settingsHue(t);
          return Text(text.toUpperCase(), maxLines: 1, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: colour, tracking: 0.6));
        }),
      );
}
