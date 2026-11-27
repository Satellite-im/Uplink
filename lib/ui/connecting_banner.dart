/// The line a call says what it is waiting for in (lib/voice/call_wait.dart; Matt, 2026-11-24: "show better loading
/// states with skeletal loaders and a connecting banner so it doesn't just seem like the app is frozen"): an arc
/// turning and "Connecting… Starting the microphone", from the press on Join until someone can be heard, and
/// "Connected" for a moment after. [CallWaitBuilder] follows the call for whoever draws it their own way (the
/// sidebar's banner, the list's row); [ConnectingBanner] is the line itself, over a call and among its people.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../backgrounds.dart' show lookCorner;
import '../kit/semantic_colors.dart';
import '../kit/settings_type.dart';
import '../voice/call_wait.dart';
import '../voice/channels.dart';
import '../voice/rtc.dart';
import '../voice/voice.dart';
import 'common.dart';
import 'dialup/bevel.dart' show isBevelChrome;

/// Builds with what the call this device is in is waiting for: null when there is no call or it is through.
/// [connected] is true for a moment after a wait ends with the call joined, for a word that it worked.
class CallWaitBuilder extends StatefulWidget {
  const CallWaitBuilder({super.key, required this.builder, this.voice});
  final Widget Function(BuildContext context, CallWait? wait, bool connected) builder;

  /// Given for a test; the app's own otherwise.
  final Voice? voice;

  /// How long "Connected" is said for.
  static const said = Duration(milliseconds: 1600);

  /// What the call there is is waiting for now, read once ([CallWait.of]).
  static CallWait? now([Voice? voice]) {
    final v = voice ?? Voice.instance;
    final s = v.session;
    if (s == null) return null;
    final media = v.media;
    return CallWait.of(s, joining: v.joining?.room == s.channel.room, links: media?.links.value ?? const {}, micLive: media?.micLive.value ?? true, nameOf: v.nameOf);
  }

  /// How many of those the relay server says are in the call are not in it here yet, while it is being come into:
  /// drawn as bones under one's own face until each is really there (they used to appear all at once, seconds after
  /// the call did, into what looked like an empty call). None once the call is joined, and never more than [most].
  static int coming([Voice? voice, int most = 6]) {
    final v = voice ?? Voice.instance;
    final s = v.session;
    if (s == null || s.joined || v.joining?.room != s.channel.room) return 0;
    return v.inChannel(s.channel).where((id) => id != v.me && !s.members.containsKey(id)).length.clamp(0, most);
  }

  @override
  State<CallWaitBuilder> createState() => _CallWaitBuilderState();
}

class _CallWaitBuilderState extends State<CallWaitBuilder> {
  Voice get _voice => widget.voice ?? Voice.instance;
  VoiceSession? _session;
  RtcMedia? _media;
  CallWait? _wait;
  bool _connected = false;

  /// Looks again when the microphone has had long enough ([CallWait.micPatience]), and puts "Connected" away.
  Timer? _again, _flash;

  @override
  void initState() {
    super.initState();
    _voice.addListener(_changed);
    _follow();
    _wait = CallWaitBuilder.now(_voice);
    _arm();
  }

  @override
  void dispose() {
    _voice.removeListener(_changed);
    _session?.removeListener(_changed);
    _media?.links.removeListener(_changed);
    _media?.micLive.removeListener(_changed);
    _again?.cancel();
    _flash?.cancel();
    super.dispose();
  }

  /// The call and its sound are other objects from one call to the next: what is listened to follows them.
  void _follow() {
    final s = _voice.session, m = _voice.media;
    if (!identical(s, _session)) {
      _session?.removeListener(_changed);
      _session = s?..addListener(_changed);
    }
    if (!identical(m, _media)) {
      _media?.links.removeListener(_changed);
      _media?.micLive.removeListener(_changed);
      _media = m;
      m?.links.addListener(_changed);
      m?.micLive.addListener(_changed);
    }
  }

  /// While the microphone is what is waited for, one more look when its patience is up.
  void _arm() {
    _again?.cancel();
    _again = null;
    final s = _session, since = _session?.since;
    if (_wait == null || s == null || since == null || !s.joined || (_media?.micLive.value ?? true)) return;
    final left = CallWait.micPatience - DateTime.now().difference(since);
    if (left > Duration.zero) _again = Timer(left + const Duration(milliseconds: 50), _changed);
  }

