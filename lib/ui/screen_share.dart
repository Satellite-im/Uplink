/// Sharing a screen in a call (GMFB-27, from the Uplink gap review: UplinkWeb shipped screen sharing in v2.0.3): the
/// button's work, the computer's choice of screen or window, the large view of someone's screen, and the line saying
/// who is sharing. And its sound (GMFB-63; lib/voice/screen_sound.dart): a switch where the screen is chosen, on a PC
/// and a Mac, and the viewer's loudness on the large view of a screen shared with it.
///
/// The screen goes out in the camera's place (lib/voice/rtc.dart, RtcMedia.setScreen), so it reaches everyone already
/// connected with nothing worked out again; each member's 'me' says it is a screen ('s'), and it is drawn whole, never
/// cropped or mirrored.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/settings_type.dart';
import '../platform_info.dart';
import '../sms.dart';
import '../app_state.dart';
import '../voice/channels.dart';
import '../voice/screen_sound.dart';
import '../voice/voice.dart';
import 'common.dart';
import 'tile_grid.dart' show VideoShapes;
import 'voice_screen.dart' show StreamView;
import 'whole_window.dart';
import '../l10n/words.dart';

/// What the button says: "Share screen", or "Stop sharing" while this device shares.
String screenShareLabel(VoiceSession s) => s.screen ? 'Stop sharing' : 'Share screen';

/// The button's work: stops sharing, or starts. A computer asks which screen or window first; a phone's system asks
/// itself. Says so where it did not start.
Future<void> toggleScreenShare(BuildContext context, VoiceSession s) async {
  if (s.screen) {
    await s.setScreen(false);
    return;
  }
  if (!s.canShareScreen) {
    toast(context, 'This device can\'t share its screen');
    return;
  }
  if (s.videoLocked) {
    toast(context, 'Your role in this space can\'t share video');
    return;
  }
  // Taken now: the menu this was pressed in may be gone by the time there is something to say.
  final toasts = GlacierToast.of(context);
  final app = AppState.maybeOf(context);
  String? source;
  var sound = false;
  if (Sms.computer) {
    final media = s.media;
    if (media is! ScreenMedia) return;
    // The computer's sound with it, where this one can take it: asked for with the screen, and kept as it was last.
    final can = media is ScreenSoundMedia ? (media as ScreenSoundMedia).screenSoundSupported() : Future.value(false);
    final wanted = ValueNotifier(app?.choice(shareSoundKey, '1') != '0');
    source = await pickScreen(context, (media as ScreenMedia).screenSources, sound: wanted, canSound: can);
    if (source == null) return;
    sound = wanted.value && await can;
    app?.keep(shareSoundKey, wanted.value ? '1' : '0');
  }
  final started = await s.setScreen(true, source: source, sound: sound);
  if (!started) {
    toasts.toast(message: const Tr('Your screen wasn\'t shared'));
  } else if (sound && !s.screenSound) {
    toasts.toast(message: Text(shareSoundFailedWords(mac: PlatformInfo.isMacOS)));
  }
}

/// Where the choice of sharing the computer's sound with its screen is kept: '0' for not, anything else for yes.
const shareSoundKey = 'share_sound';

/// The switch over the screens and windows, and what it says under it on a PC and on a Mac.
const shareSoundLabel = 'Share sound too';
String shareSoundHint({required bool mac}) => mac
    ? 'What your Mac plays goes with your screen, apart from this call. Your Mac asks once whether Uplink may record system audio.'
    : 'A window\'s own sound goes with it; with a whole screen, everything your PC plays apart from this call.';

/// Said where the screen is shared and its sound could not be taken.
String shareSoundFailedWords({required bool mac}) => mac
    ? 'Your screen is shared without its sound. To send sound, allow Uplink under System Settings › Privacy & Security › Screen & System Audio Recording, then share again.'
    : 'Your screen is shared without its sound: this PC didn\'t give any to send.';

