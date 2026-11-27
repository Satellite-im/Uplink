/// The recording's meters and its mixer (Matt, 2026-11-20: "complete the rework of the recording plugin to show audio
/// tracks being recorded in real time with meters and whatnot as well as voice level changing and more").
///
/// - [LevelMeter] is a meter as a mixing desk has one: the average loudness as a solid bar and the peaks as a lighter
///   one over it, on a decibel scale; it rises at once and falls back slowly, the loudest peak of the last second and
///   a half stays as a line, and a lamp at its end lights when the voice clips and stays lit until it is pressed.
/// - [MixerView] is the panel's second face: a channel strip per voice, its meter beside a fader that sets how loud
///   that voice is in the track of everyone mixed, the fader's decibels, and mute and solo. The mix's own strip shows
///   what the faders make of them all. What is moved while recording is kept with its moment and played back into
///   the mix (RecordingMix, mixPcm); each person's own track stays as recorded.
part of 'recording_float.dart';

/// The lowest a meter or a fader's scale shows, in decibels under the top of what a file holds.
const _floorDb = -54.0;

/// A level (0 to 1 of full scale) in decibels, no lower than the scale's floor.
double _db(double level) => level <= 0 ? _floorDb : math.max(_floorDb, 20 * math.log(level) / math.ln10);

/// Where a level stands on a meter, 0 at the floor to 1 at full scale.
double _onScale(double level) => (1 - _db(level) / _floorDb).clamp(0.0, 1.0);

/// A fader's place (0 at its foot to 1 at its head) as a gain, and back. Three quarters of the way up is as recorded
/// (0 dB); above it up to +6 dB, below it down to -42 dB and then nothing at the very foot.
const _unityAt = 0.75;
const _faderFloorDb = -42.0;
final _topDb = 20 * math.log(RecordingMix.most) / math.ln10;

/// The gain a fader at [place] gives.
double _gainAt(double place) {
  if (place <= 0.01) return 0;
  final db = place >= _unityAt ? (place - _unityAt) / (1 - _unityAt) * _topDb : _faderFloorDb * (1 - place / _unityAt);
  return math.pow(10, db / 20).toDouble();
}

/// Where a fader stands for [gain]: [_gainAt] the other way.
double _placeOf(double gain) {
  if (gain <= 0) return 0;
  final db = 20 * math.log(gain) / math.ln10;
  if (db >= 0) return (_unityAt + db / _topDb * (1 - _unityAt)).clamp(0.0, 1.0);
  return (_unityAt * (1 - db / _faderFloorDb)).clamp(0.01, _unityAt);
}

/// A gain as a desk writes it: "0.0", "+3.5", "-12", or "off".
String _gainWords(double gain) {
  if (gain <= 0) return 'off';
  final db = 20 * math.log(gain) / math.ln10;
  if (db.abs() < 0.05) return '0.0';
  final s = db.abs() >= 10 ? db.abs().toStringAsFixed(0) : db.abs().toStringAsFixed(1);
  return '${db > 0 ? '+' : '-'}$s';
}

/// Everyone mixed, now: the faders' gains on each voice, the powers added (voices that are not one another's echo add
/// as power does) and the peaks added, held to full scale.
({double peak, double rms}) _mixNow(RecordingDesk rec) {
  var peak = 0.0, power = 0.0;
  for (final tr in rec.tracks) {
    if (!tr.live) continue;
    final n = rec.meter.now[tr.key];
    if (n == null) continue;
    final g = rec.mix.gain(tr.key);
    peak += n.peak * g;
    power += n.rms * g * n.rms * g;
  }
  return (peak: math.min(1.0, peak), rms: math.min(1.0, math.sqrt(power)));
}

/// A voice now as its strip shows it: after its fader where [post], silent where it is not being taken.
({double peak, double rms}) _trackNow(RecordingDesk rec, String key, {required bool live, bool post = true}) {
  if (key == _mixKey) return _mixNow(rec);
  final n = rec.meter.now[key];
  if (!live || n == null) return (peak: 0, rms: 0);
  final g = post ? rec.mix.gain(key) : 1.0;
  return (peak: math.min(1.0, n.peak * g), rms: math.min(1.0, n.rms * g));
}

