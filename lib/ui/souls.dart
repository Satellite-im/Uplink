/// Souls, the app's points (Matt, 2026-11-19: "Build a new points system into the app called souls, right now they will
/// not have any use but I want to be able to give them out as rewards to people who submit bugs, display the points in
/// the top bar next to the feedback button with a flame icon next to them").
///
/// The relay keeps each person's souls (relay/lib/handles.dart); they are given from the admin page
/// (lib/ui/admin_page.dart) and told to the person as they are given (Me.souls, Me.gifts). Here: the count with its
/// flame in the list's top bar, and a sheet about them under it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../net/net.dart' show Net;
import 'common.dart';
import 'dialup/bevel.dart' show isBevelChrome;
import 'nav_bar.dart' show HoverTip;
import 'special_badges.dart';

/// The flame's colour: a soul's, a ghostly white-green (Matt, 2026-11-20: "make the fire for souls the white green
/// ghostly color like a soul"), pale and glowing on a dark look, a deeper mint on a light one so it reads on white.
Color soulsFlame(Tokens t) => t.isDark ? const Color(0xFFC9FFE6) : const Color(0xFF3DBF8F);

/// The souls' flame: its icon, washed in its own colour, with a soft glow behind it on a dark look.
class SoulFlame extends StatelessWidget {
  const SoulFlame({super.key, this.size = 16});
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final c = soulsFlame(t);
    final icon = AppIcon(Lucide.flame, size: size, strokeWidth: 2.1, color: c);
    if (!t.isDark) return icon;
    return Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
      Container(
        width: size * 0.55,
        height: size * 0.55,
        decoration: BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: c.withValues(alpha: 0.55), blurRadius: size * 0.6, spreadRadius: size * 0.05)]),
      ),
      icon,
    ]);
  }
}

/// 1234 as "1,234", 12 500 as "12.5k".
String soulsCount(int n) {
  if (n >= 10000) {
    final k = n / 1000;
    return '${k >= 100 ? k.round() : (k * 10).round() / 10}k'.replaceAll('.0k', 'k');
  }
  final s = '$n';
  return s.length > 3 ? '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}' : s;
}

/// The count of souls with its flame, round like the top bar's other buttons, beside Share feedback. A press says
/// what souls are. Souls given while the app is open are said as they come.
class SoulsChip extends StatefulWidget {
  const SoulsChip({super.key, this.side, this.onOpen});

  /// How tall it is: the bar's buttons' height, unless a strip says less (the Mac's title strip).
  final double? side;

  /// What a press does, where the sheet must open on a navigator below the chip (the Mac's title strip).
  final VoidCallback? onOpen;

  @override
  State<SoulsChip> createState() => _SoulsChipState();
}

class _SoulsChipState extends State<SoulsChip> {
  @override
  void initState() {
    super.initState();
    Me.instance.gifts.addListener(_gift);
    // Any that came before this was drawn (at the hello, as the app opened).
    WidgetsBinding.instance.addPostFrameCallback((_) => _gift());
  }

  @override
  void dispose() {
    Me.instance.gifts.removeListener(_gift);
    super.dispose();
  }