/// Asks which screen or window to share, from [sources]: each with a picture of it. The chosen one's id; null if
/// none was chosen.
///
/// The sheet opens at once and looks for the screens itself (Matt, 2026-11-23: "screen sharing on mac and pc doesn't
/// show anything to select"). It used to ask [sources] first and open afterwards, and by then the menu the press
/// came from (the call page closes its menu as it runs a row) had gone, its context with it, so
/// nothing opened and nothing was said. [mac] is for the tests: the words for an empty list on a Mac.
///
/// [sound] is whether the computer's sound is to go with it, switched in the sheet where [canSound] says this device
/// can send it; with neither, there is no switch.
Future<String?> pickScreen(BuildContext context, Future<List<ScreenSource>> Function() sources, {bool? mac, ValueNotifier<bool>? sound, Future<bool>? canSound}) async {
  String? chosen;
  await showChoices(
    context,
    title: 'Share your screen',
    header: ScreenChoices(sources: sources, mac: mac, sound: sound, canSound: canSound, onPick: (id) => chosen = id),
    choices: [Choice('Cancel', Lucide.x, () {})],
  );
  return chosen;
}

/// The inside of [pickScreen]'s sheet: looks for the screens and windows, says so while it does, shows them, and
/// keeps looking while it is open. Never blank: with nothing found it says why and what to do, with Try again.
class ScreenChoices extends StatefulWidget {
  const ScreenChoices({super.key, required this.sources, required this.onPick, this.mac, this.sound, this.canSound});
  final Future<List<ScreenSource>> Function() sources;

  /// Whether the computer's sound goes with the screen, switched here; shown once [canSound] has said this device can
  /// send it. Null: no switch.
  final ValueNotifier<bool>? sound;
  final Future<bool>? canSound;

  /// Told the chosen one's id; the sheet is closed here.
  final void Function(String id) onPick;

  /// Whether the words for an empty list are a Mac's (its Screen Recording permission). Null: as this device is.
  final bool? mac;

  /// How many times an empty answer is asked again before saying nothing was found, and how long between: the
  /// system's list can come a moment after it is first asked for (flutter_webrtc reports screens as it finds them).
  static const tries = 4;
  static const soon = Duration(milliseconds: 500);

  /// How often the list is asked for again while the sheet is open: a window opened since, a picture that was not
  /// ready the first time, the permission just given.
  static const again = Duration(seconds: 2);

  @override
  State<ScreenChoices> createState() => _ScreenChoicesState();
}

class _ScreenChoicesState extends State<ScreenChoices> {
  /// What was found; null while still looking the first time (or after Try again).
  List<ScreenSource>? _found;
  int _asked = 0;
  Timer? _next;
  bool _asking = false;

  bool _canSound = false;

  @override
  void initState() {
    super.initState();
    unawaited(_look());
    unawaited(widget.canSound?.then((can) {
      if (mounted && can) setState(() => _canSound = true);
    }).catchError((_) {}));
  }

  @override
  void dispose() {
    _next?.cancel();
    super.dispose();
  }

  Future<void> _look() async {
    if (_asking) return;
    _asking = true;
    _next?.cancel();
    List<ScreenSource> list;
    try {
      list = await widget.sources();
    } catch (e) {
      debugPrint('screen share: the screens could not be listed: $e');
      list = const [];
    }
    _asking = false;
    if (!mounted) return;
    _asked++;
    // An empty answer is not believed until it has been given [ScreenChoices.tries] times.
    final sure = list.isNotEmpty || _asked >= ScreenChoices.tries;
    // Once something was found, a later empty answer (a list asked for mid-change) does not blank the sheet.
    final keep = list.isEmpty && (_found?.isNotEmpty ?? false);
    if (sure && !keep) setState(() => _found = list);
    _next = Timer(sure ? ScreenChoices.again : ScreenChoices.soon, () => unawaited(_look()));
  }

