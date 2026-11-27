/// A circle drawn as its list, the one way a circle is drawn (Matt, 2026-11-17: "Lets remove the other views and focus
/// on the list view / layout it's the most practical of them all so far"): its face, name and who is on at the top,
/// then its spaces under their headings, each with its kind's mark in the kind's colour, a line of what is going on in
/// it (who is talking, how many files, the newest message), its unread count, and New space at the foot.
///
/// It is the circle's sidebar on a computer and an unfolded Fold, and the whole page on a phone, where a space opens
/// over it ([CircleView.wide] says which). It draws in every look (lib/looks.dart), Dial-Up's bevels among them, light
/// and dark, through the app's tokens.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../../art/app_icon.dart';
import '../../circles/circle.dart';
import '../../files/files_store.dart';
import '../../art/lucide.g.dart';
import '../../art/lucide_more.dart';
import '../../kit/semantic_colors.dart';
import '../../kit/settings_type.dart';
import '../../sms.dart' show Person, Sms;
import '../../voice/channels.dart' show Voice;
import '../../voice/spotify.dart' show SpotifyMusic;
import '../../voice/voice.dart';
import '../common.dart';
import '../dialup/bevel.dart';
import '../dialup/parts.dart' show VoiceFace, voiceCorner;
import '../flat_line.dart' show pictureOfSpace;
import '../hangout_screen.dart' show SpaceFace, SpacePicture;
import '../ripple_avatar.dart';
import '../space_designs/space_design.dart' show callLevels;
import '../spotify_panel.dart' show SongCover;
import '../shell.dart';
import 'circle_face.dart';
import 'circle_view.dart';
import 'new_circle.dart' show circleHueInk;
import '../../kit/picture_decode.dart';

/// [view] as the circle's page: [CirclePage] round its [CircleSpaceList].
class CircleList extends StatelessWidget {
  const CircleList({super.key, required this.view});
  final CircleView view;

  @override
  Widget build(BuildContext context) => CirclePage(view: view, body: CircleSpaceList(view: view));
}

/// A circle's page: the way back, its face and name (a press opens its menu), Invite and its settings, and [body]
/// under them. Dial-Up's
/// window draws its own title bar from it.
class CirclePage extends StatefulWidget {
  const CirclePage({super.key, required this.view, required this.body});
  final CircleView view;
  final Widget body;

  @override
  State<CirclePage> createState() => _CirclePageState();
}

class _CirclePageState extends State<CirclePage> {
  /// How far the list under the header is scrolled: the banner gives up that much of its height below the header,
  /// as it goes (Matt, 2026-11-19: "When scrolling up in a sidebar collapse the header background image to only take
  /// up the space where the header text and avatar is at the same time as we scroll").
  final _scrolled = ValueNotifier<double>(0);

  @override
  void dispose() {
    _scrolled.dispose();
    super.dispose();
  }

  // Never below zero: an overscroll past the top is not a scroll.
  void _follow(ScrollMetrics m) => _scrolled.value = m.pixels.clamp(0, double.infinity);

