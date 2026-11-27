import 'dart:io';
import '../platform_info.dart';

import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../circles/circles.dart';
import '../files/file_platform.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../voice/channels.dart';
import '../voice/voice.dart' show VoiceChannel;
import '../voice/soundboard.dart';
import 'common.dart';
import 'voice_screen.dart' show VolumeSlider;
import '../l10n/words.dart';

/// The soundboard's pads (Matt, 2026-11-20: "build a soundboards plugin for circles"; lib/voice/soundboard.dart): the
/// app's own sounds, then the circle's. In a call a press plays for everyone in it; outside one, here alone. Whoever
/// may change the circle adds its sounds here, and a long press on one names it again or takes it away. Under the pads,
/// what this device hears of it.
///
/// Opened from a call ([space]: the call's space) or from Circle settings › Plugins ([circle]), where the pads are
/// only tried.
class SoundboardScreen extends StatelessWidget {
  const SoundboardScreen({super.key, this.space, this.circle, this.pickClip});
  final VoiceChannel? space;
  final Circle? circle;

  /// Chooses a clip to add: its path, or null where none was. Null: this device's own picker.
  final Future<String?> Function()? pickClip;

  /// The circle whose sounds these are: the one given, else the call's space's; as Circles holds it now, so a sound
  /// added or taken away shows.
  Circle? get _circle {
    final c = circle ?? (space == null ? null : Circles.instance.circleOf(space!));
    return c == null ? null : Circles.instance.bySeed(c.seed) ?? c;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Soundboard.instance, Circles.instance, Voice.instance]),
      builder: (context, _) {
        final t = context.tokens;
        final board = Soundboard.instance;
        final c = _circle;
        final own = c == null ? const <BoardSound>[] : circleSounds(c);
        final edit = c != null && Circles.instance.can(c, CirclePerm.circle);
        // Arranging a circle's sounds from its settings is never a press in a call.
        final live = circle == null && board.inCall;
        final pad = EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom);

        void press(BoardSound s) {
          if (!live) return board.preview(s, space: c?.bannerChannel);
          final why = board.press(s);
          if (why != null) toast(context, why);
        }

        return GhostPage(
          title: circle == null ? 'Soundboard' : '${c?.name ?? 'Circle'}\'s soundboard',
          body: SettingsPaneScope(
            finder: SettingsFinder(),
            child: ListView(padding: pad, children: [
              SettingsCallout(
                icon: AppIcon(live ? Lucide.megaphone : Lucide.volume2, size: 18),
                child: Text(live
                    ? 'Everyone in the call hears what you press, unless they muted the soundboard.'
                    : circle != null
                        ? 'These are tried here only. In a call in ${c?.name ?? 'the circle'}, a press plays for everyone in it.'
                        : 'You aren\'t in a call, so a pad plays here only.'),
              ),
              SizedBox(height: t.space(4)),
              _Heading('Sounds'),
              _Pads(children: [for (final s in builtInSounds) _Pad(key: ValueKey('pad-${s.id}'), sound: s, onPress: () => press(s))]),
              if (c != null) ...[
                SizedBox(height: t.space(5)),
                _Heading('${c.name}\'s own', hint: own.isEmpty && !edit ? 'None yet. Whoever may change ${c.name} adds them.' : (edit ? 'Hold one to name it again or take it away. ${own.length} of $boardCircleMost.' : null)),
                if (own.isNotEmpty || edit)
                  _Pads(children: [
                    for (final s in own) _Pad(key: ValueKey('pad-${s.id}'), sound: s, onPress: () => press(s), onLong: edit ? () => _menu(context, c, s) : null),
                    if (edit && own.length < boardCircleMost) _Pad.add(key: const ValueKey('pad-add'), onPress: () => _add(context, c)),
                  ]),
              ],
              SizedBox(height: t.space(5)),
              PaneSection(
                title: 'On this device',
                footer: const Tr('Deafened in a call, you hear none of it either way.'),
                children: [
                  SettingRow(
                    key: const ValueKey('soundboard-hear'),
                    icon: AppIcon(Lucide.ear, size: 18),
                    label: 'Hear what others play',
                    hint: Text(board.quiet ? 'Off: you still see who played what, and your own pads still play.' : 'Sounds other people press play here.'),
                    control: GlacierSwitch(checked: !board.quiet, ariaLabel: 'Hear what others play', onCheckedChange: (v) => board.setQuiet(!v)),
                  ),
                  SettingRowBox(
                    child: Row(children: [
                      SizedBox(width: t.lenOf('6.5rem'), child: Text('Loudness', style: pageText(t, t.fontSize('md'), weight: 'medium', color: t.color('app-ink')))),
                      Expanded(child: VolumeSlider(key: const ValueKey('soundboard-volume'), value: board.volume / 100, max: 1, label: 'Soundboard loudness', onChanged: (x) => board.setVolume((x * 100).round()))),
                      SizedBox(width: t.space(3)),
                      SizedBox(width: t.lenOf('3rem'), child: Text('${board.volume}%', textAlign: TextAlign.end, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3')))),
                    ]),
                  ),
                ],
              ),
            ]),
          ),
        );
      },
    );
  }

  /// Chooses a clip, refuses one that isn't an audio file or is over [boardClipMost], and goes on to naming it.
  Future<void> _add(BuildContext context, Circle c) async {
    String? path;
    try {
      path = pickClip != null ? await pickClip!() : (await FilePlatform.pick()).firstOrNull?.path;
    } catch (_) {
      path = null;
    }
    if (path == null || !context.mounted) return;
    final file = File(path);
    final ending = path.contains('.') ? path.substring(path.lastIndexOf('.')).toLowerCase() : '';
    if (!Soundboard.clipEndings.contains(ending)) return toast(context, 'A sound is an audio file: ${Soundboard.clipEndings.map((e) => e.substring(1)).join(', ')}.', tone: GlacierToastTone.danger);
    if (file.existsSync() && file.lengthSync() > boardClipMost) return toast(context, 'That clip is too big: a sound is at most 1 MB. A few seconds is plenty.', tone: GlacierToastTone.danger);
    await push<void>(context, (_) => SoundNameScreen(circle: c, path: path!));
  }

  /// A long press on one of the circle's own sounds: name it again, or take it away.
  void _menu(BuildContext context, Circle c, BoardSound s) => showChoices(context, title: '${s.emoji}  ${s.name}', choices: [
        Choice('Name it again', Lucide.pencil, () => push<void>(context, (_) => SoundNameScreen(circle: c, sound: s))),
        Choice('Take it away', Lucide.trash2, () async {
          final ok = await Soundboard.instance.remove(c, s);
          if (context.mounted) toast(context, ok ? '${s.name} is gone from ${c.name}\'s sounds' : 'Couldn\'t take it away', tone: ok ? GlacierToastTone.neutral : GlacierToastTone.danger);
        }, danger: true),
      ]);
}

