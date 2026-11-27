import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/settings_type.dart';
import '../../ui/common.dart';
import '../../ui/computers.dart' show PairButton;
import '../platform.dart';

/// A computer that has just become the same you as its phone (it took on the phone's identity, lib/desktop/own_calls.dart)
/// and is in no Uplink account: signing in to the phone's, offered once, with "Not now" as plain (Matt, 2026-11-18: "On my
/// fold vs on my desktop, both with the same number linked but it seems i'm not logged in on desktop, there doesn't
/// seem to be a way to login on desktop"). Settings › Me offers it again any time. [phoneUsername] is the phone's
/// account's username where the phone has said it.
class AccountOffer extends StatelessWidget {
  const AccountOffer({super.key, required this.onSignIn, required this.onSkip, this.phoneUsername});
  final VoidCallback onSignIn;
  final VoidCallback onSkip;
  final String? phoneUsername;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final named = phoneUsername != null && phoneUsername!.isNotEmpty;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsetsDirectional.fromSTEB(t.space(6), t.space(8), t.space(6), t.space(6)),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  width: t.lenOf('4rem'),
                  height: t.lenOf('4rem'),
                  decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.lenOf('1rem')), border: Border.all(color: t.color('app-rule'))),
                  alignment: Alignment.center,
                  child: AppIcon(Lucide.keyRound, size: 28, color: t.color('app-ink-2')),
                ),
              ),
              SizedBox(height: t.space(5)),
              Text('Sign in to your Uplink account', style: pageText(t, t.fontSize('2xl'), weight: 'bold', color: t.color('app-ink'), height: 1.2)),
              SizedBox(height: t.space(2)),
              Text(
                named
                    ? 'Your phone is signed in as @$phoneUsername. Sign in here too, with its password or recovery words, and this $computerWord is listed under your account as the same you as your phone.'
                    : 'If you have an Uplink account, sign in here with its password or recovery words, and this $computerWord is listed under it as the same you as your phone. You can do it any time in Settings › Me.',
                style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.45),
              ),
              SizedBox(height: t.space(8)),
              PairButton(key: const ValueKey('account-offer-sign-in'), label: named ? 'Sign in as @$phoneUsername' : 'Sign in', icon: Lucide.keyRound, onPressed: onSignIn),
              SizedBox(height: t.space(3)),
              PairButton(key: const ValueKey('account-offer-skip'), label: 'Not now', icon: Lucide.arrowRight, quiet: true, onPressed: onSkip),
            ],
          ),
        ),
      ),
    );
  }
}

/// The step after a username on a computer of its own (Matt, 2026-11-18: "make setting up SMS and such and linking to
/// a phone an optional step all other processes should work without linking a phone"): texts from an Android phone,
/// offered once, with "Not now" as plain as "Link my phone". Settings › Your phone offers it again any time.
class LinkOffer extends StatelessWidget {
  const LinkOffer({super.key, required this.onLink, required this.onSkip});
  final VoidCallback onLink;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsetsDirectional.fromSTEB(t.space(6), t.space(8), t.space(6), t.space(6)),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Container(
                  width: t.lenOf('4rem'),
                  height: t.lenOf('4rem'),
                  decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.lenOf('1rem')), border: Border.all(color: t.color('app-rule'))),
                  alignment: Alignment.center,
                  child: AppIcon(LucideMore.smartphone, size: 28, color: t.color('app-ink-2')),
                ),
              ),
              SizedBox(height: t.space(5)),
              Text('Texts from your phone? (optional)', style: pageText(t, t.fontSize('2xl'), weight: 'bold', color: t.color('app-ink'), height: 1.2)),
              SizedBox(height: t.space(2)),
              Text(
                'If you text from an Android phone with Uplink on it, this $computerWord can show those texts and send through it. Everything else, friends, circles, Telegram and Signal, works without a phone. You can link one any time in Settings › Your phone.',
                style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'), height: 1.45),
              ),
              SizedBox(height: t.space(8)),
              PairButton(key: const ValueKey('link-offer-link'), label: 'Link my Android phone', icon: LucideMore.qrCode, onPressed: onLink),
              SizedBox(height: t.space(3)),
              PairButton(key: const ValueKey('link-offer-skip'), label: 'Not now', icon: Lucide.arrowRight, quiet: true, onPressed: onSkip),
            ],
          ),
        ),
      ),
    );
  }
}

/// A phone has just been linked to a computer that was on its own: said for the moment before the app opens again on
/// it (restartApp).
class LinkRestarting extends StatelessWidget {
  const LinkRestarting({super.key, required this.phone});
  final String phone;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ColoredBox(
      color: t.color('glacier-bg'),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const GhostSpinner(size: 24),
          SizedBox(height: t.space(4)),
          Text('Linked with $phone', style: pageText(t, t.fontSize('lg'), weight: 'semibold', color: t.color('app-ink'))),
          SizedBox(height: t.space(1)),
          Text('Opening Uplink again with your texts…', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
        ]),
      ),
    );
  }
}