/// A meter of one voice: see the top of the file.
class LevelMeter extends StatefulWidget {
  const LevelMeter({super.key, required this.read, required this.listenable, this.vertical = true, this.clipped = false, this.onClearClip, this.thickness = 10, this.scale = false});

  /// The voice now.
  final ({double peak, double rms}) Function() read;

  /// What says the voice has moved.
  final Listenable listenable;
  final bool vertical;

  /// The voice has clipped: its lamp is lit until pressed.
  final bool clipped;
  final VoidCallback? onClearClip;
  final double thickness;

  /// Decibel marks beside it (a vertical meter's).
  final bool scale;

  @override
  State<LevelMeter> createState() => _LevelMeterState();
}

class _LevelMeterState extends State<LevelMeter> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  /// What is drawn, on the meter's scale (0 to 1).
  double _peak = 0, _rms = 0, _hold = 0;
  Duration _heldAt = Duration.zero;

  /// What the voice last was.
  double _toPeak = 0, _toRms = 0;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_heard);
    _heard();
    // As it stands at once (a picture of it is whole), then moving.
    _peak = _toPeak;
    _rms = _toRms;
    _hold = _toPeak;
  }

  @override
  void didUpdateWidget(LevelMeter old) {
    super.didUpdateWidget(old);
    if (old.listenable != widget.listenable) {
      old.listenable.removeListener(_heard);
      widget.listenable.addListener(_heard);
    }
    _heard();
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_heard);
    _ticker.dispose();
    super.dispose();
  }

  /// The voice moved: reads where the bars are to go, and starts the ticker that takes them there.
  void _heard() {
    final n = widget.read();
    _toPeak = _onScale(n.peak);
    _toRms = _onScale(n.rms);
    // Moving only while there is somewhere to go.
    if (!_ticker.isActive && (_toPeak != _peak || _toRms != _rms || _hold > _peak)) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  /// A frame: moves the bars and the held peak towards where the voice is, and stops once they are there.
  void _tick(Duration now) {
    final dt = _last == Duration.zero ? 0.016 : (now - _last).inMicroseconds / 1e6;
    _last = now;
    // Up at once; down at about 26 dB a second for the peaks, slower for the average, as a desk's meter falls.
    double fall(double at, double to, double perSecond) => to >= at ? to : math.max(to, at - perSecond * dt);
    final peak = fall(_peak, _toPeak, 26 / -_floorDb);
    final rms = fall(_rms, _toRms, 16 / -_floorDb);
    var hold = _hold;
    if (peak >= hold) {
      hold = peak;
      _heldAt = now;
    } else if (now - _heldAt > const Duration(milliseconds: 1500)) {
      hold = math.max(peak, hold - 0.6 * dt);
    }
    final still = peak == _toPeak && rms == _toRms && hold <= peak;
    setState(() {
      _peak = peak;
      _rms = rms;
      _hold = hold;
    });
    if (still) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final lamp = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.clipped ? widget.onClearClip : null,
      child: Semantics(
        label: widget.clipped ? 'Clipped. Clear' : null,
        button: widget.clipped,
        child: Container(
          width: widget.vertical ? widget.thickness : 5,
          height: widget.vertical ? 5 : widget.thickness,
          decoration: BoxDecoration(color: widget.clipped ? _Studio.rec : _Studio.bar, borderRadius: BorderRadius.circular(2)),
        ),
      ),
    );
    final bar = CustomPaint(
      size: widget.vertical ? Size(widget.thickness, double.infinity) : Size(double.infinity, widget.thickness),
      painter: _MeterPainter(peak: _peak, rms: _rms, hold: _hold, vertical: widget.vertical),
    );
    if (!widget.vertical) {
      return Row(children: [Expanded(child: SizedBox(height: widget.thickness, child: bar)), const SizedBox(width: 2), lamp]);
    }
    final column = Column(children: [lamp, const SizedBox(height: 2), Expanded(child: SizedBox(width: widget.thickness, child: bar))]);
    if (!widget.scale) return column;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      column,
      const SizedBox(width: 3),
      // The scale's marks, each at its place up the meter (under the lamp).
      SizedBox(
        width: 15,
        child: Padding(
          padding: const EdgeInsets.only(top: 7),
          child: CustomPaint(size: Size.infinite, painter: _ScalePainter(style: pageText(t, 8, weight: 'semibold', color: _Studio.ink3, mono: true))),
        ),
      ),
    ]);
  }
}

