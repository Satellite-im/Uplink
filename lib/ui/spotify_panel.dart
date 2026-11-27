/// Spotify in a circle's call, on the screen (lib/voice/spotify.dart; Matt, 2026-11-25: "add a spotify plugin for circles
/// that allows a user to add songs to a queue and play them from spotify"): the queue's page ([SpotifyScreen]), the line
/// over the call saying what plays ([MusicLine]) and a song's cover ([SongCover]).
library;

import 'dart:async';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../voice/channels.dart';
import '../voice/spotify.dart';
import '../voice/spotify_queue.dart';
import 'common.dart';
import 'voice_screen.dart' show VolumeSlider;
import '../l10n/words.dart';

/// "3:07".
String songClock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// A song's cover, square; a note on the page's own ground where there is none, or it can't be had.
class SongCover extends StatelessWidget {
  const SongCover({super.key, required this.url, required this.size, this.corner = 0});
  final String? url;
  final double size, corner;

  /// How the picture is got; a test's stands in for the network.
  @visibleForTesting
  static ImageProvider Function(String url) image = (url) => NetworkImage(url);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final none = ColoredBox(color: t.color('app-paper-3'), child: Center(child: AppIcon(LucideMore.music, size: size * 0.5, wash: false, color: t.color('app-ink-3'))));
    final u = url;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(corner),
        child: SizedBox.square(dimension: size, child: u == null ? none : Image(image: image(u), width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => none)),
      ),
    );
  }
}

/// Built again as the music changes, and each second while it plays, for its place.
class _EachSecond extends StatefulWidget {
  const _EachSecond({required this.builder});
  final Widget Function(BuildContext context, SpotifyMusic music) builder;

  @override
  State<_EachSecond> createState() => _EachSecondState();
}

class _EachSecondState extends State<_EachSecond> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    SpotifyMusic.instance.addListener(_changed);
    _run();
  }

  void _changed() {
    if (!mounted) return;
    _run();
    setState(() {});
  }

  void _run() {
    final on = SpotifyMusic.instance.state?.playing ?? false;
    if (on && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!on) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    SpotifyMusic.instance.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, SpotifyMusic.instance);
}

/// Who is playing it, as it is said: "You" or their name.
String _who(SpotifyMusic m, String id) => id == m.me ? 'You' : Voice.instance.nameOf(id);

/// The queue's page: what plays, a box to paste a song's link in, the songs waiting, how loud it is here, and Start or
/// Stop for whoever may be the DJ.
class SpotifyScreen extends StatefulWidget {
  const SpotifyScreen({super.key});

  @override
  State<SpotifyScreen> createState() => _SpotifyScreenState();
}

