import 'package:flutter/services.dart';

/// The app's stickers (Matt, 2026-11-13: "generate 4 sticker packs using our ghost mascot we've developed"): the
/// ghost in the poses drawn for the message effects, made into stickers by tool/sticker_packs.py and kept in
/// `assets/stickers/<pack>/`. A sticker is sent as a picture message. Mischief is a pack drawn for itself (the
/// dark-cute one: horns, a heart-tipped tail), cut from its own sheet by the same tool.
class StickerPack {
  const StickerPack(this.id, this.name, this.stickers);
  final String id;
  final String name;

  /// The stickers' assets, in the order the pack keeps them.
  final List<String> stickers;
}

/// The packs' names, in the order they are offered. A pack with no pictures is not offered.
const _names = {'ghost': 'Ghost', 'love': 'Love', 'party': 'Party', 'sweet': 'Sweet', 'mischief': 'Mischief'};

/// The packs, read once and kept for as long as the app runs.
Future<List<StickerPack>>? _packs;

/// Every pack the app carries, read from what is bundled.
Future<List<StickerPack>> stickerPacks() => _packs ??= _read();

Future<List<StickerPack>> _read() async {
  try {
    final assets = (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();
    return [
      for (final e in _names.entries)
        // A still sticker is a WebP; one that moves is an animated PNG (tool/sticker_packs.py), which is also what is sent.
        StickerPack(e.key, e.value, assets.where((a) => a.startsWith('assets/stickers/${e.key}/') && (a.endsWith('.webp') || a.endsWith('.png'))).toList()..sort()),
    ].where((p) => p.stickers.isNotEmpty).toList();
  } catch (_) {
    return const [];
  }
}

/// A sticker's name as it travels: its pack and its number (`love-03`), from its asset.
String stickerName(String asset) {
  final parts = asset.split('/');
  return '${parts[parts.length - 2]}-${parts.last.replaceAll('.webp', '').replaceAll('.png', '')}';
}

/// The asset of the sticker named [name] ([stickerName]), where this app carries it: a space's chat sends a sticker by
/// its name alone (lib/voice/hangout.dart), and each app draws its own copy.
Future<String?> stickerAsset(String name) async {
  for (final p in await stickerPacks()) {
    for (final a in p.stickers) {
      if (stickerName(a) == name) return a;
    }
  }
  return null;
}