  @override
  Widget build(BuildContext context) {
    // Made once: the list keeps its place while the header above it changes height. The list's own scrolling (not a
    // row's, nor a sideways one inside it), and where it is put back without scrolling: a short list snaps back to its
    // top as the header grows or shrinks, and the banner would have stayed as small as it was.
    final body = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        if (n.depth == 0 && n.metrics.axis == Axis.vertical) _follow(n.metrics);
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.depth == 0 && n.metrics.axis == Axis.vertical) _follow(n.metrics);
          return false;
        },
        child: widget.body,
      ),
    );
    return ValueListenableBuilder<double>(valueListenable: _scrolled, builder: (context, scrolled, _) => _page(context, body, scrolled));
  }

  Widget _page(BuildContext context, Widget body, double scrolled) {
    final view = widget.view;
    final t = context.tokens;
    final c = view.circle;
    final live = view.live.fold(0, (n, s) => n + s.inVoice.length);
    // Over its banner's picture the header is white, shaded so it reads on any picture; over its colour, the page's ink.
    final pictured = !isBevelChrome(t) && c.banner != null;
    final ink = pictured ? const Color(0xFFFFFFFF) : t.color('app-ink');
    final ink2 = pictured ? const Color(0xE6FFFFFF) : t.color('app-ink-3');
    const shade = [Shadow(color: Color(0x99000000), blurRadius: 6)];
    final line = [
      '${view.spaces.length} ${view.spaces.length == 1 ? 'space' : 'spaces'}',
      if (view.online > 0) '${view.online} on now',
      if (live > 0) '$live talking',
    ].join(' · ');
    return GhostPage(
      title: c.name,
      subtitle: line,
      onTitle: view.onMenu,
      onBack: view.onBack,
      titleLeading: TitleBarMark(icon: circleIconOf(c.icon), child: CircleFace.of(c, size: 18)),
      titleWidget: GlacierPressable(
        onPressed: view.onMenu,
        semanticLabel: '${c.name}, $line, options',
        builder: (context, _) => Row(children: [
          // Larger beside its name (Matt, 2026-11-19: "make the circle profile picture larger").
          // As the bar is tall less a margin, so it sits inside the banner wherever the bar is shorter (the Mac's).
          CircleFace.of(c, size: t.lenOf('2.75rem')),
          SizedBox(width: t.space(3)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Flexible(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: ink).copyWith(shadows: pictured ? shade : null))),
                // A little room between the name and its chevron (Matt, 2026-11-19: "add a bit of gap between the title
                // and the down chevron").
                SizedBox(width: t.space(1) + 2),
                AppIcon(Lucide.chevronDown, size: 16, color: pictured ? ink : t.color('app-ink-2')),
              ]),
              Text(line, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: ink2).copyWith(shadows: pictured ? shade : null)),
            ]),
          ),
        ]),
      ),
      // Nothing beside the name: the circle's settings are the dock's, and adding people is the Members drawer's (Matt,
      // 2026-11-18: "remove the add user from the header next to the circle header and in the dock and simply leave it
      // under the users drawer").
      // A banner across the top of its sidebar, as a Discord server has (Matt, 2026-11-19: "make circles have a
      // background image for the header like discord does"): its own picture where it has one, else its colour. Dial-Up
      // draws its window plain.
      // Behind the header itself, the back arrow, its face and name inside it (Matt, 2026-11-19: "the background image
      // for the header of circles needs to be taller and the back arrow and other header content should render inside the
      // background image not above it").
      headerBackground: isBevelChrome(t) ? null : CircleBanner(circle: c, onPress: view.onMenu),
      // Taller at the top of the list; scrolled, down to the header row alone with as much room under it as over it
      // (the banner's own margin and the row's), a point for each point scrolled.
      headerExtra: math.max(t.space(2) * 2, math.max(t.space(2) * 2, t.lenOf(pictured ? '5rem' : '0.75rem')) - scrolled),
      headerInk: ink,
      body: body,
    );
  }
}

/// A circle's banner behind the top of its page (GhostPage.headerBackground), under the phone's status bar: its
/// picture, a little in from the edges with rounded corners, shaded at the top and the foot so the header and the list read on it; or a wash of its colour. A press
/// opens the circle's menu.
class CircleBanner extends StatefulWidget {
  const CircleBanner({super.key, required this.circle, this.onPress});
  final Circle circle;
  final VoidCallback? onPress;

  @override
  State<CircleBanner> createState() => _CircleBannerState();
}

class _CircleBannerState extends State<CircleBanner> {
  /// The full picture on this device, once it is here (Circle.bannerFile).
  String? _full;
  String? _asked;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(CircleBanner old) {
    super.didUpdateWidget(old);
    _fetch();
  }

