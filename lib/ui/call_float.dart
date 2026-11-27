import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:glacier/glacier.dart';

import '../app_seen.dart';
import '../app_state.dart';
import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../art/lucide_more.dart';
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/open_space.dart' show OpenSpaces;
import '../voice/rtc.dart' show RtcMedia;
import '../voice/voice.dart';
import 'call_pip.dart';
import 'dialup/bevel.dart';
import 'dialup/parts.dart' show DialupTool;
import 'dialup/title_bar.dart';
import 'nav_bar.dart' show NavPill;
import 'ripple_avatar.dart' show RippleAvatar;
import 'shell.dart' show AppShell;
import 'tile_grid.dart' show VideoShapes;
import 'voice_screen.dart' show StreamView, mutedMark, sayMicLocked;

/// A call's picture over the app while you are elsewhere in it (GMFB-64, Kevin, Android 0.12.29: "Streaming or video
/// calling would be nice if there were a pop out option"; Matt, 2026-11-25: "Please go ahead take care of the pop out
/// video player as well"). In a call with video or a shared screen, leaving the call's page (for another chat, the
/// list, Settings, another circle) leaves a small picture floating over the app: the one that matters most
/// ([pickPicture]), its name and whether they are heard, and, under the pointer or a tap, Back to the call, Mute,
/// Leave and Close. It is dragged to any corner and snaps there, clear of the title bar, the composer and the
/// screen's edges, and the corner is kept on this device; on a computer it is a small or a large size. A call with no
/// picture keeps its bar above the dock (CallBanner), and that bar stands in for the picture while it is closed, with a
/// Pop out button to bring it back. Android's picture in picture shows the same picture with the app put away
/// (lib/ui/call_pip.dart).

/// One picture of the call: whose, which stream, and whether it is their screen.
@immutable
class CallPicture {
  const CallPicture({required this.id, required this.name, required this.stream, this.screen = false, this.me = false, this.muted = false, this.mark = LucideMore.micOff});

  /// `me` for this device, else their id on the hub.
  final String id;
  final String name;
  final MediaStream stream;

  /// Their shared screen rather than their camera (GMFB-27): drawn whole, never cropped or mirrored.
  final bool screen;
  final bool me;

  /// Not heard here, and the mark that says why (mutedMark, GMFB-49).
  final bool muted;
  final LucideIcon mark;

  /// Their camera and their screen are two pictures, in order of coming (CallPictures).
  String get key => '${screen ? 'screen' : 'camera'}:$id';

  /// The words under it: "Riley", "Riley's screen", "Your screen".
  String get label => screen ? (me ? 'Your screen' : '$name\'s screen') : (me ? 'You' : name);

  /// The same picture, drawn the same.
  bool sameAs(CallPicture? o) => o != null && o.key == key && identical(o.stream, stream) && o.name == name && o.muted == muted && o.mark == mark;

  @override
  String toString() => 'CallPicture($key)';
}

/// The picture that matters most of [all]: someone's shared screen first (the latest shared), then whoever is talking
/// ([talker], the last of those with a camera on to have talked), then the latest camera to come on ([order], bigger
/// is later), and this device's own only where it is all there is. [screensOnly]: an open space's, where only a
/// shared screen is popped out (its floor is a room of faces, not of cameras).
CallPicture? pickPicture(List<CallPicture> all, {String? talker, Map<String, int> order = const {}, bool screensOnly = false}) {
  final pool = [for (final p in all) if (!screensOnly || p.screen) p];
  final others = [for (final p in pool) if (!p.me) p];
  int latest(CallPicture a, CallPicture b) => (order[b.key] ?? 0).compareTo(order[a.key] ?? 0);
  final screens = [for (final p in others) if (p.screen) p]..sort(latest);
  if (screens.isNotEmpty) return screens.first;
  final talking = talker == null ? null : others.where((p) => p.id == talker && !p.screen).firstOrNull;
  if (talking != null) return talking;
  final cameras = [...others]..sort(latest);
  if (cameras.isNotEmpty) return cameras.first;
  return pool.where((p) => p.me).firstOrNull;
}

