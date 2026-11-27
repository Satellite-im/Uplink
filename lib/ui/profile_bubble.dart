/// Your own face at the rail's foot, just above Settings (Matt, 2026-11-25: "in the bottom of the navigation rail just
/// above the settings add a profile bubble with our indicator status (online afk etc) and have a popup for quickly
/// managing a few profile settings within showing our profile card ... and have a button at the bottom to open all
/// profile settings", with a picture of Discord's). The bubble is the picture with the mark of how you chose to be
/// shown (Me.presenceMode) at its shoulder; a press hangs a card beside it: the banner, the face, the name and
/// username, the status to write in place, how you are shown, your picture, your souls, your username to copy, and at
/// its foot the way to the whole profile (lib/ui/profile.dart).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/settings_type.dart';
import '../me/me.dart';
import '../packs/pack_paint.dart';
import '../sms.dart' show Sms;
import 'circles/circle_picture.dart' show pickProfilePicture;
import 'common.dart';
import '../me/cosmetics.dart';
import 'cosmetics_picker.dart' show chooseBannerPicture, wearBanner;
import 'cosmetics_ui.dart';
import 'special_badges.dart';
import 'nav_bar.dart' show HoverTip;
import 'nav_rail.dart';
import 'plugins_page/plugin_art.dart' show PluginHues;
import 'profile.dart' show ModeMark;
import 'profile_card.dart' show ProfileFace;
import 'souls.dart' show showSouls;
import 'verified_badge.dart';
import '../l10n/words.dart';

/// What each way of being shown is called, in the order they are offered.
const profileModes = [('online', 'Online'), ('away', 'Away'), ('busy', 'Busy'), ('invisible', 'Invisible')];

/// [mode]'s word.
String profileModeLabel(String mode) => profileModes.firstWhere((m) => m.$1 == mode, orElse: () => profileModes.first).$2;

/// The bubble in the rail. [onOpenProfile] opens the whole profile; [shown] while that is the page open.
class ProfileBubble extends StatefulWidget {
  const ProfileBubble({super.key, required this.onOpenProfile, this.shown = false});
  final VoidCallback onOpenProfile;
  final bool shown;

  @override
  State<ProfileBubble> createState() => _ProfileBubbleState();
}

class _ProfileBubbleState extends State<ProfileBubble> {
  bool _open = false;

  /// Something of the card's own is open over it (the badges to choose from): a press there is not a press outside
  /// the card.
  final _held = ValueNotifier(false);

  void _set(bool open) {
    if (!open && _held.value) return;
    if (mounted && open != _open) setState(() => _open = open);
  }

  @override
  void dispose() {
    _held.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final ring = t.len('app-rail-ring');
    final screen = MediaQuery.sizeOf(context);
    // As wide as Discord's, less where the window has no room beside the rail (a phone).
    final width = math.max(t.lenOf('15rem'), math.min(t.lenOf('20rem'), screen.width - NavRail.width(t) - t.space(6)));
    return ListenableBuilder(
      listenable: Me.instance,
      builder: (context, _) {
        final me = Me.instance;
        final mode = me.presenceMode;
        final label = 'Your profile, ${profileModeLabel(mode)}';
        return GlacierPopover(
          open: _open,
          onOpenChange: _set,
          placement: Placement.rightEnd,
          ariaLabel: 'Your profile',
          minWidth: width,
          maxWidth: width,
          padding: EdgeInsets.zero,
          trigger: (context, trigger) => HoverTip(
            message: _open ? '' : (me.shownName.isEmpty ? 'Your profile' : me.shownName),
            beside: true,
            child: GlacierPressable(
              onPressed: trigger.toggle,
              semanticLabel: label,
              builder: (context, state) {
                final lit = _open || widget.shown;
                return SizedBox(
                  width: ring,
                  height: ring,
                  child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
                    GlacierFocusRing(
                      visible: state.focused,
                      offset: 3,
                      color: t.color('app-ink'),
                      child: AnimatedScale(
                        scale: state.pressed ? 0.94 : (state.hovered && !lit ? 1.05 : 1),
                        duration: t.duration('glacier-duration-fast'),
                        curve: t.curve('glacier-ease-out'),
                        child: Container(
                          // A line of ink round it while its card or the profile is open, as the ring shown is filled.
                          // Not round a resource pack's orb, which is its own ring (lib/ui/dialup/parts.dart's PackOrb),
                          // until it is the one open.
                          foregroundDecoration: !lit && packOf(t)?['other/minimap_orb_frame_small'] != null
                              ? null
                              : BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: t.color(lit ? 'app-ink' : 'glacier-border-strong'), width: lit ? 2 : t.len('app-line')),
                                ),
                          child: ProfileFace(key: const ValueKey('profile-bubble-face'), name: me.shownName, picture: me.pictureOwn, size: ring),
                        ),
                      ),
                    ),
                    PositionedDirectional(end: -2, bottom: -2, child: ModeMark(key: ValueKey('profile-bubble-mode-$mode'), mode: mode, size: math.max(14, ring * 0.36))),
                  ]),
                );
              },
            ),
          ),
          child: _open
              ? ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: math.max(t.lenOf('12rem'), screen.height - t.space(8))),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(t.radius('lg')),
                    child: SingleChildScrollView(
                      child: _Peek(
                        host: context,
                        held: _held,
                        close: () => _set(false),
                        openProfile: () {
                          _set(false);
                          widget.onOpenProfile();
                        },
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
  }
}

