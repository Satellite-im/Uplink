import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'reactions.dart' show isEmojiRun;

/// The effects a message can set off over the conversation (Matt, 2026-11-13: "special effects on keywords and key
/// emoji's", then "make sure we support all the same ones as imessage, samsung messenger, google messenger").
///
/// The set is the union of the iPhone's screen effects (echo, spotlight, balloons, confetti, love, lasers, fireworks,
/// celebration), the ones Google Messages plays on a phrase (snow, hearts, kisses, wow, thanks, good night, good
/// morning, get well, bye, hungry, sorry, party), and this app's own (ghosts). Samsung Messages has none of its own.
/// docs/effects.md lists every one with what sets it off and a prompt for its overlay.
enum ScreenEffect {
  confetti,
  balloons,
  fireworks,
  celebration,
  hearts,
  kisses,
  snow,
  lasers,
  ghosts,
  wow,
  thanks,
  goodNight,
  goodMorning,
  getWell,
  bye,
  hungry,
  sorry,
  party,
  echo,
  spotlight,
}

/// The iPhone's bubble effects: how one message arrives, not something over the whole screen.
enum BubbleEffect { slam, loud, gentle, invisibleInk }

/// The words that set an effect off, in lower case, matched whole anywhere in a message. The first listed wins, so
/// "happy lunar new year" is asked before "happy new year".
const _phrases = <ScreenEffect, List<String>>{
  ScreenEffect.balloons: ['happy birthday', 'happy bday', 'happy b-day'],
  ScreenEffect.confetti: ['congratulations', 'congrats', 'felicitations', 'well done', 'you did it', 'we did it'],
  ScreenEffect.celebration: ['happy lunar new year', 'happy chinese new year', 'gong xi fa cai', 'happy eid', 'eid mubarak'],
  ScreenEffect.fireworks: ['happy new year', 'happy 4th', 'happy fourth of july', 'happy diwali'],
  ScreenEffect.kisses: ['kisses', 'xoxo', 'mwah'],
  ScreenEffect.hearts: ['i love you', 'love you', 'love u', 'happy valentine', 'happy anniversary', 'miss you'],
  ScreenEffect.snow: ['it\'s snowing', 'its snowing', 'let it snow', 'merry christmas', 'happy holidays', 'snow day'],
  ScreenEffect.lasers: ['pew pew'],
  ScreenEffect.ghosts: ['boo', 'happy halloween', 'trick or treat', 'spooky'],
  ScreenEffect.wow: ['wow', 'woah', 'whoa'],
  ScreenEffect.thanks: ['thank you so much', 'thanks so much', 'thank you very much', 'many thanks'],
  ScreenEffect.goodNight: ['good night', 'goodnight', 'sweet dreams', 'nighty night'],
  ScreenEffect.goodMorning: ['good morning', 'rise and shine'],
  ScreenEffect.getWell: ['get well soon', 'feel better soon', 'feel better'],
  ScreenEffect.bye: ['bye bye', 'bye-bye', 'goodbye', 'see you later'],
  ScreenEffect.hungry: ['i\'m hungry', 'im hungry', 'so hungry', 'i\'m starving', 'im starving'],
  ScreenEffect.sorry: ['i\'m sorry', 'im sorry', 'so sorry', 'i apologize', 'i apologise'],
  ScreenEffect.party: ['party time', 'let\'s party', 'lets party'],
};

/// The key emoji: one of these in a message of nothing but emoji sets its effect off.
const _emoji = <ScreenEffect, List<String>>{
  ScreenEffect.balloons: ['🎂', '🎈', '🥳'],
  ScreenEffect.confetti: ['🎉', '🎊', '🏆'],
  ScreenEffect.celebration: ['🧧', '🐉', '🏮'],
  ScreenEffect.fireworks: ['🎆', '🎇', '🧨'],
  ScreenEffect.kisses: ['💋', '😘', '😚'],
  ScreenEffect.hearts: ['❤', '😍', '🥰', '💕', '💖', '💗', '💘', '💝', '💞'],
  ScreenEffect.snow: ['❄', '☃', '⛄', '🎄'],
  ScreenEffect.ghosts: ['👻', '🎃'],
  ScreenEffect.wow: ['🤩', '🤯', '😮'],
  ScreenEffect.thanks: ['🙏', '💐'],
  ScreenEffect.goodNight: ['🌙', '😴', '💤', '🌛'],
  ScreenEffect.goodMorning: ['☀', '🌅', '🌞', '🌄'],
  ScreenEffect.getWell: ['🤒', '🩹', '🤧'],
  ScreenEffect.bye: ['👋'],
  ScreenEffect.hungry: ['🍕', '🍔', '🌮', '🤤'],
  ScreenEffect.sorry: ['🥺', '😢', '😭'],
  ScreenEffect.party: ['🪩', '🕺', '💃'],
};

/// The emoji that is a screen effect when it is a REACTION to a message (Matt, 2026-11-13: "I'd like to be able to
/// react with full screen effects by pressing and holding on a message as well"). It goes as any reaction does,
/// `Reacted 🎈 to “See you at 7”`, which every phone can read and Google's and Samsung's apps show as a reaction;
/// this app hangs it on the message as a chip and plays the effect over the conversation, here and on the other
/// phone. None of them is among the reactions offered on a long press (lib/reactions.dart), so a plain heart or
/// 🎉 stays a plain reaction.
const effectReactionEmoji = <ScreenEffect, String>{
  ScreenEffect.balloons: '🎈',
  ScreenEffect.confetti: '🎊',
  ScreenEffect.fireworks: '🎆',
  ScreenEffect.celebration: '🏮',
  ScreenEffect.hearts: '💖',
  ScreenEffect.kisses: '💋',
  ScreenEffect.lasers: '⚡',
  ScreenEffect.ghosts: '👻',
  ScreenEffect.snow: '❄️',
  ScreenEffect.wow: '🤩',
  ScreenEffect.party: '🪩',
  ScreenEffect.thanks: '💐',
  ScreenEffect.goodMorning: '🌞',
  ScreenEffect.goodNight: '🌙',
  ScreenEffect.getWell: '🩹',
  ScreenEffect.sorry: '🥺',
  ScreenEffect.hungry: '🍕',
  ScreenEffect.bye: '👋',
  ScreenEffect.echo: '📣',
  ScreenEffect.spotlight: '🔦',
};