  void _retry() {
    setState(() {
      _found = null;
      _asked = 0;
    });
    unawaited(_look());
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final found = _found;
    Widget words(String s) => Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(2)),
          child: Text(s, style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2'), height: 1.4)),
        );
    if (found == null) return words('Looking for your screens and windows…');
    if (found.isEmpty) {
      final mac = widget.mac ?? PlatformInfo.isMacOS;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        words(mac
            ? 'No screens or windows were found. Your Mac has to allow it: open System Settings › Privacy & Security › Screen & System Audio Recording and turn on Uplink. If macOS asks, quit and reopen Uplink, then try again.'
            : 'No screens or windows were found. Try again; if there is still nothing, close Uplink, open it again and share from there.'),
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), 0, t.space(4), t.space(2)),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: GlacierPressable(
              onPressed: _retry,
              semanticLabel: 'Try again',
              builder: (context, state) => Container(
                padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                decoration: BoxDecoration(color: t.color(state.pressed || state.hovered ? 'app-paper-3' : 'app-paper'), borderRadius: BorderRadius.circular(999), border: Border.all(color: t.color('app-rule'))),
                child: Text('Try again', style: pageText(t, t.fontSize('sm'), weight: 'bold', color: t.color('app-ink'))),
              ),
            ),
          ),
        ),
      ]);
    }
    final picker = ScreenPicker(
      sources: found,
      onPick: (id) {
        widget.onPick(id);
        // The sheet's own navigator, from the sheet's own context: the one that asked may be gone.
        Navigator.of(context).pop();
      },
    );
    final sound = widget.sound;
    if (sound == null || !_canSound) return picker;
    final mac = widget.mac ?? PlatformInfo.isMacOS;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Padding(
        padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(1), t.space(4), t.space(1)),
        child: ValueListenableBuilder<bool>(
          valueListenable: sound,
          builder: (context, on, _) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(shareSoundLabel, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
                SizedBox(height: t.space(1) / 2),
                Text(shareSoundHint(mac: mac), style: pageText(t, t.fontSize('xs'), color: t.color('app-ink-3'), height: 1.35)),
              ]),
            ),
            SizedBox(width: t.space(3)),
            GlacierSwitch(key: const ValueKey('share-sound'), checked: on, ariaLabel: shareSoundLabel, onCheckedChange: (v) => sound.value = v),
          ]),
        ),
      ),
      picker,
    ]);
  }
}

/// The screens, then the windows, two across, each a picture and its name.
class ScreenPicker extends StatelessWidget {
  const ScreenPicker({super.key, required this.sources, required this.onPick});
  final List<ScreenSource> sources;
  final void Function(String id) onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final screens = [for (final s in sources) if (!s.window) s];
    final windows = [for (final s in sources) if (s.window) s];
    Widget heading(String words) => Padding(
          padding: EdgeInsetsDirectional.fromSTEB(t.space(4), t.space(2), t.space(4), t.space(1)),
          child: Text(words, style: pageText(t, t.fontSize('xs'), weight: 'bold', color: t.color('app-ink-3'))),
        );
    Widget grid(List<ScreenSource> list) => Padding(
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          child: LayoutBuilder(builder: (context, box) {
            final w = (box.maxWidth - t.space(2)) / 2;
            return Wrap(spacing: t.space(2), runSpacing: t.space(2), children: [
              for (final s in list) SizedBox(width: w, child: _SourceTile(source: s, onPick: () => onPick(s.id))),
            ]);
          }),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      if (screens.isNotEmpty) ...[heading('Screens'), grid(screens)],
      if (windows.isNotEmpty) ...[heading('Windows'), grid(windows)],
      SizedBox(height: t.space(2)),
    ]);
  }
}

/// One screen or window to choose: its picture (an icon where there is none) over its name.
class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.source, required this.onPick});
  final ScreenSource source;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final pic = source.thumbnail;
    final icon = Center(child: AppIcon(source.window ? LucideMore.appWindow : LucideMore.monitor, size: 28, wash: false, color: const Color(0xFF8A8A90)));
    return GlacierPressable(
      onPressed: onPick,
      semanticLabel: 'Share ${source.name}',
      builder: (context, state) => Container(
        padding: EdgeInsets.all(t.space(1)),
        decoration: BoxDecoration(
          color: state.pressed || state.hovered ? t.color('app-paper-3') : const Color(0x00000000),
          borderRadius: BorderRadius.circular(t.radius('lg')),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 16 / 10,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.radius('md')),
              child: ColoredBox(
                color: const Color(0xFF1C1C1F),
                // A picture that can't be read (the Mac's are TIFF) is the icon, not a hole.
                child: pic != null && pic.isNotEmpty ? Image.memory(pic, fit: BoxFit.contain, gaplessPlayback: true, errorBuilder: (_, _, _) => icon) : icon,
              ),
            ),
          ),
          SizedBox(height: t.space(1)),
          Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: t.color('app-ink-2'))),
        ]),
      ),
    );
  }
}

/// Who in [s] is sharing a screen now, other than this device, with their picture once it has arrived: the first to
/// have started, as the members are listed.
({String id, String name, MediaStream? stream})? sharerIn(VoiceSession s) {
  final v = Voice.instance;
  for (final m in s.members.values) {
    if (m.screen) return (id: m.id, name: v.nameOf(m.id), stream: v.media?.remote.value[m.id]);
  }
  return null;
}