class _SpotifyScreenState extends State<SpotifyScreen> {
  final _link = TextEditingController();
  bool _adding = false;
  String? _problem;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final pasted = _link.text.trim();
    if (_adding || pasted.isEmpty) return;
    setState(() {
      _adding = true;
      _problem = null;
    });
    final why = await SpotifyMusic.instance.add(pasted);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _problem = why;
    });
    if (why == null) _link.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pad = EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom);
    return GhostPage(
      title: 'Spotify',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: _EachSecond(
          builder: (context, m) => Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(padding: pad, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
                if (m.dj == null) ..._quiet(t, m) else ..._playing(t, m),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _wrong(Tokens t, String words, {Key? key}) => Padding(
        padding: EdgeInsets.only(top: t.space(3)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: EdgeInsetsDirectional.only(end: t.space(2), top: 2), child: AppIcon(Lucide.triangleAlert, size: 16, color: t.danger)),
          Expanded(child: Semantics(liveRegion: true, child: Text(words, key: key, style: pageText(t, t.fontSize('sm'), color: t.danger, height: 1.4)))),
        ]),
      );

  /// Nobody plays: who can start it, and Start where this device can.
  List<Widget> _quiet(Tokens t, SpotifyMusic m) {
    final on = m.inCall && m.isOn();
    return [
      SettingsCallout(
        icon: AppIcon(LucideMore.music, size: 18),
        child: Text(!m.inCall
            ? 'You aren\'t in a call. Join one in this circle to play music in it.'
            : !on
                ? 'Spotify isn\'t on in this space\'s circle.'
                : m.canDj
                    ? 'Nobody is playing music here. Start it, and your own Spotify on this computer plays to everyone in the call. Anyone who may speak can then add songs, skip and pause.'
                    : 'Nobody is playing music here. Someone on a Mac or a PC with Spotify can start it.'),
      ),
      if (on && m.canDj) ...[
        SizedBox(height: t.space(4)),
        PaneSection(
          footer: const Tr('Spotify must be open on this computer and signed in, on Premium to play a song of your choosing. People hear it live, and nothing is stored. Spotify\'s terms are for personal use and don\'t allow rebroadcasting: keep it to a small private call, at your own account\'s risk. Wear headphones, so your microphone doesn\'t send the music a second time.'),
          children: [
            SettingRow(
              key: const ValueKey('spotify-start'),
              icon: AppIcon(Lucide.play, size: 18),
              label: m.starting ? 'Starting…' : 'Start',
              hint: Text(m.mayChoose ? 'Play your Spotify to the call' : 'Your role in this space can\'t speak, so it can\'t play music.'),
              disabled: m.starting || !m.mayChoose,
              onPress: m.start,
            ),
          ],
        ),
        if (m.startWords != null) _wrong(t, m.startWords!, key: const ValueKey('spotify-start-problem')),
      ],
    ];
  }

  List<Widget> _playing(Tokens t, SpotifyMusic m) {
    final state = m.state;
    final now = state?.now;
    final next = state?.next ?? const <QueuedSong>[];
    final may = m.mayChoose;
    return [
      _NowPlaying(music: m),
      if (m.troubleWords != null) _wrong(t, m.troubleWords!, key: const ValueKey('spotify-problem')),
      if (m.capturedLow) _wrong(t, 'Your Bluetooth headset\'s microphone is in use, which brings everything this computer plays down to a call\'s quality, and the music with it. Choose another microphone, or wired headphones.', key: const ValueKey('spotify-low')),
      SizedBox(height: t.space(5)),
      PaneSection(
        title: 'Add a song',
        footer: Text(may ? 'In Spotify: Share, Copy Song Link. It plays from ${m.mine ? 'your' : '${_who(m, m.dj!)}\'s'} Spotify when its turn comes.' : 'Your role in this space can\'t speak, so it can\'t choose songs.'),
        children: [
          SettingRowBox(
            child: GlacierInput(
              key: const ValueKey('spotify-link'),
              controller: _link,
              placeholder: 'Paste a song\'s link'.t,
              ariaLabel: 'A song\'s link from Spotify',
              autoCorrect: false,
              autoCapitalize: TextCapitalization.none,
              size: GlacierFieldSize.md,
              disabled: !may,
              onChange: (_) => setState(() => _problem = null),
              onSubmitted: (_) => _add(),
            ),
          ),
          SettingRow(
            key: const ValueKey('spotify-add'),
            icon: AppIcon(Lucide.plus, size: 18),
            label: _adding ? 'Adding…' : 'Add it to the queue',
            disabled: !may || _adding || _link.text.trim().isEmpty,
            onPress: _add,
          ),
        ],
      ),
      if (_problem != null) _wrong(t, _problem!, key: const ValueKey('spotify-add-problem')),
      SizedBox(height: t.space(5)),
      PaneSection(
        title: next.isEmpty ? 'Up next' : 'Up next · ${next.length}',
        children: [
          if (next.isEmpty) SettingRowBox(child: Text(now == null ? 'Nothing is queued. Add a song and it plays.' : 'Nothing after this one yet.', style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
          for (final (i, q) in next.indexed) _SongRow(key: ValueKey('spotify-song-${q.id}'), music: m, song: q, place: i, of: next.length),
        ],
      ),
      SizedBox(height: t.space(5)),
      PaneSection(
        title: 'On this device',
        footer: Text(m.mine ? 'You hear it from Spotify itself. Wear headphones, so your microphone doesn\'t send the music a second time.' : 'Only how loud it is for you. Deafened, you hear none of it, and it is in no recording of the call.'),
        children: [
          if (!m.mine)
            SettingRowBox(
              child: Row(children: [
                SizedBox(width: t.lenOf('5.5rem'), child: Text('Loudness', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink')))),
                Expanded(child: VolumeSlider(key: const ValueKey('spotify-volume'), value: m.volume / 100, max: 1, label: 'Music loudness', onChanged: (x) => m.setVolume((x * 100).round()))),
                SizedBox(width: t.space(3)),
                SizedBox(width: t.lenOf('3rem'), child: Text('${m.volume}%', textAlign: TextAlign.end, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
              ]),
            ),
          if (!m.mine) ..._heard(t, m),
          if (m.mine) SettingRow(key: const ValueKey('spotify-stop'), icon: AppIcon(Lucide.x, size: 18), label: 'Stop', hint: const Tr('Stop playing to the call, for everyone'), onPress: m.stop),
          if (m.mine)
            SettingRow(
              key: const ValueKey('spotify-listeners'),
              icon: AppIcon(LucideMore.headphones, size: 18),
              label: 'Listening',
              hint: Text(m.sentLossless == 0
                  ? 'Lossless goes to whoever wears headphones and whose connection to you is direct. What they can hear is what Spotify plays here: in Spotify, set Audio quality to Lossless, on Premium.'
                  : 'Lossless takes ${(m.losslessBits / 1e6).toStringAsFixed(1)} Mbit/s of your upload. What they hear is what Spotify plays here: in Spotify, set Audio quality to Lossless, on Premium.'),
              value: Text('${m.listeners}${m.sentLossless == 0 ? '' : ', ${m.sentLossless} lossless'}'),
            ),
        ],
      ),
    ];
  }
}

/// What this device hears of it: without loss or as Opus, why not, and the switch.
List<Widget> _heard(Tokens t, SpotifyMusic m) {
  final why = m.losslessWords;
  final heard = m.volume == 0
      ? 'Nothing'
      : m.hearingLossless
          ? 'Lossless'
          : m.hearing
              ? 'High quality'
              : 'Connecting…';
  return [
    SettingRow(
      key: const ValueKey('spotify-quality'),
      icon: AppIcon(LucideMore.audioLines, size: 18),
      label: 'You hear',
      hint: m.volume == 0
          ? null
          : Text(m.hearingLossless
              ? 'The music as it was captured, 48 kHz, 16 bits, with nothing left out.'
              : why ?? 'Lossless begins once it has played cleanly for a second.'),
      value: Text(heard),
    ),
    if (m.losslessCan)
      SettingRow(
        key: const ValueKey('spotify-lossless'),
        icon: AppIcon(LucideMore.music, size: 18),
        label: 'Lossless music',
        hint: const Tr('About 1 Mbit/s, and a second or so later than the DJ hears it. Off, it is Opus at its highest.'),
        control: GlacierSwitch(checked: m.lossless, onCheckedChange: m.setLossless, ariaLabel: 'Lossless music'),
      ),
    if (m.losslessCan && m.asksHeadphones)
      SettingRow(
        key: const ValueKey('spotify-headphones'),
        icon: AppIcon(LucideMore.headphones, size: 18),
        label: 'I\'m wearing headphones',
        hint: const Tr('Say so for what you hear it on now, and lossless plays to it.'),
        control: GlacierSwitch(checked: m.headphones, onCheckedChange: m.setHeadphones, ariaLabel: 'I\'m wearing headphones'),
      ),
  ];
}

/// What plays: its cover, title and artist, who plays it, where it is, and the two buttons.
class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.music});
  final SpotifyMusic music;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = music;
    final s = m.state;
    final now = s?.now;
    final song = now?.song;
    final where = s?.where(m.clock()) ?? Duration.zero;
    final length = song?.length ?? Duration.zero;
    final by = now == null || now.by == m.dj ? '' : 'Added by ${now.by == m.me ? 'you' : _who(m, now.by)} · ';
    final dj = m.mine ? 'From your Spotify' : 'From ${_who(m, m.dj!)}\'s Spotify';
    return Container(
      key: const ValueKey('spotify-now'),
      padding: EdgeInsets.all(t.space(4)),
      decoration: BoxDecoration(color: t.color('app-paper-2'), borderRadius: BorderRadius.circular(t.radius('xl')), border: Border.all(color: t.color('app-rule'))),
      child: Column(children: [
        Row(children: [
          SongCover(url: song?.coverUrl, size: 72, corner: t.radius('md')),
          SizedBox(width: t.space(4)),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(song?.shown ?? 'Nothing is playing', maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('lg'), weight: 'bold', color: t.color('app-ink'))),
              if (song != null && song.artist.isNotEmpty) Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), color: t.color('app-ink-2'))),
              SizedBox(height: t.space(1)),
              Text('$by$dj', maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
            ]),
          ),
        ]),
        if (song != null) ...[
          SizedBox(height: t.space(3)),
          Semantics(
            container: true,
            label: length > Duration.zero ? '${songClock(where)} of ${songClock(length)}' : songClock(where),
            child: ExcludeSemantics(
              child: Row(children: [
                Text(songClock(where), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
                SizedBox(width: t.space(2)),
                Expanded(child: _Progress(at: length > Duration.zero ? where.inMilliseconds / length.inMilliseconds : 0)),
                SizedBox(width: t.space(2)),
                Text(length > Duration.zero ? songClock(length) : '', style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'))),
              ]),
            ),
          ),
        ],
        if (m.mayChoose && (now != null || (s?.next.isNotEmpty ?? false))) ...[
          SizedBox(height: t.space(2)),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconTap(key: const ValueKey('spotify-toggle'), icon: (s?.playing ?? false) ? Lucide.pause : Lucide.play, label: (s?.playing ?? false) ? 'Pause' : 'Play', onPressed: m.toggle, filled: true),
            SizedBox(width: t.space(3)),
            IconTap(key: const ValueKey('spotify-skip'), icon: LucideMore.skipForward, label: 'Skip', onPressed: m.skip),
          ]),
        ],
      ]),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.at});
  final double at;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SizedBox(
      height: 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: t.color('app-paper-3')),
          FractionallySizedBox(alignment: AlignmentDirectional.centerStart, widthFactor: at.clamp(0.0, 1.0), child: ColoredBox(color: t.color('app-accent'))),
        ]),
      ),
    );
  }
}