/// The screen effect a reaction's [emoji] is, or null for a plain reaction. The same emoji with or without its
/// "draw me in colour" mark (U+FE0F) is the same reaction.
ScreenEffect? effectForReaction(String emoji) {
  String bare(String s) => s.replaceAll('\uFE0F', '');
  final wanted = bare(emoji);
  for (final e in effectReactionEmoji.entries) {
    if (bare(e.value) == wanted) return e.key;
  }
  return null;
}

/// What an iPhone writes after a message it sent with an effect to a phone that can't play it: "(sent with Lasers)",
/// "(Sent with Slam effect)".
final _sentWith = RegExp(r'\s*\(sent with ([a-z ]+?)(?: effect)?\)\s*$', caseSensitive: false);

/// The names an iPhone gives its screen effects in "(sent with …)", in lower case, and the effect played for each.
const _sentScreen = {
  'echo': ScreenEffect.echo,
  'spotlight': ScreenEffect.spotlight,
  'balloons': ScreenEffect.balloons,
  'confetti': ScreenEffect.confetti,
  'love': ScreenEffect.hearts,
  'heart': ScreenEffect.hearts,
  'lasers': ScreenEffect.lasers,
  'fireworks': ScreenEffect.fireworks,
  'celebration': ScreenEffect.celebration,
  'shooting star': ScreenEffect.celebration,
  'sparkles': ScreenEffect.celebration,
};

/// The same for its bubble effects.
const _sentBubble = {
  'slam': BubbleEffect.slam,
  'loud': BubbleEffect.loud,
  'gentle': BubbleEffect.gentle,
  'invisible ink': BubbleEffect.invisibleInk,
};

/// A message's words without an iPhone's "(sent with …)" at their end, and the effect it named.
class SentWith {
  const SentWith(this.text, {this.screen, this.bubble});
  final String text;
  final ScreenEffect? screen;
  final BubbleEffect? bubble;
}

/// Takes an iPhone's "(sent with …)" off the end of [body]. A name that is no effect known here is left as written.
SentWith sentWith(String body) {
  final m = _sentWith.firstMatch(body);
  if (m == null) return SentWith(body);
  final name = m.group(1)!.trim().toLowerCase();
  final screen = _sentScreen[name];
  final bubble = _sentBubble[name];
  if (screen == null && bubble == null) return SentWith(body);
  return SentWith(body.substring(0, m.start), screen: screen, bubble: bubble);
}

/// The effect [text] sets off, or null: the one an iPhone named, else one of the phrases anywhere in it, else a
/// message of nothing but emoji with one of the key emoji among them. An emoji in the middle of a sentence sets off
/// nothing.
ScreenEffect? effectFor(String text) {
  final sent = sentWith(text);
  if (sent.screen != null) return sent.screen;
  final t = sent.text.trim();
  if (t.isEmpty || t.length > 300) return null;
  final lower = t.toLowerCase().replaceAll('’', '\'');
  for (final e in _phrases.entries) {
    for (final p in e.value) {
      // As whole words: no letter directly before or after, so "boo" is not found in "book".
      if (RegExp('(^|[^a-z])${RegExp.escape(p)}([^a-z]|\$)').hasMatch(lower)) return e.key;
    }
  }
  if (emojiOnly(t) > 0) {
    for (final e in _emoji.entries) {
      if (e.value.any(t.contains)) return e.key;
    }
  }
  return null;
}

/// How many emoji [text] is, when it is emoji and nothing else (spaces aside); 0 otherwise.
int emojiOnly(String text) {
  final t = text.replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty || !isEmojiRun(t, max: 64)) return 0;
  return t.characters.length;
}

/// The effects made of emoji in flight, drawn in the emoji set the person chose: which, and how they move.
enum _Flight { rise, fall, burst }

/// For each such effect: the emoji, how they move, and how many of them fly.
const _flights = <ScreenEffect, (List<String>, _Flight, int)>{
  ScreenEffect.kisses: (['💋', '😘', '💋', '💕'], _Flight.rise, 26),
  ScreenEffect.wow: (['🤩', '✨', '❗', '🤯', '⭐'], _Flight.burst, 34),
  ScreenEffect.thanks: (['🙏', '💐', '🌸', '🌷', '✨'], _Flight.fall, 30),
  ScreenEffect.goodNight: (['🌙', '⭐', '💤', '✨', '🌟'], _Flight.fall, 26),
  ScreenEffect.goodMorning: (['☀️', '🌤️', '🌻', '☕', '🐦'], _Flight.rise, 24),
  ScreenEffect.getWell: (['🌷', '💐', '🩹', '🍵', '💛'], _Flight.rise, 24),
  ScreenEffect.bye: (['👋', '👋🏽', '👋🏻', '👋🏿'], _Flight.rise, 22),
  ScreenEffect.hungry: (['🍕', '🍔', '🌮', '🍜', '🍟', '🍩'], _Flight.fall, 30),
  ScreenEffect.sorry: (['🥺', '💧', '💙', '💧'], _Flight.fall, 28),
  ScreenEffect.party: (['🪩', '🎶', '🕺', '💃', '✨'], _Flight.fall, 30),
};

/// How long each effect runs, in milliseconds. Every effect has one.
const _durations = <ScreenEffect, int>{
  ScreenEffect.confetti: 3600,
  ScreenEffect.balloons: 4600,
  ScreenEffect.fireworks: 4200,
  ScreenEffect.celebration: 4200,
  ScreenEffect.hearts: 4000,
  ScreenEffect.kisses: 4000,
  ScreenEffect.snow: 6000,
  ScreenEffect.lasers: 3000,
  ScreenEffect.ghosts: 4600,
  ScreenEffect.wow: 2600,
  ScreenEffect.thanks: 4200,
  ScreenEffect.goodNight: 5000,
  ScreenEffect.goodMorning: 4400,
  ScreenEffect.getWell: 4400,
  ScreenEffect.bye: 3600,
  ScreenEffect.hungry: 4200,
  ScreenEffect.sorry: 4400,
  ScreenEffect.party: 4200,
  ScreenEffect.echo: 3600,
  ScreenEffect.spotlight: 3400,
};