/// The meter's bar: its ground, the peaks light, the average solid, the held peak a line; green to amber to red by
/// where on the scale each part is, not by how loud the voice is now.
class _MeterPainter extends CustomPainter {
  _MeterPainter({required this.peak, required this.rms, required this.hold, required this.vertical});
  final double peak, rms, hold;
  final bool vertical;

  static const _green = Color(0xFF34C759), _amber = Color(0xFFFFCC00), _red = Color(0xFFFF3B30);

  /// Amber from -12 dB, red from -3 dB.
  static final _amberAt = 1 - 12 / -_floorDb, _redAt = 1 - 3 / -_floorDb;

  @override
  void paint(Canvas canvas, Size size) {
    final long = vertical ? size.height : size.width;
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Offset.zero & size, Paint()..color = _Studio.bar);
    Rect part(double from, double to) => vertical ? Rect.fromLTRB(0, long * (1 - to), size.width, long * (1 - from)) : Rect.fromLTRB(long * from, 0, long * to, size.height);
    void fill(double to, double alpha) {
      if (to <= 0) return;
      for (final (from, until, colour) in [(0.0, _amberAt, _green), (_amberAt, _redAt, _amber), (_redAt, 1.0, _red)]) {
        if (to <= from) break;
        canvas.drawRect(part(from, math.min(to, until)), Paint()..color = colour.withValues(alpha: alpha));
      }
    }

    fill(peak, 0.42);
    fill(rms, 1);
    if (hold > 0.01) {
      final colour = hold >= _redAt ? _red : (hold >= _amberAt ? _amber : _green);
      final at = long * hold;
      canvas.drawRect(vertical ? Rect.fromLTWH(0, math.max(0, long - at), size.width, 1.5) : Rect.fromLTWH(math.min(long - 1.5, at), 0, 1.5, size.height), Paint()..color = colour);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.peak != peak || old.rms != rms || old.hold != hold;
}

/// Decibel marks up a vertical meter: 0, -6, -12, -24, -36, -48.
class _ScalePainter extends CustomPainter {
  _ScalePainter({required this.style});
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    for (final db in const [0, -6, -12, -24, -36, -48]) {
      final y = size.height * (db / _floorDb);
      final tp = TextPainter(text: TextSpan(text: '${-db}', style: style), textDirection: TextDirection.ltr)..layout();
      if (y + tp.height / 2 > size.height) continue;
      canvas.drawRect(Rect.fromLTWH(0, y, 3, 1), Paint()..color = _Studio.tick);
      tp.paint(canvas, Offset(5, math.max(0, y - tp.height / 2)));
    }
  }

  @override
  bool shouldRepaint(_ScalePainter old) => false;
}

/// A fader: dragged up and down to set a voice's loudness in the mix; pressed twice, back to as recorded.
class MixFader extends StatelessWidget {
  const MixFader({super.key, required this.gain, required this.onChanged, required this.label, this.enabled = true, this.colour = _Studio.ink});
  final double gain;
  final ValueChanged<double> onChanged;
  final String label;
  final bool enabled;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      const capH = 22.0;
      final travel = math.max(1.0, box.maxHeight - capH);
      final place = _placeOf(gain);
      void to(double dy) {
        var p = (1 - (dy - capH / 2) / travel).clamp(0.0, 1.0);
        // Held at as-recorded when near it.
        if ((p - _unityAt).abs() < 0.025) p = _unityAt;
        onChanged(p == _unityAt ? 1 : _gainAt(p));
      }

