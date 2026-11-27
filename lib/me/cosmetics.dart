import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter/widgets.dart' show Color;

/// What dresses a profile, as Discord's do (GMFB-34; Matt, 2026-11-22: "get ready for supporting profile decorations,
/// profile picture borders, custom name effects and more like discord supports"): a decoration around the picture, a
/// border on it, a banner over the card, an effect on the name, and an effect drifting over the whole card.
///
/// Each is an id from [CosmeticCatalog], sent to friends with the profile (`cx`, lib/friends/buddies.dart) and to
/// spaces with a greeting: a few short words, never a picture, so an old build passes over it and a new one draws what
/// it has. The art is the app's own (`assets/cosmetics/<kind>/<id>.png`, made with Lovart from
/// ~/Desktop/ghost-profile-cosmetics-prompts.md); where a piece's file is not in this build yet it is drawn by
/// lib/ui/cosmetics_ui.dart from its [Cosmetic.accent] instead, so an id is never lost and never shown broken.
@immutable
class Cosmetics {
  const Cosmetics({this.decoration = '', this.border = '', this.banner = '', this.name = '', this.effect = ''});

  /// Ids, '' for none.
  final String decoration;
  final String border;
  final String banner;
  final String name;
  final String effect;

  static const none = Cosmetics();

  bool get isEmpty => decoration.isEmpty && border.isEmpty && banner.isEmpty && name.isEmpty && effect.isEmpty;

  /// The id worn of [kind]; '' for none.
  String of(CosmeticKind kind) => switch (kind) {
        CosmeticKind.decoration => decoration,
        CosmeticKind.border => border,
        CosmeticKind.banner => banner,
        CosmeticKind.name => name,
        CosmeticKind.effect => effect,
      };

  /// These, with [id] worn of [kind] ('' takes it off) and the rest as they are.
  Cosmetics withKind(CosmeticKind kind, String id) => Cosmetics(
        decoration: kind == CosmeticKind.decoration ? id : decoration,
        border: kind == CosmeticKind.border ? id : border,
        banner: kind == CosmeticKind.banner ? id : banner,
        name: kind == CosmeticKind.name ? id : name,
        effect: kind == CosmeticKind.effect ? id : effect,
      );

  /// As sent and kept: the ids worn, by kind's short name. Empty ones are left out, and so are the kinds no longer
  /// worn ([CosmeticKind.worn]).
  Map<String, String> toJson() => {
        for (final k in CosmeticKind.worn)
          if (of(k).isNotEmpty) k.wire: of(k),
      };

  /// What was said: each id kept only where it is one this build knows of its kind, or one shaped like an id (a
  /// newer build's piece, kept to be passed on and drawn once this build has it). Null where nothing was said.
  static Cosmetics? fromJson(Object? j) {
    if (j is! Map) return null;
    String id(CosmeticKind k) {
      // A kind no longer worn is not read: an older build's ring or effect is drawn nowhere.
      if (!CosmeticKind.worn.contains(k)) return '';
      final v = j[k.wire];
      return v is String && _idShape.hasMatch(v) ? v : '';
    }

    return Cosmetics(
      decoration: id(CosmeticKind.decoration),
      border: id(CosmeticKind.border),
      banner: id(CosmeticKind.banner),
      name: id(CosmeticKind.name),
      effect: id(CosmeticKind.effect),
    );
  }

  static final _idShape = RegExp(r'^[a-z0-9][a-z0-9-]{0,39}$');

  @override
  bool operator ==(Object other) =>
      other is Cosmetics && other.decoration == decoration && other.border == border && other.banner == banner && other.name == name && other.effect == effect;

  @override
  int get hashCode => Object.hash(decoration, border, banner, name, effect);
}

/// The kinds of piece a profile can wear, one of each at most.
enum CosmeticKind {
  decoration('d', 'decorations', 'Avatar decoration'),
  border('r', 'borders', 'Picture border'),
  banner('bn', 'banners', 'Banner'),
  name('ne', 'names', 'Name effect'),
  effect('pe', 'effects', 'Profile effect');