/// Whose picture this device keeps large in a call (GMFB-27: "Viewers see the share as its own large tile, can pin
/// it, and full-screen it"): chosen with Pin in what a press on someone's picture opens, kept until Unpin. This
/// device's alone: nothing of it is said to the call. One call's pin is not the next call's.
abstract final class CallPin {
  /// The call and who is pinned in it ('me' for this device); null for nobody.
  static final ValueNotifier<({VoiceSession call, String id})?> who = ValueNotifier(null);

  /// Who is pinned in [s]; null for nobody.
  static String? inCall(VoiceSession s) => identical(who.value?.call, s) ? who.value!.id : null;

  /// Pins [id] in [s], or unpins them where they were the one pinned.
  static void toggle(VoiceSession s, String id) => who.value = inCall(s) == id ? null : (call: s, id: id);

  static void clear() => who.value = null;

  /// Whether [id] has a picture in [s] to keep large: their camera or their screen.
  static bool canPin(VoiceSession s, String id) {
    if (id == 'me') return s.video || s.screen;
    return s.members[id]?.video ?? false;
  }
}

/// Whose picture is shown large in [s] now: whoever this device pinned ([CallPin]) while their picture is on, else
/// someone else's shared screen unless it was put away ([putAway], their id). Null for nobody. `stream` is null until
/// their picture arrives; `screen` says it is a screen, not a camera.
({String id, String name, MediaStream? stream, bool screen, bool pinned, bool mirror})? stagedIn(VoiceSession s, {String? putAway}) {
  final v = Voice.instance;
  final media = v.media;
  final pin = CallPin.inCall(s);
  if (pin == 'me' && CallPin.canPin(s, 'me')) {
    final screen = media?.localScreen.value;
    return (id: 'me', name: 'You', stream: screen ?? media?.localVideo.value, screen: s.screen, pinned: true, mirror: !s.screen && !s.backCamera);
  }
  final m = pin == null ? null : s.members[pin];
  if (m != null && m.video) return (id: m.id, name: v.nameOf(m.id), stream: media?.remote.value[m.id], screen: m.screen, pinned: true, mirror: false);
  final sharer = sharerIn(s);
  if (sharer == null || sharer.id == putAway) return null;
  return (id: sharer.id, name: sharer.name, stream: sharer.stream, screen: true, pinned: false, mirror: false);
}

/// Someone's screen, large: the whole of it on black, their name over it, and a way back to the call. A camera kept
/// large with Pin is shown the same way ([screen] false).
///
/// Once the picture is here there is a button for full screen (GMFB-27): the picture alone over the whole window, the
/// window full screen on a computer, the bars hidden on a phone; Esc, the button again or the phone's back leaves it.
/// It goes in and out as a played video does (lib/ui/whole_window.dart). With [onPin], a button that pins or unpins.
class ScreenStage extends StatefulWidget {
  const ScreenStage({super.key, required this.name, required this.stream, required this.onBack, this.screen = true, this.mirror = false, this.pinned = false, this.onPin, this.desk, this.picture, this.who, this.sound});
  final String name;

  /// Whose screen it is, by their id in the call: where they share its sound too (GMFB-63), the stage has a button
  /// for how loud that is on this device. Null for this device's own, and for a camera.
  final String? who;

  /// The sound's loudness as a test gives it; null: as the call has it ([ScreenSound]).
  final ({int volume, bool hearing, ValueChanged<int> onVolume})? sound;

  /// Null until their picture arrives.
  final MediaStream? stream;
  final VoidCallback onBack;

  /// A shared screen ("Maya's screen"); false for a camera, named as the person is and filling its space.
  final bool screen;

  /// This device's own camera, drawn as a mirror shows it.
  final bool mirror;

  /// Kept large by this device ([CallPin]); [onPin] pins or unpins, and with none there is no button for it.
  final bool pinned;
  final VoidCallback? onPin;

  /// Whether this is a computer, for a test; null: as the device is.
  final bool? desk;

  /// Drawn where the stream's picture would be, for a test, which has no stream.
  final Widget? picture;

  @override
  State<ScreenStage> createState() => _ScreenStageState();
}

class _ScreenStageState extends State<ScreenStage> {
  bool _full = false;

  /// Whether the loudness of the share's sound is open under the buttons.
  bool _soundOpen = false;
  final _over = OverlayPortalController(debugLabel: 'shared screen full screen');
  final _stage = GlobalKey(debugLabel: 'shared screen');
  final _focus = FocusNode(debugLabel: 'shared screen');