      double nudged(double by) => _gainAt((_placeOf(gain) + by).clamp(0.0, 1.0));
      String said(double g) => '${_gainWords(g)}${g > 0 ? ' decibels' : ''}';
      return Semantics(
        label: label,
        value: said(gain),
        increasedValue: said(nudged(0.04)),
        decreasedValue: said(nudged(-0.04)),
        slider: true,
        onIncrease: enabled ? () => onChanged(nudged(0.04)) : null,
        onDecrease: enabled ? () => onChanged(nudged(-0.04)) : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: enabled ? (d) => to(d.localPosition.dy) : null,
          onVerticalDragUpdate: enabled ? (d) => to(d.localPosition.dy) : null,
          onTapDown: enabled ? (d) => to(d.localPosition.dy) : null,
          onDoubleTap: enabled ? () => onChanged(1) : null,
          child: SizedBox(
            width: 30,
            height: box.maxHeight,
            child: Stack(alignment: Alignment.topCenter, children: [
              // The slot, and a notch where as-recorded is.
              Positioned(top: capH / 2, bottom: capH / 2, child: Container(width: 4, decoration: BoxDecoration(color: _Studio.bar, borderRadius: BorderRadius.circular(2), border: Border.all(color: _Studio.edge)))),
              Positioned(top: capH / 2 + travel * (1 - _unityAt) - 0.5, child: Container(width: 18, height: 1, color: _Studio.tick)),
              Positioned(
                top: travel * (1 - place),
                child: Container(
                  width: 26,
                  height: capH,
                  decoration: BoxDecoration(
                    color: enabled ? const Color(0xFF3A3A41) : _Studio.header,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: enabled ? const Color(0xFF55555E) : _Studio.edge),
                    boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4, offset: Offset(0, 2))],
                  ),
                  alignment: Alignment.center,
                  child: Container(width: 16, height: 2, decoration: BoxDecoration(color: enabled ? colour : _Studio.ink3, borderRadius: BorderRadius.circular(1))),
                ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}

/// M or S on a strip: lit when on.
class _StripButton extends StatelessWidget {
  const _StripButton({super.key, required this.letter, required this.label, required this.on, required this.lit, required this.onPressed, this.size = 22});
  final String letter;
  final String label;
  final bool on;
  final Color lit;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlacierPressable(
      onPressed: onPressed,
      semanticLabel: label,
      builder: (context, state) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? lit : (state.hovered || state.pressed ? _Studio.header : _Studio.bar),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: on ? lit : _Studio.edge),
        ),
        child: Text(letter, style: pageText(t, 10, weight: 'bold', color: on ? const Color(0xFF17171A) : (onPressed == null ? _Studio.ink3 : _Studio.ink2), mono: true)),
      ),
    );
  }
}

/// The mute and solo buttons' colours while on: amber and yellow, as a desk's are.
const _muteLit = Color(0xFFFF9F0A), _soloLit = Color(0xFFFFD60A);

/// The mixer: a strip for the mix, then one per voice.
class MixerView extends StatelessWidget {
  const MixerView({super.key, required this.recorder, required this.tracks});
  final RecordingDesk recorder;
  final List<({String key, String name, bool live})> tracks;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rec = recorder;
    return LayoutBuilder(builder: (context, box) {
      // Strips as wide as there is room for, between a least and a most; more than fit are scrolled to.
      final stripW = (box.maxWidth / tracks.length).clamp(t.lenOf('5.25rem'), t.lenOf('7.5rem'));
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          height: box.maxHeight,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < tracks.length; i++)
              _Strip(key: ValueKey('recording-strip-${tracks[i].key}'), recorder: rec, track: tracks[i], label: i == 0 ? 'Mix' : 'A$i', width: stripW),
          ]),
        ),
      );
    });
  }
}