  void _changed() {
    if (!mounted) return;
    _follow();
    final next = CallWaitBuilder.now(_voice);
    final through = _wait != null && next == null && (_voice.session?.joined ?? false);
    if (next == _wait && !through) return;
    setState(() {
      _wait = next;
      if (through) {
        _connected = true;
        _flash?.cancel();
        _flash = Timer(CallWaitBuilder.said, () {
          if (mounted) setState(() => _connected = false);
        });
      } else if (next != null || _voice.session == null) {
        _connected = false;
        _flash?.cancel();
      }
    });
    _arm();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _wait, _connected && _wait == null);
}

/// The line itself. Nothing at all while the call is through, so it can stand wherever a call is drawn.
class ConnectingBanner extends StatelessWidget {
  const ConnectingBanner({super.key, this.wide = false, this.padding = EdgeInsets.zero, this.voice});

  /// Across the width it is given, as a line in a list of people; otherwise a pill as wide as its words.
  final bool wide;

  /// Room round it while it shows (none is kept while it doesn't).
  final EdgeInsets padding;

  /// Given for a test; the app's own otherwise.
  final Voice? voice;

  /// How tall the line is: what a line under it moves down by ([CallBanners]).
  static const double height = ConnectingPill.height;

  /// The colour of a call that is still connecting, as on a face ([LinkBadge]).
  static Color amber(Tokens t) => t.colorOf('#e08a1e');

  @override
  Widget build(BuildContext context) {
    return CallWaitBuilder(
      voice: voice,
      builder: (context, wait, connected) {
        final t = context.tokens;
        final shown = wait != null || connected;
        final which = ValueKey(connected ? 'call-connected' : 'call-connecting');
        final pill = Padding(padding: padding, child: ConnectingPill(title: wait?.title ?? 'Connected', detail: wait?.detail, done: connected, wide: wide));
        final line = !shown
            ? const SizedBox(key: ValueKey('call-connecting-none'), width: double.infinity)
            : (wide ? KeyedSubtree(key: which, child: pill) : Center(key: which, heightFactor: 1, child: pill));
        // It comes and goes by growing and fading, not by a jump of everything under it.
        return AnimatedSize(
          duration: t.reducedMotion ? Duration.zero : const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: t.reducedMotion ? Duration.zero : const Duration(milliseconds: 180),
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: line,
          ),
        );
      },
    );
  }
}

/// A line that says something is being reached, with an arc turning beside it: the call's ([ConnectingBanner]), and
/// a space's chat before the relay server has answered (lib/ui/hangout_screen.dart). Amber while it waits, as a face
/// still connecting is; green with a tick once [done].
class ConnectingPill extends StatelessWidget {
  const ConnectingPill({super.key, required this.title, this.detail, this.done = false, this.wide = false});

  /// `Connecting…`, in the page's ink.
  final String title;

  /// What exactly, quieter, after it.
  final String? detail;
  final bool done;

  /// Across the width it is given; otherwise as wide as its words.
  final bool wide;

  static const double height = 34;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final hue = done ? t.online : ConnectingBanner.amber(t);
    final said = detail;
    return Semantics(
      liveRegion: true,
      container: true,
      label: said == null ? title : '$title $said',
      child: ExcludeSemantics(
        child: Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: t.space(3)),
          decoration: BoxDecoration(
            color: Color.alphaBlend(hue.withValues(alpha: 0.16), t.color('glacier-bg')),
            borderRadius: BorderRadius.circular(isBevelChrome(t) ? 0 : (wide ? lookCorner(t, '0.75rem') : height / 2)),
            border: Border.all(color: hue.withValues(alpha: 0.5), width: 1.5),
            boxShadow: wide ? null : t.shadowOf('0 4px 14px rgba(0,0,0,0.18)'),
          ),
          child: Row(mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min, children: [
            SizedBox.square(
              dimension: 16,
              child: done ? AppIcon(Lucide.check, size: 16, strokeWidth: 2.6, wash: false, color: hue) : const GhostSpinner(size: 14),
            ),
            SizedBox(width: t.space(2)),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: title, style: pageText(t, t.fontSize('sm'), weight: 'semibold', color: t.color('app-ink'))),
                  if (said != null) TextSpan(text: '  $said'),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: pageText(t, t.fontSize('sm'), color: t.color('app-ink-2')),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