  bool get _desk => widget.desk ?? (!kIsWeb && (PlatformInfo.isMacOS || PlatformInfo.isWindows || PlatformInfo.isLinux));

  @override
  void dispose() {
    _focus.dispose();
    if (_full) WholeWindow.gone(desk: _desk);
    super.dispose();
  }

  Future<void> _toggleFull() async {
    setState(() => _full = !_full);
    final done = WholeWindow.set(_full, desk: _desk, over: _over, aspect: VideoShapes.of(widget.stream?.id) ?? 0);
    // The keys are the stage's while it is full screen: Esc leaves it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _full) _focus.requestFocus();
    });
    await done;
  }

  void _back() {
    if (_full) unawaited(_toggleFull());
    widget.onBack();
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent || e.logicalKey != LogicalKeyboardKey.escape || !_full) return KeyEventResult.ignored;
    unawaited(_toggleFull());
    return KeyEventResult.handled;
  }

  /// A round button over the picture.
  Widget _tool(Tokens t, LucideIcon icon, String label, VoidCallback onPressed, {bool on = false, Key? key}) => Padding(
        padding: EdgeInsetsDirectional.only(end: t.space(2)),
        child: GlacierPressable(
          key: key,
          onPressed: onPressed,
          semanticLabel: label,
          builder: (context, state) => Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, color: on ? const Color(0xFFFFFFFF) : Color(state.pressed || state.hovered ? 0xCC000000 : 0x99000000)),
            child: AppIcon(icon, size: 16, wash: false, color: on ? const Color(0xFF000000) : const Color(0xFFFFFFFF)),
          ),
        ),
      );

  /// The share's sound on this device: what a test gave, else what the call has where [ScreenStage.who] shares it.
  ({int volume, bool hearing, ValueChanged<int> onVolume})? get _sound {
    if (widget.sound != null) return widget.sound;
    final who = widget.who, sounds = ScreenSound.instance;
    if (who == null || !widget.screen || !sounds.sounds(who)) return null;
    return (volume: sounds.volume, hearing: sounds.hearing(who), onVolume: sounds.setVolume);
  }

  /// How loud the share's sound is here: a button to silence it or bring it back, and its loudness.
  Widget _loudness(Tokens t, ({int volume, bool hearing, ValueChanged<int> onVolume}) sound) => Container(
        key: const ValueKey('stage-sound-strip'),
        constraints: const BoxConstraints(maxWidth: 340),
        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          GlacierPressable(
            key: const ValueKey('stage-sound-mute'),
            onPressed: () => sound.onVolume(sound.volume == 0 ? 100 : 0),
            semanticLabel: sound.volume == 0 ? 'Hear this screen\'s sound' : 'Silence this screen\'s sound',
            builder: (context, state) => AppIcon(sound.volume == 0 ? LucideMore.volumeX : Lucide.volume2, size: 16, wash: false, color: const Color(0xFFFFFFFF)),
          ),
          SizedBox(width: t.space(2)),
          Expanded(child: _StageSlider(key: const ValueKey('stage-sound-volume'), value: sound.volume / 100, label: 'Loudness of this screen\'s sound', onChanged: (x) => sound.onVolume((x * 100).round()))),
          SizedBox(width: t.space(2)),
          SizedBox(width: t.lenOf('2.6rem'), child: Text('${sound.volume}%', textAlign: TextAlign.end, style: pageText(t, t.fontSize('xs'), color: const Color(0xFFFFFFFF)))),
        ]),
      );

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: ScreenSound.instance, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final t = context.tokens;
    final top = MediaQuery.paddingOf(context).top;
    final s = widget.stream;
    final name = widget.name;
    final here = s != null || widget.picture != null;
    final sound = _sound;
    final stage = KeyedSubtree(
      key: _stage,
      // A phone's back gesture leaves full screen first, as Esc does on a computer.
      child: PopScope(
        canPop: !_full,
        onPopInvokedWithResult: (popped, _) {
          if (!popped && _full) unawaited(_toggleFull());
        },
        child: Focus(
          focusNode: _focus,
          onKeyEvent: _key,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Stack(children: [
              Positioned.fill(
                child: widget.picture ??
                    (s == null
                        ? Center(child: Text(widget.screen ? 'Waiting for $name\'s screen…' : 'Waiting for $name\'s video…', style: pageText(t, t.fontSize('sm'), color: const Color(0xFFB0B0B6))))
                        // One renderer per stream (GMFB-5). A camera is drawn whole too: large, nothing of it cut off.
                        : StreamView(key: ObjectKey(s), stream: s, mirror: widget.mirror, contain: true)),
              ),
              PositionedDirectional(
                top: top + t.space(2),
                start: t.space(3),
                end: t.space(3),
                child: Row(children: [
                  // The name has the room the buttons leave, so they stand at the edge, over the loudness they open.
                  Expanded(
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Container(
                        padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                        decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(999)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          AppIcon(widget.screen ? LucideMore.screenShare : Lucide.video, size: 16, wash: false, color: const Color(0xFFFFFFFF)),
                          SizedBox(width: t.space(2)),
                          Flexible(child: Text(widget.screen ? (name == 'You' ? 'Your screen' : '$name\'s screen') : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF)))),
                        ]),
                      ),
                    ),
                  ),
                  SizedBox(width: t.space(2)),
                  if (sound != null)
                    _tool(t, sound.volume == 0 ? LucideMore.volumeX : Lucide.volume2, 'Sound of this screen', () => setState(() => _soundOpen = !_soundOpen), on: _soundOpen, key: const ValueKey('stage-sound')),
                  if (widget.onPin != null)
                    _tool(t, widget.pinned ? Lucide.pinOff : Lucide.pin, widget.pinned ? 'Unpin' : 'Pin', widget.onPin!, on: widget.pinned, key: const ValueKey('stage-pin')),
                  if (here)
                    _tool(t, _full ? LucideMore.minimize : Lucide.maximize, _full ? 'Leave full screen' : 'Full screen', () => unawaited(_toggleFull()), key: const ValueKey('stage-full')),
                  GlacierPressable(
                    onPressed: _back,
                    semanticLabel: 'Back to the call',
                    builder: (context, state) => Container(
                      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
                      decoration: BoxDecoration(color: Color(state.pressed ? 0xFFDDDDDD : 0xFFFFFFFF), borderRadius: BorderRadius.circular(999)),
                      child: Text('Back to call', style: pageText(t, t.fontSize('sm'), weight: 'bold', color: const Color(0xFF000000))),
                    ),
                  ),
                ]),
              ),
              if (sound != null && _soundOpen)
                PositionedDirectional(top: top + t.space(2) + 44, end: t.space(3), start: t.space(3), child: Align(alignment: AlignmentDirectional.centerEnd, child: _loudness(t, sound))),
            ]),
          ),
        ),
      ),
    );
    if (!_desk) return stage;
    // On a computer, full screen draws it over the whole window: the list, the rail and the title bar are under it,
    // as under a played video (GMFB-65). Black stands in its place meanwhile.
    final whole = _full && _over.isShowing;
    return OverlayPortal(
      controller: _over,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (_) => Positioned.fill(child: whole ? stage : const SizedBox.shrink()),
      child: whole ? const ColoredBox(color: Color(0xFF000000), child: SizedBox.expand()) : stage,
    );
  }
}