/// Runs [f] now, or after the frame where a frame is being built (a page's mark coming and going is told while it is).
void _afterBuild(VoidCallback f) {
  final b = SchedulerBinding.instance;
  if (b.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    b.addPostFrameCallback((_) => f());
  } else {
    f();
  }
}

/// The picture of the call [Voice] is in that matters most now ([pickPicture]), followed while anything listens: who
/// has video on, whose is a screen, who talks. Shared by the floating picture and Android's picture in picture, so
/// both show the same one.
class CallPictures extends ChangeNotifier {
  CallPictures._();
  static final instance = CallPictures._();

  /// The pictures [s] has now, this device's first.
  static List<CallPicture> of(VoiceSession s, RtcMedia? media) {
    final v = Voice.instance;
    final room = v.hangoutFor(s.channel);
    final mine = media?.localScreen.value ?? media?.localVideo.value;
    return [
      if (mine != null) CallPicture(id: 'me', name: s.name.isEmpty ? 'You' : s.name, stream: mine, me: true, screen: media?.localScreen.value != null, muted: s.muted || s.deafened),
      for (final m in s.members.values)
        if (m.id != s.bridgeId && m.video && media?.remote.value[m.id] != null)
          CallPicture(
            id: m.id,
            name: v.nameOf(m.id),
            stream: media!.remote.value[m.id]!,
            screen: m.screen,
            muted: m.muted || v.silenced(m.id) || (room != null && !room.heard(m.id)),
            mark: mutedMark(all: room?.mutedForAll(m.id) ?? false, mine: v.silenced(m.id)),
          ),
    ];
  }

  /// Whether [s] has a picture to pop out: what the call's Pop out is offered for.
  static bool anyIn(VoiceSession s) => pickPicture(of(s, Voice.instance.media), screensOnly: OpenSpaces.isCall(s)) != null;

  CallPicture? _current;

  /// The picture, or null: no call, or nothing in it to see.
  CallPicture? get current => _on ? _current : _pick();

  List<CallPicture> _all = const [];
  final Map<String, int> _order = {};
  int _next = 0;
  String? _talker;
  bool _on = false;
  VoiceSession? _s;
  RtcMedia? _m;
  ValueListenable<Map<String, double>>? _levels;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (!_on) {
      _on = true;
      Voice.instance.addListener(_rewire);
      OpenSpaces.instance.addListener(_read);
      _rewire();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_on && !hasListeners) {
      _on = false;
      Voice.instance.removeListener(_rewire);
      OpenSpaces.instance.removeListener(_read);
      _unwire();
      _s = null;
      _m = null;
      _levels = null;
    }
  }

  /// Follows the call there is now, its media and its levels.
  void _rewire() {
    final v = Voice.instance;
    final s = v.session, m = v.media;
    final levels = s == null ? null : (m?.levels ?? s.media.levels);
    if (!identical(s, _s) || !identical(m, _m) || !identical(levels, _levels)) {
      _unwire();
      _s = s;
      _m = m;
      _levels = levels;
      s?.addListener(_read);
      m?.remote.addListener(_read);
      m?.localVideo.addListener(_read);
      m?.localScreen.addListener(_read);
      levels?.addListener(_heard);
    }
    _read();
  }

  void _unwire() {
    _s?.removeListener(_read);
    _m?.remote.removeListener(_read);
    _m?.localVideo.removeListener(_read);
    _m?.localScreen.removeListener(_read);
    _levels?.removeListener(_heard);
  }

  CallPicture? _pick() {
    final s = Voice.instance.session;
    if (s == null) return null;
    return pickPicture(of(s, Voice.instance.media), talker: _talker, order: _order, screensOnly: OpenSpaces.isCall(s));
  }

  void _read() {
    final s = _s;
    if (s == null) {
      _all = const [];
      _order.clear();
      _talker = null;
      return _set(null);
    }
    final all = of(s, _m);
    final keys = {for (final p in all) p.key};
    _order.removeWhere((k, _) => !keys.contains(k));
    for (final p in all) {
      _order.putIfAbsent(p.key, () => ++_next);
    }
    if (_talker != null && !all.any((p) => p.id == _talker && !p.screen)) _talker = null;
    _all = all;
    _set(pickPicture(all, talker: _talker, order: _order, screensOnly: OpenSpaces.isCall(s)));
  }

  /// Someone with a camera on talking takes the picture, and keeps it until another of them talks: it does not flick
  /// to nobody between their words.
  void _heard() {
    final now = _levels?.value ?? const {};
    CallPicture? best;
    var most = RippleAvatar.talking;
    for (final p in _all) {
      final l = now[p.id] ?? 0;
      if (!p.me && !p.screen && !p.muted && l > most) {
        best = p;
        most = l;
      }
    }
    if (best == null || best.id == _talker) return;
    _talker = best.id;
    _read();
  }

  void _set(CallPicture? p) {
    if (p == null ? _current == null : p.sameAs(_current)) return;
    _current = p;
    _afterBuild(notifyListeners);
  }
}