  /// Brings the full picture down once, where the circle has one and it isn't here yet; the stand-in shows meanwhile.
  /// A page in a browser keeps no files (Files is not in a page): the stand-in, which came with the circle, is its
  /// picture there.
  void _fetch() {
    final c = widget.circle;
    final j = c.manifest.bannerFile;
    final f = j == null || Sms.browser ? null : SpaceFile.fromJson(j, by: c.manifest.by ?? '');
    if (f == null) {
      _full = null;
      return;
    }
    final have = FilesStore.instance.cached(f);
    if (have != null) {
      _full = have;
      return;
    }
    if (_asked == f.id) return;
    _asked = f.id;
    FilesStore.instance.fetch(c.bannerChannel, f).then((path) {
      if (mounted && _asked == f.id) setState(() => _full = path);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final circle = widget.circle;
    final hue = circleHueInk(t, circle.hue);
    Widget? image;
    final b = circle.banner;
    final full = _full;
    if (full != null) {
      image = Image.file(File(full), fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, cacheWidth: fillDecodeWidth(context), errorBuilder: (_, _, _) => const SizedBox.shrink());
    } else if (b != null) {
      final bytes = pictureBytes(b);
      if (bytes != null) image = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, filterQuality: FilterQuality.medium, cacheWidth: fillDecodeWidth(context));
    }
    // Set in from the edges with rounded corners, not edge to edge (Matt, 2026-11-19: "add just a bit of margin around
    // the sidebar banner header and add some border radius to them so it's not edge to edge").
    return Padding(
      key: const ValueKey('circle-banner-inset'),
      padding: EdgeInsets.all(t.space(2)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.radius('lg')),
        child: GestureDetector(
          key: const ValueKey('circle-banner-strip'),
          onTap: widget.onPress,
          child: image == null
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(begin: AlignmentDirectional.topStart, end: AlignmentDirectional.bottomEnd, colors: [hue.withValues(alpha: 0.45), hue.withValues(alpha: 0.12)]),
                  ),
                )
              : Stack(fit: StackFit.expand, clipBehavior: Clip.hardEdge, children: [
                  image,
                  // Behind the header's words a blur that fades out downward (Matt, 2026-11-19: "add a blur gradient with a
                  // subtle black gradient behind the text on the banner header image on circles"): the picture again,
                  // blurred, shown fully at the top where the name is and not at all past the middle, so the rest stays
                  // sharp.
                  ShaderMask(
                    key: const ValueKey('circle-banner-blur'),
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (r) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF000000), Color(0xCC000000), Color(0x00000000)],
                      stops: [0, 0.35, 0.65],
                    ).createShader(r),
                    // Clipped to the banner: a blur draws past its own edges, and spilled over the list's first row.
                    child: ClipRect(child: ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: TileMode.mirror), child: image)),
                  ),
                  // And a subtle black under the words, gone by the middle; a touch at the foot against the list.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x73000000), Color(0x33000000), Color(0x00000000), Color(0x26000000)],
                        stops: [0, 0.4, 0.68, 1],
                      ),
                    ),
                  ),
                ]),
        ),
      ),
    );
  }
}

/// A circle's spaces under their headings, with New space at the foot where this device may add one.
class CircleSpaceList extends StatelessWidget {
  const CircleSpaceList({super.key, required this.view});
  final CircleView view;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    // Under Dial-Up the well ends above the taskbar, so the list needs no room of its own for it.
    final foot = AppShell.pillRoom(context) + MediaQuery.paddingOf(context).bottom;
    final list = ListView(
      padding: EdgeInsets.only(top: t.space(2), bottom: bevel ? t.space(2) : foot + t.space(4)),
      children: [
        for (final g in view.sections) ...[
          if (g.name != null) CircleSectionHeading(name: g.name!, onAdd: view.canEdit ? () => view.onNewSpace(section: g.name) : null),
          for (final s in g.spaces) ...[
            CircleSpaceTile(space: s, selected: s.seed == view.selected, onPress: () => view.onOpen(s), onLongPress: view.onSpaceMenu == null ? null : () => view.onSpaceMenu!(s)),
            // Who is in its call, each a row under it.
            if (s.people.isNotEmpty || s.music != null) CircleVoicePeople(space: s, onPress: () => view.onOpen(s)),
          ],
        ],
        if (view.spaces.isEmpty)
          Padding(
            padding: EdgeInsets.all(t.space(6)),
            child: Text(view.canEdit ? 'No spaces yet. Add one for chat and voice, texting or files.' : 'No spaces yet.', textAlign: TextAlign.center, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ),
        if (view.canEdit) _NewSpaceRow(onPress: () => view.onNewSpace()),
      ],
    );
    // Dial-Up: the list in the window's white well, sunk into the silver as the Chat List's is (conversations.dart),
    // with its bevel and a margin of silver round it. It was a flat white fill to the window's edges, so a circle in
    // the list's place had no well border (Matt, 2026-11-18: "the sidebar in circles on the dial up theme is missing
    // the border bevel").
    if (!bevel) return list;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(1), t.space(1), t.space(1), t.space(1) + foot),
      child: Sunken(child: list),
    );
  }
}