/// How long [effect] runs.
Duration effectDuration(ScreenEffect effect) => Duration(milliseconds: _durations[effect]!);

/// An effect's own pictures (Matt, 2026-11-13: "the ghost messages assets are on the desktop, please wire them all
/// and slice them up"): the ghost characters and the small props cut from its sheet by tool/effect_sprites.py into
/// `assets/effects/<effect>-h1.webp…` and `<effect>-p1.webp…`. Where an effect has them, the app moves them in place
/// of the emoji and plain shapes it drew; the light and the message's own words (fireworks, lasers, the spotlight,
/// echo) are still drawn, under them.
class EffectSprites {
  const EffectSprites(this.heroes, this.props);

  /// How many of the characters are animated: drawn six times over, played in turn.
  int get animated => heroes.where((h) => h.frames > 1).length;

  /// The characters: fewer, larger, slower.
  final List<EffectSprite> heroes;

  /// The props: many, small.
  final List<EffectSprite> props;

  /// The pictures decoded, or being decoded, in the order they were last asked for: the first is the first to go.
  static final _held = <ScreenEffect, Future<EffectSprites?>>{};

  /// How many effects' pictures are kept decoded: the one playing and the ones just played.
  static const _kept = 3;

  /// [effect]'s pictures, decoded the first time they are asked for; null where it has none.
  static Future<EffectSprites?> of(ScreenEffect effect) {
    final had = _held.remove(effect);
    final sprites = had ?? _load(effect);
    _held[effect] = sprites;
    while (_held.length > _kept) {
      _held.remove(_held.keys.first);
    }
    return sprites;
  }

  /// Finds [effect]'s pictures among the app's assets by their names and decodes them, in the order of their
  /// numbers. Null where there are none, or where one cannot be read.
  static Future<EffectSprites?> _load(ScreenEffect effect) async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      // -h1… the characters, -p1… the props, and -a1… a character's six drawings in a row (tool/effect_anims.py),
      // played where there is one in place of its still.
      final mine = RegExp('^assets/effects/${effect.name}-([hpa])(\\d+)\\.webp\$');
      final found = [for (final a in manifest.listAssets()) (a, mine.firstMatch(a))].where((f) => f.$2 != null).toList()
        ..sort((a, b) => int.parse(a.$2!.group(2)!).compareTo(int.parse(b.$2!.group(2)!)));
      Future<ui.Image> picture(String asset) async {
        final data = await rootBundle.load(asset);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
        return (await codec.getNextFrame()).image;
      }

      final moving = {for (final f in found) if (f.$2!.group(1) == 'a') f.$2!.group(2)!: f.$1};
      final heroes = <EffectSprite>[];
      for (final f in found) {
        final kind = f.$2!.group(1), number = f.$2!.group(2)!;
        if (kind == 'h') {
          heroes.add(moving.containsKey(number) ? EffectSprite(await picture(moving[number]!), EffectSprite.drawings) : EffectSprite(await picture(f.$1)));
        }
      }
      // A character with drawings and no still is a character too.
      final stills = {for (final f in found) if (f.$2!.group(1) == 'h') f.$2!.group(2)!};
      for (final e in moving.entries) {
        if (!stills.contains(e.key)) heroes.add(EffectSprite(await picture(e.value), EffectSprite.drawings));
      }
      final props = [for (final f in found) if (f.$2!.group(1) == 'p') EffectSprite(await picture(f.$1))];
      return heroes.isEmpty && props.isEmpty ? null : EffectSprites(heroes, props);
    } catch (_) {
      return null;
    }
  }
}

/// One picture of an effect: a prop or a character as a still, or a character drawn [frames] times side by side in
/// one picture (Matt, 2026-11-13: "6 frame animations for each asset in a sprite sheet"), played in turn as it flies.
class EffectSprite {
  const EffectSprite(this.image, [this.frames = 1]);
  final ui.Image image;
  final int frames;

  /// How many times a moving character is drawn in its picture, and how many of them a second are shown.
  static const drawings = 6;
  static const perSecond = 8.0;

  /// The size of one drawing, in the picture's own pixels.
  double get width => image.width / frames;
  double get height => image.height.toDouble();

  /// The part of the picture to draw [seconds] into the effect; [offset] starts each character on its own drawing,
  /// so a screen of them does not move as one.
  Rect at(double seconds, int offset) {
    final frame = frames <= 1 ? 0 : ((seconds * perSecond).floor() + offset) % frames;
    return Rect.fromLTWH(frame * width, 0, width, height);
  }
}

/// How an effect's pictures move: the props and how many, the characters and how many.
class _SpritePlan {
  const _SpritePlan(this.props, this.propCount, this.heroes, this.heroCount, {this.small = false});
  final _Flight props;
  final int propCount;
  final _Flight heroes;
  final int heroCount;

  /// The props are specks (confetti, snow): smaller, and they tumble.
  final bool small;
}