/// A heading over a group of pads, in small capitals, with a line of smaller words under it where there are any.
class _Heading extends StatelessWidget {
  const _Heading(this.words, {this.hint});
  final String words;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: t.space(2)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(words.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-3'), tracking: 0.6)),
        if (hint != null) Padding(padding: EdgeInsets.only(top: t.space(1)), child: Text(hint!, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-3'), height: 1.4))),
      ]),
    );
  }
}

/// The pads in rows, as many across as fit at about a thumb's width each.
class _Pads extends StatelessWidget {
  const _Pads({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final gap = t.space(2);
    return LayoutBuilder(builder: (context, box) {
      final across = (box.maxWidth / 92).floor().clamp(3, 8);
      final side = (box.maxWidth - gap * (across - 1)) / across;
      return Wrap(spacing: gap, runSpacing: gap, children: [for (final c in children) SizedBox(width: side.floorToDouble(), height: side.floorToDouble().clamp(84, 120), child: c)]);
    });
  }
}

/// One pad: a sound's emoji over its name, or ([_Pad.add]) the pad that adds a sound.
class _Pad extends StatelessWidget {
  const _Pad({super.key, required BoardSound this.sound, required this.onPress, this.onLong});
  const _Pad.add({super.key, required this.onPress})
      : sound = null,
        onLong = null;

  /// Null: the pad that adds one.
  final BoardSound? sound;
  final VoidCallback onPress;
  final VoidCallback? onLong;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = sound;
    return GlacierPressable(
      onPressed: onPress,
      onLongPress: onLong,
      semanticLabel: s == null ? 'Add a sound' : s.name,
      builder: (context, state) => AnimatedScale(
        scale: state.pressed ? 0.94 : 1,
        duration: const Duration(milliseconds: 90),
        child: Container(
          padding: EdgeInsets.all(t.space(2)),
          decoration: BoxDecoration(
            color: state.pressed ? t.color('app-paper-3') : t.color('app-paper-2'),
            borderRadius: BorderRadius.circular(t.radius('lg')),
            border: Border.all(color: state.pressed ? t.color('app-ink-3') : t.color('app-rule')),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (s == null) AppIcon(Lucide.plus, size: 24, color: t.color('app-ink-2')) else Text(s.emoji, style: pageText(t, 26, height: 1.1)),
            SizedBox(height: t.space(1)),
            Text(s == null ? 'Add a sound' : s.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'medium', color: t.color(s == null ? 'app-ink-3' : 'app-ink'), height: 1.2)),
          ]),
        ),
      ),
    );
  }
}