/// New space, muted, at the foot of the list: lined up with the spaces' marks above it.
class _NewSpaceRow extends StatelessWidget {
  const _NewSpaceRow({required this.onPress});
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    return GlacierPressable(
      key: const ValueKey('circle-new-space'),
      onPressed: onPress,
      semanticLabel: 'New space',
      builder: (context, state) => Container(
        margin: bevel ? EdgeInsets.only(top: t.space(1)) : EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(1), t.space(2), 0),
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
        decoration: BoxDecoration(
          color: !bevel && (state.pressed || state.hovered) ? t.color('app-paper-2') : null,
          borderRadius: bevel ? null : BorderRadius.circular(t.radius('md')),
        ),
        child: Row(children: [
          // As large as a space's mark beside it (CircleSpaceTile).
          Container(
            width: bevel ? 28 : t.lenOf('1.875rem'),
            height: bevel ? 28 : t.lenOf('1.875rem'),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: bevel ? DialupColors.of(t).shadow : t.color('app-rule'), width: 1),
              borderRadius: BorderRadius.circular(bevel ? 0 : t.lenOf('1.875rem') * 0.32),
            ),
            child: AppIcon(Lucide.plus, size: bevel ? 16 : t.lenOf('1.875rem') * 0.5, color: t.color('app-ink-3')),
          ),
          SizedBox(width: t.space(3) + 2),
          Text('New space', style: pageText(t, t.fontSize('md'), color: t.color('app-ink-3'))),
        ]),
      ),
    );
  }
}

/// A heading of a circle's list, with a + where this device may add a space under it.
class CircleSectionHeading extends StatelessWidget {
  const CircleSectionHeading({super.key, required this.name, this.onAdd});
  final String name;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(4), t.space(2), t.space(1)),
      child: Row(children: [
        Expanded(child: Text(name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'), tracking: 0.6))),
        if (onAdd != null) IconTap(icon: Lucide.plus, label: 'New space in $name', size: 16, onPressed: onAdd!),
      ]),
    );
  }
}

/// "Maya is talking", or "You're talking" where the one talking is this device's person.
String talkingAlone(String name) => name == 'You' ? 'You\'re talking' : '$name is talking';

/// What a space's row says under its name: who is talking in a call (green), how many files a Files space holds, or
/// the newest message; null where there is nothing to say.
///
/// Their names are left out of a call's line where they are listed under the space, each with a face
/// ([CircleVoicePeople]): there the line says how many.
String? circleSpaceLine(CircleSpaceView s) {
  if (s.live) {
    final names = s.inVoice.take(3).join(', ');
    if (s.inVoice.length == 1) return talkingAlone(names);
    return s.people.isNotEmpty ? '${s.inVoice.length} talking' : '${s.inVoice.length} talking · $names';
  }
  if (s.kind == SpaceKind.files && s.files != null && (s.lastMessage == null || s.unread == 0)) return s.files == 0 ? 'No files yet' : '${s.files} ${s.files == 1 ? 'file' : 'files'}';
  return s.lastMessage;
}

/// Who is in a space's call, listed under the space in the circle's list: a face and a name each, as Discord lists who
/// is in a voice channel (Matt, 2026-11-24: "show a list of connected users in the sidebar under the voice space with
/// profile pictures and names like discord does"). The face is their profile picture where this device has it
/// ([SpaceFace]), else their initials. While this device is in the call itself, whoever is talking has rings going
/// out from their face and their name in the ink. A press opens the space, as a press on the space does.
class CircleVoicePeople extends StatelessWidget {
  const CircleVoicePeople({super.key, required this.space, required this.onPress});
  final CircleSpaceView space;
  final VoidCallback onPress;