/// The card hung beside the bubble. [host] is the bubble's own place in the app, for what opens from here (a page, a
/// sheet, a toast): the card itself is drawn over everything and goes when it closes.
class _Peek extends StatefulWidget {
  const _Peek({required this.host, required this.held, required this.close, required this.openProfile});

  /// True while the badges are open over the card ([_ProfileBubbleState._held]).
  final ValueNotifier<bool> held;
  final BuildContext host;
  final VoidCallback close;
  final VoidCallback openProfile;

  @override
  State<_Peek> createState() => _PeekState();
}

class _PeekState extends State<_Peek> {
  late final _status = TextEditingController(text: Me.instance.status);

  /// The four ways of being shown, opened out under the one chosen.
  bool _modes = false;

  /// The banners to choose from, opened out under the card's head (Matt, 2026-11-25: "I need a setting to change my
  /// banner").
  bool _banners = false;

  /// The badges to choose the one shown beside your name from, hung from the one shown (Matt, 2026-11-25: "add the
  /// ability to pick your badge (show it next to your name) and show a popover when picking the badge").
  bool _badges = false;

  void _setBadges(bool open) {
    widget.held.value = open;
    if (mounted && open != _badges) setState(() => _badges = open);
  }

  /// Keeps the status written, and tells friends; nothing where it is as it was. Asked at Enter and as the card goes.
  void _saveStatus() {
    final me = Me.instance;
    final words = _status.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (words == me.status) return;
    me.setProfile(status: words);
    Buddies.instance.shareProfile();
  }

  @override
  void dispose() {
    // After this frame: the card goes while the rail is being built, and saving tells the rail to build again.
    final words = _status.text;
    scheduleMicrotask(() {
      final me = Me.instance;
      final tidy = words.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (tidy == me.status) return;
      me.setProfile(status: tidy);
      Buddies.instance.shareProfile();
    });
    _status.dispose();
    super.dispose();
  }

  Future<void> _choosePicture() async {
    final host = widget.host;
    widget.close();
    final picked = await pickProfilePicture(host);
    if (picked == null) return;
    Me.instance.setPicture(picked);
    Buddies.instance.shareProfile();
    if (host.mounted) toast(host, 'Your picture is set. Your friends will see it.');
  }