/// A loudness from nothing to all of it, dragged or pressed along its track, in white on the dark of a shared screen
/// (the app's own slider is drawn in the theme's ink, which is not seen there).
class _StageSlider extends StatelessWidget {
  const _StageSlider({super.key, required this.value, required this.onChanged, required this.label});
  final double value;
  final ValueChanged<double> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        value: '${(value * 100).round()}%',
        increasedValue: '${((value + 0.1).clamp(0.0, 1.0) * 100).round()}%',
        decreasedValue: '${((value - 0.1).clamp(0.0, 1.0) * 100).round()}%',
        onIncrease: () => onChanged((value + 0.1).clamp(0.0, 1.0)),
        onDecrease: () => onChanged((value - 0.1).clamp(0.0, 1.0)),
        child: LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          void at(double x) => onChanged((x / w).clamp(0.0, 1.0));
          final frac = value.clamp(0.0, 1.0);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => at(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
            child: SizedBox(
              height: 28,
              child: Stack(alignment: AlignmentDirectional.centerStart, children: [
                Container(height: 4, decoration: BoxDecoration(color: const Color(0x55FFFFFF), borderRadius: BorderRadius.circular(2))),
                Container(width: w * frac, height: 4, decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(2))),
                PositionedDirectional(start: (w * frac - 8).clamp(0.0, w - 16), child: Container(width: 16, height: 16, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFFFFFFF)))),
              ]),
            ),
          );
        }),
      );
}