/// The plan for each effect, used only where the effect has pictures (see [EffectSprites]).
const _spritePlans = <ScreenEffect, _SpritePlan>{
  ScreenEffect.balloons: _SpritePlan(_Flight.rise, 14, _Flight.rise, 4),
  ScreenEffect.confetti: _SpritePlan(_Flight.fall, 64, _Flight.rise, 3, small: true),
  ScreenEffect.celebration: _SpritePlan(_Flight.fall, 16, _Flight.rise, 3),
  ScreenEffect.fireworks: _SpritePlan(_Flight.burst, 10, _Flight.rise, 3),
  ScreenEffect.kisses: _SpritePlan(_Flight.rise, 22, _Flight.rise, 4),
  ScreenEffect.hearts: _SpritePlan(_Flight.rise, 24, _Flight.rise, 4),
  ScreenEffect.snow: _SpritePlan(_Flight.fall, 56, _Flight.fall, 3, small: true),
  ScreenEffect.lasers: _SpritePlan(_Flight.burst, 14, _Flight.rise, 3),
  ScreenEffect.ghosts: _SpritePlan(_Flight.rise, 12, _Flight.rise, 6),
  ScreenEffect.wow: _SpritePlan(_Flight.burst, 28, _Flight.burst, 3),
  ScreenEffect.thanks: _SpritePlan(_Flight.fall, 24, _Flight.fall, 3),
  ScreenEffect.goodNight: _SpritePlan(_Flight.fall, 20, _Flight.fall, 3),
  ScreenEffect.goodMorning: _SpritePlan(_Flight.rise, 18, _Flight.rise, 4),
  ScreenEffect.getWell: _SpritePlan(_Flight.rise, 18, _Flight.rise, 4),
  ScreenEffect.bye: _SpritePlan(_Flight.rise, 14, _Flight.rise, 5),
  ScreenEffect.hungry: _SpritePlan(_Flight.fall, 26, _Flight.rise, 3),
  ScreenEffect.sorry: _SpritePlan(_Flight.fall, 22, _Flight.fall, 2),
  ScreenEffect.party: _SpritePlan(_Flight.fall, 24, _Flight.rise, 4),
  ScreenEffect.echo: _SpritePlan(_Flight.rise, 10, _Flight.rise, 3),
  ScreenEffect.spotlight: _SpritePlan(_Flight.fall, 10, _Flight.rise, 2),
};

/// The layer over a conversation that an effect plays on. It takes no touches and draws nothing while idle.
class EffectLayer extends StatefulWidget {
  const EffectLayer({super.key, required this.style});

  /// The page's text, for the effects made of emoji and of the message's own words: its emoji are the set chosen.
  final TextStyle style;

  @override
  State<EffectLayer> createState() => EffectLayerState();
}

/// Public so a conversation can hold a key to it and call [play].
class EffectLayerState extends State<EffectLayer> with SingleTickerProviderStateMixin {
  /// Runs from 0 to 1 over the effect's length.
  late final AnimationController _run = AnimationController(vsync: this);

  /// The effect playing; null while idle.
  ScreenEffect? _effect;

  /// New for each play: where every particle starts and how it moves comes from it.
  int _seed = 0;
  String _text = '';

  /// The playing effect's pictures, where it has them, and which play this is: one asked for while another's
  /// pictures were still being fetched does not start late over the newer one.
  EffectSprites? _sprites;
  int _plays = 0;

  /// The overlays added as files (`assets/effects/NAME.webp`, an animated WebP with transparency): one of these
  /// plays in place of the effect drawn here. See docs/effects.md.
  static Set<String>? _overlays;

  @override
  void initState() {
    super.initState();
    if (_overlays == null) {
      AssetManifest.loadFromAssetBundle(rootBundle).then((m) {
        _overlays = m.listAssets().where((a) => a.startsWith('assets/effects/') && a.endsWith('.webp')).toSet();
      }).catchError((_) {
        _overlays = const {};
      });
    }
  }

  /// Plays [effect] once, from its start (over one already playing). [text] is the message's words, for echo.
  void play(ScreenEffect effect, {String text = ''}) {
    if (!mounted) return;
    // Nothing plays for someone who has asked the system for less motion.
    if (MediaQuery.disableAnimationsOf(context)) return;
    final play = ++_plays;
    EffectSprites.of(effect).then((sprites) {
      if (mounted && play == _plays) _start(effect, text, sprites);
    });
  }

  void _start(ScreenEffect effect, String text, EffectSprites? sprites) {
    setState(() {
      _effect = effect;
      _text = text;
      _sprites = sprites;
      _seed = DateTime.now().microsecondsSinceEpoch & 0xFFFF;
    });
    _run
      ..duration = effectDuration(effect)
      ..forward(from: 0).whenCompleteOrCancel(() {
        if (mounted && _run.status == AnimationStatus.completed) setState(() => _effect = null);
      });
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effect = _effect;
    if (effect == null) return const SizedBox.shrink();
    final overlay = 'assets/effects/${effect.name}.webp';
    if (_overlays?.contains(overlay) ?? false) {
      // Keyed by the play, so the animation starts from its first frame each time; it leaves with the same fade.
      return IgnorePointer(
        child: FadeTransition(
          opacity: _run.drive(TweenSequence([TweenSequenceItem(tween: ConstantTween(1.0), weight: 88), TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 12)])),
          child: Image.asset(overlay, key: ValueKey(_seed), fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: false),
        ),
      );
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(size: Size.infinite, painter: EffectPainter(effect, _run, _seed, style: widget.style, text: _text, sprites: _sprites)),
      ),
    );
  }
}

/// The colours of confetti, balloons and fireworks, and the warmer ones of the celebration's bursts.
const _bright = [Color(0xFFFF5A5F), Color(0xFFFFB400), Color(0xFF00C2A8), Color(0xFF4F5BD5), Color(0xFFB5279F), Color(0xFF2A9D4B), Color(0xFF4CC9F0)];
const _gold = [Color(0xFFFFD166), Color(0xFFFFB400), Color(0xFFFF8C42), Color(0xFFFFF1B8), Color(0xFFE63946)];

/// One effect at a moment of its run. Every particle's path is a function of the time and a seed, so a frame is
/// the same however often it is drawn, and nothing is kept between frames but the laid-out glyphs.
class EffectPainter extends CustomPainter {
  EffectPainter(this.effect, this.t, this.seed, {this.style = const TextStyle(), this.text = '', this.sprites}) : super(repaint: t);
  final ScreenEffect effect;

  /// How far through its run the effect is, 0 to 1.
  final Animation<double> t;
  final int seed;
  final TextStyle style;
  final String text;

  /// The effect's own pictures, moved in place of the emoji and shapes drawn without them.
  final EffectSprites? sprites;

  final _glyphs = <String, TextPainter>{};

