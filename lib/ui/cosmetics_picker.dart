import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../me/cosmetics.dart';
import '../me/me.dart';
import '../sms.dart' show Sms;
import '../voice/channels.dart';
import 'common.dart';
import 'circles/circle_picture.dart' show pickBannerPicture;
import 'cosmetics_ui.dart';
import 'profile_card.dart' show ProfileFace;
import '../l10n/words.dart';

/// Profile › Look (GMFB-34): what your profile wears, each kind a row opening its pieces, with how you look now at the
/// top: your face dressed, your name in its effect, over your banner.
class CosmeticsSection extends StatelessWidget {
  const CosmeticsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final me = Me.instance;
    return ListenableBuilder(
      listenable: me,
      builder: (context, _) {
        final c = me.cosmetics;
        return PaneSection(
          title: 'Look',
          description: const Tr('Dress your profile. Friends and people in your spaces see it on your profile card.'),
          children: [
            SettingRowBox(child: _Preview(cosmetics: c, name: me.shownName, picture: me.pictureOwn, banner: me.banner)),
            for (final kind in CosmeticKind.worn)
              SettingRow(
                key: ValueKey('look-${kind.name}'),
                icon: AppIcon(_iconOf(kind), size: 18),
                label: kind.label,
                value: Text(kind == CosmeticKind.banner && me.banner.isNotEmpty ? 'Your picture' : (CosmeticCatalog.find(kind, c.of(kind))?.label ?? 'None')),
                onPress: () => push(context, (_) => CosmeticPickerScreen(kind: kind)),
              ),
            if (!c.isEmpty || me.banner.isNotEmpty)
              SettingRow(
                icon: AppIcon(Lucide.x, size: 18),
                label: 'Take everything off',
                onPress: () {
                  me.setBanner(null);
                  wear(Cosmetics.none);
                },
              ),
          ],
        );
      },
    );
  }
}

LucideIcon _iconOf(CosmeticKind kind) => switch (kind) {
      CosmeticKind.decoration => Lucide.sparkles,
      CosmeticKind.border => Lucide.circleUser,
      CosmeticKind.banner => Lucide.image,
      CosmeticKind.name => Lucide.type,
      CosmeticKind.effect => Lucide.flame,
    };

/// Puts [c] on: kept, told to friends and said again in every space.
void wear(Cosmetics c) {
  Me.instance.setCosmetics(c);
  Buddies.instance.shareProfile();
  Voice.instance.sayMeEverywhere();
}

/// Wears the ready-made banner [id] ('' for none) in place of a picture of your own, which is taken away.
void wearBanner(String id) {
  Me.instance.setBanner(null);
  wear(Me.instance.cosmetics.withKind(CosmeticKind.banner, id));
}

/// A banner of your own (GMFB-34: the banner was one of ten ready-made ones only): asks for a picture and which band
/// of it (pickBannerPicture), keeps it and tells friends.
/// The ready-made banner chosen stays as it is: what a build from before draws, and what a space is told. False where
/// none was chosen or it couldn't be used (said in a toast).
Future<bool> chooseBannerPicture(BuildContext context) async {
  final made = await pickBannerPicture(context);
  if (made == null) return false;
  Me.instance.setBanner(made);
  Buddies.instance.shareProfile();
  if (context.mounted) toast(context, 'Your banner is set. Your friends will see it.');
  return true;
}

/// How the profile looks with [cosmetics]: the banner, the dressed face over its edge, the name in its effect, and the
/// profile effect over all of it, as the card draws them.
class _Preview extends StatelessWidget {
  const _Preview({required this.cosmetics, required this.name, required this.picture, this.banner = ''});
  final Cosmetics cosmetics;
  final String name;
  final String picture;
  final String banner;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final face = t.lenOf('4rem');
    final bannerH = t.lenOf('4.5rem');
    final hues = [t.color('app-paper-3'), t.color('app-paper-2')];
    return ClipRRect(
      key: const ValueKey('look-preview'),
      borderRadius: BorderRadius.circular(t.radius('lg')),
      child: Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: bannerH + face / 2,
            child: Stack(clipBehavior: Clip.none, children: [
              PositionedDirectional(
                start: 0,
                end: 0,
                top: 0,
                height: bannerH,
                child: CosmeticBanner(id: cosmetics.banner, picture: banner, fallback: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: hues)))),
              ),
              PositionedDirectional(
                start: t.space(4),
                top: bannerH - face / 2,
                child: DressedFace(size: face, cosmetics: cosmetics, face: ProfileFace(name: name, picture: picture, size: face)),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(3)),
            child: NameEffectText(name.isEmpty ? 'You' : name, id: cosmetics.name, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
          ),
        ]),
        if (cosmetics.effect.isNotEmpty) Positioned.fill(child: ProfileEffectLayer(id: cosmetics.effect)),
      ]),
    );
  }
}