/// A song waiting: its cover, title and who added it; up, down and away for whoever may.
class _SongRow extends StatelessWidget {
  const _SongRow({super.key, required this.music, required this.song, required this.place, required this.of});
  final SpotifyMusic music;
  final QueuedSong song;
  final int place, of;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = song.song;
    final who = song.by == music.me ? 'you' : Voice.instance.nameOf(song.by);
    final may = music.mayChoose;
    Widget tap(String key, LucideIcon icon, String label, VoidCallback? run) => IconTap(key: ValueKey('spotify-$key-${song.id}'), icon: icon, label: label, size: 18, box: 34, onPressed: run, color: t.color(run == null ? 'app-ink-4' : 'app-ink-2'));
    return SettingRowBox(
      child: Row(children: [
        SongCover(url: s.coverUrl, size: 40, corner: t.radius('sm')),
        SizedBox(width: t.space(3)),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.shown, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink'))),
            Text([if (s.artist.isNotEmpty) s.artist, 'added by $who'].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'))),
          ]),
        ),
        if (may && of > 1) ...[
          tap('up', Lucide.chevronUp, 'Move ${s.shown} up', place == 0 ? null : () => music.move(song.id, place - 1)),
          tap('down', Lucide.chevronDown, 'Move ${s.shown} down', place == of - 1 ? null : () => music.move(song.id, place + 1)),
        ],
        if (music.mayRemove(song)) tap('remove', Lucide.x, 'Take ${s.shown} out of the queue', () => music.remove(song.id)),
      ]),
    );
  }
}