/// One channel strip: its label and name, the meter beside the fader, the fader's decibels, and mute and solo.
class _Strip extends StatelessWidget {
  const _Strip({super.key, required this.recorder, required this.track, required this.label, required this.width});
  final RecordingDesk recorder;
  final ({String key, String name, bool live}) track;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final rec = recorder;
    final key = track.key;
    final isMix = key == _mixKey;
    final colour = _colourOf(t, key);
    final mix = rec.mix;
    final out = !isMix && mix.gain(key) == 0;
    return Container(
      width: width,
      decoration: BoxDecoration(color: isMix ? _Studio.bar : _Studio.lane, border: const Border(right: BorderSide(color: _Studio.edge))),
      padding: EdgeInsetsDirectional.fromSTEB(t.space(2), t.space(2), t.space(2), t.space(2)),
      child: Column(children: [
        // The fader's decibels, or the mix's loudest peak now.
        SizedBox(
          height: 16,
          child: isMix
              ? ListenableBuilder(
                  listenable: rec.meter,
                  builder: (context, _) {
                    final n = _mixNow(rec);
                    return Text(n.peak <= 0 ? '-∞' : _db(n.peak).toStringAsFixed(0), style: pageText(t, 10, weight: 'semibold', color: _Studio.ink2, mono: true));
                  },
                )
              : Text(_gainWords(mix.fader(key)), key: ValueKey('recording-gain-$key'), style: pageText(t, 10, weight: 'semibold', color: mix.fader(key) == 1 ? _Studio.ink2 : _Studio.ink, mono: true)),
        ),
        SizedBox(height: t.space(1)),
        Expanded(
          child: Opacity(
            opacity: out || !track.live ? 0.45 : 1,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              LevelMeter(
                key: ValueKey('recording-meter-$key'),
                listenable: Listenable.merge([rec.meter, rec.mix]),
                read: () => _trackNow(rec, key, live: track.live),
                clipped: isMix ? false : rec.meter.clipped.contains(key),
                onClearClip: () => rec.meter.clearClip(key),
                scale: true,
              ),
              if (!isMix) ...[
                SizedBox(width: t.space(1)),
                MixFader(
                  key: ValueKey('recording-fader-$key'),
                  gain: mix.fader(key),
                  label: '${track.name} in the mix',
                  colour: colour,
                  onChanged: (g) => rec.setFader(key, g),
                ),
              ],
            ]),
          ),
        ),
        SizedBox(height: t.space(2)),
        if (isMix)
          SizedBox(height: 22, child: Center(child: Tr('OUT', style: pageText(t, 10, weight: 'bold', color: _Studio.ink3, mono: true, tracking: 1))))
        else
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _StripButton(key: ValueKey('recording-mute-$key'), letter: 'M', label: mix.muted(key) ? 'Unmute ${track.name} in the mix' : 'Mute ${track.name} in the mix', on: mix.muted(key), lit: _muteLit, onPressed: () => rec.setMuted(key, !mix.muted(key))),
            SizedBox(width: t.space(1)),
            _StripButton(key: ValueKey('recording-solo-$key'), letter: 'S', label: mix.soloed(key) ? 'Stop soloing ${track.name}' : 'Solo ${track.name} in the mix', on: mix.soloed(key), lit: _soloLit, onPressed: () => rec.setSolo(key, !mix.soloed(key))),
          ]),
        SizedBox(height: t.space(2)),
        Container(height: 3, decoration: BoxDecoration(color: colour, borderRadius: BorderRadius.circular(2))),
        SizedBox(height: t.space(1)),
        Text(track.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: pageText(t, t.fontSize('xs'), weight: 'semibold', color: track.live ? _Studio.ink : _Studio.ink3)),
        Text(track.live ? label : 'Left', style: pageText(t, 9, weight: 'semibold', color: _Studio.ink3, mono: true)),
      ]),
    );
  }
}