/// Whether the floating picture is up, and what it shows: no call page on the screen ([CallPageMark]), a picture to
/// show, the app seen (AppSeen: nothing is drawn while it is put away), not in Android's picture in picture (which
/// shows it instead), and not closed for this call.
class CallFloat extends ChangeNotifier {
  CallFloat._();
  static final instance = CallFloat._();

  /// The corner it was left in (`tl`, `tr`, `bl`, `br`) and whether it is the large size, in this device's choices.
  static const cornerPref = 'call_float_corner', largePref = 'call_float_large';

  /// Where it starts: the top right, over the oldest of what a page shows rather than its newest and its composer.
  static const firstCorner = 'tr';

  final Set<Object> _pages = {};
  String? _closed, _room;
  bool _shown = false;
  CallPicture? _picture;
  bool _on = false;

  /// Up, with [picture] in it.
  bool get shown => _shown;
  CallPicture? get picture => _shown ? _picture : null;

  /// A call's page is on the screen, so nothing floats.
  bool get onCallPage => _pages.isNotEmpty;

  /// Closed for the call there is now, with a picture to bring back: the call's bar offers Pop out.
  bool get canPopOut => !_shown && Voice.instance.session != null && _closed == Voice.instance.session?.channel.room && CallPictures.instance.current != null;

  /// A call's page is on the screen ([on]) or not, as [who] says.
  void page(Object who, bool on) {
    if (on ? !_pages.add(who) : !_pages.remove(who)) return;
    _update();
  }

  /// Closes it for this call alone: the call goes on, its bar stands in, and Pop out brings it back.
  void close() {
    _closed = Voice.instance.session?.channel.room;
    _update();
  }

  /// Shows it again for this call, as soon as its page is left.
  void reopen() {
    _closed = null;
    _update();
  }

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (!_on) {
      _on = true;
      Voice.instance.addListener(_update);
      CallPictures.instance.addListener(_update);
      AppSeen.now.addListener(_update);
      CallPip.instance.inPip.addListener(_update);
      _update();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_on && !hasListeners) {
      _on = false;
      Voice.instance.removeListener(_update);
      CallPictures.instance.removeListener(_update);
      AppSeen.now.removeListener(_update);
      CallPip.instance.inPip.removeListener(_update);
    }
  }

  void _update() {
    final s = Voice.instance.session;
    final room = s?.channel.room;
    // A call of its own: closed in the last one is not closed in this.
    if (room != _room) {
      _room = room;
      if (_closed != room) _closed = null;
    }
    final p = s == null ? null : CallPictures.instance.current;
    final show = s != null && p != null && _pages.isEmpty && _closed != room && AppSeen.now.value && !CallPip.instance.inPip.value;
    final was = _picture;
    if (show == _shown && (p == null ? was == null : p.sameAs(was))) return;
    _shown = show;
    _picture = p;
    _afterBuild(notifyListeners);
  }

  /// For a test: as it is when the app starts.
  @visibleForTesting
  void reset() {
    _pages.clear();
    _closed = null;
    _room = null;
    _shown = false;
    _picture = null;
  }
}