  const CosmeticKind(this.wire, this.folder, this.label);

  /// The kinds a profile wears now: a banner and a name effect. The decoration around the picture, the border on it
  /// and the effect over the card were taken away (Matt, 2026-11-25: "remove the profile decoration, the profile
  /// border and the profile effect"): not offered, not sent, and not read from anyone, so none is drawn anywhere.
  /// Their names stay for the builds that still send them.
  static const worn = [banner, name];

  /// Its key in `cx`.
  final String wire;

  /// Its folder under assets/cosmetics.
  final String folder;
  final String label;
}

/// How a name effect is drawn: a texture from the art ([texture]), or the app's own ([gradient], a slow
/// [shimmer] across it, a [glow], or a [rainbow] that turns).
enum NameStyle { texture, gradient, shimmer, glow, rainbow }

/// One piece in the catalog: its kind, the id it is sent as, and what it is called.
@immutable
class Cosmetic {
  const Cosmetic(this.kind, this.id, this.label, this.accent, {this.second, this.style = NameStyle.texture});
  final CosmeticKind kind;
  final String id;
  final String label;

  /// Its colour: what the stand-in is drawn in until its art is in the build, and a name effect's own.
  final Color accent;

  /// A second colour, for gradients and stand-ins.
  final Color? second;

  /// For a name effect: how it is drawn.
  final NameStyle style;

  /// Where its art is, in the app's assets: a still, and (for a piece that moves) an animated WebP beside it, which is
  /// drawn in its place where it is there and motion is not switched off.
  String get asset => 'assets/cosmetics/${kind.folder}/$id.png';
  String get animated => 'assets/cosmetics/${kind.folder}/$id.webp';

  /// Whether it is drawn from code alone, needing no art.
  bool get coded => kind == CosmeticKind.name && style != NameStyle.texture;
}

/// Every piece this build knows: the forty made with Lovart and the name effects the app draws itself.
class CosmeticCatalog {
  CosmeticCatalog._();

  static const _ice = Color(0xFF7FD3FF), _amber = Color(0xFFFFB347), _pink = Color(0xFFFF8FC8), _crimson = Color(0xFFE5334B);
  static const _gold = Color(0xFFF2C94C), _green = Color(0xFF5CFF8A), _lavender = Color(0xFFB9A5FF), _violet = Color(0xFF9B5CFF);
  static const _cyan = Color(0xFF4FE3F0), _orange = Color(0xFFFF8A3D), _lime = Color(0xFFB8FF3D), _silver = Color(0xFFD9DEE6);
  static const _magenta = Color(0xFFFF3DCB), _sand = Color(0xFFE2C79A), _blue = Color(0xFF3D8BFF), _smoke = Color(0xFF8D96A3);