/// The pieces of one kind, as tiles: None first, then each piece drawn as it would be worn. The one worn is ringed.
class CosmeticPickerScreen extends StatelessWidget {
  const CosmeticPickerScreen({super.key, required this.kind});
  final CosmeticKind kind;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = Me.instance;
    return GhostPage(
      title: kind.label,
      body: ListenableBuilder(
        listenable: me,
        builder: (context, _) {
          final pieces = CosmeticCatalog.of(kind);
          final wide = kind == CosmeticKind.banner || kind == CosmeticKind.name;
          // A banner can be a picture of your own (GMFB-34), its tile after None; not in a browser, which can't choose
          // a picture yet. While one is worn no ready-made banner is ringed: pressing one takes its place.
          final own = kind == CosmeticKind.banner && !Sms.browser ? 1 : 0;
          final mine = kind == CosmeticKind.banner ? me.banner : '';
          final worn = mine.isNotEmpty ? null : me.cosmetics.of(kind);
          return GridView.builder(
            padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(3), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom),
            gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: wide ? t.lenOf('14rem') : t.lenOf('8rem'),
              mainAxisSpacing: t.space(3),
              crossAxisSpacing: t.space(3),
              childAspectRatio: wide ? 2.4 : 0.85,
            ),
            itemCount: pieces.length + 1 + own,
            itemBuilder: (context, i) {
              if (own == 1 && i == 1) {
                return _Tile(
                  key: const ValueKey('piece-own'),
                  kind: kind,
                  piece: null,
                  label: mine.isEmpty ? 'Your picture' : 'Change your picture',
                  show: mine.isEmpty ? Center(child: AppIcon(Lucide.image, size: 22, color: context.tokens.color('app-ink-3'))) : ClipRRect(borderRadius: BorderRadius.circular(context.tokens.radius('md')), child: CosmeticBanner(id: '', picture: mine, fallback: const SizedBox.shrink())),
                  worn: mine.isNotEmpty,
                  onPick: () => chooseBannerPicture(context),
                );
              }
              final piece = i == 0 ? null : pieces[i - 1 - own];
              final id = piece?.id ?? '';
              return _Tile(
                key: ValueKey('piece-${id.isEmpty ? 'none' : id}'),
                kind: kind,
                piece: piece,
                worn: worn == id,
                onPick: () => kind == CosmeticKind.banner ? wearBanner(id) : wear(me.cosmetics.withKind(kind, id)),
              );
            },
          );
        },
      ),
    );
  }
}

/// One tile: the piece as it would look worn alone on your own face, name or card (None: a ban sign), its name under.
class _Tile extends StatelessWidget {
  const _Tile({super.key, required this.kind, required this.piece, required this.worn, required this.onPick, this.label, this.show});
  final CosmeticKind kind;
  final Cosmetic? piece;

  /// For a tile that is not a piece (a banner picture of your own): what it is called and what it shows.
  final String? label;
  final Widget? show;
  final bool worn;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final me = Me.instance;
    final p = piece;
    final face = t.lenOf('3rem');
    Widget show;
    if (this.show != null) {
      show = this.show!;
    } else if (p == null) {
      show = Center(child: AppIcon(Lucide.ban, size: 22, color: t.color('app-ink-3')));
    } else {
      final just = Cosmetics.none.withKind(kind, p.id);
      show = switch (kind) {
        CosmeticKind.decoration || CosmeticKind.border => Center(child: DressedFace(size: face, cosmetics: just, face: ProfileFace(name: me.shownName, picture: me.pictureSharp, size: face))),
        CosmeticKind.banner => ClipRRect(borderRadius: BorderRadius.circular(t.radius('md')), child: CosmeticBanner(id: p.id, fallback: const SizedBox.shrink())),
        CosmeticKind.name => Center(child: NameEffectText(me.shownName.isEmpty ? p.label : me.shownName, id: p.id, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink')))),
        CosmeticKind.effect => ClipRRect(
            borderRadius: BorderRadius.circular(t.radius('md')),
            child: Stack(children: [Positioned.fill(child: ColoredBox(color: t.color('app-paper-3'))), Positioned.fill(child: ProfileEffectLayer(id: p.id))]),
          ),
      };
    }
    return GlacierPressable(
      onPressed: onPick,
      semanticLabel: '${label ?? p?.label ?? 'None'}${worn ? ', worn' : ''}',
      builder: (context, state) => Container(
        padding: EdgeInsets.all(t.space(2)),
        decoration: BoxDecoration(
          color: t.color(state.pressed ? 'app-paper-3' : 'app-paper-2'),
          borderRadius: BorderRadius.circular(t.radius('lg')),
          border: Border.all(color: worn ? t.color('app-ink') : t.color('app-rule'), width: worn ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: show),
          SizedBox(height: t.space(1)),
          Text(label ?? p?.label ?? 'None', textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: worn ? 'bold' : 'medium', color: t.color('app-ink-2'))),
        ]),
      ),
    );
  }
}