/// The line over the call while music plays: its cover, title and artist, play or pause, skip, and Queue.
class MusicLine extends StatelessWidget {
  const MusicLine({super.key});

  static const ground = Color(0xFF1B1B1F);
  static const _white = Color(0xFFFFFFFF);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SpotifyMusic.instance,
      builder: (context, _) {
        final t = context.tokens;
        final m = SpotifyMusic.instance;
        final s = m.state;
        final now = s?.now;
        if (m.dj == null || (now == null && (s?.trouble ?? '').isEmpty)) return const SizedBox.shrink();
        final playing = s?.playing ?? false;
        Widget icon(String key, LucideIcon icon, String label, VoidCallback run) => GlacierPressable(
              key: ValueKey(key),
              onPressed: run,
              semanticLabel: label,
              builder: (context, state) => Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(shape: BoxShape.circle, color: _white.withValues(alpha: state.pressed || state.hovered ? 0.24 : 0)),
                child: AppIcon(icon, size: 18, wash: false, color: _white),
              ),
            );
        final words = now == null ? 'Spotify' : now.song.shown;
        final under = m.troubleWords ?? now?.song.artist ?? '';
        return Container(
          key: const ValueKey('music-line'),
          margin: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
          padding: EdgeInsets.symmetric(horizontal: t.space(2), vertical: t.space(1) + 2),
          decoration: BoxDecoration(color: ground, borderRadius: BorderRadius.circular(t.radius('lg')), border: Border.all(color: _white.withValues(alpha: 0.12))),
          child: Row(children: [
            SongCover(url: now?.song.coverUrl, size: 36, corner: t.radius('sm')),
            SizedBox(width: t.space(2)),
            Expanded(
              child: Semantics(
                label: 'Music: $words${under.isEmpty ? '' : ', $under'}',
                child: ExcludeSemantics(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(words, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: _white)),
                    if (under.isNotEmpty) Text(under, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), color: _white.withValues(alpha: 0.72))),
                  ]),
                ),
              ),
            ),
            if (m.mayChoose && now != null) ...[
              icon('music-toggle', playing ? Lucide.pause : Lucide.play, playing ? 'Pause the music' : 'Play the music', m.toggle),
              icon('music-skip', LucideMore.skipForward, 'Skip this song', m.skip),
            ],
            SizedBox(width: t.space(1)),
            GlacierPressable(
              key: const ValueKey('music-queue'),
              onPressed: () => push<void>(context, (_) => const SpotifyScreen()),
              semanticLabel: 'Queue',
              builder: (context, state) => Container(
                padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
                decoration: BoxDecoration(color: _white.withValues(alpha: state.pressed ? 0.8 : 1), borderRadius: BorderRadius.circular(999)),
                child: Text('Queue', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: ground)),
              ),
            ),
          ]),
        );
      },
    );
  }
}