  static const all = <Cosmetic>[
    // The Uplink pack (Matt, 2026-11-22: "Let's work on just nailing one good profile decoration pack focused around
    // the ghosts"): the app's own ghosts, animated, from ~/Desktop/ghost-pack-lovart-prompts.md.
    Cosmetic(CosmeticKind.decoration, 'ghost-ring', 'Ghost Ring', Color(0xFFE8F4FF), second: _ice),
    // Avatar decorations: around the picture, spilling a little past it.
    Cosmetic(CosmeticKind.decoration, 'wisp-halo', 'Wisp halo', _ice),
    Cosmetic(CosmeticKind.decoration, 'candle-ring', 'Candle ring', _amber),
    Cosmetic(CosmeticKind.decoration, 'cat-ears', 'Cat ears', _pink),
    Cosmetic(CosmeticKind.decoration, 'devil-horns', 'Devil horns', _crimson),
    Cosmetic(CosmeticKind.decoration, 'angel-wings', 'Angel wings', _gold),
    Cosmetic(CosmeticKind.decoration, 'crt-scanlines', 'CRT', _green),
    Cosmetic(CosmeticKind.decoration, 'crown-of-moths', 'Crown of moths', _lavender),
    Cosmetic(CosmeticKind.decoration, 'static-storm', 'Static storm', _violet),
    Cosmetic(CosmeticKind.decoration, 'sakura-drift', 'Sakura drift', _pink),
    Cosmetic(CosmeticKind.decoration, 'frost-crystals', 'Frost', _cyan),
    Cosmetic(CosmeticKind.decoration, 'headphones', 'Headphones', _orange),
    Cosmetic(CosmeticKind.decoration, 'haunted-vines', 'Haunted vines', _lime),
    // Picture borders: a ring on the picture's edge.
    Cosmetic(CosmeticKind.border, 'silver-filigree', 'Silver filigree', _silver),
    Cosmetic(CosmeticKind.border, 'neon-tube', 'Neon', _magenta),
    Cosmetic(CosmeticKind.border, 'dotted-orbit', 'Orbit', _silver, second: _ice),
    Cosmetic(CosmeticKind.border, 'gold-laurel', 'Laurel', _gold),
    Cosmetic(CosmeticKind.border, 'holo-foil', 'Holo foil', _pink, second: _cyan),
    Cosmetic(CosmeticKind.border, 'rope-knot', 'Rope', _sand),
    Cosmetic(CosmeticKind.border, 'pixel-ring', 'Pixel', _blue),
    Cosmetic(CosmeticKind.border, 'smoke-ring', 'Smoke', _smoke),
    // Banners: over the top of the card.
    Cosmetic(CosmeticKind.banner, 'midnight-fog', 'Midnight fog', Color(0xFF1B2440), second: Color(0xFF5A6B8C)),
    Cosmetic(CosmeticKind.banner, 'dialup-dusk', 'Dial-up dusk', Color(0xFF3B1E6E), second: Color(0xFFFF7A59)),
    Cosmetic(CosmeticKind.banner, 'lamplight-street', 'Lamplight', Color(0xFF1E1A16), second: Color(0xFFE8A54B)),
    Cosmetic(CosmeticKind.banner, 'phosphor-grid', 'Phosphor grid', Color(0xFF031A08), second: Color(0xFF2BFF6A)),
    Cosmetic(CosmeticKind.banner, 'aurora', 'Aurora', Color(0xFF07343A), second: Color(0xFF8A4DFF)),
    Cosmetic(CosmeticKind.banner, 'paper-ghosts', 'Paper ghosts', Color(0xFFF3EAD8), second: Color(0xFFCBBFA8)),
    Cosmetic(CosmeticKind.banner, 'deep-space', 'Deep space', Color(0xFF0B0820), second: Color(0xFF5B3DB5)),
    Cosmetic(CosmeticKind.banner, 'sunset-dunes', 'Sunset dunes', Color(0xFFE36A5C), second: Color(0xFFF6B26B)),
    Cosmetic(CosmeticKind.banner, 'city-rain', 'City rain', Color(0xFF14102A), second: Color(0xFFFF3D9A)),
    Cosmetic(CosmeticKind.banner, 'forest-mist', 'Forest mist', Color(0xFF1F3326), second: Color(0xFF9FB8A0)),
    // Name effects: textures from the art, then the app's own.
    Cosmetic(CosmeticKind.name, 'flame', 'Flame', Color(0xFFFF4D1A), second: Color(0xFFFFD23F)),
    Cosmetic(CosmeticKind.name, 'galaxy', 'Galaxy', Color(0xFF6A3DFF), second: Color(0xFF3DB8FF)),
    Cosmetic(CosmeticKind.name, 'gold-leaf', 'Gold leaf', Color(0xFFB8860B), second: Color(0xFFFFE08A)),
    Cosmetic(CosmeticKind.name, 'ice', 'Ice', Color(0xFF3DA9FF), second: Color(0xFFE6F7FF)),
    Cosmetic(CosmeticKind.name, 'holographic', 'Holographic', Color(0xFFFF9AE6), second: Color(0xFF9AF0FF)),
    Cosmetic(CosmeticKind.name, 'toxic', 'Toxic', Color(0xFF39FF14), second: Color(0xFFB8FF3D)),
    Cosmetic(CosmeticKind.name, 'sunrise', 'Sunrise', Color(0xFFFF5F6D), second: Color(0xFFFFC371), style: NameStyle.gradient),
    Cosmetic(CosmeticKind.name, 'ocean', 'Ocean', Color(0xFF2E8BFF), second: Color(0xFF2EF2C8), style: NameStyle.gradient),
    Cosmetic(CosmeticKind.name, 'shimmer', 'Shimmer', Color(0xFFC9D2DE), second: Color(0xFFFFFFFF), style: NameStyle.shimmer),
    Cosmetic(CosmeticKind.name, 'spectral-glow', 'Spectral glow', Color(0xFFE8F4FF), second: Color(0xFF7FD3FF), style: NameStyle.glow),
    Cosmetic(CosmeticKind.name, 'rainbow', 'Rainbow', Color(0xFFFF4D4D), second: Color(0xFF4D7BFF), style: NameStyle.rainbow),
    // Profile effects: over the whole card, from its edges. The Uplink pack's first.
    Cosmetic(CosmeticKind.effect, 'haunted', 'Haunted', Color(0xFFFFFFFF), second: _ice),
    Cosmetic(CosmeticKind.effect, 'falling-ghosts', 'Falling ghosts', Color(0xFFFFFFFF)),
    Cosmetic(CosmeticKind.effect, 'embers', 'Embers', Color(0xFFFF7A1A), second: Color(0xFFFFD23F)),
    Cosmetic(CosmeticKind.effect, 'snowfall', 'Snowfall', Color(0xFFEFF6FF)),
    Cosmetic(CosmeticKind.effect, 'starfield-corners', 'Starfield', Color(0xFFFFF3B0), second: Color(0xFFB9A5FF)),
  ];