  /// [glyph] laid out once at 40px; drawn at other sizes by scaling.
  TextPainter _glyph(String glyph, {Color? color, double size = 40}) => _glyphs['$glyph $size ${color?.toARGB32()}'] ??= (TextPainter(
      text: TextSpan(text: glyph, style: style.copyWith(fontSize: size, height: 1.1, color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout());

  @override
  void paint(Canvas canvas, Size size) {
    final time = t.value;
    // Everything leaves in the last tenth, whatever it was doing.
    final fade = time > 0.88 ? ((1 - time) / 0.12).clamp(0.0, 1.0) : 1.0;
    // Seeded afresh each frame and asked in the same order, so each particle draws the same numbers every time.
    final r = math.Random(seed);
    final pictures = sprites;
    final plan = _spritePlans[effect];
    if (pictures != null && plan != null) {
      // What only the app can draw stays, under the pictures: the light, and the message's own words.
      switch (effect) {
        case ScreenEffect.fireworks:
          _fireworks(canvas, size, time, fade, r, _bright, 7);
        case ScreenEffect.celebration:
          _fireworks(canvas, size, time, fade, r, _gold, 12);
        case ScreenEffect.lasers:
          _lasers(canvas, size, time, fade, r);
        case ScreenEffect.echo:
          _echo(canvas, size, time, fade, r);
        case ScreenEffect.spotlight:
          _spotlight(canvas, size, time);
        default:
          break;
      }
      final small = plan.small;
      final seconds = time * _durations[effect]! / 1000;
      _spriteFlight(canvas, size, time, seconds, fade, math.Random(seed ^ 0x5bd1), pictures.props, plan.props, plan.propCount, small ? 16 : 34, small ? 34 : 62, spin: small ? 1.6 : 0.3);
      _spriteFlight(canvas, size, time, seconds, fade, math.Random(seed ^ 0x2f6b), pictures.heroes, plan.heroes, plan.heroCount, 96, 148, speed: 0.72, spin: 0.14);
      return;
    }
    // Without pictures: the effects made of emoji in flight, then those drawn as shapes.
    final flight = _flights[effect];
    if (flight != null) {
      _emojiFlight(canvas, size, time, fade, r, flight.$1, flight.$2, flight.$3);
      return;
    }
    switch (effect) {
      case ScreenEffect.confetti:
        _confetti(canvas, size, time, fade, r);
      case ScreenEffect.balloons:
        _balloons(canvas, size, time, fade, r);
      case ScreenEffect.fireworks:
        _fireworks(canvas, size, time, fade, r, _bright, 7);
      case ScreenEffect.celebration:
        _fireworks(canvas, size, time, fade, r, _gold, 12);
      case ScreenEffect.hearts:
        _hearts(canvas, size, time, fade, r);
      case ScreenEffect.snow:
        _snow(canvas, size, time, fade, r);
      case ScreenEffect.lasers:
        _lasers(canvas, size, time, fade, r);
      case ScreenEffect.ghosts:
        _ghosts(canvas, size, time, fade, r);
      case ScreenEffect.echo:
        _echo(canvas, size, time, fade, r);
      case ScreenEffect.spotlight:
        _spotlight(canvas, size, time);
      default:
        break;
    }
  }

  /// The effect's pictures rising like bubbles, falling like petals, or thrown out from the middle: [count] of
  /// them, each one of [images] in turn, from [smallest] to [largest] across.
  void _spriteFlight(Canvas canvas, Size size, double time, double seconds, double fade, math.Random r, List<EffectSprite> images, _Flight flight, int count, double smallest, double largest, {double speed = 1, double spin = 0.3}) {
    if (images.isEmpty) return;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    for (var i = 0; i < count; i++) {
      // Every random number is drawn before any picture is skipped, so the ones after it keep their paths.
      final x0 = 0.07 + r.nextDouble() * 0.86;
      final delay = r.nextDouble() * 0.4;
      final rate = (0.8 + r.nextDouble() * 0.6) * speed;
      final s = smallest + r.nextDouble() * (largest - smallest);
      final phase = r.nextDouble() * math.pi * 2;
      final angle = r.nextDouble() * math.pi * 2;
      final reach = (0.25 + r.nextDouble() * 0.55) * size.height * 0.6;
      final image = images[i % images.length];
      // How far along its own path this one is: it sets off after its delay (a burst's are a quarter as long).
      final p = (time - (flight == _Flight.burst ? delay * 0.25 : delay)) * rate;
      if (p <= 0) continue;
      double x, y, alpha = fade, scale = 1;
      switch (flight) {
        case _Flight.rise:
          y = size.height + s - p * (size.height + s * 3) * 1.15;
          x = x0 * size.width + math.sin(phase + p * 7) * 18;
          alpha *= (1 - p * 0.25).clamp(0.0, 1.0);
        case _Flight.fall:
          y = -s + p * (size.height + s * 3) * 1.1;
          x = x0 * size.width + math.sin(phase + p * 6) * 22;
        case _Flight.burst:
          final out = Curves.easeOutCubic.transform((p * 1.6).clamp(0.0, 1.0));
          x = size.width / 2 + math.cos(angle) * reach * out;
          y = size.height * 0.5 + math.sin(angle) * reach * out;
          scale = 0.4 + out * 0.9;
          alpha *= (1.2 - p * 1.1).clamp(0.0, 1.0);
      }
      if (y < -s * 2 || y > size.height + s * 2 || alpha <= 0) continue;
      final w = image.width;
      final h = image.height;
      final k = s * scale / math.max(w, h);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(math.sin(phase + p * 5) * spin);
      paint.color = Color.fromRGBO(255, 255, 255, alpha);
      // A moving character shows the drawing its time has come to; each starts on a drawing of its own.
      canvas.drawImageRect(image.image, image.at(seconds, i * 2), Rect.fromCenter(center: Offset.zero, width: w * k, height: h * k), paint);
      canvas.restore();
    }
  }

  /// Emoji rising like bubbles, falling like petals, or thrown out from the middle.
  void _emojiFlight(Canvas canvas, Size size, double time, double fade, math.Random r, List<String> glyphs, _Flight flight, int count) {
    for (var i = 0; i < count; i++) {
      final x0 = 0.05 + r.nextDouble() * 0.9;
      final delay = r.nextDouble() * 0.4;
      final speed = 0.8 + r.nextDouble() * 0.6;
      final s = 26 + r.nextDouble() * 30;
      final phase = r.nextDouble() * math.pi * 2;
      final angle = r.nextDouble() * math.pi * 2;
      final glyph = glyphs[i % glyphs.length];
      final p = (time - (flight == _Flight.burst ? delay * 0.25 : delay)) * speed;
      if (p <= 0) continue;
      double x, y, alpha = fade, scale = s / 40;
      switch (flight) {
        case _Flight.rise:
          y = size.height + s - p * (size.height + s * 4) * 1.15;
          x = x0 * size.width + math.sin(phase + p * 7) * 18;
          alpha *= (1 - p * 0.3).clamp(0.0, 1.0);
        case _Flight.fall:
          y = -s + p * (size.height + s * 3) * 1.1;
          x = x0 * size.width + math.sin(phase + p * 6) * 22;
        case _Flight.burst:
          final out = Curves.easeOutCubic.transform((p * 1.6).clamp(0.0, 1.0));
          final reach = (0.25 + r.nextDouble() * 0.55) * size.height * 0.6;
          x = size.width / 2 + math.cos(angle) * reach * out;
          y = size.height * 0.5 + math.sin(angle) * reach * out;
          scale *= 0.4 + out * 0.9;
          alpha *= (1.2 - p * 1.1).clamp(0.0, 1.0);
      }
      if (y < -s * 2 || y > size.height + s * 2 || alpha <= 0) continue;
      final tp = _glyph(glyph);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(math.sin(phase + p * 5) * 0.3);
      canvas.scale(scale);
      // A colour emoji takes no opacity from its text style: a fading one is drawn into a layer that has it.
      if (alpha < 0.999) {
        canvas.saveLayer(Rect.fromLTWH(-tp.width, -tp.height, tp.width * 2, tp.height * 2), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
        canvas.restore();
      } else {
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      }
      canvas.restore();
    }
  }

  /// Small coloured pieces falling from the top, swaying and turning as they go.
  void _confetti(Canvas canvas, Size size, double time, double fade, math.Random r) {
    for (var i = 0; i < 140; i++) {
      final x0 = r.nextDouble();
      final delay = r.nextDouble() * 0.35;
      final speed = 0.9 + r.nextDouble() * 0.8;
      final sway = 10 + r.nextDouble() * 26;
      final phase = r.nextDouble() * math.pi * 2;
      final spin = (r.nextDouble() - 0.5) * 16;
      final w = 6 + r.nextDouble() * 6;
      final color = _bright[r.nextInt(_bright.length)];
      final p = (time - delay) * speed;
      if (p <= 0) continue;
      final y = -20 + p * (size.height + 60) * 1.25;
      if (y > size.height + 20) continue;
      final x = x0 * size.width + math.sin(phase + p * 9) * sway;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(phase + p * spin);
      // A piece turning shows its edge: its height narrows and widens.
      final flip = math.cos(phase * 2 + p * 14).abs();
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: w, height: w * 0.45 + w * 0.6 * flip), Paint()..color = color.withValues(alpha: fade));
      canvas.restore();
    }
  }

  /// Balloons rising from the foot of the page, each with its knot, its string and the light on it.
  void _balloons(Canvas canvas, Size size, double time, double fade, math.Random r) {
    for (var i = 0; i < 16; i++) {
      final x0 = 0.06 + r.nextDouble() * 0.88;
      final delay = r.nextDouble() * 0.4;
      final speed = 0.9 + r.nextDouble() * 0.5;
      final radius = 24 + r.nextDouble() * 16;
      final phase = r.nextDouble() * math.pi * 2;
      final color = _bright[r.nextInt(_bright.length)];
      final p = (time - delay) * speed;
      if (p <= 0) continue;
      final y = size.height + radius * 2 - p * (size.height + radius * 6) * 1.2;
      final x = x0 * size.width + math.sin(phase + p * 6) * 14;
      final body = Rect.fromCenter(center: Offset(x, y), width: radius * 1.7, height: radius * 2.1);
      final string = Path()
        ..moveTo(x, body.bottom + 5)
        ..quadraticBezierTo(x + math.sin(phase + p * 10) * 8, body.bottom + radius, x, body.bottom + radius * 2);
      canvas.drawPath(string, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = const Color(0xFF9A9AA2).withValues(alpha: 0.8 * fade));
      canvas.drawOval(body, Paint()..color = color.withValues(alpha: 0.92 * fade));
      canvas.drawPath(Path()..moveTo(x - 5, body.bottom + 6)..lineTo(x + 5, body.bottom + 6)..lineTo(x, body.bottom - 2)..close(), Paint()..color = color.withValues(alpha: 0.92 * fade));
      // The light on it.
      canvas.drawOval(Rect.fromCenter(center: Offset(x - radius * 0.32, y - radius * 0.42), width: radius * 0.34, height: radius * 0.52), Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.35 * fade));
    }
  }

  /// [bursts] bursts in the upper part of the page, one after another over the first three quarters of the run.
  /// Each lasts a third of the run: a flash, then sparks thrown out that sink and fade.
  void _fireworks(Canvas canvas, Size size, double time, double fade, math.Random r, List<Color> colors, int bursts) {
    for (var b = 0; b < bursts; b++) {
      final cx = (0.15 + r.nextDouble() * 0.7) * size.width;
      final cy = (0.12 + r.nextDouble() * 0.45) * size.height;
      final start = b * (0.72 / bursts) + r.nextDouble() * 0.05;
      final color = colors[r.nextInt(colors.length)];
      final reach = (0.16 + r.nextDouble() * 0.12) * size.width;
      final sparks = 26 + r.nextInt(10);
      final angles = [for (var s = 0; s < sparks; s++) (s / sparks) * math.pi * 2 + r.nextDouble() * 0.2];
      final lengths = [for (var s = 0; s < sparks; s++) 0.7 + r.nextDouble() * 0.5];
      final p = (time - start) / 0.34;
      if (p <= 0 || p >= 1) continue;
      final out = Curves.easeOutCubic.transform(p);
      final alpha = (1 - Curves.easeIn.transform(p)) * fade;
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round;
      for (var s = 0; s < sparks; s++) {
        final d = reach * lengths[s];
        final head = Offset(cx + math.cos(angles[s]) * d * out, cy + math.sin(angles[s]) * d * out + p * p * 46);
        final tail = Offset(cx + math.cos(angles[s]) * d * out * 0.78, cy + math.sin(angles[s]) * d * out * 0.78 + p * p * 36);
        canvas.drawLine(tail, head, paint);
      }
      if (p < 0.12) canvas.drawCircle(Offset(cx, cy), 14 * (1 - p / 0.12) + 2, Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.8 * fade));
    }
  }