/// Says that [child] is a call's page while it is on the screen: built and not covered by another page (its tickers
/// on). The floating picture is not drawn while one is. [on]: whether it is a call's page now (a page that is one only
/// while in the call keeps its place in the tree either way).
class CallPageMark extends StatefulWidget {
  const CallPageMark({super.key, this.on = true, required this.child});
  final bool on;
  final Widget child;

  @override
  State<CallPageMark> createState() => _CallPageMarkState();
}

class _CallPageMarkState extends State<CallPageMark> {
  ValueListenable<TickerModeData>? _ticking;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final t = TickerMode.getValuesNotifier(context);
    if (!identical(t, _ticking)) {
      _ticking?.removeListener(_say);
      _ticking = t..addListener(_say);
    }
    _say();
  }

  void _say() => CallFloat.instance.page(this, widget.on && (_ticking?.value.enabled ?? true));

  @override
  void didUpdateWidget(CallPageMark old) {
    super.didUpdateWidget(old);
    if (old.on != widget.on) _say();
  }

  @override
  void dispose() {
    _ticking?.removeListener(_say);
    CallFloat.instance.page(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Pop out, on the call's own page: leaves the page with the picture floating over what is under it. Beside the list or
/// in it, the page in the shell's pane goes; a page pushed over everything is put away.
void popOutCall(BuildContext context) {
  CallFloat.instance.reopen();
  final shell = AppShell.maybeOf(context);
  if (shell != null) return shell.close();
  unawaited(Navigator.of(context).maybePop());
}

/// What the floating picture's buttons say.
abstract final class FloatWords {
  static const back = 'Back to the call', close = 'Close the picture', popOut = 'Pop out', leave = 'Leave the call', larger = 'Make the picture larger', smaller = 'Make the picture smaller';
  static String mute(VoiceSession s) => s.muted ? 'Unmute' : 'Mute';
}

/// The floating picture over the app, where [CallFloat] has it up; nothing otherwise, and nothing to press but the
/// picture itself. [onOpen]: what Back to the call does (as the call's bar does, AppShell).
class CallFloatLayer extends StatelessWidget {
  const CallFloatLayer({super.key, required this.onOpen});
  final VoidCallback onOpen;

  /// The picture's size in a [window], for a picture [shape] wide over high: on a phone small (narrower for an upright
  /// picture), on a computer [large] or small. Never more than about half the window across, nor 40% of it high.
  @visibleForTesting
  static Size sizeFor({required Size window, required double shape, required bool large, required bool computer}) {
    final aspect = shape.clamp(0.5, 2.4);
    var w = computer ? (large ? 400.0 : 240.0) : (aspect < 1 ? 120.0 : 176.0);
    w = math.min(w, window.width * (computer ? 0.5 : 0.46));
    var h = w / aspect;
    final tallest = window.height * 0.4;
    if (h > tallest) {
      h = tallest;
      w = h * aspect;
    }
    return Size(w, h);
  }

  /// The corner of [area] nearest [point].
  @visibleForTesting
  static String cornerNear(Offset point, Rect area) => '${point.dy < area.center.dy ? 't' : 'b'}${point.dx < area.center.dx ? 'l' : 'r'}';

  /// Where a picture [size] stands in [corner] of [area]: its top left, inside the area wherever it fits.
  @visibleForTesting
  static Offset placeIn(String corner, Size size, Rect area) {
    final left = corner.endsWith('l') ? area.left : area.right - size.width;
    final top = corner.startsWith('t') ? area.top : area.bottom - size.height;
    return Offset(left.clamp(area.left, math.max(area.left, area.right - size.width)), top.clamp(area.top, math.max(area.top, area.bottom - size.height)));
  }

  /// Where in [window] it may stand: inside the screen's own edges ([pad]), under the title bar, above the composer or
  /// the dock (and Dial-Up's taskbar), a step in from the sides.
  @visibleForTesting
  static Rect areaIn(Size window, EdgeInsets pad, Tokens t) {
    final side = t.space(3);
    final top = pad.top + 64;
    final bottom = pad.bottom + math.max(NavPill.clearance(t), 88.0) + (isBevelChrome(t) ? NavPill.taskbarHeight : 0);
    return Rect.fromLTRB(pad.left + side, top, math.max(pad.left + side, window.width - pad.right - side), math.max(top, window.height - bottom));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: CallFloat.instance,
        builder: (context, _) {
          final p = CallFloat.instance.picture;
          final s = Voice.instance.session;
          if (p == null || s == null) return const SizedBox.shrink();
          return _Float(key: const ValueKey('call-float'), session: s, picture: p, onOpen: onOpen);
        },
      );
}

class _Float extends StatefulWidget {
  const _Float({super.key, required this.session, required this.picture, required this.onOpen});
  final VoiceSession session;
  final CallPicture picture;
  final VoidCallback onOpen;

  @override
  State<_Float> createState() => _FloatState();
}

class _FloatState extends State<_Float> {
  /// Its top left while being dragged; null where it rests in its corner.
  Offset? _drag;
  bool _over = false, _focused = false, _tapped = false;
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  /// A tap shows the buttons, or puts them away; shown by a tap they go again after a few seconds.
  void _tap() {
    _hide?.cancel();
    setState(() => _tapped = !_tapped);
    if (_tapped) {
      _hide = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _tapped = false);
      });
    }
  }

  void _mute() {
    final s = widget.session;
    // Locked (GMFB-49), the press says why, as the call's own mute does.
    s.locked ? sayMicLocked(context, s) : s.setMuted(!s.muted);
  }

  void _toggleSize(AppState? app, bool large) => app?.set(CallFloat.largePref, large ? '' : '1');

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final app = AppState.maybeOf(context);
    final dialup = isBevelChrome(t);
    final computer = Sms.computer;
    final large = computer && app?.choice(CallFloat.largePref, '') == '1';
    final corner = app?.choice(CallFloat.cornerPref, CallFloat.firstCorner) ?? CallFloat.firstCorner;
    final pad = MediaQuery.paddingOf(context);
    final reduced = t.reducedMotion;
    // A screen reader's person reaches every button at once: nothing waits on a hover or a tap.
    final reading = MediaQuery.accessibleNavigationOf(context);
    return LayoutBuilder(builder: (context, box) {
      final window = box.biggest;
      final area = CallFloatLayer.areaIn(window, pad, t);
      return ValueListenableBuilder<Map<String, double>>(
        valueListenable: VideoShapes.changes,
        builder: (context, _, _) {
          final p = widget.picture;
          final shape = VideoShapes.of(p.stream.id) ?? (p.screen ? 16 / 9 : 4 / 3);
          final picture = CallFloatLayer.sizeFor(window: window, shape: shape, large: large, computer: computer);
          // Dial-Up's is a small window: its title bar over the picture, its tools under it.
          final bar = TitleBar.heightOf(t, withClose: true);
          final tools = computer ? 28.0 : 40.0;
          final size = dialup ? Size(math.max(picture.width, computer ? 150.0 : 176.0) + 4, picture.height + bar + tools + 4) : picture;
          final rest = CallFloatLayer.placeIn(corner, size, area);
          final at = _drag ?? rest;
          final s = widget.session;
          final shown = dialup || reading || _over || _focused || _tapped;
          final tile = dialup ? _dialup(t, s, p, large, app, computer) : _glacier(t, s, p, shown, large, app, computer);
          return Stack(children: [
            AnimatedPositioned(
              duration: _drag != null || reduced ? Duration.zero : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              left: at.dx,
              top: at.dy,
              width: size.width,
              height: size.height,
              child: Semantics(
                container: true,
                label: '${p.label}, from ${s.channel.name.isEmpty ? 'the call' : s.channel.name}${p.muted ? ', muted' : ''}. Drag to move it.',
                child: Focus(
                  canRequestFocus: false,
                  skipTraversal: true,
                  onFocusChange: (on) => setState(() => _focused = on),
                  child: MouseRegion(
                    onEnter: (_) => setState(() => _over = true),
                    onExit: (_) => setState(() => _over = false),
                    child: GestureDetector(
                      key: const ValueKey('call-float-tile'),
                      behavior: HitTestBehavior.opaque,
                      onTap: dialup ? null : _tap,
                      onPanStart: (_) => setState(() => _drag = rest),
                      onPanUpdate: (d) => setState(() => _drag = (_drag ?? rest) + d.delta),
                      onPanEnd: (d) {
                        final from = _drag ?? rest;
                        // Thrown, it goes the way it was thrown: where it would come to rest a moment on.
                        final centre = from + Offset(size.width / 2, size.height / 2) + d.velocity.pixelsPerSecond * 0.12;
                        final to = CallFloatLayer.cornerNear(centre, area);
                        app?.set(CallFloat.cornerPref, to);
                        setState(() => _drag = null);
                      },
                      onPanCancel: () => setState(() => _drag = null),
                      child: tile,
                    ),
                  ),
                ),
              ),
            ),
          ]);
        },
      );
    });
  }

  /// The picture itself: taken from the call's page while it floats (StreamView.claim), so it is drawn here alone.
  Widget _view(CallPicture p) => StreamView(key: ObjectKey(p.stream), stream: p.stream, claim: true, contain: p.screen, mirror: p.me && !p.screen && !widget.session.backCamera);

  Widget _glacier(Tokens t, VoiceSession s, CallPicture p, bool shown, bool large, AppState? app, bool computer) {
    final radius = BorderRadius.circular(t.radius('lg'));
    const white = Color(0xFFFFFFFF);
    return Container(
      decoration: BoxDecoration(borderRadius: radius, boxShadow: t.shadowOf('0 8px 28px rgba(0,0,0,0.28)')),
      // A hairline round it, so a dark picture still has an edge on a dark page.
      foregroundDecoration: BoxDecoration(borderRadius: radius, border: Border.all(color: t.color('glacier-border-subtle'), width: t.len('glacier-hairline'))),
      child: ClipRRect(
        borderRadius: radius,
        child: ColoredBox(
          color: const Color(0xFF000000),
          child: Stack(fit: StackFit.expand, children: [
            _view(p),
            // Its name along the foot, on a shade so it reads over any picture.
            PositionedDirectional(
              start: 0,
              end: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x00000000), Color(0x99000000)])),
                child: Padding(
                  padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(3), t.space(2), t.space(1) + 2),
                  child: Row(children: [
                    Flexible(child: Text(p.label, key: const ValueKey('call-float-name'), maxLines: 1, overflow: TextOverflow.ellipsis, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: white))),
                    if (p.muted) ...[SizedBox(width: t.space(1)), AppIcon(p.mark, size: 12, wash: false, color: t.danger)],
                    if (s.muted) ...[SizedBox(width: t.space(1)), AppIcon(LucideMore.micOff, key: const ValueKey('call-float-my-mic'), size: 12, wash: false, color: white.withValues(alpha: 0.8))],
                  ]),
                ),
              ),
            ),
            // The buttons, over a shade: under the pointer, after a tap, or reached by the keyboard.
            IgnorePointer(
              ignoring: !shown,
              child: AnimatedOpacity(
                opacity: shown ? 1 : 0,
                duration: t.reducedMotion ? Duration.zero : const Duration(milliseconds: 140),
                child: ColoredBox(
                  color: const Color(0x66000000),
                  child: Stack(children: [
                    PositionedDirectional(top: 6, start: 6, child: _Round(icon: Lucide.maximize, label: FloatWords.back, onPressed: widget.onOpen)),
                    PositionedDirectional(
                      top: 6,
                      end: 6,
                      child: Row(mainAxisSize: MainAxisSize.min, spacing: 6, children: [
                        if (computer) _Round(icon: large ? LucideMore.shrink : LucideMore.expand, label: large ? FloatWords.smaller : FloatWords.larger, onPressed: () => _toggleSize(app, large)),
                        _Round(icon: Lucide.x, label: FloatWords.close, onPressed: CallFloat.instance.close),
                      ]),
                    ),
                    Center(
                      child: ListenableBuilder(
                        listenable: s,
                        builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, spacing: 10, children: [
                          _Round(icon: s.muted ? LucideMore.micOff : Lucide.mic, label: FloatWords.mute(s), onPressed: _mute, on: s.muted, size: 36),
                          _Round(icon: LucideMore.phoneOff, label: FloatWords.leave, onPressed: () => unawaited(Voice.instance.leave()), danger: true, size: 36),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  /// Dial-Up's: a small raised window, its name in the title bar with the X, the picture in a sunken well, and its
  /// tools in a row under it, always there as the era's windows had them.
  Widget _dialup(Tokens t, VoiceSession s, CallPicture p, bool large, AppState? app, bool computer) {
    final c = DialupColors.of(t);
    final box = computer ? 28.0 : 40.0;
    return Bevel(
      color: c.chrome,
      padding: const EdgeInsets.all(2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TitleBar(title: p.label, onClose: CallFloat.instance.close, closeLabel: FloatWords.close),
        Expanded(child: Sunken(color: const Color(0xFF000000), child: _view(p))),
        SizedBox(
          height: box,
          child: ListenableBuilder(
            listenable: s,
            builder: (context, _) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              DialupTool(icon: Lucide.maximize, label: FloatWords.back, onPressed: widget.onOpen, box: box, size: 16),
              DialupTool(icon: s.muted ? LucideMore.micOff : Lucide.mic, label: FloatWords.mute(s), onPressed: _mute, box: box, size: 16, color: s.muted ? t.danger : null),
              DialupTool(icon: LucideMore.phoneOff, label: FloatWords.leave, onPressed: () => unawaited(Voice.instance.leave()), box: box, size: 16, color: t.danger),
              if (computer) DialupTool(icon: large ? LucideMore.shrink : LucideMore.expand, label: large ? FloatWords.smaller : FloatWords.larger, onPressed: () => _toggleSize(app, large), box: box, size: 16),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// A round button over the picture: white on a dark disc, red for Leave, white with dark ink while [on] (muted).
class _Round extends StatelessWidget {
  const _Round({required this.icon, required this.label, required this.onPressed, this.danger = false, this.on = false, this.size = 30});
  final LucideIcon icon;
  final String label;
  final VoidCallback onPressed;
  final bool danger, on;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => GlacierFocusRing(
        visible: state.focused,
        radius: size,
        offset: 1,
        width: 2,
        color: const Color(0xFFFFFFFF),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: danger ? t.danger.withValues(alpha: state.pressed ? 0.8 : 1) : (on ? const Color(0xFFFFFFFF) : Color.fromRGBO(0, 0, 0, state.pressed || state.hovered ? 0.7 : 0.5)),
          ),
          alignment: Alignment.center,
          child: AppIcon(icon, size: size * 0.5, wash: false, color: on && !danger ? const Color(0xFF000000) : const Color(0xFFFFFFFF)),
        ),
      ),
    );
  }
}