  /// The pieces of [kind], in the catalog's order.
  static List<Cosmetic> of(CosmeticKind kind) => [for (final c in all) if (c.kind == kind) c];

  /// The piece [id] of [kind]; null for none, or one this build does not know (a newer build's).
  static Cosmetic? find(CosmeticKind kind, String id) {
    if (id.isEmpty) return null;
    for (final c in all) {
      if (c.kind == kind && c.id == id) return c;
    }
    return null;
  }
}

/// Which pieces' art is in this build: read once from the app's list of its assets, so a piece whose file has not been
/// added yet is drawn as its stand-in rather than failing to load.
class CosmeticArt extends ChangeNotifier {
  CosmeticArt._();
  static final CosmeticArt instance = CosmeticArt._();

  Set<String>? _assets;
  bool _asked = false;

  /// Whether [c]'s art is here (its still or its animation); false until the list is read (asked for then), and for a
  /// piece drawn from code.
  bool has(Cosmetic c) {
    if (c.coded) return false;
    final known = _assets;
    if (known != null) return known.contains(c.asset) || known.contains(c.animated);
    if (!_asked) {
      _asked = true;
      AssetManifest.loadFromAssetBundle(rootBundle).then((m) {
        _assets = {for (final a in m.listAssets()) if (a.startsWith('assets/cosmetics/')) a};
        if (_assets!.isNotEmpty) notifyListeners();
      }, onError: (Object _) {
        _assets = const {};
      });
    }
    return false;
  }

  /// The file to draw for [c]: its animation where there is one and [moving] (motion not switched off), else its still,
  /// else the animation's first frame (Flutter draws a WebP still where it may not move). Null where neither is here.
  String? artOf(Cosmetic c, {required bool moving}) {
    final known = _assets ?? const <String>{};
    final still = known.contains(c.asset), anim = known.contains(c.animated);
    if (anim && (moving || !still)) return c.animated;
    return still ? c.asset : null;
  }

  /// For a test: the art in the build is [assets], or not yet read where null.
  @visibleForTesting
  void reset([Set<String>? assets]) {
    _assets = assets;
    _asked = assets != null;
  }
}