  void _copyUsername() {
    final name = '@${Me.instance.username}';
    unawaited(Clipboard.setData(ClipboardData(text: name)));
    widget.close();
    if (widget.host.mounted) toast(widget.host, 'Copied $name');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ListenableBuilder(
      listenable: Listenable.merge([Me.instance, SpecialBadges.instance]),
      builder: (context, _) {
        final me = Me.instance;
        final mode = me.presenceMode;
        final dress = me.cosmetics;
        final name = me.shownName;
        final face = t.lenOf('4.5rem');
        final ringW = t.lenOf('0.3125rem');
        final bannerH = t.lenOf('4.75rem');
        final ground = t.color('glacier-bg');
        final hues = PluginHues.of(t, hueFor(me.username ?? (name.isEmpty ? 'me' : name)));
        final rule = Container(height: t.len('app-line'), margin: EdgeInsets.symmetric(horizontal: t.space(3)), color: t.color('app-rule'));
        Widget group(List<Widget> rows) => Container(
              margin: EdgeInsets.only(top: t.space(3)),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('lg'))),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, row) in rows.indexed) ...[if (i > 0) rule, row],
              ]),
            );
        final body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: bannerH + face / 2 + ringW,
            child: Stack(clipBehavior: Clip.none, children: [
              PositionedDirectional(
                key: const ValueKey('profile-peek-banner'),
                start: 0,
                end: 0,
                top: 0,
                height: bannerH,
                child: CosmeticBanner(
                  id: dress.banner,
                  picture: me.banner,
                  fallback: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: [hues.start, hues.end]))),
                ),
              ),
              PositionedDirectional(
                end: t.space(2),
                top: t.space(2),
                child: GlacierPressable(
                  key: const ValueKey('profile-peek-banner-change'),
                  onPressed: () => setState(() => _banners = !_banners),
                  semanticLabel: 'Change your banner',
                  builder: (context, state) => Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: const Color(0xFF000000).withValues(alpha: state.hovered || state.pressed || _banners ? 0.62 : 0.4), shape: BoxShape.circle),
                    child: AppIcon(_banners ? Lucide.x : Lucide.pencil, size: 14, color: const Color(0xFFFFFFFF), wash: false),
                  ),
                ),
              ),
              PositionedDirectional(
                start: t.space(4) - ringW,
                top: bannerH - face / 2 - ringW,
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    padding: EdgeInsets.all(ringW),
                    decoration: BoxDecoration(color: ground, shape: BoxShape.circle),
                    child: DressedFace(size: face, cosmetics: dress, face: ProfileFace(name: name, picture: me.pictureOwn, size: face)),
                  ),
                  PositionedDirectional(end: ringW - 2, bottom: ringW - 2, child: ModeMark(key: ValueKey('profile-peek-mark-$mode'), mode: mode, size: 22)),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(4)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Flexible(
                  child: NameEffectText(name.isEmpty ? 'You' : name, key: const ValueKey('profile-peek-name'), id: dress.name, style: pageText(t, t.fontSize('xl'), weight: 'bold', color: t.color('app-ink'))),
                ),
                if (me.username != null) VerifiedBadge(id: '', username: me.username!, me: true, size: 20, special: false),
                if (specialBadgesOf(me.special).isNotEmpty) _badgePick(t),
              ]),
              Text(
                me.username == null ? 'No username yet' : '@${me.username}',
                key: const ValueKey('profile-peek-username'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')),
              ),
              if (_banners) _bannerPick(t),
              SizedBox(height: t.space(3)),
              // The status, written where it is read: kept at Enter, and as the card goes.
              GlacierInput(
                key: const ValueKey('profile-peek-status'),
                controller: _status,
                placeholder: 'What are you up to?'.t,
                ariaLabel: 'Status',
                size: GlacierFieldSize.md,
                maxLength: Me.statusMost,
                onSubmitted: (_) => _saveStatus(),
                onBlur: _saveStatus,
              ),
              group([
                _PeekRow(
                  key: const ValueKey('profile-peek-mode'),
                  icon: Center(child: ModeMark(mode: mode)),
                  label: profileModeLabel(mode),
                  end: AppIcon(_modes ? Lucide.chevronDown : Lucide.chevronRight, size: 16, color: t.color('app-ink-3')),
                  onPress: () => setState(() => _modes = !_modes),
                ),
                if (_modes)
                  for (final (id, label) in profileModes)
                    if (id != mode)
                      _PeekRow(
                        key: ValueKey('profile-peek-mode-$id'),
                        icon: Center(child: ModeMark(mode: id)),
                        label: label,
                        onPress: () {
                          me.setPresenceMode(id);
                          setState(() => _modes = false);
                        },
                      ),
              ]),
              group([
                // Not in a browser, which can't choose a picture yet (Sms.browser).
                if (!Sms.browser)
                  _PeekRow(
                    key: const ValueKey('profile-peek-picture'),
                    icon: AppIcon(Lucide.image, size: 18, color: t.color('app-ink-2')),
                    label: me.picture.isEmpty ? 'Choose a picture' : 'Change your picture',
                    onPress: () => unawaited(_choosePicture()),
                  ),
                _PeekRow(
                  key: const ValueKey('profile-peek-souls'),
                  icon: AppIcon(Lucide.flame, size: 18, color: t.color('app-ink-2')),
                  label: '${me.souls} ${me.souls == 1 ? 'soul' : 'souls'}',
                  end: AppIcon(Lucide.chevronRight, size: 16, color: t.color('app-ink-3')),
                  onPress: () {
                    final host = widget.host;
                    widget.close();
                    unawaited(showSouls(host));
                  },
                ),
                if (me.username != null)
                  _PeekRow(
                    key: const ValueKey('profile-peek-copy'),
                    icon: AppIcon(Lucide.copy, size: 18, color: t.color('app-ink-2')),
                    label: 'Copy @${me.username}',
                    onPress: _copyUsername,
                  ),
              ]),
              SizedBox(height: t.space(3)),
              // The whole profile: the username, the picture, what the profile wears, the account key.
              GlacierPressable(
                key: const ValueKey('profile-peek-all'),
                onPressed: widget.openProfile,
                semanticLabel: 'All profile settings',
                builder: (context, state) => GlacierFocusRing(
                  visible: state.focused,
                  child: Container(
                    height: t.lenOf('2.5rem'),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: t.color('app-ink').withValues(alpha: state.hovered || state.pressed ? 0.88 : 1), borderRadius: BorderRadius.circular(t.radius('lg'))),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      AppIcon(Lucide.pencil, size: 16, color: t.color('app-paper')),
                      SizedBox(width: t.space(2)),
                      Flexible(child: Text('All profile settings', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-paper')))),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ]);
        if (dress.effect.isEmpty) return body;
        return Stack(children: [body, Positioned.fill(child: ProfileEffectLayer(id: dress.effect))]);
      },
    );
  }
}

extension on _PeekState {
  /// The banners there are, None first, each as it would look: a press wears it, and the one worn is ringed.
  Widget _bannerPick(Tokens t) {
    final me = Me.instance;
    // A picture of your own as the banner (GMFB-34): while it is worn none of the ready-made ones is ringed.
    final mine = me.banner;
    final worn = mine.isNotEmpty ? null : me.cosmetics.banner;
    final hues = PluginHues.of(t, hueFor(me.username ?? (me.shownName.isEmpty ? 'me' : me.shownName)));
    return Padding(
      key: const ValueKey('profile-peek-banners'),
      padding: EdgeInsets.only(top: t.space(3)),
      child: LayoutBuilder(builder: (context, box) {
        final gap = t.space(2);
        final w = (box.maxWidth - gap * 2) / 3;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          // Not in a browser, which can't choose a picture yet (Sms.browser).
          if (!Sms.browser)
            GlacierPressable(
              key: const ValueKey('profile-peek-banner-own'),
              onPressed: () {
                final host = widget.host;
                widget.close();
                unawaited(chooseBannerPicture(host));
              },
              semanticLabel: mine.isEmpty ? 'A picture of your own as the banner' : 'Change your banner picture',
              selected: mine.isNotEmpty,
              builder: (context, state) => Container(
                width: w.floorToDouble(),
                height: 34,
                clipBehavior: Clip.antiAlias,
                alignment: Alignment.center,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(t.radius('md')),
                  border: Border.all(color: t.color(mine.isNotEmpty ? 'app-ink' : 'app-rule'), width: mine.isNotEmpty ? 2 : 1),
                ),
                decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('md'))),
                child: mine.isEmpty ? AppIcon(Lucide.image, size: 18, color: t.color('app-ink-2')) : CosmeticBanner(id: '', picture: mine, fallback: const SizedBox.shrink()),
              ),
            ),
          for (final id in ['', for (final b in CosmeticCatalog.of(CosmeticKind.banner)) b.id])
            GlacierPressable(
              key: ValueKey('profile-peek-banner-${id.isEmpty ? 'none' : id}'),
              onPressed: () => wearBanner(id),
              semanticLabel: id.isEmpty ? 'No banner' : '${CosmeticCatalog.find(CosmeticKind.banner, id)?.label ?? id} banner',
              selected: worn == id,
              builder: (context, state) => Container(
                width: w.floorToDouble(),
                height: 34,
                clipBehavior: Clip.antiAlias,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(t.radius('md')),
                  border: Border.all(color: t.color(worn == id ? 'app-ink' : 'app-rule'), width: worn == id ? 2 : 1),
                ),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(t.radius('md'))),
                child: CosmeticBanner(
                  id: id,
                  // None: the band in your own colour, as the card draws it then.
                  fallback: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: [hues.start, hues.end]))),
                ),
              ),
            ),
        ]);
      }),
    );
  }

  /// The badge shown beside your name, and under a press the ones you have to choose it from.
  Widget _badgePick(Tokens t) {
    final me = Me.instance;
    final mine = specialBadgesOf(me.special);
    final shown = SpecialBadges.instance.shownOf('', me: true) ?? mine.first;
    return GlacierPopover(
      open: _badges,
      onOpenChange: _setBadges,
      placement: Placement.bottomStart,
      ariaLabel: 'The badge beside your name',
      minWidth: t.lenOf('15rem'),
      maxWidth: t.lenOf('17rem'),
      padding: EdgeInsets.all(t.space(1)),
      trigger: (context, trigger) => Padding(
        padding: EdgeInsetsDirectional.only(start: t.space(1)),
        child: GlacierPressable(
          key: const ValueKey('profile-peek-badge'),
          onPressed: trigger.toggle,
          semanticLabel: '${shown.name}, the badge beside your name. Change it',
          builder: (context, state) => Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: state.hovered || state.pressed || _badges ? t.color('app-ink').withValues(alpha: 0.08) : null, borderRadius: BorderRadius.circular(t.radius('md'))),
            child: AppIcon(shown.icon, size: 20, color: PluginHues.of(t, shown.hue).accent),
          ),
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(2), t.space(1)),
          child: Text('SHOWN BESIDE YOUR NAME', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'), tracking: 0.4)),
        ),
        for (final b in mine)
          GlacierPressable(
            key: ValueKey('profile-peek-badge-${b.id}'),
            onPressed: () {
              if (b.id != shown.id) unawaited(me.setShowcase(b.id).catchError((_) {}));
              _setBadges(false);
            },
            semanticLabel: '${b.name}. ${b.about}',
            selected: b.id == shown.id,
            builder: (context, state) => Container(
              padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(2)),
              decoration: BoxDecoration(color: state.hovered || state.pressed || state.focused ? t.color('app-ink').withValues(alpha: 0.06) : null, borderRadius: BorderRadius.circular(t.radius('md'))),
              child: Row(children: [
                AppIcon(b.icon, size: 20, color: PluginHues.of(t, b.hue).accent),
                SizedBox(width: t.space(3)),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(b.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink'))),
                    Text(b.about, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                  ]),
                ),
                if (b.id == shown.id) AppIcon(Lucide.check, size: 16, color: t.color('app-ink')),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// One row of the card: a mark, its words, something at its end.
class _PeekRow extends StatelessWidget {
  const _PeekRow({super.key, required this.icon, required this.label, required this.onPress, this.end});
  final Widget icon;
  final String label;
  final Widget? end;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPress,
      semanticLabel: label,
      builder: (context, state) => Container(
        constraints: BoxConstraints(minHeight: t.lenOf('2.75rem')),
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
        color: state.hovered || state.pressed || state.focused ? t.color('app-ink').withValues(alpha: 0.06) : null,
        child: Row(children: [
          SizedBox(width: 20, height: 20, child: icon),
          SizedBox(width: t.space(3)),
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'medium', color: t.color('app-ink')))),
          ?end,
        ]),
      ),
    );
  }
}