  /// A heart about twice [s] wide, around the origin.
  static Path _heart(double s) => Path()
    ..moveTo(0, s * 0.35)
    ..cubicTo(-s * 1.1, -s * 0.35, -s * 0.45, -s * 1.0, 0, -s * 0.42)
    ..cubicTo(s * 0.45, -s * 1.0, s * 1.1, -s * 0.35, 0, s * 0.35)
    ..close();

  /// Hearts that pop up to their size and rise, fading as they go.
  void _hearts(Canvas canvas, Size size, double time, double fade, math.Random r) {
    const reds = [Color(0xFFFF3B5C), Color(0xFFFF6B8B), Color(0xFFE0245E), Color(0xFFFF8FA3)];
    for (var i = 0; i < 30; i++) {
      final x0 = 0.05 + r.nextDouble() * 0.9;
      final delay = r.nextDouble() * 0.45;
      final speed = 0.8 + r.nextDouble() * 0.7;
      final s = 14 + r.nextDouble() * 22;
      final phase = r.nextDouble() * math.pi * 2;
      final color = reds[r.nextInt(reds.length)];
      final p = (time - delay) * speed;
      if (p <= 0) continue;
      final y = size.height + s - p * (size.height + s * 4) * 1.15;
      final x = x0 * size.width + math.sin(phase + p * 7) * 18;
      final grow = Curves.easeOutBack.transform((p * 5).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(math.sin(phase + p * 5) * 0.25);
      canvas.scale(grow);
      canvas.drawPath(_heart(s), Paint()..color = color.withValues(alpha: (0.9 - p * 0.35).clamp(0.0, 1.0) * fade));
      canvas.restore();
    }
  }

  /// Flakes already spread over the whole page as it starts, falling and coming round again from the top.
  void _snow(Canvas canvas, Size size, double time, double fade, math.Random r) {
    for (var i = 0; i < 110; i++) {
      final x0 = r.nextDouble();
      final y0 = r.nextDouble();
      final speed = 0.5 + r.nextDouble() * 0.7;
      final radius = 1.5 + r.nextDouble() * 3.2;
      final phase = r.nextDouble() * math.pi * 2;
      final y = ((y0 + time * speed * 1.4) % 1.0) * (size.height + 20) - 10;
      final x = x0 * size.width + math.sin(phase + time * 8 * speed) * 16;
      final arrive = (time / 0.08).clamp(0.0, 1.0);
      // Grey-blue with a white heart, so a flake shows on a light page as well as a dark one.
      canvas.drawCircle(Offset(x, y), radius + 0.8, Paint()..color = const Color(0xFF9DB4D6).withValues(alpha: 0.55 * fade * arrive));
      canvas.drawCircle(Offset(x, y), radius, Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.95 * fade * arrive));
    }
  }