  /// At most this many are listed; the rest are counted in a last line.
  static const most = 12;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    // Under the space's name: past the row's own margin and padding, its mark, and the gap after the mark.
    final mark = bevel ? 28.0 : t.lenOf('1.875rem');
    // Less the ring's own room round a face, so the face itself, not its ring, is under the name's first letter (Matt,
    // 2026-11-25: "left align the users in the list of users connected a call with the title text it has just a touch
    // of padding to the left of. the avatar that should go away").
    const ring = 3.0;
    final indent = (bevel ? 0 : t.space(2)) + t.space(3) + mark + t.space(3) + 2 - ring;
    final voice = Voice.instance;
    // The space's own room knows each person's picture; none where the space is not one this device holds (a test's).
    final room = voice.hangoutFor(space.channel);
    final shown = space.people.take(most).toList();
    final rest = space.people.length - shown.length;
    // A bit larger than they were at 22 (Matt, 2026-11-27: "make the uers in the sidebar a bit larger"), and their names
    // with them.
    const face = 28.0;
    // Square in Dial-Up, a squircle in a resource pack's frame, round elsewhere: as a face in the call itself is.
    final corner = voiceCorner(t, face);
    // Rings out from a face while they talk, as everywhere else in the app (Matt, 2026-11-25: "make sure everywhere voice
    // activity is logged uses the ripple animation like the sidebar"), in Dial-Up from its square.
    Widget rippled(double level, Widget picture) => Padding(
          padding: const EdgeInsets.all(ring),
          // With the green ring round the face while they talk, as a face in a call has (RippleAvatar; Matt, 2026-11-27:
          // "make the sidebar ripples also have the green outline circle it's missing").
          child: VoiceRipples(
            level: level,
            reach: 9,
            corner: corner,
            builder: (context, strength) {
              if (strength <= 0.05) return picture;
              final line = t.online.withValues(alpha: (0.4 + strength * 0.6).clamp(0, 1));
              if (corner != null) return TalkingLine(corner: corner, color: line, width: 2, child: picture);
              return DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: line, width: 2)),
                child: picture,
              );
            },
          ),
        );
    Widget rows(Map<String, double> levels) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          // A stage says so over who is in it, with how many of them listen (GMFB-29).
          if (space.listening case final listening?)
            Padding(
              key: ValueKey('circle-voice-${space.seed}-stage'),
              padding: EdgeInsetsDirectional.fromSTEB(indent + ring, 3, t.space(4), 3),
              child: Row(children: [
                AppIcon(Lucide.megaphone, size: 14, color: t.color('app-ink-3'), wash: false),
                SizedBox(width: t.space(1)),
                Expanded(child: Text('Stage · $listening listening', maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3')))),
              ]),
            ),
          for (final p in shown)
            () {
              final talking = (levels[p.id] ?? 0) > RippleAvatar.talking;
              final id = p.id;
              final initial = Avatar(people: [Person(address: 'space:$id', name: p.name)], size: face);
              final picture = room == null
                  ? initial
                  : corner == null
                      ? SpaceFace(room: room, id: p.me ? room.me : id, name: p.name, size: face)
                      // Their picture in the call's own frame; with none, their initials as everywhere.
                      : SpacePicture(
                          room: room,
                          id: p.me ? room.me : id,
                          builder: (context, kept) {
                            final image = pictureOfSpace(context, kept, face);
                            return image == null ? initial : VoiceFace(size: face, child: image);
                          },
                        );
              return Padding(
                key: ValueKey('circle-voice-${space.seed}-${p.id}'),
                padding: EdgeInsetsDirectional.fromSTEB(indent, 3, t.space(4), 3),
                child: Row(children: [
                  rippled(levels[id] ?? 0, picture),
                  SizedBox(width: t.space(2)),
                  Expanded(
                    child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: talking ? 'medium' : 'regular', color: t.color(talking ? 'app-ink' : 'app-ink-2'))),
                  ),
                  // What they show the call, after their name (GMFB-66: "show what users are streaming and or sharing
                  // video"): a camera, or a screen.
                  if (p.screen || p.camera) ...[
                    SizedBox(width: t.space(1)),
                    Semantics(
                      label: p.screen ? 'Sharing a screen' : 'Camera on',
                      child: AppIcon(p.screen ? LucideMore.screenShare : Lucide.video, key: ValueKey('circle-voice-${space.seed}-${p.id}-${p.screen ? 'screen' : 'camera'}'), size: 14, color: t.color('app-ink-3'), wash: false),
                    ),
                  ],
                ]),
              );
            }(),
          // The music played to the call, last, as one of those in it (Matt, 2026-11-25: "Spotify doesn't show up in
          // the sidebar for the lounge").
          if (space.music case final music?)
            Padding(
              key: ValueKey('circle-voice-${space.seed}-music'),
              padding: EdgeInsetsDirectional.fromSTEB(indent, 3, t.space(4), 3),
              child: Row(children: [
                rippled(levels[SpotifyMusic.levelId] ?? 0, SongCover(url: music.cover, size: face, corner: corner ?? face / 2)),
                SizedBox(width: t.space(2)),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [const TextSpan(text: 'Spotify'), TextSpan(text: ' · ${music.song}', style: TextStyle(color: t.color('app-ink-3')))]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')),
                  ),
                ),
              ]),
            ),
          if (rest > 0)
            Padding(
              padding: EdgeInsetsDirectional.fromSTEB(indent + ring, 3, t.space(4), 3),
              child: Text('and $rest more', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
            ),
          SizedBox(height: t.space(1)),
        ]);
    // How loud each is, where this device is in the call and so hears them; from outside it nobody is ringed.
    final session = space.here ? voice.session : null;
    final levels = session == null ? null : callLevels(session);
    return GlacierPressable(
      key: ValueKey('circle-voice-${space.seed}'),
      onPressed: onPress,
      semanticLabel: 'In ${space.name}${space.listening == null ? '' : ', a stage with ${space.listening} listening'}: ${space.inVoice.join(', ')}${space.music == null ? '' : ', and Spotify playing ${space.music!.song}'}',
      builder: (context, _) => levels == null ? rows(const {}) : ValueListenableBuilder<Map<String, double>>(valueListenable: levels, builder: (context, l, _) => rows(l)),
    );
  }
}