  /// Says a gift that came (souls, souls taken back, or a badge) in a toast, once: the gift is cleared as it is read.
  void _gift() {
    if (!mounted || Me.instance.gifts.value.isEmpty) return;
    final all = Me.instance.takeGifts();
    // Given while the app was away: a card that waits to be read, each with why (Matt, 2026-11-21: "notify a user when
    // they have recieved souls wiht a description for why like "bug bounty" etc it should notify them next time they
    // connect to the app (or immediatly if they're connected in real time)"). Given now: said as it comes.
    if (all.any((g) => g.away)) {
      unawaited(showSoulsGifts(context, all));
      return;
    }
    for (final g in all) {
      // Above the app's pages (the Mac's title strip) there may be nothing to toast on: then the count says it alone.
      try {
        toast(context, giftWords(g));
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Me.instance,
      builder: (context, _) {
        final n = Me.instance.souls;
        final label = '${soulsCount(n)} ${n == 1 ? 'soul' : 'souls'}';
        void open() => widget.onOpen != null ? widget.onOpen!() : showSouls(context);
        if (isBevelChrome(t)) {
          return IconTap(key: const ValueKey('souls'), icon: Lucide.flame, label: label, onPressed: open);
        }
        final side = widget.side ?? t.len('glacier-control-height-md');
        return HoverTip(
          message: label,
          below: true,
          end: true,
          child: GlacierPressable(
            key: const ValueKey('souls'),
            onPressed: open,
            semanticLabel: label,
            builder: (context, state) => GlacierFocusRing(
              visible: state.focused,
              radius: t.radius('full'),
              child: Container(
                height: side,
                constraints: BoxConstraints(minWidth: side),
                padding: EdgeInsets.symmetric(horizontal: t.space(3)),
                decoration: BoxDecoration(
                  color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
                  borderRadius: BorderRadius.circular(side / 2),
                  border: Border.all(color: t.color('app-rule')),
                ),
                alignment: Alignment.center,
                child: ExcludeSemantics(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const SoulFlame(size: 16),
                    SizedBox(width: t.space(1)),
                    Text(soulsCount(n), style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-ink'))),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A gift in a sentence: "You got 40 souls: Bug bounty".
String giftWords(SoulsGift g) {
  final badge = g.badge == null ? null : specialBadge(g.badge!);
  if (badge != null) return 'You were given the ${badge.name} badge';
  if (g.souls > 0) return 'You got ${soulsCount(g.souls)} ${g.souls == 1 ? 'soul' : 'souls'}${g.why.isEmpty ? '' : ': ${g.why}'}';
  return '${soulsCount(-g.souls)} ${g.souls == -1 ? 'soul was' : 'souls were'} taken back${g.why.isEmpty ? '' : ': ${g.why}'}';
}

/// A gift as a line of the card: "40 souls · Bug bounty".
String giftLine(SoulsGift g) {
  final badge = g.badge == null ? null : specialBadge(g.badge!);
  if (badge != null) return 'The ${badge.name} badge';
  final n = g.souls.abs();
  final what = '${g.souls < 0 ? '−' : ''}${soulsCount(n)} ${n == 1 ? 'soul' : 'souls'}${g.souls < 0 ? ' taken back' : ''}';
  return g.why.isEmpty ? what : '$what · ${g.why}';
}

/// What was given while the app was away, each with why, in a card that waits to be read; one press opens the souls.
Future<void> showSoulsGifts(BuildContext context, List<SoulsGift> gifts) {
  final t = context.tokens;
  final got = gifts.fold<int>(0, (a, g) => a + (g.souls > 0 ? g.souls : 0));
  final title = got > 0 ? 'You got ${soulsCount(got)} ${got == 1 ? 'soul' : 'souls'}' : (gifts.length == 1 ? giftWords(gifts.single) : 'Souls and badges');
  return showChoices(
    context,
    title: title,
    header: Padding(
      key: const ValueKey('souls-gifts'),
      padding: EdgeInsets.symmetric(horizontal: t.space(4), vertical: t.space(2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final g in gifts)
          Padding(
            padding: EdgeInsets.symmetric(vertical: t.space(1)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SoulFlame(size: 16),
              SizedBox(width: t.space(2)),
              Expanded(child: Text(giftLine(g), style: pageText(t, t.fontSize('md'), color: t.color('app-ink')))),
            ]),
          ),
      ]),
    ),
    choices: [Choice('See your souls', Lucide.flame, () => unawaited(showSouls(context)))],
  );
}

/// What souls are, how many this person has, and their badges. Over the whole app, as Share feedback's drawer is, not
/// in the list's column it was pressed in (GMFB-76, Matt, Android 0.12.48: "Viewing souls from the sidebar on mobile
/// limits the popup to the sidebar instead it should open over the whole app like the share feedback modal does").
Future<void> showSouls(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<void>(PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierColor: context.tokens.sheetScrim,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => const SoulsSheet(),
    transitionsBuilder: (context, a, _, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

/// The sheet [showSouls] slides up from the foot of the screen.
class SoulsSheet extends StatelessWidget {
  const SoulsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = MediaQuery.paddingOf(context);
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(3), 0, t.space(3), pad.bottom + t.space(3)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: t.lenOf('26rem')),
          child: Container(
            key: const ValueKey('souls-sheet'),
            padding: EdgeInsets.all(t.space(5)),
            decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('xl'))),
            child: ListenableBuilder(
              listenable: Me.instance,
              builder: (context, _) {
                final n = Me.instance.souls;
                final badges = specialBadgesOf(Me.instance.special);
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const SoulFlame(size: 30),
                    SizedBox(width: t.space(2)),
                    Text(soulsCount(n), style: pageText(t, t.fontSize('3xl'), weight: 'bold', color: t.color('app-ink'), height: 1.1)),
                    SizedBox(width: t.space(2)),
                    Text(n == 1 ? 'soul' : 'souls', style: pageText(t, t.fontSize('lg'), color: t.color('app-ink-2'))),
                  ]),
                  SizedBox(height: t.space(3)),
                  Text(
                    'Souls are Uplink\'s thank-you for helping make it better. Report a bug with Share feedback and say your username, and you may be given some.',
                    style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.45),
                  ),
                  SizedBox(height: t.space(2)),
                  // Since GMFB-39 some can be sent to a friend (lib/ui/souls_send.dart).
                  Text('Send some to a friend to say thanks: press + in a chat with them. There\'s nothing else to use them on yet.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4)),
                  // On a relay of one's own: whose count this is (GMFB-25).
                  if (soulsRelayWords(Net.instance.hubUrl) case final words?) ...[
                    SizedBox(height: t.space(2)),
                    Text(words, key: const ValueKey('souls-relay'), style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4)),
                  ],
                  if (badges.isNotEmpty) ...[
                    SizedBox(height: t.space(4)),
                    Text('YOUR BADGES', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'))),
                    SizedBox(height: t.space(1)),
                    // One shows beside your name, everywhere: the one pressed (Matt, 2026-11-20: "allow the user to
                    // choose one badge to showcase next to their names don't show them all").
                    Text(badges.length > 1 ? 'Tap one to show it beside your name.' : 'Shown beside your name.', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                    SizedBox(height: t.space(2)),
                    Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                      for (final b in badges)
                        Builder(builder: (context) {
                          final shown = SpecialBadges.instance.shownOf('', me: true)?.id == b.id;
                          return GlacierPressable(
                            key: ValueKey('showcase-${b.id}'),
                            onPressed: badges.length > 1 && !shown ? () => unawaited(Me.instance.setShowcase(b.id).catchError((_) {})) : null,
                            semanticLabel: shown ? '${b.name}, shown beside your name' : 'Show ${b.name} beside your name',
                            builder: (context, state) => Row(mainAxisSize: MainAxisSize.min, children: [
                              SpecialBadgeChip(badge: b, on: shown || badges.length == 1),
                              if (shown && badges.length > 1) ...[SizedBox(width: t.space(1)), AppIcon(Lucide.check, size: 14, color: t.color('app-ink-2'))],
                            ]),
                          );
                        }),
                    ]),
                  ],
                ]);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// On the Souls page while the app uses a relay other than Uplink's own (GMFB-25: "features that only exist on
/// gogho.st (marketplace, souls) fall back cleanly"): souls are counted by each relay apart, so the count shown is that
/// relay's, and the ones given on Uplink's are still there. Null on ours, where there is nothing to say.
String? soulsRelayWords(String hubUrl) {
  if (hubUrl == Net.defaultHub) return null;
  final u = Uri.tryParse(hubUrl);
  final host = u == null || u.host.isEmpty ? 'the relay you chose' : u.host;
  return 'Each relay counts souls apart. This is your count on $host, and souls go only between people on it. The ones you were given on Uplink\'s relay are still yours there, and show again when you go back to it. Bug bounties are given on Uplink\'s relay.';
}