/// A call's page with what is shown large over it (GMFB-27): a friend's call and a group's get the stage a space's
/// call has. Someone else's shared screen covers [child] until Back to call, which leaves a line over the call with
/// View; whoever this device pinned ([CallPin]) covers it until unpinned. This device's own share is a line with Stop.
class StagedCall extends StatefulWidget {
  const StagedCall({super.key, required this.session, required this.child});
  final VoiceSession session;
  final Widget child;

  @override
  State<StagedCall> createState() => _StagedCallState();
}

class _StagedCallState extends State<StagedCall> {
  /// Whose shared screen was put away with Back to call.
  String? _putAway;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final media = Voice.instance.media;
    return ListenableBuilder(
      listenable: Listenable.merge([s, CallPin.who, ?media?.remote, ?media?.localVideo, ?media?.localScreen]),
      builder: (context, _) {
        if (_putAway != null && sharerIn(s) == null) _putAway = null;
        final staged = stagedIn(s, putAway: _putAway);
        final viewing = staged != null && !staged.pinned;
        return Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (ScreenShareBanner.shows(s, viewing: viewing))
              ScreenShareBanner(
                session: s,
                onView: () {
                  CallPin.clear();
                  setState(() => _putAway = null);
                },
              ),
            Expanded(child: widget.child),
          ]),
          if (staged != null)
            Positioned.fill(
              child: ScreenStage(
                name: staged.name,
                stream: staged.stream,
                screen: staged.screen,
                mirror: staged.mirror,
                pinned: staged.pinned,
                who: staged.id == 'me' ? null : staged.id,
                onPin: () => CallPin.toggle(s, staged.id),
                onBack: () => leaveStage(s, staged.id, pinned: staged.pinned, putAway: (id) => setState(() => _putAway = id)),
              ),
            ),
        ]);
      },
    );
  }
}

/// Back to call from what is shown large: a pin is let go, and where it is someone's shared screen it is put away
/// too ([putAway], told their id), so the call is what shows.
void leaveStage(VoiceSession s, String id, {required bool pinned, required void Function(String id) putAway}) {
  if (pinned) CallPin.clear();
  if (id != 'me' && (s.members[id]?.screen ?? false)) putAway(id);
}

/// The line over a call while a screen is shared: this device's own, with Stop; or someone else's, with View, while
/// their screen is not the one shown large ([onView]).
class ScreenShareBanner extends StatelessWidget {
  const ScreenShareBanner({super.key, required this.session, this.onView});
  final VoiceSession session;
  final VoidCallback? onView;

  /// Whether there is anything to say: this device shares, or someone else does and can be viewed.
  static bool shows(VoiceSession s, {bool viewing = false}) => s.screen || (!viewing && sharerIn(s) != null);

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final s = session;
    final other = sharerIn(s);
    final mine = s.screen;
    if (!mine && (other == null || onView == null)) return const SizedBox.shrink();
    const blue = Color(0xFF2F6FDE);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
      padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(2)),
      decoration: BoxDecoration(color: blue, borderRadius: BorderRadius.circular(t.radius('lg'))),
      child: Row(children: [
        const AppIcon(LucideMore.screenShare, size: 16, wash: false, color: Color(0xFFFFFFFF)),
        SizedBox(width: t.space(2)),
        Expanded(
          child: Text(mine ? (s.screenSound ? 'You\'re sharing your screen and its sound' : 'You\'re sharing your screen') : '${other!.name} is sharing their screen',
              maxLines: 2, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: const Color(0xFFFFFFFF))),
        ),
        GlacierPressable(
          onPressed: mine ? () => unawaited(s.setScreen(false)) : onView,
          semanticLabel: mine ? 'Stop sharing' : 'View their screen',
          builder: (context, state) => Container(
            padding: EdgeInsets.symmetric(horizontal: t.space(3), vertical: t.space(1)),
            decoration: BoxDecoration(color: const Color(0xFFFFFFFF), borderRadius: BorderRadius.circular(999)),
            child: Text(mine ? 'Stop' : 'View', style: pageText(t, t.fontSize('xs'), weight: 'bold', color: blue)),
          ),
        ),
      ]),
    );
  }
}