  /// Twelve beams from above the middle of the top edge, swinging and flickering: each a wide glow under a thin line.
  void _lasers(Canvas canvas, Size size, double time, double fade, math.Random r) {
    final origin = Offset(size.width / 2, -10);
    const colors = [Color(0xFF39FF14), Color(0xFFFF2BD6), Color(0xFF2BD9FF), Color(0xFFFFE600)];
    for (var i = 0; i < 12; i++) {
      final base = math.pi / 2 + (r.nextDouble() - 0.5) * 1.6;
      final swing = 0.35 + r.nextDouble() * 0.5;
      final rate = 3 + r.nextDouble() * 5;
      final phase = r.nextDouble() * math.pi * 2;
      final color = colors[i % colors.length];
      final angle = base + math.sin(phase + time * rate * math.pi) * swing;
      final end = origin + Offset(math.cos(angle), math.sin(angle)) * (size.height * 1.4);
      final pulse = 0.55 + 0.45 * math.sin(phase + time * 40).abs();
      canvas.drawLine(origin, end, Paint()..color = color.withValues(alpha: 0.16 * fade * pulse)..strokeWidth = 10..strokeCap = StrokeCap.round);
      canvas.drawLine(origin, end, Paint()..color = color.withValues(alpha: 0.85 * fade * pulse)..strokeWidth = 2.2..strokeCap = StrokeCap.round);
    }
  }

  /// A ghost about [s] wide: a round head, straight sides, a hem of three scallops, two eyes.
  static Path _ghost(double s) {
    final w = s / 2;
    final h = s * 0.62;
    return Path()
      ..moveTo(-w, h)
      ..lineTo(-w, -h + w)
      ..arcToPoint(Offset(w, -h + w), radius: Radius.circular(w))
      ..lineTo(w, h)
      ..quadraticBezierTo(w * 0.66, h - s * 0.2, w * 0.33, h)
      ..quadraticBezierTo(0, h - s * 0.2, -w * 0.33, h)
      ..quadraticBezierTo(-w * 0.66, h - s * 0.2, -w, h)
      ..close();
  }