/// Naming a circle's sound: one being added ([path]: the clip chosen) or one there already ([sound]).
class SoundNameScreen extends StatefulWidget {
  const SoundNameScreen({super.key, required this.circle, this.path, this.sound}) : assert(path != null || sound != null);
  final Circle circle;
  final String? path;
  final BoardSound? sound;

  /// The faces a sound can be given; the first is a new sound's.
  static const emoji = ['🔊', '😂', '🎺', '🐐', '💀', '🔥', '👻', '🎵', '🙌', '😱', '🤡', '💥', '🚨', '🐸', '❤️', '👋'];

  /// A clip's name from its file's: "wow-what.mp3" is "Wow what".
  static String nameOf(String path) {
    var n = path.split(PlatformInfo.pathSeparator).last.split('/').last;
    if (n.contains('.')) n = n.substring(0, n.lastIndexOf('.'));
    n = n.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
    if (n.isEmpty) return 'Sound';
    n = n[0].toUpperCase() + n.substring(1);
    return n.length > BoardSound.nameMost ? n.substring(0, BoardSound.nameMost).trim() : n;
  }

  @override
  State<SoundNameScreen> createState() => _SoundNameScreenState();
}

class _SoundNameScreenState extends State<SoundNameScreen> {
  late final _name = TextEditingController(text: widget.sound?.name ?? SoundNameScreen.nameOf(widget.path!));
  late String _emoji = widget.sound?.emoji ?? SoundNameScreen.emoji.first;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Renames a sound that is there already, or adds the clip under this name and face; says why where it couldn't.
  Future<void> _save() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) return toast(context, 'Give it a name.');
    setState(() => _busy = true);
    final c = widget.circle;
    final had = widget.sound;
    final why = had != null
        ? (await Soundboard.instance.rename(c, had, name: name, emoji: _emoji) ? null : 'Couldn\'t change it.')
        : await Soundboard.instance.add(c, path: widget.path!, name: name, emoji: _emoji);
    if (!mounted) return;
    setState(() => _busy = false);
    if (why != null) return toast(context, why, tone: GlacierToastTone.danger);
    toast(context, had != null ? 'Changed' : '$name is in ${c.name}\'s sounds');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final adding = widget.sound == null;
    final pad = EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(8) + MediaQuery.paddingOf(context).bottom);
    return GhostPage(
      title: adding ? 'Add a sound' : 'Name it again',
      body: SettingsPaneScope(
        finder: SettingsFinder(),
        child: ListView(padding: pad, keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag, children: [
          PaneSection(
            title: 'Its name',
            children: [
              SettingRowBox(
                child: GlacierInput(
                  key: const ValueKey('sound-name'),
                  controller: _name,
                  placeholder: 'What the pad says'.t,
                  ariaLabel: 'The sound\'s name',
                  autoCapitalize: TextCapitalization.sentences,
                  size: GlacierFieldSize.md,
                  maxLength: BoardSound.nameMost,
                  onChange: (_) => setState(() {}),
                  onSubmitted: (_) => _save(),
                ),
              ),
            ],
          ),
          SizedBox(height: t.space(5)),
          PaneSection(
            title: 'Its face',
            children: [
              SettingRowBox(
                child: Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
                  for (final e in SoundNameScreen.emoji)
                    GlacierPressable(
                      key: ValueKey('sound-emoji-$e'),
                      onPressed: () => setState(() => _emoji = e),
                      semanticLabel: e,
                      builder: (context, state) => Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: e == _emoji ? t.color('app-paper-3') : const Color(0x00000000),
                          borderRadius: BorderRadius.circular(t.radius('md')),
                          border: Border.all(color: e == _emoji ? t.color('app-ink') : t.color('app-rule'), width: e == _emoji ? 1.5 : 1),
                        ),
                        child: Text(e, style: pageText(t, 22, height: 1.1)),
                      ),
                    ),
                ]),
              ),
            ],
          ),
          SizedBox(height: t.space(5)),
          PaneSection(
            footer: Text(adding
                ? 'The clip is sealed and kept for ${widget.circle.name}; everyone in the circle can play it in a call where Soundboard is on. A sound plays for ten seconds at most.'
                : 'Everyone in ${widget.circle.name} sees the change.'),
            children: [
              if (adding) SettingRow(key: const ValueKey('sound-try'), icon: AppIcon(Lucide.play, size: 18), label: 'Hear it', onPress: () => Soundboard.instance.player(widget.path!, Soundboard.instance.volume / 100)),
              SettingRow(key: const ValueKey('sound-save'), icon: AppIcon(Lucide.check, size: 18), label: _busy ? (adding ? 'Adding…' : 'Changing…') : (adding ? 'Add it to ${widget.circle.name}' : 'Save'), disabled: _busy || _name.text.trim().isEmpty, onPress: _save),
            ],
          ),
        ]),
      ),
    );
  }
}
