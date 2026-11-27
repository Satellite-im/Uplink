import 'platform_info.dart';

/// The emoji sets the person chooses between in Settings › Look (Matt, 2026-11-13: "give the user a suite of emoji
/// libraries to choose from"). Each but the phone's own is a font the app carries (assets/emoji/, with its licence in
/// LICENSES.md), put first among the fallbacks of the page's faces: Inter has no emoji, so the set chosen draws
/// every one, in messages, the composer, reactions and notifications' previews in the app alike.
class EmojiSet {
  const EmojiSet(this.id, this.name, this.family, this.about);
  final String id;
  final String name;

  /// The font family in pubspec.yaml, or null for the emoji Android itself draws.
  final String? family;
  final String about;
}

/// The sets offered, in the order shown. The id is what is kept as the choice ([AppState.emoji]).
const emojiSets = [
  EmojiSet('system', 'This phone\'s', null, 'What Android draws: Samsung\'s on a Galaxy, Google\'s on a Pixel.'),
  EmojiSet('noto', 'Noto', 'Ghost Emoji Noto', 'Google\'s, as on a Pixel and in Google Messages.'),
  EmojiSet('twemoji', 'Twemoji', 'Ghost Emoji Twemoji', 'Flat and bright, from Twitter and Discord.'),
  EmojiSet('openmoji', 'OpenMoji', 'Ghost Emoji OpenMoji', 'Hand-drawn outlines with flat colour.'),
  EmojiSet('outline', 'Outline', 'Ghost Emoji Outline', 'One colour, in the text\'s own ink.'),
];

/// The set kept as [id]; the phone's own where the id is none of them.
EmojiSet emojiSet(String id) => emojiSets.firstWhere((s) => s.id == id, orElse: () => emojiSets.first);

/// The sets as this device offers them: all of them, but in a browser. A page there draws every letter itself and
/// can't reach the emoji of the device it is on, so "This phone's" is not on its list (lib/web).
List<EmojiSet> get offeredEmojiSets => PlatformInfo.isWeb ? [for (final s in emojiSets) if (s.family != null) s] : emojiSets;

/// The font family that draws the set [id]'s emoji: its own, and none for the device's own. In a browser, which has
/// none of its own to leave them to, [browserEmojiFamily] in that place.
String? emojiFamilyOf(String id) => emojiSet(id).family ?? (PlatformInfo.isWeb ? browserEmojiFamily : null);

/// The set whose emoji are drawn for the choice [id], to name it: the one chosen, and in a browser, where "This
/// phone's" can't be, the one drawn in its place.
EmojiSet emojiSetInUse(String id) => PlatformInfo.isWeb ? emojiSets.firstWhere((s) => s.family == emojiFamilyOf(id)) : emojiSet(id);

/// What draws emoji in a browser where no set was chosen: the fullest of the app's own.
const browserEmojiFamily = 'Ghost Emoji Noto';

/// Each family's file among the app's assets (pubspec.yaml), for where a set is fetched only once it is wanted
/// ([ensureEmojiFont]).
const emojiFontAssets = {
  'Ghost Emoji Noto': 'assets/emoji/NotoColor.ttf',
  'Ghost Emoji Twemoji': 'assets/emoji/Twemoji.ttf',
  'Ghost Emoji OpenMoji': 'assets/emoji/OpenMoji.ttf',
  'Ghost Emoji Outline': 'assets/emoji/NotoOutline.ttf',
};

/// Has [family]'s font ready to draw with. Nothing to do on a phone or a computer, where every set is in the app as
/// it starts. A page in a browser fetches a set when it is first wanted, not all four (eleven megabytes) before its
/// first frame, and puts its own way of doing so here (lib/web/emoji.dart).
Future<void> Function(String family) ensureEmojiFont = (_) async {};

/// Shown in each set's row in Settings, one at a time: a face, a heart with its variation selector, a skin tone, a
/// joined family, a flag and the ghost.
const emojiSample = ['😀', '❤️', '👍🏽', '👨‍👩‍👧', '🇺🇸', '🎉', '👻'];