  /// Drawn ghosts drifting up the page, rocking a little: what plays where the effect has no pictures.
  void _ghosts(Canvas canvas, Size size, double time, double fade, math.Random r) {
    for (var i = 0; i < 14; i++) {
      final x0 = 0.08 + r.nextDouble() * 0.84;
      final delay = r.nextDouble() * 0.4;
      final speed = 0.8 + r.nextDouble() * 0.5;
      final s = 34 + r.nextDouble() * 34;
      final phase = r.nextDouble() * math.pi * 2;
      final p = (time - delay) * speed;
      if (p <= 0) continue;
      final y = size.height + s - p * (size.height + s * 4) * 1.15;
      final x = x0 * size.width + math.sin(phase + p * 6) * 22;
      final alpha = (0.92 - p * 0.3).clamp(0.0, 1.0) * fade;
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(math.sin(phase + p * 6) * 0.14);
      final body = _ghost(s);
      // A cool edge so a white ghost shows on a light page, then the ghost, then its eyes.
      canvas.drawPath(body, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = const Color(0xFF8C95FF).withValues(alpha: 0.55 * alpha));
      canvas.drawPath(body, Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: alpha));
      final eye = Paint()..color = const Color(0xFF1C1C22).withValues(alpha: alpha);
      canvas.drawOval(Rect.fromCenter(center: Offset(-s * 0.16, -s * 0.12), width: s * 0.13, height: s * 0.19), eye);
      canvas.drawOval(Rect.fromCenter(center: Offset(s * 0.16, -s * 0.12), width: s * 0.13, height: s * 0.19), eye);
      canvas.restore();
    }
  }

  /// The message's own words, many times over, rising past at every size: the iPhone's Echo.
  void _echo(Canvas canvas, Size size, double time, double fade, math.Random r) {
    var words = text.trim().replaceAll('\n', ' ');
    if (words.isEmpty) words = '👻';
    if (words.characters.length > 28) words = '${words.characters.take(28)}…';
    final ink = style.color ?? const Color(0xFF111111);
    for (var i = 0; i < 26; i++) {
      final x0 = r.nextDouble();
      final delay = r.nextDouble() * 0.45;
      final speed = 0.8 + r.nextDouble() * 0.7;
      final s = 0.35 + r.nextDouble() * 1.1;
      final p = (time - delay) * speed;
      if (p <= 0) continue;
      final tp = _glyph(words, color: ink, size: 26);
      final y = size.height + 40 - p * (size.height + 160) * 1.2;
      final x = x0 * (size.width + tp.width * s) - tp.width * s;
      final alpha = ((0.25 + s * 0.45) * fade * (1 - p * 0.3)).clamp(0.0, 1.0);
      canvas.save();
      canvas.translate(x, y);
      canvas.scale(s);
      canvas.saveLayer(Rect.fromLTWH(0, 0, tp.width, tp.height), Paint()..color = Color.fromRGBO(0, 0, 0, alpha));
      tp.paint(canvas, Offset.zero);
      canvas.restore();
      canvas.restore();
    }
  }

  /// The page goes dark but for a round light low in the conversation, where the newest message is: Spotlight.
  void _spotlight(Canvas canvas, Size size, double time) {
    // The dark comes over the first 15% of the run and goes over the last 20%.
    final env = time < 0.15 ? time / 0.15 : (time > 0.8 ? ((1 - time) / 0.2).clamp(0.0, 1.0) : 1.0);
    final centre = Offset(size.width * 0.5, size.height * 0.78);
    final radius = size.width * (0.46 + 0.03 * math.sin(time * math.pi * 4));
    // The dark is drawn in a layer of its own and the light cut out of it, soft at its edge.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF000000).withValues(alpha: 0.78 * env));
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..shader = RadialGradient(colors: const [Color(0xFF000000), Color(0xFF000000), Color(0x00000000)], stops: const [0, 0.72, 1]).createShader(Rect.fromCircle(center: centre, radius: radius)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(EffectPainter old) => old.effect != effect || old.seed != seed;
}

/// A bubble arriving the way the iPhone sent it: slammed down, loud, or gentle. Plays once when [play] is true as it
/// is first built; otherwise the bubble simply stands.
class BubbleEntrance extends StatefulWidget {
  const BubbleEntrance({super.key, required this.effect, required this.play, required this.child});
  final BubbleEffect effect;
  final bool play;
  final Widget child;

  @override
  State<BubbleEntrance> createState() => _BubbleEntranceState();
}

class _BubbleEntranceState extends State<BubbleEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.play) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !MediaQuery.disableAnimationsOf(context)) _c.forward(from: 0);
      });
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _c.value;
        double scale = 1, turn = 0;
        switch (widget.effect) {
          case BubbleEffect.slam:
            // From large, down hard, with a shudder as it lands.
            scale = t < 0.35 ? 2.4 - 1.5 * Curves.easeIn.transform(t / 0.35) : 1 - 0.1 * math.sin((t - 0.35) / 0.65 * math.pi * 3) * (1 - t);
            turn = t < 0.35 ? -0.12 * (1 - t / 0.35) : 0;
          case BubbleEffect.loud:
            // Swells and shakes, then settles.
            scale = 1 + 0.55 * math.sin(t * math.pi) * (1 - t * 0.2);
            turn = 0.05 * math.sin(t * math.pi * 10) * (1 - t);
          case BubbleEffect.gentle:
            // Arrives small and grows slowly to its size.
            scale = 0.45 + 0.55 * Curves.easeOut.transform(t);
          case BubbleEffect.invisibleInk:
            // Has no entrance: the bubble stands as it is.
            break;
        }
        return Transform.rotate(angle: turn, child: Transform.scale(scale: scale, child: child));
      },
    );
  }
}

/// An effect's name as Settings and the menus say it.
String effectLabel(ScreenEffect e) => switch (e) {
      ScreenEffect.confetti => 'Confetti',
      ScreenEffect.balloons => 'Balloons',
      ScreenEffect.fireworks => 'Fireworks',
      ScreenEffect.celebration => 'Celebration',
      ScreenEffect.hearts => 'Hearts',
      ScreenEffect.kisses => 'Kisses',
      ScreenEffect.snow => 'Snow',
      ScreenEffect.lasers => 'Lasers',
      ScreenEffect.ghosts => 'Ghosts',
      ScreenEffect.wow => 'Wow',
      ScreenEffect.thanks => 'Thank you',
      ScreenEffect.goodNight => 'Good night',
      ScreenEffect.goodMorning => 'Good morning',
      ScreenEffect.getWell => 'Get well soon',
      ScreenEffect.bye => 'Bye bye',
      ScreenEffect.hungry => 'Hungry',
      ScreenEffect.sorry => 'Sorry',
      ScreenEffect.party => 'Party time',
      ScreenEffect.echo => 'Echo',
      ScreenEffect.spotlight => 'Spotlight',
    };

/// What sets [e] off, in a line: its first words and its emoji.
String effectTriggers(ScreenEffect e) {
  final words = (_phrases[e] ?? const <String>[]).take(2).map((p) => '"$p"');
  final emoji = (_emoji[e] ?? const <String>[]).take(3).join(' ');
  if (words.isEmpty && emoji.isEmpty) return 'From an iPhone\'s "sent with ${effectLabel(e)}"';
  return [words.join(', '), emoji].where((x) => x.isNotEmpty).join('  ');
}