/// A space's row: its kind's mark in the kind's colour, its name (bold while unread), what is going on in it, then
/// its unread count or how many are talking.
class CircleSpaceTile extends StatelessWidget {
  const CircleSpaceTile({super.key, required this.space, required this.onPress, this.onLongPress, this.selected = false});
  final CircleSpaceView space;
  final VoidCallback onPress;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final bevel = isBevelChrome(t);
    final d = bevel ? DialupColors.of(t) : null;
    final highlit = d != null && selected;
    final bold = space.unread > 0 || selected;
    final ink = highlit ? d.onHighlight : t.color(bold ? 'app-ink' : 'app-ink-2');
    final sub = circleSpaceLine(space);
    // The kind's mark as large as the one by a space's name in its header (hangout_screen.dart), 2.1rem (Matt,
    // 2026-11-19: "make the circles spaces in the sidebar a tad bit smaller to match the icon size of the header icon
    // for a space"); Dial-Up's as small as its rows.
    // A step smaller again (Matt, 2026-11-19: "make the spaces slightly smaller still in the sidebar on circles").
    final mark = bevel ? 28.0 : t.lenOf('1.875rem');
    return GlacierPressable(
      key: ValueKey('circle-space-${space.seed}'),
      onPressed: onPress,
      onLongPress: onLongPress,
      semanticLabel: [space.name, spaceKindTitle(space.kind), if (space.unread > 0) '${space.unread} unread', ?sub].join(', '),
      builder: (context, state) => Container(
        // A size nearer the conversations' rows (Matt, 2026-11-18: "The spaces should be a bit larger in the sidebar they
        // feel small compared to the rest of the app"): a larger mark, name and line, and more room round them.
        margin: bevel ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: t.space(2), vertical: 2),
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
        decoration: BoxDecoration(
          color: d != null ? (selected ? d.highlight : null) : (selected ? t.color('app-paper-3') : (state.pressed || state.hovered ? t.color('app-paper-2') : null)),
          borderRadius: bevel ? null : BorderRadius.circular(t.radius('md')),
        ),
        child: Row(children: [
          // Dial-Up's chosen row is its navy highlight: the mark in the highlight's own ink, where its hue would sink.
          if (highlit) SizedBox.square(dimension: mark, child: Center(child: AppIcon(space.icon, size: mark * 0.56, color: d.onHighlight, wash: false))) else SpaceKindBadge(kind: space.kind, live: space.live, size: mark),
          SizedBox(width: t.space(3) + 2),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(space.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: bold ? 'semibold' : 'medium', color: ink)),
              if (sub != null && sub.isNotEmpty)
                Row(children: [
                  if (space.live) ...[
                    Container(width: 6, height: 6, decoration: BoxDecoration(color: highlit ? d.onHighlight : t.online, shape: bevel ? BoxShape.rectangle : BoxShape.circle)),
                    SizedBox(width: t.space(1) + 2),
                  ],
                  Flexible(child: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: space.unread > 0 && !space.live ? 'medium' : 'regular', color: highlit ? d.onHighlight : (space.live ? t.online : t.color(space.unread > 0 ? 'app-ink-2' : 'app-ink-3'))))),
                ]),
            ]),
          ),
          if (space.unread > 0) ...[
            SizedBox(width: t.space(2)),
            UnreadBadge(count: space.unread, mentioned: space.mentions > 0, color: highlit ? d.onHighlight : t.color('app-accent'), ink: highlit ? d.highlight : t.color('app-on-accent'), square: bevel),
          ] else if (space.live) ...[
            SizedBox(width: t.space(2)),
            AppIcon(spaceKindIcon(SpaceKind.voice), size: 14, color: highlit ? d.onHighlight : t.online, wash: false),
            SizedBox(width: t.space(1)),
            Text('${space.inVoice.length}', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: highlit ? d.onHighlight : t.online)),
          ],
        ]),
      ),
    );
  }
}
